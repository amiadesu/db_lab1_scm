SET search_path TO scm, public;

-- 1. Невидалені suppliers з адресою та основним контактом
CREATE OR REPLACE VIEW v_suppliers_active AS
SELECT s.supplier_id, s.name, s.tax_code,
       s.city_id, ci.name AS city_name, ci.country_code, co.name AS country_name,
       s.street, s.building, s.postal_code,
       fn_format_address(s.city_id, s.street, s.building) AS full_address,
       s.phone, s.email, s.rating, s.lead_time_days,
       fn_short_name(pc.last_name, pc.first_name, pc.middle_name) AS primary_contact,
       b.supplier_id IS NOT NULL AS has_bank_details,
       s.updated_at, s.updated_by, u.login AS updated_by_login
FROM suppliers s
JOIN cities ci ON ci.city_id = s.city_id
JOIN countries co ON co.country_code = ci.country_code
LEFT JOIN supplier_contacts pc ON pc.supplier_id = s.supplier_id AND pc.is_primary
LEFT JOIN supplier_bank_details b ON b.supplier_id = s.supplier_id
LEFT JOIN users u ON u.user_id = s.updated_by
WHERE NOT s.is_deleted;

-- 2. Невидалені products з характеристиками та загальним залишком
CREATE OR REPLACE VIEW v_products_active AS
SELECT p.product_id, p.sku, p.name, p.description, p.category_id, cat.name AS category_name,
       uom.code AS uom, p.unit_price, p.weight_kg, p.reorder_level,
       COALESCE((SELECT jsonb_object_agg(a.attr_name, a.attr_value)
                 FROM product_attributes a
                 WHERE a.product_id = p.product_id), '{}'::jsonb) AS attributes,
       COALESCE(st.on_hand, 0) AS total_on_hand,
       COALESCE(st.available, 0) AS total_available,
       p.updated_at, u.login AS updated_by_login
FROM products p
JOIN product_categories cat ON cat.category_id = p.category_id
JOIN units_of_measure uom ON uom.uom_id = p.uom_id
LEFT JOIN LATERAL (
    SELECT SUM(i.qty_on_hand) AS on_hand, SUM(i.qty_on_hand - i.qty_reserved) AS available
    FROM inventory i
    WHERE i.product_id = p.product_id
) st ON TRUE
LEFT JOIN users u ON u.user_id = p.updated_by
WHERE NOT p.is_deleted;

-- 3. inventory по складах із вільним залишком
CREATE OR REPLACE VIEW v_stock_levels AS
SELECT w.warehouse_id, w.code AS warehouse_code, w.name AS warehouse_name,
       p.product_id, p.sku, p.name AS product_name,
       i.qty_on_hand, i.qty_reserved, i.qty_on_hand - i.qty_reserved AS qty_available,
       p.reorder_level,
       i.qty_on_hand - i.qty_reserved <= p.reorder_level AS needs_reorder,
       i.updated_at
FROM inventory i
JOIN warehouses w ON w.warehouse_id = i.warehouse_id AND NOT w.is_deleted
JOIN products p ON p.product_id = i.product_id AND NOT p.is_deleted;

-- 4. Товари з inventory нижче reorder_level і найдешевший постачальник для них
CREATE OR REPLACE VIEW v_reorder_recommendations AS
SELECT sl.warehouse_id, sl.warehouse_code, sl.product_id, sl.sku, sl.product_name,
       sl.qty_available, sl.reorder_level,
       GREATEST(sl.reorder_level * 2 - sl.qty_available, 1) AS suggested_qty,
       bs.supplier_id, bs.supplier_name, bs.purchase_price, bs.lead_time_days
FROM v_stock_levels sl
LEFT JOIN LATERAL fn_best_suppliers(sl.product_id, 1) bs ON TRUE
WHERE sl.needs_reorder;

-- 5. purchase_orders із сумою та відсотком прийнятого товару
CREATE OR REPLACE VIEW v_purchase_orders AS
SELECT po.po_id, po.po_number, po.status, po.order_date, po.expected_date,
       po.supplier_id, s.name AS supplier_name, s.is_deleted AS supplier_deleted,
       po.warehouse_id, w.code AS warehouse_code,
       COALESCE(SUM(i.line_total), 0)::NUMERIC(14,2) AS total_amount,
       po.currency,
       COUNT(i.po_item_id) AS items_count,
       COALESCE(SUM(i.quantity), 0) AS qty_ordered,
       COALESCE(SUM(i.received_qty), 0) AS qty_received,
       CASE WHEN SUM(i.quantity) > 0
            THEN ROUND(100.0 * SUM(i.received_qty) / SUM(i.quantity), 1)
            ELSE 0 END AS received_pct,
       po.created_at, cu.login AS created_by_login,
       po.updated_at, uu.login AS updated_by_login
FROM purchase_orders po
JOIN suppliers s ON s.supplier_id = po.supplier_id
JOIN warehouses w ON w.warehouse_id = po.warehouse_id
LEFT JOIN purchase_order_items i ON i.po_id = po.po_id
LEFT JOIN users cu ON cu.user_id = po.created_by
LEFT JOIN users uu ON uu.user_id = po.updated_by
GROUP BY po.po_id, s.name, s.is_deleted, w.code, cu.login, uu.login;

