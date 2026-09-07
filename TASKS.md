# Backlog

## Milestone 2 — DONE 2026-09-06 (image + Pebble stand)

Delivered: multi-stage `Dockerfile` (pinned by digest, patch applied from the
local tarball, no Node), `docker/compose.yaml` stand with Pebble and an
`acmeproxy` that captures ACME request bodies, `scripts/stand.sh`,
`scripts/release.sh` (written, never executed — see the owner's item below).
All 11 acceptance criteria re-run green by the gate; the stand was also brought
up by hand.

Proven on the live protocol, not just in unit tests:
`subject=C=RU, L=Moscow, O=NUC Stand, CN=stand.traefik-nuc.test` in the CSR
captured on the wire, and renewal reissues (serial changes) while sending a CSR
that still carries the subject.

Facts that milestone 3 must not rediscover:

- **Pebble does not copy Subject from the CSR into the leaf** — it takes SANs
  and the public key only (`ca/ca.go:466`). Let's Encrypt behaves the same way.
  So `C=RU` is proven on the CSR **we send**, never on the issued leaf; against
  the live НУЦ that criterion tests НУЦ's behaviour, not our code.
- **The stand has TWO CAs.** `roots/0` is the issuing CA (regenerated on every
  start); the TLS of the directory endpoint itself is signed by the static
  `test/certs/pebble.minica.pem`. Trust both — trusting only `roots/0` breaks
  the handshake to the directory and looks like "ACME is broken".
- Pebble builds absolute URLs from `request.Host` and honours
  `X-Forwarded-Proto` (`wfe/wfe.go:631`), which is why a reverse proxy in front
  of it is transparent.
- Challenge validation goes to **5002/5001**, not 80/443.
- `PEBBLE_WFE_NONCEREJECT=0` and `PEBBLE_VA_NOSLEEP=1` are required, otherwise
  Pebble rejects 5% of nonces by design and the stand reddens at random.
- **The image ships without the web dashboard** (owner's decision): `go:embed
  static` is satisfied by the placeholder directory, so no Node in the build.
  `api.dashboard` will not work — say so in README and COMPATIBILITY.md.
- **Do not use UPX.** With `-s -w` the binary is ~180 MB and that is fine:
  registry layers are gzipped anyway (`docker save` = 53.9 MB), while UPX would
  decompress into RAM on every start and lose page sharing between containers.
  Note `docker image inspect .Size` is not a usable measure here — on the
  containerd store it counts uncompressed layers *and* compressed blobs
  (245.9 MB reported against 182.8 MB of real content).

## Milestone 3a — DONE 2026-09-07 (config guard)

Executor `cx-traefik-nuc-m3`, spec `docs/specs/m3-config-guard.md`, 12 criteria.
Adds a `validate-csr-subject` subcommand INSIDE the patch that loads the static
configuration with Traefik's own loaders (`pkg/cli`), plus an image entrypoint
that runs it before starting the server. Stock resolver behaviour is untouched.

Why a subcommand and not a separate binary: Traefik resolves its config through
a chain (`/etc/traefik/traefik`, `$XDG_CONFIG_HOME/traefik`,
`$HOME/.config/traefik`, `./traefik`, plus the `traefik.configfile` flag), and a
reimplementation would diverge silently. A guard reading a different file is
worse than no guard — the absence of a check is visible, a check answering a
different question is not.

Accepted by hand 2026-09-07: all 12 criteria re-run independently (11 by
`accept_run.py`; AC-010 refused there because the reported command had a
trailing `printf` swallowing its exit code — the spec's own wording passes,
run separately). Boundaries hold: 7 added lines in `cmd/traefik/traefik.go`,
no new patch files. Live stand walked by hand — `csrSubject OK` is the first
line of the container log (the entrypoint really does gate the start), the
captured CSR carries `C=RU, L=Moscow, O=NUC Stand`, and renewal keeps it
(serial 7D88D71121ECD0A8 → 7D6B2766B4FD2575).

One test hole found and closed by me before the cross-review: the mutation
`continue` → `return nil` in the resolver walk SURVIVED. A resolver without an
`acme` section sorted before an invalid one (say a `tailscale` resolver named
`a-…`) would have made the guard return OK and Traefik start with a broken
subject — fail-open, the exact failure the milestone exists to prevent. The
product was already correct; the tests never covered it. Added
`TestCSRGuardKeepsWalkingPastNonACMEResolver` and a 14th gate mutation; gate is
14/14 with every mutation failing on its own assert line.

Cross-mutation review by Grok (opposite executor) accepted 5/5: 13 of its own
mutations, 8 survived. Its findings and my verification of each are kept in
`docs/reviews/m3-cross-review.md` — including one claim that was wrong (AC-010
does kill both entrypoint mutations, with distinct exit codes proving the
reason). Four holes closed with new tests; the gate now runs 17 mutations, all
killed on their own assert lines. One known gap left open deliberately: nothing
tests that the entrypoint keeps excluding `healthcheck` from the guard. Left
open because the regression costs one extra validation pass before probing a
live daemon that already has a valid subject — not a fail-open, and cheaper than
the shell-test machinery it would take to cover. This is a priced gap, not debt;
do not spend a milestone on it.

Merged to `main` and pushed. The executor's `report.json` was dropped from the
repository and gitignored: it describes one run, not the product, and M1/M2 had
never carried one.

## Milestone 4 — DONE 2026-09-07 (НУЦ preset and CA bundle)

Executor `gk-traefik-nuc-m4`, spec `docs/specs/m4-nuc-preset.md`, 12 criteria.
Research verified live, not read from docs: the ACME directory really is
`https://nuc-acme.voskhod.ru/acme/api/v1/directory` (RFC 8555, `meta: null`,
so no EAB — safe for lego v5.4.1, where `Meta` is a value, not a pointer).

**CA bundle question answered.** The server does NOT send its intermediate, so
the root alone is not enough. The widely linked sub CA on gu-st.ru (serial
1002, 2022) is NOT the issuer of the current leaf — its SKI does not match the
leaf's AKI. The real issuer comes from the leaf's own AIA:
`http://nuc-cdp.voskhod.ru/cdp/subca_ssl_rsa2024.crt`, and it is served as PEM
despite the `.crt` name. Root + that intermediate verify the live TLS
(`ssl_verify_result=0`).

**DECIDED (coordinator, not the owner): do NOT bake the bundle into the image.**
The intermediate already rotated once (2022 → 2024); a baked bundle would go
stale silently and surface as a handshake failure with no hint at the cause.
A pinned fetch script plus a documented mount instead. Reversible: baking it in
later is cheaper than digging it out.

Still an assumption, marked as such in the spec and to be marked in the docs:
that НУЦ requires `RSA2048` and rejects EC keys. Only accreditation could
settle it, and issuing against the live CA stays a separate step "after access".

Implementation accepted by hand: 12/12 re-run independently, the bundle built by
the executor's own script verified by me down to a live handshake
(`ssl_verify_result=0`, chain OK against the leaf), and the image accepted the
preset with the bundle mounted. Nothing was sent to the live CA: registering an
ACME account there is outward-facing and would create state at a state CA under
a placeholder email, and the `caCertificates` mechanism is already proven by the
Pebble stand from milestone 2.

Two of my own defects found and fixed after the run:

- **A hole in my own criterion.** The sixth criterion exercised only the ROOT
  pin, so a script that never checked the intermediate's pin passed all twelve —
  proven by mutation. That pin matters more, not less: the intermediate is
  fetched over plain HTTP, so it is the only integrity control. The criterion
  now exercises both pins and kills that mutation.
- **I corrupted a clone myself** by running two mutation gates at once: the
  second snapshots an already-mutated file as its "original" and cements it in
  `finally`. The gate now takes an exclusive lock and refuses to start when the
  upstream tree does not match the committed patch. Both refusals are proven.

Cross-mutation review handed to Codex (opposite executor) in pane
`cx-traefik-nuc-m4-cross`, clone `/home/deploy/exec-clones/traefik-nuc-m4-cross`,
branch `m4-cross-review`, spec `docs/specs/m4-cross-review.md` (5 criteria).
Because the deliverables are shell and YAML with no unit tests, the twelve
acceptance criteria play the role of the test suite, and the review hunted
corruptions that all twelve miss.

The review's first pass stopped on a defect in my own task: I told it to run all
twelve criteria per corruption, but the twelfth checks the tree is clean, so any
temporary edit "killed" every mutation and measured nothing. Fixed by splitting
behavioural criteria (per corruption) from hygiene ones (once before and once
after the campaign). The second pass ran 17 corruptions over 153 command runs;
8 survived, all of them holes in my criteria rather than defects in the work.
Seven are now closed by `scripts/nuc_preset_checks.sh`, each proven by killing
its corruption; the review and its machine-readable evidence are kept in
`docs/reviews/`.

Known gap left open deliberately: nothing catches a non-atomic write to the
destination bundle. Catching it needs a failure injected mid-write; the
regression costs a corrupted bundle that a re-run repairs, and the script
already stages and renames. Priced gap, not debt.

Both milestone reviewers were called on the diff. Codex found two real defects
in tooling I had written myself and verified as fine: concurrent `run`
invocations shared one binary path, and the gate's new baseline check compared
against `git diff`, which hides a staged change to a file outside the patch.
Both fixed and probed. agy returned "accepted, no findings" three times with a
mutation-gate transcript whose assertion texts do not exist anywhere in this
repository — composed from the wording of the milestone 1 spec, not produced by
a run. Its clone was untouched; the review carries no evidentiary weight.

Merged to `main` and pushed.

## Milestone 5 — documentation (was part of milestone 3)

- [x] **DONE in milestone 4:** НУЦ configuration preset and its CA bundle.
- **ANSWERED BY THE OWNER 2026-09-07 (relayed by the coordinator): "по нуц
      доступов нет".** There is no access to the production НУЦ, so the live
      issuance criterion is removed from the project, acceptance runs against
      the Pebble stand, and the docs say the production CA is UNREACHABLE —
      verification deferred until accreditation. Word it as a gap in ACCESS,
      never as an assumption or an oversight: a later session must see that
      nobody skipped a check, the check was not available to run.
      **Acceptance runs against the Pebble stand, not against the live НУЦ.**
      "Works against production НУЦ" is removed as a criterion: it depends on
      accreditation nobody has confirmed, not on code quality. Ship the preset
      and state plainly in the docs that the live CA is UNVERIFIED. Note also
      that no mock CA can prove `C=RU` in the issued leaf — Pebble and Let's
      Encrypt both drop the CSR subject — so against the live НУЦ that check
      would be testing НУЦ's behaviour, not ours.
- [ ] **CA bundle.** `nuc-acme.voskhod.ru` presents a certificate signed by a
      Russian state root CA that is not in any standard trust store — plain
      `curl` fails the TLS handshake before ACME even starts. Decide: ship the
      root in the image, or document mounting it. Find the official source of
      the root certificate first.
- [ ] `COMPATIBILITY.md`, README in EN + RU, FAQ blocks written to be quotable
      by LLMs, GitHub topics.
- [ ] GitHub Pages — only if the site can be built locally in Docker and pushed
      to a `gh-pages` branch without a workflow. Verify that before starting.

## Open questions for the owner

- [ ] **GHCR push and where the PAT lives.** STILL OPEN 2026-09-07: the owner
      answered the НУЦ question and did not answer this one. Silence is not a
      cancellation, so the stated default stands — the image is built locally
      and pushed nowhere. `scripts/release.sh` supports `--dry-run`; the push
      itself was deliberately never given to an executor and has never run.
      Publishing outward under the owner's account with a `write:packages`
      token is the owner's call: say where the token is kept and the push
      becomes a separate step.
- [x] **DECIDED 2026-09-07 (coordinator, not the owner): validate `csrSubject`
      BEFORE Traefik, do not touch Traefik's behaviour.** The hazard is real —
      an invalid subject does not stop Traefik: it logs `ERR The ACME resolve is
      skipped from the resolvers list` and keeps running, so the user gets NO
      certificates and only a log line says why (verified: the process never
      exits, `rc=124` on a timeout). Stock Traefik treats every resolver error
      this way, so patching it would fork upstream in a place upstream will not
      change, and every rebase would pay for it. Instead the guard lives on OUR
      side of the boundary: parse and validate `csrSubject` in our own entry
      point and refuse to start LOUDLY on an invalid subject, so a bad config
      never reaches the resolver. Fail-closed — a guard that passes bad input is
      not a guard. Keep a README note in milestone 3 explaining why validation
      sits outside Traefik. Do NOT close this in passing inside another
      milestone: an executor already tried, with a `log.Fatal` patch that would
      have taken the whole proxy down over one resolver (withdrawn — fake hunk
      hashes, error matched by text).

## Blocked until 2026-10-06

- [ ] GitHub Actions: build/release/upstream-watch workflows, immutable
      releases, SBOM, OpenSSF Scorecard badge. All of it needs Actions minutes,
      which the owner has capped until 2026-10-06. **No `.github/workflows/`
      file may exist in this repository before that date** — not even a disabled
      one. OpenSSF Scorecard in particular exists only as a GitHub Action.

## Deferred from the milestone 1 review (Grok cross-run, 2026-09-06)

Found by cross-review, deliberately not fixed in milestone 1. Mutation coverage
itself is sound: 10/10 author mutations and 8/8 cross mutations killed, and the
three stale cross-mutations that stopped applying after M1a were verified by
hand to still be caught by the tests.

- [ ] `resolveCertificate` / `resolveDefaultCertificate` have no test coverage:
      breaking the `CSRSubject.IsEmpty()` branch directly in `provider.go` would
      go unnoticed. This is a hole in the TESTS, not in the code; fix by
      extracting the path choice into a pure function, the way renewal already
      does it.
- [ ] Renewal takes names from `Resource.Domains` (Traefik's own store), while
      stock lego takes them from the certificate's SANs
      (`certcrypto.ExtractDomains`). These diverge only if `acme.json` loses
      `Domain` while the certificate body stays intact: stock would renew, our
      path stops with "cannot build CSR without domains".
- [ ] `GetKeyType` on the CSR issuance path is called with `context.Background()`
      instead of the request context — no effect on the key type, only on logger
      context.
- [ ] RDN ordering in `pkix.Name` is fixed by Go (C, O, OU, L, CN). If НУЦ
      compares the canonical DN byte for byte, this could diverge from a
      hand-built CSR. GUESS — never tested against the live CA.
