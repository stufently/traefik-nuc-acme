# Веха M3 — fail-closed валидация `csrSubject` до старта Traefik

Продолжение вех M1 (патч `csrSubject`) и M2 (образ и стенд), `main` = `9ededf5`.

Эта спека лежит в клоне как `docs/specs/m3-config-guard.md` и приехала УЖЕ
закоммиченной — отдельно её коммитить не надо.

## Зачем веха

Неверный `csrSubject` СЕЙЧАС не останавливает Traefik. Он пишет
`ERR The ACME resolve is skipped from the resolvers list  error="invalid CSR
subject: …"` и продолжает работать без этого резолвера: пользователь не получает
НИ ОДНОГО сертификата, а причина видна только в логе. Проверено запуском
собранного бинаря с `country=RUS`: процесс не завершается, `rc=124` по таймауту.

Так ведёт себя стоковый Traefik со ВСЕМИ ошибками резолверов, поэтому менять это
поведение мы не будем — форк в месте, которое апстрим менять не собирается,
оплачивается на каждом ребейзе. Гвард ставится РАНЬШЕ: конфиг проверяется до
старта сервера, и невалидный субъект громко останавливает запуск.

## Ключевое архитектурное требование

Гвард обязан читать **ТОТ ЖЕ конфиг, что и Traefik**. У Traefik есть цепочка
источников и путей поиска: загрузчики `[]cli.ResourceLoader{&tcli.DeprecationLoader{},
&tcli.FileLoader{}, &tcli.FlagLoader{}, &tcli.EnvLoader{}}` (`cmd/traefik/traefik.go:58`),
а `FileLoader` ищет файл по `BasePaths` `/etc/traefik/traefik`,
`$XDG_CONFIG_HOME/traefik`, `$HOME/.config/traefik`, `./traefik` и разбирает флаг
`traefik.configfile` (`pkg/cli/loader_file.go:32-71`).

🚨 **Поэтому подкоманда обязана получать ТОТ ЖЕ массив `loaders`, а не звать
парсер сама.** Гвард, читающий другой файл, ХУЖЕ отсутствующего гварда:
отсутствие проверки видно, а проверка, отвечающая на другой вопрос, даёт ложную
уверенность и обнаруживается только инцидентом.

Образец для подражания — подкоманда `healthcheck`
(`cmd/healthcheck/healthcheck.go`): `NewCmd(cfg *static.Configuration, loaders
[]cli.ResourceLoader) *cli.Command`, регистрируется в `traefik.go` тем же
`loaders`. Делай так же.

## Где работать

- Клон: `/home/deploy/exec-clones/traefik-nuc-m3` (твой). Другие клоны в
  `~/exec-clones/` и живое дерево `/home/deploy/github/traefik-nuc-acme` НЕ ТРОГАТЬ.
- Новая ветка от `main`: `m3-config-guard`.
- Апстрим — `.upstream/traefik` (патч M1 уже наложен), Go только обёрткой
  `scripts/upstream-go.sh` (офлайн, `GOPROXY=off`). `GOTOOLCHAIN` НЕ подставлять.
- У тебя ЕСТЬ Docker, сеть и слушающие сокеты (замер в `env-probe.txt` клона M2).
- Право пуша у клона отобрано намеренно (`push origin no-push`) — работу заберёт
  координатор фетчем. Не пытайся пушить и не меняй remote.

## Что сделать

### 1. Подкоманда в патче

Новый пакет в апстриме (например `cmd/validatecsr/`) и регистрация в
`cmd/traefik/traefik.go` рядом с `healthcheck`, ТЕМ ЖЕ `loaders`.

Поведение:

- пройтись по всем `cfg.CertificatesResolvers`, у которых есть ACME;
- для каждого вызвать существующую `(*CSRSubject).Validate()` из вехи M1 —
  НЕ дублировать правила валидации, единственный источник правды один;
- при первой ошибке напечатать в **stderr** строку СТРОГО такого вида и выйти
  с кодом **1**:
  `invalid CSR subject in resolver "<имя>": <текст ошибки>`
- если невалидных нет — напечатать в stdout `csrSubject OK` и выйти с кодом **0**.

Оба направления обязательны: «отказывает на плохом» без «пропускает хорошее» —
это критерий, который нельзя удовлетворить, он стоит перезапуска панели.

### 2. Энтрипоинт образа

`ENTRYPOINT` образа становится скриптом, который СНАЧАЛА гоняет
`/traefik validate-csr-subject "$@"`, и только при коде 0 делает
`exec /traefik "$@"`. При ненулевом коде — выходит с ним же, не запуская сервер.

