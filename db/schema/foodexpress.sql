-- ============================================================================
-- FoodExpress — физическая схема и функционал (FOOD-101 … FOOD-108)
-- СУБД: PostgreSQL 15+ (проверено на 18.4)
-- Схема: tsys_food
--
-- Предусловие (BR-13.3): схема exts с расширением uuid-ossp уже существует.
-- Скрипт её не пересоздаёт; блок ниже только проверяет наличие.
--
-- Скрипт идемпотентен: при повторном запуске схема tsys_food пересоздаётся.
-- Права для пользователя inspector — в отдельном файле grants.sql (FOOD-109).
-- ============================================================================

DO $$
BEGIN
    IF to_regprocedure('exts.uuid_generate_v4()') IS NULL THEN
        RAISE EXCEPTION 'Не найдена функция exts.uuid_generate_v4(): схема exts с расширением uuid-ossp должна быть создана заранее (BR-13.3)';
    END IF;
END $$;

DROP SCHEMA IF EXISTS tsys_food CASCADE;
CREATE SCHEMA tsys_food;
COMMENT ON SCHEMA tsys_food IS 'FoodExpress: сервис доставки еды';

SET search_path TO tsys_food, exts;

-- ============================================================================
-- 1. ENUM-типы (BR-11.5)
-- ============================================================================

CREATE TYPE tsys_food.restaurant_status AS ENUM ('активен', 'неактивен');                                   -- BR-4.3
CREATE TYPE tsys_food.product_status    AS ENUM ('доступно', 'нет_в_наличии', 'архив');                     -- BR-5.5
CREATE TYPE tsys_food.courier_status    AS ENUM ('свободен', 'занят', 'на_доставке', 'уволен');             -- BR-6.2
CREATE TYPE tsys_food.order_status      AS ENUM ('создан', 'готовится', 'в_доставке', 'доставлен', 'отменён'); -- BR-7.7
CREATE TYPE tsys_food.order_pay_status  AS ENUM ('ожидает', 'оплачен', 'ошибка');                           -- BR-7.9
CREATE TYPE tsys_food.payment_status    AS ENUM ('успех', 'ошибка', 'в_обработке');                         -- BR-8.2
CREATE TYPE tsys_food.payment_type      AS ENUM ('карта', 'наличные', 'безнал');                            -- BR-8.2
CREATE TYPE tsys_food.review_entity_type AS ENUM ('блюдо', 'ресторан', 'заказ');                            -- BR-9.1

-- ============================================================================
-- 2. Таблицы (FOOD-101)
-- ============================================================================

-- ---------------------------------------------------------------- address
CREATE TABLE tsys_food.address (
    address_id       uuid         NOT NULL DEFAULT exts.uuid_generate_v4(),
    street           varchar(100) NOT NULL,
    house_number     varchar(10)  NOT NULL,
    apartment_office varchar(10),                                   -- BR-3.2: может отсутствовать
    CONSTRAINT address_pk PRIMARY KEY (address_id),
    CONSTRAINT address_street_not_blank_chk       CHECK (btrim(street) <> ''),
    CONSTRAINT address_house_not_blank_chk        CHECK (btrim(house_number) <> ''),
    CONSTRAINT address_apartment_not_blank_chk    CHECK (apartment_office IS NULL OR btrim(apartment_office) <> '')
);
COMMENT ON TABLE tsys_food.address IS 'Физический адрес (BR-3.1)';

-- ---------------------------------------------------------------- client
CREATE TABLE tsys_food.client (
    client_id    uuid        NOT NULL DEFAULT exts.uuid_generate_v4(),
    login        varchar(50) NOT NULL,
    password     char(32)    NOT NULL,
    phone_number char(12)    NOT NULL,
    CONSTRAINT client_pk PRIMARY KEY (client_id),
    CONSTRAINT client_login_uq  UNIQUE (login),                                  -- BR-2.2
    CONSTRAINT client_phone_uq  UNIQUE (phone_number),                           -- BR-2.2
    CONSTRAINT client_login_not_blank_chk CHECK (btrim(login) <> ''),            -- BR-2.1
    CONSTRAINT client_password_md5_chk    CHECK (password ~ '^[0-9a-f]{32}$'),   -- BR-2.3
    CONSTRAINT client_phone_format_chk    CHECK (phone_number ~ '^\+7[0-9]{10}$') -- BR-2.1
);
COMMENT ON TABLE tsys_food.client IS 'Клиент (BR-2.x). ФИО не хранится (BR-2.6)';

-- ---------------------------------------------------------------- client_address
CREATE TABLE tsys_food.client_address (
    client_id  uuid NOT NULL,
    address_id uuid NOT NULL,
    CONSTRAINT client_address_pk PRIMARY KEY (client_id, address_id),            -- BR-2.5
    CONSTRAINT client_address_client_fk  FOREIGN KEY (client_id)
        REFERENCES tsys_food.client (client_id) ON DELETE CASCADE,             -- BR-2.4
    CONSTRAINT client_address_address_fk FOREIGN KEY (address_id)
        REFERENCES tsys_food.address (address_id) ON DELETE RESTRICT           -- BR-2.4, BR-3.5
);
CREATE INDEX client_address_address_idx ON tsys_food.client_address (address_id);

-- ---------------------------------------------------------------- restaurant
CREATE TABLE tsys_food.restaurant (
    restaurant_id   uuid         NOT NULL DEFAULT exts.uuid_generate_v4(),
    restaurant_name varchar(100) NOT NULL,
    address_id      uuid         NOT NULL,
    description     text         NOT NULL,
    work_start      time         NOT NULL,
    work_end        time         NOT NULL,
    company_details text         NOT NULL,
    rating          numeric(3,2),                                                -- BR-9.7: NULL, если отзывов нет
    status          tsys_food.restaurant_status NOT NULL DEFAULT 'активен',
    CONSTRAINT restaurant_pk PRIMARY KEY (restaurant_id),
    CONSTRAINT restaurant_address_uq UNIQUE (address_id),                        -- BR-3.3
    CONSTRAINT restaurant_address_fk FOREIGN KEY (address_id)
        REFERENCES tsys_food.address (address_id) ON DELETE RESTRICT,          -- BR-3.3, BR-3.5
    CONSTRAINT restaurant_name_not_blank_chk CHECK (btrim(restaurant_name) <> ''),
    CONSTRAINT restaurant_rating_chk   CHECK (rating BETWEEN 0 AND 5),           -- BR-4.2
    CONSTRAINT restaurant_work_time_chk CHECK (work_end > work_start)            -- BR-4.4
);

-- ---------------------------------------------------------------- courier
CREATE TABLE tsys_food.courier (
    courier_id     uuid         NOT NULL DEFAULT exts.uuid_generate_v4(),
    fio            varchar(150) NOT NULL,
    phone_number   char(12)     NOT NULL,
    status         tsys_food.courier_status NOT NULL DEFAULT 'свободен',
    hire_date      date         NOT NULL DEFAULT current_date,
    dismissal_date date,                                                          -- BR-6.3: NULL у работающего
    coefficient    numeric(2,1) NOT NULL DEFAULT 0.1,                             -- BR-6.5
    CONSTRAINT courier_pk PRIMARY KEY (courier_id),
    CONSTRAINT courier_phone_uq UNIQUE (phone_number),
    CONSTRAINT courier_fio_not_blank_chk   CHECK (btrim(fio) <> ''),
    CONSTRAINT courier_phone_format_chk    CHECK (phone_number ~ '^\+7[0-9]{10}$'),
    CONSTRAINT courier_coefficient_chk     CHECK (coefficient BETWEEN 0.1 AND 0.5), -- BR-6.4
    CONSTRAINT courier_dismissed_has_date_chk
        CHECK (status <> 'уволен' OR dismissal_date IS NOT NULL),                -- BR-6.3
    CONSTRAINT courier_dismissal_after_hire_chk
        CHECK (dismissal_date IS NULL OR dismissal_date >= hire_date)            -- BR-6.1, BR-6.3
);

