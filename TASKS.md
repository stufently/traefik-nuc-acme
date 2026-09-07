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

## Milestone 6 — DONE 2026-09-07 (issuance path coverage, renewal names)

Executor `gk-traefik-nuc-m6`, spec `docs/specs/m6-provider-path-coverage.md`,
10 criteria. Closes three of the four items deferred from the M1 cross-review:
the duplicated `CSRSubject.IsEmpty()` block left `provider.go` for
`obtainCertificate` behind a `certificateObtainer` interface, renewal now takes
names from the certificate body (`ParsePEMBundle` + `ExtractDomains`) exactly as
stock lego does, and the request context reaches `GetKeyType`.

Accepted by hand: nine criteria re-run green independently, the mutation gate
re-run by the coordinator, tests and `go vet` re-run, and the patch verified
byte-for-byte against the tree.

**A defect of the SPEC, not of the work: AC-009 is non-deterministic.** Five runs
of the live stand gave three failures and two passes. Cause: traefik renews once
at startup and re-checks only every 168h, so when the ACME challenge loses the
race with router setup (`403 unauthorized … returned 404` on
`/.well-known/acme-challenge/`), the next attempt falls outside the 180s window
and `renew-check` times out. The only file that could fix it, `scripts/stand.sh`,
is in the spec's own "do not touch" list — so the executor was right not to touch
it. The criterion's INTENT was verified by hand: renewal happened, the serial
changed (`0E6002FA…` → `0F5FFC33…`), subject `C=RU, L=Moscow, O=NUC Stand`.

The cross-mutation run by Codex (opposite executor) returned "do not accept" and
was right on two counts, both verified by hand in the clone before acting: with
the dispatch narrowed to `Country` alone the whole package stayed green (a
subject carrying only `organization` would have silently taken the stock path),
and `ExtractDomains` swapped for `DNSNames` also stayed green (renewal would have
dropped IP SANs and a CN absent from the SANs). One fix round closed both plus
error propagation and context threading; the gate went 21 → 27, every mutation
failing on its own assert line.

Open follow-ups:

- [x] **DONE in milestone 7:** de-flake `scripts/stand.sh renew-check`.
- [ ] Not reachable by unit tests, closed structurally by AC-007 instead: a
      mutation that bypasses `p.obtainCertificate` inside `provider.go` survives,
      because calling `resolveCertificate` needs a live ACME client. Revisit only
      if the resolver itself becomes testable.

## Milestone 5 — documentation (was part of milestone 3)

- [x] **DONE in milestone 4:** НУЦ configuration preset and its CA bundle.
- **ANSWERED BY THE OWNER 2026-09-07 (relayed by the coordinator): "по нуц
      доступов нет".** There is no access to the production НУЦ, so the live
      issuance criterion is removed from the project, acceptance runs against
      the Pebble stand, and the docs say the production CA is UNREACHABLE —
      verification deferred until accreditation. Word it as a gap in ACCESS,
      never as an assumption or an oversight: a later session must see that
      nobody skipped a check, the check was not available to run.
      Note also that no mock CA can prove `C=RU` in the issued leaf — Pebble and
      Let's Encrypt both drop the CSR subject — so even against the live НУЦ
      that check would be testing НУЦ's behaviour, not ours.
- [x] **DONE in milestone 4: CA bundle.** The root is fetched from gu-st.ru and
      the issuing intermediate from the leaf's own AIA, both pinned by sha256,
      and mounted rather than baked into the image.
- [x] **DONE 2026-09-07: `COMPATIBILITY.md`.** Measured, not asserted: the patch
      applies to Traefik v3.7.13 and to none of the other fourteen releases
      tested. Before v3.7.13 the renewal hunk has no `EnableCommonName` in
      `RenewOptions` to anchor on; before v3.7.6 Traefik carries no lego v5 at
      all. No v3.8 tags exist upstream. Research was commissioned from
      `ask-codex research`, and its central claim re-checked by hand.
- [x] **DONE 2026-09-07: README in RU (`README.ru.md`).** Executor
      `cx-traefik-nuc-m5`, spec `docs/specs/m5-readme-ru.md`, 12 criteria,
      checks in `scripts/readme_parity.py`. The anti-fake criterion was the
      point of the milestone: a copy of the English file passes headings, code
      blocks, URLs and pins, and is caught only by the per-section Cyrillic
      check — probed, the copy fails 14 sections of 15. All twelve criteria
      re-run independently on the merged tree, all eight parity checks green.
      Boundaries held: `README.md` gained two lines (the link and its blank
      line), `CHANGELOG.md` three, and no file under `patches/`, `scripts/`,
      `presets/` or `docker/` was touched.
      Cross-review was a MEANING check, not a mutation campaign: mutating a
      translation measures nothing, but a second reader comparing what the two
      files actually claim measures exactly the risk. Grok compared twelve
      second-level sections plus the intro and both `###` subsections and found
      **zero semantic divergences**; its technical claims were spot-checked by
      me against the code rather than taken on trust. The access paragraph
      survives the translation intact — no verification because there is no
      access, no access because accreditation is required, a gap in access and
      not in diligence. One fix was mine and predates the review: a Russian
      paragraph the English README keeps for Russian-speaking readers was
      duplicating text already translated above it, and was removed.
      Kept in `docs/reviews/m5-cross-review.md` with the acceptance notes.
