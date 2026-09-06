# Changelog

## 2026-09-06

- Added the M1 patch for optional ACME `csrSubject` country, organization,
  organizational unit, and locality fields, with subject validation. Issuance
  sends a signed CSR and its private key; renewal rebuilds the CSR from current
  configuration and the saved key without changing `acme.json`. Empty subjects
  retain the stock lego paths. Includes offline tests and a six-mutation gate.
- Repository bootstrapped: MIT license, README, `upstream.lock` pinning
  Traefik `v3.7.13` (`fc92cc1`) / lego `v5.4.1` / Go `1.26.0`.
- Milestone 1 spec written (`docs/specs/m1-csr-subject.md`): generic
  `csrSubject` configuration for the ACME resolver.
