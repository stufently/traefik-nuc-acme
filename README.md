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

## НУЦ preset

`presets/nuc.yml` is a static Traefik configuration aimed at
[НУЦ](https://nuc-acme.voskhod.ru) (`https://nuc-acme.voskhod.ru/acme/api/v1/directory`).
Copy it, replace the `REPLACE-ME` values (`email`, `organization`, `locality`,
storage path), and keep `csrSubject.country: RU`.

**Live НУЦ is UNVERIFIED.** The directory URL, the TLS chain, and the absence
of EAB were checked on 2026-09-07. No certificate has been issued or renewed
against the production CA — that step needs accreditation nobody here has.
`keyType: RSA2048` is an assumption from public RSA DV docs, not a measured
rejection of EC keys. Treat the preset as a starting point, not a proven
production config. Боевой НУЦ не проверен.

### CA bundle (not baked into the image)

`nuc-acme.voskhod.ru` is signed by the Russian Trusted Root CA (Минцифры). That
root is in no standard trust store, so a plain `curl` fails the handshake
before ACME starts. The issuing Sub CA has already rotated once (2022 → 2024).
A copy baked into the image would silently go stale on the next rotation: the
handshake would fail and nothing would point at an outdated file inside the
image. The bundle is therefore built by a script with sha256 pins and mounted
from outside.

```bash
scripts/nuc-ca-bundle.sh -o nuc-ca.pem
```

`--root-sha256` / `--sub-sha256` override the pins after a rotation, without
editing the script. A pin mismatch exits non-zero and does not create or
replace the destination file.

Mount the preset and the bundle, then start Traefik (the image entrypoint
validates `csrSubject` first):

```bash
docker build -t traefik-nuc-acme:3.7.13-nuc.1 -f Dockerfile .
docker run --rm \
  -v "$PWD/presets/nuc.yml:/etc/traefik/traefik.yml:ro" \
  -v "$PWD/nuc-ca.pem:/etc/traefik/ca/nuc-ca.pem:ro" \
  -v acme-data:/data \
  -p 80:80 -p 443:443 \
  traefik-nuc-acme:3.7.13-nuc.1
```

### Trap: the 2022 Sub CA is not the issuer

Do not use the widely copied
`https://gu-st.ru/content/lending/russian_trusted_sub_ca_pem.crt` (serial
`1002`, issued 2022). It is **not** the issuer of the current leaf: that
file's SKI is `D1:E1:71:0D…`, the leaf's AKI is `77:3D:D9:39…`. Take the
issuer from the leaf's Authority Information Access (AIA):
`http://nuc-cdp.voskhod.ru/cdp/subca_ssl_rsa2024.crt` (PEM despite the `.crt`
extension — do not decode it as DER). The working bundle is that Sub CA plus
`https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt`.

## Validation before startup

Stock Traefik skips an ACME resolver that fails initialization and keeps the
server running. An invalid `csrSubject` therefore leaves that resolver issuing
no certificates, with the reason visible only in logs. A typo can otherwise
cause a silent absence of certificates.

The image entrypoint first runs `/traefik validate-csr-subject "$@"`. This command
uses the same configuration loader instances as Traefik: deprecation, file,
flags, then environment. It respects `--configfile` and Traefik's normal file
search paths; it does not parse a separate configuration. Every ACME resolver
is checked with the existing `CSRSubject.Validate()` rules, in name order.
Resolvers without ACME and empty subjects are accepted.

On failure the command writes a line such as this to stderr and exits with 1:

```text
invalid CSR subject in resolver "nuc": CSR subject country must contain exactly two ASCII letters
```

On success it writes `csrSubject OK` to stdout and exits with 0. Only then does
the entrypoint replace itself with the Traefik server using `exec`. A nonzero
validation status is returned unchanged, so the server never starts with an
invalid subject. Stock resolver initialization behavior is unchanged.

Run the check directly without starting the server:

```bash
docker run --rm -v "$PWD/traefik.yml:/etc/traefik/traefik.yml:ro" \
  traefik-nuc-acme:3.7.13-nuc.1 validate-csr-subject \
  --configfile=/etc/traefik/traefik.yml
```

The entrypoint forwards `healthcheck`, `version`, and `validate-csr-subject`
directly, so service commands retain their own behavior. This guard validates
CSR subjects; other ACME configuration errors still follow Traefik's behavior.

## Pinned versions

| Component | Version |
|---|---|
| Traefik | `v3.7.13` (`fc92cc1`) |
| lego | `v5.4.1` |
| Go (upstream `go.mod`) | `1.26.0` |

Machine-readable: [`upstream.lock`](upstream.lock).

## Status

Milestone 4: НУЦ preset (`presets/nuc.yml`) and an externally mounted CA
bundle (`scripts/nuc-ca-bundle.sh`). Live issuance against НУЦ remains
UNVERIFIED. Earlier milestones: fail-closed CSR subject validation before
startup, a patched image, and a Pebble integration stand.

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
