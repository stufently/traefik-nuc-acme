#!/usr/bin/env bash
# Multi-arch image build. Does not publish unless --push is given.
# Default and --dry-run only print the plan; they never log in or push.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_repo="${IMAGE_REPO:-ghcr.io/stufently/traefik-nuc-acme}"
tag="${IMAGE_TAG:-3.7.13-nuc.1}"
platforms="${PLATFORMS:-linux/amd64,linux/arm64}"
dry_run=0
do_push=0

usage() {
    cat <<'EOF'
Usage: scripts/release.sh [--dry-run] [--push]

  --dry-run  Print the buildx command and exit 0 (default behaviour).
  --push     Build linux/amd64,linux/arm64 and publish the tag.
             Uses the current docker credential helper; this script
             never logs in and never embeds credentials.

Default (no flags) is the same as --dry-run: print the plan, do not push.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=1 ;;
        --push) do_push=1 ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

cmd=(docker buildx build
    --platform "$platforms"
    -t "${image_repo}:${tag}"
    -f "$root/Dockerfile"
    --build-arg "VERSION=v${tag}"
    "$root")

if [[ "$do_push" -eq 1 && "$dry_run" -eq 0 ]]; then
    cmd+=(--push)
    printf 'Running:'
    printf ' %q' "${cmd[@]}"
    printf '\n'
    "${cmd[@]}"
    exit 0
fi

echo "Would build multi-arch image ${image_repo}:${tag}"
echo "Platforms: ${platforms}"
printf 'Would run:'
printf ' %q' "${cmd[@]}"
if [[ "$do_push" -eq 1 ]]; then
    printf ' --push'
    echo
    echo "Would publish ${image_repo}:${tag} (not executed because --dry-run)."
else
    echo
    echo "Not publishing. Pass --push to build and publish. No login is performed."
fi
