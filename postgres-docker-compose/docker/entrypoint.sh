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
# 1. Docker network rules -- allow same-host Docker peers without SSL.
#
# Services sharing a Docker network with this container reach Postgres over the
# bridge by private IP.  pg_hba.conf must list those subnets or the connections
# are refused, but Docker assigns the subnets dynamically so they are not known
# ahead of time.  At startup we therefore discover this container's
# directly-attached subnets and emit a "host" (no-SSL) rule for each -- no
# manual subnet configuration needed.  External, non-Docker clients are handled
# separately and require SSL (step 2).
#
# Detection prefers iproute2; the stock postgres image lacks it, so we fall
# back to /proc/net/route.  Link-local IPv6 (fe80::/64) is skipped.
########################################################################
detect_docker_subnets() {
    # Prefer iproute2 when present (covers IPv4 and IPv6).
    if command -v ip >/dev/null 2>&1; then
        ip -4 route show proto kernel scope link 2>/dev/null | awk '{print $1}'
        ip -6 route show proto kernel scope link 2>/dev/null | awk '$1 !~ /^fe80:/ {print $1}'
        return 0
    fi

    # Fallback: the stock postgres image has no iproute2.  Parse IPv4 on-link
    # routes from /proc/net/route (always present); destination and mask are
    # stored as little-endian hex.  IPv6 docker auto-detection needs iproute2;
    # external IPv6 is still handled by POSTGRES_ALLOWED_NETWORKS (hostssl).
    [[ -r /proc/net/route ]] || return 0
    local iface dest gw flags refcnt use metric mask mtu window irtt
    while read -r iface dest gw flags refcnt use metric mask mtu window irtt; do
        [[ "$iface" == "Iface" ]] && continue   # header row
        [[ "$gw" != "00000000" ]] && continue    # on-link routes only (no gateway)
        [[ "$dest" == "00000000" ]] && continue  # skip the default route
        local o1=$((16#${dest:6:2})) o2=$((16#${dest:4:2}))
        local o3=$((16#${dest:2:2})) o4=$((16#${dest:0:2}))
        local m=$((16#$mask)) p=0 i
        for ((i = 0; i < 32; i++)); do
            if (( (m >> i) & 1 )); then p=$((p + 1)); fi
        done
        echo "${o1}.${o2}.${o3}.${o4}/${p}"
    done < /proc/net/route
}

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
# '|| true': grep exits non-zero when there are no rules, which would abort the
# wrapper under 'set -o pipefail' before postgres ever starts.
grep -v '^#' "$DOCKER_HBA" | grep -v '^[[:space:]]*$' | awk '{print "  " $4}' || true

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
    grep -v '^#' "$EXTERNAL_HBA" | grep -v '^[[:space:]]*$' | awk '{print "  " $4}' || true
else
    echo "postgres entrypoint: POSTGRES_ALLOWED_NETWORKS not set — external connections disabled."
    rm -f "$EXTERNAL_HBA"
fi

exec docker-entrypoint.sh "$@"
