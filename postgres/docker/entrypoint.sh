#!/usr/bin/env bash
#
# Entrypoint wrapper for the PostgreSQL container.
#
# Generates /tmp/pg_hba_external.conf from the POSTGRES_ALLOWED_NETWORKS
# environment variable, then hands off to the official PostgreSQL entrypoint.
#
# POSTGRES_ALLOWED_NETWORKS is a comma-separated list of CIDRs that are
# allowed to make SSL connections from outside the Docker bridge network.
#
#   Example: POSTGRES_ALLOWED_NETWORKS=203.0.113.0/24,198.51.100.128/25
#
# If the variable is empty or unset the generated file is not created.
# The @include_if_exists directive in pg_hba.conf silently skips a missing
# file, so external connections are disabled by default — a safe default.
#
# To update the allowlist: edit POSTGRES_ALLOWED_NETWORKS in .env and
# restart the container (docker compose restart).

set -euo pipefail

EXTERNAL_HBA=/tmp/pg_hba_external.conf

if [[ -n "${POSTGRES_ALLOWED_NETWORKS:-}" ]]; then
    {
        echo "# External network allowlist"
        echo "# Generated at startup from POSTGRES_ALLOWED_NETWORKS — do not edit by hand."
        echo "# TYPE    DATABASE  USER  ADDRESS                   METHOD"
    } > "$EXTERNAL_HBA"

    IFS=',' read -ra _networks <<< "$POSTGRES_ALLOWED_NETWORKS"
    for _net in "${_networks[@]}"; do
        _net="${_net//[[:space:]]/}"    # strip any surrounding whitespace
        [[ -z "$_net" ]] && continue
        printf "hostssl   all       all   %-25s scram-sha-256\n" "$_net" >> "$EXTERNAL_HBA"
    done

    echo "postgres entrypoint: external SSL access enabled for:"
    grep -v '^#' "$EXTERNAL_HBA" | grep -v '^$' | awk '{print "  " $4}'
else
    echo "postgres entrypoint: POSTGRES_ALLOWED_NETWORKS not set — external connections disabled."
    rm -f "$EXTERNAL_HBA"
fi

exec docker-entrypoint.sh "$@"
