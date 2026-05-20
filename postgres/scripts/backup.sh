#!/usr/bin/env bash
#
# Backup one or all PostgreSQL databases to compressed SQL dumps.
#
# Usage:
#   ./scripts/backup.sh                  # dump all databases (pg_dumpall)
#   ./scripts/backup.sh <database_name>  # dump one database (pg_dump)
#
# Output goes to ./backups/ with a timestamp in the filename.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/.env"
    set +a
fi

POSTGRES_USER="${POSTGRES_USER:-postgres}"
BACKUP_DIR="$PROJECT_DIR/backups"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP_DIR"

COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T postgres)

backup_single() {
    local db="$1"
    local outfile="$BACKUP_DIR/${db}_${TIMESTAMP}.sql.gz"
    echo "Backing up '$db' -> $outfile"
    "${COMPOSE[@]}" pg_dump -U "$POSTGRES_USER" -d "$db" --no-password \
        | gzip > "$outfile"
    echo "Done: $(du -h "$outfile" | cut -f1)"
}

backup_all() {
    local outfile="$BACKUP_DIR/all_${TIMESTAMP}.sql.gz"
    echo "Backing up all databases -> $outfile"
    "${COMPOSE[@]}" pg_dumpall -U "$POSTGRES_USER" --no-password \
        | gzip > "$outfile"
    echo "Done: $(du -h "$outfile" | cut -f1)"
}

if [[ $# -eq 0 ]]; then
    backup_all
else
    backup_single "$1"
fi