Исключение: если первый аргумент — существующая подкоманда (`healthcheck`,
`version`), валидацию пропускать, иначе сломаешь эти команды.

### 3. Тесты в апстриме

`cmd/validatecsr/*_test.go`: валидный субъект → nil/0; невалидная страна →
ошибка с ожидаемым текстом; НЕСКОЛЬКО резолверов, где невалиден второй (гвард
обязан проверять все, а не только первый); резолвер без ACME не роняет гвард;
пустой `csrSubject` валиден.

### 4. Мутационный гейт

Расширь `scripts/mutation_gate_m1.py` — не менее ТРЁХ новых мутаций по гварду:
проверяется только первый резолвер; код возврата всегда 0; текст ошибки не
содержит имени резолвера. Правила прежние: фрагмент встречается ровно один раз
до замены, мутация ЛОЖИТСЯ, падает ИМЕННО целевой тест на своей строке, байты и
sha256 восстанавливаются в `finally`. Прежние мутации не ломать.

### 5. Патч, документация

- `patches/0001-csr-subject.patch` перегенерировать (`git -C .upstream/traefik diff`).
- `README.md` — раздел, объясняющий, ПОЧЕМУ валидация вынесена перед стартом:
  стоковый Traefik пропускает резолвер с ошибкой и работает дальше, поэтому
  опечатка иначе стоила бы молчаливого отсутствия сертификатов.
- `CHANGELOG.md` — запись за 2026-09-07.

## Не трогать

- Поведение стокового Traefik при ошибках резолверов — только ДОБАВЛЯЕМ
  подкоманду, существующую логику `initACMEProvider` не меняем.
- `docs/specs/`, `docs/reviews/`, `TASKS.md`, `CLAUDE.md`, `LICENSE`,
  `upstream.lock`, `scripts/upstream-go.sh`, `.gitignore`.
- `.upstream/traefik/` вне `pkg/provider/acme/`, `cmd/validatecsr/` и одной
  строки регистрации в `cmd/traefik/traefik.go`.
- **`.github/` не создавать НИ В КАКОМ ВИДЕ** — минуты GitHub Actions исчерпаны
  до 2026-10-06.
- `go.mod`/`go.sum` апстрима: новых зависимостей веха не вводит.
- Реальный пуш куда бы то ни было.

## Критерии приёмки

Каждый критерий проверяет ПРИЧИНУ, а не только код возврата: у падения по среде
и падения по сути код одинаковый.

- **AC-001** — патч накладывается на ЧИСТЫЙ апстрим:
  `bash -c 'd=$(mktemp -d) && tar -xzf .upstream/traefik-v3.7.13.tar.gz -C "$d" && git -C "$d/traefik-3.7.13" init -q && git -C "$d/traefik-3.7.13" apply --check /home/deploy/exec-clones/traefik-nuc-m3/patches/0001-csr-subject.patch'`
- **AC-002** — патч детерминирован:
  `bash -c 'f=$(mktemp) && git -C .upstream/traefik diff > "$f" && diff -u patches/0001-csr-subject.patch "$f"'`
- **AC-003** — апстрим собирается целиком:
  `bash -c 'scripts/upstream-go.sh build ./...'`
- **AC-004** — тесты затронутых пакетов зелёные:
  `bash -c 'scripts/upstream-go.sh test -count=1 ./pkg/provider/acme/... ./pkg/config/... ./cmd/...'`
- **AC-005** — `go vet` чист:
  `bash -c 'scripts/upstream-go.sh vet ./pkg/provider/acme/... ./cmd/...'`
- **AC-006** — все мутации убиты, включая новые:
  `bash -c 'python3 scripts/mutation_gate_m1.py'`
- **AC-007** — 🚩 гвард ОТКАЗЫВАЕТ на невалидном субъекте, и отказ по ЗАДУМАННОЙ
  причине (проверяется ТЕКСТОМ; разные коды выхода говорят, что именно не так):
  `bash -c 'out=$(scripts/upstream-go.sh run ./cmd/traefik validate-csr-subject --certificatesresolvers.t.acme.csrsubject.country=RUS --certificatesresolvers.t.acme.storage=/tmp/m3a.json 2>&1); rc=$?; if ! printf "%s\n" "$out" | grep -q "invalid CSR subject in resolver"; then printf "нет ожидаемой причины отказа: %s\n" "$out" >&2; exit 3; fi; if [ "$rc" -eq 0 ]; then echo "гвард не отказал: код 0" >&2; exit 4; fi'`

