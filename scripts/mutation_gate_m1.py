#!/usr/bin/env python3
"""Kill M1, M1a, and M3 regressions offline and restore the exact upstream bytes.

Each mutation runs only its named Go test, first unchanged and then mutated.
A compiler error, unrelated assertion, absent test, or timeout is not a kill.
"""

from dataclasses import dataclass
import fcntl
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
PATCH = ROOT / "patches/0001-csr-subject.patch"
LOCK = ROOT / ".upstream/.mutation-gate.lock"


@dataclass(frozen=True)
class Mutation:
    name: str
    before: str
    after: str
    test: str
    assertion: str
    source: Path = SOURCE
    tests: Path = TESTS
    package: str = PACKAGE


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
    Mutation(
        "Guard checks only the first resolver",
        "for _, name := range names {",
        "for _, name := range names[:1] {",
        "TestCSRGuardChecksAllResolvers",
        't.Fatalf("second resolver was not rejected: %v", err)',
        UPSTREAM / "cmd/validatecsr/validatecsr.go",
        UPSTREAM / "cmd/validatecsr/validatecsr_test.go",
        "github.com/traefik/traefik/v3/cmd/validatecsr",
    ),
    Mutation(
        "Guard always exits zero",
        "os.Exit(1)",
        "os.Exit(0)",
        "TestCSRGuardExitStatus",
        't.Fatalf("invalid subject exit code = %d, want 1; stdout=%q stderr=%q", rc, stdout, stderr)',
        UPSTREAM / "cmd/validatecsr/validatecsr.go",
        UPSTREAM / "cmd/validatecsr/validatecsr_test.go",
        "github.com/traefik/traefik/v3/cmd/validatecsr",
    ),
    Mutation(
        "Guard stops at a resolver without ACME",
        "\t\t\tcontinue\n",
        "\t\t\treturn nil\n",
        "TestCSRGuardKeepsWalkingPastNonACMEResolver",
        't.Fatalf("resolver after a non-ACME one was not checked: %v", err)',
        UPSTREAM / "cmd/validatecsr/validatecsr.go",
        UPSTREAM / "cmd/validatecsr/validatecsr_test.go",
        "github.com/traefik/traefik/v3/cmd/validatecsr",
    ),
    Mutation(
        "Guard walks resolvers in map order",
        "\tnames := slices.Sorted(maps.Keys(cfg.CertificatesResolvers))\n",
        "\tnames := slices.Sorted(maps.Keys(cfg.CertificatesResolvers))\n\tslices.Reverse(names)\n",
        "TestCSRGuardNamesFirstResolverInSortedOrder",
        't.Fatalf("guard did not report the first resolver in sorted order: %v", err)',
        UPSTREAM / "cmd/validatecsr/validatecsr.go",
        UPSTREAM / "cmd/validatecsr/validatecsr_test.go",
        "github.com/traefik/traefik/v3/cmd/validatecsr",
    ),
    Mutation(
        "Guard validates only subjects with a country",
        "if err := resolver.ACME.CSRSubject.Validate(); err != nil {",
        "if err := resolver.ACME.CSRSubject.Validate(); err != nil && resolver.ACME.CSRSubject.Country != \"\" {",
        "TestCSRGuardValidatesSubjectWithoutCountry",
        't.Fatalf("subject without a country was not validated: %v", err)',
        UPSTREAM / "cmd/validatecsr/validatecsr.go",
        UPSTREAM / "cmd/validatecsr/validatecsr_test.go",
        "github.com/traefik/traefik/v3/cmd/validatecsr",
    ),
    Mutation(
        "Guard drops a loader from the chain",
        "Resources:     loaders,",
        "Resources:     loaders[1:],",
        "TestCSRGuardUsesGivenLoadersUnchanged",
        't.Fatalf("loader chain resized: got %d, want %d", len(got), len(loaders))',
        UPSTREAM / "cmd/validatecsr/validatecsr.go",
        UPSTREAM / "cmd/validatecsr/validatecsr_test.go",
        "github.com/traefik/traefik/v3/cmd/validatecsr",
    ),
    Mutation(
        "Guard error omits resolver name",
        'fmt.Errorf("invalid CSR subject in resolver %q: %w", name, err)',
        'fmt.Errorf("invalid CSR subject: %w", err)',
        "TestCSRGuardInvalidCountry",
        't.Fatalf("invalid country error missing resolver or validation reason: %v", err)',
        UPSTREAM / "cmd/validatecsr/validatecsr.go",
        UPSTREAM / "cmd/validatecsr/validatecsr_test.go",
        "github.com/traefik/traefik/v3/cmd/validatecsr",
    ),
    Mutation(
        "Subject ignored on the obtain path",
        "	if p.CSRSubject.IsEmpty() {\n		request := certificate.ObtainRequest{",
        "	if true {\n		request := certificate.ObtainRequest{",
        "TestObtainNonEmptySubjectUsesCSR",
        't.Fatal("nonempty subject used Obtain instead of ObtainForCSR")',
    ),
    Mutation(
        "CSR path taken for an empty subject",
        "	if p.CSRSubject.IsEmpty() {\n		request := certificate.ObtainRequest{",
        "	if false {\n		request := certificate.ObtainRequest{",
        "TestObtainEmptySubjectUsesStock",
        't.Fatal("empty subject used ObtainForCSR instead of Obtain")',
    ),
    Mutation(
        "Renewal domains taken from the store",
        "p.csrRequest(certcrypto.ExtractDomains(certificates[0]), key)",
        "p.csrRequest(res.Domains, key); _ = certificates",
        "TestCSRRenewalDomainsFromCertificateWhenStoreEmpty",
        't.Fatalf("renewal CSR DNS names = %v, want %v", got, dnsNames)',
    ),
    Mutation(
        "Obtain request loses the domains",
        "			Domains:          domains,\n			Bundle:           true,",
        "			Domains:          nil,\n			Bundle:           true,",
        "TestObtainEmptySubjectUsesStock",
        't.Fatalf("ObtainRequest domains = %v, want %v", client.obtain.Domains, domains)',
    ),
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run_test(mutation):
    result = subprocess.run(
        [str(ROOT / "scripts/upstream-go.sh"), "test", "-count=1", "-json",
         "-run", f"^{mutation.test}$", "./" + str(mutation.source.parent.relative_to(UPSTREAM))],
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


def test_action(events, mutation, action):
    return any(event.get("Package") == mutation.package and event.get("Test") == mutation.test
               and event.get("Action") == action for event in events)


def first_assertion(events):
    for event in events:
        if event.get("Action") != "output":
            continue
        for line in event.get("Output", "").splitlines():
            match = re.search(r"\b(\w+_test\.go):(\d+):\s*(.*)", line)
            if match:
                return event, match[1], int(match[2]), line.strip()
    return None, None, None, "нет упавшей строки ассерта"


def take_lock():
    """Two gates at once cement a mutation: the second snapshots a mutated file
    as its "original" and restores the tree to it. Refuse instead of racing."""
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    handle = LOCK.open("w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit("another mutation gate is already running in this clone")
    return handle


def check_baseline():
    """The snapshot is only trustworthy if the tree still matches the patch."""
    # "git diff" alone compares the worktree with the INDEX, so a staged change
    # to a file outside the patch is invisible to it. Compare against HEAD.
    diff = subprocess.run(["git", "-C", str(UPSTREAM), "diff", "HEAD"],
                          stdout=subprocess.PIPE, text=True, timeout=120).stdout
    if diff != PATCH.read_text():
        sys.exit(f"upstream tree does not match {PATCH.relative_to(ROOT)}; "
                 "restore it before running the gate")


def main():
    lock = take_lock()
    check_baseline()
    paths = {path for mutation in MUTATIONS for path in (mutation.source, mutation.tests)}
    originals = {path: path.read_bytes() for path in paths}
    hashes = {path: digest(data) for path, data in originals.items()}
    killed = 0
    for path in sorted(paths):
        print(f"Original {path.relative_to(UPSTREAM)} sha256: {hashes[path]}", flush=True)

    for mutation in MUTATIONS:
        original = originals[mutation.source]
        test_lines = originals[mutation.tests].decode().splitlines()
        first_line = "нет упавшей строки ассерта"
        did_kill = False
        detail = ""
        try:
            if any(path.read_bytes() != data for path, data in originals.items()):
                raise RuntimeError("upstream files differ from the clean gate baseline")
            baseline, events = run_test(mutation)
            if baseline.returncode != 0 or not test_action(events, mutation, "pass"):
                raise RuntimeError(f"clean target test is not green (rc={baseline.returncode}):\n{baseline.stdout}")

            before = mutation.before.encode()
            count = original.count(before)
            if count != 1:
                raise RuntimeError(f"replacement must match exactly once, got {count}")
            assertion_lines = [i for i, line in enumerate(test_lines, 1)
                               if line.strip() == mutation.assertion]
            if len(assertion_lines) != 1:
                raise RuntimeError("expected assertion must match exactly once")

            mutation.source.write_bytes(original.replace(before, mutation.after.encode(), 1))
            mutated, events = run_test(mutation)
            event, filename, line_number, first_line = first_assertion(events)
            did_kill = (
                mutated.returncode == 1
                and test_action(events, mutation, "fail")
                and event is not None
                and event.get("Package") == mutation.package
                and event.get("Test") == mutation.test
                and filename == mutation.tests.name
                and line_number == assertion_lines[0]
            )
            if not did_kill:
                detail = f"unexpected result (rc={mutated.returncode}):\n{mutated.stdout}"
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
            detail = str(exc)
        finally:
            changed_tests = any(m.tests.read_bytes() != originals[m.tests] for m in MUTATIONS)
            for path, data in originals.items():
                path.write_bytes(data)
                restored = path.read_bytes()
                if restored != data or digest(restored) != hashes[path]:
                    raise RuntimeError(f"RESTORATION FAILED: {path}")
            if changed_tests:
                raise RuntimeError("test file changed during mutation gate (original bytes restored)")

        killed += int(did_kill)
        print(f"{mutation.name}: {'убит' if did_kill else 'выжил'}; {first_line}", flush=True)
        if detail:
            print(detail, flush=True)

    print(f"Убито {killed}/{len(MUTATIONS)}; исходные байты и sha256 всех {len(paths)} файлов восстановлены", flush=True)
    return 0 if killed == len(MUTATIONS) else 1


if __name__ == "__main__":
    sys.exit(main())
