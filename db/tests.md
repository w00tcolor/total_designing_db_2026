# Протокол для самопроверки

Заполняется по желанию. 

По данному протоколу работа будет проверяться преподавателем.

**Если на каком-то этапе функционал оказывается нерабочим, значит учащийся проигнорировал обязательное тестирование и работа может быть отправлена на доработку без проверки и комментариев или по работе может быть проставлен незачет, если лимит доработок исчерпан.**

## Окружение

| Параметр | Значение |
|---|---|
| PostgreSQL version | `SELECT version();` → `PostgreSQL 18.4 on x86_64-windows, compiled by msvc-19.44.35227, 64-bit` |
| Дата проверки | 2026-11-13 |
| Схема | `tsys_food` |
| Роль-аудитор | `inspector` |

Все проверки — под `inspector`, если не указано иное.

Заполняй «Факт» и «Вердикт» по каждой проверке. «Вердикт»: `OK` / `FAIL: <что именно>`.

> Как выполнялся прогон: на чистую БД (со схемой `exts` и `uuid-ossp`) восстановлен `db/foodexpress_tsys.backup` (структура схемы + тестовые данные `insert_test_data(10)`), применён `db/schema/grants.sql`. Затем все SQL-блоки этого протокола выполнены **дословно и по порядку** одним файлом через `psql`. Подставлены только плейсхолдеры: `<фамилия>` → `tsys`, `<product_id>` → id из первого запроса E.3, `<review_id>` → id вставленного в E.3 отзыва. В E.2 вместо комментария `-- остальные аргументы` переданы остальные аргументы. Данные генерируются случайно, поэтому конкретные суммы и id при повторном прогоне будут другими.

---

## A. Подготовка

### A.1. Восстановление бэкапа

Ожидается: без ошибок.
Факт: `pg_restore -d food2 --exit-on-error db/foodexpress_tsys.backup` → код возврата 0, ошибок нет; `psql -d food2 -f db/schema/grants.sql` → код возврата 0.

Требования к окружению восстановления:
- `pg_restore` версии **17 или новее**: архив снят `pg_dump` 18 (формат архива 1.16). Если у проверяющего PostgreSQL 15/16, схема разворачивается скриптом `psql -d <db> -f db/schema/foodexpress.sql`, результат тот же.
- В архиве записан владелец объектов `postgres` (для формата `-Fc` ключ `pg_dump -O` не действует). Если в кластере нет роли `postgres`, восстанавливать с `pg_restore --no-owner`.
Вердикт: OK

### A.2. Переключение на inspector

```sql
SET ROLE inspector;
SET search_path TO tsys_food, exts;
SELECT current_user;
```

Ожидается: `inspector`.
Факт: `inspector`
Вердикт: OK

---

## B. FOOD-101: Структура схемы

### B.1. Схема существует

```sql
SELECT schema_name FROM information_schema.schemata
WHERE schema_name LIKE '%_food';
```

Ожидается: `tsys_food`.
Факт: `tsys_food`
Вердикт: OK

### B.2. Схема `exts` с `uuid-ossp`

```sql
SELECT extname, extnamespace::regnamespace AS schema
FROM pg_extension WHERE extname = 'uuid-ossp';
```

Ожидается: `uuid-ossp`, схема `exts`.
Факт: `uuid-ossp | exts`
Вердикт: OK

### B.3. Все 12 исходных таблиц + N после нормализации

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'tsys_food'
ORDER BY table_name;
```

Ожидается: `address`, `client`, `client_address`, `courier`, `courier_pay`, `order`, `order_structure`, `payment`, `product`, `product_category`, `restaurant`, `review` (12 + N штук).
Факт: 13 строк: `address`, `client`, `client_address`, `courier`, `courier_pay`, `how_much_money`, `order`, `order_structure`, `payment`, `product`, `product_category`, `restaurant`, `review`. Все 12 таблиц ERD на месте, дополнительных таблиц нормализация не потребовала. Тринадцатая строка — представление `how_much_money` (FOOD-108), `information_schema.tables` выводит и представления.
Вердикт: OK

### B.4. Все PK — `uuid`

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'tsys_food'
  AND column_name LIKE '%_id'
  AND data_type != 'uuid';
```

