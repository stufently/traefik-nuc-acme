# Compatibility

This repository ships one patch, `patches/0001-csr-subject.patch`, against a
pinned Traefik release. Neither Traefik nor lego is forked, so the only
compatibility question that matters is: on which upstream releases does the
patch apply?

Measured on 2026-09-07 by fetching each release archive and running
`git apply --check` on a clean tree. Fifteen releases were tested.

## Supported

| Traefik | lego in `go.mod` | `git apply --check` |
|---|---|---|
| **v3.7.13** (`fc92cc1`) | v5.4.1 | applies cleanly |

That is the whole list. `upstream.lock` pins this release, Go 1.26.0 and lego
v5.4.1; the image builds on `golang:1.27-alpine`.

## Not supported, and why

| Traefik | lego in `go.mod` | What blocks the patch |
|---|---|---|
| v3.7.6 – v3.7.12 | v5.2.2 / v5.3.1 | `RenewOptions` has no `EnableCommonName` field |
| v3.7.0 – v3.7.5 | lego v5 absent (v4.35.2 only) | `ObtainRequest` has no `EnableCommonName` or `KeyType`; `Obtain` takes no context; renewal calls `RenewWithOptions` |
| v3.6.25 | v5.3.1 | same as v3.7.6 – v3.7.12 |
| v3.8.x | — | no such tags exist upstream |

The single decisive difference is in the renewal path. Our patch replaces the
renewal call and carries `EnableCommonName: !p.DisableCommonName,` in its
context. Upstream added that field to `RenewOptions` in v3.7.13:

```
v3.7.12  pkg/provider/acme/provider.go:947   PreferredChain: p.PreferredChain,
                                       948   }
                                       950   renewedCert, err := client.Certificate.Renew(ctx, res, opts)

v3.7.13  pkg/provider/acme/provider.go:966   PreferredChain:   p.PreferredChain,
                                       968   EnableCommonName: !p.DisableCommonName,
```

Releases before v3.7.6 differ more deeply: they predate lego v5 in Traefik
entirely, so three hunks fail rather than one.

## Why the range is this narrow, and why that is fine

The patch is deliberately small and touches upstream code that changes often.
A narrow supported range is the honest consequence: `git apply` either succeeds
byte for byte or it does not, and we would rather say "one release" than claim
a range nobody measured.

Rebasing onto a new release is cheap for the same reason. When Traefik cuts a
new patch release:

1. Update `upstream.lock` and fetch the new archive.
2. `git apply --check patches/0001-csr-subject.patch`. If it applies, run the
   mutation gate and the Pebble stand; nothing else is needed.
3. If it does not apply, the failing hunk names the upstream change. Adjust the
   patch context, regenerate with `git -C .upstream/traefik diff`, and re-run
   the gate — the tests, not the patch, are what prove the behaviour survived.

## What is NOT covered by these numbers

Applying is not building, and building is not working. The table above reports
`git apply --check` only. For the pinned release the project also runs the
upstream build, the affected package tests, `go vet`, a seventeen-mutation
offline gate and an end-to-end Pebble stand that captures the CSR on the wire.
None of that was run against the unsupported releases, because the patch does
not reach them.

Issuing against the production НУЦ is not covered either, on any release:
access to that CA requires accreditation nobody involved has. That is a gap in
access, not in diligence — see `presets/nuc.yml` and the README.
