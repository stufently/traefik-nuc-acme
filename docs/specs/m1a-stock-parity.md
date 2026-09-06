# Веха M1a — довести CSR-путь до паритета со стоковым Traefik

Продолжение вехи M1 (коммит `280021e`, ветка `m1-csr-subject`). Код писал ты,
перекрёстную проверку гонял Grok: 14 мутаций, все убиты — **дыр в твоих тестах
нет**. Но ревью нашло два места, где новый CSR-путь ведёт себя ИНАЧЕ, чем
стоковый Traefik, хотя спека M1 требовала «никакой другой разницы в поведении
быть не должно». Обе находки я перепроверил по исходникам lego v5.4.1 — они
подтверждены дословно. Это доработка, а не переделка.

## Где работать

- Клон: `/home/deploy/exec-clones/traefik-nuc-m1` (твой, тот же).
- Эта спека лежит в клоне как `docs/specs/m1a-stock-parity.md` и приехала туда
  УЖЕ закоммиченной — отдельно коммитить её не надо, дерево от неё не грязнится.
- Ветка `m1-csr-subject`, поверх `280021e`. Новую ветку не создавай.
- Апстрим — `.upstream/traefik`, Go только обёрткой `scripts/upstream-go.sh`
  (офлайн, `GOPROXY=off`). Сети нет. `GOTOOLCHAIN` НЕ подставлять.

## Что чинить

### 1. IP-адрес обязан попадать в `IPAddresses`, а не в `DNSNames`

`csr.go`, `buildCSR`: сейчас весь `domains` уезжает в `DNSNames`. Стоковый
`certcrypto.CreateCSR` (`lego v5.4.1`, `certcrypto/crypto.go:145-151`) делит
список: `net.ParseIP(altname) != nil` → `IPAddresses`, иначе `DNSNames`.

Почему это боевой отказ: `Provider.sanitizeDomains` (`provider.go:1070`) чистит
только `*.*` и точку в конце — IP она НЕ отбрасывает, то есть адрес легально
доезжает до CSR. Дальше lego снимает идентификаторы `ExtractDomainsCSR`, заказ
уходит с identifier type `dns` вместо `ip`, и CA по RFC 8738 его отвергает.
Без `csrSubject` тот же вход работает.

Раздели список ровно как сток. `CommonName` при `enableCommonName` берётся из
`domains[0]` как и раньше, независимо от того, IP это или имя.

### 2. `CommonName` длиннее 64 байт обязан опускаться

`csr.go`: сейчас CN ставится всегда. Стоковый `Certifier.getForOrder`
(`certificate/certificates.go:352-354`) ставит его только так:

```go
if len(domains[0]) <= 64 && request.EnableCommonName {
```

Почему это боевой отказ: домен длиннее 64 байт — легальный вход, X.520 ограничивает
CN 64 символами, и CA отвергнет заявку, которая без `csrSubject` проходила.
Условие писать байтовой длиной (`len`), как в стоке, а не по рунам — иначе
разойдёшься со стоком на не-ASCII.

### 3. `Country` приводить к верхнему регистру

`Validate` принимает `"ru"`, и в CSR уезжает `C=ru`. ISO 3166-1 alpha-2 — это
заглавные буквы. Нормализуй при укладке в CSR (`strings.ToUpper`), приём обоих
регистров в конфиге оставь как есть — ломать существующее поведение конфига не
надо. Того же самого для `Organization`/`OrganizationalUnit`/`Locality` НЕ делай:
там регистр значащий.

## Тесты — обязательная часть, не довесок

На каждое из трёх изменений — тест в `pkg/provider/acme/csr_test.go`:

- вход `["203.0.113.10", "example.org"]` → в CSR ровно один `IPAddresses` с этим
  адресом и ровно один `DNSNames`; проверь ОБА поля, а не только одно;
- домен 65 байт + `enableCommonName=true` → `CommonName` пустой, домен при этом
  жив в `DNSNames`; и парный случай ровно 64 байта → CN заполнен (граница
  проверяется С ОБЕИХ сторон, иначе нестрогое неравенство не убивается мутацией);
- `Country: "ru"` → в CSR `C=RU`.

**У теста на отказ проверяй ПРИЧИНУ отказа, а не факт.** Тест, который лишь
убеждается, что CN пустой, останется зелёным и при полностью выломанном
построении Subject — проверяй заодно, что остальные поля Subject на месте.

