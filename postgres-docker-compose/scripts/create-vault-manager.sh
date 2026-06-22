#!/usr/bin/env bash
#
# Create the vault_manager PostgreSQL role used by HashiCorp Vault's database
# secrets engine to issue dynamic credentials.
#
# vault_manager needs CREATEROLE so it can create and drop ephemeral roles.
# It is given no direct database access — those grants live on the per-app
# base roles that vault_manager is allowed to grant.
#
# Usage:
#   VAULT_POSTGRES_PASSWORD=<strong-password> ./scripts/create-vault-manager.sh

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
VAULT_PASSWORD="${VAULT_POSTGRES_PASSWORD:?VAULT_POSTGRES_PASSWORD must be set}"

if [[ "$VAULT_PASSWORD" == *"'"* || "$VAULT_PASSWORD" == *'$'* ]]; then
    echo "Error: VAULT_POSTGRES_PASSWORD must not contain single-quote or dollar-sign characters." >&2
    exit 1
fi

PSQL=(
    docker compose -f "$PROJECT_DIR/docker-compose.yml"
    exec -T postgres
    psql -U "$POSTGRES_USER"
)

echo "Creating vault_manager role..."

"${PSQL[@]}" <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'vault_manager') THEN
        CREATE ROLE vault_manager
            WITH LOGIN PASSWORD '${VAULT_PASSWORD}'
            CREATEROLE
            NOCREATEDB
            NOINHERIT;
    ELSE
        ALTER ROLE vault_manager WITH PASSWORD '${VAULT_PASSWORD}';
    END IF;
END \$\$;
SQL

echo "vault_manager role ready."
echo ""
echo "For each database Vault will manage, grant vault_manager the base role:"
echo "  GRANT \"<app_role>_base\" TO vault_manager WITH ADMIN OPTION;"
