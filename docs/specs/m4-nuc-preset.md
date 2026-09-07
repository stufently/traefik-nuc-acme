# Веха M4 — пресет НУЦ и бандл его CA

## Зачем веха

Фича `csrSubject` готова и проверена на стенде. Осталось дать пользователю
готовую конфигурацию под НУЦ — российский гос-ACME-CA, ради которого фича и
писалась, — и решить проблему доверия к его TLS: `nuc-acme.voskhod.ru`
подписан корнем Минцифры, которого нет ни в одном стандартном хранилище, и
`curl` падает на рукопожатии ещё до начала ACME.

## Проверено вживую 2026-09-07 (на это опирается спека)

Всё ниже измерено, а не взято из документации:

- **Директория ACME:** `https://nuc-acme.voskhod.ru/acme/api/v1/directory`,
  HTTP 200, валидный RFC 8555. Отдаёт `newNonce`, `newAccount`, `newOrder`,
  `revokeCert`, `keyChange`; `newAuthz` и `renewalInfo` отсутствуют,
  **`meta` равен `null`**.
- **`meta: null` для lego v5.4.1 безопасен:** в `acme/commons.go:49` поле
  объявлено значением (`Meta Meta`), а не указателем, поэтому JSON `null`
  разворачивается в нулевую структуру. Следствие: `externalAccountRequired`
  ложно, EAB не требуется.
- **Цепочка доверия.** Лист `CN=nuc-acme.voskhod.ru, O=Минцифры России`
  подписан `Russian Trusted Sub CA`. Сервер промежуточный сертификат **НЕ
  досылает** — одного корня недостаточно (`ssl_verify_result=20`).
- **🚩 Ловушка, стоившая половины ресерча.** Широко растиражированный
  `https://gu-st.ru/content/lending/russian_trusted_sub_ca_pem.crt` (серийник
  `1002`, выпущен в 2022) **НЕ является издателем** текущего листа: его SKI
  `D1:E1:71:0D…`, а AKI листа `77:3D:D9:39…`. Настоящий издатель берётся из
  AIA самого листа: `http://nuc-cdp.voskhod.ru/cdp/subca_ssl_rsa2024.crt`
  (DER, выпущен 2024-07-15, годен до 2029-07-19, SKI `77:3D:D9:39…`).
- **Рабочий бандл:** корень + этот Sub CA дают `ssl_verify_result=0` и
  `openssl verify` → OK.

| файл | источник | sha256 |
|---|---|---|
| `russian_trusted_root_ca_pem.crt` | `https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt` | `936a43fea6e8e525bcc0f81acd9c3d21b4fc4b9b68acea7906d698005afc6504` |
| `subca_ssl_rsa2024.crt` (DER) | `http://nuc-cdp.voskhod.ru/cdp/subca_ssl_rsa2024.crt` | `6f9d829c8e6712444fce3624658d8788672849c5d5b7b53fd9cf7e83eac4193e` |

**Предположения, НЕ проверенные (пометить как таковые и в коде, и в доке):**

- что НУЦ требует именно `keyType: RSA2048` и отвергает EC-ключи. Косвенно:
  публичные инструкции говорят про RSA DV. Проверить можно только с
  аккредитацией, которой нет.
- что выпуск и продление против боевого НУЦ работают. Доступа нет; живая
  проверка остаётся отдельным шагом «после доступа».

## Решение по бандлу: НЕ вшивать в образ

Sub CA уже ротировался (2022 → 2024), и вшитый в образ бандл молча протух бы
на следующей ротации: пользователь получил бы отказ рукопожатия и никакого
намёка, что дело в устаревшем файле внутри образа. Поэтому бандл собирается
скриптом с пинами и монтируется снаружи. Решение координатора, не владельца;
обратимо — вшить файл позже дешевле, чем выковыривать.

## Где работать

Клон, ветка `m4-nuc-preset`. Спека лежит в клоне как
`docs/specs/m4-nuc-preset.md` и уже входит в коммит ветки — отдельно
коммитить её не нужно, править и удалять нельзя.

Go зови ТОЛЬКО через `scripts/upstream-go.sh` (офлайн-кэш модулей).
Сеть нужна: скрипт бандла ходит на `gu-st.ru` и `nuc-cdp.voskhod.ru`.
Если сети нет — это `blocked` с доказательством, а не повод подделать файлы.

## Что сделать

### 1. `presets/nuc.yml`

Статическая конфигурация Traefik под НУЦ: `caServer` ровно тем URL, что
проверен выше; `keyType: RSA2048`; `csrSubject.country: RU` плюс
`organization`/`locality` как заполняемые пользователем примеры;
`caCertificates` указывает на смонтированный бандл; `httpChallenge`.
Комментарии в файле объясняют, что именно пользователь обязан заменить и
какие поля — предположение, а не измеренный факт.

