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

## Milestone 3 — НУЦ preset and SEO/GEO documentation

- [ ] НУЦ configuration preset: `caServer`, `keyType=RSA2048`,
      `csrSubject.country=RU`.
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
- [ ] **A typo in `csrSubject` silently disables the resolver.** Traefik does not
      fail on an invalid subject: it logs `ERR The ACME resolve is skipped from
      the resolvers list` and keeps running, so the user gets NO certificates and
      only a log line says why (verified: the process never exits, `rc=124` on a
      timeout). Stock Traefik treats every resolver error this way. Options: a
      warning in the README (milestone 3), or a deliberate behaviour change as
      its own milestone. Do NOT fix this in passing — an executor already tried
      to close it with a `log.Fatal` patch to make a criterion pass, and that
      patch was withdrawn (fake hunk hashes, error matched by text, and it would
      take the whole proxy down over one resolver).


- [ ] Is there verified access to НУЦ (personally or through a controlled legal
      entity) to obtain even one real test certificate? Without accreditation an
      anonymous request cannot be filed at all, so "works against production
      НУЦ" cannot be an acceptance criterion.
      **Asked 2026-09-06. NO ANSWER FROM THE OWNER YET.** The answer that
      appeared in the question UI ("can be obtained, needs time") came from the
      `cl-tg-claude-userbot` session, which stated plainly that it does not know
      the fact and picked the least blocking option. Milestone 3 is therefore
      planned in two parts as a PLANNING decision, not as confirmed access:
      part A (preset, CA bundle, documentation) proceeds regardless; part B
      (live verification against a real НУЦ certificate) waits for the owner to
      confirm access and is NOT queued to an executor until then.
- [x] Search demand measured 2026-09-06 (Yandex Wordstat): `traefik` 1521
      impressions/month, `traefik acme` 18, `traefik сертификат` 32,
      `нуц сертификат` 5139, `нуц acme` 8. The "нуц" volume is people installing
      root certificates into a browser — a different audience; no traefik × нуц
      overlap appears in any row. Conclusion: there is effectively no
      Russian-language search demand for this product, so the SEO premise does
      not hold. RECOMMENDATION (the owner decides): cut milestone 3 to README
      EN/RU + FAQ + `COMPATIBILITY.md`, drop GitHub Pages and the SEO
      scaffolding; the value is the tool itself plus GEO citation on a rare but
      exact query.

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
