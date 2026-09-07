# Changelog

## 2026-09-07

- Added `validate-csr-subject` with Traefik's shared configuration loaders and
  the existing CSR subject validation rules. Invalid subjects exit with 1 and
  identify the resolver on stderr; valid and empty subjects return `csrSubject OK`.
- Added an image entrypoint that validates before starting the server, preserves
  failure status, and forwards service subcommands directly. Stock resolver
  initialization remains unchanged.
- Added guard tests for multiple resolvers, exit status, output, and configuration
  sources. Expanded the offline mutation gate from ten to fourteen mutations,
  checking each target assertion and restoring source and test bytes and hashes.
  Four of the seventeen came from cross-review holes: the walk must continue
  past a resolver without an ACME section, keep its sorted order so the reported
  resolver is stable, validate subjects that set no country at all, and carry
  the caller's loader chain unchanged in composition and order.

## 2026-09-06

- Added a multi-stage Docker image `traefik-nuc-acme:3.7.13-nuc.1` (no web
  dashboard, stripped with `-s -w`, no UPX) and a Pebble stand that proves
  `csrSubject.country=RU` on the CSR Traefik sends: nginx `acmeproxy`
  captures ACME bodies, `scripts/stand.sh csr-dump` prints the finalize CSR.
  `scripts/release.sh` plans a multi-arch GHCR publish and does not push
  unless `--push` is given.
- Brought the CSR path into stock parity for IP SANs and the 64-byte common-name
  limit, and normalized country codes to uppercase. Added regression tests and
  expanded the offline mutation gate to ten mutations, including both sides of
  the common-name length boundary.
- Added the M1 patch for optional ACME `csrSubject` country, organization,
  organizational unit, and locality fields, with subject validation. Issuance
  sends a signed CSR and its private key; renewal rebuilds the CSR from current
  configuration and the saved key without changing `acme.json`. Empty subjects
  retain the stock lego paths. Includes offline tests and a six-mutation gate.
- Repository bootstrapped: MIT license, README, `upstream.lock` pinning
  Traefik `v3.7.13` (`fc92cc1`) / lego `v5.4.1` / Go `1.26.0`.
- Milestone 1 spec written (`docs/specs/m1-csr-subject.md`): generic
  `csrSubject` configuration for the ACME resolver.
