import argparse
import csv
import json
import os
import random
import statistics
import time
from datetime import datetime, timezone

import psycopg2
from pymongo import MongoClient

from .config import MONGO_DB, MONGO_URI, PG_DSN, RESULTS_DIR
from .generate import ATTRS, LEAVES, TREE, attr_text, make_product, n_suppliers

ROOT = {code: root for code, root in TREE}
LEAF_CODE = {leaf: code for code, _, leaf, _ in LEAVES}
from .migrate import typed

# код: (опис, кількість вимірювань, прогрів)
TESTS = {
    "T1": ("Картка товару за артикулом (увесь агрегат)", 1000, 100),
    "T2": ("Сторінка підкатегорії: 20 найдешевших", 500, 50),
    "T3": ("Фільтр: підкатегорія + 2 характеристики + ціна", 500, 50),
    "T4": ("Фасети листової категорії (кількість за значеннями)", 100, 10),
    "T5": ("Вставка товару з характеристиками і пропозиціями", 300, 0),
    "T6": ("Зміна однієї характеристики", 300, 0),
    "T7": ("Перейменування постачальника", 100, 0),
}
NEW_ID = 10_000_000 # id товарів, які вставляє T5

SUBTREE = """WITH RECURSIVE sub AS (
    SELECT category_id FROM scm.product_categories WHERE category_id = %(cat)s
    UNION ALL
    SELECT c.category_id FROM scm.product_categories c JOIN sub ON c.parent_category_id = sub.category_id)
"""
SQL = {
    "T1": """
SELECT p.product_id, p.sku, p.name, p.description, p.unit_price, u.code,
       (WITH RECURSIVE up AS (
            SELECT category_id, parent_category_id, name, 0 AS d FROM scm.product_categories
             WHERE category_id = p.category_id
            UNION ALL
            SELECT c.category_id, c.parent_category_id, c.name, up.d + 1
              FROM scm.product_categories c JOIN up ON c.category_id = up.parent_category_id)
        SELECT json_agg(name ORDER BY d DESC) FROM up) AS path,
       (SELECT json_object_agg(attr_name, attr_value) FROM scm.product_attributes a
         WHERE a.product_id = p.product_id) AS attributes,
       (SELECT json_agg(json_build_object('supplierId', s.supplier_id, 'supplierName', s.name,
                                          'purchasePrice', sp.purchase_price) ORDER BY s.supplier_id)
          FROM scm.supplier_products sp JOIN scm.suppliers s ON s.supplier_id = sp.supplier_id AND NOT s.is_deleted
         WHERE sp.product_id = p.product_id) AS offers
FROM scm.products p JOIN scm.units_of_measure u ON u.uom_id = p.uom_id
WHERE p.sku = %(sku)s AND NOT p.is_deleted""",
    "T2": SUBTREE + """
SELECT p.product_id, p.sku, p.name, p.unit_price FROM scm.products p
WHERE p.category_id IN (SELECT category_id FROM sub) AND NOT p.is_deleted
ORDER BY p.unit_price, p.product_id LIMIT 20""",
    "T3": SUBTREE + """
SELECT p.product_id, p.sku, p.name, p.unit_price FROM scm.products p
JOIN scm.product_attributes a1 ON a1.product_id = p.product_id AND a1.attr_name = %(a1)s AND a1.attr_value = %(v1)s
JOIN scm.product_attributes a2 ON a2.product_id = p.product_id AND a2.attr_name = %(a2)s AND a2.attr_value = %(v2)s
WHERE p.category_id IN (SELECT category_id FROM sub) AND NOT p.is_deleted AND p.unit_price <= %(max_price)s
ORDER BY p.unit_price, p.product_id LIMIT 50""",
    "T4": SUBTREE + """
SELECT a.attr_name, a.attr_value, count(*) FROM scm.products p
JOIN scm.product_attributes a ON a.product_id = p.product_id
WHERE p.category_id IN (SELECT category_id FROM sub) AND NOT p.is_deleted
GROUP BY a.attr_name, a.attr_value""",
    # один оператор = одна транзакція: товар + характеристики + пропозиції
    "T5": """
WITH p AS (
    INSERT INTO scm.products(product_id, sku, name, description, category_id, uom_id, unit_price, weight_kg)
    VALUES (%(id)s, %(sku)s, %(name)s, %(description)s, %(cat)s, %(uom)s, %(price)s, %(weight)s)
    RETURNING product_id
), a AS (
    INSERT INTO scm.product_attributes SELECT (SELECT product_id FROM p), key, value FROM json_each_text(%(attrs)s)
)
INSERT INTO scm.supplier_products(supplier_id, product_id, supplier_sku, purchase_price, min_order_qty)
SELECT x.s, (SELECT product_id FROM p), x.ssku, x.price, x.qty
FROM json_to_recordset(%(offers)s) AS x(s INT, ssku TEXT, price NUMERIC, qty INT)""",
    "T6": "CALL scm.sp_product_set_attribute(%(id)s, %(attr)s, %(value)s)", # процедура з ЛР1
    "T7": "UPDATE scm.suppliers SET name = %(name)s WHERE supplier_id = %(sid)s",
}

