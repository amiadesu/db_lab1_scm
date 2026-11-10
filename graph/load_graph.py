"""
Модель графа:
    (:Category)-[:CHILD_OF]->(:Category)
    (:Product)-[:IN_CATEGORY]->(:Category)
    (:Supplier)-[:SUPPLIES {price, minQty}]->(:Product)
    (:Warehouse)-[:STOCKS {onHand, reserved}]->(:Product)
    (:Customer)-[:PLACED]->(:SalesOrder)-[:CONTAINS {qty, price}]->(:Product)
    (:SalesOrder)-[:SHIPS_FROM]->(:Warehouse)
"""
import argparse

import psycopg2
from neo4j import GraphDatabase

from nosql.config import NEO4J_AUTH, NEO4J_URI, PG_DSN

CONSTRAINTS = [
    "CREATE CONSTRAINT category_id IF NOT EXISTS FOR (c:Category) REQUIRE c.id IS UNIQUE",
    "CREATE CONSTRAINT product_id IF NOT EXISTS FOR (p:Product) REQUIRE p.id IS UNIQUE",
    "CREATE CONSTRAINT product_sku IF NOT EXISTS FOR (p:Product) REQUIRE p.sku IS UNIQUE",
    "CREATE CONSTRAINT supplier_id IF NOT EXISTS FOR (s:Supplier) REQUIRE s.id IS UNIQUE",
    "CREATE CONSTRAINT warehouse_id IF NOT EXISTS FOR (w:Warehouse) REQUIRE w.id IS UNIQUE",
    "CREATE CONSTRAINT customer_id IF NOT EXISTS FOR (c:Customer) REQUIRE c.id IS UNIQUE",
    "CREATE CONSTRAINT order_id IF NOT EXISTS FOR (o:SalesOrder) REQUIRE o.id IS UNIQUE",
    "CREATE INDEX supplier_name IF NOT EXISTS FOR (s:Supplier) ON (s.name)",
]

# (назва кроку, SQL-запит, Cypher-запит)
STEPS = [
    ("категорії",
     "SELECT category_id AS id, parent_category_id AS parent, name FROM scm.product_categories",
     """UNWIND $rows AS r MERGE (c:Category {id: r.id}) SET c.name = r.name
        WITH c, r WHERE r.parent IS NOT NULL
        MERGE (p:Category {id: r.parent}) MERGE (c)-[:CHILD_OF]->(p)"""),
    ("товари",
     """SELECT product_id AS id, sku, name, unit_price::float AS price, category_id AS cat
        FROM scm.products WHERE NOT is_deleted ORDER BY product_id LIMIT %(limit)s""",
     """UNWIND $rows AS r MERGE (p:Product {id: r.id}) SET p.sku = r.sku, p.name = r.name, p.price = r.price
        WITH p, r MATCH (c:Category {id: r.cat}) MERGE (p)-[:IN_CATEGORY]->(c)"""),
    ("постачальники",
     """SELECT s.supplier_id AS id, s.name, ci.country_code AS country, s.rating::float AS rating,
               s.lead_time_days AS lead
        FROM scm.suppliers s JOIN scm.cities ci ON ci.city_id = s.city_id WHERE NOT s.is_deleted""",
     """UNWIND $rows AS r MERGE (s:Supplier {id: r.id})
        SET s.name = r.name, s.country = r.country, s.rating = r.rating, s.leadTimeDays = r.lead"""),
    ("пропозиції постачальників",
     """SELECT supplier_id AS s, product_id AS p, purchase_price::float AS price, min_order_qty AS qty
        FROM scm.supplier_products WHERE product_id IN
             (SELECT product_id FROM scm.products WHERE NOT is_deleted ORDER BY product_id LIMIT %(limit)s)""",
     """UNWIND $rows AS r MATCH (s:Supplier {id: r.s}) MATCH (p:Product {id: r.p})
        MERGE (s)-[x:SUPPLIES]->(p) SET x.price = r.price, x.minQty = r.qty"""),
    ("склади і залишки",
     """SELECT w.warehouse_id AS w, w.code, w.name, i.product_id AS p, i.qty_on_hand AS on_hand,
               i.qty_reserved AS reserved
        FROM scm.warehouses w LEFT JOIN scm.inventory i ON i.warehouse_id = w.warehouse_id
        WHERE NOT w.is_deleted""",
     """UNWIND $rows AS r MERGE (w:Warehouse {id: r.w}) SET w.code = r.code, w.name = r.name
        WITH w, r WHERE r.p IS NOT NULL MATCH (p:Product {id: r.p})
        MERGE (w)-[s:STOCKS]->(p) SET s.onHand = r.on_hand, s.reserved = r.reserved"""),
    ("клієнти і замовлення",
     """SELECT c.customer_id AS c, c.name AS cname, so.so_id AS o, so.so_number AS num, so.status::text AS status,
               so.order_date::text AS date, so.warehouse_id AS w, i.product_id AS p, i.quantity AS qty,
               i.unit_price::float AS price
        FROM scm.customers c JOIN scm.sales_orders so ON so.customer_id = c.customer_id
        JOIN scm.sales_order_items i ON i.so_id = so.so_id""",
     """UNWIND $rows AS r MERGE (c:Customer {id: r.c}) SET c.name = r.cname
        MERGE (o:SalesOrder {id: r.o}) SET o.number = r.num, o.status = r.status, o.date = date(r.date)
        MERGE (c)-[:PLACED]->(o)
        WITH o, r MATCH (w:Warehouse {id: r.w}) MERGE (o)-[:SHIPS_FROM]->(w)
        WITH o, r MATCH (p:Product {id: r.p}) MERGE (o)-[x:CONTAINS]->(p) SET x.qty = r.qty, x.price = r.price"""),
]

def main(limit: int):
    pg = psycopg2.connect(PG_DSN)
    driver = GraphDatabase.driver(NEO4J_URI, auth=NEO4J_AUTH)
    with driver.session() as s:
        s.run("MATCH (n) DETACH DELETE n").consume()
        for c in CONSTRAINTS:
            s.run(c).consume()
        for title, sql, cypher in STEPS:
            with pg.cursor() as cur:
                cur.execute(sql, {"limit": limit})
                cols = [d[0] for d in cur.description]
                rows = [dict(zip(cols, r)) for r in cur.fetchall()]
            for i in range(0, len(rows), 2000):
                s.run(cypher, rows=rows[i:i + 2000]).consume()
            print(f"  {title}: {len(rows)}")
        s.run("MATCH (s:Supplier) WHERE NOT (s)-->() DELETE s").consume()
        for label, n in s.run("MATCH (n) RETURN labels(n)[0] AS l, count(*) AS n ORDER BY l"):
            print(f"  {label}: {n}")
    driver.close()
    pg.close()

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=5000, help="скільки товарів перенести в граф")
    main(ap.parse_args().limit)
