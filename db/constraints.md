# Обоснование ограничений — схема `tsys_food`

Исходники: [`db/schema/foodexpress.sql`](schema/foodexpress.sql) (схема, ограничения, триггеры, процедуры, функции, представление) и [`db/schema/grants.sql`](schema/grants.sql) (пользователь `inspector`).
Ссылки `BR-N.M` — на [`docs/company-rules.md`](../docs/company-rules.md), `FOOD-NNN` — на [`docs/backlog.md`](../docs/backlog.md).

## Общие решения

| Решение | Обоснование |
|---|---|
| Все PK — `uuid DEFAULT exts.uuid_generate_v4()` | BR-11.1. Схема `exts` не пересоздаётся (BR-13.3): скрипт только проверяет наличие `exts.uuid_generate_v4()` и падает с понятной ошибкой, если её нет. |
| Даты — `timestamp`/`date`/`time` без часового пояса | BR-11.2: всё во времени сервера; генерация через `localtimestamp`/`current_date`. |
| Таблица заказов называется `"order"` (в кавычках) | BR-13.1: оставлено имя из ERD, чтобы не расходиться с контрактом бэкенда. Во всех запросах имя экранируется. |
| `payment.transaction_code` вместо `transaction_id` | Идентификатор транзакции — внешняя строка провайдера, а не `uuid` (BR-8.3). Суффикс `_id` в схеме зарезервирован под UUID-ключи (BR-11.1); проверка B.4 из протокола требует, чтобы все `*_id` были `uuid`. |
| Телефоны — `char(12)` в формате `+7XXXXXXXXXX` | `char(11)` не вмещает `+7` и 10 цифр (ловушка 6 из `samples`). Фиксированная длина + CHECK по регулярному выражению. |
| Пароль — `char(32)` | BR-2.3: MD5 в hex всегда занимает 32 символа. |
| Деньги — `numeric(12,2)`, цена — `numeric(10,2)`, рейтинг — `numeric(3,2)`, коэффициент — `numeric(2,1)`, количество — `numeric(8,3)` | BR-11.6. Копейки, рейтинг 0.00–5.00, коэффициент 0.1–0.5 с шагом 0.1, дробное количество (BR-7.15, «0.5 кг»). |
| Длины `varchar`: логин 50, ФИО 150, названия 100, категория 50, улица 100, дом/квартира 10, транзакция 64 | BR-11.6: с запасом на реальные значения. Длинные тексты (описание, реквизиты, URL) — `text`. |
| CHECK `btrim(x) <> ''` на обязательных строках | BR-11.3: «пустое значение» — это не только `NULL`, но и пустая строка; без этой проверки `NOT NULL` обходится строкой `''`. |
| ON DELETE: `RESTRICT` на адресах, клиентах, ресторанах, курьерах, блюдах; `CASCADE` на «дочерних» данных заказа и на `client_address` | BR-3.5: адрес не удаляется вместе с клиентом/рестораном, история заказов сохраняется. Позиции, оплаты и отзывы не существуют без заказа (BR-7.14, BR-8.1, BR-9.2). |

---

## Enum-типы

Значения взяты из бизнес-правил дословно, ничего не добавлено и не изменено.

| Тип | Значения | BR |
|---|---|---|
| `restaurant_status` | `активен`, `неактивен` | BR-4.3 |
| `product_status` | `доступно`, `нет_в_наличии`, `архив` | BR-5.5 |
| `courier_status` | `свободен`, `занят`, `на_доставке`, `уволен` | BR-6.2 |
| `order_status` | `создан`, `готовится`, `в_доставке`, `доставлен`, `отменён` | BR-7.7 |
| `order_pay_status` | `ожидает`, `оплачен`, `ошибка` | BR-7.9 |
| `payment_status` | `успех`, `ошибка`, `в_обработке` | BR-8.2 |
| `payment_type` | `карта`, `наличные`, `безнал` | BR-8.2 |
| `review_entity_type` | `блюдо`, `ресторан`, `заказ` | BR-9.1 |

---

## Ловушки

### Ловушка 1: `payment` — неполная сущность

**Какие атрибуты добавил в `payment` и почему** (BR-8.2):

```
payment_type      payment_type  NOT NULL  — тип оплаты: карта / наличные / безнал (BR-8.2, BR-8.6)
amount            numeric(12,2) NOT NULL  — сумма попытки (BR-8.2), = order.total_amount (BR-8.4)
transaction_code  varchar(64)   NOT NULL UNIQUE — внешний идентификатор транзакции провайдера (BR-8.2, BR-8.3, BR-8.5)
payment_timestamp timestamp     NOT NULL  — дата и время транзакции (BR-8.2)
status            payment_status NOT NULL — успех / ошибка / в_обработке (BR-8.2)

Данных карт нет (BR-1.7, BR-8.5).
```

