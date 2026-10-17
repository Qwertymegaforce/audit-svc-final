# Итоговая работа: развёртывание и мониторинг audit-svc

Я делал вариант 2: GitHub Actions, образы в ghcr.io и self-hosted раннер с меткой `deploy` на целевой машине. Репозиторий `audit-svc-final` приватный, образ лежит в `ghcr.io/qwertymegaforce/audit-svc-final`. Релизы: `v1.0.0` (первое развёртывание), `v1.0.1` (неудачная смена пароля, ниже объясняю почему), `v1.0.2` (смена пароля, которая прошла) и `v1.1.0` (задание со звёздочкой).

## Как всё устроено

Образ собирается многоступенчатым `Dockerfile`: в первой ступени Poetry собирает wheel и зависимости по `poetry.lock`, в финальную попадает только то, что ставится через `pip install --no-index`. Сервис работает от пользователя `10001:10001`, `.dockerignore` пропускает только нужные файлы. Сборка воспроизводимая: задан `SOURCE_DATE_EPOCH`, не создаются `.pyc`, в BuildKit включён `rewrite-timestamp`, provenance выключен. Поэтому образы из одного и того же кода под разными тегами получаются побайтно одинаковыми.

В `.github/workflows/ci.yml` три задачи: `test` (pytest, отчёт JUnit), `build` (образ в ghcr.io с тегом `main_<sha>` на ветке или `vX.Y.Z` на теге) и `deploy`. `deploy` запускается только на теге, на раннере с меткой `deploy`, в окружении `production`.

Секреты лежат в `deploy/inventories/prom/group_vars/all/vault.yml`, он зашифрован через `ansible-vault`. Ключ хранится только в секрете окружения `ANSIBLE_VAULT_KEY` и передаётся через `--vault-password-file ./vault-pass.sh`. Задачи с паролями выполняются с `no_log`.

Развёртывание описано в `deploy/audit-svc.play.yml`. Он создаёт docker-сеть `audit` и том для PostgreSQL, поднимает базу, создаёт БД `audit` и роль `audit_svc` модулями `community.postgresql`, кладёт `config.yaml` из шаблона (права `0640`), применяет миграции до обновления сервиса, затем запускает сервис, Nginx и nginx-exporter. Когда меняется конфиг, срабатывает хендлер `Reload audit-svc`: он делает `POST /reload` по адресу контейнера, и сервис перечитывает конфиг без перезапуска. Хендлеры выполняются принудительно (`meta: flush_handlers`) до проверки здоровья сервиса.

Nginx работает по белому списку точных путей: `/healthz`, `/metrics` и `/api/events`, на всё остальное отвечает 404. Страница `stub_status` вынесена на отдельный порт 8081, который наружу не публикуется. Мониторинг лежит в `monitoring/compose.yaml` (Prometheus и Grafana в той же сети), дашборд сервиса подключается из `monitoring/grafana/audit-svc.json`, дашборд Nginx я импортировал из `nginx.json`.

## Задание 1. Сборка и публикация образа

Пайплайн на ветке `main` (коммит `63bb7ce`): `test` и `build` прошли, `deploy` пропущен, потому что на ветку он не запускается.

В логе `build` образ опубликован как `ghcr.io/qwertymegaforce/audit-svc-final:main_63bb7ce`, дайджест `sha256:34089047462995f1185e230edfa43ff5b57a8dd9a12b22f66e3f1753f24d607b`.

Тот же образ в разделе Packages:

## Задание 2. База данных и секреты

PostgreSQL 17 работает в контейнере, данные лежат в томе `audit_pgdata`, порты наружу не опубликованы. БД `audit` и пользователя `audit_svc` (владельца базы) создаёт Ansible. Пароли суперпользователя и `audit_svc` хранятся в зашифрованном `vault.yml` (в начале файла `$ANSIBLE_VAULT;1.1;AES256`), в логах их нет.

## Задание 3. Развёртывание из CI

Пайплайн для тега `v1.0.0`: `test`, `build` и `deploy` прошли.

В логе первого развёртывания применились миграции `0001` и `0002`, итог `PLAY RECAP: ok=29 changed=16 failed=0`.

Повторный запуск без изменений: `ok=27 changed=0 failed=0`, хендлеры не срабатывали, миграции `done: 0 applied, 2 already in place`.

