"""
6 таблиць -> 1 документ:
    products            -> поля документа
    product_attributes  -> attributes {назва: типізоване значення}
    product_categories  -> category {id, name, path, pathIds}
    units_of_measure    -> uom {code, name}
    supplier_products   -> offers[]
    suppliers           -> offers[].supplierName / supplierRating
"""
import re
import time

import psycopg2
from pymongo import ASCENDING, IndexModel, MongoClient

from .config import MONGO_DB, MONGO_URI, PG_DSN

VALIDATOR = {"$jsonSchema": {
    "bsonType": "object",
    "required": ["_id", "sku", "name", "category", "uom", "priceMinor", "attributes", "offers", "isDeleted"],
    "properties": {
        "_id": {"bsonType": "int"},
        "sku": {"bsonType": "string", "pattern": "^[A-Z0-9]+(-[A-Z0-9]+)*$"},
        "name": {"bsonType": "string", "maxLength": 200},
        "category": {"bsonType": "object", "required": ["id", "pathIds"]},
        "priceMinor": {"bsonType": ["int", "long"], "minimum": 0},
        "attributes": {"bsonType": "object",
                       "patternProperties": {"^[a-z][a-z0-9_]*$": {"bsonType": ["string", "int", "double", "bool"]}},
                       "additionalProperties": False},
        "offers": {"bsonType": "array", "maxItems": 50},
        "isDeleted": {"bsonType": "bool"},
    },
}}

INDEXES = [
    IndexModel([("sku", ASCENDING)], 
                name="ux_sku_active", 
                unique=True,
                partialFilterExpression={"isDeleted": False}), # картка за артикулом
    IndexModel([("category.pathIds", ASCENDING), ("priceMinor", ASCENDING), ("_id", ASCENDING)],
                name="ix_path_price"), # сторінка категорії
    IndexModel([("attributes.$**", ASCENDING)], 
                name="wx_attributes"), # фільтр за будь-якою характеристикою
    IndexModel([("offers.supplierId", ASCENDING)], 
                name="ix_offers_supplier"), # оновлення назви постачальника
]

KEEP_AS_STRING = {"version", "size", "model"}

# Робимо дані типізованими
def typed(name: str, value: str):
    if name in KEEP_AS_STRING:
        return value
    if value in ("true", "false"):
        return value == "true"
    if re.fullmatch(r"-?\d{1,15}", value):
        return int(value)
    if re.fullmatch(r"-?\d+\.\d+", value):
        return float(value)
    return value

def minor(x) -> int:
    return int(round(x * 100))

QUERY = """
SELECT p.product_id, p.sku, p.name, p.description, p.category_id, u.code, u.name,
       p.unit_price, p.weight_kg, p.reorder_level, p.created_at, p.updated_at,
       (SELECT json_object_agg(a.attr_name, a.attr_value) FROM scm.product_attributes a
         WHERE a.product_id = p.product_id),
       (SELECT json_agg(json_build_object('supplierId', s.supplier_id, 'supplierName', s.name,
                                          'supplierRating', s.rating, 'supplierSku', sp.supplier_sku,
                                          'purchasePrice', sp.purchase_price, 'minOrderQty', sp.min_order_qty)
                        ORDER BY s.supplier_id)
          FROM scm.supplier_products sp JOIN scm.suppliers s ON s.supplier_id = sp.supplier_id AND NOT s.is_deleted
         WHERE sp.product_id = p.product_id)
FROM scm.products p
JOIN scm.units_of_measure u ON u.uom_id = p.uom_id
WHERE NOT p.is_deleted
ORDER BY p.product_id"""

def category_paths(cur) -> dict:
    cur.execute("SELECT category_id, parent_category_id, name FROM scm.product_categories")
    rows = {cid: (parent, name) for cid, parent, name in cur.fetchall()}
    paths = {}
    for cid in rows:
        ids, c = [], cid
        while c is not None:
            ids.append(c)
            c = rows[c][0]
        ids.reverse()
        paths[cid] = {"id": cid, "name": rows[cid][1], "path": [rows[i][1] for i in ids], "pathIds": ids}
    return paths

def to_document(r, cats) -> dict:
    (pid, sku, name, descr, cat_id, uom_code, uom_name, price, weight, reorder, created, updated, attrs, offers) = r
    return {
        "_id": pid, "sku": sku, "name": name, "description": descr,
        "category": cats[cat_id],
        "uom": {"code": uom_code, "name": uom_name},
        "priceMinor": minor(price), "currency": "UAH",
        "weightKg": float(weight) if weight is not None else None,
        "reorderLevel": reorder,
        "attributes": {k: typed(k, v) for k, v in (attrs or {}).items()},
        "offers": [{"supplierId": o["supplierId"], "supplierName": o["supplierName"],
                    "supplierRating": o["supplierRating"], "supplierSku": o["supplierSku"],
                    "purchasePriceMinor": int(round(o["purchasePrice"] * 100)), "minOrderQty": o["minOrderQty"]}
                   for o in (offers or [])],
        "isDeleted": False, "createdAt": created, "updatedAt": updated,
    }

def migrate():
    t0 = time.perf_counter()
    pg = psycopg2.connect(PG_DSN)
    db = MongoClient(MONGO_URI)[MONGO_DB]
    db.drop_collection("products")
    coll = db.create_collection("products", validator=VALIDATOR)

    with pg.cursor() as c:
        cats = category_paths(c)
    total = 0
    with pg.cursor(name="catalog") as cur:
        cur.itersize = 5000
        cur.execute(QUERY)
        batch = []
        for r in cur:
            batch.append(to_document(r, cats))
            if len(batch) == 5000:
                coll.insert_many(batch, ordered=False)
                total += len(batch)
                batch = []
                if total % 100_000 == 0:
                    print(f"  {total:,} документів ({time.perf_counter() - t0:.0f} с)")
        if batch:
            coll.insert_many(batch, ordered=False)
            total += len(batch)
    coll.create_indexes(INDEXES)

    with pg.cursor() as cur:
        cur.execute("SELECT count(*) FROM scm.products WHERE NOT is_deleted")
        pg_count = cur.fetchone()[0]
    pg.close()
    print(f"MongoDB: {total:,} документів за {time.perf_counter() - t0:.0f} с "
          f"(у PostgreSQL {pg_count:,} активних товарів - {'збігається' if total == pg_count else 'НЕ збігається'})")

if __name__ == "__main__":
    migrate()
