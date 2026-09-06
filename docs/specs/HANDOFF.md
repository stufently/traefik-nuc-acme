# Хендофф координатору проекта

Эта сессия (`cl-traefik-nuc-acme`) ведёт проект целиком. Бот-сессия
`cl-tg-claude-userbot` его завела и запустила первую веху, дальше — за тобой.

## Что уже сделано (06.09.2026)

- Ресерч по исходному замыслу (чат ChatGPT владельца + тред Habr Q&A) —
  `/home/deploy/gitlab/9qw/tg-claude-userbot/tmp/briefs/chatgpt-project-research.md`.
  Читать обязательно: там же перечислены дыры постановки и открытые вопросы.
- Репозиторий заведён и запушен: `github.com/stufently/traefik-nuc-acme`,
  локально `/home/deploy/github/traefik-nuc-acme`.
- Спека вехи 1 — `docs/specs/m1-csr-subject.md`, preflight пройден (9 критериев).
- Клон исполнителя `/home/deploy/exec-clones/traefik-nuc-m1` укомплектован
  офлайн: исходники Traefik v3.7.13, кэш Go-модулей (5.6 ГБ), обёртка
  `scripts/upstream-go.sh`. Проверено вживую: тесты `pkg/provider/acme` и
  `pkg/config` зелены офлайн (`GOPROXY=off`), сокетов эти тесты не открывают.
- **Исполнитель запущен:** панель `cx-traefik-nuc-m1` (Codex).

## Что делать дальше

1. Наблюдать прогон ТОЛЬКО через `watch.sh` в Monitor — никаких `tail -f` и
   циклов опроса. На время прогона сессия свободна.
2. Приёмка: `python3 /home/deploy/gitlab/9qw/tg-claude-userbot/scripts/accept_run.py
   /home/deploy/exec-clones/traefik-nuc-m1 --spec /home/deploy/exec-clones/traefik-nuc-m1/docs/specs/m1-csr-subject.md`.
   Гейт перезапускает команды критериев сам.
3. Дальше руками: прочитать патч целиком, проверить границы «Не трогать»,
   прогнать тесты своей командой, отдельно прогнать мутации по НОВЫМ тестам.
   **Перекрёстные мутации гоняет Grok** — противоположный исполнитель.
4. Забрать работу: `git -C /home/deploy/github/traefik-nuc-acme fetch
   /home/deploy/exec-clones/traefik-nuc-m1 m1-csr-subject:m1-csr-subject`,
   слить, запушить. Панель погасить `tmux kill-session -t cx-traefik-nuc-m1`
   ТОЛЬКО после того, как убедишься, что всё закоммичено.
5. Вехи 2 и 3 и открытые вопросы владельцу — в `TASKS.md`.

## Ограничения, которые нельзя нарушать

- **Никакого `.github/workflows/` до 2026-10-06.** Всё гоняется локально Docker'ом.
- Реализация — руками Codex/Grok по спеке, не руками Claude. Claude здесь
  координирует: пишет спеку, принимает веху, сводит итог.
- Ничего не ставить на хост. Go 1.26.0 на хосте уже есть и совпадает с `go.mod`
  апстрима — `GOTOOLCHAIN` подставлять не надо.