Ожидается: пусто.
Факт: `(0 строк)`
Вердикт: OK

### B.5. Enum-типы

```sql
SELECT t.typname, array_agg(e.enumlabel ORDER BY e.enumsortorder) AS values
FROM pg_type t
JOIN pg_enum e ON t.oid = e.enumtypid
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'tsys_food'
GROUP BY t.typname
ORDER BY t.typname;
```

Ожидается: 8 типов со значениями из constraints.md.
Факт: 8 строк:

| typname | values |
|---|---|
| courier_status | {свободен,занят,на_доставке,уволен} |
| order_pay_status | {ожидает,оплачен,ошибка} |
| order_status | {создан,готовится,в_доставке,доставлен,отменён} |
| payment_status | {успех,ошибка,в_обработке} |
| payment_type | {карта,наличные,безнал} |
| product_status | {доступно,нет_в_наличии,архив} |
| restaurant_status | {активен,неактивен} |
| review_entity_type | {блюдо,ресторан,заказ} |

Вердикт: OK

### B.6. FK-ограничения

```sql
SELECT conname, conrelid::regclass AS tbl, confrelid::regclass AS ref
FROM pg_constraint
WHERE contype = 'f'
  AND connamespace = 'tsys_food'::regnamespace
ORDER BY tbl, conname;
```

Ожидается: не менее 15 FK, все из erd.md.
Факт: 16 FK: `client_address_address_fk`, `client_address_client_fk`, `courier_pay_courier_fk`, `order_address_fk`, `order_client_address_fk` (составной, BR-7.4), `order_client_fk`, `order_courier_fk`, `order_restaurant_fk`, `order_structure_order_fk`, `order_structure_product_fk`, `payment_order_fk`, `product_category_fk`, `product_restaurant_fk`, `restaurant_address_fk`, `review_client_fk`, `review_order_fk`. Все 15 связей ERD присутствуют.
Вердикт: OK

### B.7. Пароль — MD5

```sql
SELECT length(password) AS len, password
FROM client LIMIT 5;
```

Ожидается: `len = 32`, hex-строка.
Факт: `32 | d96b72c9677214aa97f092b53ed21140`, `32 | 7e5b1c3b468e4e75563709abb1c603bb`, `32 | 36b2f97fd18cea1542a2cb4c84867238`, `32 | 7a6e5f759d3c6b45f5d7f6dcba349c0c`, `32 | c0344be8f2e9205456b154495750cd9d`. Бэкап содержит тестовые данные (`insert_test_data(10)`), поэтому B.7 проверяется сразу после восстановления, до C.1.
Вердикт: OK

---

## C. FOOD-102: `insert_test_data(value)`

### C.1. Чистая схема

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.
Факт: `CALL`
Вердикт: OK

### C.2. Первый запуск

```sql
CALL insert_test_data(10);
```

Ожидается: без ошибок.
Факт: `CALL`
Вердикт: OK

### C.3. Распределение строк (BR-11.7)

```sql
SELECT 'client' AS tbl, count(*) FROM client
UNION ALL SELECT 'courier', count(*) FROM courier
UNION ALL SELECT 'product_category', count(*) FROM product_category
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
UNION ALL SELECT 'address', count(*) FROM address
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'order', count(*) FROM "order"
UNION ALL SELECT 'review', count(*) FROM review
UNION ALL SELECT 'payment', count(*) FROM payment
ORDER BY tbl;
```

Ожидается: 10, 10, 10, 10, 50, 50, 50, 50, 50.
Факт: address 50, client 10, courier 10, order 50, payment 50, product 50, product_category 10, restaurant 10, review 50.
Вердикт: OK

### C.4. Адреса ресторанов vs клиентов (BR-11.7)

```sql
SELECT 'restaurant addresses' AS cat, count(*) FROM restaurant WHERE address_id IS NOT NULL
UNION ALL
SELECT 'total addresses', count(*) FROM address;
```

Ожидается: 10 ресторанных адресов, 50 всего → 40 клиентских.
Факт: `restaurant addresses | 10`, `total addresses | 50`
Вердикт: OK

### C.5. Нет пустых строк (BR-11.3)

```sql
SELECT count(*) FROM client WHERE login = '' OR password = '' OR phone_number = '';
-- и аналогично для других varchar-полей с NOT NULL
```

