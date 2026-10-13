SET search_path TO scm, public;

-- 1. Заповнення updated_at і updated_by при кожній вставці чи зміні
CREATE OR REPLACE FUNCTION trg_fn_set_audit_fields()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    NEW.updated_by := COALESCE(fn_current_app_user(), NEW.updated_by);
    RETURN NEW;
END $$;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['suppliers', 'products', 'warehouses', 'customers', 'inventory',
                             'purchase_orders', 'sales_orders', 'shipments']
    LOOP
        EXECUTE format('CREATE TRIGGER trg_%1$s_audit_fields
                        BEFORE INSERT OR UPDATE ON %1$I
                        FOR EACH ROW EXECUTE FUNCTION trg_fn_set_audit_fields()', t);
    END LOOP;
END $$;

-- 2. Запис кожної зміни в audit_log (TG_ARGV[0] - назва колонки первинного ключа)
CREATE OR REPLACE FUNCTION trg_fn_audit_log()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_op TEXT := TG_OP;
    v_old JSONB := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
    v_new JSONB := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
BEGIN
    IF TG_OP = 'UPDATE' AND v_new ? 'is_deleted' THEN
        IF NOT (v_old->>'is_deleted')::bool AND (v_new->>'is_deleted')::bool THEN
            v_op := 'SOFT_DEL';
        ELSIF (v_old->>'is_deleted')::bool AND NOT (v_new->>'is_deleted')::bool THEN
            v_op := 'RESTORE';
        END IF;
    END IF;

    INSERT INTO audit_log(table_name, record_id, operation, old_data, new_data, changed_by)
    VALUES (TG_TABLE_NAME, COALESCE(v_new, v_old)->>TG_ARGV[0], v_op, v_old, v_new, fn_current_app_user());
    RETURN NULL;
END $$;

CREATE TRIGGER trg_suppliers_audit_log AFTER INSERT OR UPDATE OR DELETE ON suppliers
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_log('supplier_id');
CREATE TRIGGER trg_products_audit_log AFTER INSERT OR UPDATE OR DELETE ON products
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_log('product_id');
CREATE TRIGGER trg_customers_audit_log AFTER INSERT OR UPDATE OR DELETE ON customers
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_log('customer_id');
CREATE TRIGGER trg_warehouses_audit_log AFTER INSERT OR UPDATE OR DELETE ON warehouses
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_log('warehouse_id');
CREATE TRIGGER trg_purchase_orders_audit_log AFTER INSERT OR UPDATE OR DELETE ON purchase_orders
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_log('po_id');
CREATE TRIGGER trg_sales_orders_audit_log AFTER INSERT OR UPDATE OR DELETE ON sales_orders
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_log('so_id');
CREATE TRIGGER trg_shipments_audit_log AFTER INSERT OR UPDATE OR DELETE ON shipments
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_log('shipment_id');
-- inventory без журналу: кожна зміна залишку вже є в inventory_movements

-- 3. Заборона DELETE для таблиць із soft delete (обхід: SET LOCAL app.allow_hard_delete = 'on')
CREATE OR REPLACE FUNCTION trg_fn_block_hard_delete()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF COALESCE(current_setting('app.allow_hard_delete', true), 'off') <> 'on' THEN
        RAISE EXCEPTION 'Видаляти записи з % не можна, використовуйте soft delete', TG_TABLE_NAME;
    END IF;
    RETURN OLD;
END $$;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['suppliers', 'products', 'warehouses', 'customers', 'carriers']
    LOOP
        EXECUTE format('CREATE TRIGGER trg_%1$s_block_delete
                        BEFORE DELETE ON %1$I
                        FOR EACH ROW EXECUTE FUNCTION trg_fn_block_hard_delete()', t);
    END LOOP;
END $$;

-- 4. Лише один запис supplier_contacts з is_primary на постачальника
CREATE OR REPLACE FUNCTION trg_fn_single_primary_contact()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE supplier_contacts
    SET is_primary = FALSE
    WHERE supplier_id = NEW.supplier_id
      AND contact_id <> NEW.contact_id
      AND is_primary;
    RETURN NULL;
END $$;

CREATE TRIGGER trg_supplier_contacts_single_primary
AFTER INSERT OR UPDATE OF is_primary ON supplier_contacts
FOR EACH ROW WHEN (NEW.is_primary) EXECUTE FUNCTION trg_fn_single_primary_contact();

-- 5. Заборона циклів у product_categories через parent_category_id
CREATE OR REPLACE FUNCTION trg_fn_category_no_cycle()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.parent_category_id IS NOT NULL AND EXISTS (
        WITH RECURSIVE up AS (
            SELECT category_id, parent_category_id
            FROM product_categories
            WHERE category_id = NEW.parent_category_id
            UNION ALL
            SELECT c.category_id, c.parent_category_id
            FROM product_categories c
            JOIN up ON c.category_id = up.parent_category_id
        )
        SELECT 1 FROM up WHERE category_id = NEW.category_id
    ) THEN
        RAISE EXCEPTION 'Категорія % не може бути підкатегорією %, вийде цикл',
            NEW.category_id, NEW.parent_category_id;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_product_categories_no_cycle
BEFORE INSERT OR UPDATE OF parent_category_id ON product_categories
FOR EACH ROW EXECUTE FUNCTION trg_fn_category_no_cycle();

-- 6. Вставка в inventory_movements одразу змінює залишок у inventory
CREATE OR REPLACE FUNCTION trg_fn_apply_movement()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE inventory
    SET qty_on_hand = qty_on_hand + NEW.quantity
    WHERE warehouse_id = NEW.warehouse_id AND product_id = NEW.product_id;

    IF NOT FOUND THEN
        IF NEW.quantity < 0 THEN
            RAISE EXCEPTION 'Товару % немає на складі %', NEW.product_id, NEW.warehouse_id;
        END IF;
        INSERT INTO inventory(warehouse_id, product_id, qty_on_hand)
        VALUES (NEW.warehouse_id, NEW.product_id, NEW.quantity);
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER trg_inventory_movements_apply
AFTER INSERT ON inventory_movements
FOR EACH ROW EXECUTE FUNCTION trg_fn_apply_movement();

-- 7. purchase_orders не можна створити на видаленого постачальника чи склад і змінити після закриття
CREATE OR REPLACE FUNCTION trg_fn_po_guard()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.supplier_id IS DISTINCT FROM OLD.supplier_id THEN
        IF EXISTS (SELECT 1 FROM suppliers WHERE supplier_id = NEW.supplier_id AND is_deleted) THEN
            RAISE EXCEPTION 'Постачальник % видалений', NEW.supplier_id;
        END IF;
    END IF;

    IF TG_OP = 'INSERT' OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id THEN
        IF EXISTS (SELECT 1 FROM warehouses WHERE warehouse_id = NEW.warehouse_id AND is_deleted) THEN
            RAISE EXCEPTION 'Склад % видалений', NEW.warehouse_id;
        END IF;
    END IF;

    IF TG_OP = 'UPDATE' AND OLD.status IN ('received', 'cancelled')
       AND (NEW.status <> OLD.status OR NEW.supplier_id <> OLD.supplier_id OR NEW.warehouse_id <> OLD.warehouse_id) THEN
        RAISE EXCEPTION 'Замовлення % уже закрите (%)', OLD.po_number, OLD.status;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_purchase_orders_guard
BEFORE INSERT OR UPDATE ON purchase_orders
FOR EACH ROW EXECUTE FUNCTION trg_fn_po_guard();

-- 8. purchase_order_items змінюються лише поки замовлення в статусі draft (крім received_qty)
CREATE OR REPLACE FUNCTION trg_fn_po_items_guard()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_status po_status;
BEGIN
    SELECT status INTO v_status FROM purchase_orders WHERE po_id = COALESCE(NEW.po_id, OLD.po_id);

    IF TG_OP = 'UPDATE' AND NEW.quantity = OLD.quantity AND NEW.unit_price = OLD.unit_price
       AND NEW.product_id = OLD.product_id THEN
        RETURN NEW;
    END IF;

    IF v_status <> 'draft' THEN
        RAISE EXCEPTION 'Рядки замовлення можна змінювати лише в чернетці (зараз %)', v_status;
    END IF;

    IF TG_OP <> 'DELETE' AND EXISTS (SELECT 1 FROM products WHERE product_id = NEW.product_id AND is_deleted) THEN
        RAISE EXCEPTION 'Товар % видалений', NEW.product_id;
    END IF;
    RETURN COALESCE(NEW, OLD);
END $$;

CREATE TRIGGER trg_po_items_guard
BEFORE INSERT OR UPDATE OR DELETE ON purchase_order_items
FOR EACH ROW EXECUTE FUNCTION trg_fn_po_items_guard();

-- 9. Перевірка tax_code у suppliers і customers, якщо місто в Україні
CREATE OR REPLACE FUNCTION trg_fn_check_tax_code()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.tax_code IS NOT NULL
       AND (SELECT country_code FROM cities WHERE city_id = NEW.city_id) = 'UA'
       AND NOT fn_ua_tax_code_is_valid(NEW.tax_code) THEN
        RAISE EXCEPTION 'Некоректний український податковий код: %', NEW.tax_code
            USING HINT = 'Очікується 8 цифр ЄДРПОУ або 10 цифр РНОКПП з правильною контрольною цифрою';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_suppliers_check_tax_code
BEFORE INSERT OR UPDATE OF tax_code, city_id ON suppliers
FOR EACH ROW EXECUTE FUNCTION trg_fn_check_tax_code();

CREATE TRIGGER trg_customers_check_tax_code
BEFORE INSERT OR UPDATE OF tax_code, city_id ON customers
FOR EACH ROW EXECUTE FUNCTION trg_fn_check_tax_code();