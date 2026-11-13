-- ============================================================================
-- FOOD-109. Пользователь inspector и права
-- Запускать под суперпользователем (или владельцем схемы) ПОСЛЕ восстановления
-- foodexpress_tsys.backup / выполнения foodexpress.sql. Скрипт идемпотентен.
-- ============================================================================

-- 1. Пользователь (CREATE ROLE не поддерживает IF NOT EXISTS)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'inspector') THEN
        CREATE ROLE inspector WITH LOGIN PASSWORD 'NetoSQL2025';
    ELSE
        ALTER ROLE inspector WITH LOGIN PASSWORD 'NetoSQL2025';
    END IF;
END $$;

-- 2. Подключение к текущей БД
DO $$
BEGIN
    EXECUTE format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO inspector', current_database());
END $$;

-- 3. Системные каталоги (по умолчанию доступны PUBLIC — выдаём явно на случай отзыва)
GRANT USAGE ON SCHEMA information_schema TO inspector;
GRANT USAGE ON SCHEMA pg_catalog         TO inspector;

-- 4. exts — для exts.uuid_generate_v4()
GRANT USAGE   ON SCHEMA exts                  TO inspector;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA exts TO inspector;

-- 5. Рабочая схема — полный доступ
GRANT ALL PRIVILEGES ON SCHEMA tsys_food                   TO inspector;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA tsys_food  TO inspector;  -- таблицы и представление
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA tsys_food  TO inspector;
GRANT ALL PRIVILEGES ON ALL ROUTINES  IN SCHEMA tsys_food  TO inspector;  -- функции и процедуры

-- enum-типы
DO $$
DECLARE
    t record;
BEGIN
    FOR t IN
        SELECT typname FROM pg_type
        WHERE typnamespace = 'tsys_food'::regnamespace AND typtype = 'e'
    LOOP
        EXECUTE format('GRANT ALL PRIVILEGES ON TYPE tsys_food.%I TO inspector', t.typname);
    END LOOP;
END $$;

-- 6. Права на объекты, которые будут созданы в схеме позже
ALTER DEFAULT PRIVILEGES IN SCHEMA tsys_food GRANT ALL PRIVILEGES ON TABLES    TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA tsys_food GRANT ALL PRIVILEGES ON SEQUENCES TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA tsys_food GRANT ALL PRIVILEGES ON ROUTINES  TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA tsys_food GRANT ALL PRIVILEGES ON TYPES     TO inspector;

-- 7. Удобство: search_path по умолчанию для inspector
ALTER ROLE inspector SET search_path TO tsys_food, exts, public;
