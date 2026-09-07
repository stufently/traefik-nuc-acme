# Веха M6 — покрыть выбор пути выпуска, снять расхождение с lego на продлении

Репозиторий: `github.com/stufently/traefik-nuc-acme` (живое дерево
`/home/deploy/github/traefik-nuc-acme`). Дата: 2026-09-07.
Базовая ветка — `main` в состоянии, в котором ты её видишь: последним коммитом
лежит ЭТА спека, а под ней **`0257e35`** («Price the GitHub Pages item»). Ветку
вехи режь от текущего `main`, ничего в него не доливая.

Исполнитель — **Grok**. Мутации по этому коду потом гоняет ПРОТИВОПОЛОЖНЫЙ
исполнитель (Codex): автор теста не видит своей слепой зоны.

Эта спека лежит в клоне как `docs/specs/m6-provider-path-coverage.md` и приехала
УЖЕ закоммиченной — отдельно её коммитить не надо.

## Зачем веха

Три пункта из кросс-ревью вехи M1 (`TASKS.md`, секция «Deferred from the
milestone 1 review»). Четвёртый пункт секции (порядок RDN в `pkix.Name`) в эту
веху НЕ входит: он помечен как GUESS и проверяется только против живого НУЦ,
доступа к которому нет. Его не трогать.

### 1. Выбор пути выпуска не покрыт ничем

`resolveDefaultCertificate` (`provider.go:692`) и `resolveCertificate`
(`provider.go:749`) содержат ОДИН И ТОТ ЖЕ вложенный блок `if
p.CSRSubject.IsEmpty() { … Obtain … } else { … ObtainForCSR … }`. Ни один тест
эти функции не зовёт (`grep -n "resolveCertificate\|resolveDefaultCertificate"
.upstream/traefik/pkg/provider/acme/*_test.go` → пусто): чтобы их вызвать, нужен
живой ACME-клиент. Значит сломанное условие — например инверсия — прошло бы
незамеченным.

🚨 Это дыра в **ТЕСТАХ**, а не дефект кода. Действующий код выбирает путь
ПРАВИЛЬНО; чинить его поведение не надо, надо сделать выбор проверяемым.

Лечение то же, что уже применено на продлении: выбор пути выносится в чистую
функцию рядом с существующей парой `certificateRenewer` / `renewCertificate`
(`csr.go`), и на неё пишутся тесты через подделку клиента.

### 2. Продление берёт имена не оттуда, откуда сток

`renewalForCSRRequest` (`csr.go:144`) строит CSR по `res.Domains` — это поле
ХРАНИЛИЩА Traefik. Сток-lego в `Renew` домены из `certRes.Domains` не берёт
вообще: он разбирает тело сертификата и зовёт `certcrypto.ExtractDomains(x509Cert)`
(`certificate/certificates.go:613` в lego v5.4.1; `certRes.Domains` там уходит
только в текст лога и в текст ошибки).

Расходятся эти два источника ровно в одном случае: `acme.json` потерял `Domain`,
а тело сертификата цело. Тогда сток продлит, а наш путь встанет с
`cannot build CSR without domains`. Веха убирает расхождение: домены на продлении
берутся из тела сертификата, как у стока.

### 3. `GetKeyType` зовётся с `context.Background()`

`csr.go:119`: `certcrypto.GeneratePrivateKey(GetKeyType(context.Background(), p.KeyType))`.
`GetKeyType` (`account.go:72`) использует `ctx` ТОЛЬКО для `log.Ctx(ctx)` —
на тип ключа это не влияет никак, влияет только на контекст логгера.

⚠️ Поэтому мутация «подставить обратно `context.Background()`» —
**эквивалентный мутант**: наблюдаемое поведение не меняется, поведенческим тестом
его убить нельзя, и требовать этого запрещено. Пункт закрывается СТРУКТУРНО
(AC-008): контекст запроса протянут до `GetKeyType`, `context.Background()` в
`csr.go` не осталось.

## Что проверено вживую, а что предположение

Всё ниже прочитано в файлах КЛОНА (`.upstream/traefik`), а не по памяти.