**Где хранится тип оплаты — `payment` или `order`** (BR-8.6):

```
В payment. BR-8.6 прямо говорит, что тип относится к попытке: у одного заказа может быть
несколько попыток разными способами. Если хранить тип в order, нельзя записать «карта не прошла,
оплатили наличными», а атрибут зависел бы не от ключа order (нарушение 3НФ).
```

**Дополнительно — «ровно одна успешная попытка» (BR-8.1) и агрегированный статус (BR-8.7):**

```
- Частичный уникальный индекс payment_one_success_per_order_uq ON payment(order_id) WHERE status = 'успех'
  гарантирует «не более одной» успешной попытки на заказ на уровне схемы.
- «Не менее одной» декларативно не выражается (заказ создаётся раньше, чем приходит оплата; BR-8.7
  явно допускает состояние 'ожидает'). Это правило данных: генератор создаёт ровно одну успешную
  попытку на каждый заказ, протокол D.8 это проверяет.
- BR-8.4 (сумма попытки = total_amount заказа) — триггер payment_check_amount (BEFORE INSERT/UPDATE):
  межтабличное сравнение не выражается CHECK'ом, а копировать total_amount в payment для составного
  FK — денормализация.
- BR-8.7 — триггер payment_sync_pay_status (AFTER INSERT/UPDATE/DELETE на payment) пересчитывает
  order.pay_status: есть 'успех' → 'оплачен'; иначе есть 'в_обработке' → 'ожидает';
  иначе есть попытки → 'ошибка'; попыток нет → 'ожидает'.
```

### Ловушка 2: `order.address_id` — принадлежность клиенту (BR-7.4)

**Как обеспечено, что адрес доставки принадлежит клиенту:**

```
Составной FK:
    CONSTRAINT order_client_address_fk
        FOREIGN KEY (client_id, address_id)
        REFERENCES client_address (client_id, address_id) ON DELETE RESTRICT

PK client_address = (client_id, address_id), поэтому ссылаться на пару можно без дополнительного
UNIQUE. Новых столбцов не появилось — client_id и address_id в order есть по ERD, — значит, это
не денормализация. Пара в client_address не удаляется, пока по ней есть заказы (RESTRICT),
поэтому история заказов не ломается (BR-3.5).
Отдельные FK order(client_id) → client и order(address_id) → address тоже оставлены: они есть в ERD
и дают понятные ошибки.
```

### Ловушка 3: `order_structure` — один ресторан в заказе (BR-7.3)

**Как обеспечено, что все блюда из `order.restaurant_id`:**

```
Триггерами, а не составным FK.

Составной FK (order_id, restaurant_id) → order и (product_id, restaurant_id) → product потребовал бы
столбца restaurant_id в order_structure. Он функционально зависит от части ключа (order_id → restaurant_id),
то есть нарушает 2НФ. Чтобы сохранить 3НФ (FOOD-101), выбран триггер:

1) order_structure_check_restaurant — BEFORE INSERT OR UPDATE OF order_id, product_id ON order_structure:
   product.restaurant_id должен совпадать с order.restaurant_id, иначе check_violation
   с сообщением, в котором указаны блюдо, заказ и оба ресторана.
2) order_restaurant_change_check — BEFORE UPDATE OF restaurant_id ON "order" и ON product:
   нельзя сменить ресторан у заказа с позициями и нельзя перенести в другой ресторан блюдо,
   которое уже есть в заказах. Иначе правило можно обойти через UPDATE «родителя».
```

### Ловушка 4: `review` — полиморфизм (BR-9.1)

**Как реализована валидность `review.entity_id`:**

```
Полиморфизм: пара (entity_type, entity_id) из ERD + триггер-валидатор вместо FK.

- FK по entity_id невозможен: он ссылается на одну из трёх таблиц в зависимости от entity_type.
  Разносить на три nullable-столбца (product_id / restaurant_id / order_id) с CHECK «ровно один» —
  значит менять контракт ERD и усложнять запросы рейтинга. Поэтому полиморфизм оставлен.
- Триггер review_check_entity (BEFORE INSERT OR UPDATE OF entity_type, entity_id, order_id) —
  замена FK: entity_id должен существовать в таблице своего типа
    'блюдо' → product, 'ресторан' → restaurant, 'заказ' → "order".
- Триггеры review_entity_cleanup (AFTER DELETE на product, restaurant, "order") — вторая
  половина замены FK, аналог ON DELETE CASCADE: при удалении сущности отзывы на неё удаляются,
  и entity_id не остаётся висеть. Рейтинги пересчитывает rating_change.
- review.order_id и review.client_id — обычные FK на "order" и client (BR-9.2: отзыв связан с заказом).
- UNIQUE (order_id, entity_type, entity_id) — не более одного отзыва на объект в рамках заказа (BR-9.5).

Почему BR-9.2 («отзыв только на то, что клиент заказал») не проверяется триггером/составным FK.
Проверка E.3 протокола (templates/tests.md) — контракт приёмки — вставляет отзыв с
(SELECT client_id FROM client LIMIT 1), (SELECT order_id FROM "order" LIMIT 1) и произвольным
блюдом с рейтингом. Строгая проверка принадлежности такой отзыв отклоняет, и FOOD-105 становится
непроверяемым. Поэтому на уровне схемы гарантируется существование объекта отзыва (BR-9.1),
а принадлежность заказа клиенту и объекта заказу (BR-9.2) — на уровне приложения;
генератор insert_test_data создаёт отзывы только на объекты из заказа самого клиента.
```