Ожидается: 0.
Факт: `0`. Для остальных строковых полей пустые строки исключены CHECK-ограничениями `btrim(...) <> ''` (см. constraints.md).
Вердикт: OK

### C.6. Нет NULL там, где запрещено (BR-11.3)

```sql
SELECT count(*) FROM "order" WHERE client_id IS NULL OR restaurant_id IS NULL
  OR courier_id IS NULL OR address_id IS NULL OR total_amount IS NULL;
-- и аналогично для других NOT NULL полей
```

Ожидается: 0.
Факт: `0`
Вердикт: OK

### C.7. Минимум один активный курьер (BR-6.6)

```sql
SELECT count(*) FROM courier WHERE status != 'уволен';
```

Ожидается: `>= 1`.
Факт: `8`
Вердикт: OK

### C.8. `courier_pay` консистентен с правилами (BR-10.2)

```sql
SELECT cp.year, cp.month, cp.courier_id, cp.amount, cp.coefficient_used,
       round(coalesce((
           SELECT sum(o.commission)
           FROM "order" o
           WHERE o.courier_id = cp.courier_id
             AND o.status = 'доставлен'
             AND extract(year  from o.order_timestamp) = cp.year
             AND extract(month from o.order_timestamp) = cp.month
       ), 0) * cp.coefficient_used, 2) AS expected_amount
FROM courier_pay cp
LIMIT 20;
```

Ожидается: `amount = expected_amount` в каждой строке.
Факт: 20 строк, во всех `amount = expected_amount`, расхождений 0. Пример: `2026 | 9 | 9c594077-… | 95.76 | 0.1 | 95.76`, `2026 | 7 | 820870b9-… | 92.10 | 0.1 | 92.10`; в месяцы без доставок — `0.00 = 0.00`.
Вердикт: OK

### C.9. Повторный вызов не ломает

```sql
DO $$
BEGIN
    FOR i IN 1..10 LOOP
        CALL insert_test_data(10);
    END LOOP;
END $$;
```

Ожидается: без ошибок, данные добавляются или заменяются (по решению студента, задокументированному в constraints.md).
Факт: `DO`, без ошибок. Данные **добавляются**: после цикла в `product` 550 строк (50 + 10 × 50). Решение описано в constraints.md (FOOD-102).
Вердикт: OK

---

## D. Проверки бизнес-правил на сгенерированных данных

### D.1. Все FK валидны (нет orphans)

```sql
SELECT 'order_structure → order' AS fk, count(*) AS orphans
FROM order_structure os
LEFT JOIN "order" o ON os.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'order_structure → product', count(*)
FROM order_structure os
LEFT JOIN product p ON os.product_id = p.product_id
WHERE p.product_id IS NULL
UNION ALL
SELECT 'payment → order', count(*)
FROM payment pmt
LEFT JOIN "order" o ON pmt.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'review → order', count(*)
FROM review r
LEFT JOIN "order" o ON r.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'courier_pay → courier', count(*)
FROM courier_pay cp
LEFT JOIN courier c ON cp.courier_id = c.courier_id
WHERE c.courier_id IS NULL
UNION ALL
SELECT 'client_address → client', count(*)
FROM client_address ca
LEFT JOIN client c ON ca.client_id = c.client_id
WHERE c.client_id IS NULL
UNION ALL
SELECT 'client_address → address', count(*)
FROM client_address ca
LEFT JOIN address a ON ca.address_id = a.address_id
WHERE a.address_id IS NULL;
```

Ожидается: все 0.
Факт: все 7 строк — `0`.
Вердикт: OK

### D.2. Минимальная сумма заказа (BR-1.8)

```sql
SELECT count(*) FROM "order" WHERE total_amount < 1000;
```

Ожидается: 0.
Факт: `0`
Вердикт: OK

### D.3. Комиссия = 10% (BR-1.4)

```sql
SELECT count(*) FROM "order" WHERE round(order_amount * 0.10, 2) != commission;
```

Ожидается: 0.
Факт: `0`
Вердикт: OK

### D.4. `total_amount = order_amount + commission`

```sql
SELECT count(*) FROM "order"
WHERE round(order_amount + commission, 2) != total_amount;
```

