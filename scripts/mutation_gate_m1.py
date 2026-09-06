#!/usr/bin/env python3
"""Kill M1 and M1a regressions offline and restore the exact upstream bytes.

Each mutation runs only its named Go test, first unchanged and then mutated.
A compiler error, unrelated assertion, absent test, or timeout is not a kill.
"""

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = ROOT / ".upstream/traefik"
SOURCE = UPSTREAM / "pkg/provider/acme/csr.go"
TESTS = UPSTREAM / "pkg/provider/acme/csr_test.go"
PACKAGE = "github.com/traefik/traefik/v3/pkg/provider/acme"


@dataclass(frozen=True)
class Mutation:
    name: str
    before: str
    after: str
    test: str
    assertion: str


MUTATIONS = (
    Mutation(
        "Country removed",
        "template.Subject.Country = []string{country}",
        "template.Subject.Country = nil",
        "TestCSRSubjectCountry",
        't.Fatalf("country missing from signed CSR: %v", csr.Subject.Country)',
    ),
    Mutation(
        "Renewal falls back to Renew",
        "return client.ObtainForCSR(ctx, *request)",
        "return client.Renew(ctx, res, opts)",
        "TestCSRRenewalUsesCSR",
        't.Fatal("renewal fell back to Renew instead of ObtainForCSR")',
    ),
    Mutation(
        "PrivateKey omitted",
        "PrivateKey:       key,",
        "PrivateKey:       nil,",
        "TestCSRRequestPrivateKey",
        't.Fatal("obtain CSR request has no private key")',
    ),
    Mutation(
        "Three-letter country accepted",
        "if len(s.Country) != 2 {",
        "if len(s.Country) < 2 {",
        "TestCSRSubjectCountryValidation",
        't.Fatal("three-letter country accepted")',
    ),
    Mutation(
        "Empty subject selects CSR",
        'return s == nil || (s.Country == "" && s.Organization == "" && s.OrganizationalUnit == "" && s.Locality == "")',
        "return s == nil",
        "TestCSRSubjectEmptyUsesStock",
        't.Fatal("empty subject selects CSR path")',
    ),
    Mutation(
        "DNSNames lost",
        "DNSNames:       dnsNames,",
        "DNSNames:       nil,",
        "TestCSRSubjectDNSNames",
        't.Fatalf("DNS names lost from signed CSR: %v", csr.DNSNames)',
    ),
    Mutation(
        "IP address sent as DNS SAN",
        "if ip := net.ParseIP(altname); ip != nil {",
        "if ip := net.ParseIP(altname); ip != nil && false {",
        "TestCSRSubjectIPAddresses",
        't.Fatalf("IP and DNS SANs not separated: IP=%v DNS=%v", csr.IPAddresses, csr.DNSNames)',
    ),
    Mutation(
        "Common name length limit removed",
        "if len(domains[0]) <= 64 && enableCommonName {",
        "if enableCommonName {",
        "TestCSRSubjectCommonNameLength",
        't.Fatalf("65-byte common name was not omitted: %q", csr.Subject.CommonName)',
    ),
    Mutation(
        "64-byte common name incorrectly omitted",
        "if len(domains[0]) <= 64 && enableCommonName {",
        "if len(domains[0]) < 64 && enableCommonName {",
        "TestCSRSubjectCommonNameLength",
        't.Fatalf("64-byte common name omitted: %q", csr.Subject.CommonName)',
    ),
    Mutation(
        "Country normalization bypassed",
        "template.Subject.Country = []string{country}",
        "template.Subject.Country = []string{subject.Country}",
        "TestCSRSubjectCountryUppercase",
        't.Fatalf("country was not uppercased: %v", csr.Subject.Country)',
    ),
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run_test(name):
    result = subprocess.run(
        [str(ROOT / "scripts/upstream-go.sh"), "test", "-count=1", "-json",
         "-run", f"^{name}$", "./pkg/provider/acme"],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=180,
    )
    events = []
    for line in result.stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict):
            events.append(event)
    return result, events


def test_action(events, name, action):
    return any(event.get("Package") == PACKAGE and event.get("Test") == name
               and event.get("Action") == action for event in events)


def first_assertion(events):
    for event in events:
        if event.get("Action") != "output":
            continue
        for line in event.get("Output", "").splitlines():
            match = re.search(r"\b(csr_test\.go):(\d+):\s*(.*)", line)
            if match:
                return event, int(match[2]), line.strip()
    return None, None, "нет упавшей строки ассерта"


def main():
    original = SOURCE.read_bytes()
    original_sha = digest(original)
    test_bytes = TESTS.read_bytes()
    test_sha = digest(test_bytes)
    test_lines = test_bytes.decode().splitlines()
    killed = 0
    print(f"Original csr.go sha256: {original_sha}", flush=True)

    for mutation in MUTATIONS:
        first_line = "нет упавшей строки ассерта"
        did_kill = False
        detail = ""
        try:
            if SOURCE.read_bytes() != original or digest(TESTS.read_bytes()) != test_sha:
                raise RuntimeError("upstream files differ from the clean gate baseline")
            baseline, events = run_test(mutation.test)
            if baseline.returncode != 0 or not test_action(events, mutation.test, "pass"):
                raise RuntimeError(f"clean target test is not green (rc={baseline.returncode}):\n{baseline.stdout}")

            before = mutation.before.encode()
            count = original.count(before)
            if count != 1:
                raise RuntimeError(f"replacement must match exactly once, got {count}")
            assertion_lines = [i for i, line in enumerate(test_lines, 1)
                               if line.strip() == mutation.assertion]
            if len(assertion_lines) != 1:
                raise RuntimeError("expected assertion must match exactly once")

            SOURCE.write_bytes(original.replace(before, mutation.after.encode(), 1))
            mutated, events = run_test(mutation.test)
            event, line_number, first_line = first_assertion(events)
            did_kill = (
                mutated.returncode == 1
                and test_action(events, mutation.test, "fail")
                and event is not None
                and event.get("Package") == PACKAGE
                and event.get("Test") == mutation.test
                and line_number == assertion_lines[0]
            )
            if not did_kill:
                detail = f"unexpected result (rc={mutated.returncode}):\n{mutated.stdout}"
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
            detail = str(exc)
        finally:
            SOURCE.write_bytes(original)
            restored_sha = digest(SOURCE.read_bytes())
            if restored_sha != original_sha:
                raise RuntimeError(f"RESTORATION FAILED: expected {original_sha}, got {restored_sha}")
            if digest(TESTS.read_bytes()) != test_sha:
                raise RuntimeError("test file changed during mutation gate")

        killed += int(did_kill)
        print(f"{mutation.name}: {'убит' if did_kill else 'выжил'}; {first_line}", flush=True)
        if detail:
            print(detail, flush=True)

    print(f"Убито {killed}/{len(MUTATIONS)}; исходный sha256 восстановлен: {original_sha}", flush=True)
    return 0 if killed == len(MUTATIONS) else 1


if __name__ == "__main__":
    sys.exit(main())
