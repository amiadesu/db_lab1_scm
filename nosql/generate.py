"""
Перевстановлює схему scm з ЛР1 і заповнює каталог N згенерованими товарами
"""
import argparse
import io
import os
import random
import time

import psycopg2

from .config import PG_DSN

SQL_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sql")

# Дерево категорій
TREE = {
    ("EL", "Електроніка"): {
        "Комплектуючі": ["SSD-накопичувачі", "Жорсткі диски", "Оперативна пам'ять", "Блоки живлення"],
        "Периферія": ["Миші", "Клавіатури", "Навушники", "Веб-камери"],
        "Кабелі та зарядки": ["Кабелі USB", "Кабелі HDMI", "Зарядні пристрої", "Павербанки"],
    },
    ("PK", "Пакування"): {
        "Коробки": ["Гофрокоробки", "Поштові коробки", "Архівні коробки", "Подарункові коробки"],
        "Плівки та стрічки": ["Стретч-плівка", "Скотч", "Бульбашкова плівка", "Термоусадна плівка"],
        "Пакети": ["Поліетиленові пакети", "Паперові пакети", "Кур'єрські пакети", "Zip-пакети"],
    },
    ("CH", "Побутова хімія"): {
        "Миючі засоби": ["Для підлоги", "Для скла", "Для посуду", "Універсальні"],
        "Дезінфекція": ["Антисептики", "Хлорвмісні засоби", "Дезінфекційні серветки", "Засоби для рук"],
        "Пральні засоби": ["Пральні порошки", "Гелі для прання", "Кондиціонери", "Плямовивідники"],
    },
    ("TL", "Інструменти"): {
        "Електроінструмент": ["Дрилі", "Шуруповерти", "Болгарки", "Перфоратори"],
        "Ручний інструмент": ["Викрутки", "Ключі", "Молотки", "Плоскогубці"],
        "Вимірювальний інструмент": ["Рулетки", "Рівні", "Лазерні далекоміри", "Штангенциркулі"],
    },
}

# Характеристики товарів у кожному кореневому розділі
ATTRS = {
    "EL": {"brand": ["Orion", "Voltix", "NordTech", "Kvant", "Sigma", "Lumo", "Arkada", "Zenit"],
           "color": ["black", "white", "gray", "silver", "blue"], "warranty_months": [6, 12, 24, 36],
           "wireless": [True, False], "interface": ["USB-A", "USB-C", "PCIe", "SATA", "NVMe", "HDMI", "DDR5"],
           "capacity_gb": [128, 256, 512, 1024, 2048], "power_w": [5, 18, 30, 65, 100, 650, 850],
           "length_m": [0.5, 1.0, 1.5, 2.0, 3.0], "rgb": [True, False], "voltage_v": [5, 9, 12, 20, 220],
           "country_of_origin": ["CN", "TW", "KR", "VN", "PL"]},
    "PK": {"brand": ["PackPro", "Kartonia", "PolPack", "FlexiWrap", "Upak", "EcoPak"],
           "color": ["brown", "white", "transparent", "black"],
           "material": ["гофрокартон", "картон", "LDPE", "HDPE", "PP", "крафт-папір"],
           "size": ["XS", "S", "M", "L", "XL"], "thickness_mkm": [12, 17, 20, 23, 30, 50],
           "width_mm": [48, 50, 75, 100, 500], "layers": [1, 3, 5], "max_load_kg": [5, 10, 20, 30],
           "recyclable": [True, False], "pack_qty": [10, 25, 50, 100, 500], "country_of_origin": ["UA", "PL", "CN"]},
    "CH": {"brand": ["ChemClean", "Freshy", "Blysk", "Chysto", "Hygio", "Sanitex"],
           "volume_l": [0.5, 0.75, 1.0, 1.5, 5.0], "scent": ["без запаху", "лимон", "лаванда", "хвоя"],
           "concentrate": [True, False], "ph_level": [3, 5, 7, 9, 11], "hypoallergenic": [True, False],
           "package_type": ["пляшка", "каністра", "дой-пак", "спрей"],
           "active_substance": ["ПАР", "хлор", "спирт", "ензими"], "shelf_life_months": [12, 24, 36],
           "professional": [True, False], "country_of_origin": ["UA", "PL", "DE", "TR"]},
    "TL": {"brand": ["Kraft", "Grizli", "Tornado", "Masterko", "IronHand", "Volat"],
           "power_w": [400, 600, 900, 1200, 2000], "voltage_v": [12, 18, 36, 220], "battery_ah": [1.5, 2.0, 4.0],
           "cordless": [True, False], "max_rpm": [1500, 2800, 3500, 11000], "chuck_mm": [10, 13],
           "material": ["сталь CrV", "сталь S2", "алюміній"], "length_mm": [100, 150, 200, 300],
           "measuring_range_m": [3, 5, 10, 30, 50], "warranty_months": [12, 24, 36],
           "country_of_origin": ["UA", "CN", "DE", "PL"]},
}
UOM = {"EL": "pcs", "PK": "pcs", "CH": "l", "TL": "pcs"}

