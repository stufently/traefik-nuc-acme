# Перекрёстная мутационная проверка M3 (fail-closed гвард `csrSubject`)

Код вехи писал Codex. Ниже — мутации по новому коду гварда. Выживший
мутант — дыра в тестах, не в продукте: код и тесты не переписывались.

Протокол для каждой своей мутации: целевой тест зелёный на чистом дереве;
фрагмент нашёлся ровно один раз и файл после правки отличается; гонялся
только целевой тест через `scripts/upstream-go.sh`; убийство засчитывалось
только на строке ассерта целевого теста; исходные байты и sha256
восстановлены в `finally`.

Исходные sha256 до прогона и после восстановления совпали:

- `cmd/validatecsr/validatecsr.go` `e0f902da15f700de1af4f5bfd55ce46ca2a961e22278aa71f7be8daae5569d6e`
- `cmd/traefik/traefik.go` `d77b5471855988124ad07788f2ddfd9732455de0a4a3b2042e615b3f79bce57c`
- `docker/entrypoint.sh` `1ad6f0af938f03ed95514fe5658fe77f0ffa3b6f56b65c536e0e30d86f74cc3d`

## Четыре мутации гейта

Все четыре фрагмента легли ровно один раз. Все четыре убиты заявленным
тестом на заявленной строке ассерта, не компилятором и не чужим тестом.

| мутация | файл | целевой тест | вердикт | строка ассерта |
|---|---|---|---|---|
| Guard checks only the first resolver (`names` → `names[:1]`) | `cmd/validatecsr/validatecsr.go` | `TestCSRGuardChecksAllResolvers` | убита | `validatecsr_test.go:50` |
| Guard always exits zero (`os.Exit(1)` → `os.Exit(0)`) | `cmd/validatecsr/validatecsr.go` | `TestCSRGuardExitStatus` | убита | `validatecsr_test.go:125` |
| Guard error omits resolver name | `cmd/validatecsr/validatecsr.go` | `TestCSRGuardInvalidCountry` | убита | `validatecsr_test.go:39` |
| Guard stops at a resolver without ACME (`continue` → `return nil`) | `cmd/validatecsr/validatecsr.go` | `TestCSRGuardKeepsWalkingPastNonACMEResolver` | убита | `validatecsr_test.go:63` |

Заявленные строки совпали с фактическими. «Guard always exits zero»
падает именно на проверке `rc != 1` (`:125`), а не на следующем ассерте
про stdout/stderr: при `os.Exit(0)` ошибка по-прежнему печатается в stderr.

## Свои мутации

| мутация | файл | целевой тест | вердикт | строка ассерта |
|---|---|---|---|---|
| `slices.Sorted` → `slices.Collect` (обход резолверов без сортировки) | `cmd/validatecsr/validatecsr.go` | `TestCSRGuardChecksAllResolvers` | выжила | — |
| `Validate()` пропускается, если `Country == ""` | `cmd/validatecsr/validatecsr.go` | `TestCSRGuardInvalidCountry` | выжила | — |
| `Resources: loaders[1:]` (выброшен `DeprecationLoader`) | `cmd/validatecsr/validatecsr.go` | `TestCSRGuardConfigSources` | выжила | — |
| EnvLoader раньше FlagLoader | `cmd/validatecsr/validatecsr.go` | `TestCSRGuardConfigSources` | выжила | — |
| ошибка гварда печатается в stdout, не в stderr | `cmd/validatecsr/validatecsr.go` | `TestCSRGuardExitStatus` | убита | `validatecsr_test.go:128` |
| `os.Exit(1)` заменён на `return err` | `cmd/validatecsr/validatecsr.go` | `TestCSRGuardExitStatus` | убита | `validatecsr_test.go:125` |
| `%q` → `%s` в тексте ошибки (имя резолвера без кавычек) | `cmd/validatecsr/validatecsr.go` | `TestCSRGuardInvalidCountry` | убита | `validatecsr_test.go:39` |
| `csrSubject OK` уходит в stderr | `cmd/validatecsr/validatecsr.go` | `TestCSRGuardSuccessOutput` | убита | `validatecsr_test.go:136` |
| инверсия `err != nil` / `err == nil` в `Do()` | `cmd/validatecsr/validatecsr.go` | `TestCSRGuardValidSubjects` | убита | `validatecsr_test.go:28` |
| `main()` передаёт в гвард `nil` вместо `loaders` | `cmd/traefik/traefik.go` | `TestAppendCertMetric` | выжила | — |
| энтрипоинт зовёт гвард без `"$@"` | `docker/entrypoint.sh` | нет юнит-теста | выжила | — |
| энтрипоинт игнорирует ненулевой статус гварда (`-ne 0` → `-eq 99`) | `docker/entrypoint.sh` | нет юнит-теста | выжила | — |
| энтрипоинт не исключает `healthcheck` из гварда | `docker/entrypoint.sh` | нет юнит-теста | выжила | — |

## Чего не хватает выжившим

**Обход без `slices.Sorted`.** `TestCSRGuardChecksAllResolvers` держит ровно
один невалидный резолвер, поэтому порядок имён не наблюдаем. Нет теста с
двумя невалидными резолверами, который требовал бы стабильно первое имя
в отсортированном порядке — хотя комментарий в `Do()` именно это обещает.

**`Validate()` при пустой стране.** Все невалидные фикстуры гварда — это
`Country: "RUS"`. Конфиг с пустой страной и `organization`/`locality` длиннее
64 рун `Do()` после мутации пропускает, хотя `(*CSRSubject).Validate()` из M1
такой субъект отвергает. Гвард не проверяет, что зовёт `Validate()` безусловно.

