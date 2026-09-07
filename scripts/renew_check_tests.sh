#!/usr/bin/env bash
# Offline contract tests for the real cmd_renew_check loop. No Docker or network.
set -euo pipefail

# Set before source: stand.sh reads these values when defining its helpers.
export STAND_RENEW_ATTEMPTS=3
export STAND_RENEW_TIMEOUT=1
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stand.sh"

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
# Keep the real PEM/CSR parsing; only stand dependencies are replaced below.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$test_dir/key.pem" -out "$test_dir/before.pem" \
    -subj '/CN=renew.test/C=RU' -set_serial 1 -days 1 >/dev/null 2>&1
openssl x509 -in "$test_dir/before.pem" -signkey "$test_dir/key.pem" \
    -set_serial 2 -out "$test_dir/after.pem" >/dev/null 2>&1
openssl req -new -key "$test_dir/key.pem" -subj '/CN=renew.test/C=RU' \
    -out "$test_dir/ru.csr" >/dev/null 2>&1
openssl req -new -key "$test_dir/key.pem" -subj '/CN=renew.test' \
    -out "$test_dir/no-country.csr" >/dev/null 2>&1

compose() {
    if [[ "${1:-}" == up && "${2:-}" == -d && "${3:-}" == --force-recreate ]]; then
        restarts=$((restarts + 1))
    elif [[ "${1:-}" == logs && "${2:-}" == traefik ]]; then
        cat "$root/docker/testdata/$log_fixture"
    fi
    return 0
}

cert_pem_from_store() {
    # Match stdout and absence semantics, including calls inside pipelines.
    [[ "$certificate_available" == true ]] || return 1
    if ((success_on > 0 && restarts >= success_on)); then
        cat "$test_dir/after.pem"
    else
        cat "$test_dir/before.pem"
    fi
}

latest_csr_mtime() {
    # Frozen mtime = the capture directory never gets a fresh CSR.
    if [[ "$csr_frozen" == true ]]; then
        printf '100.000000000\n'
    else
        printf '%d.000000000\n' "$((100 + restarts))"
    fi
}

csr_from_capture() {
    cat "$test_dir/$csr_fixture"
}

traefik_running() {
    [[ "$running" == true ]]
}

expect_equal() {
    local field="$1" expected="$2" actual="$3"
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL %s: %s expected %s, got %s\n' "$case_name" "$field" "$expected" "$actual"
        case_failed=1
    fi
}

expect_output() {
    if ! grep -qF -- "$1" "$test_dir/$case_name.log"; then
        printf 'FAIL %s: expected output containing %s, got:\n' "$case_name" "$1"
        cat "$test_dir/$case_name.log"
        case_failed=1
    fi
}

run_case() (
    # A subshell isolates scenarios, but cmd_renew_check itself must NOT run
    # in command substitution: compose's restart counter would be lost there.
    case_name="$1"
    restarts=0
    success_on=0
    certificate_available=true
    running=true
    csr_fixture=ru.csr
    log_fixture=renew-log-retryable.txt
    csr_frozen=false
    case_failed=0
    case "$case_name" in
        success_first_attempt) success_on=1 ;;
        race_then_success) success_on=2 ;;
        race_exhausted) ;;
        foreign_failure_fails_fast) log_fixture=renew-log-other.txt ;;
        traefik_died) running=false ;;
        csr_without_country) success_on=1; csr_fixture=no-country.csr ;;
        stale_csr_never_fresh) success_on=1; csr_frozen=true ;;
        *) printf 'FAIL %s: unknown case\n' "$case_name"; return 1 ;;
    esac

    rc=0
    cmd_renew_check >"$test_dir/$case_name.log" 2>&1 || rc=$?
    case "$case_name" in
        success_first_attempt)
            expect_equal rc 0 "$rc"
            expect_equal restarts 1 "$restarts"
            expect_output 'renewed serial=01 -> serial=02'
            ;;
        race_then_success)
            expect_equal rc 0 "$rc"
            expect_equal restarts 2 "$restarts"
            expect_output 'renewed serial=01 -> serial=02'
            ;;
        race_exhausted)
            expect_equal rc 1 "$rc"
            expect_equal restarts "$STAND_RENEW_ATTEMPTS" "$restarts"
            expect_output "after $STAND_RENEW_ATTEMPTS attempts"
            ;;
        foreign_failure_fails_fast)
            expect_equal rc 1 "$rc"
            expect_equal restarts 1 "$restarts"
            expect_output 'not a known ACME challenge race'
            ;;
        traefik_died)
            expect_equal rc 1 "$rc"
            expect_equal restarts 1 "$restarts"
            expect_output 'traefik is not running during renew-check'
            ;;
        csr_without_country)
            expect_equal rc 1 "$rc"
            expect_equal restarts 1 "$restarts"
            expect_output 'renewed CSR missing C=RU:'
            ;;
        stale_csr_never_fresh)
            # A new serial without a new CSR is not a renewal: the loop must
            # keep retrying and end exhausted, not report success.
            expect_equal rc 1 "$rc"
            expect_equal restarts "$STAND_RENEW_ATTEMPTS" "$restarts"
            expect_output "after $STAND_RENEW_ATTEMPTS attempts"
            ;;
    esac
    if ((case_failed)); then
        return 1
    fi
    printf 'ok %s\n' "$case_name"
)

cases=(success_first_attempt race_then_success race_exhausted
       foreign_failure_fails_fast traefik_died csr_without_country
       stale_csr_never_fresh)
# The mutation gate can select its assigned case; the default runs all six.
if (($#)); then
    cases=("$@")
fi
failed=0
for case_name in "${cases[@]}"; do
    run_case "$case_name" || failed=1
done
exit "$failed"