### 2. `scripts/nuc-ca-bundle.sh`

Собирает PEM-бандл: корень + издающий Sub CA (DER → PEM).

- пины sha256 обоих файлов заданы в скрипте; несовпадение — отказ с
  ненулевым кодом и внятным сообщением, файл назначения НЕ создаётся и НЕ
  портится;
- флаги `--root-sha256` / `--sub-sha256` позволяют пережить ротацию, не правя
  скрипт; `-o` задаёт путь назначения;
- запись атомарна: скачивание во временный файл, `mv` в цель только после
  всех проверок;
- скрипт идемпотентен: второй запуск даёт побайтово тот же файл;
- при склейке PEM следить за переводом строки между сертификатами —
  без него получается `-----END-----BEGIN-----` и OpenSSL says `bad end line`.

### 3. Документация

Раздел в `README.md`: как поднять Traefik под НУЦ, как собрать и смонтировать
бандл, почему он не вшит в образ, и явное предупреждение, что боевой НУЦ
**НЕ ПРОВЕРЕН** — против него не выпускался ни один сертификат. Отдельно
назвать ловушку с чужим Sub CA: издателя брать из AIA листа.

Запись в `CHANGELOG.md` про добавленное.

## Критерии приёмки

Каждый критерий проверяет ПРИЧИНУ, а не только код возврата: у падения по
среде и падения по сути код одинаковый, поэтому коды разведены.

- **AC-001** — пресет проходит наш собственный гвард:
  `bash -c 'out=$(scripts/upstream-go.sh run ./cmd/traefik validate-csr-subject --configfile=presets/nuc.yml 2>&1); rc=$?; if [ "$rc" -ne 0 ]; then printf "гвард отверг пресет: %s\n" "$out" >&2; exit 3; fi; printf "%s\n" "$out" | grep -q "csrSubject OK" || { echo "нет подтверждения csrSubject OK" >&2; exit 4; }'`
- **AC-002** — 🚩 пресет ловится гвардом, если испортить страну (доказывает,
  что критерий выше проверяет ПРЕСЕТ, а не сам факт запуска):
  `bash -c 'd=$(mktemp -d); sed "s/country: RU$/country: RUS/" presets/nuc.yml > "$d/bad.yml"; out=$(scripts/upstream-go.sh run ./cmd/traefik validate-csr-subject --configfile="$d/bad.yml" 2>&1); rc=$?; printf "%s\n" "$out" | grep -q "invalid CSR subject in resolver" || { printf "нет ожидаемой причины: %s\n" "$out" >&2; exit 3; }; [ "$rc" -ne 0 ] || { echo "испорченный пресет принят" >&2; exit 4; }'`
- **AC-003** — пресет указывает ровно проверенный адрес директории:
  `bash -c 'grep -qF "caServer: https://nuc-acme.voskhod.ru/acme/api/v1/directory" presets/nuc.yml || { echo "caServer не тот, что проверен" >&2; exit 3; }'`
- **AC-004** — пресет задаёт тип ключа и страну:
  `bash -c 'grep -qE "^ *keyType: RSA2048" presets/nuc.yml || { echo "нет keyType RSA2048" >&2; exit 3; }; grep -qE "^ *country: RU$" presets/nuc.yml || { echo "нет country RU" >&2; exit 4; }'`
- **AC-005** — 🚩 бандл собирается и ДЕЙСТВИТЕЛЬНО валидирует живой TLS НУЦ:
  `bash -c 'd=$(mktemp -d); scripts/nuc-ca-bundle.sh -o "$d/ca.pem" >/dev/null 2>&1 || { echo "скрипт не собрал бандл" >&2; exit 2; }; n=$(grep -c "BEGIN CERTIFICATE" "$d/ca.pem"); [ "$n" -eq 2 ] || { echo "в бандле $n сертификатов, нужно 2" >&2; exit 3; }; v=$(curl -sS --cacert "$d/ca.pem" -o "$d/dir.json" -w "%{ssl_verify_result}" https://nuc-acme.voskhod.ru/acme/api/v1/directory 2>/dev/null); [ "$v" = "0" ] || { echo "TLS не проверился: ssl_verify_result=$v" >&2; exit 4; }; grep -q "newOrder" "$d/dir.json" || { echo "директория не получена" >&2; exit 5; }'`
