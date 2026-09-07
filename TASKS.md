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

## Milestone 3a — IN_PROGRESS since 2026-09-07 (config guard)

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

Cross-mutation review handed to Grok (opposite executor) in pane
`gk-traefik-nuc-m3-cross`, clone `/home/deploy/exec-clones/traefik-nuc-m3-cross`,
branch `m3-cross-review`, spec `docs/specs/m3-cross-review.md` (5 criteria).
Merge waits on its verdict.

## Milestone 3 — НУЦ preset and SEO/GEO documentation

- [ ] НУЦ configuration preset: `caServer`, `keyType=RSA2048`,
      `csrSubject.country=RU`.
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

- [ ] **GHCR push and where the PAT lives.** `scripts/release.sh` is written and
      supports `--dry-run`; the push itself was deliberately NOT given to an
      executor and never ran — publishing outward under the owner's account with
      a `write:packages` token is the owner's call. Say where the token is kept
      and the push can be done as a separate step.
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
