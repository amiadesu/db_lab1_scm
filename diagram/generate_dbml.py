# Будує schema.dbml зі структури бази db_lab1_scm.
# Отриманий текст вставляється на https://dbdiagram.io
import os
import re
import sys

import psycopg2

DSN = os.getenv("SCM_DSN", "dbname=db_lab1_scm user=postgres host=localhost")

GROUPS = {
    "Довідники": ["roles", "users", "countries", "cities", "units_of_measure", "product_categories"],
    "Постачання": ["suppliers", "supplier_bank_details", "supplier_contacts", "supplier_products",
                   "purchase_orders", "purchase_order_items"],
    "Склад": ["products", "product_attributes", "warehouses", "inventory", "inventory_movements"],
    "Продажі та доставка": ["customers", "sales_orders", "sales_order_items",
                            "carriers", "carrier_contracts", "shipments"],
    "Аудит": ["audit_log"],
}
TABLE_NOTES = {
    "suppliers": "SOFT DELETE + AUDIT (updated_at/updated_by)",
    "products": "SOFT DELETE + AUDIT; search_vector - GENERATED tsvector",
    "warehouses": "SOFT DELETE + AUDIT; location - GiST",
    "customers": "SOFT DELETE + AUDIT",
    "carriers": "SOFT DELETE",
    "inventory": "AUDIT; qty_on_hand оновлюється тригером з inventory_movements",
    "purchase_orders": "AUDIT; сума рахується у v_purchase_orders (3НФ)",
    "sales_orders": "AUDIT; сума рахується у v_sales_orders (3НФ)",
    "shipments": "AUDIT",
    "supplier_bank_details": "Зв'язок 1-до-1 з suppliers (PK = FK)",
    "carrier_contracts": "EXCLUDE USING gist: періоди одного перевізника не перетинаються",
    "audit_log": "PARTITION BY RANGE (changed_at): audit_log_2026, audit_log_2027, audit_log_default",
    "inventory_movements": "CLUSTER ON ix_movements_wh_product",
    "product_attributes": "1НФ: характеристика = окремий кортеж",
    "cities": "3НФ: місто визначає країну",
}
 
conn = psycopg2.connect(DSN)
cur = conn.cursor()
q = lambda sql: (cur.execute(sql), cur.fetchall())[1]
 
enums = q("""SELECT t.typname, array_agg(e.enumlabel ORDER BY e.enumsortorder)
               FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid
               JOIN pg_namespace n ON n.oid = t.typnamespace
              WHERE n.nspname = 'scm' GROUP BY t.typname ORDER BY t.typname""")
 
cols = q("""SELECT c.relname, a.attname,
                   replace(format_type(a.atttypid, a.atttypmod), 'scm.', ''),
                   a.attnotnull, pg_get_expr(d.adbin, d.adrelid), a.attgenerated, a.attidentity
              FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
              LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
             WHERE n.nspname = 'scm' AND c.relkind IN ('r','p') AND NOT c.relispartition
               AND a.attnum > 0 AND NOT a.attisdropped
             ORDER BY c.relname, a.attnum""")
 
pk = q("""SELECT c.relname, array_agg(a.attname ORDER BY array_position(k.conkey, a.attnum))
            FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(k.conkey)
           WHERE n.nspname = 'scm' AND k.contype = 'p' AND NOT c.relispartition
           GROUP BY c.relname""")
pk = {t: c for t, c in pk}
 
uniq = q("""SELECT c.relname, a.attname
              FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
              JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.conkey[1]
             WHERE n.nspname = 'scm' AND k.contype = 'u' AND array_length(k.conkey, 1) = 1""")
uniq = set(uniq)
 
fks = q("""SELECT c.relname, a.attname, rc.relname, ra.attname
             FROM pg_constraint k
             JOIN pg_class c  ON c.oid = k.conrelid
             JOIN pg_class rc ON rc.oid = k.confrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
             JOIN pg_attribute a  ON a.attrelid = c.oid  AND a.attnum  = k.conkey[1]
             JOIN pg_attribute ra ON ra.attrelid = rc.oid AND ra.attnum = k.confkey[1]
            WHERE n.nspname = 'scm' AND k.contype = 'f' AND NOT c.relispartition
            ORDER BY 1, 2""")
 
# без індексів, які PostgreSQL сам створив під PRIMARY KEY і UNIQUE
idx = q("""SELECT t.relname, i.relname, am.amname, ix.indisunique,
                  pg_get_indexdef(ix.indexrelid), pg_get_expr(ix.indpred, ix.indrelid)
             FROM pg_index ix
             JOIN pg_class i  ON i.oid = ix.indexrelid
             JOIN pg_class t  ON t.oid = ix.indrelid
             JOIN pg_am am    ON am.oid = i.relam
             JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE n.nspname = 'scm' AND t.relkind IN ('r','p') AND NOT t.relispartition
              AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = ix.indexrelid)
            ORDER BY 1, 2""")