-- ---------------------------------------------------------------- courier_pay
CREATE TABLE tsys_food.courier_pay (
    year             smallint      NOT NULL,
    month            smallint      NOT NULL,
    courier_id       uuid          NOT NULL,
    amount           numeric(12,2) NOT NULL DEFAULT 0,
    coefficient_used numeric(2,1)  NOT NULL,
    CONSTRAINT courier_pay_pk PRIMARY KEY (year, month, courier_id),              -- BR-10.3
    CONSTRAINT courier_pay_courier_fk FOREIGN KEY (courier_id)
        REFERENCES tsys_food.courier (courier_id) ON DELETE RESTRICT,           -- BR-10.1
    CONSTRAINT courier_pay_month_chk  CHECK (month BETWEEN 1 AND 12),             -- BR-10.2
    CONSTRAINT courier_pay_year_chk   CHECK (year BETWEEN 2000 AND 2100),         -- BR-10.2
    CONSTRAINT courier_pay_amount_chk CHECK (amount >= 0),                        -- BR-10.4
    CONSTRAINT courier_pay_coefficient_chk CHECK (coefficient_used BETWEEN 0.1 AND 0.5) -- BR-6.4
);
CREATE INDEX courier_pay_courier_idx ON tsys_food.courier_pay (courier_id);

-- ---------------------------------------------------------------- product_category
CREATE TABLE tsys_food.product_category (
    product_category_id   uuid        NOT NULL DEFAULT exts.uuid_generate_v4(),
    product_category_name varchar(50) NOT NULL,
    CONSTRAINT product_category_pk PRIMARY KEY (product_category_id),
    CONSTRAINT product_category_name_not_blank_chk CHECK (btrim(product_category_name) <> '')
);

-- ---------------------------------------------------------------- product
CREATE TABLE tsys_food.product (
    product_id          uuid          NOT NULL DEFAULT exts.uuid_generate_v4(),
    product_name        varchar(100)  NOT NULL,
    product_category_id uuid          NOT NULL,
    price               numeric(10,2) NOT NULL,
    restaurant_id       uuid          NOT NULL,
    photo_url           text,                                                     -- BR-5.6
    rating              numeric(3,2),                                             -- BR-9.7
    status              tsys_food.product_status NOT NULL DEFAULT 'доступно',
    description         text          NOT NULL,
    CONSTRAINT product_pk PRIMARY KEY (product_id),
    CONSTRAINT product_category_fk FOREIGN KEY (product_category_id)
        REFERENCES tsys_food.product_category (product_category_id) ON DELETE RESTRICT, -- BR-5.1
    CONSTRAINT product_restaurant_fk FOREIGN KEY (restaurant_id)
        REFERENCES tsys_food.restaurant (restaurant_id) ON DELETE RESTRICT,     -- BR-5.1
    CONSTRAINT product_name_not_blank_chk CHECK (btrim(product_name) <> ''),
    CONSTRAINT product_price_chk  CHECK (price >= 0),                             -- BR-5.3
    CONSTRAINT product_rating_chk CHECK (rating BETWEEN 0 AND 5),                 -- BR-5.4
    CONSTRAINT product_photo_not_blank_chk CHECK (photo_url IS NULL OR btrim(photo_url) <> '')
);
CREATE INDEX product_restaurant_idx ON tsys_food.product (restaurant_id);
CREATE INDEX product_category_idx   ON tsys_food.product (product_category_id);

-- ---------------------------------------------------------------- order
-- Имя "order" сохранено (в кавычках), как в ERD (BR-13.1).
CREATE TABLE tsys_food."order" (
    order_id           uuid          NOT NULL DEFAULT exts.uuid_generate_v4(),
    courier_id         uuid          NOT NULL,
    client_id          uuid          NOT NULL,
    address_id         uuid          NOT NULL,
    restaurant_id      uuid          NOT NULL,
    order_timestamp    timestamp     NOT NULL DEFAULT localtimestamp,
    delivery_timestamp timestamp,                                                 -- BR-7.12
    order_amount       numeric(12,2) NOT NULL,
    commission         numeric(12,2) GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED,                -- BR-1.4, BR-7.10
    total_amount       numeric(12,2) GENERATED ALWAYS AS (order_amount + round(order_amount * 0.10, 2)) STORED, -- BR-7.10
    status             tsys_food.order_status     NOT NULL DEFAULT 'создан',
    pay_status         tsys_food.order_pay_status NOT NULL DEFAULT 'ожидает',
    description        text          NOT NULL,
    CONSTRAINT order_pk PRIMARY KEY (order_id),
    CONSTRAINT order_courier_fk    FOREIGN KEY (courier_id)
        REFERENCES tsys_food.courier (courier_id) ON DELETE RESTRICT,           -- BR-7.5
    CONSTRAINT order_restaurant_fk FOREIGN KEY (restaurant_id)
        REFERENCES tsys_food.restaurant (restaurant_id) ON DELETE RESTRICT,     -- BR-7.2
    CONSTRAINT order_client_fk     FOREIGN KEY (client_id)
        REFERENCES tsys_food.client (client_id) ON DELETE RESTRICT,             -- BR-7.2
    CONSTRAINT order_address_fk    FOREIGN KEY (address_id)
        REFERENCES tsys_food.address (address_id) ON DELETE RESTRICT,           -- BR-7.4, BR-3.5
    CONSTRAINT order_client_address_fk FOREIGN KEY (client_id, address_id)
        REFERENCES tsys_food.client_address (client_id, address_id) ON DELETE RESTRICT, -- BR-7.4
    CONSTRAINT order_amount_chk    CHECK (order_amount >= 0),                     -- BR-7.10
    CONSTRAINT order_total_min_chk CHECK (total_amount >= 1000),                  -- BR-1.8, BR-7.11
    CONSTRAINT order_delivery_after_create_chk
        CHECK (delivery_timestamp IS NULL OR delivery_timestamp >= order_timestamp), -- BR-7.13
    CONSTRAINT order_delivered_has_time_chk
        CHECK (status <> 'доставлен' OR delivery_timestamp IS NOT NULL)           -- BR-7.12
);
CREATE INDEX order_courier_idx        ON tsys_food."order" (courier_id);
CREATE INDEX order_restaurant_idx     ON tsys_food."order" (restaurant_id);
CREATE INDEX order_client_address_idx ON tsys_food."order" (client_id, address_id);
CREATE INDEX order_address_idx        ON tsys_food."order" (address_id);
CREATE INDEX order_status_ts_idx      ON tsys_food."order" (status, order_timestamp);

-- ---------------------------------------------------------------- order_structure
CREATE TABLE tsys_food.order_structure (
    order_id   uuid         NOT NULL,
    product_id uuid         NOT NULL,
    quantity   numeric(8,3) NOT NULL,
    CONSTRAINT order_structure_pk PRIMARY KEY (order_id, product_id),            -- BR-7.16
    CONSTRAINT order_structure_order_fk FOREIGN KEY (order_id)
        REFERENCES tsys_food."order" (order_id) ON DELETE CASCADE,              -- BR-7.14
    CONSTRAINT order_structure_product_fk FOREIGN KEY (product_id)
        REFERENCES tsys_food.product (product_id) ON DELETE RESTRICT,           -- BR-7.14
    CONSTRAINT order_structure_quantity_chk CHECK (quantity > 0)                  -- BR-7.15
);
CREATE INDEX order_structure_product_idx ON tsys_food.order_structure (product_id);