### Смена пароля audit_svc

Сначала я выпустил `v1.0.1` (коммит `3f2e32e`), и развёртывание упало на шаге `Wait until audit-svc is healthy`: `/healthz` отвечал `503 database is unavailable`. Ошибка была в моём плейбуке. Хендлер `Reload audit-svc` выполнялся в самом конце, а проверка здоровья шла раньше. После смены пароля сервис держал соединения со старым паролем и не мог переподключиться, и до перечитывания конфига дело не доходило. Я добавил `meta: flush_handlers` перед проверкой здоровья и повторные попытки для хендлера перечитывания. Теги защищены от изменения (ruleset `protect-tags`), поэтому `v1.0.1` остался в истории как есть, а смену пароля я выпустил заново как `v1.0.2`.

Состояние до смены. Счётчик перечитываний равен 2, потому что перед этим я один раз вызвал перечитывание вручную:

```
StartedAt: 2026-10-16T16:06:12.368104283Z
image id:  sha256:34089047462995f1185e230edfa43ff5b57a8dd9a12b22f66e3f1753f24d607b
audit_config_reloads_total{result="success"} 2.0
```

В логе `v1.0.2` задачи `Role audit_svc` и `config.yaml for the service` в статусе `changed`, контейнер `audit-svc` в статусе `ok`, а `RUNNING HANDLER [Reload audit-svc]` выполнился до `Wait until audit-svc is healthy`. Итог `PLAY RECAP: ok=28 changed=3 failed=0`.

Состояние после:

```
StartedAt: 2026-10-16T16:06:12.368104283Z
image id:  sha256:34089047462995f1185e230edfa43ff5b57a8dd9a12b22f66e3f1753f24d607b
2026-10-16 16:45:46,190 [INFO] audit_svc.main: config reloaded, reconnected to the database
audit_config_reloads_total{result="success"} 3.0
healthz: 200
```

Время запуска контейнера и идентификатор образа не изменились, то есть контейнер не перезапускался. Образ `v1.0.2` совпадает с `v1.0.0`, потому что код не менялся, менялся только пароль.

## Задание 4. Nginx и nginx-exporter

```
--- reload до: 1
--- healthz: {"status": "ok"}
--- /reload: 404 404 404 404
--- reload после: 1
--- порты:
nginx-exporter  0.0.0.0:9113->9113/tcp
nginx           80/tcp, 0.0.0.0:8088->8080/tcp
audit-svc       8080/tcp
postgres        5432/tcp
--- exporter: nginx_up 1
--- stub_status на основном порту: 404
```

Я попробовал четыре варианта запроса `/reload` снаружи, и все дали 404, счётчик перечитываний не изменился. Наружу опубликованы только `nginx` и `nginx-exporter`; у `audit-svc` и `postgres` указан только порт образа, на хост он не проброшен.

## Задание 5. Мониторинг

Для нагрузки я запускал `generate` (адрес `nginx:8080`, `--duration 1200`) из образа `ghcr.io/qwertymegaforce/audit-svc-final:v1.0.2` в сети `audit`.

На странице `/targets` в Prometheus обе цели в состоянии `UP`:

Дашборд сервиса: события в секунду по приложениям, коды ответов в процентах и панель «Сервис запущен»:

Импортированный дашборд Nginx под нагрузкой:

Панель «Сервис запущен» после `docker stop audit-svc` показывает `DOWN`, после `docker start audit-svc` снова `UP`:

## ★ Миграции при каждом развёртывании

Задача `Apply database migrations` на каждом развёртывании запускает `migrate` из образа релиза до обновления сервиса. Если миграция упала, новый контейнер сервиса не стартует. Релизы `v1.0.0` и `v1.0.2` вышли без миграции `0003`, а в `v1.1.0` я добавил `0003_events_actor_index.sql`.

Лог развёртывания `v1.1.0`:

```
"[INFO] applying 0003_events_actor_index",
"[INFO] done: 1 applied, 2 already in place"
PLAY RECAP: ok=27 changed=3 failed=0
```

При повторном запуске того же релиза миграций нет: `done: 0 applied, 3 already in place`, `PLAY RECAP: ok=27 changed=0 failed=0`.

Проверка в базе: индекс `events_actor_idx` по столбцу `actor` создан, сервис отвечает `{"status": "ok"}`.

