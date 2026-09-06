# Backlog

## Milestone 2 — Docker image and integration stand

- [ ] Multi-stage `Dockerfile`: download pinned Traefik source, apply the
      patchset, run `go test`, build the binary. No network access at runtime.
- [ ] `docker/compose.yaml` integration stand: patched Traefik + Pebble (the
      Let's Encrypt mock ACME server) + a test domain. Prove end-to-end that
      (a) the issued certificate carries the configured Subject, (b) HTTP-01
      completes, (c) renewal rebuilds the CSR correctly.
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
      НУЦ" cannot be an acceptance criterion — milestone 3 then ships the preset
      and the documentation, unverified against the live CA.
- [ ] Search demand for "traefik нуц" / "traefik nuc acme" was never measured.
      The whole SEO/GEO premise rests on one Habr thread with 185 views. Worth a
      Wordstat check before investing in milestone 3.

## Blocked until 2026-10-06

- [ ] GitHub Actions: build/release/upstream-watch workflows, immutable
      releases, SBOM, OpenSSF Scorecard badge. All of it needs Actions minutes,
      which the owner has capped until 2026-10-06. **No `.github/workflows/`
      file may exist in this repository before that date** — not even a disabled
      one. OpenSSF Scorecard in particular exists only as a GitHub Action.
