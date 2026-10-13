-- Заповнення таблиць початковими видуманими даними щоб у них було хоча б щось
SET search_path TO scm, public;

INSERT INTO roles(name, description) VALUES
 ('admin','Адміністратор системи'),
 ('purchaser','Менеджер із закупівель'),
 ('storekeeper','Комірник'),
 ('sales','Менеджер з продажу');

INSERT INTO users(role_id, login, last_name, first_name, middle_name, email) VALUES
 (1, 'admin', 'Адмін', 'Олена', 'Іванівна', 'admin@scm.ua'),
 (2, 'ipetrenko', 'Петренко', 'Іван', 'Олексійович', 'petrenko@scm.ua'),
 (3, 'okoval', 'Коваль', 'Оксана', NULL, 'koval@scm.ua'),
 (4, 'mshevchuk', 'Шевчук', 'Марія', 'Петрівна', 'shevchuk@scm.ua');

INSERT INTO countries VALUES ('UA','Україна'),('PL','Польща'),('DE','Німеччина'),('CN','Китай'),('TR','Туреччина');

INSERT INTO cities(country_code, name, region) VALUES
 ('UA', 'Київ', NULL),
 ('UA', 'Львів', 'Львівська обл.'),
 ('UA', 'Одеса', 'Одеська обл.'),
 ('UA', 'Харків', 'Харківська обл.'),
 ('UA', 'Дніпро', 'Дніпропетровська обл.'),
 ('PL', 'Варшава', 'Мазовецьке воєв.'),
 ('CN', 'Шеньчжень', 'Гуандун'),
 ('DE', 'Берлін', NULL),
 ('TR', 'Стамбул', NULL);

INSERT INTO units_of_measure(code,name) VALUES ('pcs','штука'),('kg','кілограм'),('box','коробка'),('l','літр');

INSERT INTO product_categories(name) VALUES ('Електроніка'),('Пакування'),('Побутова хімія');
INSERT INTO product_categories(parent_category_id,name) VALUES (1,'Комплектуючі'),(1,'Периферія');

-- Далі від імені ipetrenko
SELECT set_config('app.current_user_id', '2', false);

INSERT INTO warehouses(code,name,city_id,street,building,location,capacity_m3,manager_id) VALUES
 ('KYIV-01','Центральний склад',1,'вул. Складська','1',point(30.5234, 50.4501),5000,3),
 ('LVIV-01','Західний склад',   2,'вул. Городоцька','200',point(24.0297, 49.8397),2500,3);

CALL sp_supplier_create('ТОВ «ТехноПостач»','32157840',1,'просп. Перемоги','45','sales@techno.ua','+380441112233',5);
CALL sp_supplier_create('PolPack Sp. z o.o.','PL5260001234',6,'ul. Marszałkowska','10','office@polpack.pl','+48221234567',10);
CALL sp_supplier_create('Shenzhen Parts Co.','CN9144030012',7,'Huaqiang Rd','88','export@szparts.cn','+8675512345678',30);
CALL sp_supplier_create('ChemClean GmbH','DE811234567',8,'Friedrichstraße','5','info@chemclean.de','+49301234567',14);

CALL sp_supplier_set_bank_details(1,'ПриватБанк','UA21 3223 1300 0002 6007 2335 6600 1','PBANUA2X');
CALL sp_supplier_set_bank_details(2,'PKO BP','PL61109010140000071219812874','BPKOPLPW','PLN');

INSERT INTO supplier_contacts(supplier_id, last_name, first_name, middle_name, position, phone, email, is_primary) VALUES
 (1,'Мельник','Андрій','Петрович','Менеджер з продажу','+380671112233','melnyk@techno.ua',TRUE),
 (2,'Nowak','Piotr',NULL,'Account manager','+48501234567','nowak@polpack.pl',TRUE),
 (3,'Li','Wei',NULL,'Sales','+8613800000000','li.wei@szparts.cn',TRUE),
 (4,'Schmidt','Anna',NULL,'Vertrieb','+491701234567','schmidt@chemclean.de',TRUE);

CALL sp_product_create('EL-USB-C-1M','Кабель USB-C 1 м',5,'pcs',149.00,50,'{"color":"black","length_m":"1"}','Кабель для заряджання та передачі даних USB-C - USB-C');
CALL sp_product_create('EL-SSD-512','SSD накопичувач 512 ГБ',4,'pcs',1899.00,10,'{"interface":"NVMe","capacity_gb":"512"}','Твердотільний накопичувач M.2 NVMe');
CALL sp_product_create('EL-MOUSE-W','Миша бездротова',5,'pcs',499.00,20,'{"color":"white","wireless":"true"}','Бездротова оптична миша 2.4 ГГц');
CALL sp_product_create('PK-BOX-M','Коробка картонна 40x30x30',2,'pcs',18.50,200,'{"size":"M"}','Гофрокартон, тришаровий');
CALL sp_product_create('PK-TAPE-48','Скотч пакувальний 48 мм',2,'pcs',35.00,100,'{}','Прозора пакувальна стрічка');
CALL sp_product_create('CH-GEL-5L','Гель для миття підлоги 5 л',3,'l',289.00,15,'{"volume_l":"5"}','Концентрований засіб для професійного прибирання');

