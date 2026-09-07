#!/usr/bin/env python3
"""Kill six offline stand regressions; restore original bytes even on failure.

A kill needs a green baseline and the assigned assertion (or fixture's exact
opposite classification). Syntax errors, timeouts and unrelated failures do not
count. Run only one gate at a time in this clone.
"""

from dataclasses import dataclass
import fcntl
import hashlib
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "scripts/stand.sh"
TESTS = ROOT / "scripts/renew_check_tests.sh"
FIXTURES = ROOT / "docker/testdata"

SIGNATURE = '''        index($0, "urn:ietf:params:acme:error:unauthorized") &&
        index($0, "/.well-known/acme-challenge/") &&
        index($0, "404") { found=1; exit }
        END { exit found ? 0 : 1 }'''


@dataclass(frozen=True)
class Mutation:
    name: str
    before: str
    after: str
    test: str
    assertion: str = ""
    expected_rc: int = 0

    @property
    def fixture(self):
        return self.test.endswith(".txt")


MUTATIONS = (
    Mutation(
        "Exhausted attempts report success",
        '    compose logs traefik acmeproxy >&2 || true\n    return 1\n}\n\ncmd_down()',
        '    compose logs traefik acmeproxy >&2 || true\n    return 0\n}\n\ncmd_down()',
        "race_exhausted",
        "FAIL race_exhausted: rc expected 1, got 0",
    ),
    Mutation(
        "Retry without asking the classifier",
        '        if classify_renew_log "$logfile"; then',
        '        if true; then',
        "foreign_failure_fails_fast",
        "FAIL foreign_failure_fails_fast: restarts expected 1, got 3",
    ),
    Mutation(
        "First lost race is final",
        '                rm -f "$logfile"\n                continue',
        '                rm -f "$logfile"\n                return 1',
        "race_then_success",
        "FAIL race_then_success: rc expected 0, got 1",
    ),
    Mutation(
        "Bare word instead of the full URN",
        'index($0, "urn:ietf:params:acme:error:unauthorized")',
        'index($0, "unauthorized")',
        "renew-log-near-word-unauthorized.txt",
        expected_rc=1,
    ),
    Mutation(
        "Signature may span lines",
        SIGNATURE,
        r'''        { whole = whole $0 "\n" }
        END {
            found = index(whole, "urn:ietf:params:acme:error:unauthorized") &&
                index(whole, "/.well-known/acme-challenge/") && index(whole, "404")
            exit found ? 0 : 1
        }''',
        "renew-log-near-split.txt",
        expected_rc=1,
    ),
    Mutation(
        "First almost-match ends the scan",
        SIGNATURE,
        '''        index($0, "urn:ietf:params:acme:error:unauthorized") ||
        index($0, "/.well-known/acme-challenge/") || index($0, "404") {
            found = index($0, "urn:ietf:params:acme:error:unauthorized") &&
                index($0, "/.well-known/acme-challenge/") && index($0, "404")
            exit
        }
        END { exit found ? 0 : 1 }''',
        "renew-log-race-after-near-miss.txt",
    ),
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(command):
    return subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, timeout=60)


def run_test(mutation):
    if mutation.fixture:
        return run(["bash", str(SOURCE), "classify-renew-log",
                    str(FIXTURES / mutation.test)])
    return run(["bash", str(TESTS), mutation.test])


def baseline_green(mutation, result):
    if mutation.fixture:
        return result.returncode == mutation.expected_rc and not result.stdout
    return result.returncode == 0 and result.stdout.splitlines() == [f"ok {mutation.test}"]


def target_failed(mutation, result):
    if mutation.fixture:
        # In particular, an awk error (rc=1 plus stderr) is not a positive
        # fixture's kill; a missing input cannot qualify as a green baseline.
        return result.returncode == 1 - mutation.expected_rc and not result.stdout
    lines = result.stdout.splitlines()
    failures = [line for line in lines if line.startswith("FAIL ")]
    return (result.returncode == 1 and mutation.assertion in failures
            and all(line.startswith(f"FAIL {mutation.test}: ") for line in failures)
            and f"ok {mutation.test}" not in lines)


def take_lock():
    result = run(["git", "rev-parse", "--git-path", "mutation-gate-stand.lock"])
    if result.returncode != 0:
        raise RuntimeError(result.stdout)
    handle = (ROOT / result.stdout.strip()).open("w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        raise RuntimeError("another stand mutation gate is already running in this clone")
    return handle


def main():
    # Keep the lock alive until restoration and all verification have finished.
    with take_lock():
        paths = {SOURCE, TESTS, *FIXTURES.glob("renew-log-*.txt")}
        for mutation in MUTATIONS:
            if mutation.fixture:
                paths.add(FIXTURES / mutation.test)
        originals = {path: path.read_bytes() for path in paths}
        hashes = {path: digest(data) for path, data in originals.items()}
        original = originals[SOURCE]
        print(f"Original scripts/stand.sh sha256: {hashes[SOURCE]}", flush=True)
        killed = 0

        for mutation in MUTATIONS:
            did_kill = False
            detail = ""
            try:
                if any(path.read_bytes() != data for path, data in originals.items()):
                    raise RuntimeError("files differ from the clean gate baseline")
                before = mutation.before.encode()
                count = original.count(before)
                if count != 1:
                    raise RuntimeError(f"replacement must match exactly once, got {count}")
                baseline = run_test(mutation)
                if not baseline_green(mutation, baseline):
                    raise RuntimeError(f"clean target is not green (rc={baseline.returncode}):\n{baseline.stdout}")

                SOURCE.write_bytes(original.replace(before, mutation.after.encode(), 1))
                syntax = run(["bash", "-n", str(SOURCE)])
                if syntax.returncode != 0:
                    raise RuntimeError(f"invalid mutant syntax:\n{syntax.stdout}")
                mutated = run_test(mutation)
                did_kill = target_failed(mutation, mutated)
                if did_kill:
                    detail = (f"{mutation.test}: expected rc={mutation.expected_rc}, "
                              f"got rc={mutated.returncode}" if mutation.fixture
                              else mutation.assertion)
                else:
                    detail = f"unexpected result (rc={mutated.returncode}):\n{mutated.stdout}"
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
                detail = str(exc)
            finally:
                changed_tests = any(not path.exists() or path.read_bytes() != data
                                    for path, data in originals.items() if path != SOURCE)
                for path, data in originals.items():
                    if not path.exists() or path.read_bytes() != data:
                        path.write_bytes(data)
                    restored = path.read_bytes()
                    if restored != data or digest(restored) != hashes[path]:
                        raise RuntimeError(f"RESTORATION FAILED: {path}")
                if changed_tests:
                    raise RuntimeError("test or fixture changed during gate (original bytes restored)")

            killed += int(did_kill)
            print(f"{mutation.name}: {'убит' if did_kill else 'выжил'}; {detail}", flush=True)

        print(f"Убито {killed}/{len(MUTATIONS)}; исходные байты и sha256 всех "
              f"{len(paths)} файлов восстановлены", flush=True)
        return 0 if killed == len(MUTATIONS) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        sys.exit(str(exc))