## Мутационный гейт

Расширь `scripts/mutation_gate_m1.py` — новые ветки обязаны быть покрыты
мутациями по тем же правилам, что и прежние шесть: фрагмент встречается ровно
один раз до замены; целевой тест зелёный на чистом дереве; после мутации падает
ИМЕННО он и на своей строке ассерта; байты и sha256 восстанавливаются в
`finally`. Минимум ТРИ новые мутации: IP уехал в `DNSNames`; снят лимит 64 на CN;
снята нормализация регистра. Прежние шесть не ломай.

## Патч и changelog

- `patches/0001-csr-subject.patch` перегенерировать (`git -C .upstream/traefik diff`)
  — файл обязан совпадать с diff'ом байт в байт.
- `CHANGELOG.md` — дописать в запись за 2026-09-06, что CSR-путь приведён к
  паритету со стоком по IP-SAN, лимиту CN и регистру страны.

## Не трогать

- `README.md`, `LICENSE`, `TASKS.md`, `CLAUDE.md`, `upstream.lock`,
  `scripts/upstream-go.sh`, `.gitignore`, `docs/specs/` (включая
  `docs/specs/m1a-stock-parity.md` — саму эту спеку).
- `.upstream/traefik/` вне `pkg/provider/acme/`.
- `.gomodcache/`, `.gocache/`, тарбол апстрима.
- **`.github/` не создавать ни в каком виде.**
- `go.mod`/`go.sum` апстрима: новых зависимостей нет, `net` и `strings` — стандартная
  библиотека.
- Клон `/home/deploy/exec-clones/traefik-nuc-m1-gk` и живое дерево
  `/home/deploy/github/traefik-nuc-acme` — чужие, не твои.

## Критерии приёмки

- **AC-001** — патч накладывается на ЧИСТЫЙ апстрим:
  `bash -c 'd=$(mktemp -d) && tar -xzf .upstream/traefik-v3.7.13.tar.gz -C "$d" && git -C "$d/traefik-3.7.13" init -q && git -C "$d/traefik-3.7.13" apply --check /home/deploy/exec-clones/traefik-nuc-m1/patches/0001-csr-subject.patch'`
- **AC-002** — патч детерминирован:
  `bash -c 'f=$(mktemp) && git -C .upstream/traefik diff > "$f" && diff -u patches/0001-csr-subject.patch "$f"'`
- **AC-003** — пропатченный апстрим собирается:
  `bash -c 'scripts/upstream-go.sh build ./...'`
- **AC-004** — тесты затронутых пакетов зелёные:
  `bash -c 'scripts/upstream-go.sh test -count=1 ./pkg/provider/acme/... ./pkg/config/...'`
- **AC-005** — `go vet` чист:
  `bash -c 'scripts/upstream-go.sh vet ./pkg/provider/acme/...'`
- **AC-006** — все мутации убиты, включая новые:
  `bash -c 'python3 scripts/mutation_gate_m1.py'`
- **AC-007** — IP реально уходит в `IPAddresses` (проверка предмета вехи, не своими тестами):
  `bash -c 'scripts/upstream-go.sh test -count=1 -run TestCSR ./pkg/provider/acme/'`
- **AC-008** — дерево нашего репозитория чистое:
  `bash -c 'test -z "$(git status --porcelain -- . ":(exclude)report.json" ":(exclude)report-blocked.md")"'`
- **AC-009** — в репозитории нет ни одного файла GitHub Actions:
  `bash -c 'test -z "$(git ls-files -- ".github")" && test ! -d .github'`

## Контракт отчёта

Положи в корень клона `report.json`:

```json
{"criteria": [{"id": "AC-001", "status": "pass|fail|blocked",
               "command": "<команда-доказательство>", "rc": 0, "note": "…"}]}
```

Ровно девять записей. В `note` у AC-006 назови, сколько мутаций убито из скольких.

## Контракт на невыполнимое

Если требование несовместимо с реальностью кода — остановись и доложи в
`report-blocked.md`: что не сходится, какой командой это видно, какие варианты
видишь. Обходить несовместимость запрещено: не глушить код возврата, не
отключать тесты, не ходить в сеть, не подставлять `GOTOOLCHAIN`. Честная
остановка дешевле правдоподобного отчёта.
