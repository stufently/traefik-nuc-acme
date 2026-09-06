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

Milestone 2: a patched image and a Pebble integration stand. The НУЦ preset
and published documentation come later.

## Docker image

Tag: `traefik-nuc-acme:3.7.13-nuc.1`. Never a bare `3.7.13` — that tag would
be mistaken for official Traefik.

```bash
docker build -t traefik-nuc-acme:3.7.13-nuc.1 -f Dockerfile .
```

The image is built **without Node and without the web dashboard**.
`api.dashboard` will not work. That is an intentional trade so the binary
can be compiled offline from the release tarball plus the patch, with no
yarn/Node toolchain in the build.

Multi-arch publish is `scripts/release.sh`. Default and `--dry-run` only
print the plan; `--push` is required to publish, and the script never
embeds registry credentials.

## Integration stand

Patched Traefik plus Pebble (Let's Encrypt mock ACME). HTTP-01 is checked
on port 5002. The test domain `stand.traefik-nuc.test` is a Docker network
alias on the Traefik service. An nginx reverse proxy in front of Pebble
records ACME request bodies so `csr-dump` can print the CSR that actually
went to the CA (Pebble does not copy Subject into the issued leaf).

```bash
scripts/stand.sh up
scripts/stand.sh wait
scripts/stand.sh csr-dump | openssl req -noout -subject
scripts/stand.sh dump-cert | openssl x509 -noout -subject
scripts/stand.sh renew-check
scripts/stand.sh down
```

## Building

Build and test locally with Docker. There is deliberately no CI in this
repository yet.

## License

MIT — see [LICENSE](LICENSE). Traefik and lego are MIT-licensed upstream.
