-- Індекси під запити каталогу, аналогічні індексам MongoDB (nosql/migrate.py)
SET search_path TO scm, public;

-- сторінка категорії, відсортована за ціною
CREATE INDEX IF NOT EXISTS ix_products_category_price ON products(category_id, unit_price, product_id);
-- рекурсивний обхід дерева категорій вниз
CREATE INDEX IF NOT EXISTS ix_categories_parent ON product_categories(parent_category_id);
-- фільтр за характеристикою
DROP INDEX IF EXISTS ix_product_attr_value;
CREATE INDEX ix_product_attr_value ON product_attributes(attr_name, attr_value, product_id);