CALL sp_supplier_product_upsert(1,1,95.00,10,'TP-USBC1');
CALL sp_supplier_product_upsert(3,1,62.00,100,'SZ-C1M');
CALL sp_supplier_product_upsert(1,2,1450.00,1,'TP-SSD512');
CALL sp_supplier_product_upsert(3,2,1210.00,20,'SZ-SSD512');
CALL sp_supplier_product_upsert(1,3,310.00,5,'TP-MW');
CALL sp_supplier_product_upsert(2,4,9.80,100,'PP-BOXM');
CALL sp_supplier_product_upsert(2,5,21.00,50,'PP-TAPE48');
CALL sp_supplier_product_upsert(4,6,180.00,10,'CC-GEL5');

INSERT INTO customers(name,tax_code,city_id,street,building,email,phone,credit_limit) VALUES
 ('ФОП Бондаренко','3012345670',3,'вул. Дерибасівська','12','bondarenko@gmail.com','+380501234567',50000),
 ('ТОВ «Ритейл Плюс»','38765439',4,'вул. Сумська','100','buy@retailplus.ua','+380577654321',300000);

INSERT INTO carriers(name,transport_mode,phone,email) VALUES
 ('Нова Пошта','road','0800500609','b2b@novaposhta.ua'),
 ('Укрзалізниця Вантаж','rail','0800503111','cargo@uz.gov.ua'),
 ('DHL Express','air','+380445001500','ua@dhl.com');

INSERT INTO carrier_contracts(carrier_id, valid_period, rate_per_kg) VALUES
 (1, daterange('2026-01-01','2026-07-01'), 12.50),
 (1, daterange('2026-07-01','2027-01-01'), 13.20),
 (2, daterange('2026-01-01','2027-01-01'), 4.10),
 (3, daterange('2026-03-01','2027-03-01'), 95.00);

-- purchase_orders, отримане повністю
DO $$
DECLARE v_po INT; v_num VARCHAR;
BEGIN
    CALL sp_po_create(1, 1, NULL, v_po, v_num);
    CALL sp_po_add_item(v_po, 1, 100);
    CALL sp_po_add_item(v_po, 2, 15);
    CALL sp_po_add_item(v_po, 3, 40);
    CALL sp_po_set_status(v_po, 'approved');
    CALL sp_po_set_status(v_po, 'sent');
    CALL sp_po_receive(v_po);
END $$;

-- purchase_orders, отримане частково
DO $$
DECLARE v_po INT; v_num VARCHAR;
BEGIN
    CALL sp_po_create(2, 2, NULL, v_po, v_num);
    CALL sp_po_add_item(v_po, 4, 500);
    CALL sp_po_add_item(v_po, 5, 100);
    CALL sp_po_set_status(v_po, 'approved');
    CALL sp_po_set_status(v_po, 'sent');
    CALL sp_po_receive(v_po, 4, 300);
END $$;

-- purchase_orders у статусі draft
DO $$
DECLARE v_po INT; v_num VARCHAR;
BEGIN
    CALL sp_po_create(4, 1, NULL, v_po, v_num);
    CALL sp_po_add_item(v_po, 6, 30);
END $$;

-- Далі від імені okoval (комірник): коригування inventory
SELECT set_config('app.current_user_id', '3', false);
CALL sp_inventory_adjust(2, 4, -2, 'Інвентаризація: пошкоджено при розвантаженні');

-- Далі від імені mshevchuk (менеджер з продажу): sales_orders і shipments
SELECT set_config('app.current_user_id', '4', false);
DO $$
DECLARE v_so INT; v_num VARCHAR; v_sh INT;
BEGIN
    CALL sp_so_create(2, 1, CURRENT_DATE + 3, v_so, v_num);
    CALL sp_so_add_item(v_so, 1, 60, 5);
    CALL sp_so_add_item(v_so, 2, 8);
    CALL sp_shipment_create(v_so, 1, '20450000123456', 350, v_sh);

    CALL sp_so_create(1, 1, NULL, v_so, v_num);
    CALL sp_so_add_item(v_so, 3, 25);
END $$;

SELECT set_config('app.current_user_id', '', false);
CALL sp_refresh_reports();

CLUSTER inventory_movements;
ANALYZE;