Ожидается: 0.
Факт: `0`
Вердикт: OK

### D.5. Дата доставки не раньше создания (BR-7.13)

```sql
SELECT count(*) FROM "order"
WHERE delivery_timestamp IS NOT NULL AND delivery_timestamp < order_timestamp;
```

Ожидается: 0.
Факт: `0`
Вердикт: OK

### D.6. Адрес доставки принадлежит клиенту (BR-7.4)

```sql
SELECT count(*) FROM "order" o
LEFT JOIN client_address ca
  ON ca.client_id = o.client_id AND ca.address_id = o.address_id
WHERE ca.client_id IS NULL;
```

Ожидается: 0.
Факт: `0`
Вердикт: OK

### D.7. Все блюда в заказе из одного ресторана (BR-7.3)

```sql
SELECT count(DISTINCT os.order_id)
FROM order_structure os
JOIN "order" o ON os.order_id = o.order_id
JOIN product p ON os.product_id = p.product_id
WHERE p.restaurant_id != o.restaurant_id;
```

Ожидается: 0.
Факт: `0`
Вердикт: OK

### D.8. Ровно одна успешная оплата на заказ (BR-8.1)

```sql
SELECT order_id, count(*) AS cnt
FROM payment
WHERE status = 'успех'
GROUP BY order_id
HAVING count(*) != 1;
```

Ожидается: пусто.
Факт: `(0 строк)`
Вердикт: OK

### D.9. Сумма оплаты = `total_amount` заказа (BR-8.4)

```sql
SELECT count(*) FROM payment p
JOIN "order" o ON p.order_id = o.order_id
WHERE p.amount != o.total_amount;
```

Ожидается: 0.
Факт: `0`
Вердикт: OK

### D.10. Нет дубликатов в `client_address` (BR-2.5)

```sql
SELECT client_id, address_id, count(*)
FROM client_address
GROUP BY client_id, address_id
HAVING count(*) > 1;
```

Ожидается: пусто.
Факт: `(0 строк)`
Вердикт: OK

### D.11. Нет дубликатов в `order_structure` (BR-7.16)

```sql
SELECT order_id, product_id, count(*)
FROM order_structure
GROUP BY order_id, product_id
HAVING count(*) > 1;
```

Ожидается: пусто.
Факт: `(0 строк)`
Вердикт: OK

### D.12. `work_end > work_start` (BR-4.4)

```sql
SELECT count(*) FROM restaurant WHERE work_end <= work_start;
```

Ожидается: 0.
Факт: `0`
Вердикт: OK

### D.13. `dismissal_date >= hire_date` (BR-6.3)

```sql
SELECT count(*) FROM courier
WHERE dismissal_date IS NOT NULL AND dismissal_date < hire_date;
```

Ожидается: 0.
Факт: `0`
Вердикт: OK

### D.14. Рейтинг блюд/ресторанов соответствует отзывам (BR-9.6)

```sql
-- product.rating = AVG(review.rating) по отзывам на блюдо
SELECT p.product_id, p.rating,
       (SELECT round(avg(r.rating), 2) FROM review r
        WHERE r.entity_type = 'блюдо' AND r.entity_id = p.product_id) AS expected
FROM product p
WHERE p.rating IS NOT NULL
LIMIT 20;
```

Ожидается: `rating = expected`.
Факт: 20 строк, во всех `rating = expected` (например, `3.00 | 3.00`, `4.00 | 4.00`, `5.00 | 5.00`), расхождений 0.
Вердикт: OK

---

## E. Функции и процедуры

### E.1. `add_product` — успешный вызов

```sql
SELECT count(*) AS before FROM product;

CALL add_product(
    p_restaurant_id => (SELECT restaurant_id FROM restaurant LIMIT 1),
    p_product_category_id => (SELECT product_category_id FROM product_category LIMIT 1),
    p_name => 'Тестовое блюдо',
    p_price => 250,
    p_rating => 4.5,
    p_status => 'доступно',
    p_description => 'Описание'
    -- + photo_url если есть
);

SELECT count(*) AS after FROM product;
```

Ожидается: `after = before + 1`.
Факт: `before = 550`;
```
ERROR:  cannot use subquery in CALL argument
LINE 2:     p_restaurant_id => (SELECT restaurant_id FROM restaurant...
```
`after = 550`.

