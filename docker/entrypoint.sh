#!/bin/sh

case "${1:-}" in
    healthcheck|version|validate-csr-subject)
        exec /traefik "$@"
        ;;
esac

/traefik validate-csr-subject "$@"
status=$?
if [ "$status" -ne 0 ]; then
    exit "$status"
fi

exec /traefik "$@"
