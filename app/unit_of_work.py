from __future__ import annotations

import os

import psycopg2
from psycopg2 import sql
from psycopg2.extensions import connection as PgConnection

from .repositories import (AuditRepository, InventoryRepository, ProductRepository,
                           PurchaseOrderRepository, SupplierRepository)

DEFAULT_DSN = os.getenv("SCM_DSN", "dbname=db_lab1_scm user=postgres host=localhost")

# Одна транзакція на всі репозиторії: або зберігаються всі зміни, або жодна.
class UnitOfWork:
    suppliers: SupplierRepository
    products: ProductRepository
    purchase_orders: PurchaseOrderRepository
    inventory: InventoryRepository
    audit: AuditRepository

    def __init__(self, user_id: int, dsn: str = DEFAULT_DSN):
        self._dsn = dsn
        self._user_id = user_id
        self._conn: PgConnection | None = None
        self._committed = False

    def __enter__(self) -> "UnitOfWork":
        self._conn = psycopg2.connect(self._dsn)
        self._conn.autocommit = False
        self._bind_user()

        self.suppliers = SupplierRepository(self._conn)
        self.products = ProductRepository(self._conn)
        self.purchase_orders = PurchaseOrderRepository(self._conn)
        self.inventory = InventoryRepository(self._conn)
        self.audit = AuditRepository(self._conn)
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        try:
            if exc_type is not None or not self._committed:
                self._conn.rollback()
        finally:
            self._conn.close()

    def _bind_user(self) -> None:
        with self._conn.cursor() as cur:
            cur.execute("SELECT set_config('app.current_user_id', %s, true)", (str(self._user_id),))

    def commit(self) -> None:
        self._conn.commit()
        self._committed = True
        self._bind_user()

    def rollback(self) -> None:
        self._conn.rollback()
        self._committed = False
        self._bind_user()

    def savepoint(self, name: str) -> None:
        with self._conn.cursor() as cur:
            cur.execute(sql.SQL("SAVEPOINT {}").format(sql.Identifier(name)))

    def rollback_to(self, name: str) -> None:
        with self._conn.cursor() as cur:
            cur.execute(sql.SQL("ROLLBACK TO SAVEPOINT {}").format(sql.Identifier(name)))