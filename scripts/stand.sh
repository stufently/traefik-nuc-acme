#!/usr/bin/env bash
# Integration stand: patched Traefik + Pebble.
# Subcommands: up, wait, dump-cert, renew-check, down.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="$root/docker/compose.yaml"
data_dir="$root/docker/run"
acme_json="$data_dir/acme.json"
ca_dir="$data_dir/ca"
pebble_mgmt="https://127.0.0.1:24150"
wait_timeout="${STAND_WAIT_TIMEOUT:-120}"
renew_timeout="${STAND_RENEW_TIMEOUT:-180}"

compose() {
    docker compose -f "$compose_file" --project-directory "$root/docker" "$@"
}

usage() {
    cat <<'EOF'
Usage: scripts/stand.sh <up|wait|dump-cert|renew-check|down>
EOF
}

prepare_data() {
    mkdir -p "$ca_dir"
    umask 077
    : >"$acme_json"
    chmod 600 "$acme_json"
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

cmd_up() {
    compose down --remove-orphans >/dev/null 2>&1 || true
    prepare_data
    compose up -d pebble
    wait_http_file "$pebble_mgmt/roots/0" "$ca_dir/pebble-root.pem" 30
    docker cp traefik-nuc-pebble:/test/certs/pebble.minica.pem "$ca_dir/pebble-minica.pem"
    chmod 644 "$ca_dir/pebble-minica.pem"
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
            compose logs traefik >&2 || true
            return 1
        fi
        sleep 2
    done
    echo "timeout waiting for certificate in $acme_json" >&2
    compose logs traefik >&2 || true
    return 1
}

cmd_dump_cert() {
    cert_pem_from_store
}

cmd_renew_check() {
    if ! cert_pem_from_store >/dev/null; then
        echo "no certificate to renew; run up && wait first" >&2
        return 1
    fi
    local before after
    before="$(cert_pem_from_store | openssl x509 -noout -serial)"
    compose up -d --force-recreate --no-deps traefik
    local deadline=$((SECONDS + renew_timeout))
    while ((SECONDS < deadline)); do
        if after="$(cert_pem_from_store | openssl x509 -noout -serial 2>/dev/null)" \
            && [[ -n "$after" ]] && [[ "$after" != "$before" ]]; then
            local subject
            subject="$(cert_pem_from_store | openssl x509 -noout -subject)"
            if echo "$subject" | grep -q "C = RU\|C=RU"; then
                echo "renewed $before -> $after"
                echo "$subject"
                return 0
            fi
            echo "renewed certificate missing C=RU: $subject" >&2
            return 1
        fi
        if ! traefik_running; then
            echo "traefik is not running during renew-check" >&2
            compose logs traefik >&2 || true
            return 1
        fi
        sleep 2
    done
    echo "timeout waiting for renewed serial (still $before)" >&2
    compose logs traefik >&2 || true
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
    renew-check) cmd_renew_check ;;
    down) cmd_down ;;
    -h|--help) usage ;;
    *)
        usage >&2
        exit 2
        ;;
esac
