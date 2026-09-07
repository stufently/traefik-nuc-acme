#!/usr/bin/env python3
"""Check README.ru.md against README.md.

One check per invocation so a failing acceptance criterion names what broke:
`python3 scripts/readme_parity.py headings`. Exit code 0 means the check holds;
any other code prints the reason on stderr. Codes differ per check so a failure
by environment (2) is never mistaken for a failure by substance (3+).
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
EN = ROOT / "README.md"
RU = ROOT / "README.ru.md"

# Anything the English text names as a file, the Russian text must name too —
# derived from the original rather than listed by hand, so the rule cannot drift
# apart from what the README actually mentions.
PATH_TOKEN = re.compile(r"`([A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\-]+)+|[A-Za-z0-9_\-]+\.(?:md|lock|yml|yaml|json|sh|py))`")


def read(path):
    if not path.is_file() or not path.stat().st_size:
        sys.exit(f"{path.name} отсутствует или пуст")
    return path.read_text(encoding="utf-8")


def fences(text):
    return re.findall(r"```.*?```", text, flags=re.S)


def headings(text):
    return re.findall(r"^(#{1,6}) ", text, flags=re.M)


def check_headings():
    en, ru = headings(read(EN)), headings(read(RU))
    if len(en) != len(ru):
        sys.exit(f"разное число заголовков: EN={len(en)} RU={len(ru)}")
    for i, (a, b) in enumerate(zip(en, ru), 1):
        if a != b:
            sys.exit(f"заголовок #{i}: уровень EN={a!r} против RU={b!r}")


def check_cyrillic():
    """A copy of the English file passes every other check; only this one sees
    that nothing was actually translated."""
    text = re.sub(r"```.*?```", "", read(RU), flags=re.S)
    sections = re.split(r"^#{1,6} .*$", text, flags=re.M)[1:]
    thin = [i for i, part in enumerate(sections, 1)
            if len(re.findall(r"[а-яёА-ЯЁ]", part)) < 80]
    if thin:
        sys.exit(f"разделы без русской прозы (нужно >= 80 кириллических знаков): {thin}")


def check_code():
    en, ru = fences(read(EN)), fences(read(RU))
    if len(en) != len(ru):
        sys.exit(f"разное число блоков кода: EN={len(en)} RU={len(ru)}")
    for i, (a, b) in enumerate(zip(en, ru), 1):
        if a != b:
            sys.exit(f"блок кода #{i} изменён; команды не переводятся")


def check_urls():
    pattern = r"https?://[^\s)\"'>]+"
    en = set(re.findall(pattern, read(EN)))
    ru = set(re.findall(pattern, read(RU)))
    if en - ru:
        sys.exit(f"ссылки потеряны в переводе: {sorted(en - ru)}")
    if ru - en:
        sys.exit(f"в переводе появились чужие ссылки: {sorted(ru - en)}")


def check_paths():
    text = read(RU)
    named = sorted(set(PATH_TOKEN.findall(read(EN))))
    missing = [p for p in named if p not in text]
    if missing:
        sys.exit(f"в переводе не названы файлы из оригинала: {missing}")


def check_pins():
    lock = json.loads((ROOT / "upstream.lock").read_text(encoding="utf-8"))
    text = read(RU)
    missing = [lock[k] for k in ("traefik_version", "lego_version", "go_version")
               if lock[k] not in text]
    if missing:
        sys.exit(f"в переводе нет версий из upstream.lock: {missing}")


def check_access():
    """The НУЦ gap is one of access, not of diligence — the Russian text has to
    say so as plainly as the English one."""
    text = read(RU).lower()
    for word, why in (("доступ", "не сказано, что дело в доступе"),
                      ("аккредитац", "не названа причина — аккредитация")):
        if word not in text:
            sys.exit(why)


def check_links():
    if "README.ru.md" not in read(EN):
        sys.exit("из английского README нет ссылки на русский")
    if "README.md" not in read(RU):
        sys.exit("из русского README нет ссылки на английский")


CHECKS = {
    "headings": check_headings,
    "cyrillic": check_cyrillic,
    "code": check_code,
    "urls": check_urls,
    "paths": check_paths,
    "pins": check_pins,
    "access": check_access,
    "links": check_links,
}


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "all":
        failed = []
        for name, check in CHECKS.items():
            try:
                check()
                print(f"ok   {name}")
            except SystemExit as exc:
                failed.append(name)
                print(f"FAIL {name}: {exc}", file=sys.stderr)
        return 1 if failed else 0
    if len(sys.argv) != 2 or sys.argv[1] not in CHECKS:
        print(f"usage: {sys.argv[0]} <{'|'.join(CHECKS)}|all>", file=sys.stderr)
        return 2
    CHECKS[sys.argv[1]]()
    print(f"ok   {sys.argv[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