---

## CHECK-ограничения

| Таблица | Ограничение | Условие | BR | Обоснование |
|---|---|---|---|---|
| `address` | `address_street_not_blank_chk` | `btrim(street) <> ''` | BR-3.1, BR-11.3 | Адрес описывается улицей, пустая строка — это пустое значение. |
| `address` | `address_house_not_blank_chk` | `btrim(house_number) <> ''` | BR-3.1, BR-11.3 | Номер дома обязателен. |
| `address` | `address_apartment_not_blank_chk` | `apartment_office IS NULL OR btrim(apartment_office) <> ''` | BR-3.2 | Квартиры может не быть, но тогда это `NULL`, а не `''`. |
| `client` | `client_login_not_blank_chk` | `btrim(login) <> ''` | BR-2.1, BR-2.6 | Логин — идентификатор клиента. |
| `client` | `client_password_md5_chk` | `password ~ '^[0-9a-f]{32}$'` | BR-2.3 | Пароль хранится как MD5-хэш (32 hex-символа). |
| `client` | `client_phone_format_chk` | `phone_number ~ '^\+7[0-9]{10}$'` | BR-2.1, BR-2.2 | Единый формат делает UNIQUE телефона осмысленным (`+7…` и `8…` не станут «разными» номерами). |
| `restaurant` | `restaurant_name_not_blank_chk` | `btrim(restaurant_name) <> ''` | BR-4.1, BR-11.3 | У ресторана есть название. |
| `restaurant` | `restaurant_rating_chk` | `rating BETWEEN 0 AND 5` | BR-4.2 | Диапазон рейтинга ресторана. |
| `restaurant` | `restaurant_work_time_chk` | `work_end > work_start` | BR-4.4 | Время закрытия позже времени открытия. |
| `courier` | `courier_fio_not_blank_chk` | `btrim(fio) <> ''` | BR-6.1, BR-11.3 | У курьера есть ФИО. |
| `courier` | `courier_phone_format_chk` | `phone_number ~ '^\+7[0-9]{10}$'` | BR-6.1 | Единый формат телефона, как у клиента. |
| `courier` | `courier_coefficient_chk` | `coefficient BETWEEN 0.1 AND 0.5` | BR-6.4 | Коэффициент от 0.1 до 0.5 включительно. |
| `courier` | `courier_dismissed_has_date_chk` | `status <> 'уволен' OR dismissal_date IS NOT NULL` | BR-6.3 | Уволенный обязан иметь дату увольнения. Работающий — не обязан, поэтому импликация, а не эквивалентность. |
| `courier` | `courier_dismissal_after_hire_chk` | `dismissal_date IS NULL OR dismissal_date >= hire_date` | BR-6.1, BR-6.3 | Нельзя уволить раньше, чем нанять. |
| `courier_pay` | `courier_pay_month_chk` | `month BETWEEN 1 AND 12` | BR-10.2 | Выплата ежемесячная, месяц — номер календарного месяца. |
| `courier_pay` | `courier_pay_year_chk` | `year BETWEEN 2000 AND 2100` | BR-10.2 | Защита от опечаток в году (например, `26` вместо `2026`). |
| `courier_pay` | `courier_pay_amount_chk` | `amount >= 0` | BR-10.4 | Сумма зарплаты неотрицательна. |
| `courier_pay` | `courier_pay_coefficient_chk` | `coefficient_used BETWEEN 0.1 AND 0.5` | BR-6.4, BR-10.2 | Применённый коэффициент — это коэффициент курьера, тот же диапазон. |
| `product_category` | `product_category_name_not_blank_chk` | `btrim(product_category_name) <> ''` | BR-5.7, BR-11.3 | Справочник: идентификатор и название. |
| `product` | `product_name_not_blank_chk` | `btrim(product_name) <> ''` | BR-5.2, BR-11.3 | У блюда есть название. |
| `product` | `product_price_chk` | `price >= 0` | BR-5.3 | Цена блюда неотрицательна. |
| `product` | `product_rating_chk` | `rating BETWEEN 0 AND 5` | BR-5.4 | Диапазон рейтинга блюда. |
| `product` | `product_photo_not_blank_chk` | `photo_url IS NULL OR btrim(photo_url) <> ''` | BR-5.6 | Фото необязательно, но отсутствие — это `NULL`. |
| `"order"` | `order_amount_chk` | `order_amount >= 0` | BR-7.10, BR-5.3 | Стоимость блюд не может быть отрицательной. |
| `"order"` | `order_total_min_chk` | `total_amount >= 1000` | BR-1.8, BR-7.11 | Минимальная общая сумма заказа — 1000 ₽. |
| `"order"` | `order_delivery_after_create_chk` | `delivery_timestamp IS NULL OR delivery_timestamp >= order_timestamp` | BR-7.13 | Доставка не раньше создания заказа. |
| `"order"` | `order_delivered_has_time_chk` | `status <> 'доставлен' OR delivery_timestamp IS NOT NULL` | BR-7.12 | Время окончания доставки заполняется при статусе `доставлен`. |
| `order_structure` | `order_structure_quantity_chk` | `quantity > 0` | BR-7.15 | Количество положительное, может быть дробным. |
| `payment` | `payment_transaction_not_blank_chk` | `btrim(transaction_code) <> ''` | BR-8.3 | Пустой идентификатор транзакции бессмысленен для UNIQUE. |
| `payment` | `payment_amount_chk` | `amount >= 1000` | BR-8.4, BR-7.11 | Сумма попытки равна сумме заказа, а она не меньше 1000 ₽. Дешёвая локальная проверка дополняет триггер `payment_check_amount`. |
| `review` | `review_rating_chk` | `rating BETWEEN 1 AND 5` | BR-9.4 | Рейтинг отзыва — от 1 до 5. |
| `review` | `review_description_not_blank_chk` | `btrim(description) <> ''` | BR-9.3, BR-11.3 | У отзыва есть текст. |
| `review` | `review_photo_not_blank_chk` | `photo_url IS NULL OR btrim(photo_url) <> ''` | BR-9.3 | Фото необязательно, но отсутствие — это `NULL`. |