class Ctx:
    """Відповідність (контекст) між номером згенерованого товару і id/категоріями в базі"""

    def __init__(self, pg):
        with pg.cursor() as c:
            c.execute("SELECT n FROM scm.lab2_meta")
            self.n = c.fetchone()[0]
            c.execute("SELECT min(product_id) - 1 FROM scm.products WHERE sku ~ '^G[A-Z]{2}-'")
            self.p_base = c.fetchone()[0]
            c.execute("SELECT min(supplier_id) - 1 FROM scm.suppliers WHERE tax_code LIKE 'GEN%%'")
            self.s_base = c.fetchone()[0]
            c.execute("SELECT name, category_id FROM scm.product_categories")
            self.cat = dict(c.fetchall())
            c.execute("SELECT code, uom_id FROM scm.units_of_measure")
            self.uom = dict(c.fetchall())

def make_params(test, ctx: Ctx, count, seed=1):
    rng = random.Random(f"{test}:{seed}")
    rnd = lambda: make_product(rng.randint(1, ctx.n), ctx.n)
    out = []
    for k in range(count):
        if test == "T1":
            out.append({"sku": rnd()["sku"]})
        elif test == "T2":
            out.append({"cat": ctx.cat[rnd()["mid"]]})
        elif test == "T3":
            p = rnd()
            while len(p["attrs"]) < 3:
                p = rnd()
            a1, a2 = rng.sample([a for a in p["attrs"] if a != "brand"], 2)
            out.append({"cat": ctx.cat[p["mid"]], "a1": a1, "v1": p["attrs"][a1], "a2": a2, "v2": p["attrs"][a2],
                        "max_price": round(float(p["price"]) * rng.uniform(1, 3), 2)})
        elif test == "T4":
            out.append({"cat": ctx.cat[rnd()["leaf"]]})
        elif test == "T5":
            p = rnd()
            p["id"], p["sku"] = NEW_ID + seed * 100_000 + k, f"NEW-{seed}-{k}"
            out.append(p)
        elif test == "T6":
            i = rng.randint(1, ctx.n)
            p = make_product(i, ctx.n)
            attr = rng.choice(list(p["attrs"]))
            code = next(c for c, mid, leaf, _ in LEAVES if leaf == p["leaf"])
            out.append({"id": ctx.p_base + i, "attr": attr, "value": rng.choice(ATTRS[code][attr])})
        elif test == "T7":
            s = rng.randint(1, n_suppliers(ctx.n))
            out.append({"sid": ctx.s_base + s, "name": f"Постачальник №{s} (ред. {seed}.{k})"})
    return out

# --- Виконання бенчмарка ---

def run_sql(cur, test, p, ctx):
    a = dict(p)
    if test == "T3":
        a["v1"], a["v2"] = attr_text(p["v1"]), attr_text(p["v2"])
    elif test == "T5":
        a = {"id": p["id"], "sku": p["sku"], "name": p["name"], "description": p["description"],
             "cat": ctx.cat[p["leaf"]], "uom": ctx.uom[p["uom"]], "price": p["price"], "weight": p["weight"],
             "attrs": json.dumps({k: attr_text(v) for k, v in p["attrs"].items()}),
             "offers": json.dumps([{"s": ctx.s_base + s, "ssku": ss, "price": pp, "qty": q}
                                   for s, ss, pp, q in p["offers"]])}
    elif test == "T6":
        a["value"] = attr_text(p["value"])
    cur.execute(SQL[test], a)
    return cur.fetchall() if cur.description else cur.rowcount

