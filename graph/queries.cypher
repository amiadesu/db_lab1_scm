MATCH (p:Product {sku: 'EL-SSD-512'})
CREATE (s:Supplier {id: 900001, name: 'ТОВ «Демо Постач»', country: 'UA', rating: 4.2, leadTimeDays: 5})
CREATE (s)-[:SUPPLIES {price: 1300.0, minQty: 5}]->(p)
RETURN s, p;

MATCH (s:Supplier {name: 'ТОВ «Демо Постач»'}) RETURN s;

MATCH (s:Supplier {id: 900001})-[r:SUPPLIES]->(:Product {sku: 'EL-SSD-512'})
SET s.rating = 4.5, r.price = 1250.0
RETURN s.name, s.rating, r.price;

// MERGE створює вузол лише якщо його ще немає, тож повторний запуск не дублює дані
MERGE (c:Category {id: 900001})
ON CREATE SET c.name = 'Демо-категорія', c.created = datetime()
ON MATCH SET c.seen = datetime()
RETURN c;

// звичайний DELETE відмовить, якщо у вузла є зв'язки; DETACH видаляє їх разом із вузлом
MATCH (n) WHERE n.id = 900001 AND (n:Supplier OR n:Category) DETACH DELETE n;

// аналог fn_best_suppliers з ЛР1
MATCH (s:Supplier)-[r:SUPPLIES]->(p:Product {sku: 'EL-SSD-512'})
RETURN s.name AS supplier, r.price AS price, s.leadTimeDays AS days, s.rating AS rating
ORDER BY price, days, rating DESC;

MATCH (s:Supplier)-[:SUPPLIES]->(p:Product)
RETURN s.name AS supplier, count(p) AS products, round(avg(p.price), 2) AS avgPrice
ORDER BY products DESC LIMIT 10;

MATCH (p:Product)-[:IN_CATEGORY]->(c:Category)
RETURN c.name AS category, count(p) AS products, collect(p.sku)[0..3] AS examples
ORDER BY products DESC LIMIT 10;

// *0.. - ланцюжок CHILD_OF будь-якої довжини, включно з нульовою (сама «Електроніка»);
// у SQL для цього потрібен рекурсивний CTE
MATCH (root:Category {name: 'Електроніка'})<-[:CHILD_OF*0..]-(c:Category)<-[:IN_CATEGORY]-(p:Product)
RETURN c.name AS category, count(p) AS products ORDER BY products DESC;

// корінь - категорія без батька; nodes(path)[1..] пропускає сам товар
MATCH path = (:Product {sku: 'EL-SSD-512'})-[:IN_CATEGORY]->(:Category)-[:CHILD_OF*0..]->(root:Category)
WHERE NOT (root)-[:CHILD_OF]->()
RETURN [n IN nodes(path)[1..] | n.name] AS breadcrumbs;

// товари з єдиним постачальником - ризик для ланцюга постачання
MATCH (p:Product)<-[:SUPPLIES]-(s:Supplier)
WITH p, collect(s) AS suppliers
WHERE size(suppliers) = 1
RETURN p.sku, p.name, suppliers[0].name AS onlySupplier LIMIT 20;

// які товари залишаться без постачальника, якщо цей постачальник зникне, і чиї замовлення це зачепить;
// OPTIONAL MATCH залишає товар у результаті, навіть якщо замовлень на нього немає
MATCH (s:Supplier {name: 'Shenzhen Parts Co.'})-[:SUPPLIES]->(p:Product)
WHERE NOT EXISTS { MATCH (p)<-[:SUPPLIES]-(other:Supplier) WHERE other <> s }
OPTIONAL MATCH (c:Customer)-[:PLACED]->(o:SalesOrder)-[:CONTAINS]->(p)
RETURN p.sku AS product, collect(DISTINCT o.number) AS orders, collect(DISTINCT c.name) AS customers;

// конкуренти: хто ще постачає ті самі товари
MATCH (s:Supplier {name: 'ТОВ «ТехноПостач»'})-[:SUPPLIES]->(p:Product)<-[:SUPPLIES]-(alt:Supplier)
RETURN alt.name AS alternative, count(p) AS commonProducts, collect(p.sku) AS products
ORDER BY commonProducts DESC;

// без стрілки зв'язки проходяться в обидва боки; *..10 обмежує глибину пошуку
MATCH (a:Supplier {name: 'ТОВ «ТехноПостач»'}), (b:Supplier {name: 'ChemClean GmbH'})
MATCH path = shortestPath((a)-[:SUPPLIES|IN_CATEGORY|CHILD_OF*..10]-(b))
RETURN [n IN nodes(path) | coalesce(n.sku, n.name)] AS route, length(path) AS hops;

// рекомендація: інші товари з категорій, де клієнт уже купував, крім уже куплених
MATCH (c:Customer {name: 'ФОП Бондаренко'})-[:PLACED]->(:SalesOrder)-[:CONTAINS]->(p:Product)
MATCH (p)-[:IN_CATEGORY]->(cat:Category)<-[:IN_CATEGORY]-(rec:Product)
WHERE NOT (c)-[:PLACED]->(:SalesOrder)-[:CONTAINS]->(rec)
RETURN rec.sku, rec.name, rec.price, cat.name AS sameCategoryAs
ORDER BY rec.price LIMIT 10;

// OPTIONAL MATCH: якщо товару на складі немає, onHand буде null, а рядок не зникне
MATCH (o:SalesOrder)-[:SHIPS_FROM]->(w:Warehouse), (o)-[x:CONTAINS]->(p:Product)
OPTIONAL MATCH (w)-[st:STOCKS]->(p)
RETURN o.number, w.code, p.sku, x.qty AS ordered, st.onHand AS onHand, st.reserved AS reserved;

PROFILE MATCH (p:Product {sku: 'EL-SSD-512'})<-[:SUPPLIES]-(s) RETURN s.name;