| Утверждение | Чем подтверждено |
|---|---|
| Ветка `p.CSRSubject.IsEmpty()` лежит в трёх местах: `csr.go:145`, `provider.go:692`, `provider.go:749` | `grep -rn "CSRSubject.IsEmpty()" .upstream/traefik/pkg .upstream/traefik/cmd` |
| `resolveCertificate` и `resolveDefaultCertificate` не упомянуты ни в одном тесте пакета | `grep -n "resolveCertificate\|resolveDefaultCertificate" .upstream/traefik/pkg/provider/acme/*_test.go` → пусто |
| Блоки в обеих функциях текстуально одинаковы (различаются только типы возврата вокруг) | `sed -n "670,790p" .upstream/traefik/pkg/provider/acme/provider.go` |
| `client.Certificate` — это `*certificate.Certifier`, у него есть `Obtain(ctx, ObtainRequest) (*Resource, error)` (`certificates.go:188`) и `ObtainForCSR(ctx, ObtainForCSRRequest) (*Resource, error)` (`certificates.go:264`) | чтение lego v5.4.1 в `.gomodcache` |
| Сток-`Renew` берёт домены `certcrypto.ExtractDomains(x509Cert)` после `certcrypto.ParsePEMBundle(certRes.Certificate)` | `certificates.go:559-615` |
| `certcrypto.ExtractDomains` существует и отдаёт `CN + DNS SAN + IP SAN` | `certcrypto/crypto.go:248` |
| `GetKeyType` использует `ctx` только под `log.Ctx(ctx)` | `account.go:72-93` |
| В `csr.go` уже есть образец для подражания: интерфейс `certificateRenewer` и метод `renewCertificate` | `csr.go`, конец файла |
| Подделка клиента продления в тестах называется `csrRenewalClient` и пишется рядом с тестами | `csr_test.go:191` |
| Мутационный гейт сверяет базис: `git -C .upstream/traefik diff HEAD` обязан посимвольно равняться `patches/0001-csr-subject.patch` | `scripts/mutation_gate_m1.py`, функция `check_baseline` |
| На хосте и в клоне Go 1.26.0, совпадает с `upstream.lock` | `go version` |

**Предположение (помечено честно):** после правки продления существующие тесты
`TestCSRRenewalUsesCSR` и `TestCSRRenewalError` покраснеют, потому что их
фикстура `certificate.Resource` не несёт тела сертификата. Это ОЖИДАЕМО и входит
в работу вехи (см. «Что сделать», п. 4). `TestCSRRenewalEmptyUsesStock` и
`TestCSRInvalidInput` затронуты не будут: первый уходит из функции до разбора
тела, второй падает раньше на разборе ключа.

## Где работать

- Клон: `/home/deploy/exec-clones/traefik-nuc-m6` (твой). Другие клоны в
  `~/exec-clones/` и живое дерево `/home/deploy/github/traefik-nuc-acme`
  НЕ ТРОГАТЬ ни одной командой, включая чтение через `cd`.
- Новая ветка от `main`: `m6-provider-path-coverage`.
- Апстрим — `.upstream/traefik` (патч M1+M3 уже наложен как незакоммиченная
  правка рабочего дерева). Go зовётся ТОЛЬКО обёрткой `scripts/upstream-go.sh`
  (офлайн, `GOPROXY=off`). `GOTOOLCHAIN` не подставлять.
- У тебя ЕСТЬ Docker, сеть и слушающие сокеты — это замерено, не режь критерии
  «на всякий случай».
- **Push запрещён.** Право пуша у клона отобрано намеренно
  (`remote set-url --push origin no-push`); работу заберёт координатор через
  `git fetch` из клона. Не пытайся пушить, не меняй remote, не мержи.

### Что кладёт постановщик (уже лежит в клоне, коммитить не надо)

| Путь | Что это | Как убедиться |
|---|---|---|
| `.upstream/traefik/` | дерево Traefik v3.7.13 с наложенным патчем как правка рабочего дерева | `git -C .upstream/traefik diff HEAD \| sha256sum` → `9ac0205f847957d95316c7fd7fdf4d1389c64e3cefe9d066cc96cb6276e1e035` |
| `.upstream/traefik-v3.7.13.tar.gz` | чистый апстрим для проверки наложения патча | нужен AC-001 |
| `.gomodcache/`, `.gocache/` | кэш модулей и сборки для офлайн-прогона | `scripts/upstream-go.sh build ./...` проходит без сети |

Все три каталога в `.gitignore` — в коммит они не попадают и попасть не должны.

## Что сделать

### 1. Вынести выбор пути в чистую функцию (`.upstream/traefik/pkg/provider/acme/csr.go`)

По образцу уже имеющихся `certificateRenewer` / `renewCertificate` в этом же
файле:

```go
type certificateObtainer interface {
	Obtain(context.Context, certificate.ObtainRequest) (*certificate.Resource, error)
	ObtainForCSR(context.Context, certificate.ObtainForCSRRequest) (*certificate.Resource, error)
}

func (p *Provider) obtainCertificate(ctx context.Context, client certificateObtainer, domains []string) (*certificate.Resource, error) {
	// стоковая ветка: ровно тот же ObtainRequest, что стоял в provider.go
	// CSR-ветка: obtainForCSRRequest + ObtainForCSR
}
```

Требования к содержимому, все обязательные:

- поля `ObtainRequest` перенести ОДИН В ОДИН из `provider.go`: `Domains`,
  `Bundle: true`, `EmailAddresses`, `Profile`, `PreferredChain`,
  `EnableCommonName: !p.DisableCommonName`, `KeyType: GetKeyType(ctx, p.KeyType)`.
  Ни одно поле не выбрасывать и не переименовывать;
- при ошибке `obtainForCSRRequest` до сети не ходить — вернуть ошибку;
- сигнатура метода — ровно
  `func (p *Provider) obtainCertificate(ctx context.Context, client certificateObtainer, domains []string) (*certificate.Resource, error)`.

### 2. Заменить оба блока в `provider.go` вызовом

В `resolveDefaultCertificate` и в `resolveCertificate` весь блок
`var cert *certificate.Resource; if p.CSRSubject.IsEmpty() { … } else { … }`
заменяется РОВНО на строку

```go
	cert, err := p.obtainCertificate(ctx, client.Certificate, domains)
```

Всё, что идёт ПОСЛЕ (обработка `err`, проверки `cert == nil`, пустых полей,
логирование, формирование `types.Domain`) — не трогать, тексты ошибок сохранить
дословно. Обрати внимание, что в `resolveCertificate` тексты ошибок оперируют
`uncheckedDomains`, а не `domains`: это существующее поведение, менять его не
надо. После правки в `provider.go` не должно остаться ни `certificate.ObtainRequest{`,
ни `CSRSubject.IsEmpty()`.

### 3. Протянуть контекст запроса (`csr.go`)

`obtainForCSRRequest` получает первым аргументом `ctx context.Context` и
передаёт его в `GetKeyType`. Сигнатура — ровно
`func (p *Provider) obtainForCSRRequest(ctx context.Context, domains []string) (certificate.ObtainForCSRRequest, crypto.Signer, error)`.
`context.Background()` из `csr.go` исчезает полностью. Все вызовы (боевой код и
тесты) обновить. Больше в этом пункте ничего: тип ключа от контекста не зависит.

### 4. Продление: домены из тела сертификата (`csr.go`)

`renewalForCSRRequest` перестаёт читать `res.Domains`. Порядок внутри:

1. `p.CSRSubject.IsEmpty()` → `nil, nil` (как сейчас);
2. разбор приватного ключа `certcrypto.ParsePEMPrivateKey(res.PrivateKey)` —
   ОСТАЁТСЯ ПЕРВЫМ после п.1, чтобы существующий кейс «испорченный ключ» в
   `TestCSRInvalidInput` падал по прежней причине;
3. `certcrypto.ParsePEMBundle(res.Certificate)`; ошибку обернуть с внятным
   текстом (`parsing saved certificate: %w`);
4. домены — `certcrypto.ExtractDomains(certificates[0])`;
5. дальше как сейчас: `p.csrRequest(domains, key)`.

Проверка «бандл начинается с CA-сертификата», которая есть у стока, в эту веху
НЕ входит: Traefik кладёт в хранилище лист первым, а отдельного сигнала об этой
проблеме у нас нет. Не добавляй её.

Пустой список доменов по-прежнему обязан давать существующую ошибку
`cannot build CSR without domains` из `buildCSR` — своей ветки для этого не
заводить.

**Правка существующих тестов — с границей.** `TestCSRRenewalUsesCSR` и
`TestCSRRenewalError` покраснеют: их `certificate.Resource` не несёт тела.
Разрешено РОВНО ОДНО: добавить в фикстуру поле `Certificate` с PEM
самоподписанного сертификата, у которого SAN'ы совпадают с теми именами, которые
тест уже ожидает (`example.org`, `www.example.org` — и `example.org` во втором).
ЗАПРЕЩЕНО: удалять ассерты, ослаблять их (переход с `reflect.DeepEqual` на
проверку подмножества, выброс полей, `_ = `), переименовывать тесты, менять
дословный текст `t.Fatal*`, снимать `CheckSignature`. Если не получается
удовлетворить ассерт, не ослабляя его, — ОСТАНОВИСЬ и доложи, это дефект спеки.

