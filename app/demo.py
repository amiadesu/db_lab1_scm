from decimal import Decimal

from psycopg2 import Error as DbError

from .models import Product, Supplier
from .unit_of_work import UnitOfWork

ADMIN = 1  # admin
PURCHASER = 2  # ipetrenko
STOREKEEPER = 3  # okoval


def title(t: str) -> None:
    print(f"\n=== {t} " + "=" * max(0, 60 - len(t)))


def scenario_1_onboard_supplier_and_order() -> tuple[int, int, int]:
    title("1. Новий постачальник, товар і замовлення в одній транзакції")
    with UnitOfWork(user_id=PURCHASER) as uow:
        sup = Supplier(None, "ТОВ «Дніпро Логістик»", "40111224", city_id=5,
                       street="вул. Робоча", building="12", email="sales@dnipro-log.ua",
                       lead_time_days=3)
        uow.suppliers.add(sup)
        uow.suppliers.set_bank_details(sup.supplier_id, "Monobank",
                                       "UA26 3220 0100 0002 6201 2345 6789 0")

        prod = Product(None, "EL-HDMI-2M", "Кабель HDMI 2.1, 2 м", category_id=5, uom="pcs",
                       unit_price=Decimal("259.00"), reorder_level=30,
                       attributes={"version": "2.1", "length_m": 2},
                       description="Високошвидкісний кабель HDMI 2.1 для 8K")
        uow.products.add(prod)

        uow.suppliers.link_product(sup.supplier_id, prod.product_id, Decimal("140.00"), 20, "DL-HDMI2")
        uow.suppliers.link_product(sup.supplier_id, 1, Decimal("70.00"), 50)

        po_id, po_number = uow.purchase_orders.create(sup.supplier_id, warehouse_id=1)
        uow.purchase_orders.add_item(po_id, prod.product_id, 60)
        uow.purchase_orders.add_item(po_id, 1, 100)
        uow.purchase_orders.set_status(po_id, "approved")
        uow.purchase_orders.set_status(po_id, "sent")
        uow.commit()

        s = uow.suppliers.get_by_id(sup.supplier_id)
        print(f"{s.name}: {s.full_address}, реквізити={'так' if s.has_bank_details else 'ні'}")
        print("характеристики товару:", uow.products.get_by_id(prod.product_id).attributes)
        po = uow.purchase_orders.get_by_id(po_id)
        print(f"{po.po_number}: {po.supplier_name}, статус={po.status}, сума={po.total_amount}, "
              f"створив={po.created_by_login}")
        for it in po.items:
            print(f"   {it.sku:<12} {it.quantity:>4} x {it.unit_price:>8} = {it.line_total}")
        return sup.supplier_id, prod.product_id, po_id


def scenario_2_rollback(supplier_id: int) -> None:
    title("2. Відкат: soft delete постачальника з відкритим замовленням")
    with UnitOfWork(user_id=PURCHASER) as uow:
        try:
            uow.suppliers.update(Supplier(supplier_id, None, None, None, rating=Decimal("4.80")))
            print("   рейтинг оновлено в транзакції (ще не зафіксовано)")
            uow.suppliers.delete(supplier_id)  # відмова: у постачальника є відкрите замовлення
            uow.commit()
        except DbError as e:
            print("   БД відмовила:", e.diag.message_primary)
            uow.rollback()
        print("   рейтинг після rollback:", uow.suppliers.get_by_id(supplier_id).rating)


def scenario_3_receive(po_id: int, product_id: int) -> None:
    title("3. Приймання товару (часткове -> повне), оновлення залишків")
    with UnitOfWork(user_id=STOREKEEPER) as uow:
        uow.purchase_orders.receive(po_id, product_id, 40)
        uow.commit()
        print("   після часткового:", uow.purchase_orders.get_by_id(po_id).status)
        uow.purchase_orders.receive(po_id)
        uow.commit()
        po = uow.purchase_orders.get_by_id(po_id)
        print(f"   після повного: {po.status}, отримано {po.received_pct}%, змінив={po.updated_by_login}")
        for s in uow.inventory.get_stock(warehouse_id=1):
            flag = "  <- дозамовити" if s.needs_reorder else ""
            print(f"   {s.sku:<12} на складі={s.qty_on_hand:>4} резерв={s.qty_reserved:>3} "
                  f"доступно={s.qty_available:>4}{flag}")


def scenario_4_soft_delete_restore() -> None:
    title("4. Soft delete / restore та журнал змін")
    with UnitOfWork(user_id=ADMIN) as uow:
        sid = uow.suppliers.add(Supplier(None, "Тимчасовий постачальник", "99990000", city_id=9))
        uow.commit()
        uow.suppliers.delete(sid)
        uow.commit()
        print("   у списку активних:", uow.suppliers.get_by_id(sid) is not None)
        print("   у кошику:", [r["name"] for r in uow.audit.recycle_bin()])
        uow.suppliers.restore(sid)
        uow.commit()
        print("   після restore активний:", uow.suppliers.get_by_id(sid) is not None)
        for h in uow.audit.history("suppliers", sid):
            print(f"   {h['changed_at']:%H:%M:%S} {h['operation']:<8} {h['changed_by_login']:<6} "
                  f"{h['changed_fields'] or ''}")


def scenario_5_reports() -> None:
    title("5. Звіти з розрізів даних")
    with UnitOfWork(user_id=ADMIN) as uow:
        for r in uow.inventory.get_reorder_recommendations():
            print(f"   дозамовити {r['sku']:<12} x{r['suggested_qty']:<4} у {r['supplier_name']} "
                  f"по {r['purchase_price']}")
        for r in uow.suppliers.get_performance():
            print(f"   {r['name']:<25} замовлень={r['orders_total']} сума={r['total_spend']} "
                  f"вчасно={r['on_time_rate']}")

# Запуск: python -m app.demo
# Підключення задається змінною SCM_DSN, наприклад "dbname=db_lab1_scm user=postgres host=localhost"
if __name__ == "__main__":
    supplier_id, product_id, po_id = scenario_1_onboard_supplier_and_order()
    scenario_2_rollback(supplier_id)
    scenario_3_receive(po_id, product_id)
    scenario_4_soft_delete_restore()
    scenario_5_reports()