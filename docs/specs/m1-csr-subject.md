# Веха M1 — настраиваемый Subject в CSR у ACME-резолвера Traefik

- **Репозиторий:** `stufently/traefik-nuc-acme` (GitHub, публичный).
- **Дата:** 2026-09-06.
- **Базовый коммит:** ветка `main`, «Bootstrap repository» (каркас репо, кода ещё нет).
- **Исполнитель:** Codex. Сетевых и Docker-критериев в вехе нет, всё делается
  локальным тулчейном Go — балансировка квоты в пользу Codex.
- **Перекрёстные мутации после приёмки гоняет Grok** (противоположный исполнитель).

## Где работать

- Клон: `/home/deploy/exec-clones/traefik-nuc-m1`. Живое дерево
  `/home/deploy/github/traefik-nuc-acme` НЕ трогать.
- Новая ветка от `main`: `m1-csr-subject`.
- Работа идёт в ДВУХ деревьях: наш репозиторий (патч, гейт мутаций, документация)
  и **staged-копия апстрима** `.upstream/traefik` — она под `.gitignore`, в наш
  git не попадает и служит рабочим столом для правки исходников Traefik.

### Что кладёт постановщик ДО запуска (уже лежит, качать ничего не нужно)

| Путь | Что это | Размер |
|---|---|---|
| `.upstream/traefik-v3.7.13.tar.gz` | тарбол релиза, sha256 `c1cff59261740def3a393ea2c4d7c7d0184eb8eb39c88402b26eb3b3e4735b96` | 13 МБ |
| `.upstream/traefik/` | распакованный апстрим, **свой git-репозиторий**, ветка `upstream`, единственный коммит «Pristine traefik v3.7.13» | 52 МБ |
| `.gomodcache/` | полный кэш Go-модулей Traefik (`go mod download all`) | 5.6 ГБ |
| `.gocache/` | кэш сборки Go | — |
| `scripts/upstream-go.sh` | обёртка: `go` в апстрим-дереве с `GOMODCACHE`/`GOCACHE` из клона, `GOPROXY=off` | — |

**Сети в песочнице нет и не нужно.** Тулчейн Go 1.26.0 стоит на хосте и точно
совпадает с `go 1.26.0` из `go.mod` Traefik, поэтому `GOTOOLCHAIN` подставлять
НЕ НАДО и НЕЛЬЗЯ. Проверено вживую до написания спеки:
`scripts/upstream-go.sh test -count=1 ./pkg/provider/acme/... ./pkg/config/...`
проходит на чистом апстриме (`ok` по всем пакетам) с `GOPROXY=off`.

⚠️ В `.upstream/traefik/` лежат ЧУЖИЕ `AGENTS.md` и `CLAUDE.md` — они апстримовы
и к этой вехе отношения не имеют. Инструкции для тебя — только этот файл.

## Задача и почему

Traefik умеет получать ACME-сертификаты, но не даёт задать Subject в CSR.
Российский гос-CA НУЦ требует поле `C=RU`, и без него заявка отвергается. Задача
вехи — добавить в ACME-резолвер **generic**-конфигурацию `csrSubject` и провести
её до реального CSR, не форкая lego.

### Что при этом ломается и обязано быть починено в этой же вехе

Продление. `renewCertificates` собирает `certificate.Resource` БЕЗ поля `CSR` и
зовёт `client.Certificate.Renew`. Проверено по исходнику lego v5.4.1
(`certificate/certificates.go:558`): `Renew` идёт через `ObtainForCSR`, только
если `len(certRes.CSR) > 0`, иначе молча падает в обычный `Obtain` и строит CSR
сам — **без нашего Subject**. То есть наивная правка одного лишь пути выпуска
даёт сертификат с `C=RU`, который через два месяца тихо продлевается без `C=RU`.

Чинить надо БЕЗ смены формата `acme.json`: пересобирать CSR на продлении из
текущей конфигурации и сохранённого приватного ключа и звать `ObtainForCSR`
напрямую. Побочный выигрыш: правка `csrSubject` в конфиге вступает в силу на
ближайшем продлении.

