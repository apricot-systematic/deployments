#!/usr/bin/env bash
#
# Backup one or all PostgreSQL databases to compressed (and optionally
# encrypted) dump files.
#
# Usage:
#   ./scripts/backup.sh                  # dump all databases (pg_dumpall)
#   ./scripts/backup.sh <database_name>  # dump one database (pg_dump)
#
# Output goes to ./backups/ with a timestamp in the filename.
#
# Encryption
# ----------
# Set BACKUP_ENCRYPTION_KEY_ID and BACKUP_ENCRYPTION_KEYS in .env to encrypt
# backups with AES-256-CBC (PBKDF2, 600 000 iterations).  The key ID is
# embedded in the filename so restore.sh can find the right key automatically.
# Plaintext data is never written to disk — the pipeline is:
#   pg_dump | gzip | openssl enc > file
#
# Generate a key:  openssl rand -base64 32 | tr -d '\n'

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
# Must match restore.sh exactly — OpenSSL enc does not store this in the file.
PBKDF2_ITER=600000

mkdir -p "$BACKUP_DIR"

COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T postgres)

########################################################################
# find_backup_key <key_id>
#
# Searches BACKUP_ENCRYPTION_KEYS (format: "id:value,id:value,...") for
# an entry whose id field matches <key_id> and prints the key value.
# Returns 1 (and prints nothing) if the id is not found.
########################################################################
find_backup_key() {
    local target_id="$1"
    local pair pair_id pair_key
    local IFS=','
    read -ra _pairs <<< "${BACKUP_ENCRYPTION_KEYS:-}"
    for pair in "${_pairs[@]}"; do
        pair="${pair//[[:space:]]/}"    # strip any whitespace
        [[ -z "$pair" ]] && continue
        pair_id="${pair%%:*}"           # everything before the first ':'
        pair_key="${pair#*:}"           # everything after the first ':'
        if [[ "$pair_id" == "$target_id" ]]; then
            printf '%s' "$pair_key"
            return 0
        fi
    done
    return 1
}

########################################################################
# Encryption setup
########################################################################
ENCRYPTION_KEY_ID="${BACKUP_ENCRYPTION_KEY_ID:-}"
ENCRYPTION_KEY=""

if [[ -n "$ENCRYPTION_KEY_ID" ]]; then
    if [[ -z "${BACKUP_ENCRYPTION_KEYS:-}" ]]; then
        echo "Error: BACKUP_ENCRYPTION_KEY_ID is set but BACKUP_ENCRYPTION_KEYS is empty." >&2
        exit 1
    fi
    if ! ENCRYPTION_KEY="$(find_backup_key "$ENCRYPTION_KEY_ID")"; then
        echo "Error: key ID '$ENCRYPTION_KEY_ID' not found in BACKUP_ENCRYPTION_KEYS." >&2
        exit 1
    fi
fi

# encrypt_stream: AES-256-CBC via stdin→stdout, or passthrough if no key is set.
# Key is passed via environment variable to avoid exposure in the process list.
encrypt_stream() {
    if [[ -n "$ENCRYPTION_KEY" ]]; then
        BACKUP_OPENSSL_PASS="$ENCRYPTION_KEY" \
            openssl enc -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" -salt \
                -pass env:BACKUP_OPENSSL_PASS
    else
        cat
    fi
}

backup_suffix() {
    if [[ -n "$ENCRYPTION_KEY_ID" ]]; then
        echo "_enc_${ENCRYPTION_KEY_ID}.sql.gz.enc"
    else
        echo ".sql.gz"
    fi
}

########################################################################
backup_single() {
    local db="$1"
    local outfile="$BACKUP_DIR/${db}_${TIMESTAMP}$(backup_suffix)"
    echo "Backing up '$db' -> $outfile"
    "${COMPOSE[@]}" pg_dump -U "$POSTGRES_USER" -d "$db" --no-password \
        | gzip \
        | encrypt_stream > "$outfile"
    echo "Done: $(du -h "$outfile" | cut -f1) ${ENCRYPTION_KEY_ID:+(encrypted: $ENCRYPTION_KEY_ID)}"
}

backup_all() {
    local outfile="$BACKUP_DIR/all_${TIMESTAMP}$(backup_suffix)"
    echo "Backing up all databases -> $outfile"
    "${COMPOSE[@]}" pg_dumpall -U "$POSTGRES_USER" --no-password \
        | gzip \
        | encrypt_stream > "$outfile"
    echo "Done: $(du -h "$outfile" | cut -f1) ${ENCRYPTION_KEY_ID:+(encrypted: $ENCRYPTION_KEY_ID)}"
}

########################################################################
if [[ $# -eq 0 ]]; then
    backup_all
else
    backup_single "$1"
fi
