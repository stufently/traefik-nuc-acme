#!/usr/bin/env bash
# Checks the M4 acceptance criteria could not see, found by cross-review.
# Each check states what corruption it kills, so a future edit that weakens one
# is recognisable as a loss rather than a tidy-up.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

bundle="scripts/nuc-ca-bundle.sh"
preset="presets/nuc.yml"
failures=0

fail() {
    printf 'FAIL %s: %s\n' "$1" "$2" >&2
    failures=$((failures + 1))
}

ok() {
    printf 'ok   %s\n' "$1"
}

# M01: a pin check that compares only a prefix keeps refusing an all-zero pin,
# so the criterion must use a digest that is wrong only in its last character.
check_pin_compares_every_character() {
    local pin flipped out rc dir
    for which in root sub; do
        pin="$(grep -oE "^${which^^}_SHA256=\"[0-9a-f]{64}\"" "$bundle" | grep -oE '[0-9a-f]{64}')"
        [ -n "$pin" ] || { fail "pin-full-$which" "не нашёл пин в $bundle"; return; }
        if [ "${pin: -1}" = "0" ]; then flipped="${pin:0:63}1"; else flipped="${pin:0:63}0"; fi
        dir="$(mktemp -d)"
        out="$("$bundle" "--${which}-sha256" "$flipped" -o "$dir/ca.pem" 2>&1)"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            fail "pin-full-$which" "пин, отличающийся ТОЛЬКО последним символом, принят"
        elif ! printf '%s' "$out" | grep -qiE 'sha256|пин|checksum'; then
            fail "pin-full-$which" "отказ без внятной причины: $out"
        elif [ -e "$dir/ca.pem" ]; then
            fail "pin-full-$which" "при отказе создан файл назначения"
        else
            ok "pin-full-$which"
        fi
        rm -rf "$dir"
    done
}

# M05: a failed update must leave the bundle that is already in place untouched,
# or one bad run destroys a working trust store.
check_failure_keeps_existing_bundle() {
    local dir before after
    dir="$(mktemp -d)"
    printf 'existing bundle\n' > "$dir/ca.pem"
    before="$(sha256sum "$dir/ca.pem" | cut -d' ' -f1)"
    "$bundle" --sub-sha256 0000000000000000000000000000000000000000000000000000000000000000 \
        -o "$dir/ca.pem" >/dev/null 2>&1
    if [ ! -e "$dir/ca.pem" ]; then
        fail "keep-existing" "неудачное обновление УДАЛИЛО рабочий бандл"
    else
        after="$(sha256sum "$dir/ca.pem" | cut -d' ' -f1)"
        [ "$before" = "$after" ] && ok "keep-existing" \
            || fail "keep-existing" "неудачное обновление испортило рабочий бандл"
    fi
    rm -rf "$dir"
}

# M06: downloads must not pile up in TMPDIR — on success and, just as much, on
# the failure path, which runs before the staging trap is installed.
check_tempdir_left_clean() {
    local tmp out
    for path in success failure; do
        tmp="$(mktemp -d)"
        out="$(mktemp -d)"
        if [ "$path" = "success" ]; then
            TMPDIR="$tmp" "$bundle" -o "$out/ca.pem" >/dev/null 2>&1
            if [ ! -s "$out/ca.pem" ]; then
                fail "tmp-clean-$path" "скрипт не собрал бандл, проверка не состоялась"
                rm -rf "$tmp" "$out"; continue
            fi
        else
            TMPDIR="$tmp" "$bundle" --sub-sha256 \
                0000000000000000000000000000000000000000000000000000000000000000 \
                -o "$out/ca.pem" >/dev/null 2>&1
            if [ -e "$out/ca.pem" ]; then
                fail "tmp-clean-$path" "отказ создал файл назначения"
                rm -rf "$tmp" "$out"; continue
            fi
        fi
        if [ -n "$(ls -A "$tmp" 2>/dev/null)" ]; then
            fail "tmp-clean-$path" "в TMPDIR осталось: $(ls -A "$tmp" | tr '\n' ' ')"
        else
            ok "tmp-clean-$path"
        fi
        rm -rf "$tmp" "$out"
    done
}

# M11 and M13: the path the preset reads and the path README tells the user to
# mount must be the same string, or following the documentation yields a
# resolver whose CA file is not there.
check_readme_mount_matches_preset() {
    local in_preset in_readme
    in_preset="$(grep -oE '^ *- /[^ ]*\.pem' "$preset" | head -1 | sed 's/^ *- *//')"
    in_readme="$(grep -oE '[^ ":]+\.pem:ro' README.md | head -1 | sed 's/:ro$//' | awk -F: '{print $NF}')"
    if [ -z "$in_preset" ] || [ -z "$in_readme" ]; then
        fail "mount-match" "не нашёл путь бандла: пресет='$in_preset' README='$in_readme'"
    elif [ "$in_preset" != "$in_readme" ]; then
        fail "mount-match" "README монтирует '$in_readme', пресет читает '$in_preset'"
    else
        ok "mount-match"
    fi
}

# M12: the entryPoint the HTTP challenge names must be declared, or Traefik
# drops the router and the challenge never gets served.
check_challenge_entrypoint_declared() {
    local named
    named="$(awk '/httpChallenge:/{f=1} f&&/entryPoint:/{print $2; exit}' "$preset")"
    if [ -z "$named" ]; then
        fail "challenge-entrypoint" "в пресете нет entryPoint у httpChallenge"
    elif ! awk '/^entryPoints:/{f=1;next} /^[^ ]/{f=0} f' "$preset" | grep -qE "^  ${named}:"; then
        fail "challenge-entrypoint" "httpChallenge ссылается на необъявленный entryPoint '$named'"
    else
        ok "challenge-entrypoint"
    fi
}

# M14: the go wrapper must keep argument boundaries; a path with a space is the
# cheapest way to see an unquoted "$@".
check_wrapper_keeps_argument_boundaries() {
    local dir out
    dir="$(mktemp -d)"
    printf 'certificatesResolvers:\n  t:\n    acme:\n      storage: /tmp/x.json\n      csrSubject:\n        country: RUS\n' \
        > "$dir/config with spaces.yml"
    out="$(scripts/upstream-go.sh run ./cmd/traefik validate-csr-subject --configfile="$dir/config with spaces.yml" 2>&1)"
    if printf '%s' "$out" | grep -q 'invalid CSR subject in resolver'; then
        ok "arg-boundaries"
    else
        fail "arg-boundaries" "путь с пробелом не дошёл до гварда: $(printf '%s' "$out" | tail -1)"
    fi
    rm -rf "$dir"
}

check_pin_compares_every_character
check_failure_keeps_existing_bundle
check_tempdir_left_clean
check_readme_mount_matches_preset
check_challenge_entrypoint_declared
check_wrapper_keeps_argument_boundaries

if [ "$failures" -ne 0 ]; then
    printf '\n%d проверок не прошло\n' "$failures" >&2
    exit 1
fi
printf '\nвсе проверки прошли\n'