**Цепочка загрузчиков внутри `NewCmd`.** Тесты сами собирают
`[]cli.ResourceLoader{Deprecation, File, Flag, Env}` и отдают его в `NewCmd`.
Выброс `DeprecationLoader` и перестановка Flag/Env не ломают ни один
источник из `TestCSRGuardConfigSources`, потому что каждый подтест кормит
ровно один источник и не смотрит на deprecation-предупреждения. Нет проверки,
что `Resources` — тот же набор и в том же порядке, что у Traefik.

**`main()` с `nil` loaders.** Юнит-тесты гварда не ходят в `cmd/traefik.main`:
`TestCSRGuardProcess` заново конструирует `NewCmd` со своим срезом загрузчиков.
`TestAppendCertMetric` в том же пакете `main` остался зелёным — он `main()` не
вызывает. Регистрация `validatecsr.NewCmd(&tConfig.Configuration, loaders)`
в `traefik.go` ни одним юнит-тестом не покрыта. Живой бинарь из приёмки M3
это поймал бы; тесты вехи — нет. Это как раз «гвард, читающий другой файл»:
подкоманда стартует, но без File/Flag/Env.

## `docker/entrypoint.sh`

У скрипта нет юнит-тестов вообще. Три порчи легли по одному фрагменту,
после правки файл отличался, Go-тесты вехи к нему не обращаются.

Самая дорогая — вызов `/traefik validate-csr-subject` без `"$@"`. Гвард
читает дефолтный поиск `traefik.yml` (часто пустой → `csrSubject OK`), а
затем `exec /traefik "$@"` поднимает демон с настоящими флагами. Невалидный
`csrSubject` на флаге или `--configfile` молча проходит. Это хуже отсутствующего
гварда: оператор видит, что проверка «прошла».

Вторая порча (`-ne 0` → `-eq 99`) гоняет гвард, но при любом реальном отказе
всё равно делает `exec /traefik "$@"`. Образ стартует, резолвер стоково
выбрасывается из списка, сертификатов нет.

Третья — `healthcheck` забыт в обходе. `docker exec … healthcheck` сначала
гоняет гвард по конфигу контейнера. Для живого демона с валидным субъектом
это лишний проход; если в смонтированном файле субъект испортили после
старта, проба упадёт по CSR, а не по `/ping`. Спека M3 требовала обход
именно чтобы не ломать эти подкоманды.

Образный прогон AC-010 вехи M3 закрывает только «контейнер с `country=RUS` на
флагах завершается с кодом 1». Он не видит ни потерю argv, ни игнор статуса
на другом коде, ни healthcheck.

## Итог

Своих мутаций: 13. Выжило: 8. Убито: 5.

Мутации гейта по гварду: 4/4 убиты на заявленных строках, ложных срабатываний
нет.

Дыры тестов: нет проверки порядка нескольких невалидных резолверов; гвард
не обязан звать `Validate()` на субъекте без страны; цепочка загрузчиков
не сверяется с Traefik (состав и порядок); регистрация в `main()` не
покрыта; `entrypoint.sh` не покрыт совсем.

---

## Приёмка обзора (координатор, 2026-09-07)

Каждый вывод перепроверен прогоном, а не прочтением. Восемь выживших мутантов
разделились на две группы.

**Три покрыты приёмкой вехи, хотя мутационным гейтом действительно не ловятся.**
Утверждение обзора, что AC-010 «не видит ни потерю argv, ни игнор статуса»,
неверно — проверено на живом образе:

| порча | критерий | код | почему упало |
|---|---|---|---|
| энтрипоинт зовёт гвард без `"$@"` | AC-010 | 3 | гвард сказал `csrSubject OK`, а Traefik выбросил резолвер из списка |
| энтрипоинт игнорирует статус (`-ne 0` → `-eq 99`) | AC-010 | 4 | контейнер остался `running:0` вместо `exited:1` |
| `main()` передаёт в гвард `nil` вместо `loaders` | AC-009 | 3 | конфиг из `--configfile` перестал учитываться |

Разница существенная: покрытие есть, но живёт в критериях приёмки, а не в
повторяемом гейте. Это осознанный компромисс — регистрация в `traefik.go`
ограничена семью строками, и юнит-тест на неё потребовал бы вызывать `main()`.

**Пять не были покрыты ничем; четыре закрыты тестами, пятая описана.**
Добавлены `TestCSRGuardNamesFirstResolverInSortedOrder`,
`TestCSRGuardValidatesSubjectWithoutCountry` и
`TestCSRGuardUsesGivenLoadersUnchanged`; гейт вырос до 17 мутаций, все убиты на
своих строках ассертов. Последний тест сверяет цепочку загрузчиков поэлементно,
поэтому ловит и выброс `DeprecationLoader`, и перестановку `Env`/`Flag`
(проверено отдельной мутацией: `loader 0 replaced: got *cli.EnvLoader`).

Самой дорогой из пяти была не архитектурная, а тихая: `Validate()` вызывался бы
только при непустой стране. Субъект с пустым `country` и `organization` длиннее
64 рун прошёл бы гвард и выбросил резолвер уже в бою — тот самый fail-open,
против которого веха и написана.

Не закрыт один выживший: энтрипоинт, забывший исключить `healthcheck` из
проверки. Цена регрессии мала (лишний проход гварда перед пробой на живом
демоне с валидным конфигом), а машинерия для shell-тестов образа
несоразмерна — фиксируется как известный пробел, а не как долг.