### 5. Новые тесты (`.upstream/traefik/pkg/provider/acme/csr_test.go`)

Подделка клиента выпуска пишется рядом, по образцу `csrRenewalClient`: она
ЗАПИСЫВАЕТ, каким методом её позвали и с каким запросом, и НИЧЕГО не изобретает
сверх этого — фейк, который «умнее» оригинала, зеленит всё поверх себя.

Минимальный набор:

1. **пустой субъект (`nil` и `&CSRSubject{}`) → зовётся `Obtain`**, `ObtainForCSR`
   не зовётся, и записанный `ObtainRequest` несёт домены, `Bundle`,
   `EmailAddresses`, `Profile`, `PreferredChain`, `EnableCommonName` и `KeyType`,
   выведенный из `p.KeyType`;
2. **непустой субъект → зовётся `ObtainForCSR`**, `Obtain` не зовётся, а CSR в
   записанном запросе несёт `C=RU` и ровно те DNS-имена, что переданы;
3. **невалидный субъект (`Country: "RUS"`) → ошибка, и КЛИЕНТ НЕ ПОЗВАН ни одним
   методом** (до сети дело не доходит);
4. **продление, у которого `res.Domains` ПУСТ, а тело сертификата цело** → запрос
   строится, и DNS-имена CSR равны SAN'ам сертификата. Это и есть регрессия,
   ради которой веха;
5. **продление, у которого `res.Domains` РАСХОДИТСЯ с телом сертификата** → CSR
   следует за сертификатом, а не за хранилищем (паритет со стоком).

Ассерты — на КОНКРЕТНЫЕ значения (`reflect.DeepEqual` по списку имён), а не
«длина больше нуля».

### 6. Мутационный гейт (`scripts/mutation_gate_m1.py`)

Дописать в `MUTATIONS` четыре записи. **Имена — дословно эти**, критерий AC-006
ищет их по тексту:

| Имя | Что подменяет | Что обязано покраснеть |
|---|---|---|
| `Subject ignored on the obtain path` | условие в `obtainCertificate` так, чтобы стоковый `Obtain` брался ВСЕГДА | тест п.5.2 |
| `CSR path taken for an empty subject` | то же условие так, чтобы CSR-путь брался ВСЕГДА | тест п.5.1 |
| `Renewal domains taken from the store` | источник доменов в `renewalForCSRRequest` обратно на `res.Domains` | тест п.5.4 |
| `Obtain request loses the domains` | `Domains` в собранном `ObtainRequest` на `nil` | тест п.5.1 |

Правила прежние и их проверяет сама обвязка: заменяемый фрагмент встречается в
файле РОВНО ОДИН РАЗ (подбирай якорь подлиннее, если короткий не уникален),
целевой тест зелёный на чистом дереве ДО мутации, падает ИМЕННО он и ИМЕННО на
своей строке ассерта, байты и sha256 всех файлов восстанавливаются в `finally`.
Прежние 18 мутаций не ломать и не переименовывать.

Мутацию на `context.Background()` НЕ добавляй: она эквивалентная (см. выше),
убить её поведенческим тестом нельзя.

### 7. Патч и журнал

- `patches/0001-csr-subject.patch` перегенерировать:
  `git -C .upstream/traefik diff HEAD > patches/0001-csr-subject.patch`.
- `CHANGELOG.md` — запись за 2026-09-07 о том, что выбор пути стал проверяемым и
  что продление сравнялось со стоком по источнику имён.

## Не трогать

- **`.github/` не создавать НИ В КАКОМ ВИДЕ** — ни workflow, ни отключённый, ни
  `on: workflow_dispatch`, ни пустой каталог. Минуты GitHub Actions исчерпаны,
  запрет владельца действует до 2026-10-06.
- `upstream.lock` и любые версии/пины — веха не двигает ни Traefik, ни lego, ни Go.
- `scripts/release.sh` и всё, что связано с публикацией образа в GHCR: вопрос
  открыт за владельцем, дефолт — образ никуда не пушится.
