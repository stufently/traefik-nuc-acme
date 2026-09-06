# Веха M2 — Docker-образ и интеграционный стенд с Pebble

Продолжение вехи M1 (патч `patches/0001-csr-subject.patch` в `main`, `8898c9b`).
Задача: собрать образ пропатченного Traefik и ДОКАЗАТЬ на живом стенде, что
`csrSubject` доезжает до реального сертификата — и при выпуске, и при продлении.

Эта спека лежит в клоне как `docs/specs/m2-image-and-stand.md` и приехала УЖЕ
закоммиченной — отдельно её коммитить не надо.

## Где работать

- Клон: `/home/deploy/exec-clones/traefik-nuc-m2` (твой). Живое дерево
  `/home/deploy/github/traefik-nuc-acme` и другие клоны в `~/exec-clones/` НЕ ТРОГАТЬ.
- Новая ветка от `main`: `m2-image-and-stand`.
- Уже лежит в клоне, качать не нужно: `.upstream/traefik-v3.7.13.tar.gz`
  (sha256 `c1cff59261740def3a393ea2c4d7c7d0184eb8eb39c88402b26eb3b3e4735b96`),
  кэши `.gomodcache/` и `.gocache/`. Всё под `.gitignore`.

## Среда: у тебя ЕСТЬ Docker, сеть и слушающие сокеты

Проверено пробой в этой же панели 2026-09-06 22:02 UTC, файл `env-probe.txt`
в корне клона, все команды rc=0: `docker info` → `29.8.0 overlayfs`;
`docker image inspect` по дайджесту → образ виден; `docker run -d -p 24000:14000`
+ `curl -ks https://localhost:24000/dir` → ACME-директория; `curl
https://proxy.golang.org/` → 200; `socket.bind(...); listen()` → ok.

Docker-демон общий с хозяином, поэтому образ Pebble уже вытянут и `docker pull`
для него не нужен. Не сокращай критерии «из-за песочницы» — её нет.

Работай своим юзером (`id -u` = 1002, `id -g` = 1002), не под root. Контейнеры,
пишущие в смонтированные каталоги, запускай с `user: "1002:1002"`, иначе файлы
достанутся root и хозяин потеряет к ним доступ.

## Проверенные факты, на которых стоит веха

Каждый измерен до написания спеки. Не перепроверяй их заново, но если факт
разойдётся с реальностью — остановись и доложи, это важнее вехи.

