#!/usr/bin/env bash
# Build a PEM trust bundle for nuc-acme.voskhod.ru (root + issuing Sub CA).
#
# The leaf is signed by Russian Trusted Sub CA 2024, NOT by the widely copied
# 2022 Sub CA from gu-st.ru (serial 1002). Pins below are sha256 of the
# downloaded files; override with --root-sha256 / --sub-sha256 after a rotation.
#
# Both files are already PEM despite the .crt suffix — do not decode as DER.
# The root arrives with CRLF and no trailing newline; concatenation must
# insert a newline between certificates or OpenSSL reports "bad end line".
set -euo pipefail

ROOT_URL="https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt"
SUB_URL="http://nuc-cdp.voskhod.ru/cdp/subca_ssl_rsa2024.crt"
ROOT_SHA256="936a43fea6e8e525bcc0f81acd9c3d21b4fc4b9b68acea7906d698005afc6504"
SUB_SHA256="6f9d829c8e6712444fce3624658d8788672849c5d5b7b53fd9cf7e83eac4193e"
output=""

usage() {
    cat <<'EOF'
Usage: scripts/nuc-ca-bundle.sh -o FILE [--root-sha256 HEX] [--sub-sha256 HEX]

  -o FILE            Destination PEM bundle (required). Written atomically.
  --root-sha256 HEX  Expected sha256 of the root CA download (default: pinned).
  --sub-sha256 HEX   Expected sha256 of the issuing Sub CA download (default: pinned).

Downloads the Russian Trusted Root CA and the 2024 SSL Sub CA, checks sha256
pins, rewrites each as PEM with a trailing newline, and concatenates them.
A pin mismatch exits non-zero and does not create or replace FILE.
EOF
}

lowercase_hex() {
    printf '%s' "$1" | tr 'A-F' 'a-f'
}

sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}

require_pin() {
    local file="$1" expected="$2" label="$3"
    local got
    got="$(sha256_of "$file")"
    expected="$(lowercase_hex "$expected")"
    if [ "$got" != "$expected" ]; then
        echo "sha256 mismatch for $label: got $got, expected $expected (пин не совпал)" >&2
        exit 1
    fi
}

pem_from() {
    local src="$1" dest="$2" label="$3"
    if ! openssl x509 -in "$src" -out "$dest" 2>"$tmpdir/openssl.err"; then
        echo "downloaded $label is not a PEM certificate" >&2
        cat "$tmpdir/openssl.err" >&2 || true
        exit 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        -o)
            [ $# -ge 2 ] || { echo "-o requires a path" >&2; exit 2; }
            output="$2"
            shift 2
            ;;
        -o*)
            output="${1#-o}"
            shift
            ;;
        --root-sha256)
            [ $# -ge 2 ] || { echo "--root-sha256 requires a hex digest" >&2; exit 2; }
            ROOT_SHA256="$2"
            shift 2
            ;;
        --sub-sha256)
            [ $# -ge 2 ] || { echo "--sub-sha256 requires a hex digest" >&2; exit 2; }
            SUB_SHA256="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "$output" ]; then
    echo "destination path is required" >&2
    usage >&2
    exit 2
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

curl -fsSL --max-time 60 -o "$tmpdir/root.crt" "$ROOT_URL"
curl -fsSL --max-time 60 -o "$tmpdir/sub.crt" "$SUB_URL"

require_pin "$tmpdir/root.crt" "$ROOT_SHA256" "root CA ($ROOT_URL)"
require_pin "$tmpdir/sub.crt" "$SUB_SHA256" "Sub CA ($SUB_URL)"

# openssl x509 rewrites PEM with LF and a trailing newline, and proves the
# download is a certificate. Hash pins are checked on the raw download.
pem_from "$tmpdir/root.crt" "$tmpdir/root.pem" "root CA"
pem_from "$tmpdir/sub.crt" "$tmpdir/sub.pem" "Sub CA"

cat "$tmpdir/root.pem" "$tmpdir/sub.pem" > "$tmpdir/bundle.pem"

parent="$(dirname "$output")"
mkdir -p "$parent"
# Stage the final file next to its destination: mv is only atomic within one
# filesystem, and $tmpdir usually lives on another one.
staged="$(mktemp "$parent/.nuc-ca-bundle.XXXXXX")"
trap 'rm -rf "$tmpdir"; rm -f "$staged"' EXIT
cat "$tmpdir/bundle.pem" > "$staged"
chmod 644 "$staged"
mv -f "$staged" "$output"
