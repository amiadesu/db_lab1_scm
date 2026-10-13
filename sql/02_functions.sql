SET search_path TO scm, public;

CREATE SEQUENCE po_number_seq;
CREATE SEQUENCE so_number_seq;

-- 1. user_id поточного користувача з users (застосунок задає його через set_config('app.current_user_id', ...))
CREATE OR REPLACE FUNCTION fn_current_app_user()
RETURNS INT LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('app.current_user_id', true), '')::INT;
$$;

-- 2. Вільний залишок товару в inventory: qty_on_hand - qty_reserved
CREATE OR REPLACE FUNCTION fn_available_qty(p_product_id INT, p_warehouse_id INT)
RETURNS INT LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT qty_on_hand - qty_reserved
                     FROM inventory
                     WHERE product_id = p_product_id AND warehouse_id = p_warehouse_id), 0);
$$;

-- 3. Сума замовлення у постачальника за purchase_order_items
CREATE OR REPLACE FUNCTION fn_po_total(p_po_id INT)
RETURNS NUMERIC(14,2) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(line_total), 0)::NUMERIC(14,2)
    FROM purchase_order_items
    WHERE po_id = p_po_id;
$$;

-- 4. Сума замовлення клієнта за sales_order_items
CREATE OR REPLACE FUNCTION fn_so_total(p_so_id INT)
RETURNS NUMERIC(14,2) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(line_total), 0)::NUMERIC(14,2)
    FROM sales_order_items
    WHERE so_id = p_so_id;
$$;

-- 5. Частка purchase_orders постачальника, отриманих не пізніше expected_date
CREATE OR REPLACE FUNCTION fn_supplier_on_time_rate(p_supplier_id INT)
RETURNS NUMERIC(5,4) LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN COUNT(*) = 0 THEN NULL
                ELSE ROUND(COUNT(*) FILTER (WHERE updated_at::date <= expected_date)::numeric / COUNT(*), 4)
           END
    FROM purchase_orders
    WHERE supplier_id = p_supplier_id
      AND status = 'received'
      AND expected_date IS NOT NULL;
$$;

-- 6. Наступний po_number або so_number
CREATE OR REPLACE FUNCTION fn_next_doc_number(p_prefix TEXT)
RETURNS VARCHAR(20) LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_seq BIGINT;
BEGIN
    IF p_prefix = 'PO' THEN
        v_seq := nextval('po_number_seq');
    ELSIF p_prefix = 'SO' THEN
        v_seq := nextval('so_number_seq');
    ELSE
        RAISE EXCEPTION 'Невідомий тип документа %', p_prefix;
    END IF;
    RETURN p_prefix || '-' || to_char(CURRENT_DATE, 'YYYY') || '-' || lpad(v_seq::text, 6, '0');
END $$;

-- 7. Найдешевші активні постачальники товару за supplier_products
CREATE OR REPLACE FUNCTION fn_best_suppliers(p_product_id INT, p_limit INT DEFAULT 3)
RETURNS TABLE (supplier_id INT, supplier_name VARCHAR, purchase_price NUMERIC, lead_time_days INT, rating NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT s.supplier_id, s.name, sp.purchase_price, s.lead_time_days, s.rating
    FROM supplier_products sp
    JOIN suppliers s ON s.supplier_id = sp.supplier_id AND NOT s.is_deleted
    WHERE sp.product_id = p_product_id
    ORDER BY sp.purchase_price, s.lead_time_days, s.rating DESC NULLS LAST
    LIMIT p_limit;
$$;

-- 8. Прізвище з ініціалами для users і supplier_contacts
CREATE OR REPLACE FUNCTION fn_short_name(p_last VARCHAR, p_first VARCHAR, p_middle VARCHAR)
RETURNS VARCHAR LANGUAGE sql IMMUTABLE AS $$
    SELECT p_last || ' ' || left(p_first, 1) || '.' || COALESCE(' ' || left(p_middle, 1) || '.', '');
$$;

-- 9. Адреса одним рядком з урахуванням cities і countries
CREATE OR REPLACE FUNCTION fn_format_address(p_city_id INT, p_street VARCHAR, p_building VARCHAR)
RETURNS VARCHAR LANGUAGE sql STABLE AS $$
    SELECT concat_ws(', ', NULLIF(concat_ws(' ', p_street, p_building), ''), c.name, c.region, co.name)
    FROM cities c
    JOIN countries co ON co.country_code = c.country_code
    WHERE c.city_id = p_city_id;
$$;