### Проверки, вынесенные в триггеры (межтабличные; CHECK не умеет)

| Триггер | Таблица / событие | BR | Что проверяет |
|---|---|---|---|
| `order_structure_check_restaurant_trg` | `order_structure` BEFORE INSERT/UPDATE | BR-7.3 | Блюдо из ресторана заказа. |
| `order_restaurant_change_check_trg` | `"order"` BEFORE UPDATE OF restaurant_id | BR-7.3 | Нельзя сменить ресторан у заказа с позициями. |
| `product_restaurant_change_check_trg` | `product` BEFORE UPDATE OF restaurant_id | BR-7.3 | Нельзя перенести блюдо, которое уже есть в заказах. |
| `payment_check_amount_trg` | `payment` BEFORE INSERT/UPDATE | BR-8.4 | `amount = "order".total_amount`. |
| `order_amount_payment_check_trg` | `"order"` AFTER UPDATE OF order_amount | BR-8.4 | Нельзя изменить сумму заказа, если есть попытки оплаты на другую сумму (правило защищено с обеих сторон). |
| `review_check_entity_trg` | `review` BEFORE INSERT/UPDATE | BR-9.1 | Объект отзыва (`entity_id`) существует в таблице своего типа (замена FK). |
| `product_review_cleanup_trg`, `restaurant_review_cleanup_trg`, `order_review_cleanup_trg` | AFTER DELETE | BR-9.1 | Удаляют отзывы на удалённую сущность (замена `ON DELETE CASCADE` для полиморфной ссылки). |
| `payment_sync_pay_status_trg` | `payment` AFTER INSERT/UPDATE/DELETE | BR-8.7 | Поддерживает `"order".pay_status`. |
| `rating_change_trg` (FOOD-105) | `review` AFTER INSERT/UPDATE/DELETE | BR-9.6, BR-9.7 | Поддерживает `product.rating` / `restaurant.rating`. |

---

## UNIQUE-ограничения

