#!/usr/bin/env bash
#
# Entrypoint wrapper for the PostgreSQL container.
#
# At startup this script does two things before handing off to the real
# PostgreSQL entrypoint:
#
# 1. AUTO-DETECT DOCKER NETWORK SUBNETS
#    Inspects the container's own network interfaces and writes a
#    /tmp/pg_hba_docker.conf that grants scram-sha-256 access (no SSL) to
#    every subnet the container is attached to.  This covers all Docker
#    services that share a network with this container — no manual subnet
#    configuration required.
#
# 2. EXTERNAL ALLOWLIST (POSTGRES_ALLOWED_NETWORKS)
#    If POSTGRES_ALLOWED_NETWORKS is set, writes /tmp/pg_hba_external.conf
#    containing hostssl rules (SSL required) for each CIDR in the list.
#    These cover non-Docker clients connecting via the exposed host port.
#
#    POSTGRES_ALLOWED_NETWORKS is a comma-separated list of CIDRs:
#      POSTGRES_ALLOWED_NETWORKS=203.0.113.0/24,198.51.100.128/25
#
#    If the variable is empty or unset the file is not created and
#    external connections are blocked — the safe default.
#
# Both files are included by pg_hba.conf via @include_if_exists.
# To update either list, edit .env and run: docker compose restart

set -euo pipefail

DOCKER_HBA=/tmp/pg_hba_docker.conf
EXTERNAL_HBA=/tmp/pg_hba_external.conf

########################################################################
# Helper: convert an interface CIDR (e.g. 172.18.0.5/16) to the
# network CIDR (e.g. 172.18.0.0/16) using bash integer arithmetic.
# Bash uses 64-bit signed integers, so all 32-bit values fit cleanly.
########################################################################
cidr_to_network() {
    local cidr="$1"
    local ip="${cidr%%/*}"
    local prefix="${cidr##*/}"
    local a b c d
    IFS='.' read -r a b c d <<< "$ip"
    local n=$(( (a << 24) + (b << 16) + (c << 8) + d ))
    local shift=$(( 32 - prefix ))
    # Build host-mask, then invert within 32 bits to get network-mask.
    local mask=$(( 0xFFFFFFFF & ~((1 << shift) - 1) ))
    local net=$(( n & mask ))
    printf "%d.%d.%d.%d/%d" \
        $(( (net >> 24) & 0xFF )) \
        $(( (net >> 16) & 0xFF )) \
        $(( (net >>  8) & 0xFF )) \
        $(( net & 0xFF )) \
        "$prefix"
}

########################################################################
# 1. Docker network rules — auto-detected
########################################################################
{
    echo "# Docker network rules — auto-detected at startup."
    echo "# Do not edit by hand; regenerated on every container start."
    echo "# TYPE    DATABASE  USER  ADDRESS                   METHOD"

    # 'scope global' excludes loopback (scope host) automatically.
    while IFS= read -r _cidr; do
        _network="$(cidr_to_network "$_cidr")"
        printf "host      all       all   %-25s scram-sha-256\n" "$_network"
    done < <(ip -4 -o addr show scope global | awk '{print $4}')
} > "$DOCKER_HBA"

echo "postgres entrypoint: Docker network rules:"
grep -v '^#' "$DOCKER_HBA" | grep -v '^[[:space:]]*$' | awk '{print "  " $4}'

########################################################################
# 2. External allowlist — from POSTGRES_ALLOWED_NETWORKS
########################################################################
if [[ -n "${POSTGRES_ALLOWED_NETWORKS:-}" ]]; then
    {
        echo "# External network allowlist — SSL required."
        echo "# Generated at startup from POSTGRES_ALLOWED_NETWORKS — do not edit by hand."
        echo "# TYPE    DATABASE  USER  ADDRESS                   METHOD"

        IFS=',' read -ra _nets <<< "$POSTGRES_ALLOWED_NETWORKS"
        for _net in "${_nets[@]}"; do
            _net="${_net//[[:space:]]/}"    # strip surrounding whitespace
            [[ -z "$_net" ]] && continue
            printf "hostssl   all       all   %-25s scram-sha-256\n" "$_net"
        done
    } > "$EXTERNAL_HBA"

    echo "postgres entrypoint: external SSL access enabled for:"
    grep -v '^#' "$EXTERNAL_HBA" | grep -v '^[[:space:]]*$' | awk '{print "  " $4}'
else
    echo "postgres entrypoint: POSTGRES_ALLOWED_NETWORKS not set — external connections disabled."
    rm -f "$EXTERNAL_HBA"
fi

exec docker-entrypoint.sh "$@"