- `scripts/upstream-go.sh`, `scripts/stand.sh`, `scripts/nuc-ca-bundle.sh`,
  `scripts/nuc_preset_checks.sh`, `scripts/readme_parity.py`, `docker/`,
  `Dockerfile`, `presets/`.
- `README.md`, `README.ru.md` (они сверяются `readme_parity.py`, а веха
  пользовательский конфиг не меняет), `COMPATIBILITY.md`, `TASKS.md`,
  `CLAUDE.md`, `LICENSE`, `.gitignore`, `docs/reviews/`.
- `docs/specs/` — исключение ровно одно: файл ЭТОЙ спеки уже закоммичен и
  остаётся как есть. Саму спеку не править: нашёл в ней дефект — опиши в отчёте.
- Четвёртый пункт отложенной секции (порядок RDN в `pkix.Name`) — вне вехи.
- `.upstream/traefik/` вне `pkg/provider/acme/csr.go`, `csr_test.go` и
  `provider.go`. В `provider.go` разрешены ровно два места — блоки выпуска в
  `resolveDefaultCertificate` и `resolveCertificate`; ни импорты (кроме тех, что
  стали не нужны), ни соседние функции, ни `Configuration` не менять.
- `go.mod` / `go.sum` апстрима: новых зависимостей веха не вводит.
- Стоковое поведение Traefik при ошибках резолверов.
- Реальный пуш куда бы то ни было, мерж, смена remote.

## Критерии приёмки

Каждый критерий проверяет ПРИЧИНУ, а не только код возврата.

- **AC-001** — патч накладывается на ЧИСТЫЙ апстрим:
  `bash -c 'd=$(mktemp -d) && tar -xzf .upstream/traefik-v3.7.13.tar.gz -C "$d" && git -C "$d/traefik-3.7.13" init -q && git -C "$d/traefik-3.7.13" apply --check "$PWD/patches/0001-csr-subject.patch"'`
- **AC-002** — патч детерминирован и равен состоянию дерева:
  `bash -c 'f=$(mktemp) && git -C .upstream/traefik diff HEAD > "$f" && diff -u patches/0001-csr-subject.patch "$f"'`
- **AC-003** — апстрим собирается целиком:
  `bash -c 'scripts/upstream-go.sh build ./...'`
- **AC-004** — тесты затронутых пакетов зелёные (единственный полный прогон):
  `bash -c 'scripts/upstream-go.sh test -count=1 ./pkg/provider/acme/... ./cmd/...'`
- **AC-005** — `go vet` чист:
  `bash -c 'scripts/upstream-go.sh vet ./pkg/provider/acme/... ./cmd/...'`
- **AC-006** — 🚩 все мутации убиты, и четыре НОВЫЕ присутствуют поимённо:
  `bash -c 'out=$(python3 scripts/mutation_gate_m1.py); rc=$?; printf "%s\n" "$out"; if [ "$rc" -ne 0 ]; then echo "гейт мутаций не зелёный" >&2; exit 2; fi; for m in "Subject ignored on the obtain path" "CSR path taken for an empty subject" "Renewal domains taken from the store" "Obtain request loses the domains"; do printf "%s\n" "$out" | grep -qF "$m: убит" || { printf "мутация отсутствует или не убита: %s\n" "$m" >&2; exit 3; }; done'`
- **AC-007** — 🚩 ветка ушла из `provider.go`, и обе функции зовут вынесенную:
  `bash -c 'p=.upstream/traefik/pkg/provider/acme/provider.go; c=.upstream/traefik/pkg/provider/acme/csr.go; [ "$(grep -cF "p.obtainCertificate(ctx, client.Certificate, domains)" "$p")" = "2" ] && ! grep -qF "certificate.ObtainRequest{" "$p" && ! grep -qF "CSRSubject.IsEmpty()" "$p" && grep -qF "func (p *Provider) obtainCertificate(ctx context.Context, client certificateObtainer, domains []string) (*certificate.Resource, error)" "$c"'`
- **AC-008** — контекст запроса протянут, `context.Background()` в `csr.go` нет:
  `bash -c 'c=.upstream/traefik/pkg/provider/acme/csr.go; ! grep -qF "context.Background()" "$c" && grep -qF "GetKeyType(ctx, p.KeyType)" "$c" && grep -qF "func (p *Provider) obtainForCSRRequest(ctx context.Context, domains []string) (certificate.ObtainForCSRRequest, crypto.Signer, error)" "$c"'`
