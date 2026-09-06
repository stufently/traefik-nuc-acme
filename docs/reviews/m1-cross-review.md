# Перекрёстное ревью M1 (`280021e`)

Код писал Codex. Ниже — дефекты и расхождения со стоковым путём lego/Traefik,
которые тесты вехи не закрывают. Выдуманных находок нет: пустые разделы
означают, что подтверждаемого отказа не видно.

Мутационный прогон: `scripts/mutation_gate_m1_cross.py` — убито 14/14,
выживших нет. Авторские шесть мутаций не повторялись.

## Дефекты

### 1. IP из списка доменов попадает в `DNSNames`, а не в `IPAddresses`

- Файл: `.upstream/traefik/pkg/provider/acme/csr.go:69-71`
- Стоковый путь lego `certcrypto.CreateCSR` (`lego v5.4.1`, `certcrypto/crypto.go:145-157`)
  разбирает SAN: `net.ParseIP(altname) != nil` → `IPAddresses`, иначе `DNSNames`.
- Новый `buildCSR` кладёт **весь** `domains` в `DNSNames`.

Сценарий отказа:

1. Резолвер с `csrSubject.country: "RU"` и доменом `"203.0.113.10"`.
2. CSR уходит в `ObtainForCSR`. lego снимает идентификаторы через
   `ExtractDomainsCSR` — это DNS-имена, не IP.