| Факт | Чем измерено |
|---|---|
| У образа Pebble НЕТ версионных тегов — только `latest` и `sha-<commit>`. Пин `:v2.10.1` даст `manifest unknown`. Пинить ДАЙДЖЕСТОМ. | обход каталога тегов GHCR, 31 тег |
| Дайджест: `ghcr.io/letsencrypt/pebble@sha256:ddf230642b1a584f519f32e347de1b05a6e4c1f6c35c1863b33effeab5f78199`, платформы linux/amd64 + linux/arm64 | `ghcr.io/v2/.../manifests/latest` |
| **Валидация challenge ходит на 5002 (HTTP-01) и 5001 (TLS-ALPN), НЕ на 80/443.** Это `httpPort`/`tlsPort` из конфига, с которым собран образ. | `test/config/pebble-config.json` в репо Pebble |
| **Корневой CA генерируется ЗАНОВО при каждом старте** контейнера. Вшить его в образ нельзя — стенд обязан забирать его в рантайме с `https://<pebble>:15000/roots/0`. | логи запуска: «Generated new root issuer CN=Pebble Root CA 45fc6c» |
| Pebble НАМЕРЕННО отбраковывает 5% нонсов и спит перед валидацией. Без `PEBBLE_WFE_NONCEREJECT=0` и `PEBBLE_VA_NOSLEEP=1` стенд будет случайно краснеть, и это спишут на наш код. | логи: «Configured to reject 5% of good nonces»; `wfe/wfe.go`, `va/va.go` |
| Бинарь Traefik собирается ОФЛАЙН без Node и без веб-интерфейса: `//go:embed static` доволен каталогом-заглушкой `webui/static/DONT-EDIT-FILES-IN-THIS-DIRECTORY.md`. | `upstream-go.sh build ./cmd/traefik` с `GOPROXY=off` → бинарь 243 МБ |
| **Неверный `csrSubject` НЕ роняет Traefik**: он пишет `ERR The ACME resolve is skipped from the resolvers list  error="invalid CSR subject: …"` и продолжает работать без этого резолвера. Значит любой критерий, ждущий ЗАВЕРШЕНИЯ процесса на плохом конфиге, повиснет навсегда. | запуск собранного бинаря с `country=RUS`: сообщение в логе, `rc=124` по таймауту |
| **Pebble НЕ переносит Subject из CSR в выданный сертификат** — берёт только SAN и публичный ключ (`ca/ca.go:466`: `newCertificate(csr.DNSNames, csr.IPAddresses, csr.PublicKey, …)`). Так же поступает Let's Encrypt. Значит `C=RU` в ЛИСТЕ не докажет ни один мок-CA; доказывать надо на CSR, который мы ОТПРАВЛЯЕМ. | чтение `ca/ca.go`; стенд выдал `subject=` при живом `csrSubject.country=RU` |
| **У стенда ДВА разных CA.** `roots/0` — issuing CA (новый на каждый старт), им подписаны выданные сертификаты. TLS самого `https://pebble:14000` подписан СТАТИЧЕСКИМ `test/certs/pebble.minica.pem`. Доверять надо ОБОИМ: только `roots/0` — и рукопожатие к директории падает, а выглядит это как «ACME не работает». | находка исполнителя, подтверждена работающим стендом |
| **Pebble дружелюбен к прокси**: абсолютные URL он строит из `request.Host` и уважает `X-Forwarded-Proto` (`wfe/wfe.go:631` `relativeEndpoint`). Поэтому обратный прокси перед ним прозрачен — все последующие запросы, включая finalize с CSR, пойдут через прокси сами. | чтение `wfe/wfe.go` |
| Продление можно вызвать НЕМЕДЛЕННО: при `certificatesDuration >= 8760` (год) период продления — 4 месяца, а сертификат Pebble живёт 90 дней, поэтому `renewCertificates` на старте видит его просроченным и продлевает сразу. | `getCertificateRenewDurations`, `provider.go:828` |

## Что сделать

### 1. `Dockerfile` — многостадийная сборка

- Стадия сборки: `golang:1.27-alpine` (пин тегом И дайджестом — дайджест возьми
  сам при сборке и впиши). Распаковать `.upstream/traefik-v3.7.13.tar.gz`,
  наложить `patches/0001-csr-subject.patch`, собрать `./cmd/traefik`.
  Веб-интерфейс НЕ собирать: Node и yarn в сборку не тащим — **это осознанное
  решение владельца**, образ идёт без дашборда.
- Бинарь собирать с `-ldflags="-s -w"` (иначе 243 МБ) и с версией в
  `github.com/traefik/traefik/v3/pkg/version.Version`.
- Финальная стадия: `alpine:3.24` (пин тегом и дайджестом), `ca-certificates`,
  `tzdata`, копия бинаря, `EXPOSE 80`, `ENTRYPOINT ["/traefik"]` — как в
  официальном Dockerfile апстрима.
- Тег образа: `traefik-nuc-acme:3.7.13-nuc.1`. **Голый `3.7.13` не использовать
  никогда** — образ не должен путаться с официальным Traefik.

### 2. `docker/compose.yaml` — стенд

Сервисы: `pebble` (по дайджесту) и `traefik` (собранный образ). Требования:

- Pebble с `PEBBLE_WFE_NONCEREJECT=0` и `PEBBLE_VA_NOSLEEP=1`.
- Тестовый домен обязан РЕЗОЛВИТЬСЯ у Pebble в контейнер Traefik: повесь на
  сервис `traefik` сетевой алиас с этим именем, тогда встроенный DNS Docker
  отдаст Pebble нужный адрес. Своего DNS-сервера не поднимай.
- Traefik слушает entryPoint для HTTP-01 на **5002** — именно туда Pebble пойдёт
  проверять. Резолвер: `caServer` на `https://pebble:14000/dir`, `httpChallenge`,
  `csrSubject.country=RU` плюс ещё хотя бы одно поле Subject.