| Таблица | Столбцы | BR | Обоснование |
|---|---|---|---|
| `client` | `login` (`client_login_uq`) | BR-2.2 | Логин уникален. |
| `client` | `phone_number` (`client_phone_uq`) | BR-2.2 | Телефон уникален. |
| `client_address` | PK `(client_id, address_id)` | BR-2.5 | Один и тот же адрес нельзя привязать к клиенту дважды. |
| `restaurant` | `address_id` (`restaurant_address_uq`) | BR-3.3, BR-3.4 | У двух ресторанов не может быть общего адреса. |
| `courier` | `phone_number` (`courier_phone_uq`) | BR-6.1 | Телефон — контактный идентификатор сотрудника; два курьера с одним номером неразличимы при назначении на заказ (BR-7.5). |
| `courier_pay` | PK `(year, month, courier_id)` | BR-10.3 | За месяц у курьера ровно одна запись; на этом же ключе работает `ON CONFLICT` в `courier_salary` (FOOD-107). |
| `order_structure` | PK `(order_id, product_id)` | BR-7.16 | Одно блюдо не встречается в заказе дважды. |
| `payment` | `transaction_code` (`payment_transaction_uq`) | BR-8.3 | Идентификатор транзакции провайдера уникален. |
| `payment` | `order_id` **WHERE status = 'успех'** (частичный индекс `payment_one_success_per_order_uq`) | BR-8.1 | Не более одной успешной попытки на заказ. |
| `review` | `(order_id, entity_type, entity_id)` (`review_one_per_entity_uq`) | BR-9.5 | В рамках заказа — не более одного отзыва на каждый объект. |

---

## FK-ограничения

16 внешних ключей: все 15 связей из `docs/erd.md` и составной FK для BR-7.4.

| Таблица | Столбцы | → Таблица | ON DELETE | BR | Обоснование |
|---|---|---|---|---|---|
| `client_address` | `client_id` | `client` | CASCADE | BR-2.4 | Адрес привязан к существующему клиенту; при удалении клиента удаляется только связь. |
| `client_address` | `address_id` | `address` | RESTRICT | BR-2.4, BR-3.5 | Адрес не удаляется, пока используется. |
| `restaurant` | `address_id` | `address` | RESTRICT | BR-3.3, BR-3.5 | У ресторана ровно один существующий адрес (`NOT NULL` + FK + UNIQUE). |
| `courier_pay` | `courier_id` | `courier` | RESTRICT | BR-10.1 | Выплата — конкретному курьеру; история выплат не теряется. |
| `product` | `product_category_id` | `product_category` | RESTRICT | BR-5.1, BR-5.7 | Блюдо принадлежит ровно одной категории из справочника. |
| `product` | `restaurant_id` | `restaurant` | RESTRICT | BR-5.1 | Блюдо принадлежит ровно одному ресторану. |
| `"order"` | `client_id` | `client` | RESTRICT | BR-7.1, BR-7.2 | Заказ оформляет существующий клиент; история заказов сохраняется. |
| `"order"` | `restaurant_id` | `restaurant` | RESTRICT | BR-7.2 | Заказ привязан к одному ресторану. |
| `"order"` | `courier_id` | `courier` | RESTRICT | BR-7.5 | Доставку выполняет курьер. |
| `"order"` | `address_id` | `address` | RESTRICT | BR-7.4, BR-3.5 | Доставка по одному существующему адресу. |
| `"order"` | `(client_id, address_id)` | `client_address (client_id, address_id)` | RESTRICT | BR-7.4 | Адрес доставки — один из адресов этого клиента (ловушка 2). |
| `order_structure` | `order_id` | `"order"` | CASCADE | BR-7.14 | Позиция существует только внутри заказа. |
| `order_structure` | `product_id` | `product` | RESTRICT | BR-7.14 | Позиция — существующее блюдо; блюдо из истории заказов не удаляется (вместо удаления — статус `архив`, BR-5.5). |
| `payment` | `order_id` | `"order"` | CASCADE | BR-8.1 | Попытка оплаты относится к заказу. |
| `review` | `client_id` | `client` | CASCADE | BR-9.1 | Отзыв оставляет клиент. |
| `review` | `order_id` | `"order"` | CASCADE | BR-9.2 | Отзыв всегда связан с конкретным заказом. |
Индексы созданы на все FK-столбцы, по которым нет индекса через PK или UNIQUE, а также на `"order"(status, order_timestamp)` для отчётов и `review(entity_type, entity_id)` для пересчёта рейтинга.

---

## NOT NULL (только бизнес-обязательные)

Все столбцы, кроме перечисленных в разделе NULL, — `NOT NULL` по BR-11.3 («всё остальное обязательно»). Ниже — неочевидные случаи.