def mongo_spec(test, p):
    page = {"sku": 1, "name": 1, "priceMinor": 1}
    if test == "T1":
        return {"filter": {"sku": p["sku"], "isDeleted": False}, "limit": 1}
    if test == "T2":
        return {"filter": {"category.pathIds": p["cat"], "isDeleted": False}, "projection": page,
                "sort": {"priceMinor": 1, "_id": 1}, "limit": 20}
    if test == "T3":
        return {"filter": {"category.pathIds": p["cat"], "isDeleted": False,
                           f"attributes.{p['a1']}": p["v1"], f"attributes.{p['a2']}": p["v2"],
                           "priceMinor": {"$lte": int(round(p["max_price"] * 100))}},
                "projection": page, "sort": {"priceMinor": 1, "_id": 1}, "limit": 50}
    if test == "T4":
        return {"pipeline": [
            {"$match": {"category.pathIds": p["cat"], "isDeleted": False}},
            {"$project": {"_id": 0, "kv": {"$objectToArray": "$attributes"}}},
            {"$unwind": "$kv"},
            {"$group": {"_id": {"k": "$kv.k", "v": "$kv.v"}, "n": {"$sum": 1}}}]}


def run_mongo(coll, test, p, ctx):
    if test == "T5":
        return coll.insert_one({
            "_id": p["id"], "sku": p["sku"], "name": p["name"], "description": p["description"],
            "category": {"id": ctx.cat[p["leaf"]], "name": p["leaf"],
                         "pathIds": [ctx.cat[ROOT[LEAF_CODE[p["leaf"]]]], ctx.cat[p["mid"]], ctx.cat[p["leaf"]]]},
            "uom": {"code": p["uom"]}, "priceMinor": int(round(float(p["price"]) * 100)), "currency": "UAH",
            "weightKg": float(p["weight"]),
            "attributes": {k: typed(k, attr_text(v)) for k, v in p["attrs"].items()},
            "offers": [{"supplierId": ctx.s_base + s, "supplierName": f"Постачальник №{s}", "supplierSku": ss,
                        "purchasePriceMinor": int(round(float(pp) * 100)), "minOrderQty": q}
                       for s, ss, pp, q in p["offers"]],
            "isDeleted": False, "createdAt": datetime.now(timezone.utc)})
    if test == "T6":
        return coll.update_one({"_id": p["id"]}, {"$set": {f"attributes.{p['attr']}": p["value"],
                                                           "updatedAt": datetime.now(timezone.utc)}})
    if test == "T7": # назва постачальника скопійована в кожен документ з його пропозицією
        return coll.update_many({"offers.supplierId": p["sid"]}, {"$set": {"offers.$[o].supplierName": p["name"]}},
                                array_filters=[{"o.supplierId": p["sid"]}])
    s = mongo_spec(test, p)
    if "pipeline" in s:
        return list(coll.aggregate(s["pipeline"]))
    cur = coll.find(s["filter"], s.get("projection"))
    if "sort" in s:
        cur = cur.sort(list(s["sort"].items()))
    return list(cur.limit(s["limit"]))

# --- Перевірка еквівалентності результатів SQL і MongoDB ---

def normalize(test, db, res):
    if test == "T1":
        if db == "sql":
            r = res[0]
            return (r[1], r[2], f"{r[4]:.2f}", tuple(r[6]), tuple(sorted((r[7] or {}).items())),
                    tuple((o["supplierId"], o["supplierName"], f"{o['purchasePrice']:.2f}") for o in r[8] or []))
        d = res[0]
        return (d["sku"], d["name"], f"{d['priceMinor'] / 100:.2f}", tuple(d["category"]["path"]),
                tuple(sorted((k, attr_text(v)) for k, v in d["attributes"].items())),
                tuple((o["supplierId"], o["supplierName"], f"{o['purchasePriceMinor'] / 100:.2f}")
                      for o in d["offers"]))
    if test in ("T2", "T3"):
        return [r[0] for r in res] if db == "sql" else [d["_id"] for d in res]
    if test == "T4":
        if db == "sql":
            return sorted(res)
        return sorted((d["_id"]["k"], attr_text(d["_id"]["v"]), d["n"]) for d in res)