conn.close()
 
fk_map = {(t, c): f"{rt}.{rc}" for t, c, rt, rc in fks}
AUDIT_FK = {"created_by", "updated_by", "deleted_by", "changed_by"}
# FK, який водночас є всім первинним ключем, означає зв'язок 1:1
one_to_one = {(t, c) for t, c, _, _ in fks if pk.get(t) == [c]}
 
out = ["// Система управління ланцюгами постачання",
       "Project supply_chain {", "  database_type: 'PostgreSQL'",
       "  Note: 'SCM: закупівлі, склади, продажі, доставка'", "}", ""]
 
for name, labels in enums:
    out.append(f"Enum {name} {{")
    out += [f"  {l}" for l in labels]
    out += ["}", ""]
 
for g, tables in GROUPS.items():
    out.append(f'TableGroup "{g}" {{')
    out += [f"  {t}" for t in tables]
    out += ["}", ""]
 
table_cols: dict[str, list] = {}
for row in cols:
    table_cols.setdefault(row[0], []).append(row[1:])
 
 
def dbml_type(t: str) -> str:
    return t.replace("character varying", "varchar").replace("timestamp with time zone", "timestamptz") \
            .replace("character(", "char(").replace(" ", "_") if " " in t or "character" in t else t
 
 
for t in sum(GROUPS.values(), []):
    out.append(f"Table {t} {{")
    composite_pk = len(pk.get(t, [])) > 1
    for col, typ, nn, default, generated, identity in table_cols[t]:
        s = []
        if col in pk.get(t, []) and not composite_pk:
            s.append("pk")
        if nn and not (col in pk.get(t, []) and not composite_pk):
            s.append("not null")
        if (t, col) in uniq:
            s.append("unique")
        if default and not generated:
            if default.startswith("nextval"):
                s.append("increment")
            else:
                clean = re.sub(r"::[a-z_ ]+(\(\d+\))?", "", default)  # прибираємо приведення типів на кшталт ::bpchar
                s.append("default: `" + clean.replace("`", "") + "`")
        if identity:
            s.append("increment")
        if (t, col) in fk_map:
            if fk_map[(t, col)] == "users.user_id" and col in AUDIT_FK:
                # такі посилання є майже в кожній таблиці, і на dbdiagram.io їхні лінії
                # перекривають усю схему, тому FK лишається лише приміткою
                s.append("note: 'FK -> users.user_id'")
            else:
                s.append(("ref: - " if (t, col) in one_to_one else "ref: > ") + fk_map[(t, col)])
        if generated:
            s.append(f"note: 'GENERATED: {default.replace(chr(39), '')}'")
        settings = f" [{', '.join(s)}]" if s else ""
        out.append(f"  {col} {dbml_type(typ)}{settings}")
    ix_lines = []
    if composite_pk:
        ix_lines.append(f"    ({', '.join(pk[t])}) [pk]")
    for tbl, iname, am, unique, idef, pred in idx:
        if tbl != t:
            continue
        cols_part = idef[idef.index("(", idef.index(" USING ")) + 1:]
        cols_part = cols_part[:cols_part.rfind(")")] if " WHERE " not in idef else \
            cols_part[:cols_part.index(" WHERE ")].rstrip(")")
        flags = [f"name: '{iname}'"]
        if am in ("btree", "hash"):  # інші типи індексів DBML не підтримує
            flags.insert(0, f"type: {am}")
        if unique:
            flags.insert(0, "unique")
        note = f"{am.upper()}" + (f" WHERE {pred}" if pred else "") + \
               (" INCLUDE" if "INCLUDE" in idef else "")
        flags.append(f"note: '{note.replace(chr(39), '')}'")
        parts = [x.strip() for x in cols_part.split(",")]
        if all(re.fullmatch(r"[a-z_]+", x) for x in parts):
            target = parts[0] if len(parts) == 1 else f"({', '.join(parts)})"
        else:
            target = f"`{cols_part.replace('`', '')}`"
        ix_lines.append(f"    {target} [{', '.join(flags)}]")
    if ix_lines:
        out += ["", "  indexes {"] + ix_lines + ["  }"]
    if t in TABLE_NOTES:
        out.append("  Note: '" + TABLE_NOTES[t].replace("'", "\\'") + "'")
    out += ["}", ""]
 
path = sys.argv[1] if len(sys.argv) > 1 else "schema.dbml"
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(out))
print("written", path, "tables:", len(table_cols), "refs:", len(fks), "indexes:", len(idx))