## Что проверено вживую, а что предположение

Проверено (командами, до написания спеки):

- Тег `v3.7.13` — самый свежий (`/repos/traefik/traefik/tags`), коммит
  `fc92cc118a0557a029c7019d5ee06665127b0f13`.
- `pkg/provider/acme/provider.go` импортирует `github.com/go-acme/lego/v5`
  (в `go.mod` есть и `lego/v4 v4.35.2` — это транзитивная зависимость чужих
  пакетов, к нашему коду отношения не имеет, трогать её не надо).
- `certificate.ObtainForCSRRequest` (lego v5.4.1) содержит `CSR`, `PrivateKey`,
  `NotBefore`, `NotAfter`, `Bundle`, `PreferredChain`, `EnableCommonName`,
  `Profile`, `ReplacesCertID`, `AlwaysDeactivateAuthorizations`. **Полей
  `Domains`, `KeyType` и `EmailAddresses` в нём НЕТ**: домены lego извлекает из
  самого CSR (`certcrypto.ExtractDomainsCSR`), ключ ты обязан сгенерировать сам,
  e-mail'ы кладутся в CSR.
- 🚨 `ObtainForCSR` заполняет `Resource.PrivateKey`, **только если
  `request.PrivateKey != nil`** (`certificates.go:313`). Traefik же отвергает
  результат проверкой `len(cert.PrivateKey) == 0`. Забыть ключ = рабочий на вид
  код, который не отдаёт ни одного сертификата.
- Два одинаковых места сборки `certificate.ObtainRequest`:
  `resolveDefaultCertificate` (:685) и `resolveCertificate` (:733).
- Тесты `pkg/provider/acme` и `pkg/config` не открывают сокетов
  (`grep` по `httptest`/`net.Listen` пуст) — это важно, потому что **в песочнице
  сокеты запрещены**, `net.Listen` вернёт `operation not permitted`.

Предположения (пометь в отчёте, если факт разойдётся):

- Добавление вложенной структуры в статическую конфигурацию не ломает
  рефлексивные тесты `pkg/config/...`. Базовый прогон зелёный, но поле ещё не
  добавлено. Если тесты потребуют правок — это часть вехи, чини.
- Генерация ссылочной документации нужна только динамической конфигурации
  (`script/code-gen.sh` пишет в `docs/content/reference/dynamic-configuration/`),
  ACME-резолвер — статическая, кодогенерация не нужна.

## Что сделать

### 1. Конфигурация (в апстрим-дереве)

`pkg/provider/acme/provider.go`, структура `Configuration`: добавить поле

```go
CSRSubject *CSRSubject `description:"Subject fields to put into the CSR." json:"csrSubject,omitempty" toml:"csrSubject,omitempty" yaml:"csrSubject,omitempty" export:"true"`
```

и тип `CSRSubject` с полями `Country`, `Organization`, `OrganizationalUnit`,
`Locality` (все `string`, все опциональные, теги в стиле соседних полей).

### 2. Новый файл `pkg/provider/acme/csr.go`

Чистые функции, без сети и без сокетов — на них держится вся проверяемость вехи:

- `func (s *CSRSubject) IsEmpty() bool` — nil или все поля пустые.
- `func (s *CSRSubject) Validate() error` — `Country`, если задан, обязан быть
  ровно двумя буквами (ISO 3166-1 alpha-2, как того требует X.520); прочие поля
  произвольны, но не длиннее 64 символов.
- `func buildCSR(subject *CSRSubject, domains, emails []string, key crypto.Signer, enableCommonName bool) (*x509.CertificateRequest, error)` —
  собирает `x509.CertificateRequest`: `Subject.CommonName = domains[0]` при
  `enableCommonName`, поля Subject из конфига, `DNSNames = domains` целиком,
  `EmailAddresses = emails`, подпись ключом `key`, возврат уже разобранного
  запроса (то есть `x509.CreateCertificateRequest` + `ParseCertificateRequest`,
  чтобы `Raw` был заполнен — lego использует именно `CSR.Raw`).
