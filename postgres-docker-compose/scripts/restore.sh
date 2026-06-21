#!/usr/bin/env bash
#
# Restore a PostgreSQL backup produced by backup.sh.
#
# Usage:
#   ./scripts/restore.sh <backup_file> [db_name]
#
# Encrypted backups (.sql.gz.enc) are detected automatically from the filename.
# The key ID embedded in the filename is looked up in BACKUP_ENCRYPTION_KEYS —
# no manual key selection required, including for backups encrypted with
# retired keys.
#
# WARNING: restoring into an existing database merges objects.
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
# Must match backup.sh exactly — OpenSSL enc does not store this in the file.
PBKDF2_ITER=600000

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <backup_file> [db_name]" >&2
    exit 1
fi

BACKUP_FILE="$1"
TARGET_DB="${2:-}"

if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "Error: file not found: $BACKUP_FILE" >&2
    exit 1
fi

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
# Detect encryption and resolve the decryption key
########################################################################
is_encrypted=false
decrypt_key=""

if [[ "$BACKUP_FILE" == *.sql.gz.enc ]]; then
    is_encrypted=true

    # Extract the key ID from the filename.
    # Expected format: <anything>_enc_<keyid>.sql.gz.enc
    filename="$(basename "$BACKUP_FILE")"
    file_key_id="${filename##*_enc_}"
    file_key_id="${file_key_id%.sql.gz.enc}"

    if [[ -z "$file_key_id" ]]; then
        echo "Error: cannot extract key ID from filename: $filename" >&2
        echo "Expected format: <name>_enc_<keyid>.sql.gz.enc" >&2
        exit 1
    fi

    echo "Encrypted backup — key ID: $file_key_id"

    if ! decrypt_key="$(find_backup_key "$file_key_id")"; then
        echo "Error: key ID '$file_key_id' not found in BACKUP_ENCRYPTION_KEYS." >&2
        echo "" >&2
        echo "Add it to BACKUP_ENCRYPTION_KEYS in .env:" >&2
        echo "  BACKUP_ENCRYPTION_KEYS=...,${file_key_id}:<key_value>" >&2
        exit 1
    fi

    echo "Key found."
fi

########################################################################
# decrypt_input: emit the decrypted (or plain) byte stream from a file.
########################################################################
decrypt_input() {
    local file="$1"
    if $is_encrypted; then
        # Key passed via env var — does not appear in the process list.
        BACKUP_OPENSSL_PASS="$decrypt_key" \
            openssl enc -d -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" \
                -pass env:BACKUP_OPENSSL_PASS < "$file"
    else
        cat "$file"
    fi
}

########################################################################
# Restore
########################################################################
if [[ -n "$TARGET_DB" ]]; then
    echo "Restoring '$BACKUP_FILE' into database '$TARGET_DB'..."
    decrypt_input "$BACKUP_FILE" \
        | gunzip \
        | "${COMPOSE[@]}" psql -U "$POSTGRES_USER" -d "$TARGET_DB" --no-password
else
    echo "Restoring all databases from '$BACKUP_FILE'..."
    decrypt_input "$BACKUP_FILE" \
        | gunzip \
        | "${COMPOSE[@]}" psql -U "$POSTGRES_USER" --no-password
fi

echo "Restore complete."
