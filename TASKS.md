# Backlog

## Milestone 2 — Docker image and integration stand

- [ ] Multi-stage `Dockerfile`: download pinned Traefik source, apply the
      patchset, run `go test`, build the binary. No network access at runtime.
- [ ] `docker/compose.yaml` integration stand: patched Traefik + Pebble (the
      Let's Encrypt mock ACME server) + a test domain. Prove end-to-end that
      (a) the issued certificate carries the configured Subject, (b) HTTP-01
      completes, (c) renewal rebuilds the CSR correctly.
      **Pin Pebble by digest, not by version.** `ghcr.io/letsencrypt/pebble`
      publishes no version tags at all — only `latest` and `sha-<commit>`
      (checked 2026-09-06 against the GHCR tag catalogue, 31 tags). A
      `:v2.10.1` pin fails with `manifest unknown`. Current digest
      `sha256:ddf230642b1a584f519f32e347de1b05a6e4c1f6c35c1863b33effeab5f78199`,
      platforms linux/amd64 + linux/arm64. Verify before writing the spec:
      Pebble mints its own root CA and serves it at `:15000/roots/0`, and
      Traefik needs that root trusted — otherwise TLS to the mock ACME server
      fails exactly the way `curl` to the live НУЦ endpoint fails today.
- [ ] Local release script: build `linux/amd64` + `linux/arm64`, tag as
      `<traefik-version>-nuc.<revision>` (never a bare `3.7.13`, so the image is
      not mistaken for official Traefik), push to GHCR with a host-side PAT.

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
