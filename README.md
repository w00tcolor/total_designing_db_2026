# FoodExpress — база данных
## Выполнил студент: Цыс Павел Александрович

Добро пожаловать в проект. Твоя задача — спроектировать и реализовать базу данных для сервиса доставки еды.

## С чего начать
1. Прочитай [онбординг](docs/onboarding.md) — это твой первый рабочий день.
2. Изучи [бизнес-правила](docs/company-rules.md).
3. Открой [бэклог](docs/backlog.md) — там твои задачи.

## Если ты никогда не работал с Git
1. Посмотри [скринкаст](docs/git-screencast.md) (10 минут).
2. Держи под рукой [шпаргалку](docs/git-cheatsheet.md).

## Сдача работы
Все требования к составу файлов, формату резервной копии и процессу сдачи описаны в файле [docs/acceptance.md](docs/acceptance.md).

## Платформы
Репозиторий зеркалируется на две платформы. Форкай ту, где тебе удобнее:
- GitHub: [`<ссылка_на_github>`](https://github.com/NKhashchanov/total_designing_db_2026)
- GitVerse: [`<ссылка_на_gitverse>`](https://gitverse.ru/nkhashchanov/total_designing_db_2026)

## Решение (схема `tsys_food`)

| Файл | Содержимое |
|---|---|
| [`db/schema/foodexpress.sql`](db/schema/foodexpress.sql) | Схема, 8 enum, 12 таблиц, ограничения, триггеры, `insert_test_data`, `erase_test_data`, `add_product`, `rating_change`, `get_statistic`, `courier_salary`, `how_much_money` (FOOD-101…108) |
| [`db/schema/grants.sql`](db/schema/grants.sql) | Пользователь `inspector` / `NetoSQL2025` и права (FOOD-109) |
| [`db/constraints.md`](db/constraints.md) | Обоснование каждого ограничения со ссылками на BR, решения ловушек, 3НФ |
| [`db/tests.md`](db/tests.md) | Протокол прогона под `inspector` |
| `db/foodexpress_tsys.backup` | `pg_dump -Fc -x -n tsys_food` (структура + тестовые данные `insert_test_data(10)`; нужен `pg_restore` 17+) (FOOD-110) |

Развёртывание (в БД уже есть схема `exts` с `uuid-ossp`):

```bash
pg_restore -d <db> --exit-on-error --no-owner db/foodexpress_tsys.backup   # или: psql -d <db> -f db/schema/foodexpress.sql
psql -d <db> -f db/schema/grants.sql
```