-- ---------------------------------------------------------------- payment
CREATE TABLE tsys_food.payment (
    payment_id        uuid          NOT NULL DEFAULT exts.uuid_generate_v4(),
    order_id          uuid          NOT NULL,
    payment_type      tsys_food.payment_type   NOT NULL,
    amount            numeric(12,2) NOT NULL,
    transaction_code    varchar(64)   NOT NULL,
    payment_timestamp timestamp     NOT NULL DEFAULT localtimestamp,
    status            tsys_food.payment_status NOT NULL DEFAULT 'в_обработке',
    CONSTRAINT payment_pk PRIMARY KEY (payment_id),
    CONSTRAINT payment_order_fk FOREIGN KEY (order_id)
        REFERENCES tsys_food."order" (order_id) ON DELETE CASCADE,              -- BR-8.1
    CONSTRAINT payment_transaction_uq UNIQUE (transaction_code),                   -- BR-8.3
    CONSTRAINT payment_transaction_not_blank_chk CHECK (btrim(transaction_code) <> ''), -- BR-8.3
    CONSTRAINT payment_amount_chk CHECK (amount >= 1000)                          -- BR-8.4 + BR-7.11
);
CREATE INDEX payment_order_idx ON tsys_food.payment (order_id);
-- BR-8.1: не более одной успешной попытки на заказ (частичный уникальный индекс)
CREATE UNIQUE INDEX payment_one_success_per_order_uq
    ON tsys_food.payment (order_id) WHERE status = 'успех';

-- ---------------------------------------------------------------- review
CREATE TABLE tsys_food.review (
    review_id        uuid      NOT NULL DEFAULT exts.uuid_generate_v4(),
    client_id        uuid      NOT NULL,
    review_timestamp timestamp NOT NULL DEFAULT localtimestamp,
    entity_id        uuid      NOT NULL,
    entity_type      tsys_food.review_entity_type NOT NULL,
    order_id         uuid      NOT NULL,
    description      text      NOT NULL,
    photo_url        text,                                                        -- BR-9.3
    rating           smallint  NOT NULL,
    CONSTRAINT review_pk PRIMARY KEY (review_id),
    CONSTRAINT review_client_fk FOREIGN KEY (client_id)
        REFERENCES tsys_food.client (client_id) ON DELETE CASCADE,              -- BR-9.1
    CONSTRAINT review_order_fk FOREIGN KEY (order_id)
        REFERENCES tsys_food."order" (order_id) ON DELETE CASCADE,              -- BR-9.2
    CONSTRAINT review_one_per_entity_uq UNIQUE (order_id, entity_type, entity_id), -- BR-9.5
    CONSTRAINT review_rating_chk CHECK (rating BETWEEN 1 AND 5),                  -- BR-9.4
    CONSTRAINT review_description_not_blank_chk CHECK (btrim(description) <> ''),
    CONSTRAINT review_photo_not_blank_chk CHECK (photo_url IS NULL OR btrim(photo_url) <> '')
);
CREATE INDEX review_entity_idx ON tsys_food.review (entity_type, entity_id);
CREATE INDEX review_client_idx ON tsys_food.review (client_id);

-- ============================================================================
-- 3. Триггеры целостности (то, что нельзя выразить CHECK/FK без денормализации)
--
-- Генератор insert_test_data сам вычисляет агрегаты (rating, pay_status) и на
-- время своей работы выставляет локальный флаг foodexpress.generator = 'on',
-- при котором триггеры-«вычислители» (rating_change, payment_sync_pay_status)
-- не выполняют работу. Триггеры-«валидаторы» работают всегда.
-- ============================================================================

-- BR-7.3: все блюда заказа — из ресторана заказа
CREATE FUNCTION tsys_food.order_structure_check_restaurant()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tsys_food, pg_catalog
AS $$
DECLARE
    v_order_rest   uuid;
    v_product_rest uuid;
BEGIN
    SELECT restaurant_id INTO v_order_rest   FROM "order" WHERE order_id   = NEW.order_id;
    SELECT restaurant_id INTO v_product_rest FROM product WHERE product_id = NEW.product_id;
    IF v_order_rest IS DISTINCT FROM v_product_rest THEN
        RAISE EXCEPTION 'Блюдо % принадлежит ресторану %, а заказ % оформлен в ресторане % (BR-7.3)',
            NEW.product_id, v_product_rest, NEW.order_id, v_order_rest
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER order_structure_check_restaurant_trg
BEFORE INSERT OR UPDATE OF order_id, product_id ON tsys_food.order_structure
FOR EACH ROW EXECUTE FUNCTION tsys_food.order_structure_check_restaurant();

-- BR-7.3: нельзя сменить ресторан у заказа с позициями / ресторан у блюда, которое уже в заказах другого ресторана
CREATE FUNCTION tsys_food.order_restaurant_change_check()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tsys_food, pg_catalog
AS $$
BEGIN
    IF TG_TABLE_NAME = 'order' THEN
        IF EXISTS (SELECT 1 FROM order_structure os JOIN product p USING (product_id)
                   WHERE os.order_id = NEW.order_id AND p.restaurant_id <> NEW.restaurant_id) THEN
            RAISE EXCEPTION 'Нельзя сменить ресторан заказа %: в нём есть блюда другого ресторана (BR-7.3)', NEW.order_id
                USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        IF EXISTS (SELECT 1 FROM order_structure os JOIN "order" o USING (order_id)
                   WHERE os.product_id = NEW.product_id AND o.restaurant_id <> NEW.restaurant_id) THEN
            RAISE EXCEPTION 'Нельзя перенести блюдо % в другой ресторан: оно уже есть в заказах (BR-7.3)', NEW.product_id
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER order_restaurant_change_check_trg
BEFORE UPDATE OF restaurant_id ON tsys_food."order"
FOR EACH ROW WHEN (OLD.restaurant_id IS DISTINCT FROM NEW.restaurant_id)
EXECUTE FUNCTION tsys_food.order_restaurant_change_check();

CREATE TRIGGER product_restaurant_change_check_trg
BEFORE UPDATE OF restaurant_id ON tsys_food.product
FOR EACH ROW WHEN (OLD.restaurant_id IS DISTINCT FROM NEW.restaurant_id)
EXECUTE FUNCTION tsys_food.order_restaurant_change_check();

-- BR-8.4: сумма попытки оплаты = общей сумме заказа
CREATE FUNCTION tsys_food.payment_check_amount()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tsys_food, pg_catalog
AS $$
DECLARE
    v_total numeric;
BEGIN
    SELECT total_amount INTO v_total FROM "order" WHERE order_id = NEW.order_id;
    IF v_total IS NOT NULL AND NEW.amount <> v_total THEN
        RAISE EXCEPTION 'Сумма оплаты % не равна общей сумме заказа % (BR-8.4)', NEW.amount, v_total
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER payment_check_amount_trg
BEFORE INSERT OR UPDATE OF order_id, amount ON tsys_food.payment
FOR EACH ROW EXECUTE FUNCTION tsys_food.payment_check_amount();

-- BR-8.4 со стороны заказа: нельзя изменить сумму заказа, по которому уже есть попытки оплаты
-- на прежнюю сумму (AFTER — чтобы total_amount был уже пересчитан как GENERATED)
CREATE FUNCTION tsys_food.order_amount_payment_check()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tsys_food, pg_catalog
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM payment WHERE order_id = NEW.order_id AND amount <> NEW.total_amount) THEN
        RAISE EXCEPTION 'Нельзя изменить сумму заказа %: есть попытки оплаты на сумму, отличную от новой общей суммы % (BR-8.4)',
            NEW.order_id, NEW.total_amount
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER order_amount_payment_check_trg
AFTER UPDATE OF order_amount ON tsys_food."order"
FOR EACH ROW WHEN (OLD.order_amount IS DISTINCT FROM NEW.order_amount)
EXECUTE FUNCTION tsys_food.order_amount_payment_check();

-- BR-8.7: агрегированный статус оплаты заказа вычисляется по попыткам
CREATE FUNCTION tsys_food.payment_sync_pay_status()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tsys_food, pg_catalog
AS $$
DECLARE
    v_order uuid;
