from __future__ import annotations

from dataclasses import dataclass, field, fields
from datetime import date, datetime
from decimal import Decimal
from typing import Any, Optional


def _from_row(cls, row: dict[str, Any]):
    # колонки view, яких немає в моделі, пропускаються
    names = {f.name for f in fields(cls)}
    return cls(**{k: v for k, v in row.items() if k in names})


@dataclass
class Supplier:
    supplier_id: Optional[int]
    name: str
    tax_code: str
    city_id: int
    street: Optional[str] = None
    building: Optional[str] = None
    email: Optional[str] = None
    phone: Optional[str] = None
    rating: Optional[Decimal] = None
    lead_time_days: int = 7
    city_name: Optional[str] = None
    country_code: Optional[str] = None
    full_address: Optional[str] = None
    primary_contact: Optional[str] = None
    has_bank_details: bool = False
    updated_at: Optional[datetime] = None
    updated_by_login: Optional[str] = None

    from_row = classmethod(_from_row)


@dataclass
class Product:
    product_id: Optional[int]
    sku: str
    name: str
    category_id: int
    uom: str
    unit_price: Decimal
    reorder_level: int = 0
    attributes: dict = field(default_factory=dict)
    description: Optional[str] = None
    category_name: Optional[str] = None
    total_on_hand: int = 0
    total_available: int = 0
    updated_at: Optional[datetime] = None
    updated_by_login: Optional[str] = None

    from_row = classmethod(_from_row)


@dataclass
class PurchaseOrderItem:
    po_item_id: int
    product_id: int
    sku: str
    product_name: str
    quantity: int
    unit_price: Decimal
    line_total: Decimal
    received_qty: int
    qty_outstanding: int

    from_row = classmethod(_from_row)


@dataclass
class PurchaseOrder:
    po_id: int
    po_number: str
    status: str
    order_date: date
    expected_date: Optional[date]
    supplier_id: int
    supplier_name: str
    warehouse_id: int
    warehouse_code: str
    total_amount: Decimal
    items_count: int
    received_pct: Decimal
    created_by_login: Optional[str] = None
    updated_at: Optional[datetime] = None
    updated_by_login: Optional[str] = None
    items: list[PurchaseOrderItem] = field(default_factory=list)

    from_row = classmethod(_from_row)


@dataclass
class StockLevel:
    warehouse_id: int
    warehouse_code: str
    product_id: int
    sku: str
    product_name: str
    qty_on_hand: int
    qty_reserved: int
    qty_available: int
    reorder_level: int
    needs_reorder: bool

    from_row = classmethod(_from_row)


@dataclass
class ReorderRecommendation:
    warehouse_id: int
    warehouse_code: str
    product_id: int
    sku: str
    product_name: str
    qty_available: int
    reorder_level: int
    suggested_qty: int
    supplier_id: Optional[int] = None
    supplier_name: Optional[str] = None
    purchase_price: Optional[Decimal] = None
    lead_time_days: Optional[int] = None

    from_row = classmethod(_from_row)


@dataclass
class SupplierPerformance:
    supplier_id: int
    name: str
    rating: Optional[Decimal]
    lead_time_days: int
    orders_total: int
    orders_received: int
    orders_cancelled: int
    total_spend: Decimal
    on_time_rate: Optional[Decimal]

    from_row = classmethod(_from_row)


@dataclass
class ChangeRecord:
    audit_id: int
    changed_at: datetime
    table_name: str
    record_id: str
    operation: str
    changed_by_login: Optional[str]
    changed_fields: Optional[dict]

    from_row = classmethod(_from_row)


@dataclass
class DeletedRecord:
    entity: str
    id: int
    name: str
    deleted_at: datetime
    deleted_by: Optional[int]

    from_row = classmethod(_from_row)