- Traefik обязан ДОВЕРЯТЬ корню Pebble. Корень новый на каждый старт, поэтому
  забирай его в рантайме с `https://pebble:15000/roots/0` и клади в доверенные
  (`caSystemCertPool`/`caCertificates`, смонтированный файл — выбери сам,
  но сделай это ДАННЫМИ, а не пересборкой образа).
- `acme.json` — на смонтированном томе, владелец `1002:1002`, права 600.

### 3. `scripts/stand.sh` — управление стендом

Подкоманды `up`, `wait`, `dump-cert`, `down`. `wait` ждёт появления сертификата
в `acme.json` с таймаутом и НЕНУЛЕВЫМ кодом возврата по таймауту (молчаливое
зависание хуже падения). `dump-cert` печатает сертификат в PEM на stdout.
**Ждать по маркеру/файлу, а не опросом процессов по имени.**

### 4. `scripts/release.sh` — написать, НО НЕ ВЫПОЛНЯТЬ пуш

Multi-arch сборка (`linux/amd64`, `linux/arm64`) и теги вида
`<traefik-версия>-nuc.<ревизия>`. **Пуш в GHCR запрещён в этой вехе** —
публикация наружу решается владельцем отдельно. Скрипт обязан поддерживать
`--dry-run` и по умолчанию НИЧЕГО не пушить; без явного флага пуша он должен
только печатать, что бы сделал. Токенов и кред в скрипт не зашивать.

### 4b. Перехват CSR на проводе — ГЛАВНОЕ в этой доработке

`C=RU` в выданном сертификате недостижим (см. факты). Контракт продукта —
«Traefik ОТПРАВЛЯЕТ CSR с заданным Subject», и проверять надо именно это, на
живом протоколе, а не только юнит-тестами вехи 1.

Поставь между Traefik и Pebble обратный прокси (`acmeproxy`), который
СОХРАНЯЕТ тела запросов. `caServer` у Traefik переводится на прокси. Схему
выбери сам: у nginx тела пишутся файлами при `client_body_in_file_only on`;
годится и другой лёгкий образ. Прокси ходит в Pebble по TLS, доверяя `minica`.
Если lego откажется от `http://` в `caServer` — терминируй TLS на прокси
сертификатом, которому Traefik доверяет; это допустимо, но сперва попробуй
простой вариант.

Добавь в `scripts/stand.sh` подкоманду `csr-dump`: найти последний захваченный
finalize-запрос, достать из JWS поле `payload`, декодировать base64url, взять из
него `csr`, декодировать base64url в DER и напечатать CSR в PEM на stdout.
Ненулевой код возврата, если захвата нет — молчаливое «пусто» недопустимо.

### 5. Документация

- `CHANGELOG.md` — запись за 2026-09-06 про образ и стенд.
- В `README.md` добавить короткий раздел про образ и **прямо написать, что он
  идёт БЕЗ веб-дашборда** (`api.dashboard` работать не будет) — это осознанный
  размен ради офлайн-сборки без Node.

## Не трогать

- `patches/0001-csr-subject.patch`, `scripts/mutation_gate_m1.py`,
  `docs/specs/`, `docs/reviews/`, `TASKS.md`, `CLAUDE.md`, `LICENSE`,
  `upstream.lock`, `scripts/upstream-go.sh`, `.gitignore`.
- `.github/` не создавать НИ В КАКОМ ВИДЕ — минуты GitHub Actions у владельца
  исчерпаны до 2026-10-06. Ни workflow, ни отключённого, ни `dependabot.yml`.
- Реальный пуш в любой registry. Логин в GHCR не выполнять.
- `.gomodcache/`, `.gocache/`, тарбол апстрима.

## Критерии приёмки

- **AC-001** — образ собирается:
  `bash -c 'docker build -t traefik-nuc-acme:3.7.13-nuc.1 -f Dockerfile . && docker image inspect traefik-nuc-acme:3.7.13-nuc.1 --format "{{.Id}}"'`
