# traefik-nuc-acme

Traefik with a **configurable ACME CSR Subject** — so the certificate signing
request Traefik sends to an ACME CA can carry `C=RU`, an organization name, or
any other Distinguished Name field the CA requires.

Built for [НУЦ](https://nuc-acme.voskhod.ru) (Национальный удостоверяющий центр,
the Russian state ACME CA operated by НИИ «Восход»), which — unlike Let's
Encrypt — requires a country field in the CSR. The feature itself is generic:
any CA with the same requirement works.

## What this is

A **patchset** applied to a pinned upstream Traefik release, plus a Dockerfile
that builds the patched binary. Traefik is MIT-licensed and its notices are
preserved; this repository ships the patch, not a copy of Traefik's sources.

## What this is NOT

- **Not a fork of lego.** The patch builds the CSR itself with Go's `crypto/x509`
  and hands it to the stock `lego.ObtainForCSR()`. lego stays an unmodified
  dependency.
- **Not a fork of Traefik.** No upstream sources are vendored into this
  repository. The build downloads the pinned release and applies the patch.
- **Not a Traefik plugin.** Traefik's Yaegi plugin system covers HTTP
  middleware, not the ACME certificate resolver, so a core patch is required.

## Why upstream doesn't cover it

`go-acme/lego#2433` ("Add option for specifying subject Distinguished Name in
certificate") has been open since 2025-02-11. `go-acme/lego#2423` is sometimes
cited as a base for this — it is not: it merged support for CSR *emails*, not
the Subject DN.

## Configuration

```yaml
certificatesResolvers:
  nuc:
    acme:
      caServer: https://nuc-acme.voskhod.ru/acme/api/v1/directory
      keyType: RSA2048
      httpChallenge:
        entryPoint: web
      csrSubject:
        country: RU
        organization: "Example LLC"
```

Every `csrSubject` field is optional; omitting the whole block reproduces stock
Traefik behaviour byte for byte.

## Pinned versions

| Component | Version |
|---|---|
| Traefik | `v3.7.13` (`fc92cc1`) |
| lego | `v5.4.1` |
| Go (upstream `go.mod`) | `1.26.0` |

Machine-readable: [`upstream.lock`](upstream.lock).

## Status

Early. Milestone 1 (the patch itself, tested against a local mock ACME server)
is in progress. Docker images, the НУЦ preset and published documentation come
in later milestones — this README will stop being a promise and start being a
description when they land.

## Building

See `docs/` once milestone 2 lands. There is deliberately no CI in this
repository yet; everything is built and tested locally with Docker.

## License

MIT — see [LICENSE](LICENSE). Traefik and lego are MIT-licensed upstream.
