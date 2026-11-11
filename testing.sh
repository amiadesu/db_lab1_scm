#!/usr/bin/env bash
# Повний прогін ЛР2: для кожного обсягу генерація -> міграція -> перевірка -> вимірювання, потім граф Neo4j.
#
#   export PG_DSN="dbname=db_lab2_scm user=postgres password=... host=localhost"
#   bash testing.sh                    # обсяги 10000 100000 1000000
#   bash testing.sh 10000              # лише вказаний обсяг
set -euo pipefail
cd "$(dirname "$0")"

SIZES=("${@:-10000 100000 1000000}")
read -ra SIZES <<< "${SIZES[*]}"
K="${K:-1}"
mkdir -p results
LOG="results/run_$(date +%Y%m%d_%H%M%S).log"

log() { echo -e "\n=== $* ===" | tee -a "$LOG"; }
run() { "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }

# ---------------------------------------------------------------- перевірки
[[ -n "${PG_DSN:-}" ]] || { echo "Не задано PG_DSN (див. README, розділ «Запуск»)"; exit 1; }
[[ -n "${VIRTUAL_ENV:-}" ]] || [[ ! -d .venv ]] || source .venv/bin/activate

if command -v podman >/dev/null; then COMPOSE="podman compose"; else COMPOSE="docker compose"; fi
log "Контейнери ($COMPOSE)"
run $COMPOSE up -d

log "Очікування баз"
python - <<'EOF'
import time, psycopg2
from pymongo import MongoClient
from neo4j import GraphDatabase
from nosql.config import PG_DSN, MONGO_URI, NEO4J_URI, NEO4J_AUTH

def wait(name, check, tries=3):
    for _ in range(tries):
        try:
            check(); print(f"  {name}: OK"); return
        except Exception as e:
            err = e; time.sleep(2)
    raise SystemExit(f"  {name}: недоступна - {err}")

wait("PostgreSQL", lambda: psycopg2.connect(PG_DSN).close())
wait("MongoDB", lambda: MongoClient(MONGO_URI, serverSelectionTimeoutMS=2000).admin.command("ping"))
wait("Neo4j", lambda: GraphDatabase.driver(NEO4J_URI, auth=NEO4J_AUTH).verify_connectivity())
EOF

# --- Бенчмарк ---
for N in "${SIZES[@]}"; do
  log "N = $N: генерація"
  run python -m nosql.generate --n "$N"

  log "N = $N: міграція в MongoDB"
  run python -m nosql.migrate

  log "N = $N: перевірка еквівалентності"
  run python -m nosql.bench verify
  if ! tail -n 1 "$LOG" | grep -q "^OK"; then
    echo "Бази повертають різні результати - вимірювання не має сенсу. Дивіться $LOG" | tee -a "$LOG"
    exit 1
  fi

  log "N = $N: вимірювання"
  run python -m nosql.bench run --k "$K"
done

# --- Граф ---
log "Neo4j: завантаження графа (з останнього набору даних)"
run python -m graph.load_graph

log "Готово"
echo "Лог: $LOG
Результати: results/summary.csv, results/chart_*.png, results/sizes.txt, results/explain/
Neo4j Browser: http://localhost:7474 (neo4j / lab2-password), запити - graph/queries.cypher" | tee -a "$LOG"
