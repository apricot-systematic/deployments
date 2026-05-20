#!/usr/bin/env bash
#
# Restore a PostgreSQL backup produced by backup.sh.
#
# Usage:
#   ./scripts/restore.sh <backup.sql.gz>              # restore all (pg_dumpall output)
#   ./scripts/restore.sh <backup.sql.gz> <db_name>   # restore into a specific database
#
# WARNING: restoring into an existing database will merge/overwrite objects.
# For a clean restore, drop and recreate the database first.

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

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <backup.sql.gz> [db_name]" >&2
    exit 1
fi

BACKUP_FILE="$1"
TARGET_DB="${2:-}"

if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "Error: file not found: $BACKUP_FILE" >&2
    exit 1
fi

COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T postgres)

if [[ -n "$TARGET_DB" ]]; then
    echo "Restoring '$BACKUP_FILE' into database '$TARGET_DB'..."
    gunzip -c "$BACKUP_FILE" \
        | "${COMPOSE[@]}" psql -U "$POSTGRES_USER" -d "$TARGET_DB" --no-password
else
    echo "Restoring all databases from '$BACKUP_FILE'..."
    gunzip -c "$BACKUP_FILE" \
        | "${COMPOSE[@]}" psql -U "$POSTGRES_USER" --no-password
fi

echo "Restore complete."