BEGIN
    IF current_setting('foodexpress.generator', true) = 'on' THEN
        RETURN NULL;
    END IF;
    FOREACH v_order IN ARRAY ARRAY[
        CASE WHEN TG_OP <> 'INSERT' THEN OLD.order_id END,
        CASE WHEN TG_OP <> 'DELETE' THEN NEW.order_id END]
    LOOP
        CONTINUE WHEN v_order IS NULL;
        UPDATE "order" o
        SET pay_status = s.new_status
        FROM (
            SELECT CASE
                       WHEN bool_or(p.status = 'успех')       THEN 'оплачен'
                       WHEN bool_or(p.status = 'в_обработке') THEN 'ожидает'
                       WHEN count(p.payment_id) > 0           THEN 'ошибка'
                       ELSE 'ожидает'
                   END::order_pay_status AS new_status
            FROM payment p
            WHERE p.order_id = v_order
        ) s
        WHERE o.order_id = v_order
          AND o.pay_status IS DISTINCT FROM s.new_status;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE TRIGGER payment_sync_pay_status_trg
AFTER INSERT OR UPDATE OR DELETE ON tsys_food.payment
FOR EACH ROW EXECUTE FUNCTION tsys_food.payment_sync_pay_status();

-- BR-9.1: полиморфная ссылка entity_id указывает на существующую сущность своего типа
-- (замена FK, который невозможен для полиморфной связи)
CREATE FUNCTION tsys_food.review_check_entity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tsys_food, pg_catalog
AS $$
DECLARE
    v_ok boolean;
BEGIN
    IF NEW.entity_type = 'заказ' THEN
        v_ok := EXISTS (SELECT 1 FROM "order" WHERE order_id = NEW.entity_id);
    ELSIF NEW.entity_type = 'ресторан' THEN
        v_ok := EXISTS (SELECT 1 FROM restaurant WHERE restaurant_id = NEW.entity_id);
    ELSE -- 'блюдо'
        v_ok := EXISTS (SELECT 1 FROM product WHERE product_id = NEW.entity_id);
    END IF;

    IF NOT v_ok THEN
        RAISE EXCEPTION 'Отзыв невозможен: объект "%" с id % не существует (BR-9.1)',
            NEW.entity_type, NEW.entity_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER review_check_entity_trg
BEFORE INSERT OR UPDATE OF entity_type, entity_id, order_id ON tsys_food.review
FOR EACH ROW EXECUTE FUNCTION tsys_food.review_check_entity();

-- Вторая половина «замены FK» для полиморфной ссылки: при удалении блюда / ресторана / заказа
-- отзывы на него удаляются (аналог ON DELETE CASCADE у review_order_fk), чтобы entity_id
-- не указывал в никуда. Рейтинги пересчитает rating_change на удалении отзывов.
CREATE FUNCTION tsys_food.review_entity_cleanup()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tsys_food, pg_catalog
AS $$
BEGIN
    IF TG_TABLE_NAME = 'product' THEN
        DELETE FROM review WHERE entity_type = 'блюдо'    AND entity_id = OLD.product_id;
    ELSIF TG_TABLE_NAME = 'restaurant' THEN
        DELETE FROM review WHERE entity_type = 'ресторан' AND entity_id = OLD.restaurant_id;
    ELSE
        DELETE FROM review WHERE entity_type = 'заказ'    AND entity_id = OLD.order_id;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER product_review_cleanup_trg
AFTER DELETE ON tsys_food.product
FOR EACH ROW EXECUTE FUNCTION tsys_food.review_entity_cleanup();

CREATE TRIGGER restaurant_review_cleanup_trg
AFTER DELETE ON tsys_food.restaurant
FOR EACH ROW EXECUTE FUNCTION tsys_food.review_entity_cleanup();

CREATE TRIGGER order_review_cleanup_trg
AFTER DELETE ON tsys_food."order"
FOR EACH ROW EXECUTE FUNCTION tsys_food.review_entity_cleanup();

-- ============================================================================
-- 4. FOOD-105. Триггер пересчёта рейтинга
-- ============================================================================
CREATE FUNCTION tsys_food.rating_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tsys_food, pg_catalog
AS $$
DECLARE
    v_type review_entity_type;
    v_id   uuid;
    i      int;
BEGIN
    IF current_setting('foodexpress.generator', true) = 'on' THEN
        RETURN NULL;   -- генератор сам выставляет агрегаты
    END IF;

    -- i = 1: старая сущность (UPDATE/DELETE), i = 2: новая (INSERT/UPDATE)
    FOR i IN 1..2 LOOP
        IF i = 1 THEN
            CONTINUE WHEN TG_OP = 'INSERT';
            v_type := OLD.entity_type; v_id := OLD.entity_id;
        ELSE
            CONTINUE WHEN TG_OP = 'DELETE';
            -- при UPDATE без смены сущности второй раз не пересчитываем
            CONTINUE WHEN TG_OP = 'UPDATE'
                      AND OLD.entity_type = NEW.entity_type
                      AND OLD.entity_id   = NEW.entity_id;
            v_type := NEW.entity_type; v_id := NEW.entity_id;
        END IF;

        IF v_type = 'блюдо' THEN
            UPDATE product
            SET rating = (SELECT round(avg(r.rating), 2) FROM review r
                          WHERE r.entity_type = 'блюдо' AND r.entity_id = v_id)
            WHERE product_id = v_id;
        ELSIF v_type = 'ресторан' THEN
            UPDATE restaurant
            SET rating = (SELECT round(avg(r.rating), 2) FROM review r
                          WHERE r.entity_type = 'ресторан' AND r.entity_id = v_id)
            WHERE restaurant_id = v_id;
        END IF;
        -- 'заказ': агрегата нет (BR-9.6)
    END LOOP;

    RETURN NULL;  -- AFTER-триггер; обновляются другие таблицы → рекурсии нет
END;
$$;

CREATE TRIGGER rating_change_trg
AFTER INSERT OR UPDATE OR DELETE ON tsys_food.review
FOR EACH ROW EXECUTE FUNCTION tsys_food.rating_change();

-- ============================================================================
-- 5. FOOD-102. Генератор тестовых данных
-- ============================================================================
CREATE PROCEDURE tsys_food.insert_test_data(value int)
LANGUAGE plpgsql
SET search_path = tsys_food, exts, pg_catalog
-- Таблицы растут от 0 строк внутри одной транзакции. Без этой настройки PostgreSQL кэширует
-- «общий» план поиска по ключу (FK-проверки, триггеры-валидаторы), построенный на пустой таблице,
-- — Seq Scan, и генерация становится квадратичной (value=1000: минуты вместо секунд).
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
    -- окно дат: 6 календарных месяцев (текущий + 5 предыдущих), конец — за 3 часа до «сейчас»,
    -- чтобы доставка и отзыв тоже оказались в прошлом
    v_start  timestamp := date_trunc('month', localtimestamp) - interval '5 months';
    v_span   interval  := (localtimestamp - interval '3 hours') - (date_trunc('month', localtimestamp) - interval '5 months');

    v_cat    uuid[] := '{}';
    v_cour   uuid[] := '{}';
    v_hires  date[] := '{}';   -- даты найма курьеров (параллельно v_cour)
    v_disms  date[] := '{}';   -- даты увольнения курьеров (NULL — работает)
    v_addr   uuid[] := '{}';
    v_rest   uuid[] := '{}';
    v_cli    uuid[] := '{}';
    v_orders uuid[] := '{}';

    -- меню: все блюда вызова, сгруппированные по ресторанам (samples, раздел 7:
    -- ID собираются в массивы один раз, в цикле по заказам таблица product не читается)
    v_prod   uuid[]    := '{}';
    v_price  numeric[] := '{}';
    v_prest  int[]     := '{}';   -- индекс ресторана (в v_rest) для каждого блюда
    v_rcnt   int[];               -- сколько блюд у ресторана
    v_roff   int[];               -- смещение блюд ресторана в v_prod / v_price
    v_idx    int[];
    v_ri     int;
    v_j      int;
    v_tmp    int;
    v_p      numeric;

    -- доставки по (курьер, месяц) копятся при генерации заказов → courier_pay без чтения "order"
    v_base_m int := (extract(year  FROM date_trunc('month', localtimestamp) - interval '5 months') * 12
                   + extract(month FROM date_trunc('month', localtimestamp) - interval '5 months'))::int;
    v_dcnt   int[];
    v_dcom   numeric[];
    v_mi     int;
    v_pos    int;
    v_comm_o numeric;

    v_id      uuid;
    v_status  courier_status;
    v_hire    date;
    v_dism    date;
    v_start_t time;

    -- заказ
    v_ci      int;
    v_rest_id uuid;
    v_prods   uuid[];
    v_prices  numeric[];
    v_qty     numeric[];
    v_n       int;
    v_sum     numeric;
    v_factor  numeric;
    v_ts      timestamp;
    v_cidx    int;
    v_lo      timestamp;
    v_hi      timestamp;
    v_dts     timestamp;
    v_ostatus order_status;
    v_total   numeric;
    v_etype   review_entity_type;
    v_eid     uuid;

    -- зарплата
    v_coef    numeric;
    v_cnt     bigint;
    v_comm    numeric;
    v_month   timestamp;
    v_cour_id uuid;

    i int;
    k int;
