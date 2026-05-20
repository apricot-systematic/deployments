#!/usr/bin/env bash
#
# Entrypoint wrapper for the PostgreSQL container.
#
# At startup this script does two things before handing off to the real
# PostgreSQL entrypoint:
#
# 1. AUTO-DETECT DOCKER NETWORK SUBNETS (IPv4 and IPv6)
#    Reads the kernel routing table for directly-attached routes and writes
#    /tmp/pg_hba_docker.conf with a "host" rule (no SSL) for each subnet.
#    This covers all Docker services that share a network with this container
#    without any manual subnet configuration.
#
# 2. EXTERNAL ALLOWLIST (POSTGRES_ALLOWED_NETWORKS)
#    If POSTGRES_ALLOWED_NETWORKS is set, writes /tmp/pg_hba_external.conf
#    with "hostssl" rules (SSL required) for each CIDR in the list.
#    Accepts both IPv4 and IPv6 CIDRs, comma-separated.
#
#      POSTGRES_ALLOWED_NETWORKS=10.0.1.0/24,100.64.0.0/10,fd7a:115c:a1e0::/48
#
#    If the variable is empty or unset the file is not created and external
#    connections are blocked — the safe default.
#
# Both files are pulled in by pg_hba.conf via @include_if_exists.
# To update either list, edit .env and run: docker compose restart

set -euo pipefail

DOCKER_HBA=/tmp/pg_hba_docker.conf
EXTERNAL_HBA=/tmp/pg_hba_external.conf

########################################################################
# 1. Docker network rules — auto-detected from the kernel routing table.
#
# "ip route show proto kernel scope link" returns only directly-attached
# network routes (added automatically by the kernel for each interface).
# The first field of each line is already the network CIDR — no address
# arithmetic needed.  Works for both IPv4 and IPv6.
#
# Link-local IPv6 (fe80::/64) routes are skipped — they are not useful
# in pg_hba.conf and vary per interface.
########################################################################
{
    echo "# Docker network rules — auto-detected at startup."
    echo "# Do not edit; regenerated on every container start."
    printf "# %-8s %-10s %-6s %-40s %s\n" TYPE DATABASE USER ADDRESS METHOD

    # IPv4 directly-attached routes
    while IFS= read -r _net; do
        [[ -z "$_net" ]] && continue
        printf "host      all        all    %-40s scram-sha-256\n" "$_net"
    done < <(ip -4 route show proto kernel scope link 2>/dev/null | awk '{print $1}')

    # IPv6 directly-attached routes (skip link-local fe80:: prefixes)
    while IFS= read -r _net; do
        [[ -z "$_net" ]] && continue
        printf "host      all        all    %-40s scram-sha-256\n" "$_net"
    done < <(ip -6 route show proto kernel scope link 2>/dev/null | awk '$1 !~ /^fe80:/ {print $1}')

} > "$DOCKER_HBA"

echo "postgres entrypoint: Docker network rules (auto-detected):"
grep -v '^#' "$DOCKER_HBA" | grep -v '^[[:space:]]*$' | awk '{print "  " $4}'

########################################################################
# 2. External allowlist — from POSTGRES_ALLOWED_NETWORKS.
#    Accepts IPv4 and IPv6 CIDRs; both are valid in pg_hba.conf.
########################################################################
if [[ -n "${POSTGRES_ALLOWED_NETWORKS:-}" ]]; then
    {
        echo "# External network allowlist — SSL required."
        echo "# Generated at startup from POSTGRES_ALLOWED_NETWORKS — do not edit by hand."
        printf "# %-8s %-10s %-6s %-40s %s\n" TYPE DATABASE USER ADDRESS METHOD

        IFS=',' read -ra _nets <<< "$POSTGRES_ALLOWED_NETWORKS"
        for _net in "${_nets[@]}"; do
            _net="${_net//[[:space:]]/}"    # strip surrounding whitespace
            [[ -z "$_net" ]] && continue
            printf "hostssl   all        all    %-40s scram-sha-256\n" "$_net"
        done
    } > "$EXTERNAL_HBA"

    echo "postgres entrypoint: external SSL access enabled for:"
    grep -v '^#' "$EXTERNAL_HBA" | grep -v '^[[:space:]]*$' | awk '{print "  " $4}'
else
    echo "postgres entrypoint: POSTGRES_ALLOWED_NETWORKS not set — external connections disabled."
    rm -f "$EXTERNAL_HBA"
fi

exec docker-entrypoint.sh "$@"