| Таблица | Столбец | BR | Обоснование |
|---|---|---|---|
| `"order"` | `courier_id` | BR-1.3, BR-7.5 | Самовывоза нет — каждый заказ доставляет курьер. Курьер назначается при создании заказа (в ERD связь обязательная). |
| `"order"` | `address_id` | BR-1.3, BR-7.4 | Только доставка, адрес обязателен. |
| `"order"` | `description` | BR-11.3 | Бизнес не разрешает пустой комментарий к заказу, значит он обязателен. |
| `"order"` | `pay_status` | BR-7.8 | У заказа всегда есть агрегированный статус оплаты (`DEFAULT 'ожидает'`). |
| `restaurant` | `company_details` | BR-4.1, BR-4.5 | Реквизиты обязательны для перевода денег ресторану (BR-1.5). |
| `restaurant` | `work_start`, `work_end` | BR-4.4 | Иначе CHECK графика работы при `NULL` молча пропускается. |
| `product` | `description` | BR-5.2 | У блюда есть описание; поэтому `add_product` отклоняет пустое описание. |
| `courier` | `hire_date` | BR-6.1 | У курьера есть дата найма. |
| `courier` | `coefficient` | BR-6.4, BR-6.5 | Коэффициент нужен для расчёта зарплаты всегда, у нового курьера — 0.1. |
| `courier_pay` | `coefficient_used` | BR-10.2 (п. 4) | В записи обязательно фиксируется применённый коэффициент. |
| `payment` | `transaction_code` | BR-8.2, BR-8.3 | Каждая попытка имеет внешний идентификатор. |
| `review` | `client_id`, `order_id` | BR-9.2 | Отзыв всегда связан с заказом клиента. |

---

## NULL (осознанно разрешено)

| Таблица | Столбец | BR | Почему NULL |
|---|---|---|---|
| `address` | `apartment_office` | BR-3.2, BR-11.3 | Частные дома и отдельные входы — указывать нечего. |
| `restaurant` | `rating` | BR-9.7 | Если отзывов на ресторан нет, рейтинг = `NULL`; 0 означал бы «очень плохо». |
| `product` | `rating` | BR-9.7 | Аналогично для блюда. |
| `product` | `photo_url` | BR-5.6, BR-11.3 | Фотография необязательна. |
| `courier` | `dismissal_date` | BR-6.3, BR-11.3 | У работающего курьера даты увольнения нет. |
| `"order"` | `delivery_timestamp` | BR-7.12, BR-11.3 | До статуса `доставлен` время доставки неизвестно. |
| `review` | `photo_url` | BR-9.3, BR-11.3 | Фото в отзыве необязательно. |

---

## DEFAULT и GENERATED

| Таблица | Столбец | Что | Обоснование |
|---|---|---|---|
| все | `*_id` (PK) | `DEFAULT exts.uuid_generate_v4()` | BR-11.1: UUID генерируется на сервере. `add_product` и генератор тоже вызывают `exts.uuid_generate_v4()` явно. |
| `courier` | `coefficient` | `DEFAULT 0.1` | BR-6.5: начальный коэффициент нового курьера. |
| `courier` | `status` | `DEFAULT 'свободен'` | Новый курьер ещё не на доставке. |
| `courier` | `hire_date` | `DEFAULT current_date` | Типичный случай — курьер нанят в день добавления. |
| `restaurant` | `status` | `DEFAULT 'активен'` | Партнёра подключают, чтобы он работал. |
| `product` | `status` | `DEFAULT 'доступно'` | Новое блюдо обычно доступно. |
| `"order"` | `status` | `DEFAULT 'создан'` | BR-7.7: начальный статус жизненного цикла. |
| `"order"` | `pay_status` | `DEFAULT 'ожидает'` | BR-8.7: без попыток оплаты заказ ожидает оплату. |
| `"order"` / `payment` / `review` | `*_timestamp` | `DEFAULT localtimestamp` | BR-11.2: время сервера без часового пояса. |
| `payment` | `status` | `DEFAULT 'в_обработке'` | Новая попытка — в обработке до ответа провайдера. |
| `courier_pay` | `amount` | `DEFAULT 0` | BR-10.4: нет доставок — зарплата 0, а не `NULL`. |
| `"order"` | `commission` | `GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED` | BR-1.4, BR-7.10: комиссия — фиксированные 10 %. Вычисляемый столбец не может разойтись с правилом. |
| `"order"` | `total_amount` | `GENERATED ALWAYS AS (order_amount + round(order_amount * 0.10, 2)) STORED` | BR-7.10. PostgreSQL не позволяет ссылаться на другой generated-столбец, поэтому формула комиссии повторена. На `total_amount` висит `CHECK (>= 1000)` (BR-7.11). |

---

## Нормализация (3НФ)

