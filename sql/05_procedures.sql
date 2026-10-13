SET search_path TO scm, public;

-- 1. Вставка в suppliers
CREATE OR REPLACE PROCEDURE sp_supplier_create(
    p_name VARCHAR, p_tax_code VARCHAR, p_city_id INT,
    p_street VARCHAR, p_building VARCHAR, p_email VARCHAR, p_phone VARCHAR, p_lead_time_days INT,
    INOUT p_supplier_id INT DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM suppliers WHERE tax_code = p_tax_code AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Постачальник з кодом % уже існує', p_tax_code;
    END IF;

    INSERT INTO suppliers(name, tax_code, city_id, street, building, email, phone, lead_time_days, created_by)
    VALUES (p_name, p_tax_code, p_city_id, p_street, p_building, p_email, p_phone,
            COALESCE(p_lead_time_days, 7), fn_current_app_user())
    RETURNING supplier_id INTO p_supplier_id;
END $$;

-- 2. Оновлення suppliers (NULL - поле не змінюється)
CREATE OR REPLACE PROCEDURE sp_supplier_update(
    p_supplier_id INT, p_name VARCHAR DEFAULT NULL, p_city_id INT DEFAULT NULL,
    p_email VARCHAR DEFAULT NULL, p_phone VARCHAR DEFAULT NULL,
    p_rating NUMERIC DEFAULT NULL, p_lead_time_days INT DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE suppliers
    SET name = COALESCE(p_name, name),
        city_id = COALESCE(p_city_id, city_id),
        email = COALESCE(p_email, email),
        phone = COALESCE(p_phone, phone),
        rating = COALESCE(p_rating, rating),
        lead_time_days = COALESCE(p_lead_time_days, lead_time_days)
    WHERE supplier_id = p_supplier_id AND NOT is_deleted;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Активного постачальника % не знайдено', p_supplier_id;
    END IF;
END $$;

-- 3. Soft delete у suppliers, якщо немає відкритих purchase_orders
CREATE OR REPLACE PROCEDURE sp_supplier_soft_delete(p_supplier_id INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM purchase_orders
               WHERE supplier_id = p_supplier_id
                 AND status IN ('draft', 'approved', 'sent', 'partially_received')) THEN
        RAISE EXCEPTION 'У постачальника % є незакриті замовлення', p_supplier_id;
    END IF;

    UPDATE suppliers
    SET is_deleted = TRUE, deleted_at = now(), deleted_by = fn_current_app_user()
    WHERE supplier_id = p_supplier_id AND NOT is_deleted;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Активного постачальника % не знайдено', p_supplier_id;
    END IF;
END $$;

-- 4. Відновлення видаленого запису suppliers
CREATE OR REPLACE PROCEDURE sp_supplier_restore(p_supplier_id INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM suppliers a
               JOIN suppliers d ON d.tax_code = a.tax_code
               WHERE d.supplier_id = p_supplier_id AND a.supplier_id <> p_supplier_id AND NOT a.is_deleted) THEN
        RAISE EXCEPTION 'Активний постачальник з таким кодом уже існує';
    END IF;

    UPDATE suppliers
    SET is_deleted = FALSE, deleted_at = NULL, deleted_by = NULL
    WHERE supplier_id = p_supplier_id AND is_deleted;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Видаленого постачальника % не знайдено', p_supplier_id;
    END IF;
END $$;

-- 5. Вставка або заміна supplier_bank_details
CREATE OR REPLACE PROCEDURE sp_supplier_set_bank_details(
    p_supplier_id INT, p_bank_name VARCHAR, p_iban VARCHAR,
    p_swift_code VARCHAR DEFAULT NULL, p_currency CHAR(3) DEFAULT 'UAH')
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO supplier_bank_details(supplier_id, bank_name, iban, swift_code, currency)
    VALUES (p_supplier_id, p_bank_name, upper(replace(p_iban, ' ', '')), upper(p_swift_code), p_currency)
    ON CONFLICT (supplier_id) DO UPDATE
    SET bank_name = EXCLUDED.bank_name,
        iban = EXCLUDED.iban,
        swift_code = EXCLUDED.swift_code,
        currency = EXCLUDED.currency;

    UPDATE suppliers SET updated_at = now() WHERE supplier_id = p_supplier_id;
END $$;

-- 6. Вставка або оновлення ціни в supplier_products
CREATE OR REPLACE PROCEDURE sp_supplier_product_upsert(
    p_supplier_id INT, p_product_id INT, p_purchase_price NUMERIC,
    p_min_order_qty INT DEFAULT 1, p_supplier_sku VARCHAR DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO supplier_products(supplier_id, product_id, purchase_price, min_order_qty, supplier_sku)
    VALUES (p_supplier_id, p_product_id, p_purchase_price, p_min_order_qty, p_supplier_sku)
    ON CONFLICT (supplier_id, product_id) DO UPDATE
    SET purchase_price = EXCLUDED.purchase_price,
        min_order_qty = EXCLUDED.min_order_qty,
        supplier_sku = COALESCE(EXCLUDED.supplier_sku, supplier_products.supplier_sku);
END $$;

-- 7. Вставка в products і product_attributes
CREATE OR REPLACE PROCEDURE sp_product_create(
    p_sku VARCHAR, p_name VARCHAR, p_category_id INT, p_uom_code VARCHAR,
    p_unit_price NUMERIC, p_reorder_level INT DEFAULT 0, p_attributes JSONB DEFAULT '{}',
    p_description TEXT DEFAULT NULL,
    INOUT p_product_id INT DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_uom INT;
BEGIN
    SELECT uom_id INTO v_uom FROM units_of_measure WHERE code = p_uom_code;
    IF v_uom IS NULL THEN
        RAISE EXCEPTION 'Невідома одиниця виміру %', p_uom_code;
    END IF;

    INSERT INTO products(sku, name, description, category_id, uom_id, unit_price, reorder_level, created_by)
    VALUES (p_sku, p_name, p_description, p_category_id, v_uom, p_unit_price,
            COALESCE(p_reorder_level, 0), fn_current_app_user())
    RETURNING product_id INTO p_product_id;

    INSERT INTO product_attributes(product_id, attr_name, attr_value)
    SELECT p_product_id, key, value FROM jsonb_each_text(COALESCE(p_attributes, '{}'));
END $$;

-- 8. Оновлення products (NULL - поле не змінюється)
CREATE OR REPLACE PROCEDURE sp_product_update(
    p_product_id INT, p_name VARCHAR DEFAULT NULL, p_unit_price NUMERIC DEFAULT NULL,
    p_reorder_level INT DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE products
    SET name = COALESCE(p_name, name),
        unit_price = COALESCE(p_unit_price, unit_price),
        reorder_level = COALESCE(p_reorder_level, reorder_level)
    WHERE product_id = p_product_id AND NOT is_deleted;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Активного товару % не знайдено', p_product_id;
    END IF;
END $$;

-- 9. Вставка, зміна або видалення (якщо значення NULL) запису product_attributes
CREATE OR REPLACE PROCEDURE sp_product_set_attribute(
    p_product_id INT, p_attr_name VARCHAR, p_attr_value VARCHAR)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_attr_value IS NULL THEN
        DELETE FROM product_attributes WHERE product_id = p_product_id AND attr_name = p_attr_name;
    ELSE
        INSERT INTO product_attributes VALUES (p_product_id, p_attr_name, p_attr_value)
        ON CONFLICT (product_id, attr_name) DO UPDATE SET attr_value = EXCLUDED.attr_value;
    END IF;

    UPDATE products SET updated_at = now() WHERE product_id = p_product_id;
END $$;

-- 10. Soft delete у products, якщо товару немає в inventory
CREATE OR REPLACE PROCEDURE sp_product_soft_delete(p_product_id INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM inventory WHERE product_id = p_product_id AND qty_on_hand > 0) THEN
        RAISE EXCEPTION 'Товар % є на складі, спершу спишіть залишки', p_product_id;
    END IF;

    UPDATE products
    SET is_deleted = TRUE, deleted_at = now(), deleted_by = fn_current_app_user()
    WHERE product_id = p_product_id AND NOT is_deleted;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Активного товару % не знайдено', p_product_id;
    END IF;
END $$;

-- 11. Відновлення видаленого запису products (sku не має збігатися з активним товаром)
CREATE OR REPLACE PROCEDURE sp_product_restore(p_product_id INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM products a
               JOIN products d ON d.sku = a.sku
               WHERE d.product_id = p_product_id AND a.product_id <> p_product_id AND NOT a.is_deleted) THEN
        RAISE EXCEPTION 'Активний товар з таким sku уже існує';
    END IF;

    UPDATE products
    SET is_deleted = FALSE, deleted_at = NULL, deleted_by = NULL
    WHERE product_id = p_product_id AND is_deleted;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Видаленого товару % не знайдено', p_product_id;
    END IF;
END $$;

-- 12. Нове замовлення у постачальника в purchase_orders
CREATE OR REPLACE PROCEDURE sp_po_create(
    p_supplier_id INT, p_warehouse_id INT, p_expected_date DATE DEFAULT NULL,
    INOUT p_po_id INT DEFAULT NULL, INOUT p_po_number VARCHAR DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_lead INT;
BEGIN
    SELECT lead_time_days INTO v_lead FROM suppliers WHERE supplier_id = p_supplier_id;
    p_po_number := fn_next_doc_number('PO');

    INSERT INTO purchase_orders(po_number, supplier_id, warehouse_id, expected_date, created_by)
    VALUES (p_po_number, p_supplier_id, p_warehouse_id,
            COALESCE(p_expected_date, CURRENT_DATE + COALESCE(v_lead, 7)), fn_current_app_user())
    RETURNING po_id INTO p_po_id;
END $$;

-- 13. Рядок у purchase_order_items (без ціни - береться з supplier_products)
CREATE OR REPLACE PROCEDURE sp_po_add_item(
    p_po_id INT, p_product_id INT, p_quantity INT, p_unit_price NUMERIC DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_price NUMERIC;
    v_moq INT;
    v_current INT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Кількість має бути додатною (%)', p_quantity;
    END IF;

    SELECT sp.purchase_price, sp.min_order_qty INTO v_price, v_moq
    FROM supplier_products sp
    JOIN purchase_orders po ON po.supplier_id = sp.supplier_id
    WHERE po.po_id = p_po_id AND sp.product_id = p_product_id;

    IF v_price IS NULL AND p_unit_price IS NULL THEN
        RAISE EXCEPTION 'Постачальник не постачає товар %, а ціну не вказано', p_product_id;
    END IF;

    SELECT quantity INTO v_current
    FROM purchase_order_items
    WHERE po_id = p_po_id AND product_id = p_product_id;

    IF v_moq IS NOT NULL AND COALESCE(v_current, 0) + p_quantity < v_moq THEN
        RAISE EXCEPTION 'Мінімальна партія товару %: %', p_product_id, v_moq;
    END IF;

    INSERT INTO purchase_order_items(po_id, product_id, quantity, unit_price)
    VALUES (p_po_id, p_product_id, p_quantity, COALESCE(p_unit_price, v_price))
    ON CONFLICT (po_id, product_id) DO UPDATE
    SET quantity = purchase_order_items.quantity + EXCLUDED.quantity;
END $$;

-- 14. Зміна статусу purchase_orders: draft -> approved -> sent, скасування до приймання
CREATE OR REPLACE PROCEDURE sp_po_set_status(p_po_id INT, p_status po_status)
LANGUAGE plpgsql AS $$
DECLARE
    v_old po_status;
BEGIN
    SELECT status INTO v_old FROM purchase_orders WHERE po_id = p_po_id FOR UPDATE;
    IF v_old IS NULL THEN
        RAISE EXCEPTION 'Замовлення % не знайдено', p_po_id;
    END IF;

    IF NOT ((v_old = 'draft' AND p_status IN ('approved', 'cancelled'))
         OR (v_old = 'approved' AND p_status IN ('sent', 'cancelled'))
         OR (v_old = 'sent' AND p_status = 'cancelled')) THEN
        RAISE EXCEPTION 'Недопустимий перехід статусу % -> %', v_old, p_status;
    END IF;
    IF p_status = 'approved' AND NOT EXISTS (SELECT 1 FROM purchase_order_items WHERE po_id = p_po_id) THEN
        RAISE EXCEPTION 'Не можна затвердити порожнє замовлення';
    END IF;

    UPDATE purchase_orders SET status = p_status WHERE po_id = p_po_id;
END $$;

-- 15. Приймання товару за purchase_orders через inventory_movements (p_product_id = NULL - приймається все недоотримане)
CREATE OR REPLACE PROCEDURE sp_po_receive(
    p_po_id INT, p_product_id INT DEFAULT NULL, p_quantity INT DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_po purchase_orders%ROWTYPE;
    r RECORD;
    v_qty INT;
BEGIN
    IF p_quantity IS NOT NULL AND p_product_id IS NULL THEN
        RAISE EXCEPTION 'Кількість можна вказати лише разом з товаром';
    END IF;
    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'Кількість має бути додатною (%)', p_quantity;
    END IF;

    SELECT * INTO v_po FROM purchase_orders WHERE po_id = p_po_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Замовлення % не знайдено', p_po_id;
    END IF;
    IF v_po.status NOT IN ('sent', 'partially_received') THEN
        RAISE EXCEPTION 'Приймати можна лише відправлені замовлення (статус %)', v_po.status;
    END IF;

    FOR r IN SELECT * FROM purchase_order_items
             WHERE po_id = p_po_id
               AND (p_product_id IS NULL OR product_id = p_product_id)
               AND received_qty < quantity
    LOOP
        IF p_quantity > r.quantity - r.received_qty THEN
            RAISE EXCEPTION 'Товару % у замовленні % залишилось прийняти %, а вказано %',
                r.product_id, v_po.po_number, r.quantity - r.received_qty, p_quantity;
        END IF;
        v_qty := COALESCE(p_quantity, r.quantity - r.received_qty);

        UPDATE purchase_order_items
        SET received_qty = received_qty + v_qty
        WHERE po_item_id = r.po_item_id;

        INSERT INTO inventory_movements(warehouse_id, product_id, movement_type, quantity, po_id, created_by)
        VALUES (v_po.warehouse_id, r.product_id, 'receipt', v_qty, p_po_id, fn_current_app_user());
    END LOOP;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'У замовленні % немає неприйнятого товару%', v_po.po_number,
            COALESCE(' ' || p_product_id, '');
    END IF;

    UPDATE purchase_orders
    SET status = CASE WHEN EXISTS (SELECT 1 FROM purchase_order_items
                                   WHERE po_id = p_po_id AND received_qty < quantity)
                      THEN 'partially_received'::po_status
                      ELSE 'received'::po_status END
    WHERE po_id = p_po_id;
END $$;

-- 16. Нове замовлення клієнта в sales_orders
CREATE OR REPLACE PROCEDURE sp_so_create(
    p_customer_id INT, p_warehouse_id INT, p_required_date DATE DEFAULT NULL,
    INOUT p_so_id INT DEFAULT NULL, INOUT p_so_number VARCHAR DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id AND is_deleted) THEN
        RAISE EXCEPTION 'Клієнт % видалений', p_customer_id;
    END IF;
    IF EXISTS (SELECT 1 FROM warehouses WHERE warehouse_id = p_warehouse_id AND is_deleted) THEN
        RAISE EXCEPTION 'Склад % видалений', p_warehouse_id;
    END IF;

    p_so_number := fn_next_doc_number('SO');

    INSERT INTO sales_orders(so_number, customer_id, warehouse_id, required_date, created_by)
    VALUES (p_so_number, p_customer_id, p_warehouse_id, p_required_date, fn_current_app_user())
    RETURNING so_id INTO p_so_id;
END $$;

-- 17. Рядок у sales_order_items з резервуванням у inventory
CREATE OR REPLACE PROCEDURE sp_so_add_item(
    p_so_id INT, p_product_id INT, p_quantity INT, p_discount_pct NUMERIC DEFAULT 0)
LANGUAGE plpgsql AS $$
DECLARE
    v_wh INT;
    v_status so_status;
    v_price NUMERIC;
    v_discount NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Кількість має бути додатною (%)', p_quantity;
    END IF;

    SELECT warehouse_id, status INTO v_wh, v_status FROM sales_orders WHERE so_id = p_so_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Замовлення клієнта % не знайдено', p_so_id;
    END IF;
    IF v_status NOT IN ('new', 'confirmed') THEN
        RAISE EXCEPTION 'Додавати товар можна лише в нове або підтверджене замовлення (зараз %)', v_status;
    END IF;

    SELECT unit_price INTO v_price FROM products WHERE product_id = p_product_id AND NOT is_deleted;
    IF v_price IS NULL THEN
        RAISE EXCEPTION 'Товар % недоступний', p_product_id;
    END IF;

    IF fn_available_qty(p_product_id, v_wh) < p_quantity THEN
        RAISE EXCEPTION 'Недостатньо товару %: доступно %, потрібно %',
            p_product_id, fn_available_qty(p_product_id, v_wh), p_quantity;
    END IF;

    SELECT discount_pct INTO v_discount
    FROM sales_order_items
    WHERE so_id = p_so_id AND product_id = p_product_id;

    IF FOUND THEN
        IF v_discount <> COALESCE(p_discount_pct, 0) THEN
            RAISE EXCEPTION 'Товар % уже є в замовленні зі знижкою % %%, а вказано % %%',
                p_product_id, v_discount, COALESCE(p_discount_pct, 0);
        END IF;
        UPDATE sales_order_items
        SET quantity = quantity + p_quantity
        WHERE so_id = p_so_id AND product_id = p_product_id;
    ELSE
        INSERT INTO sales_order_items(so_id, product_id, quantity, unit_price, discount_pct)
        VALUES (p_so_id, p_product_id, p_quantity, v_price, COALESCE(p_discount_pct, 0));
    END IF;

    UPDATE inventory
    SET qty_reserved = qty_reserved + p_quantity
    WHERE warehouse_id = v_wh AND product_id = p_product_id;
END $$;

-- 18. Скасування sales_orders до відвантаження зі зняттям резерву в inventory
CREATE OR REPLACE PROCEDURE sp_so_cancel(p_so_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_wh INT;
    v_status so_status;
BEGIN
    SELECT warehouse_id, status INTO v_wh, v_status FROM sales_orders WHERE so_id = p_so_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Замовлення клієнта % не знайдено', p_so_id;
    END IF;
    IF v_status NOT IN ('new', 'confirmed', 'picking') THEN
        RAISE EXCEPTION 'Скасувати можна лише невідвантажене замовлення (зараз %)', v_status;
    END IF;

    UPDATE inventory i
    SET qty_reserved = i.qty_reserved - soi.quantity
    FROM sales_order_items soi
    WHERE soi.so_id = p_so_id
      AND i.warehouse_id = v_wh AND i.product_id = soi.product_id;

    UPDATE sales_orders SET status = 'cancelled' WHERE so_id = p_so_id;
END $$;

-- 19. Списання товару через inventory_movements і створення запису в shipments
CREATE OR REPLACE PROCEDURE sp_shipment_create(
    p_so_id INT, p_carrier_id INT, p_tracking VARCHAR, p_cost NUMERIC DEFAULT 0,
    INOUT p_shipment_id INT DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_wh INT;
    v_status so_status;
    r RECORD;
BEGIN
    SELECT warehouse_id, status INTO v_wh, v_status FROM sales_orders WHERE so_id = p_so_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Замовлення клієнта % не знайдено', p_so_id;
    END IF;
    IF v_status NOT IN ('new', 'confirmed', 'picking') THEN
        RAISE EXCEPTION 'Замовлення % уже відвантажене або скасоване (%)', p_so_id, v_status;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM sales_order_items WHERE so_id = p_so_id) THEN
        RAISE EXCEPTION 'Не можна відвантажити порожнє замовлення';
    END IF;
    IF EXISTS (SELECT 1 FROM carriers WHERE carrier_id = p_carrier_id AND is_deleted) THEN
        RAISE EXCEPTION 'Перевізник % видалений', p_carrier_id;
    END IF;

    FOR r IN SELECT product_id, quantity FROM sales_order_items WHERE so_id = p_so_id LOOP
        UPDATE inventory
        SET qty_reserved = qty_reserved - r.quantity
        WHERE warehouse_id = v_wh AND product_id = r.product_id;

        INSERT INTO inventory_movements(warehouse_id, product_id, movement_type, quantity, so_id, created_by)
        VALUES (v_wh, r.product_id, 'issue', -r.quantity, p_so_id, fn_current_app_user());
    END LOOP;

    INSERT INTO shipments(so_id, carrier_id, tracking_number, status, shipped_at, shipping_cost, created_by)
    VALUES (p_so_id, p_carrier_id, p_tracking, 'in_transit', now(), p_cost, fn_current_app_user())
    RETURNING shipment_id INTO p_shipment_id;

    UPDATE sales_orders SET status = 'shipped' WHERE so_id = p_so_id;
END $$;

-- 20. Ручне коригування залишку через inventory_movements
CREATE OR REPLACE PROCEDURE sp_inventory_adjust(
    p_warehouse_id INT, p_product_id INT, p_quantity INT, p_note VARCHAR)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO inventory_movements(warehouse_id, product_id, movement_type, quantity, note, created_by)
    VALUES (p_warehouse_id, p_product_id, 'adjustment', p_quantity, p_note, fn_current_app_user());
END $$;

-- 21. Оновлення mv_monthly_purchases (CONCURRENTLY - лише після першого заповнення)
CREATE OR REPLACE PROCEDURE sp_refresh_reports()
LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT ispopulated FROM pg_matviews
        WHERE schemaname = 'scm' AND matviewname = 'mv_monthly_purchases') THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_monthly_purchases;
    ELSE
        REFRESH MATERIALIZED VIEW mv_monthly_purchases;
    END IF;
END $$;

-- 22. Soft delete у customers, якщо немає незакритих sales_orders
CREATE OR REPLACE PROCEDURE sp_customer_soft_delete(p_customer_id INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM sales_orders
               WHERE customer_id = p_customer_id
                 AND status IN ('new', 'confirmed', 'picking')) THEN
        RAISE EXCEPTION 'У клієнта % є невідвантажені замовлення', p_customer_id;
    END IF;

    UPDATE customers
    SET is_deleted = TRUE, deleted_at = now(), deleted_by = fn_current_app_user()
    WHERE customer_id = p_customer_id AND NOT is_deleted;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Активного клієнта % не знайдено', p_customer_id;
    END IF;
END $$;

-- 23. Відновлення видаленого запису customers
CREATE OR REPLACE PROCEDURE sp_customer_restore(p_customer_id INT)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE customers
    SET is_deleted = FALSE, deleted_at = NULL, deleted_by = NULL
    WHERE customer_id = p_customer_id AND is_deleted;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Видаленого клієнта % не знайдено', p_customer_id;
    END IF;
END $$;

-- 24. Soft delete у warehouses, якщо склад порожній і на нього немає незакритих замовлень
CREATE OR REPLACE PROCEDURE sp_warehouse_soft_delete(p_warehouse_id INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM inventory WHERE warehouse_id = p_warehouse_id AND qty_on_hand > 0) THEN
        RAISE EXCEPTION 'На складі % є товар, спершу перемістіть або спишіть залишки', p_warehouse_id;
    END IF;
    IF EXISTS (SELECT 1 FROM purchase_orders
               WHERE warehouse_id = p_warehouse_id
                 AND status IN ('draft', 'approved', 'sent', 'partially_received')) THEN
        RAISE EXCEPTION 'На склад % очікуються незакриті замовлення постачальникам', p_warehouse_id;
    END IF;
    IF EXISTS (SELECT 1 FROM sales_orders
               WHERE warehouse_id = p_warehouse_id
                 AND status IN ('new', 'confirmed', 'picking')) THEN
        RAISE EXCEPTION 'Зі складу % ще не відвантажені замовлення клієнтів', p_warehouse_id;
    END IF;

    UPDATE warehouses
    SET is_deleted = TRUE, deleted_at = now(), deleted_by = fn_current_app_user()
    WHERE warehouse_id = p_warehouse_id AND NOT is_deleted;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Активного складу % не знайдено', p_warehouse_id;
    END IF;
END $$;

-- 25. Відновлення видаленого запису warehouses (code не має збігатися з активним складом)
CREATE OR REPLACE PROCEDURE sp_warehouse_restore(p_warehouse_id INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM warehouses a
               JOIN warehouses d ON d.code = a.code
               WHERE d.warehouse_id = p_warehouse_id AND a.warehouse_id <> p_warehouse_id AND NOT a.is_deleted) THEN
        RAISE EXCEPTION 'Активний склад з таким кодом уже існує';
    END IF;

    UPDATE warehouses
    SET is_deleted = FALSE, deleted_at = NULL, deleted_by = NULL
    WHERE warehouse_id = p_warehouse_id AND is_deleted;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Видаленого складу % не знайдено', p_warehouse_id;
    END IF;
END $$;

-- 26. Soft delete у carriers, якщо в перевізника немає відвантажень у дорозі
CREATE OR REPLACE PROCEDURE sp_carrier_soft_delete(p_carrier_id INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM shipments
               WHERE carrier_id = p_carrier_id AND status IN ('planned', 'in_transit')) THEN
        RAISE EXCEPTION 'У перевізника % є відвантаження в дорозі', p_carrier_id;
    END IF;

    UPDATE carriers
    SET is_deleted = TRUE, deleted_at = now(), deleted_by = fn_current_app_user()
    WHERE carrier_id = p_carrier_id AND NOT is_deleted;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Активного перевізника % не знайдено', p_carrier_id;
    END IF;
END $$;

-- 27. Відновлення видаленого запису carriers
CREATE OR REPLACE PROCEDURE sp_carrier_restore(p_carrier_id INT)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE carriers
    SET is_deleted = FALSE, deleted_at = NULL, deleted_by = NULL
    WHERE carrier_id = p_carrier_id AND is_deleted;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Видаленого перевізника % не знайдено', p_carrier_id;
    END IF;
END $$;

-- 28. Зміна статусу sales_orders: new -> confirmed -> picking
CREATE OR REPLACE PROCEDURE sp_so_set_status(p_so_id INT, p_status so_status)
LANGUAGE plpgsql AS $$
DECLARE
    v_old so_status;
BEGIN
    SELECT status INTO v_old FROM sales_orders WHERE so_id = p_so_id FOR UPDATE;
    IF v_old IS NULL THEN
        RAISE EXCEPTION 'Замовлення клієнта % не знайдено', p_so_id;
    END IF;

    IF NOT ((v_old = 'new' AND p_status = 'confirmed')
         OR (v_old = 'confirmed' AND p_status = 'picking')) THEN
        RAISE EXCEPTION 'Недопустимий перехід статусу % -> %', v_old, p_status
            USING HINT = 'shipped, delivered і cancelled ставляться через відвантаження або скасування';
    END IF;
    IF p_status = 'confirmed' AND NOT EXISTS (SELECT 1 FROM sales_order_items WHERE so_id = p_so_id) THEN
        RAISE EXCEPTION 'Не можна підтвердити порожнє замовлення';
    END IF;

    UPDATE sales_orders SET status = p_status WHERE so_id = p_so_id;
END $$;

-- 29. Зміна статусу shipments: planned -> in_transit -> delivered / lost / returned
CREATE OR REPLACE PROCEDURE sp_shipment_set_status(p_shipment_id INT, p_status shipment_status)
LANGUAGE plpgsql AS $$
DECLARE
    v_sh shipments%ROWTYPE;
    v_so sales_orders%ROWTYPE;
BEGIN
    SELECT * INTO v_sh FROM shipments WHERE shipment_id = p_shipment_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Відвантаження % не знайдено', p_shipment_id;
    END IF;

    IF NOT ((v_sh.status = 'planned' AND p_status = 'in_transit')
         OR (v_sh.status = 'in_transit' AND p_status IN ('delivered', 'lost', 'returned'))
         OR (v_sh.status = 'lost' AND p_status = 'returned')) THEN
        RAISE EXCEPTION 'Недопустимий перехід статусу відвантаження % -> %', v_sh.status, p_status;
    END IF;

    UPDATE shipments
    SET status = p_status,
        shipped_at = CASE WHEN p_status = 'in_transit' THEN now() ELSE shipped_at END,
        delivered_at = CASE WHEN p_status = 'delivered' THEN now() ELSE delivered_at END
    WHERE shipment_id = p_shipment_id;

    SELECT * INTO v_so FROM sales_orders WHERE so_id = v_sh.so_id FOR UPDATE;

    IF p_status = 'delivered' THEN
        UPDATE sales_orders SET status = 'delivered' WHERE so_id = v_so.so_id;
    ELSIF p_status = 'returned' THEN
        INSERT INTO inventory_movements(warehouse_id, product_id, movement_type, quantity, note, created_by)
        SELECT v_so.warehouse_id, soi.product_id, 'adjustment', soi.quantity,
               format('Повернення відвантаження %s за замовленням %s',
                      COALESCE(v_sh.tracking_number, v_sh.shipment_id::text), v_so.so_number),
               fn_current_app_user()
        FROM sales_order_items soi
        WHERE soi.so_id = v_so.so_id;

        -- товар уже на складі без резерву, тож повторно відвантажити замовлення не можна
        UPDATE sales_orders SET status = 'cancelled' WHERE so_id = v_so.so_id;
    END IF;
END $$;

-- Фіксований search_path для всіх функцій і процедур схеми scm,
-- інакше вони залежать від search_path сесії, з якої їх викликали
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT p.oid::regprocedure AS sig, p.prokind
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'scm'
    LOOP
        EXECUTE format('ALTER %s %s SET search_path = scm, public',
                       CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END, r.sig);
    END LOOP;
END $$;
