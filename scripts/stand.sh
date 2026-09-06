#!/usr/bin/env bash
# Integration stand: patched Traefik + Pebble + ACME body-capturing proxy.
# Subcommands: up, wait, dump-cert, csr-dump, renew-check, down.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="$root/docker/compose.yaml"
data_dir="$root/docker/run"
acme_json="$data_dir/acme.json"
ca_dir="$data_dir/ca"
capture_dir="$data_dir/capture"
tls_dir="$data_dir/acmeproxy-tls"
pebble_mgmt="https://127.0.0.1:24150"
wait_timeout="${STAND_WAIT_TIMEOUT:-120}"
renew_timeout="${STAND_RENEW_TIMEOUT:-180}"

compose() {
    docker compose -f "$compose_file" --project-directory "$root/docker" "$@"
}

usage() {
    cat <<'EOF'
Usage: scripts/stand.sh <up|wait|dump-cert|csr-dump|renew-check|down>
EOF
}

prepare_data() {
    mkdir -p "$ca_dir" "$capture_dir" "$tls_dir"
    umask 077
    : >"$acme_json"
    chmod 600 "$acme_json"
    chmod 755 "$capture_dir" "$tls_dir"
}

wait_http_file() {
    local url="$1" dest="$2" timeout="$3"
    local deadline=$((SECONDS + timeout))
    while ((SECONDS < deadline)); do
        if curl -ksS --max-time 3 "$url" -o "$dest" \
            && grep -q "BEGIN CERTIFICATE" "$dest"; then
            chmod 644 "$dest"
            return 0
        fi
        sleep 1
    done
    echo "timeout waiting for $url" >&2
    return 1
}

issue_acmeproxy_cert() {
    local key="$tls_dir/acmeproxy.key"
    local crt="$tls_dir/acmeproxy.crt"
    local csr="$tls_dir/acmeproxy.csr"
    cp "$ca_dir/pebble-minica.pem" "$tls_dir/pebble-minica.pem"
    docker cp traefik-nuc-pebble:/test/certs/pebble.minica.key.pem "$tls_dir/pebble.minica.key.pem"
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$key" -out "$csr" \
        -subj "/CN=acmeproxy" \
        -addext "subjectAltName=DNS:acmeproxy" >/dev/null 2>&1
    openssl x509 -req -in "$csr" \
        -CA "$tls_dir/pebble-minica.pem" \
        -CAkey "$tls_dir/pebble.minica.key.pem" \
        -CAcreateserial -days 2 -sha256 \
        -copy_extensions copy \
        -out "$crt" >/dev/null 2>&1
    chmod 600 "$key" "$tls_dir/pebble.minica.key.pem"
    chmod 644 "$crt" "$tls_dir/pebble-minica.pem"
    rm -f "$csr" "$tls_dir/pebble.minica.srl"
}

traefik_running() {
    local id
    id="$(compose ps -q traefik 2>/dev/null || true)"
    [[ -n "$id" ]] && [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || echo false)" == "true" ]]
}

cert_pem_from_store() {
    python3 - "$acme_json" <<'PY'
import base64, json, sys
path = sys.argv[1]
try:
    raw = open(path, encoding="utf-8").read()
except OSError as e:
    sys.exit(f"cannot read {path}: {e}")
if not raw.strip():
    sys.exit(1)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)

def as_pem(value):
    if not isinstance(value, str) or not value:
        return None
    text = value.strip()
    if "BEGIN CERTIFICATE" in text:
        return text if text.endswith("\n") else text + "\n"
    try:
        decoded = base64.b64decode(text, validate=True).decode("ascii")
    except (ValueError, UnicodeDecodeError):
        return None
    if "BEGIN CERTIFICATE" in decoded:
        return decoded if decoded.endswith("\n") else decoded + "\n"
    return None

for body in data.values():
    if not isinstance(body, dict):
        continue
    certs = body.get("Certificates") or body.get("certificates") or []
    for cert in certs:
        if not isinstance(cert, dict):
            continue
        pem = as_pem(cert.get("certificate") or cert.get("Certificate") or "")
        if pem:
            sys.stdout.write(pem)
            sys.exit(0)
sys.exit(1)
PY
}