def verify(samples=30):
    pg, coll, ctx = connect()
    ok = True
    with pg.cursor() as cur:
        for test in ("T1", "T2", "T3", "T4"):
            same = 0
            for p in make_params(test, ctx, samples, seed=99):
                a = normalize(test, "sql", run_sql(cur, test, p, ctx))
                b = normalize(test, "mongo", run_mongo(coll, test, p, ctx))
                if a == b:
                    same += 1
                elif same == 0:
                    print(f"  розбіжність {test} {p}\n    sql:   {str(a)[:200]}\n    mongo: {str(b)[:200]}")
            print(f"  {test}: {same}/{samples} однакових відповідей")
            ok &= same == samples
    print("OK: результати однакові" if ok else "Є РОЗБІЖНОСТІ")

# --- Вимірювання часу виконання ---

def connect():
    pg = psycopg2.connect(PG_DSN)
    pg.autocommit = True # кожен запит - окрема транзакція з COMMIT (як окремий запит застосунку)
    coll = MongoClient(MONGO_URI, w=1, journal=True)[MONGO_DB]["products"]
    return pg, coll, Ctx(pg)

def cleanup(pg, coll):
    with pg.cursor() as cur:
        cur.execute("SET session_replication_role = replica") # тригер ЛР1 забороняє фізичне видалення товарів
        cur.execute("DELETE FROM scm.product_attributes WHERE product_id >= %s", (NEW_ID,))
        cur.execute("DELETE FROM scm.supplier_products WHERE product_id >= %s", (NEW_ID,))
        cur.execute("DELETE FROM scm.products WHERE product_id >= %s", (NEW_ID,))
        cur.execute("SET session_replication_role = origin")
    coll.delete_many({"_id": {"$gte": NEW_ID}})

def explain(pg, coll, test, p, ctx, path):
    with pg.cursor() as cur:
        if test in SQL and test <= "T4":
            q = cur.mogrify(SQL[test], {**p, **({"v1": attr_text(p["v1"]), "v2": attr_text(p["v2"])}
                                                 if test == "T3" else {})}).decode()
            cur.execute("EXPLAIN (ANALYZE, BUFFERS) " + q)
            with open(f"{path}_sql.txt", "w", encoding="utf-8") as f:
                f.write(q + "\n\n" + "\n".join(r[0] for r in cur.fetchall()))
    if test <= "T4":
        s = mongo_spec(test, p)
        cmd = ({"aggregate": "products", "pipeline": s["pipeline"], "cursor": {}} if "pipeline" in s else
               {"find": "products", "filter": s["filter"], "projection": s.get("projection"),
                "sort": s.get("sort"), "limit": s["limit"]})
        res = coll.database.command("explain", {k: v for k, v in cmd.items() if v is not None},
                                    verbosity="executionStats")
        with open(f"{path}_mongo.json", "w", encoding="utf-8") as f:
            json.dump(res, f, default=str, ensure_ascii=False, indent=1)

def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, round(q / 100 * (len(xs) - 1)))]