- [ ] FAQ blocks and GitHub topics. **Recommended to drop** (coordinator, not
      the owner): Wordstat shows no RU search demand for this subject, so the
      SEO premise these items rest on is not there. Left for the owner to
      confirm rather than removed.
- [ ] GitHub Pages — **feasibility checked 2026-09-07, work not started; the
      owner decides whether it is wanted.** Publishing from a branch needs no
      workflow FILE in the repository, so the standing "no `.github/workflows/`"
      rule survives, but GitHub still runs its own managed
      `pages-build-deployment` on every push to the published branch: the
      Actions tab stops being empty (`total_count` is 0 today). The repository
      is public, where a run billed zero minutes when that was measured on
      2026-09-06 — the "no CI" rule was nevertheless kept for public
      repositories too, deliberately. Beyond the rule this is outward-facing
      publishing under the owner's account, which is the owner's call, not the
      coordinator's. Recommendation: skip it. The README is the documentation,
      and a site would duplicate it in a second place that can drift.

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

## Milestone 7 — DONE 2026-09-07 (deterministic renew-check)

Executor `gk-traefik-stand-deflake`, spec `docs/specs/m7-stand-renew-deflake.md`,
7 criteria. `renew-check` now retries the whole recreate cycle, but ONLY when the
traefik log carries the known HTTP-01 race signature — `unauthorized`,
`/.well-known/acme-challenge/` and `404` on ONE line — and fails immediately on
any other error, so the fix cannot mask a real regression. Attempts are capped by
`STAND_RENEW_ATTEMPTS` (default 3), and the classifier is exposed as its own
subcommand `classify-renew-log <file>` so it can be tested without the stand.

Accepted by hand: seven criteria re-run, the live stand walked twice end to end
(5/5 renewals both times, serials change, subject `C=RU`), and four mutations of
the classifier replayed by me — each killed by its own near-miss fixture,
including the "all three tokens but on different lines" case.

**A defect of MY criterion, caught by timing that looked wrong.** AC-003 as first
written could not fail: the trailing `scripts/stand.sh down` swallowed the exit
code of the whole chain. Proven with `STAND_WAIT_TIMEOUT=1` — zero renewals ran
and the criterion still returned 0. The sound form keeps the result in a variable
and ends with `exit $rc`; verified red on a failing `wait` and green on five real
renewals. Any future criterion that ends in a cleanup step has this bug.

Backlog from the Codex cross-mutation run (out of this milestone's one fix round,
kept as the next milestone's material — three of them need a test harness the
repository has deliberately never built):

- [ ] The retry LOOP itself is untested: mutants that `return 0` after attempts
      are exhausted, that retry unconditionally without asking the classifier, or
      that turn `continue` into `return 1`, all survive every criterion. Killing
      them needs a harness that fakes `compose` and `cert_pem_from_store`, not
      another fixture.
- [ ] Three more classifier fixtures would pin what the current set does not:
      the full URN replaced by the bare word `unauthorized` (verified by hand —
      it survives), a two-plus-one line split where `unauthorized` and the
      challenge share a line and a stray `404` follows later, and a positive log
      where a near-miss line precedes the real race line.

## Deferred from the milestone 1 review (Grok cross-run, 2026-09-06)

Found by cross-review, deliberately not fixed in milestone 1. Mutation coverage
itself is sound: 10/10 author mutations and 8/8 cross mutations killed, and the
three stale cross-mutations that stopped applying after M1a were verified by
hand to still be caught by the tests.

Three of the four items are closed by milestone M6 (`0e5a650`): the path choice
now lives in `obtainCertificate` and is covered by tests, renewal takes names
from the certificate body via `certcrypto.ExtractDomains`, and the request
context reaches `GetKeyType`. The mutation gate went 17 → 27.

- [ ] RDN ordering in `pkix.Name` is fixed by Go (C, O, OU, L, CN). If НУЦ
      compares the canonical DN byte for byte, this could diverge from a
      hand-built CSR. GUESS — never tested against the live CA.
