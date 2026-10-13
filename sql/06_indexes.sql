SET search_path TO scm, public;

-- 1. Унікальні з фільтром: tax_code, sku і code унікальні лише серед невидалених записів
CREATE UNIQUE INDEX ux_suppliers_tax_code_active ON suppliers(tax_code) WHERE NOT is_deleted;
CREATE UNIQUE INDEX ux_products_sku_active ON products(sku) WHERE NOT is_deleted;
CREATE UNIQUE INDEX ux_warehouses_code_active ON warehouses(code) WHERE NOT is_deleted;
-- не більше одного основного контакту на постачальника (тригер лише знімає позначку зі старого)
CREATE UNIQUE INDEX ux_supplier_contacts_primary ON supplier_contacts(supplier_id) WHERE is_primary;

-- 2. Складені: замовлення постачальника або клієнта за датою
CREATE INDEX ix_po_supplier_date ON purchase_orders(supplier_id, order_date DESC);
CREATE INDEX ix_so_customer_date ON sales_orders(customer_id, order_date DESC);

-- 3. З фільтром: лише незакриті purchase_orders
CREATE INDEX ix_po_open_status ON purchase_orders(status, expected_date)
    WHERE status IN ('draft', 'approved', 'sent', 'partially_received');

-- 4. Покриваючий: залишки з inventory без звернення до самої таблиці
CREATE INDEX ix_inventory_product_cover ON inventory(product_id) INCLUDE (qty_on_hand, qty_reserved);

-- 5. На значеннях функції: пошук email без урахування регістру
CREATE INDEX ix_customers_email_lower ON customers(lower(email));
CREATE INDEX ix_suppliers_email_lower ON suppliers(lower(email));

-- 6. На обчислюваному стовпці line_total
CREATE INDEX ix_po_items_line_total ON purchase_order_items(line_total DESC);

-- 7. Повнотекстовий: пошук по назві й опису products
CREATE INDEX gx_products_search ON products USING gin (search_vector);

-- 8. Доменний: пошук products за частиною назви (ILIKE '%...%')
CREATE INDEX gx_products_name_trgm ON products USING gin (name gin_trgm_ops);

-- 9. Розділені індекси на секціонованій audit_log, зокрема JSON-індекс
CREATE INDEX gx_audit_log_new_data ON audit_log USING gin (new_data jsonb_path_ops);
CREATE INDEX ix_audit_log_record ON audit_log(table_name, record_id);

-- 10. Просторовий: пошук найближчих warehouses
CREATE INDEX sx_warehouses_location ON warehouses USING gist (location);

-- 11. Нещільний (BRIN): inventory_movements за датою
CREATE INDEX bx_inventory_movements_created ON inventory_movements USING brin (created_at);

-- 12. Хеш: точний пошук у supplier_products за supplier_sku
CREATE INDEX hx_supplier_products_supplier_sku ON supplier_products USING hash (supplier_sku);

-- 13. Прості на зовнішніх ключах
CREATE INDEX ix_cities_country ON cities(country_code);
CREATE INDEX ix_suppliers_city ON suppliers(city_id);
CREATE INDEX ix_customers_city ON customers(city_id);
CREATE INDEX ix_warehouses_city ON warehouses(city_id);
CREATE INDEX ix_products_category ON products(category_id);
CREATE INDEX ix_product_attr_value ON product_attributes(attr_name, attr_value);
CREATE INDEX ix_supplier_products_prod ON supplier_products(product_id);
CREATE INDEX ix_po_items_product ON purchase_order_items(product_id);
CREATE INDEX ix_so_items_product ON sales_order_items(product_id);
CREATE INDEX ix_shipments_so ON shipments(so_id);
CREATE INDEX ix_supplier_contacts_supp ON supplier_contacts(supplier_id);
CREATE INDEX ix_movements_po ON inventory_movements(po_id) WHERE po_id IS NOT NULL;
CREATE INDEX ix_movements_so ON inventory_movements(so_id) WHERE so_id IS NOT NULL;

-- 14. Кластерний для inventory_movements
CREATE INDEX ix_movements_wh_product ON inventory_movements(warehouse_id, product_id, created_at);
ALTER TABLE inventory_movements CLUSTER ON ix_movements_wh_product;