- **AC-009** — 🚩 сквозной сценарий не сломан: стенд выпускает сертификат с
  Subject `C=RU` и продлевает его. Долгий критерий (минуты), Docker обязателен:
  `bash -c 'scripts/stand.sh down >/dev/null 2>&1; scripts/stand.sh up && scripts/stand.sh wait && scripts/stand.sh csr-dump | openssl req -noout -subject | grep -qE "C *= *RU" && scripts/stand.sh renew-check; rc=$?; scripts/stand.sh down >/dev/null 2>&1; exit $rc'`
- **AC-010** — дерево чистое и никаких GitHub Actions:
  `bash -c 'test -z "$(git status --porcelain -- . ":(exclude)report.json" ":(exclude)report-blocked.md")" && test -z "$(git ls-files -- ".github")" && test ! -d .github'`

## Авторевью перед отчётом (обязательно)

Закончив работу и получив зелёные критерии, ДО написания report.json:

1. Закоммить всё в клоне (`git add` по именам, никогда `-A`). Ревьюеры ходят в
   клон СВОИМ шеллом и способны прибрать незакоммиченное дерево — тогда гейт
   окажется зелёным не про твой код.
2. Из КОРНЯ КЛОНА запусти оба ревью, ПАРАЛЛЕЛЬНО (два фоновых вызова):
   bash ~/.claude/skills/ask-codex/scripts/run.sh "result" "<что сделано, какие файлы, какие критерии>"
   bash ~/.claude/skills/ask-agy/scripts/run.sh "result" "<тот же текст>"
   Оба смотрят репозиторий по текущему каталогу — из другого каталога отревьюят
   чужой код. Codex обязателен: сбой — один повтор, второй сбой — пиши в отчёт
   `review_codex: "failed: <ошибка>"` и продолжай. agy — soft-fail, при сбое
   просто отметь это в отчёте.
3. Замечания перепроверь ПО КОДУ, а не принимай на веру: оба ревьюера дают
   ложные находки. Настоящие — почини в этом же заходе, тесты прогони заново,
   почини — снова закоммить.
4. Круг исправлений ровно ОДИН. Замечания, пришедшие после него, НЕ чини —
   выпиши их в отчёт полем `review_backlog`. Бесконечные круги ревью уже стоили
   нам 19 итераций и ни одного коммита в прод.
5. В report.json добавь три поля верхнего уровня:
   "review_codex":   "<вердикт и находки одной-двумя строками>",
   "review_agy":     "<то же; 'принято, находок нет' пиши дословно>",
   "review_backlog": ["<замечание, оставленное без правки>", "…"]
   Пустой список — законный ответ. Врать в этих полях бессмысленно: приёмщик
   гоняет те же два ревью сам и сверяет.

## Контракт отчёта

`report.json` в корне клона, ровно десять записей — по одной на критерий:

```json
{"criteria": [{"id": "AC-001", "status": "pass|fail|blocked",
               "command": "<команда-доказательство>", "rc": 0, "note": "…"}]}
```

Плюс три поля авторевью из раздела выше.

У AC-006 в `note` приведи итоговую строку гейта (`Убито N/N …`) и по каждой из
четырёх новых мутаций — упавшую строку ассерта. У AC-009 в `note` — дословный
вывод `renew-check` (`renewed <serial> -> <serial>` и строка subject).

`blocked` — штатный исход, когда среда не даёт выполнить критерий: в `command`
команда-улика, в `note` дословная ошибка, `"rc": null`. Выдумывать ноль нельзя.

## Контракт на невыполнимое

Несовместимость — остановись и доложи в `report-blocked.md`: что не сходится,
какой командой это видно, какие есть варианты. Обходить запрещено: не глушить
код возврата (`|| true`, `set +e`), не отключать и не переименовывать тесты, не
ослаблять существующие ассерты, не менять стоковое поведение Traefik ради
зелёного критерия, не заводить новых патчей в `patches/`, не создавать `.github/`,
не править эту спеку, не пушить. Если дефект в САМОЙ спеке — опиши его, правку
внесёт координатор. Честная остановка дешевле правдоподобного отчёта.

## Стыки с соседними вехами

Веха закрывает три из четырёх пунктов отложенной секции кросс-ревью M1. Четвёртый
(порядок RDN) остаётся открытым и ждёт доступа к живому НУЦ. Вынесенная
`obtainCertificate` становится единственной точкой, где выбирается путь выпуска:
следующая веха, добавляющая поле в CSR, правит её, а не `provider.go`.