BEGIN
    IF value IS NULL OR value < 1 THEN
        RAISE EXCEPTION 'insert_test_data: value должен быть >= 1, передано %', value
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- агрегаты (rating, pay_status) генератор считает сам (см. раздел 3)
    PERFORM set_config('foodexpress.generator', 'on', true);

    -- ---------------------------------------------------- product_category: value
    FOR i IN 1..value LOOP
        INSERT INTO product_category (product_category_id, product_category_name)
        VALUES (exts.uuid_generate_v4(),
                left(repeat(md5(random()::text), 2), 1 + floor(random() * 50)::int))
        RETURNING product_category_id INTO v_id;
        v_cat := v_cat || v_id;
    END LOOP;

    -- ---------------------------------------------------- courier: value (минимум один активный, BR-6.6)
    FOR i IN 1..value LOOP
        v_status := CASE WHEN i = 1 THEN 'свободен'::courier_status
                         ELSE (enum_range(NULL::courier_status))[1 + floor(random() * cardinality(enum_range(NULL::courier_status)))::int]
                    END;
        -- нанят не позже вчерашнего дня, уволен не раньше найма и не позже вчерашнего дня
        v_hire := (v_start + random() * (v_span - interval '1 day'))::date;
        v_dism := CASE WHEN v_status = 'уволен'
                       THEN v_hire + floor(random() * (current_date - v_hire))::int END;
        LOOP
            v_id := NULL;
            INSERT INTO courier (courier_id, fio, phone_number, status, hire_date, dismissal_date, coefficient)
            VALUES (exts.uuid_generate_v4(),
                    left(repeat(md5(random()::text), 5), 1 + floor(random() * 150)::int),
                    '+7' || lpad(floor(random() * 1e10)::bigint::text, 10, '0'),
                    v_status, v_hire, v_dism, 0.1)
            ON CONFLICT DO NOTHING
            RETURNING courier_id INTO v_id;
            EXIT WHEN v_id IS NOT NULL;   -- повтор при коллизии телефона
        END LOOP;
        v_cour  := v_cour  || v_id;
        v_hires := v_hires || v_hire;
        v_disms := v_disms || v_dism;
    END LOOP;

    -- ---------------------------------------------------- address: value * 5
    -- первые value — под рестораны, остальные value * 4 — под клиентов (BR-11.7)
    FOR i IN 1..value * 5 LOOP
        INSERT INTO address (address_id, street, house_number, apartment_office)
        VALUES (exts.uuid_generate_v4(),
                left(repeat(md5(random()::text), 4), 1 + floor(random() * 100)::int),
                left(md5(random()::text), 1 + floor(random() * 10)::int),
                CASE WHEN i > value AND random() < 0.7
                     THEN left(md5(random()::text), 1 + floor(random() * 10)::int) END)
        RETURNING address_id INTO v_id;
        v_addr := v_addr || v_id;
    END LOOP;

    -- ---------------------------------------------------- restaurant: value
    FOR i IN 1..value LOOP
        v_start_t := time '06:00' + floor(random() * 361)::int * interval '1 minute';   -- 06:00..12:00
        INSERT INTO restaurant (restaurant_id, restaurant_name, address_id, description,
                                work_start, work_end, company_details, rating, status)
        VALUES (exts.uuid_generate_v4(),
                left(repeat(md5(random()::text), 4), 1 + floor(random() * 100)::int),
                v_addr[i],
                md5(random()::text),
                v_start_t,
                v_start_t + (6 + floor(random() * 6)::int) * interval '1 hour',      -- +6..11 ч, не позже 23:00
                'ИНН ' || lpad(floor(random() * 1e10)::bigint::text, 10, '0')
                    || ', ОГРН ' || lpad(floor(random() * 1e13)::bigint::text, 13, '0')
                    || ', р/с ' || lpad(floor(random() * 1e10)::bigint::text, 10, '0')
                    || lpad(floor(random() * 1e10)::bigint::text, 10, '0'),
                NULL,
                (enum_range(NULL::restaurant_status))[1 + floor(random() * cardinality(enum_range(NULL::restaurant_status)))::int])
        RETURNING restaurant_id INTO v_id;
        v_rest := v_rest || v_id;
    END LOOP;

    -- ---------------------------------------------------- client: value
    FOR i IN 1..value LOOP
        LOOP
            v_id := NULL;
            INSERT INTO client (client_id, login, password, phone_number)
            VALUES (exts.uuid_generate_v4(),
                    left(md5(random()::text || clock_timestamp()::text) || md5(random()::text),
                         8 + floor(random() * 43)::int),                               -- 8..50 символов
                    md5(random()::text),                                               -- BR-2.3
                    '+7' || lpad(floor(random() * 1e10)::bigint::text, 10, '0'))
            ON CONFLICT DO NOTHING
            RETURNING client_id INTO v_id;
            EXIT WHEN v_id IS NOT NULL;   -- повтор при коллизии логина/телефона
        END LOOP;
        v_cli := v_cli || v_id;
    END LOOP;

    -- ---------------------------------------------------- client_address
    -- клиент i владеет адресами v_addr[value + i + k*value], k = 0..3 (все 4*value адресов разобраны,
    -- без повторов, BR-2.5) + разделяет первый адрес соседа (BR-2.4: один адрес — нескольким клиентам)
    INSERT INTO client_address (client_id, address_id)
    SELECT v_cli[g.n], v_addr[value + g.n + h.m * value]
    FROM generate_series(1, value) AS g(n), generate_series(0, 3) AS h(m);

    IF value > 1 THEN
        INSERT INTO client_address (client_id, address_id)
        SELECT v_cli[g.n], v_addr[value + (g.n % value) + 1]
        FROM generate_series(1, value) AS g(n);
    END IF;

    -- ---------------------------------------------------- product: value * 5
    -- первые value блюд — по одному в каждый ресторан (у каждого ресторана есть меню)
    FOR i IN 1..value * 5 LOOP
        v_ri := CASE WHEN i <= value THEN i ELSE 1 + floor(random() * value)::int END;
        INSERT INTO product (product_id, product_name, product_category_id, price, restaurant_id,
                             photo_url, rating, status, description)
        VALUES (exts.uuid_generate_v4(),
                left(repeat(md5(random()::text), 4), 1 + floor(random() * 100)::int),
                v_cat[1 + floor(random() * value)::int],
                round((50 + random() * 1450)::numeric, 2),                         -- > 0: минималку можно добрать
                v_rest[v_ri],
                CASE WHEN random() < 0.7 THEN 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg' END,
                NULL,
                (enum_range(NULL::product_status))[1 + floor(random() * cardinality(enum_range(NULL::product_status)))::int],
                md5(random()::text))
        RETURNING product_id, price INTO v_id, v_p;
        v_prod  := v_prod  || v_id;
        v_price := v_price || v_p;
        v_prest := v_prest || v_ri;
    END LOOP;

    -- группируем блюда по ресторанам: блюда ресторана r лежат в позициях v_roff[r] + 1 .. v_roff[r] + v_rcnt[r]
    SELECT array_agg(u.p ORDER BY u.r), array_agg(u.pr ORDER BY u.r)
    INTO v_prod, v_price
    FROM unnest(v_prod, v_price, v_prest) AS u(p, pr, r);

    v_rcnt := array_fill(0, ARRAY[value]);
    FOREACH v_ri IN ARRAY v_prest LOOP
        v_rcnt[v_ri] := v_rcnt[v_ri] + 1;
    END LOOP;
    v_roff := array_fill(0, ARRAY[value]);
    FOR i IN 2..value LOOP
        v_roff[i] := v_roff[i - 1] + v_rcnt[i - 1];
    END LOOP;

    v_dcnt := array_fill(0, ARRAY[value * 6]);
    v_dcom := array_fill(0::numeric, ARRAY[value * 6]);

    -- ---------------------------------------------------- order + order_structure + payment + review: value * 5
    FOR i IN 1..value * 5 LOOP
        v_ci      := 1 + floor(random() * value)::int;
        v_ri      := 1 + floor(random() * value)::int;
        v_rest_id := v_rest[v_ri];

        -- 1..5 РАЗНЫХ блюд этого ресторана (BR-7.3, BR-7.14, BR-7.16): частичное перемешивание
        -- Фишера–Йетса индексов меню ресторана, без обращения к таблице product
        v_n := 1 + floor(random() * least(5, v_rcnt[v_ri]))::int;
        v_idx := '{}';
        FOR k IN 1..v_rcnt[v_ri] LOOP
            v_idx := v_idx || k;
        END LOOP;
        v_prods  := '{}';
        v_prices := '{}';
        FOR k IN 1..v_n LOOP
            v_j := k + floor(random() * (v_rcnt[v_ri] - k + 1))::int;
            v_tmp := v_idx[k]; v_idx[k] := v_idx[v_j]; v_idx[v_j] := v_tmp;
            v_prods  := v_prods  || v_prod [v_roff[v_ri] + v_idx[k]];
            v_prices := v_prices || v_price[v_roff[v_ri] + v_idx[k]];
        END LOOP;

        v_qty := '{}';
        v_sum := 0;
        FOR k IN 1..v_n LOOP
            v_qty := v_qty || CASE WHEN random() < 0.2 THEN 0.5 ELSE 1 + floor(random() * 3) END::numeric; -- BR-7.15
            v_sum := v_sum + v_prices[k] * v_qty[k];
        END LOOP;
        -- минимальная сумма заказа (BR-1.8): total = 1.1 * order_amount >= 1000  ⇔  order_amount >= 909.10
        IF v_sum < 910 THEN
            v_factor := ceil(910 / v_sum);
            FOR k IN 1..v_n LOOP
                v_qty[k] := v_qty[k] * v_factor;
            END LOOP;
            v_sum := v_sum * v_factor;
        END IF;

        -- курьер и время заказа: заказ попадает в период работы курьера (с даты найма
        -- до конца дня увольнения минус 3 ч — чтобы и доставка уложилась в период работы)
        v_cidx    := 1 + floor(random() * value)::int;
        v_lo      := greatest(v_start, v_hires[v_cidx]::timestamp);
        v_hi      := least(localtimestamp - interval '3 hours',
                           coalesce(v_disms[v_cidx] + interval '1 day' - interval '3 hours', 'infinity'::timestamp));
        v_ts      := v_lo + random() * (v_hi - v_lo);
        v_ostatus := (enum_range(NULL::order_status))[1 + floor(random() * cardinality(enum_range(NULL::order_status)))::int];
        v_dts     := CASE WHEN v_ostatus = 'доставлен'
                          THEN v_ts + (20 + floor(random() * 101)::int) * interval '1 minute' END;

        INSERT INTO "order" (order_id, courier_id, client_id, address_id, restaurant_id,
                             order_timestamp, delivery_timestamp, order_amount, status, pay_status, description)
        VALUES (exts.uuid_generate_v4(),
                v_cour[v_cidx],
                v_cli[v_ci],
                v_addr[value + v_ci + floor(random() * 4)::int * value],            -- адрес этого клиента (BR-7.4)
                v_rest_id,
                v_ts, v_dts,
                round(v_sum, 2),
                v_ostatus,
                'оплачен',                                                           -- одна успешная оплата ниже (BR-8.7)
                md5(random()::text))
        RETURNING order_id, total_amount, commission INTO v_id, v_total, v_comm_o;
        v_orders := v_orders || v_id;

        -- учёт доставки для courier_pay (месяц — по order_timestamp, BR-10.2, BR-10.5)
        IF v_ostatus = 'доставлен' THEN
            v_mi  := (extract(year FROM v_ts) * 12 + extract(month FROM v_ts))::int - v_base_m;  -- 0..5
            v_pos := (v_cidx - 1) * 6 + v_mi + 1;
            v_dcnt[v_pos] := v_dcnt[v_pos] + 1;
            v_dcom[v_pos] := v_dcom[v_pos] + v_comm_o;
        END IF;

        INSERT INTO order_structure (order_id, product_id, quantity)
        SELECT v_id, v_prods[g.n], v_qty[g.n] FROM generate_series(1, v_n) AS g(n);

        -- payment: ровно одна попытка на заказ, успешная (BR-8.1), сумма = total_amount (BR-8.4)
        INSERT INTO payment (payment_id, order_id, payment_type, amount, transaction_code, payment_timestamp, status)
        VALUES (exts.uuid_generate_v4(), v_id,
                (enum_range(NULL::payment_type))[1 + floor(random() * cardinality(enum_range(NULL::payment_type)))::int],
                v_total,
                'TX' || upper(md5(random()::text || clock_timestamp()::text)),           -- внешний код транзакции (не наш ID)
                v_ts + (1 + floor(random() * 10)::int) * interval '1 minute',
                'успех');

        -- review: один отзыв на заказ, объект — из этого заказа (BR-9.2, BR-9.5)
        -- первый заказ вызова получает отзыв на заказ целиком: так ручной отзыв на любое блюдо
        -- в «первый» заказ (проверка E.3 протокола) не может упасть на UNIQUE BR-9.5
        v_etype := CASE WHEN i = 1 THEN 'заказ'::review_entity_type
                        ELSE (enum_range(NULL::review_entity_type))[1 + floor(random() * cardinality(enum_range(NULL::review_entity_type)))::int]
                   END;
        v_eid   := CASE v_etype
                       WHEN 'блюдо'    THEN v_prods[1 + floor(random() * v_n)::int]
                       WHEN 'ресторан' THEN v_rest_id
                       ELSE v_id
                   END;
        INSERT INTO review (review_id, client_id, review_timestamp, entity_id, entity_type, order_id,
                            description, photo_url, rating)
        VALUES (exts.uuid_generate_v4(), v_cli[v_ci],
                coalesce(v_dts, v_ts) + (10 + floor(random() * 51)::int) * interval '1 minute',
                v_eid, v_etype, v_id,
                md5(random()::text),
                CASE WHEN random() < 0.5 THEN 'https://cdn.foodexpress.ru/review/' || md5(random()::text) || '.jpg' END,
                1 + floor(random() * 5)::int);                                         -- 1..5 (BR-9.4)
    END LOOP;

    -- ---------------------------------------------------- рейтинги (BR-9.6) — напрямую, без rating_change
    UPDATE product p
    SET rating = a.avg_rating
    FROM (SELECT entity_id, round(avg(rating), 2) AS avg_rating
          FROM review
          WHERE entity_type = 'блюдо'
            AND entity_id IN (SELECT entity_id FROM review
                              WHERE order_id = ANY (v_orders) AND entity_type = 'блюдо')
          GROUP BY entity_id) a
    WHERE p.product_id = a.entity_id;

    UPDATE restaurant r
    SET rating = a.avg_rating
    FROM (SELECT entity_id, round(avg(rating), 2) AS avg_rating
          FROM review
          WHERE entity_type = 'ресторан'
            AND entity_id IN (SELECT entity_id FROM review
                              WHERE order_id = ANY (v_orders) AND entity_type = 'ресторан')
          GROUP BY entity_id) a
    WHERE r.restaurant_id = a.entity_id;

    -- ---------------------------------------------------- courier_pay за 6 месяцев (BR-10.2, BR-10.7)
    -- Заказы этого вызова назначены только курьерам этого вызова → история старых курьеров не меняется.
    -- Число доставок и сумма комиссий по (курьер, месяц) накоплены в v_dcnt / v_dcom при генерации заказов.
    FOR i IN 1..value LOOP
        v_coef := 0.1;                                                                 -- BR-6.5
        FOR k IN 0..5 LOOP
            v_month := v_start + k * interval '1 month';
            v_cnt   := v_dcnt[(i - 1) * 6 + k + 1];                                    -- только 'доставлен' (BR-10.5)
            v_comm  := v_dcom[(i - 1) * 6 + k + 1];

            -- зарплата = коэффициент текущего месяца × сумма комиссий (BR-10.2)
            INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
            VALUES (extract(year FROM v_month)::int, extract(month FROM v_month)::int,
                    v_cour[i], round(v_coef * v_comm, 2), v_coef);

            -- коэффициент на следующий месяц; уволенному после месяца увольнения не назначается (BR-10.6)
            IF v_disms[i] IS NULL OR v_disms[i] >= (v_month + interval '1 month')::date THEN
                v_coef := CASE WHEN v_cnt <= 150 THEN 0.1
                               WHEN v_cnt <= 250 THEN 0.2
                               WHEN v_cnt <= 500 THEN 0.3
                               ELSE 0.5 END;
            END IF;
        END LOOP;
        UPDATE courier SET coefficient = v_coef WHERE courier_id = v_cour[i];          -- коэффициент на следующий месяц
    END LOOP;

    PERFORM set_config('foodexpress.generator', 'off', true);