def run(tests, k):
    pg, coll, ctx = connect()
    os.makedirs(os.path.join(RESULTS_DIR, "explain"), exist_ok=True)
    cleanup(pg, coll)
    with pg.cursor() as cur:
        # аудит ЛР1 пише в audit_log при кожній зміні; у MongoDB аудиту немає - вимикаємо на час тестів
        cur.execute("ALTER TABLE scm.products DISABLE TRIGGER trg_products_audit_log")
        cur.execute("ALTER TABLE scm.suppliers DISABLE TRIGGER trg_suppliers_audit_log")
    rows = []
    print(f"{ctx.n:,} товарів\n{'тест':4} {'база':6} {'p50, мс':>9} {'p95, мс':>9} {'p99, мс':>9} {'оп/с':>8}")
    try:
        for test in tests:
            title, repeat, warm = TESTS[test]
            repeat, warm = max(10, int(repeat * k)), int(warm * k)
            for db in ("sql", "mongo"):
                params = make_params(test, ctx, warm + repeat) # однакові для обох баз
                lat = []
                with pg.cursor() as cur:
                    for j, p in enumerate(params):
                        t0 = time.perf_counter()
                        run_sql(cur, test, p, ctx) if db == "sql" else run_mongo(coll, test, p, ctx)
                        if j >= warm:
                            lat.append((time.perf_counter() - t0) * 1000)
                row = {"n": ctx.n, "test": test, "title": title, "db": db, "ops": len(lat),
                       "p50_ms": round(pct(lat, 50), 3), "p95_ms": round(pct(lat, 95), 3),
                       "p99_ms": round(pct(lat, 99), 3), "ops_s": round(1000 / statistics.fmean(lat), 1)}
                rows.append(row)
                print(f"{test:4} {db:6} {row['p50_ms']:>9} {row['p95_ms']:>9} {row['p99_ms']:>9} {row['ops_s']:>8}")
            explain(pg, coll, test, make_params(test, ctx, 1, seed=7)[0], ctx,
                    os.path.join(RESULTS_DIR, "explain", f"{ctx.n}_{test}"))
    finally:
        with pg.cursor() as cur:
            cur.execute("ALTER TABLE scm.products ENABLE TRIGGER trg_products_audit_log")
            cur.execute("ALTER TABLE scm.suppliers ENABLE TRIGGER trg_suppliers_audit_log")
        cleanup(pg, coll)

    path = os.path.join(RESULTS_DIR, "summary.csv")
    new = not os.path.exists(path)
    with open(path, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        if new:
            w.writeheader()
        w.writerows(rows)
    sizes(pg, coll, ctx.n)
    chart()

def sizes(pg, coll, n):
    with pg.cursor() as cur:
        cur.execute("""SELECT sum(pg_table_size(t)), sum(pg_indexes_size(t)) FROM unnest(ARRAY[
            'scm.products', 'scm.product_attributes', 'scm.supplier_products', 'scm.suppliers',
            'scm.product_categories', 'scm.units_of_measure']::regclass[]) t""")
        d, i = cur.fetchone()
    st = coll.database.command("collStats", "products")
    line = (f"{n} товарів: PostgreSQL дані {d / 2**20:.0f} МБ + індекси {i / 2**20:.0f} МБ; "
            f"MongoDB дані {st['storageSize'] / 2**20:.0f} МБ (стиснуто, без стиснення {st['size'] / 2**20:.0f} МБ) "
            f"+ індекси {st['totalIndexSize'] / 2**20:.0f} МБ")
    print(line)
    with open(os.path.join(RESULTS_DIR, "sizes.txt"), "a", encoding="utf-8") as f:
        f.write(line + "\n")

def chart():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    with open(os.path.join(RESULTS_DIR, "summary.csv"), encoding="utf-8") as f:
        data = list(csv.DictReader(f))
    for n in sorted({r["n"] for r in data}, key=int):
        rs = [r for r in data if r["n"] == n]
        tests = list(dict.fromkeys(r["test"] for r in rs))
        fig, ax = plt.subplots(figsize=(10, 4.5))
        for off, db, color in ((-0.2, "sql", "#336791"), (0.2, "mongo", "#47A248")):
            vals = [next(float(r["p50_ms"]) for r in reversed(rs) if r["test"] == t and r["db"] == db) for t in tests]
            ax.bar([x + off for x in range(len(tests))], vals, 0.4, label="PostgreSQL" if db == "sql" else "MongoDB",
                   color=color)
        ax.set_xticks(range(len(tests)), tests)
        ax.set_yscale("log")
        ax.set_ylabel("медіана затримки, мс (лог. шкала)")
        ax.set_title(f"{int(n):,} товарів: менше - краще")
        ax.legend()
        ax.grid(axis="y", alpha=0.3)
        fig.tight_layout()
        fig.savefig(os.path.join(RESULTS_DIR, f"chart_{n}.png"), dpi=120)
        plt.close(fig)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["verify", "run"])
    ap.add_argument("--tests", default=",".join(TESTS))
    ap.add_argument("--k", type=float, default=1.0, help="множник кількості повторів (0.2 - швидкий прогін)")
    a = ap.parse_args()
    verify() if a.cmd == "verify" else run(a.tests.split(","), a.k)