# Read the newest captured ACME POST body that contains a CSR (finalize).
# Source is nginx client_body_in_file_only files, not Traefik storage.
csr_from_capture() {
    python3 - "$capture_dir" <<'PY'
import base64, json, os, sys

capture = sys.argv[1]


def b64url_decode(data):
    if not isinstance(data, str) or not data:
        raise ValueError("empty")
    pad = "=" * ((4 - len(data) % 4) % 4)
    return base64.urlsafe_b64decode(data + pad)


def csr_der_from_body(raw):
    body = json.loads(raw)
    if not isinstance(body, dict) or "payload" not in body:
        raise ValueError("not jws")
    payload = json.loads(b64url_decode(body["payload"]))
    if not isinstance(payload, dict) or "csr" not in payload:
        raise ValueError("no csr")
    return b64url_decode(payload["csr"])


def iter_files(root):
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(dirpath, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            yield st.st_mtime, path


found = []
for mtime, path in iter_files(capture):
    try:
        raw = open(path, "rb").read()
        der = csr_der_from_body(raw)
    except (OSError, ValueError, json.JSONDecodeError):
        continue
    if der:
        found.append((mtime, path, der))

if not found:
    sys.exit("no captured finalize CSR in %s" % capture)

_mtime, _path, der = max(found, key=lambda item: item[0])
b64 = base64.encodebytes(der).decode("ascii")
sys.stdout.write("-----BEGIN CERTIFICATE REQUEST-----\n")
sys.stdout.write(b64)
if not b64.endswith("\n"):
    sys.stdout.write("\n")
sys.stdout.write("-----END CERTIFICATE REQUEST-----\n")
PY
}

latest_csr_mtime() {
    python3 - "$capture_dir" <<'PY'
import json, os, sys, base64
capture = sys.argv[1]

def b64url_decode(data):
    pad = "=" * ((4 - len(data) % 4) % 4)
    return base64.urlsafe_b64decode(data + pad)

latest = 0.0
if os.path.isdir(capture):
    for dirpath, _, filenames in os.walk(capture):
        for name in filenames:
            path = os.path.join(dirpath, name)
            try:
                raw = open(path, "rb").read()
                body = json.loads(raw)
                payload = json.loads(b64url_decode(body["payload"]))
                if "csr" not in payload:
                    continue
                latest = max(latest, os.stat(path).st_mtime)
            except (OSError, ValueError, KeyError, json.JSONDecodeError, TypeError):
                continue
print("%.9f" % latest)
PY
}

cmd_up() {
    compose down --remove-orphans >/dev/null 2>&1 || true
    prepare_data
    compose up -d pebble
    wait_http_file "$pebble_mgmt/roots/0" "$ca_dir/pebble-root.pem" 30
    docker cp traefik-nuc-pebble:/test/certs/pebble.minica.pem "$ca_dir/pebble-minica.pem"
    chmod 644 "$ca_dir/pebble-minica.pem"
    issue_acmeproxy_cert
    compose up -d acmeproxy
    compose up -d traefik
}

cmd_wait() {
    local deadline=$((SECONDS + wait_timeout))
    while ((SECONDS < deadline)); do
        if cert_pem_from_store >/dev/null 2>&1; then
            return 0
        fi
        if ! traefik_running; then
            echo "traefik is not running while waiting for acme.json" >&2
            compose logs traefik acmeproxy >&2 || true
            return 1
        fi
        sleep 2
    done
    echo "timeout waiting for certificate in $acme_json" >&2
    compose logs traefik acmeproxy >&2 || true
    return 1
}

cmd_dump_cert() {
    cert_pem_from_store
}

cmd_csr_dump() {
    csr_from_capture
}

cmd_renew_check() {
    if ! cert_pem_from_store >/dev/null; then
        echo "no certificate to renew; run up && wait first" >&2
        return 1
    fi
    local before after before_csr
    before="$(cert_pem_from_store | openssl x509 -noout -serial)"
    before_csr="$(latest_csr_mtime)"
    compose up -d --force-recreate --no-deps traefik
    local deadline=$((SECONDS + renew_timeout))
    while ((SECONDS < deadline)); do
        if after="$(cert_pem_from_store | openssl x509 -noout -serial 2>/dev/null)" \
            && [[ -n "$after" ]] && [[ "$after" != "$before" ]]; then
            local now_csr subject
            now_csr="$(latest_csr_mtime)"
            if awk -v n="$now_csr" -v o="$before_csr" 'BEGIN { exit !(n > o) }'; then
                subject="$(csr_from_capture 2>/dev/null | openssl req -noout -subject)"
                if echo "$subject" | grep -qE "C *= *RU"; then
                    echo "renewed $before -> $after"
                    echo "$subject"
                    return 0
                fi
                echo "renewed CSR missing C=RU: $subject" >&2
                return 1
            fi
        fi
        if ! traefik_running; then
            echo "traefik is not running during renew-check" >&2
            compose logs traefik acmeproxy >&2 || true
            return 1
        fi
        sleep 2
    done
    echo "timeout waiting for renewed serial and new captured CSR (still $before)" >&2
    compose logs traefik acmeproxy >&2 || true
    return 1
}

cmd_down() {
    compose down --remove-orphans >/dev/null 2>&1 || true
    local leftover
    leftover="$(docker ps -aq --filter name=traefik-nuc || true)"
    if [[ -n "$leftover" ]]; then
        # shellcheck disable=SC2086
        docker rm -f $leftover >/dev/null
    fi
    rm -rf "$data_dir"
}

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 2
fi

case "$1" in
    up) cmd_up ;;
    wait) cmd_wait ;;
    dump-cert) cmd_dump_cert ;;
    csr-dump) cmd_csr_dump ;;
    renew-check) cmd_renew_check ;;
    down) cmd_down ;;
    -h|--help) usage ;;
    *)
        usage >&2
        exit 2
        ;;
esac
