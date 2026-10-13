from __future__ import annotations

import json
from typing import Any, Optional, Sequence

from psycopg2.extensions import connection as PgConnection
from psycopg2.extras import RealDictCursor
from psycopg2 import sql

from .models import (ChangeRecord, DeletedRecord, Product, PurchaseOrder, PurchaseOrderItem,
                     ReorderRecommendation, StockLevel, Supplier, SupplierPerformance)


class BaseRepository:
    def __init__(self, conn: PgConnection):
        self._conn = conn

    def _query_view(self, view: str, where: Optional[dict[str, Any]] = None,
                    order_by: Optional[str] = None) -> list[dict]:
        where = where or {}
        query = sql.SQL("SELECT * FROM scm.{}").format(sql.Identifier(view))
        if where:
            query += sql.SQL(" WHERE ") + sql.SQL(" AND ").join(
                sql.SQL("{} = %s").format(sql.Identifier(k)) for k in where)
        if order_by:
            query += sql.SQL(" ORDER BY {}").format(sql.Identifier(order_by))
        with self._conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(query, list(where.values()))
            return [dict(r) for r in cur.fetchall()]

    def _call(self, procedure: str, args: Sequence[Any] = (), out_params: int = 0) -> Optional[dict]:
        # out_params - кількість INOUT-параметрів у кінці процедури, їх значення повертаються словником
        placeholders = [sql.Placeholder()] * len(args) + [sql.SQL("NULL")] * out_params
        query = sql.SQL("CALL scm.{}({})").format(sql.Identifier(procedure),
                                                 sql.SQL(", ").join(placeholders))
        with self._conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(query, list(args))
            return dict(cur.fetchone()) if out_params else None


class SupplierRepository(BaseRepository):
    def get_all(self) -> list[Supplier]:
        return [Supplier.from_row(r) for r in self._query_view("v_suppliers_active", order_by="name")]

    def get_by_id(self, supplier_id: int) -> Optional[Supplier]:
        rows = self._query_view("v_suppliers_active", {"supplier_id": supplier_id})
        return Supplier.from_row(rows[0]) if rows else None

    def add(self, s: Supplier) -> int:
        out = self._call("sp_supplier_create",
                         (s.name, s.tax_code, s.city_id, s.street, s.building, s.email, s.phone,
                          s.lead_time_days),
                         out_params=1)
        s.supplier_id = out["p_supplier_id"]
        return s.supplier_id

    def update(self, s: Supplier) -> None:
        self._call("sp_supplier_update",
                   (s.supplier_id, s.name, s.city_id, s.email, s.phone, s.rating, s.lead_time_days))

    def set_bank_details(self, supplier_id: int, bank_name: str, iban: str,
                         swift_code: Optional[str] = None, currency: str = "UAH") -> None:
        self._call("sp_supplier_set_bank_details", (supplier_id, bank_name, iban, swift_code, currency))

    def link_product(self, supplier_id: int, product_id: int, price, min_order_qty: int = 1,
                     supplier_sku: Optional[str] = None) -> None:
        self._call("sp_supplier_product_upsert", (supplier_id, product_id, price, min_order_qty, supplier_sku))

    def delete(self, supplier_id: int) -> None:  # soft delete
        self._call("sp_supplier_soft_delete", (supplier_id,))

    def restore(self, supplier_id: int) -> None:
        self._call("sp_supplier_restore", (supplier_id,))

    def get_performance(self) -> list[SupplierPerformance]:
        return [SupplierPerformance.from_row(r)
                for r in self._query_view("v_supplier_performance", order_by="supplier_id")]


class ProductRepository(BaseRepository):
    def get_all(self) -> list[Product]:
        return [Product.from_row(r) for r in self._query_view("v_products_active", order_by="sku")]

    def get_by_id(self, product_id: int) -> Optional[Product]:
        rows = self._query_view("v_products_active", {"product_id": product_id})
        return Product.from_row(rows[0]) if rows else None

    def add(self, p: Product) -> int:
        out = self._call("sp_product_create",
                         (p.sku, p.name, p.category_id, p.uom, p.unit_price, p.reorder_level,
                          json.dumps(p.attributes), p.description),
                         out_params=1)
        p.product_id = out["p_product_id"]
        return p.product_id

    def update(self, p: Product) -> None:
        self._call("sp_product_update", (p.product_id, p.name, p.unit_price, p.reorder_level))

    def set_attribute(self, product_id: int, name: str, value: Optional[str]) -> None:
        self._call("sp_product_set_attribute", (product_id, name, value))

    def delete(self, product_id: int) -> None:  # soft delete
        self._call("sp_product_soft_delete", (product_id,))

    def restore(self, product_id: int) -> None:
        self._call("sp_product_restore", (product_id,))


class PurchaseOrderRepository(BaseRepository):
    def get_by_id(self, po_id: int) -> Optional[PurchaseOrder]:
        rows = self._query_view("v_purchase_orders", {"po_id": po_id})
        if not rows:
            return None
        po = PurchaseOrder.from_row(rows[0])
        po.items = [PurchaseOrderItem.from_row(r)
                    for r in self._query_view("v_purchase_order_items", {"po_id": po_id}, "po_item_id")]
        return po

    def get_by_supplier(self, supplier_id: int) -> list[PurchaseOrder]:
        return [PurchaseOrder.from_row(r)
                for r in self._query_view("v_purchase_orders", {"supplier_id": supplier_id}, "po_id")]

    def create(self, supplier_id: int, warehouse_id: int, expected_date=None) -> tuple[int, str]:
        out = self._call("sp_po_create", (supplier_id, warehouse_id, expected_date), out_params=2)
        return out["p_po_id"], out["p_po_number"]

    def add_item(self, po_id: int, product_id: int, quantity: int, unit_price=None) -> None:
        self._call("sp_po_add_item", (po_id, product_id, quantity, unit_price))

    def set_status(self, po_id: int, status: str) -> None:
        self._call("sp_po_set_status", (po_id, status))

    def receive(self, po_id: int, product_id: Optional[int] = None, quantity: Optional[int] = None) -> None:
        self._call("sp_po_receive", (po_id, product_id, quantity))


class InventoryRepository(BaseRepository):
    def get_stock(self, warehouse_id: Optional[int] = None) -> list[StockLevel]:
        where = {"warehouse_id": warehouse_id} if warehouse_id is not None else None
        return [StockLevel.from_row(r) for r in self._query_view("v_stock_levels", where, "sku")]

    def adjust(self, warehouse_id: int, product_id: int, quantity: int, note: str) -> None:
        self._call("sp_inventory_adjust", (warehouse_id, product_id, quantity, note))

    def get_reorder_recommendations(self) -> list[ReorderRecommendation]:
        return [ReorderRecommendation.from_row(r)
                for r in self._query_view("v_reorder_recommendations", order_by="sku")]


class AuditRepository(BaseRepository):
    def history(self, table_name: str, record_id: int) -> list[ChangeRecord]:
        rows = self._query_view("v_change_history",
                                {"table_name": table_name, "record_id": str(record_id)}, "audit_id")
        return [ChangeRecord.from_row(r) for r in rows]

    def recycle_bin(self) -> list[DeletedRecord]:
        return [DeletedRecord.from_row(r) for r in self._query_view("v_recycle_bin", order_by="deleted_at")]