- **AC-008** — 🚩 гвард ПРОПУСКАЕТ валидный субъект (обратное направление):
  `bash -c 'out=$(scripts/upstream-go.sh run ./cmd/traefik validate-csr-subject --certificatesresolvers.t.acme.csrsubject.country=RU --certificatesresolvers.t.acme.storage=/tmp/m3b.json 2>&1) && printf "%s\n" "$out" | grep -q "csrSubject OK"'`
- **AC-009** — гвард читает конфиг ЦЕПОЧКОЙ ЗАГРУЗЧИКОВ Traefik, а не сам: конфиг
  из ФАЙЛА в нестандартном месте, указанный `--configfile`, обязан быть учтён —
  собственный парсер этого не сделает:
  `bash -c 'd=$(mktemp -d); printf "certificatesResolvers:\n  t:\n    acme:\n      storage: /tmp/m3c.json\n      csrSubject:\n        country: RUS\n" > "$d/cfg.yml"; out=$(scripts/upstream-go.sh run ./cmd/traefik validate-csr-subject --configfile="$d/cfg.yml" 2>&1); rc=$?; if ! printf "%s\n" "$out" | grep -q "invalid CSR subject in resolver"; then printf "конфиг из файла не учтён: %s\n" "$out" >&2; exit 3; fi; if [ "$rc" -eq 0 ]; then echo "гвард не отказал на файле: код 0" >&2; exit 4; fi'`

- **AC-010** — 🚩 ОБРАЗ отказывается стартовать с невалидным конфигом: контейнер
  ЗАВЕРШАЕТСЯ с ненулевым кодом и в логах наша причина. Критерий НЕБЛОКИРУЮЩИЙ:
  Traefik без гварда не завершается вовсе, и ожидание его выхода повисло бы
  навсегда — поэтому контейнер поднимается фоном и опрашивается:
  `bash -c 'docker rm -f m3guard >/dev/null 2>&1; docker build -q -t traefik-nuc-acme:m3 -f Dockerfile . >/dev/null || { echo "образ не собрался" >&2; exit 2; }; docker run -d --name m3guard traefik-nuc-acme:m3 --certificatesresolvers.t.acme.csrsubject.country=RUS --certificatesresolvers.t.acme.storage=/tmp/a.json --entrypoints.web.address=:80 >/dev/null; sleep 8; st=$(docker inspect -f "{{.State.Status}}:{{.State.ExitCode}}" m3guard); lg=$(docker logs m3guard 2>&1); docker rm -f m3guard >/dev/null 2>&1; if ! printf "%s\n" "$lg" | grep -q "invalid CSR subject in resolver"; then printf "нет ожидаемой причины в логах: %s\n" "$lg" >&2; exit 3; fi; if [ "$st" != "exited:1" ]; then printf "контейнер не завершился с кодом 1: %s\n" "$st" >&2; exit 4; fi'`

- **AC-011** — 🚩 счастливый путь НЕ сломан: с валидным конфигом стенд
  по-прежнему выпускает сертификат, а CSR несёт Subject:
  `bash -c 'scripts/stand.sh down >/dev/null 2>&1; scripts/stand.sh up && scripts/stand.sh wait && scripts/stand.sh csr-dump | openssl req -noout -subject | grep -qE "C *= *RU"; rc=$?; scripts/stand.sh down >/dev/null 2>&1; exit $rc'`
- **AC-012** — дерево чистое и никаких GitHub Actions:
  `bash -c 'test -z "$(git status --porcelain -- . ":(exclude)report.json" ":(exclude)report-blocked.md" ":(exclude)env-probe.txt")" && test -z "$(git ls-files -- ".github")" && test ! -d .github'`

## Контракт отчёта

`report.json` в корне клона, ровно двенадцать записей:

```json
{"criteria": [{"id": "AC-001", "status": "pass|fail|blocked",
               "command": "<команда-доказательство>", "rc": 0, "note": "…"}]}
```

У AC-007, AC-009 и AC-010 в `note` приведи ДОСЛОВНУЮ строку отказа — она и есть
доказательство, что упало по задуманной причине.

## Контракт на невыполнимое

Несовместимость — остановись и доложи в `report-blocked.md`: что не сходится,
какой командой видно, какие варианты. Обходить запрещено: не глушить код
возврата, не отключать тесты, не менять стоковое поведение Traefik ради зелёного
критерия, не создавать `.github/`, не править эту спеку. Если дефект в САМОЙ
спеке — опиши его, правку внесёт координатор. Честная остановка дешевле
правдоподобного отчёта.