# Випадковий генератор для вибору категорій і характеристик
_rng = random.Random("leaves")
LEAVES = []
for (code, _root), mids in TREE.items():
    for mid, leaves in mids.items():
        for leaf in leaves:
            others = [a for a in ATTRS[code] if a != "brand"]
            LEAVES.append((code, mid, leaf, ["brand"] + _rng.sample(others, 7)))

def attr_text(v) -> str:
    """Значення характеристики в EAV-таблиці (VARCHAR)."""
    return ("true" if v else "false") if isinstance(v, bool) else str(v)

def n_suppliers(n: int) -> int:
    return max(40, n // 100 // 4 * 4) # ~1 постачальник на 100 товарів

# Генератор ініціалізується номером товару i, тому make_product(i, n) щоразу повертає той самий товар.
# Так бенчмарк може "відтворити" будь-який товар і взяти з нього SKU чи характеристики
# для запитів, не звертаючись до бази, за номером товару i (1..N).
def make_product(i: int, n: int) -> dict:
    rng = random.Random(i)
    code, mid, leaf, attr_names = LEAVES[rng.randrange(len(LEAVES))]
    attrs = {a: rng.choice(ATTRS[code][a]) for a in attr_names if a == "brand" or rng.random() < 0.9}
    price = max(5.0, round(rng.lognormvariate(4.5, 1.2), 2))
    roots = [c for c, _ in TREE]
    per_root = n_suppliers(n) // 4
    sup = sorted({roots.index(code) + 1 + 4 * rng.randrange(per_root) for _ in range(rng.randint(1, 4))})
    return {
        "i": i, "sku": f"G{code}-{i:07d}", "leaf": leaf, "mid": mid, "uom": UOM[code],
        "name": f"{leaf}: {attrs['brand']} {rng.randint(100, 9999)}",
        "description": f"Товар категорії «{leaf}», бренд {attrs['brand']}.",
        "price": f"{price:.2f}", "weight": f"{rng.uniform(0.05, 15):.3f}",
        "reorder": rng.choice([0, 10, 20, 50, 100]), "attrs": attrs,
        "offers": [(s, f"S{s}-{i}", f"{price * rng.uniform(0.55, 0.9):.2f}", rng.choice([1, 10, 50]))
                   for s in sup],
    }

def _esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")

def _copy(cur, table, cols, rows):
    cur.copy_expert(f"COPY scm.{table} ({cols}) FROM STDIN", io.StringIO("".join(rows)))

def install_schema(conn):
    with conn.cursor() as cur:
        for f in ["01_schema.sql", "02_functions.sql", "03_triggers.sql", "04_views.sql",
                  "05_procedures.sql", "06_indexes.sql", "07_seed.sql", "08_lab2_indexes.sql"]:
            with open(os.path.join(SQL_DIR, f), encoding="utf-8") as fh:
                cur.execute(fh.read())
            cur.execute("SET search_path TO scm, public")

def generate(n: int):
    conn = psycopg2.connect(PG_DSN)
    conn.autocommit = True
    t0 = time.perf_counter()
    install_schema(conn)
    with conn.cursor() as cur:
        cur.execute("SET session_replication_role = replica")

        for (code, root), mids in TREE.items():
            cur.execute("INSERT INTO product_categories(name) VALUES (%s) ON CONFLICT (name) DO NOTHING", (root,))
            for mid, leaves in mids.items():
                cur.execute("INSERT INTO product_categories(parent_category_id, name) "
                            "SELECT category_id, %s FROM product_categories WHERE name = %s "
                            "ON CONFLICT (name) DO NOTHING", (mid, root))
                for leaf in leaves:
                    cur.execute("INSERT INTO product_categories(parent_category_id, name) "
                                "SELECT category_id, %s FROM product_categories WHERE name = %s", (leaf, mid))
        cur.execute("SELECT name, category_id FROM product_categories")
        cat = dict(cur.fetchall())
        cur.execute("SELECT code, uom_id FROM units_of_measure")
        uom = dict(cur.fetchall())

        cur.execute("SELECT array_agg(city_id) FROM cities WHERE country_code <> 'UA'")
        cities = cur.fetchone()[0]
        cur.execute("SELECT COALESCE(MAX(supplier_id), 0) FROM suppliers")
        s_base = cur.fetchone()[0]
        _copy(cur, "suppliers", "supplier_id, name, tax_code, city_id, rating, lead_time_days",
              [f"{s_base + s}\tПостачальник №{s}\tGEN{s:07d}\t{cities[s % len(cities)]}\t"
               f"{3 + s % 200 / 100:.2f}\t{7 + s % 4 * 7}\n" for s in range(1, n_suppliers(n) + 1)])

        cur.execute("SELECT COALESCE(MAX(product_id), 0) FROM products")
        p_base = cur.fetchone()[0]
        for start in range(1, n + 1, 20000):
            prods, attrs, offers = [], [], []
            for i in range(start, min(start + 20000, n + 1)):
                p = make_product(i, n)
                pid = p_base + i
                prods.append(f"{pid}\t{p['sku']}\t{_esc(p['name'])}\t{_esc(p['description'])}\t{cat[p['leaf']]}\t"
                             f"{uom[p['uom']]}\t{p['price']}\t{p['weight']}\t{p['reorder']}\n")
                attrs += [f"{pid}\t{k}\t{attr_text(v)}\n" for k, v in p["attrs"].items()]
                offers += [f"{s_base + s}\t{pid}\t{ssku}\t{pp}\t{q}\n" for s, ssku, pp, q in p["offers"]]
            _copy(cur, "products", "product_id, sku, name, description, category_id, uom_id, unit_price, "
                                   "weight_kg, reorder_level", prods)
            _copy(cur, "product_attributes", "product_id, attr_name, attr_value", attrs)
            _copy(cur, "supplier_products", "supplier_id, product_id, supplier_sku, purchase_price, min_order_qty",
                  offers)
            print(f"  {min(start + 19999, n):>9,} / {n:,} товарів  ({time.perf_counter() - t0:.0f} с)")

        cur.execute("SET session_replication_role = origin")
        for t, col in (("products", "product_id"), ("suppliers", "supplier_id"), ("product_categories", "category_id")):
            cur.execute(f"SELECT setval(pg_get_serial_sequence('scm.{t}', '{col}'), (SELECT MAX({col}) FROM scm.{t}))")
        cur.execute("VACUUM ANALYZE scm.products, scm.product_attributes, scm.supplier_products, scm.suppliers")
        cur.execute("CREATE TABLE IF NOT EXISTS scm.lab2_meta (n INT NOT NULL)")
        cur.execute("TRUNCATE scm.lab2_meta; INSERT INTO scm.lab2_meta VALUES (%s)", (n,))
    conn.close()
    print(f"PostgreSQL: {n:,} товарів за {time.perf_counter() - t0:.0f} с")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=100_000)
    generate(ap.parse_args().n)