Эту ошибку выдаёт **синтаксический анализатор PostgreSQL** ещё до того, как процедура начинает выполняться: в аргументах `CALL` подзапросы запрещены (`EXPR_KIND_CALL_ARGUMENT`). Проверено на PostgreSQL 18.4: та же ошибка возникает и с «пустой» процедурой `CREATE PROCEDURE p(x uuid) … ; CALL p((SELECT …))`. Исправить это реализацией `add_product` нельзя: сигнатура (процедура, параметры `p_restaurant_id`, `p_product_category_id`, `p_name`, `p_price`, `p_rating`, `p_status`, `p_description`, `p_photo_url`) совпадает с шаблоном, но вызов отклоняется раньше.

Тот же вызов с теми же значениями, вычисленными заранее, проходит:

```sql
SELECT restaurant_id AS rid FROM restaurant LIMIT 1 \gset
SELECT product_category_id AS cid FROM product_category LIMIT 1 \gset
CALL add_product(p_restaurant_id => :'rid', p_product_category_id => :'cid',
                 p_name => 'Тестовое блюдо', p_price => 250, p_rating => 4.5,
                 p_status => 'доступно', p_description => 'Описание');
```

Результат (отдельный запуск на БД после раздела I, где в `product` 50 строк): `before = 50`, `NOTICE: add_product: добавлено блюдо 845f98d3-…`, `CALL`, `after = 51`, то есть `after = before + 1`.
Вердикт: FAIL (запрос в исходном виде отклоняет PostgreSQL, процедура до вызова не доходит; с заранее вычисленными аргументами — OK)

### E.2. `add_product` — падает на несуществующий ресторан

```sql
CALL add_product(
    p_restaurant_id => '00000000-0000-0000-0000-000000000000',
    -- остальные аргументы
);
```

Остальные аргументы: `p_product_category_id => '00000000-0000-0000-0000-000000000001', p_name => 'X', p_price => 100, p_description => 'd'`.

Ожидается: ошибка с внятным сообщением.
Факт:
```
ERROR:  add_product: ресторан с restaurant_id = 00000000-0000-0000-0000-000000000000 не существует
HINT:  BR-5.1: блюдо принадлежит существующему ресторану
```
Аналогично: несуществующая категория → `add_product: категория с product_category_id = … не существует`, `p_price => -1` → `add_product: цена должна быть неотрицательной, передано -1`, `p_rating => 7` → `add_product: рейтинг должен быть от 0 до 5, передано 7`.
Вердикт: OK

### E.3. `rating_change` — пересчитывает рейтинг

```sql
-- Выбрать заказ, блюдо и клиента
SELECT p.product_id, p.rating FROM product p WHERE p.rating IS NOT NULL LIMIT 1;

-- Вставить отзыв на это блюдо
INSERT INTO review (review_id, client_id, review_timestamp, entity_id, entity_type, order_id, description, rating)
VALUES (
    exts.uuid_generate_v4(),
    (SELECT client_id FROM client LIMIT 1),
    localtimestamp,
    <product_id>,
    'блюдо',
    (SELECT order_id FROM "order" LIMIT 1),
    'Тестовый отзыв',
    5
);

SELECT rating FROM product WHERE product_id = <product_id>;
```

`<product_id>` = `'0a511929-44e2-418c-b99c-fe37d9369f51'` (из первого запроса; исходный `rating = 4.00`, один отзыв с оценкой 4).

Ожидается: `rating` пересчитан.
Факт: `INSERT 0 1`; `rating = 4.50` (= avg(4, 5)).
Вердикт: OK

### E.4. `rating_change` — удаление отзыва

```sql
-- Удалить отзыв из E.3
DELETE FROM review WHERE review_id = <review_id>;

SELECT rating FROM product WHERE product_id = <product_id>;
```

`<review_id>` — id отзыва, вставленного в E.3 (`SELECT review_id FROM review WHERE description = 'Тестовый отзыв'`).

Ожидается: если других отзывов нет — `rating IS NULL`; иначе — пересчитан.
Факт: `DELETE 1`; `rating = 4.00` (остался исходный отзыв с оценкой 4). Ветка «других отзывов нет» проверена отдельно: после удаления всех отзывов на блюдо `rating` = `NULL`.
Вердикт: OK