- **AC-002** — в образе именно НАША сборка: неверная страна даёт нашу ошибку в
  логах. ⚠️ Traefik при этом НЕ ЗАВЕРШАЕТСЯ (см. факт про пропуск резолвера
  ниже), поэтому критерий обязан быть НЕБЛОКИРУЮЩИМ — контейнер поднимается
  фоном, лог читается, контейнер сносится:
  `bash -c 'docker rm -f m2ac002 >/dev/null 2>&1; docker run -d --name m2ac002 traefik-nuc-acme:3.7.13-nuc.1 --certificatesresolvers.t.acme.csrsubject.country=RUS --certificatesresolvers.t.acme.storage=/tmp/a.json --certificatesresolvers.t.acme.email=a@example.org --entrypoints.web.address=:80 >/dev/null && sleep 6 && docker logs m2ac002 2>&1 | grep -qi "invalid CSR subject"; rc=$?; docker rm -f m2ac002 >/dev/null 2>&1; exit $rc'`

- **AC-003** — бинарь ужат стрипом (порог поднят: со `-s -w` он весит ~176 МБ,
  прежние 150 МБ были недостижимы и вынуждали паковать UPX'ом):
  `bash -c 'test "$(docker image inspect traefik-nuc-acme:3.7.13-nuc.1 --format "{{.Size}}")" -lt 220000000'`
  **UPX убрать.** Для долгоживущего прокси это плохой размен: бинарь
  распаковывается в память при каждом старте, страницы не разделяются между
  контейнерами, а слои в реестре и так жмутся gzip.

- **AC-004** — стенд поднимается и Pebble отвечает:
  `bash -c 'scripts/stand.sh up && scripts/stand.sh wait'`
- **AC-005** — 🚩 ГЛАВНОЕ: CSR, реально ушедший в CA, несёт `C=RU`:
  `bash -c 'scripts/stand.sh csr-dump | openssl req -noout -subject | grep -qE "C *= *RU"'`

- **AC-006** — в сертификате есть тестовый домен (HTTP-01 реально прошёл, а не подсунут самоподписанный):
  `bash -c 'scripts/stand.sh dump-cert | openssl x509 -noout -text | grep -A1 "Subject Alternative Name" | grep -q DNS'`
- **AC-007** — 🚩 ПРОДЛЕНИЕ снова отправляет CSR с Subject: после перезапуска с
  `certificatesDuration=8760` сертификат перевыпускается (serial МЕНЯЕТСЯ) и
  захвачен НОВЫЙ finalize, в CSR которого снова `C=RU`:
  `bash -c 'scripts/stand.sh renew-check'`
  (подкоманду доработай: сверить смену serial И проверить свежезахваченный CSR;
  таймаут с ненулевым кодом обязателен)

- **AC-008** — стенд гасится без остатков:
  `bash -c 'scripts/stand.sh down && test -z "$(docker ps -aq --filter name=traefik-nuc)"'`
- **AC-009** — релизный скрипт не пушит и не носит в себе кред:
  `bash -c 'scripts/release.sh --dry-run >/dev/null 2>&1 && ! grep -qiE "ghp_|github_pat_|--password|PAT=|TOKEN=" scripts/release.sh'`
  (dry-run обязан отработать с кодом 0 и не выполнять ни `docker login`, ни
  `docker push`; печатать, что он БЫ сделал, — можно и нужно)

- **AC-010** — дерево репозитория чистое:
  `bash -c 'test -z "$(git status --porcelain -- . ":(exclude)report.json" ":(exclude)report-blocked.md" ":(exclude)env-probe.txt")"'`
- **AC-011** — нет ни одного файла GitHub Actions:
  `bash -c 'test -z "$(git ls-files -- ".github")" && test ! -d .github'`

## Контракт отчёта

Положи в корень клона `report.json`:

```json
{"criteria": [{"id": "AC-001", "status": "pass|fail|blocked",
               "command": "<команда-доказательство>", "rc": 0, "note": "…"}]}
```

Ровно одиннадцать записей. У AC-005 и AC-007 в `note` приведи ДОСЛОВНУЮ строку
Subject из сертификата — это предмет вехи, и он должен быть виден в отчёте.

## Контракт на невыполнимое

Если требование несовместимо с реальностью — остановись и доложи в
`report-blocked.md`: что не сходится, какой командой это видно, какие варианты
видишь. Обходить несовместимость запрещено: не глушить код возврата, не
отключать проверки, не заменять живой стенд заглушкой, не пушить в registry,
не создавать `.github/`. Честная остановка стоит дешевле правдоподобного отчёта.