END;
$$;

COMMENT ON PROCEDURE tsys_food.insert_test_data(int) IS 'FOOD-102: генерация тестовых данных по BR-11.7; можно вызывать многократно';

-- ============================================================================
-- 6. FOOD-103. Удаление тестовых данных
-- ============================================================================
CREATE PROCEDURE tsys_food.erase_test_data()
LANGUAGE plpgsql
SET search_path = tsys_food, pg_catalog
AS $$
BEGIN
    -- порядок: дочерние → родительские; TRUNCATE одним оператором проверяет FK для всего набора
    TRUNCATE TABLE
        review,
        payment,
        order_structure,
        "order",
        courier_pay,
        product,
        product_category,
        client_address,
        client,
        restaurant,
        courier,
        address;
END;
$$;

COMMENT ON PROCEDURE tsys_food.erase_test_data() IS 'FOOD-103: очистка всех таблиц схемы';

-- ============================================================================
-- 7. FOOD-104. Добавление блюда
-- ============================================================================
CREATE PROCEDURE tsys_food.add_product(
    p_restaurant_id       uuid,
    p_product_category_id uuid,
    p_name                varchar,
    p_price               numeric,
    p_rating              numeric                    DEFAULT NULL,
    p_status              tsys_food.product_status DEFAULT 'доступно',
    p_description         text                       DEFAULT NULL,
    p_photo_url           text                       DEFAULT NULL
)
LANGUAGE plpgsql
SET search_path = tsys_food, exts, pg_catalog
AS $$
DECLARE
    v_id uuid;