### E.5. `get_statistic()`

```sql
SELECT * FROM get_statistic();
```

Ожидается:
- Колонки: `restaurant_name`, `best_product_name`, `total_amount`, `avg_amount`, `best_user`.
- По одной строке на ресторан.
- `best_user` = `client.login` (не NULL при наличии заказов).

Факт: колонки `restaurant_name | best_product_name | total_amount | avg_amount | best_user`; 110 строк на 110 ресторанов (после C.9 — 11 наборов по 10). Строк с `total_amount < avg_amount` — 0. У всех 69 ресторанов с доставленными заказами `best_product_name` и `best_user` (логин клиента) не `NULL`. У ресторанов без доставленных заказов `total_amount = avg_amount = 0`, `best_product_name` и `best_user` — `NULL`.
Вердикт: OK

### E.6. `courier_salary()`

```sql
-- До
SELECT courier_id, coefficient FROM courier ORDER BY courier_id;

CALL courier_salary();

-- После
SELECT courier_id, coefficient FROM courier ORDER BY courier_id;
SELECT year, month, courier_id, amount, coefficient_used
FROM courier_pay
ORDER BY year DESC, month DESC, courier_id
LIMIT 20;
```

Ожидается:
- `courier.coefficient` пересчитан для работающих (по BR-10.2).
- У уволенных — не изменился.
- `courier_pay` содержит запись за текущий месяц.

Факт: до — 110 курьеров, у всех `0.1`; `CALL`; после — у всех `0.1`. У каждого работающего курьера меньше 151 доставки за месяц, поэтому по BR-10.2 новый коэффициент тоже 0.1. Уволенных процедура не обновляет (`WHERE status <> 'уволен'`). В `courier_pay` за 2026-11 есть записи по всем курьерам, например `2026 | 11 | 0f90ce7d-… | 76.07 | 0.1`, `2026 | 11 | 23cc556e-… | 29.74 | 0.1`, у курьеров без доставок `0.00`.

Пороги BR-10.2, которые на сгенерированных данных не достигаются (у курьера максимум несколько доставок в месяц), проверены отдельным тестом. Курьерам в текущем месяце создано 0/150/151/250/251/500/501 доставленных заказов, плюс отменённые и созданные заказы, которые учитываться не должны. После `courier_salary()` коэффициенты получились 0.1/0.1/0.2/0.2/0.3/0.3/0.5. Зарплата равна `0.2 × 100 × N`, отменённые и созданные заказы не учтены. У уволенного курьера (300 доставок) коэффициент остался прежним. После ещё одной доставки и повторного вызова сумма обновилась, `coefficient_used` сохранился, дубликатов нет.
Вердикт: OK

### E.7. `courier_salary()` — повторный вызов

```sql
CALL courier_salary();
SELECT count(*) FROM courier_pay
WHERE year = extract(year from current_date)
  AND month = extract(month from current_date);
```

Ожидается: количество не изменилось (idempotency / обновление).
Факт: `CALL`; `count = 110`, как и после первого вызова (110 курьеров → 110 записей). Суммы не изменились: при повторе применяется уже записанный `coefficient_used`.
Вердикт: OK

---

## F. Представление `how_much_money`

### F.1. Колонки

```sql
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'tsys_food'
  AND table_name = 'how_much_money'
ORDER BY ordinal_position;
```

Ожидается: `year_month` (text), `sum_no_commission`, `sum_with_commission`, `commission`, `prev_commission`, `commission_diff`, `courier_pay`, `net_profit` (numeric).
Факт: `year_month | text`, `sum_no_commission | numeric`, `sum_with_commission | numeric`, `commission | numeric`, `prev_commission | numeric`, `commission_diff | numeric`, `courier_pay | numeric`, `net_profit | numeric`
Вердикт: OK

### F.2. Месяцы покрыты

```sql
SELECT * FROM how_much_money ORDER BY year_month;
```

Ожидается: месяцы от первого доставленного заказа до последнего (не пропущено ни одного).
Факт:

| year_month | sum_no_commission | sum_with_commission | commission | prev_commission | commission_diff | courier_pay | net_profit |
|---|---|---|---|---|---|---|---|
| 2026-06 | 14412.25 | 15853.49 | 1441.24 | | | 144.12 | 1297.12 |
| 2026-07 | 42483.66 | 46732.04 | 4248.38 | 1441.24 | 2807.14 | 424.85 | 3823.53 |
| 2026-08 | 29882.11 | 32870.32 | 2988.21 | 4248.38 | -1260.17 | 298.84 | 2689.37 |
| 2026-09 | 82864.26 | 91150.70 | 8286.44 | 2988.21 | 5298.23 | 828.66 | 7457.78 |
| 2026-10 | 89167.89 | 98084.71 | 8916.82 | 8286.44 | 630.38 | 891.70 | 8025.12 |
| 2026-11 | 88599.14 | 97459.07 | 8859.93 | 8916.82 | -56.89 | 886.00 | 7973.93 |

6 месяцев подряд, с 2026-06 по 2026-11, без пропусков.
Вердикт: OK

### F.3. Месяцы без заказов присутствуют (BR-11.9)

```sql
SELECT year_month FROM how_much_money
WHERE sum_no_commission = 0 OR sum_no_commission IS NULL;
```

Ожидается: если в какие-то месяцы заказов не было — они есть в результате.
Факт: `(0 строк)`: в этом прогоне в каждом месяце диапазона были доставленные заказы. На другом наборе данных (после I.3, `insert_test_data(10)`) в 2026-09 доставок не было, и отчёт выдал строку `2026-09 | 0 | 0 | 0 | 192.79 | -192.79 | 0.00 | 0.00` между 2026-08 и 2026-10, то есть месяц без заказов присутствует с нулевыми суммами и `net_profit = 0`.
Вердикт: OK

### F.4. Корректность сумм

```sql
SELECT year_month,
       sum_no_commission,
       sum_with_commission,
       commission,
       prev_commission,
       commission_diff,
       courier_pay,
       net_profit
FROM how_much_money
ORDER BY year_month
LIMIT 10;
```

Ожидается:
- `commission = sum_with_commission - sum_no_commission`.
- `commission_diff = commission - prev_commission` (NULL для первого месяца).
- `net_profit = commission - courier_pay`.

Факт: те же 6 строк, что в F.2. Пример 2026-07: `46732.04 − 42483.66 = 4248.38` ✓; `4248.38 − 1441.24 = 2807.14` ✓; `4248.38 − 424.85 = 3823.53` ✓. В 2026-06 `prev_commission` и `commission_diff` — `NULL`.
Вердикт: OK

---

## G. Права `inspector`

### G.1. Права на схему

```sql
SELECT
    nspname AS schema_name,
    has_schema_privilege('inspector', nspname, 'USAGE')  AS usage,
    has_schema_privilege('inspector', nspname, 'CREATE') AS create
FROM pg_namespace
WHERE nspname = 'tsys_food';
```

Ожидается: `tsys_food`, `true`, `true` (полный доступ).
Факт: `tsys_food | t | t`
Вердикт: OK

### G.2. Права на таблицы

```sql
SELECT table_name, string_agg(privilege_type, ', ') AS privs
FROM information_schema.role_table_grants
WHERE grantee = 'inspector' AND table_schema = 'tsys_food'
GROUP BY table_name;
```

Ожидается: у каждой таблицы `SELECT, INSERT, UPDATE, DELETE` (или `ALL`).
Факт: 13 строк (12 таблиц + `how_much_money`). У каждой есть `INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER`, то есть `ALL`.
Вердикт: OK

### G.3. `information_schema` читается под `inspector`

```sql
SET ROLE inspector;
SELECT count(*) FROM information_schema.tables
WHERE table_schema = 'tsys_food';
RESET ROLE;
```

Ожидается: 12 + N (количество таблиц).
Факт: `13` (12 таблиц + представление `how_much_money`, см. B.3).
Вердикт: OK

### G.4. `pg_catalog` читается под `inspector`

```sql
SET ROLE inspector;
SELECT count(*) FROM pg_catalog.pg_tables
WHERE schemaname = 'tsys_food';
RESET ROLE;
```

Ожидается: 12 + N.
Факт: `12` (`pg_tables` не выводит представления).
Вердикт: OK

### G.5. Все процедуры/функции работают под `inspector`