- `func (p *Provider) obtainForCSRRequest(domains []string) (certificate.ObtainForCSRRequest, crypto.Signer, error)` —
  генерирует ключ нужного `KeyType` через `certcrypto.GeneratePrivateKey`,
  строит CSR и возвращает **готовый запрос с непустым `PrivateKey`**.

### 3. Путь выпуска

В `resolveDefaultCertificate` и `resolveCertificate`: если
`p.CSRSubject.IsEmpty()` — оставить существующий вызов `Obtain` **дословно
как был**; иначе идти через `obtainForCSRRequest` + `client.Certificate.ObtainForCSR`.
Никакой другой разницы в поведении быть не должно.

### 4. Путь продления

В `renewCertificates`: если `CSRSubject` не пуст — разобрать сохранённый ключ
(`certcrypto.ParsePEMPrivateKey`), пересобрать CSR по доменам сертификата и
текущему конфигу и вызвать `ObtainForCSR`; иначе — прежний `Renew`. Вынеси выбор
в отдельную чистую функцию, чтобы он проверялся тестом без сети.

### 5. Тесты (в апстрим-дереве, `pkg/provider/acme/csr_test.go`)

Покрыть: наличие `C=RU` в собранном CSR; попадание всех доменов в `DNSNames`;
`CommonName` при `enableCommonName` и его отсутствие при выключенном; отказ
`Validate` на трёхбуквенной стране; пустой `CSRSubject` → выбирается стоковый
путь; непустой → путь CSR; непустой `PrivateKey` в `ObtainForCSRRequest`;
продление при непустом `CSRSubject` не уходит в `Renew`.

### 6. Патч и гейт мутаций (в НАШЕМ репозитории)

- `patches/0001-csr-subject.patch` — вывод
  `git -C .upstream/traefik diff` от коммита «Pristine traefik v3.7.13».
  Именно этот файл и есть продукт вехи.
- `scripts/mutation_gate_m1.py` — обвязка мутаций по правилам ниже. Мутирует
  файлы ВНУТРИ `.upstream/traefik` (они не под нашим git, поэтому дерево от
  этого не грязнится), сохраняет исходные байты и sha256, восстанавливает их в
  `finally` и сверяет sha256. Обязательный набор мутаций — не менее ШЕСТИ:
  выброшенное поле `Country` из Subject; продление, свалившееся обратно в
  `Renew`; `PrivateKey`, не переданный в `ObtainForCSRRequest`; снятая проверка
  двухбуквенности страны; пустой `CSRSubject`, всё равно уходящий по пути CSR;
  потерянные `DNSNames`.
  Для каждой мутации: прогнать целевой тест на ЧИСТОМ дереве и убедиться, что он
  ЗЕЛЁНЫЙ; проверить, что заменяемый фрагмент встречается ровно один раз ДО
  замены; наложить мутацию; прогнать ИМЕННО целевой тест; убедиться, что он упал
  на СВОЕЙ строке ассерта. Печатать по каждой «убит/выжил» и первую упавшую
  строку. Код возврата 0 — только если убиты все.
- `CHANGELOG.md` — запись за 2026-09-06 о фиче.

## Не трогать

- `README.md`, `LICENSE`, `TASKS.md`, `CLAUDE.md`, `upstream.lock`,
  `scripts/upstream-go.sh`, `.gitignore`, саму эту спеку
  `docs/specs/m1-csr-subject.md` — она приехала в клон УЖЕ закоммиченной в
  `main`, поэтому коммитить её отдельно не надо и дерево от неё не грязнится.
- `.upstream/traefik/` вне `pkg/provider/acme/` — никаких «заодно» правок
  апстрима: чем шире патч, тем дороже его переносить на следующий Traefik.