BEGIN
    IF p_restaurant_id IS NULL OR NOT EXISTS (SELECT 1 FROM restaurant WHERE restaurant_id = p_restaurant_id) THEN
        RAISE EXCEPTION 'add_product: ресторан с restaurant_id = % не существует', p_restaurant_id
            USING ERRCODE = 'foreign_key_violation', HINT = 'BR-5.1: блюдо принадлежит существующему ресторану';
    END IF;
    IF p_product_category_id IS NULL OR NOT EXISTS (SELECT 1 FROM product_category WHERE product_category_id = p_product_category_id) THEN
        RAISE EXCEPTION 'add_product: категория с product_category_id = % не существует', p_product_category_id
            USING ERRCODE = 'foreign_key_violation', HINT = 'BR-5.1, BR-5.7: блюдо принадлежит существующей категории';
    END IF;
    IF p_name IS NULL OR btrim(p_name) = '' OR length(p_name) > 100 THEN
        RAISE EXCEPTION 'add_product: название блюда обязательно и должно содержать от 1 до 100 символов'
            USING ERRCODE = 'check_violation', HINT = 'BR-5.2';
    END IF;
    IF p_price IS NULL OR p_price < 0 THEN
        RAISE EXCEPTION 'add_product: цена должна быть неотрицательной, передано %', p_price
            USING ERRCODE = 'check_violation', HINT = 'BR-5.3';
    END IF;
    IF p_rating IS NOT NULL AND (p_rating < 0 OR p_rating > 5) THEN
        RAISE EXCEPTION 'add_product: рейтинг должен быть от 0 до 5, передано %', p_rating
            USING ERRCODE = 'check_violation', HINT = 'BR-5.4';
    END IF;
    IF p_status IS NULL THEN
        RAISE EXCEPTION 'add_product: статус блюда обязателен'
            USING ERRCODE = 'not_null_violation', HINT = 'BR-5.5';
    END IF;
    IF p_description IS NULL OR btrim(p_description) = '' THEN
        RAISE EXCEPTION 'add_product: описание блюда обязательно'
            USING ERRCODE = 'not_null_violation', HINT = 'BR-5.2, BR-11.3';
    END IF;

    BEGIN
        INSERT INTO product (product_id, product_name, product_category_id, price, restaurant_id,
                             photo_url, rating, status, description)
        VALUES (exts.uuid_generate_v4(), p_name, p_product_category_id, p_price, p_restaurant_id,
                p_photo_url, p_rating, p_status, p_description)
        RETURNING product_id INTO v_id;
    EXCEPTION
        WHEN check_violation OR not_null_violation OR foreign_key_violation
             OR numeric_value_out_of_range OR string_data_right_truncation THEN
            RAISE EXCEPTION 'add_product: данные блюда нарушают ограничения схемы: %', SQLERRM
                USING ERRCODE = SQLSTATE;
    END;

    RAISE NOTICE 'add_product: добавлено блюдо %', v_id;
END;
$$;

COMMENT ON PROCEDURE tsys_food.add_product(uuid, uuid, varchar, numeric, numeric, tsys_food.product_status, text, text)
    IS 'FOOD-104: добавление блюда; product_id генерируется через exts.uuid_generate_v4()';

