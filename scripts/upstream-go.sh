#!/usr/bin/env bash
# Run the Go toolchain against the staged upstream Traefik tree, fully offline.
#
# The upstream sources and the module cache are never committed (see
# .gitignore); whoever prepares a working copy stages them under .upstream/ and
# .gomodcache/ before any build. GOPROXY=off is deliberate: it turns a missing
# module into an honest error instead of a silent network fetch that would only
# work on a machine that has network.
#
# Usage: scripts/upstream-go.sh test -count=1 ./pkg/provider/acme/...
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
upstream="$root/.upstream/traefik"

if [ ! -d "$upstream" ]; then
    echo "upstream tree missing: $upstream" >&2
    echo "stage Traefik sources there before building (see docs/specs/)" >&2
    exit 2
fi

export GOMODCACHE="$root/.gomodcache"
export GOCACHE="$root/.gocache"
export GOFLAGS=-mod=mod
export GOPROXY=off

# `go -C` also changes the child CWD, so a relative --configfile would resolve
# inside .upstream/traefik instead of the caller's directory. Build there, run
# here, so repo-relative paths such as presets/nuc.yml work.
if [ "${1:-}" = "run" ]; then
    shift
    pkg="${1:-}"
    if [ -z "$pkg" ]; then
        echo "usage: scripts/upstream-go.sh run <package> [args...]" >&2
        exit 2
    fi
    shift
    mkdir -p "$root/.gocache"
    bin="$root/.gocache/upstream-run-bin"
    go -C "$upstream" build -o "$bin" "$pkg"
    exec "$bin" "$@"
fi

exec go -C "$upstream" "$@"