-- 6. purchase_order_items із назвою товару та недоотриманою кількістю
CREATE OR REPLACE VIEW v_purchase_order_items AS
SELECT i.po_item_id, i.po_id, po.po_number, i.product_id, p.sku, p.name AS product_name,
       i.quantity, i.unit_price, i.line_total, i.received_qty,
       i.quantity - i.received_qty AS qty_outstanding
FROM purchase_order_items i
JOIN purchase_orders po ON po.po_id = i.po_id
JOIN products p ON p.product_id = i.product_id;

-- 7. Кількість, сума та вчасність purchase_orders для кожного постачальника
CREATE OR REPLACE VIEW v_supplier_performance AS
SELECT s.supplier_id, s.name, s.rating, s.lead_time_days,
       COUNT(po.po_id) AS orders_total,
       COUNT(po.po_id) FILTER (WHERE po.status = 'received') AS orders_received,
       COUNT(po.po_id) FILTER (WHERE po.status = 'cancelled') AS orders_cancelled,
       COALESCE(SUM(fn_po_total(po.po_id)) FILTER (WHERE po.status <> 'cancelled'), 0) AS total_spend,
       fn_supplier_on_time_rate(s.supplier_id) AS on_time_rate
FROM suppliers s
LEFT JOIN purchase_orders po ON po.supplier_id = s.supplier_id
WHERE NOT s.is_deleted
GROUP BY s.supplier_id;

-- 8. Записи з is_deleted = TRUE з усіх таблиць
CREATE OR REPLACE VIEW v_recycle_bin AS
SELECT 'suppliers' AS entity, supplier_id AS id, name, deleted_at, deleted_by FROM suppliers WHERE is_deleted
UNION ALL
SELECT 'products', product_id, name, deleted_at, deleted_by FROM products WHERE is_deleted
UNION ALL
SELECT 'warehouses', warehouse_id, name, deleted_at, deleted_by FROM warehouses WHERE is_deleted
UNION ALL
SELECT 'customers', customer_id, name, deleted_at, deleted_by FROM customers WHERE is_deleted
UNION ALL
SELECT 'carriers', carrier_id, name, deleted_at, deleted_by FROM carriers WHERE is_deleted;

-- 9. audit_log з логіном автора і лише зміненими полями
CREATE OR REPLACE VIEW v_change_history AS
SELECT a.audit_id, a.changed_at, a.table_name, a.record_id, a.operation,
       u.login AS changed_by_login,
       CASE WHEN a.operation IN ('UPDATE', 'SOFT_DEL', 'RESTORE') THEN (
           SELECT jsonb_object_agg(n.key, jsonb_build_object('old', a.old_data->n.key, 'new', n.value))
           FROM jsonb_each(a.new_data) n
           WHERE n.value IS DISTINCT FROM a.old_data->n.key
             AND n.key NOT IN ('updated_at', 'search_vector')
       ) END AS changed_fields
FROM audit_log a
LEFT JOIN users u ON u.user_id = a.changed_by;

-- 10. sales_orders із сумою та даними з shipments
CREATE OR REPLACE VIEW v_sales_orders AS
SELECT so.so_id, so.so_number, so.status, so.order_date, so.required_date,
       c.customer_id, c.name AS customer_name, w.code AS warehouse_code,
       fn_so_total(so.so_id) AS total_amount,
       sh.shipment_id, sh.tracking_number, sh.status AS shipment_status, cr.name AS carrier_name
FROM sales_orders so
JOIN customers c ON c.customer_id = so.customer_id
JOIN warehouses w ON w.warehouse_id = so.warehouse_id
LEFT JOIN shipments sh ON sh.so_id = so.so_id
LEFT JOIN carriers cr ON cr.carrier_id = sh.carrier_id;

-- 11. Невидалені warehouses з адресою та менеджером
CREATE OR REPLACE VIEW v_warehouses_active AS
SELECT w.warehouse_id, w.code, w.name,
       fn_format_address(w.city_id, w.street, w.building) AS full_address,
       w.location, w.capacity_m3,
       fn_short_name(m.last_name, m.first_name, m.middle_name) AS manager
FROM warehouses w
LEFT JOIN users m ON m.user_id = w.manager_id
WHERE NOT w.is_deleted;

-- 12. carrier_contracts, що діють сьогодні
CREATE OR REPLACE VIEW v_carrier_current_rates AS
SELECT c.carrier_id, c.name, c.transport_mode, cc.rate_per_kg,
       lower(cc.valid_period) AS valid_from, upper(cc.valid_period) AS valid_to
FROM carriers c
JOIN carrier_contracts cc ON cc.carrier_id = c.carrier_id
WHERE NOT c.is_deleted AND cc.valid_period @> CURRENT_DATE;

-- 13. Сума purchase_order_items по місяцях і product_categories
CREATE MATERIALIZED VIEW mv_monthly_purchases AS
SELECT date_trunc('month', po.order_date)::date AS month,
       cat.name AS category,
       SUM(i.quantity) AS qty,
       SUM(i.line_total) AS amount
FROM purchase_orders po
JOIN purchase_order_items i ON i.po_id = po.po_id
JOIN products p ON p.product_id = i.product_id
JOIN product_categories cat ON cat.category_id = p.category_id
WHERE po.status <> 'cancelled'
GROUP BY 1, 2
WITH NO DATA;

CREATE UNIQUE INDEX ux_mv_monthly_purchases ON mv_monthly_purchases(month, category);