-- ============================================================================
-- 8. FOOD-106. Статистика по ресторанам
--    Каждая таблица читается ровно один раз; без оконных функций и LATERAL.
--    "Случайный при равенстве" — через DISTINCT ON с random() во вторичном ключе.
-- ============================================================================
CREATE FUNCTION tsys_food.get_statistic()
RETURNS TABLE (
    restaurant_name   varchar,
    best_product_name varchar,
    total_amount      numeric,
    avg_amount        numeric,
    best_user         varchar
)
LANGUAGE sql
VOLATILE   -- random() при выборе «случайного из равных» → функция не STABLE
SET search_path = tsys_food, pg_catalog
AS $$
    WITH delivered AS MATERIALIZED (          -- единственный проход по "order"
        SELECT o.order_id, o.restaurant_id, o.client_id, o.total_amount
        FROM "order" o
        WHERE o.status = 'доставлен'
    ),
    rest_client AS (                          -- (ресторан, клиент): число заказов и сумма
        SELECT d.restaurant_id, d.client_id, count(*) AS cnt, sum(d.total_amount) AS amount
        FROM delivered d
        GROUP BY d.restaurant_id, d.client_id
    ),
    rest_totals AS (
        SELECT rc.restaurant_id, sum(rc.amount) AS total_amount, sum(rc.amount) / sum(rc.cnt) AS avg_amount
        FROM rest_client rc
        GROUP BY rc.restaurant_id
    ),
    best_client AS (
        SELECT DISTINCT ON (rc.restaurant_id) rc.restaurant_id, rc.client_id
        FROM rest_client rc
        ORDER BY rc.restaurant_id, rc.cnt DESC, random()
    ),
    best_product AS (                         -- единственный проход по order_structure
        SELECT DISTINCT ON (d.restaurant_id) d.restaurant_id, os.product_id
        FROM delivered d
        JOIN order_structure os ON os.order_id = d.order_id
        GROUP BY d.restaurant_id, os.product_id
        ORDER BY d.restaurant_id, sum(os.quantity) DESC, random()
    )
    SELECT r.restaurant_name,
           p.product_name,
           coalesce(t.total_amount, 0),
           round(coalesce(t.avg_amount, 0), 2),
           c.login                            -- ФИО клиента не хранится (BR-2.6) → логин
    FROM restaurant r
    LEFT JOIN rest_totals  t  ON t.restaurant_id  = r.restaurant_id
    LEFT JOIN best_client  bc ON bc.restaurant_id = r.restaurant_id
    LEFT JOIN client       c  ON c.client_id      = bc.client_id
    LEFT JOIN best_product bp ON bp.restaurant_id = r.restaurant_id
    LEFT JOIN product      p  ON p.product_id     = bp.product_id
    ORDER BY r.restaurant_name;
$$;

COMMENT ON FUNCTION tsys_food.get_statistic() IS 'FOOD-106: статистика по ресторанам (только доставленные заказы)';

-- ============================================================================
-- 9. FOOD-107. Зарплата курьеров за текущий месяц
-- ============================================================================
CREATE PROCEDURE tsys_food.courier_salary()
LANGUAGE plpgsql
SET search_path = tsys_food, pg_catalog
AS $$
DECLARE
    v_month_start timestamp := date_trunc('month', localtimestamp);
    v_year        smallint  := extract(year  FROM localtimestamp)::smallint;
    v_month       smallint  := extract(month FROM localtimestamp)::smallint;
BEGIN
    WITH stats AS (
        SELECT c.courier_id,
               c.status,
               -- при повторном вызове в том же месяце берём уже применённый коэффициент,
               -- а не обновлённый «на следующий месяц» → результат идемпотентен
               coalesce(cp.coefficient_used, c.coefficient) AS coef,
               count(o.order_id)                      AS cnt,
               coalesce(sum(o.commission), 0)         AS commission_sum
        FROM courier c
        LEFT JOIN courier_pay cp
               ON cp.courier_id = c.courier_id AND cp.year = v_year AND cp.month = v_month
        LEFT JOIN "order" o
               ON o.courier_id = c.courier_id
              AND o.status = 'доставлен'                                           -- BR-10.5
              AND o.order_timestamp >= v_month_start
              AND o.order_timestamp <  v_month_start + interval '1 month'
        GROUP BY c.courier_id, c.status, cp.coefficient_used, c.coefficient
    ),
    pay AS (
        INSERT INTO courier_pay AS cp (year, month, courier_id, amount, coefficient_used)
        SELECT v_year, v_month, s.courier_id, round(s.coef * s.commission_sum, 2), s.coef
        FROM stats s
        ON CONFLICT (year, month, courier_id)                                     -- BR-10.3
        DO UPDATE SET amount = EXCLUDED.amount, coefficient_used = EXCLUDED.coefficient_used
        RETURNING cp.courier_id
    )
    UPDATE courier c
    SET coefficient = CASE WHEN s.cnt <= 150 THEN 0.1
                           WHEN s.cnt <= 250 THEN 0.2
                           WHEN s.cnt <= 500 THEN 0.3
                           ELSE 0.5 END
    FROM stats s
    WHERE c.courier_id = s.courier_id
      AND s.status <> 'уволен'                                                    -- BR-10.6
      AND EXISTS (SELECT 1 FROM pay WHERE pay.courier_id = s.courier_id);
END;
$$;

COMMENT ON PROCEDURE tsys_food.courier_salary() IS 'FOOD-107: расчёт зарплаты курьеров за текущий месяц и коэффициента на следующий';

-- ============================================================================
-- 10. FOOD-108. Отчёт «сколько денег»
-- ============================================================================
CREATE VIEW tsys_food.how_much_money AS
WITH RECURSIVE
bounds AS (
    SELECT date_trunc('month', min(order_timestamp)) AS first_month,
           date_trunc('month', max(order_timestamp)) AS last_month
    FROM tsys_food."order"
    WHERE status = 'доставлен'
),
months AS (                                   -- непрерывная серия месяцев (BR-11.9)
    SELECT first_month AS month_start, last_month
    FROM bounds
    WHERE first_month IS NOT NULL
    UNION ALL
    SELECT month_start + interval '1 month', last_month
    FROM months
    WHERE month_start < last_month
),
orders_by_month AS (
    SELECT date_trunc('month', order_timestamp) AS month_start,
           sum(order_amount) AS sum_no_commission,
           sum(total_amount) AS sum_with_commission
    FROM tsys_food."order"
    WHERE status = 'доставлен'
    GROUP BY 1
),
pay_by_month AS (
    SELECT make_date(year, month, 1)::timestamp AS month_start,
           sum(amount) AS courier_pay
    FROM tsys_food.courier_pay
    GROUP BY 1
),
base AS (
    SELECT m.month_start,
           coalesce(o.sum_no_commission, 0)::numeric   AS sum_no_commission,
           coalesce(o.sum_with_commission, 0)::numeric AS sum_with_commission,
           coalesce(p.courier_pay, 0)::numeric         AS courier_pay
    FROM months m
    LEFT JOIN orders_by_month o ON o.month_start = m.month_start
    LEFT JOIN pay_by_month    p ON p.month_start = m.month_start
),
calc AS (
    SELECT month_start, sum_no_commission, sum_with_commission,
           sum_with_commission - sum_no_commission AS commission,
           courier_pay
    FROM base
),
with_prev AS (
    SELECT c.*, lag(c.commission) OVER (ORDER BY c.month_start) AS prev_commission
    FROM calc c
)
SELECT to_char(month_start, 'YYYY-MM')::text        AS year_month,
       sum_no_commission::numeric                   AS sum_no_commission,
       sum_with_commission::numeric                 AS sum_with_commission,
       commission::numeric                          AS commission,
       prev_commission::numeric                     AS prev_commission,
       (commission - prev_commission)::numeric      AS commission_diff,
       courier_pay::numeric                         AS courier_pay,
       (commission - courier_pay)::numeric          AS net_profit
FROM with_prev
ORDER BY month_start;

COMMENT ON VIEW tsys_food.how_much_money IS 'FOOD-108: помесячный финансовый отчёт по доставленным заказам';