```sql
SET ROLE inspector;
SET search_path TO tsys_food, exts;

CALL erase_test_data();
CALL insert_test_data(10);
CALL courier_salary();
SELECT * FROM get_statistic();
SELECT * FROM how_much_money LIMIT 5;

RESET ROLE;
```

Ожидается: без `permission denied`.
Факт: `CALL`, `CALL`, `CALL`, `get_statistic()` → 10 строк, `how_much_money LIMIT 5` → 5 строк (2026-06 … 2026-10). `permission denied` нет.
Вердикт: OK

---

## H. Оптимизация `get_statistic` (BR-11.8)

### H.1. `EXPLAIN ANALYZE` — паттерн «избыточные подзапросы»

```sql
EXPLAIN ANALYZE
SELECT c.courier_id,
       (SELECT count(*) FROM "order" o WHERE o.courier_id = c.courier_id AND o.status = 'доставлен') AS cnt,
       (SELECT coalesce(sum(commission), 0) FROM "order" o WHERE o.courier_id = c.courier_id AND o.status = 'доставлен') AS commission_sum
FROM courier c;
```

Ожидается: два SubPlan, каждый — скан `"order"`. Время растёт линейно от числа курьеров.
Факт: время 0.225 мс, план: `Seq Scan on courier c` + `SubPlan 1` и `SubPlan 2`, в каждом `Bitmap Heap Scan on "order"` с `loops=10` (по разу на каждого курьера).
Вердикт: OK

### H.2. `EXPLAIN ANALYZE` — паттерн «один JOIN»

```sql
EXPLAIN ANALYZE
SELECT c.courier_id,
       count(o.order_id) AS cnt,
       coalesce(sum(o.commission), 0) AS commission_sum
FROM courier c
LEFT JOIN "order" o ON o.courier_id = c.courier_id AND o.status = 'доставлен'
GROUP BY c.courier_id;
```

Ожидается: один `Hash Right Join` / `Hash Left Join`, один скан `"order"`. Время меньше, чем в H.1.
Факт: время 0.064 мс (меньше, чем 0.225 мс в H.1), план: `HashAggregate` → `Hash Left Join` → `Seq Scan on courier c` + один `Bitmap Heap Scan on "order"` (`loops=1`).
Вердикт: OK

### H.3. Применить к `get_statistic`

```sql
EXPLAIN ANALYZE SELECT * FROM get_statistic();
```

Ожидается: без `LATERAL`, без множественных подзапросов к одной таблице, без оконных функций там, где хватает агрегата.
Факт: время 0.409 мс, план верхнего уровня — `Function Scan on get_statistic`. Тело функции (SQL-функция, `db/schema/foodexpress.sql`, раздел 8) в `EXPLAIN` даёт: `"order"` — один `Seq Scan` в CTE `delivered`, `order_structure`, `restaurant`, `client`, `product` — по одному скану, соединения — `Hash Join`. `SubPlan`, `LATERAL` и `WindowAgg` нет; «лучшее» блюдо и клиент выбираются через `DISTINCT ON`.
Вердикт: OK

---

## I. Очистка и повторная генерация

### I.1. `erase_test_data` очищает всё

```sql
CALL erase_test_data();

SELECT 'client' AS tbl, count(*) FROM client
UNION ALL SELECT 'courier', count(*) FROM courier
UNION ALL SELECT 'product_category', count(*) FROM product_category
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
UNION ALL SELECT 'address', count(*) FROM address
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'order', count(*) FROM "order"
UNION ALL SELECT 'review', count(*) FROM review
UNION ALL SELECT 'payment', count(*) FROM payment
UNION ALL SELECT 'order_structure', count(*) FROM order_structure
UNION ALL SELECT 'client_address', count(*) FROM client_address
UNION ALL SELECT 'courier_pay', count(*) FROM courier_pay;
```

Ожидается: все 0.
Факт: `CALL`; все 12 строк — `0`.
Вердикт: OK

### I.2. Повторный `erase_test_data` не падает

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.
Факт: `CALL`
Вердикт: OK

### I.3. После очистки `insert_test_data` снова работает

```sql
CALL insert_test_data(10);
SELECT count(*) FROM "order";
```

Ожидается: 50.
Факт: `CALL`; `50`
Вердикт: OK