- `.gomodcache/`, `.gocache/`, `.upstream/traefik-v3.7.13.tar.gz`.
- **`.github/` не создавать ни в каком виде** — ни workflow, ни отключённого, ни
  `dependabot.yml`. Минуты GitHub Actions у владельца исчерпаны до 2026-10-06.
- `go.mod`/`go.sum` апстрима: новых зависимостей веха не вводит, всё нужное уже
  в стандартной библиотеке и в lego.

## Критерии приёмки

- **AC-001** — патч накладывается на ЧИСТЫЙ апстрим:
  `bash -c 'd=$(mktemp -d) && tar -xzf .upstream/traefik-v3.7.13.tar.gz -C "$d" && git -C "$d/traefik-3.7.13" init -q && git -C "$d/traefik-3.7.13" apply --check /home/deploy/exec-clones/traefik-nuc-m1/patches/0001-csr-subject.patch'`
- **AC-002** — патч детерминирован, закоммиченный файл совпадает с
  перегенерированным:
  `bash -c 'f=$(mktemp) && git -C .upstream/traefik diff > "$f" && diff -u patches/0001-csr-subject.patch "$f"'`
- **AC-003** — пропатченный апстрим собирается целиком:
  `bash -c 'scripts/upstream-go.sh build ./...'`
- **AC-004** — тесты затронутых пакетов зелёные (единственный полный прогон):
  `bash -c 'scripts/upstream-go.sh test -count=1 ./pkg/provider/acme/... ./pkg/config/...'`
- **AC-005** — `go vet` чист по затронутому пакету:
  `bash -c 'scripts/upstream-go.sh vet ./pkg/provider/acme/...'`
- **AC-006** — все мутации убиты своими тестами:
  `bash -c 'python3 scripts/mutation_gate_m1.py'`
- **AC-007** — дерево нашего репозитория чистое:
  `bash -c 'test -z "$(git status --porcelain -- . ":(exclude)report.json" ":(exclude)report-blocked.md")"'`
- **AC-008** — состав работы ровно такой, как обещано (патч, гейт, changelog):
  `bash -c 'f=$(mktemp) && git diff --name-only main...HEAD | sort > "$f" && printf "%s\n" CHANGELOG.md patches/0001-csr-subject.patch scripts/mutation_gate_m1.py | sort | diff -u - "$f"'`
- **AC-009** — в репозитории нет ни одного файла GitHub Actions:
  `bash -c 'test -z "$(git ls-files -- ".github")" && test ! -d .github'`
  (искать `find`'ом по всему клону НЕЛЬЗЯ: у самого апстрима Traefik в
  `.upstream/traefik/.github/` свои workflow, и такой критерий падает всегда.)

## Контракт отчёта

Положи в корень клона `report.json`:

```json
{"criteria": [{"id": "AC-001", "status": "pass|fail|blocked",
               "command": "<команда-доказательство>", "rc": 0, "note": "…"}]}
```

Ровно девять записей, по одной на критерий. `blocked` — штатный исход, когда
среда не даёт выполнить критерий: в `command` команда-улика, в `note` дословная
ошибка, `rc` — `null`.

## Контракт на невыполнимое

Если требование вехи несовместимо с реальностью кода — **остановись и доложи** в
`report-blocked.md`: что именно не сходится, какой командой это видно, какие
варианты видишь. Обходить несовместимость запрещено: не подставлять
`GOTOOLCHAIN`, не вводить `go.local.mod`, не глушить код возврата, не ходить в
сеть, не отключать тесты. Честная остановка стоит дешевле правдоподобного отчёта.

## Стыки с соседними вехами

Следующая веха собирает Docker-образ и поднимает интеграционный стенд с мок-ACME
сервером Pebble. Ей от этой вехи нужны ровно две вещи: патч, накладывающийся на
чистый апстрим одной командой, и `upstream.lock` как единственный источник
пинов. Поэтому патч обязан быть самодостаточным — никаких правок, которые
существуют только в staged-дереве и не попали в `.patch`.
