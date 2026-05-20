#!/usr/bin/env bash
#
# Configure HashiCorp Vault's PostgreSQL database secrets engine for one application.
#
# This script is idempotent — safe to re-run to update credentials or TTLs.
#
# Prerequisites:
#   1. Vault is running and reachable (VAULT_ADDR, VAULT_TOKEN set in environment).
#   2. The vault_manager role exists in PostgreSQL.  Create it with:
#        ./scripts/create-vault-manager.sh
#   3. The application database and its base role exist.  Create them with:
#        ./scripts/create-database.sh <db_name> <app_role>
#
# Usage:
#   export VAULT_ADDR=https://vault.example.com:8200
#   export VAULT_TOKEN=...
#   export VAULT_POSTGRES_PASSWORD=...   # password for vault_manager in PostgreSQL
#   ./scripts/vault-setup.sh <db_name> <app_role>
#
# The script registers the DB connection, creates a Vault role that issues dynamic
# credentials inheriting from <app_role>_base, and prints next steps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/.env"
    set +a
fi

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <db_name> <app_role>" >&2
    exit 1
fi

DB_NAME="$1"
APP_ROLE="$2"
BASE_ROLE="${APP_ROLE}_base"

: "${VAULT_ADDR:?VAULT_ADDR must be set}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set}"
VAULT_MANAGER_PASSWORD="${VAULT_POSTGRES_PASSWORD:?VAULT_POSTGRES_PASSWORD must be set}"

PG_HOST="${POSTGRES_HOST:-127.0.0.1}"
PG_PORT="${POSTGRES_PORT:-5432}"
# Use sslmode=require once SSL is enabled in postgresql.conf and pg_hba.conf.
# Default to disable so the setup works before SSL is configured.
PG_SSLMODE="${POSTGRES_SSLMODE:-disable}"

MOUNT="database"

echo "Enabling database secrets engine (path: ${MOUNT})..."
vault secrets enable -path="$MOUNT" database 2>/dev/null \
    || echo "  (already enabled at ${MOUNT}/)"

echo "Configuring PostgreSQL connection for '${DB_NAME}'..."
vault write "${MOUNT}/config/${DB_NAME}" \
    plugin_name="postgresql-database-plugin" \
    allowed_roles="${APP_ROLE}" \
    connection_url="postgresql://{{username}}:{{password}}@${PG_HOST}:${PG_PORT}/${DB_NAME}?sslmode=${PG_SSLMODE}" \
    username="vault_manager" \
    password="${VAULT_MANAGER_PASSWORD}"

echo "Creating Vault role '${APP_ROLE}'..."
vault write "${MOUNT}/roles/${APP_ROLE}" \
    db_name="${DB_NAME}" \
    creation_statements="
        CREATE ROLE \"{{name}}\"
            WITH LOGIN PASSWORD '{{password}}'
            VALID UNTIL '{{expiration}}'
            INHERIT;
        GRANT \"${BASE_ROLE}\" TO \"{{name}}\";
    " \
    revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"

echo ""
echo "Vault configuration complete."
echo ""
echo "Next steps:"
echo "  1. Ensure '${BASE_ROLE}' exists and vault_manager can grant it:"
echo "       ./scripts/create-database.sh ${DB_NAME} ${BASE_ROLE}"
echo "     Then in psql as superuser:"
echo "       GRANT \"${BASE_ROLE}\" TO vault_manager WITH ADMIN OPTION;"
echo ""
echo "  2. Apply the Vault policy for application access:"
echo "       vault policy write ${APP_ROLE} vault/policy-template.hcl"
echo "     (edit APP_ROLE placeholder in that file first)"
echo ""
echo "  3. Test credential generation:"
echo "       vault read ${MOUNT}/creds/${APP_ROLE}"