3. ACME-заказ получает identifier type `dns` со значением `203.0.113.10`.
4. CA, который ждёт type `ip` (Let's Encrypt и любой RFC 8738), заявку
  отвергает. Стоковый `Obtain` без `csrSubject` для того же входа собрал бы
  `IPAddresses` и type `ip`.

Traefik `sanitizeDomains` IP не выкидывает, так что вход легален. Для НУЦ с
обычными DNS-именами это не стреляет; для IP-сертификата с включённым
`csrSubject` — да.

## Расхождения со стоковым путём

Спека требовала: при непустом Subject «никакой другой разницы в поведении быть
не должно». Ниже — места, где новый путь всё же отличается. Это не всегда
боевой отказ, но автор их мог не заметить.

### CommonName длиннее 64 байт

- Новый путь: `csr.go:73-75` ставит `Subject.CommonName = domains[0]` при любом
  `enableCommonName`, без проверки длины.
- Стоковый `Certifier.getForOrder` (`certificates.go:352-354`):
  `if len(domains[0]) <= 64 && request.EnableCommonName`.

Вход: первый домен 65 байт, `disableCommonName: false`.

- Стоковый CSR: CN пустой, имя живёт только в SAN.
- Новый CSR: CN = 65-байтовая строка. `x509.CreateCertificateRequest` это
  принимает; CA с лимитом X.520 (64) заявку отвергнет, хотя без `csrSubject`
  тот же домен проходил.

Спека буквально просила `CommonName = domains[0]`, поэтому это расхождение со
стоком, а не нарушение текста спеки.

### Продление берёт имена из `Resource.Domains`, не из сертификата

- Новый путь: `csr.go:139` — `p.csrRequest(res.Domains, key)`.
- Стоковый `Renew` (`certificates.go:612`): `certcrypto.ExtractDomains(x509Cert)`.

Traefik заполняет `res.Domains` из `cert.Domain.ToStrArray()` (`provider.go:958`).
Пока Main/SANs совпадают с тем, что CA положил в сертификат, разницы нет.

Вход, где разъедется: в `acme.json` стёрт/побился `Domain`, а тело сертификата
целое. Стоковый `Renew` продлит по SAN сертификата. Новый путь упрётся в
`cannot build CSR without domains` и сертификат не продлится.

`NotBefore`/`NotAfter` из `RenewOptions` на CSR-пути тоже отбрасываются
(`csr.go:151-159` не читает `opts`). У единственного вызывающего
(`provider.go:963-971`) эти поля нулевые, сейчас это тождество.

### Регистр `Country` не канонизируется

- `csr.go:36-43` принимает `"ru"`; `csr.go:77-78` кладёт в CSR как есть.
- ISO 3166-1 alpha-2 и типичный PrintableString в CN — заглавные.

Вход: `csrSubject.country: "ru"`. CSR содержит `C=ru`, не `C=RU`. Тесты это
считают валидным (`TestCSRSubjectValidation`). Отвергнет ли НУЦ именно
строчные — догадка; факт в том, что нормализации нет.

### `GetKeyType` на выпуске зовётся с `context.Background()`

- CSR-путь: `csr.go:106`.
- Стоковый `Obtain`: `GetKeyType(ctx, p.KeyType)` (`provider.go:700` и `:757`).

На тип ключа не влияет (функция смотрит только строку `KeyType`). Меняется
только контекст логгера при пустом/неизвестном значении.

## Что проверялось и не подтвердилось как дефект

- Пустой `CSRSubject` остаётся на `Obtain`/`Renew`; `IsEmpty` и `Validate`
  терпят nil-получатель.
- `PrivateKey` в `ObtainForCSRRequest` заполняется; без него lego не кладёт
  ключ в `Resource`, и Traefik отбрасывает результат.
- Продление не ходит в `Renew` при непустом Subject и переиспользует
  сохранённый ключ.
- `Bundle`, `Profile`, `PreferredChain`, `EnableCommonName`, `EmailAddresses`
  копируются в запрос; мутации этих полей тесты убивают.
- Двойной `Validate` (в `obtainForCSRRequest` и в `buildCSR`) — лишний, не
  ломает поведение.
- Выпуск в `resolveCertificate` / `resolveDefaultCertificate` по-прежнему
  передаёт полный `domains`, как стоковый `Obtain`. Это не регрессия патча.

Покрытие: `csr_test.go` не вызывает `resolveCertificate` /
`resolveDefaultCertificate`. Обрыв ветки `IsEmpty` прямо в `provider.go:692`
или `:749` существующие тесты не увидят. Это дыра в тестах, не в коде; чинить
в этом прогоне нельзя.

## Догадки

- НУЦ может требовать именно `C=RU` в верхнем регистре. Патч это не
  гарантирует (см. регистр выше).
- Порядок RDN в `pkix.Name` задаёт Go (`C, O, OU, L, CN`). Если НУЦ сверяет
  канонический DN побайтно, это может разъехаться со «ручным» CSR. Не
  проверялось против живого НУЦ.

## M1a (`37b1a18`)

Дифф `280021e..37b1a18` трогает только `buildCSR` и тесты к трём веткам:
деление SAN через `net.ParseIP`, `len(domains[0]) <= 64 && enableCommonName`,
`strings.ToUpper` для Country. `provider.go` не менялся.

Мутационный прогон: `scripts/mutation_gate_m1a_cross.py` — убито 8/8, выживших
нет. Авторские десять и прежние четырнадцать не повторялись.

Прежний `mutation_gate_m1_cross.py` на этом дереве даёт 11/14. Три мутации
не легли: `DNSNames: domains` и `if enableCommonName {` (дважды) — M1a
переименовал фрагменты в `dnsNames` и `len(domains[0]) <= 64 && enableCommonName`.
Это не дыра в тестах: `TestCSRSubjectDNSNames` и `TestCSRSubjectFields` живы,
а `enableCommonName ignored for CN` в новом гейте закрывает ту же ветку.
Гейт M1 по спеке не трогался.

### Закрытие находок M1

1. **IP в `DNSNames`** — закрыто. `csr.go:73-79` копирует стоковый
   `certcrypto.CreateCSR` (`crypto.go:145-151`): `ParseIP != nil` →
   `IPAddresses`, иначе `DNSNames`. Тест `TestCSRSubjectIPAddresses` проверяет
   оба поля и оба семейства адресов.
2. **CN длиннее 64 байт** — закрыто. `csr.go:86` совпадает со стоковым
   `getForOrder` (`certificates.go:352`): `len(domains[0]) <= 64 && enableCommonName`.
   Граница покрыта с обеих сторон (64 ставится, 65 опускается), имя остаётся в
   `DNSNames`.
3. **Регистр Country** — закрыто (это делали сверх двух обязательных пунктов
   M1a). `csr.go:90-91` кладёт `strings.ToUpper(subject.Country)` в CSR и не
   меняет конфиг. Вход `"ru"` даёт `C=RU`.

Не чинилось и осталось как в M1:

- Продление по `res.Domains`, не по SAN сертификата (`csr.go:152`).
- `GetKeyType(context.Background(), …)` (`csr.go:119`).
- `RenewOptions.NotBefore`/`NotAfter` на CSR-пути игнорируются.

### Новые дефекты

Нет.

### Новые расхождения со стоком

Новых нет. Сверка с `CreateCSR` и `getForOrder` в lego v5.4.1:

- Деление SAN побайтово совпадает с `CreateCSR`.
- CN берётся из `domains[0]` (в том числе если это IP) — так требует спека M1a
  и так делает `getForOrder`.
- Весь `domains` прогоняется через split, поэтому IP из `domains[0]` попадает и
  в CN (строка), и в `IPAddresses`. Стоковый путь кладёт CN ещё и в SAN, после
  чего `CreateCSR` тоже кладёт IP в `IPAddresses`. Результат тот же.
- `ToUpper` для Country в стоковом `Obtain` нет: там Subject не заполняется.
  Это не расхождение путей, а новое поле.

`len` для лимита CN, а не `RuneCountInString` — как в стоке. На ASCII-доменах
тестов это тождество; на не-ASCII длинном CN оба пути опустили бы его одинаково,
потому что байт больше рун.

---

## Приёмка координатора (2026-09-06)

Обе находки M1 перепроверены по исходникам lego v5.4.1 до починки и подтверждены
дословно: `certcrypto/crypto.go:145-151` (разбор IP) и
`certificate/certificates.go:352` (лимит 64 на CN). Отдельно проверено, что
`Provider.sanitizeDomains` (`provider.go:1070`) IP не отбрасывает, то есть адрес
легально доезжает до построения CSR — без этого находка была бы теоретической.

Результат M1a проверен независимо от тестов исполнителя, выгрузкой настоящего
CSR и разбором его `openssl`:

- `["203.0.113.10", "example.org"]` → `DNS:example.org, IP Address:203.0.113.10`;
- домен 65 байт → `subject=C=RU`, CN отсутствует, имя живо в SAN;
- `country: "ru"` → `C=RU`.

Три мутации прежнего кросс-гейта, переставшие ложиться после M1a, проверены
вручную на новом коде: обе убиваются тестами на своих строках ассерта
(`csr_test.go:50` и `csr_test.go:113`), байты восстановлены со сверкой sha256.
Дыры в тестах нет — гейт устарел текстуально.