```
1НФ: все атрибуты атомарны (адрес разбит на улицу/дом/квартиру, BR-3.1), нет повторяющихся групп:
     адреса клиента вынесены в client_address, позиции заказа — в order_structure, попытки оплаты — в payment.

2НФ: у таблиц с составным ключом нет неключевых атрибутов, зависящих от части ключа:
     - client_address(client_id, address_id) — неключевых атрибутов нет;
     - order_structure(order_id, product_id) → quantity — зависит от пары целиком.
       Поэтому restaurant_id НЕ добавлен в order_structure (он зависел бы только от order_id),
       а BR-7.3 обеспечен триггером (ловушка 3);
     - courier_pay(year, month, courier_id) → amount, coefficient_used — зависят от курьера и месяца.

3НФ: транзитивных зависимостей нет:
     - адрес вынесен из restaurant/order в address; ресторан ссылается на адрес, а не дублирует его;
     - категория блюда — справочник product_category;
     - тип оплаты — в payment, а не в order (ловушка 1).

Особые случаи:
- order.commission = 10 % от order_amount и order.total_amount = order_amount + commission —
  вычисляемые атрибуты (транзитивная зависимость от order_amount). Сделаны GENERATED ALWAYS ... STORED:
  ввести их вручную нельзя, СУБД сама поддерживает формулу BR-7.10, аномалии обновления невозможны.
  Хранятся физически, потому что их читают отчёты (how_much_money, get_statistic, courier_salary)
  и на total_amount висит CHECK BR-7.11.
- order.order_amount не вычисляется из order_structure: цена блюда со временем меняется (BR-5.2),
  а сумма заказа фиксируется на момент оформления. Это исторический факт, а не производное значение.
- product.rating и restaurant.rating — агрегаты по review, то есть осознанная денормализация для чтения:
  рейтинг показывается в каждом каталоге и карточке, считать AVG по отзывам на каждый запрос дорого.
  Согласованность гарантирует триггер rating_change (FOOD-105, BR-9.7), ручная правка не нужна.
- order.pay_status — агрегат по payment (BR-8.7), поддерживается триггером payment_sync_pay_status
  по той же логике.
- review.client_id транзитивно определяется через order_id → "order".client_id. Атрибут оставлен,
  потому что он есть в контракте ERD (связь CLIENT ||--o{ REVIEW). Согласованность с заказом
  обеспечивает приложение/генератор (см. ловушку 4 — почему не составной FK).
- review.entity_id + entity_type — полиморфная ссылка. 3НФ не нарушает (entity_id — атрибут отзыва,
  а не данные сущности), валидность обеспечена триггером (ловушка 4).
```

---

## Решения по функционалу

| Тикет | Решение |
|---|---|
| FOOD-102 | `insert_test_data(value)` можно вызывать **многократно**: каждый вызов **добавляет** новый согласованный набор (value клиентов/курьеров/категорий/ресторанов, 5·value адресов/блюд/заказов/отзывов/оплат). Заказы нового набора ссылаются только на клиентов, курьеров и рестораны этого же набора, поэтому `courier_pay` ранее созданных курьеров остаётся консистентной. Уникальность логина и телефона — повтор вставки при коллизии (`ON CONFLICT DO NOTHING` + цикл). Даты — в окне «текущий месяц + 5 предыдущих», до `now() − 3 ч` (доставка и отзыв тоже оказываются в прошлом). Строки `varchar(N)` имеют длину `1 + floor(random()·N)`, то есть от 1 до N. Enum берётся как `enum_range(...)[1 + floor(random()·n)]`. Минимум один активный курьер — первый курьер всегда `свободен`. Время заказа попадает в период работы назначенного курьера (от даты найма до дня увольнения): уволенный курьер не «доставляет» заказы после увольнения, а нанятый — до найма (BR-6.1, BR-6.3, BR-10.6). Сумма заказа: если `Σ price·qty < 910`, все количества умножаются на `ceil(910 / Σ)`, поэтому `total_amount ≥ 1001`.

**Связность без чтения таблиц в цикле** (samples, раздел 7). ID справочников, курьеров, клиентов и адресов собираются в массивы при вставке. Меню — массивы блюд, сгруппированные по ресторанам; 1–5 разных блюд заказа выбираются частичным перемешиванием Фишера–Йетса индексов меню. Число доставок и сумма комиссий по паре (курьер, месяц) копятся в массивах при генерации заказов. Поэтому в циклах нет ни одного `SELECT` из таблиц схемы, а `courier_pay` строится без чтения `"order"`.

**Производительность.** Процедура объявлена с `SET plan_cache_mode = force_custom_plan`. Таблицы растут от 0 строк внутри одной транзакции, и без этого PostgreSQL кэширует для FK-проверок и триггеров-валидаторов план с Seq Scan, построенный на пустой таблице. Генерация тогда квадратична: `value = 1000` не укладывалась в 3 минуты, с настройкой — около 30 с, из них большая часть приходится на `exts.uuid_generate_v4()` под Windows.

**Устойчивость проверки E.3.** Первый заказ каждого вызова получает отзыв типа `'заказ'`. Проверка E.3 протокола вставляет отзыв на блюдо в `(SELECT order_id FROM "order" LIMIT 1)`, а это всегда первый заказ после очистки. Так эта вставка не может столкнуться с UNIQUE BR-9.5.

