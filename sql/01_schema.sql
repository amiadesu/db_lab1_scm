DROP SCHEMA IF EXISTS scm CASCADE;
CREATE SCHEMA scm; -- scm - Supply Chain Management
SET search_path TO scm, public;

CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public;
CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA public;

CREATE TYPE po_status AS ENUM ('draft', 'approved', 'sent', 'partially_received', 'received', 'cancelled');
CREATE TYPE so_status AS ENUM ('new', 'confirmed', 'picking', 'shipped', 'delivered', 'cancelled');
CREATE TYPE shipment_status AS ENUM ('planned', 'in_transit', 'delivered', 'lost', 'returned');
CREATE TYPE movement_type AS ENUM ('receipt', 'issue', 'adjustment');

-- Перевірка IBAN за ISO 13616 (mod 97)
CREATE FUNCTION fn_iban_is_valid(p_iban TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v TEXT := upper(replace(p_iban, ' ', ''));
    rem INT := 0;
    ch TEXT;
BEGIN
    IF v !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$' THEN
        RETURN FALSE;
    END IF;
    v := substr(v, 5) || substr(v, 1, 4);
    FOR i IN 1 .. length(v) LOOP
        ch := substr(v, i, 1);
        IF ch ~ '[0-9]' THEN
            rem := (rem * 10 + ch::INT) % 97;
        ELSE
            rem := (rem * 100 + ascii(ch) - 55) % 97;
        END IF;
    END LOOP;
    RETURN rem = 1;
END $$;

-- Контрольна цифра ЄДРПОУ (8 цифр) або РНОКПП (10 цифр)
CREATE FUNCTION fn_ua_tax_code_is_valid(p_code TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    w INT[];
    s INT := 0;
BEGIN
    IF p_code ~ '^[0-9]{8}$' THEN
        w := CASE WHEN p_code::INT BETWEEN 30000000 AND 60000000
                  THEN ARRAY[7, 1, 2, 3, 4, 5, 6]
                  ELSE ARRAY[1, 2, 3, 4, 5, 6, 7] END;
        FOR i IN 1 .. 7 LOOP
            s := s + substr(p_code, i, 1)::INT * w[i];
        END LOOP;
        s := s % 11;
        IF s = 10 THEN
            s := 0;
            FOR i IN 1 .. 7 LOOP
                s := s + substr(p_code, i, 1)::INT * (w[i] + 2);
            END LOOP;
            s := s % 11 % 10;
        END IF;
        RETURN s = substr(p_code, 8, 1)::INT;
    ELSIF p_code ~ '^[0-9]{10}$' THEN
        w := ARRAY[-1, 5, 7, 9, 4, 6, 10, 5, 7];
        FOR i IN 1 .. 9 LOOP
            s := s + substr(p_code, i, 1)::INT * w[i];
        END LOOP;
        RETURN s % 11 % 10 = substr(p_code, 10, 1)::INT;
    END IF;
    RETURN FALSE;
END $$;

CREATE DOMAIN country_code AS CHAR(2) CHECK (VALUE ~ '^[A-Z]{2}$');
CREATE DOMAIN currency_code AS CHAR(3) CHECK (VALUE ~ '^[A-Z]{3}$');
CREATE DOMAIN email_address AS VARCHAR(150) CHECK (VALUE ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$');
CREATE DOMAIN phone_number AS VARCHAR(30) CHECK (VALUE ~ '^\+?[0-9]{7,15}$');
CREATE DOMAIN iban_code AS VARCHAR(34) CHECK (fn_iban_is_valid(VALUE) AND VALUE = upper(VALUE) AND VALUE !~ ' ');
CREATE DOMAIN swift_code AS VARCHAR(11) CHECK (VALUE ~ '^[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?$');
CREATE DOMAIN item_code AS VARCHAR(40) CHECK (VALUE ~ '^[A-Z0-9]+(-[A-Z0-9]+)*$');


-- 1. Ролі
CREATE TABLE roles (
    role_id SERIAL PRIMARY KEY,
    name VARCHAR(50) NOT NULL UNIQUE,
    description VARCHAR(255)
);

-- 2. Користувачі
CREATE TABLE users (
    user_id SERIAL PRIMARY KEY,
    role_id INT NOT NULL REFERENCES roles(role_id),
    login VARCHAR(50) NOT NULL UNIQUE CHECK (login ~ '^[a-z][a-z0-9_.]{2,49}$'),
    last_name VARCHAR(60) NOT NULL,
    first_name VARCHAR(60) NOT NULL,
    middle_name VARCHAR(60),
    email email_address NOT NULL UNIQUE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. Країни
CREATE TABLE countries (
    country_code country_code PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE
);

-- 4. Міста
CREATE TABLE cities (
    city_id SERIAL PRIMARY KEY,
    country_code country_code NOT NULL REFERENCES countries(country_code),
    name VARCHAR(100) NOT NULL,
    region VARCHAR(100),
    CONSTRAINT uq_cities UNIQUE NULLS NOT DISTINCT (country_code, region, name)
);

-- 5. Постачальники
CREATE TABLE suppliers (
    supplier_id SERIAL PRIMARY KEY,
    name VARCHAR(200) NOT NULL,
    tax_code VARCHAR(20) NOT NULL CHECK (tax_code ~ '^[A-Z0-9]{5,20}$'),
    city_id INT NOT NULL REFERENCES cities(city_id),
    street VARCHAR(150),
    building VARCHAR(20),
    postal_code VARCHAR(12) CHECK (postal_code ~ '^[A-Z0-9][A-Z0-9 -]{2,10}$'),
    phone phone_number,
    email email_address,
    rating NUMERIC(3,2) CHECK (rating BETWEEN 0 AND 5),
    lead_time_days INT NOT NULL DEFAULT 7 CHECK (lead_time_days >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by INT REFERENCES users(user_id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by INT REFERENCES users(user_id),
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMPTZ,
    deleted_by INT REFERENCES users(user_id),
    CONSTRAINT chk_suppliers_soft_delete
        CHECK ((is_deleted AND deleted_at IS NOT NULL) OR (NOT is_deleted AND deleted_at IS NULL))
);

-- 6. Банківські реквізити постачальника
CREATE TABLE supplier_bank_details (
    supplier_id INT PRIMARY KEY REFERENCES suppliers(supplier_id),
    bank_name VARCHAR(150) NOT NULL,
    iban iban_code NOT NULL UNIQUE,
    swift_code swift_code,
    currency currency_code NOT NULL DEFAULT 'UAH',
    CONSTRAINT chk_bank_country CHECK (swift_code IS NULL OR substr(swift_code, 5, 2) = substr(iban, 1, 2))
);

-- 7. Контактні особи постачальника
CREATE TABLE supplier_contacts (
    contact_id SERIAL PRIMARY KEY,
    supplier_id INT NOT NULL REFERENCES suppliers(supplier_id),
    last_name VARCHAR(60) NOT NULL,
    first_name VARCHAR(60) NOT NULL,
    middle_name VARCHAR(60),
    position VARCHAR(100),
    phone phone_number,
    email email_address,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE
);

-- 8. Одиниці виміру
CREATE TABLE units_of_measure (
    uom_id SERIAL PRIMARY KEY,
    code VARCHAR(10) NOT NULL UNIQUE CHECK (code ~ '^[a-z0-9]{1,10}$'),
    name VARCHAR(50) NOT NULL
);

-- 9. Категорії товарів
CREATE TABLE product_categories (
    category_id SERIAL PRIMARY KEY,
    parent_category_id INT REFERENCES product_categories(category_id),
    name VARCHAR(100) NOT NULL UNIQUE,
    CONSTRAINT chk_category_not_self CHECK (parent_category_id <> category_id)
);

-- 10. Товари
CREATE TABLE products (
    product_id SERIAL PRIMARY KEY,
    sku item_code NOT NULL,
    name VARCHAR(200) NOT NULL,
    description TEXT,
    category_id INT NOT NULL REFERENCES product_categories(category_id),
    uom_id INT NOT NULL REFERENCES units_of_measure(uom_id),
    unit_price NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
    weight_kg NUMERIC(10,3) CHECK (weight_kg >= 0),
    reorder_level INT NOT NULL DEFAULT 0 CHECK (reorder_level >= 0),
    search_vector TSVECTOR GENERATED ALWAYS AS
        (to_tsvector('simple', coalesce(name, '') || ' ' || coalesce(description, ''))) STORED,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by INT REFERENCES users(user_id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by INT REFERENCES users(user_id),
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMPTZ,
    deleted_by INT REFERENCES users(user_id),
    CONSTRAINT chk_products_soft_delete
        CHECK ((is_deleted AND deleted_at IS NOT NULL) OR (NOT is_deleted AND deleted_at IS NULL))
);

-- 11. Характеристики товару
CREATE TABLE product_attributes (
    product_id INT NOT NULL REFERENCES products(product_id),
    attr_name VARCHAR(50) NOT NULL CHECK (attr_name ~ '^[a-z][a-z0-9_]*$'),
    attr_value VARCHAR(200) NOT NULL,
    PRIMARY KEY (product_id, attr_name)
);

-- 12. Прайс постачальника
CREATE TABLE supplier_products (
    supplier_id INT NOT NULL REFERENCES suppliers(supplier_id),
    product_id INT NOT NULL REFERENCES products(product_id),
    supplier_sku VARCHAR(40),
    purchase_price NUMERIC(12,2) NOT NULL CHECK (purchase_price >= 0),
    min_order_qty INT NOT NULL DEFAULT 1 CHECK (min_order_qty > 0),
    PRIMARY KEY (supplier_id, product_id)
);

-- 13. Склади
CREATE TABLE warehouses (
    warehouse_id SERIAL PRIMARY KEY,
    code item_code NOT NULL,
    name VARCHAR(150) NOT NULL,
    city_id INT NOT NULL REFERENCES cities(city_id),
    street VARCHAR(150),
    building VARCHAR(20),
    location POINT CHECK (location[0] BETWEEN -180 AND 180 AND location[1] BETWEEN -90 AND 90), -- (довгота, широта)
    capacity_m3 NUMERIC(12,2) CHECK (capacity_m3 > 0),
    manager_id INT REFERENCES users(user_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by INT REFERENCES users(user_id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by INT REFERENCES users(user_id),
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMPTZ,
    deleted_by INT REFERENCES users(user_id),
    CONSTRAINT chk_warehouses_soft_delete
        CHECK ((is_deleted AND deleted_at IS NOT NULL) OR (NOT is_deleted AND deleted_at IS NULL))
);

-- 14. Залишки на складах
CREATE TABLE inventory (
    warehouse_id INT NOT NULL REFERENCES warehouses(warehouse_id),
    product_id INT NOT NULL REFERENCES products(product_id),
    qty_on_hand INT NOT NULL DEFAULT 0 CHECK (qty_on_hand >= 0),
    qty_reserved INT NOT NULL DEFAULT 0 CHECK (qty_reserved >= 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by INT REFERENCES users(user_id),
    PRIMARY KEY (warehouse_id, product_id),
    CONSTRAINT chk_inventory_reserved CHECK (qty_reserved <= qty_on_hand)
);

-- 15. Клієнти
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    name VARCHAR(200) NOT NULL,
    tax_code VARCHAR(20) CHECK (tax_code ~ '^[A-Z0-9]{5,20}$'),
    city_id INT NOT NULL REFERENCES cities(city_id),
    street VARCHAR(150),
    building VARCHAR(20),
    email email_address,
    phone phone_number,
    credit_limit NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (credit_limit >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by INT REFERENCES users(user_id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by INT REFERENCES users(user_id),
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMPTZ,
    deleted_by INT REFERENCES users(user_id),
    CONSTRAINT chk_customers_soft_delete
        CHECK ((is_deleted AND deleted_at IS NOT NULL) OR (NOT is_deleted AND deleted_at IS NULL))
);

-- 16. Замовлення у постачальника
CREATE TABLE purchase_orders (
    po_id SERIAL PRIMARY KEY,
    po_number VARCHAR(20) NOT NULL UNIQUE, -- PO-РРРР-NNNNNN
    supplier_id INT NOT NULL REFERENCES suppliers(supplier_id),
    warehouse_id INT NOT NULL REFERENCES warehouses(warehouse_id),
    status po_status NOT NULL DEFAULT 'draft',
    order_date DATE NOT NULL DEFAULT CURRENT_DATE,
    expected_date DATE,
    currency currency_code NOT NULL DEFAULT 'UAH',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by INT REFERENCES users(user_id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by INT REFERENCES users(user_id),
    CONSTRAINT chk_po_number CHECK (CASE WHEN po_number ~ '^PO-[0-9]{4}-[0-9]{6}$'
                                         THEN substr(po_number, 4, 4)::INT = extract(YEAR FROM order_date)
                                         ELSE FALSE END),
    CONSTRAINT chk_po_dates CHECK (expected_date IS NULL OR expected_date >= order_date)
);

-- 17. Рядки замовлення у постачальника
CREATE TABLE purchase_order_items (
    po_item_id SERIAL PRIMARY KEY,
    po_id INT NOT NULL REFERENCES purchase_orders(po_id) ON DELETE CASCADE,
    product_id INT NOT NULL REFERENCES products(product_id),
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0), -- ціна на момент замовлення
    received_qty INT NOT NULL DEFAULT 0 CHECK (received_qty >= 0),
    line_total NUMERIC(14,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    CONSTRAINT uq_po_item UNIQUE (po_id, product_id),
    CONSTRAINT chk_po_received CHECK (received_qty <= quantity)
);

-- 18. Замовлення клієнта
CREATE TABLE sales_orders (
    so_id SERIAL PRIMARY KEY,
    so_number VARCHAR(20) NOT NULL UNIQUE, -- SO-РРРР-NNNNNN
    customer_id INT NOT NULL REFERENCES customers(customer_id),
    warehouse_id INT NOT NULL REFERENCES warehouses(warehouse_id),
    status so_status NOT NULL DEFAULT 'new',
    order_date DATE NOT NULL DEFAULT CURRENT_DATE,
    required_date DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by INT REFERENCES users(user_id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by INT REFERENCES users(user_id),
    CONSTRAINT chk_so_number CHECK (CASE WHEN so_number ~ '^SO-[0-9]{4}-[0-9]{6}$'
                                         THEN substr(so_number, 4, 4)::INT = extract(YEAR FROM order_date)
                                         ELSE FALSE END),
    CONSTRAINT chk_so_dates CHECK (required_date IS NULL OR required_date >= order_date)
);

-- 19. Рядки замовлення клієнта
CREATE TABLE sales_order_items (
    so_item_id SERIAL PRIMARY KEY,
    so_id INT NOT NULL REFERENCES sales_orders(so_id) ON DELETE CASCADE,
    product_id INT NOT NULL REFERENCES products(product_id),
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
    discount_pct NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 100),
    line_total NUMERIC(14,2) GENERATED ALWAYS AS (round(quantity * unit_price * (1 - discount_pct / 100), 2)) STORED,
    CONSTRAINT uq_so_item UNIQUE (so_id, product_id)
);

-- 20. Рух товарів
CREATE TABLE inventory_movements (
    movement_id BIGSERIAL PRIMARY KEY,
    warehouse_id INT NOT NULL REFERENCES warehouses(warehouse_id),
    product_id INT NOT NULL REFERENCES products(product_id),
    movement_type movement_type NOT NULL,
    quantity INT NOT NULL CHECK (quantity <> 0),
    po_id INT REFERENCES purchase_orders(po_id),
    so_id INT REFERENCES sales_orders(so_id),
    note VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by INT REFERENCES users(user_id),
    CONSTRAINT chk_movement_source CHECK (
        (movement_type = 'receipt' AND po_id IS NOT NULL AND so_id IS NULL AND quantity > 0) OR
        (movement_type = 'issue' AND so_id IS NOT NULL AND po_id IS NULL AND quantity < 0) OR
        (movement_type = 'adjustment' AND po_id IS NULL AND so_id IS NULL AND note IS NOT NULL))
);

-- 21. Перевізники
CREATE TABLE carriers (
    carrier_id SERIAL PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    transport_mode VARCHAR(20) NOT NULL CHECK (transport_mode IN ('road', 'rail', 'sea', 'air', 'multimodal')),
    phone phone_number,
    email email_address,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMPTZ,
    deleted_by INT REFERENCES users(user_id),
    CONSTRAINT chk_carriers_soft_delete
        CHECK ((is_deleted AND deleted_at IS NOT NULL) OR (NOT is_deleted AND deleted_at IS NULL))
);

-- 22. Договори з перевізниками
CREATE TABLE carrier_contracts (
    contract_id SERIAL PRIMARY KEY,
    carrier_id INT NOT NULL REFERENCES carriers(carrier_id),
    valid_period DATERANGE NOT NULL CHECK (NOT isempty(valid_period) AND NOT lower_inf(valid_period)),
    rate_per_kg NUMERIC(10,2) NOT NULL CHECK (rate_per_kg >= 0),
    CONSTRAINT ex_carrier_contracts_no_overlap
        EXCLUDE USING gist (carrier_id WITH =, valid_period WITH &&)
);

-- 23. Відвантаження
CREATE TABLE shipments (
    shipment_id SERIAL PRIMARY KEY,
    so_id INT NOT NULL REFERENCES sales_orders(so_id),
    carrier_id INT NOT NULL REFERENCES carriers(carrier_id),
    tracking_number VARCHAR(50) UNIQUE CHECK (tracking_number ~ '^[A-Z0-9]{8,30}$'),
    status shipment_status NOT NULL DEFAULT 'planned',
    shipped_at TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ,
    shipping_cost NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (shipping_cost >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by INT REFERENCES users(user_id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by INT REFERENCES users(user_id),
    CONSTRAINT chk_ship_dates CHECK (delivered_at IS NULL OR shipped_at IS NULL OR delivered_at >= shipped_at),
    CONSTRAINT chk_ship_status CHECK (
        (status = 'planned' AND shipped_at IS NULL AND delivered_at IS NULL) OR
        (status IN ('in_transit', 'lost') AND shipped_at IS NOT NULL AND delivered_at IS NULL) OR
        (status = 'delivered' AND shipped_at IS NOT NULL AND delivered_at IS NOT NULL) OR
        (status = 'returned' AND shipped_at IS NOT NULL))
);

-- 24. Журнал аудиту
CREATE TABLE audit_log (
    audit_id BIGINT GENERATED ALWAYS AS IDENTITY,
    table_name VARCHAR(63) NOT NULL,
    record_id TEXT NOT NULL,
    operation VARCHAR(10) NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE', 'SOFT_DEL', 'RESTORE')),
    old_data JSONB,
    new_data JSONB,
    changed_by INT REFERENCES users(user_id),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (audit_id, changed_at)
) PARTITION BY RANGE (changed_at);

CREATE TABLE audit_log_2026 PARTITION OF audit_log FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE audit_log_2027 PARTITION OF audit_log FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');
CREATE TABLE audit_log_default PARTITION OF audit_log DEFAULT;