- **AC-006** — 🚩 скрипт ОТКАЗЫВАЕТ на неверном пине и не оставляет файла:
  `bash -c 'd=$(mktemp -d); out=$(scripts/nuc-ca-bundle.sh --root-sha256 0000000000000000000000000000000000000000000000000000000000000000 -o "$d/ca.pem" 2>&1); rc=$?; [ "$rc" -ne 0 ] || { echo "неверный пин принят" >&2; exit 3; }; printf "%s\n" "$out" | grep -qiE "sha256|пин|checksum" || { printf "отказ без внятной причины: %s\n" "$out" >&2; exit 4; }; [ ! -e "$d/ca.pem" ] || { echo "при отказе остался файл назначения" >&2; exit 5; }'`
- **AC-007** — скрипт идемпотентен: два прогона дают побайтово одно и то же:
  `bash -c 'd=$(mktemp -d); scripts/nuc-ca-bundle.sh -o "$d/a.pem" >/dev/null 2>&1 && scripts/nuc-ca-bundle.sh -o "$d/b.pem" >/dev/null 2>&1 && cmp "$d/a.pem" "$d/b.pem"'`
- **AC-008** — пресет работает СМОНТИРОВАННЫМ в образ, а не только на хосте:
  `bash -c 'docker build -q -t traefik-nuc-acme:m4 -f Dockerfile . >/dev/null || { echo "образ не собрался" >&2; exit 2; }; out=$(docker run --rm -v "$PWD/presets/nuc.yml:/etc/traefik/traefik.yml:ro" traefik-nuc-acme:m4 validate-csr-subject 2>&1); rc=$?; printf "%s\n" "$out" | grep -q "csrSubject OK" || { printf "гвард в образе не принял пресет: %s\n" "$out" >&2; exit 3; }; [ "$rc" -eq 0 ] || { echo "ненулевой код при валидном пресете" >&2; exit 4; }'`
- **AC-009** — README называет и ловушку, и непроверенность боевого НУЦ:
  `bash -c 'grep -qiE "AIA|Authority Information Access" README.md || { echo "не описано, откуда брать издателя" >&2; exit 3; }; grep -qiE "UNVERIFIED|не проверен" README.md || { echo "нет предупреждения о непроверенности" >&2; exit 4; }'`
- **AC-010** — 🚩 продукт прошлых вех НЕ тронут: патч побайтово прежний:
  `bash -c 'git diff --quiet HEAD -- patches/ || { echo "патч изменён" >&2; exit 3; }; s=$(sha256sum patches/0001-csr-subject.patch | cut -d" " -f1); [ "$s" = "9ac0205f847957d95316c7fd7fdf4d1389c64e3cefe9d066cc96cb6276e1e035" ] || { echo "sha патча разошлась: $s" >&2; exit 4; }'`
- **AC-011** — гейт мутаций прошлых вех по-прежнему зелёный (17/17):
  `bash -c 'python3 scripts/mutation_gate_m1.py'`
- **AC-012** — дерево чистое и никаких GitHub Actions:
  `bash -c 'test -z "$(git status --porcelain -- . ":(exclude)report.json" ":(exclude)report-blocked.md")" || { echo "дерево грязное" >&2; exit 3; }; test -z "$(git ls-files -- ".github")" && test ! -d .github || { echo "появился .github" >&2; exit 4; }'`

## Контракт отчёта

`report.json` в корне клона, по критерию на каждый AC:

```json
{"criteria": [{"id": "AC-001", "status": "pass|fail|blocked",
  "command": "<команда-доказательство>", "rc": 0, "note": "…"}]}
```

`command` обязана быть перезапускаемой: её перезапустит приёмка. Не дописывай
в хвост `printf`/`echo` «для наглядности» — хвост съедает код возврата, и
критерий вернёт ноль при любом исходе. Всё для глаз — в `note`.

## Не трогать

- `patches/0001-csr-subject.patch` и `.upstream/` — продукт прошлых вех.
  Эта веха НЕ меняет ни строки кода Traefik.
- `Dockerfile` — бандл в образ не вшивается, это решение вехи.
- `docker/entrypoint.sh`, `cmd/`, `scripts/mutation_gate_m1.py`.
- `docs/specs/` — постановка не правится.
- `.github/` — в этом репозитории не должно быть GitHub Actions ВООБЩЕ.

## Контракт на невыполнимое

Требование невыполнимо или противоречиво — **остановись и доложи** в
`report-blocked.md`: что требовалось, чем проверял, почему не выходит.
Обходить несовместимость, подгонять проверку под результат или менять продукт
ради зелёного критерия ЗАПРЕЩЕНО. Отдельно: если сеть до `gu-st.ru` или
`nuc-cdp.voskhod.ru` недоступна — это `blocked` с выводом команды, а НЕ повод
положить сертификаты в репозиторий руками.