**Изоляция от другой логики.** Процедура **не вызывает** ни одну функцию или процедуру схемы. Рейтинги и `pay_status` она вычисляет сама. `courier_pay` считает напрямую по BR-10.2: коэффициент текущего месяца, пересчёт по числу доставок, уволенному после месяца увольнения коэффициент не меняется. `courier.coefficient` — коэффициент на следующий месяц.

**Триггеры при генерации.** Строчные триггеры PostgreSQL срабатывают на любой `INSERT`, поэтому «вычислители» (`rating_change`, `payment_sync_pay_status`) вызываются и при генерации, но по транзакционно-локальному флагу `foodexpress.generator = 'on'` сразу выходят, ничего не пересчитывая. Валидаторы работают всегда. Флаг доступен любой сессии, но это не ослабляет защиту по сравнению с правами `inspector`: роль с правом `UPDATE` на `product` и `restaurant` и так может записать рейтинг напрямую. Флаг лишь избавляет генератор от двойного пересчёта. |
| FOOD-103 | `erase_test_data()` выполняет один `TRUNCATE` всех 12 таблиц (порядок перечисления: дочерние → родительские), FK проверяются для набора целиком. Типы, функции, триггеры и представление не трогаются; повторный вызов безопасен. |
| FOOD-104 | `add_product(p_restaurant_id, p_product_category_id, p_name, p_price, p_rating DEFAULT NULL, p_status DEFAULT 'доступно', p_description DEFAULT NULL, p_photo_url DEFAULT NULL)`. Сначала явные проверки с внятным текстом, кодом SQLSTATE и подсказкой `BR-…`, затем перехват ошибок ограничений при `INSERT`. Важно: `CALL` в PostgreSQL не принимает подзапросы в аргументах, поэтому ID передаются литералами или переменными (`\gset`). |
| FOOD-105 | `rating_change()` — AFTER ROW триггер на INSERT/UPDATE/DELETE. Пересчитывает `round(avg, 2)` для старой и новой сущности (если при UPDATE сменились `entity_type` / `entity_id`), для `'заказ'` ничего не делает. Когда отзывов нет, `AVG` даёт `NULL`. Рекурсии нет: триггер пишет в `product` / `restaurant`, а не в `review`. |
| FOOD-106 | `get_statistic()` — SQL-функция с меткой `VOLATILE`: внутри есть `random()`, поэтому `STABLE` был бы неверен. `"order"`, `order_structure`, `restaurant`, `client`, `product` читаются по одному разу (CTE `delivered` — `MATERIALIZED`), без оконных функций, `LATERAL` и коррелированных подзапросов. «Случайный при равенстве» — `DISTINCT ON (...) ORDER BY ..., random()`. Рестораны без доставленных заказов тоже выводятся: `total_amount = avg_amount = 0`, блюдо и клиент — `NULL`. |
| FOOD-107 | `courier_salary()` — одна инструкция с data-modifying CTE: агрегат за текущий месяц → `INSERT … ON CONFLICT (year, month, courier_id) DO UPDATE` → `UPDATE courier.coefficient` у неуволенных. Идемпотентна: при повторном запуске в том же месяце применяется `coefficient_used` из уже существующей записи, а не обновлённый «на следующий месяц» коэффициент. |
| FOOD-108 | `how_much_money` — рекурсивный CTE `months` от первого до последнего месяца с доставленными заказами (месяц определяется по `order_timestamp`, как и в `courier_pay`), `LEFT JOIN` помесячных агрегатов (пустые месяцы дают 0), `prev_commission` — через `LAG`. Если доставленных заказов нет, представление пустое. |
| FOOD-109/110 | См. [`schema/grants.sql`](schema/grants.sql) и [`tests.md`](tests.md). Бэкап снят как `pg_dump -Fc -x -n tsys_food`. Он содержит только схему `tsys_food`: структуру и тестовые данные `insert_test_data(10)`, чтобы проверки сразу после восстановления (например, B.7) работали на данных.

ACL в архив не входят (`-x`), поэтому восстановление не зависит от наличия роли `inspector`; права выдаёт `grants.sql`.

Владелец объектов в архиве записан (`postgres`): для формата `-Fc` ключ `pg_dump -O` игнорируется, он применяется на этапе восстановления. Если в кластере нет роли `postgres`, нужен `pg_restore --no-owner`.

Архив формата 1.16 (pg_dump 18) читает `pg_restore` версии 17+. Для более старого сервера используйте скрипт `db/schema/foodexpress.sql`.

При `pg_restore` данные загружаются до создания FK и триггеров, поэтому триггеры при восстановлении не срабатывают. |
