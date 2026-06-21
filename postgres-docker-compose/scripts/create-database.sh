#!/usr/bin/env bash
#
# Create a new database with a dedicated, least-privilege role.
#
# Usage:
#   ./scripts/create-database.sh <db_name> <role_name> [password]
#
# If password is omitted a random one is generated.  The role can connect to
# <db_name> only — it has no access to other databases.

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

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <db_name> <role_name> [password]" >&2
    exit 1
fi

DB_NAME="$1"
ROLE_NAME="$2"
PASSWORD="${3:-$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)}"

# Guard against characters that would break the SQL literal or be bash-expanded.
if [[ "$PASSWORD" == *"'"* || "$PASSWORD" == *'$'* ]]; then
    echo "Error: password must not contain single-quote or dollar-sign characters." >&2
    exit 1
fi

PSQL=(
    docker compose -f "$PROJECT_DIR/docker-compose.yml"
    exec -T postgres
    psql -U "$POSTGRES_USER"
)

echo "Creating role '$ROLE_NAME' and database '$DB_NAME'..."

# Create the role (idempotent — updates password if it already exists).
"${PSQL[@]}" <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${ROLE_NAME}') THEN
        CREATE ROLE "${ROLE_NAME}"
            WITH LOGIN PASSWORD '${PASSWORD}'
            NOCREATEDB
            NOCREATEROLE
            NOINHERIT;
    ELSE
        ALTER ROLE "${ROLE_NAME}" WITH PASSWORD '${PASSWORD}';
    END IF;
END \$\$;

CREATE DATABASE "${DB_NAME}" OWNER "${ROLE_NAME}";
SQL

# Connect to the new database to lock down its schema permissions.
"${PSQL[@]}" -d "$DB_NAME" <<SQL
-- Prevent any user from creating objects in public unless explicitly granted.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE "${DB_NAME}" FROM PUBLIC;

-- Grant only what this role needs.
GRANT CONNECT ON DATABASE "${DB_NAME}" TO "${ROLE_NAME}";
GRANT USAGE, CREATE ON SCHEMA public TO "${ROLE_NAME}";

-- Ensure the role owns all future objects it creates (default privileges).
ALTER DEFAULT PRIVILEGES FOR ROLE "${ROLE_NAME}" IN SCHEMA public
    GRANT ALL PRIVILEGES ON TABLES TO "${ROLE_NAME}";
ALTER DEFAULT PRIVILEGES FOR ROLE "${ROLE_NAME}" IN SCHEMA public
    GRANT ALL PRIVILEGES ON SEQUENCES TO "${ROLE_NAME}";
ALTER DEFAULT PRIVILEGES FOR ROLE "${ROLE_NAME}" IN SCHEMA public
    GRANT ALL PRIVILEGES ON FUNCTIONS TO "${ROLE_NAME}";
SQL

echo ""
echo "Done."
echo ""
echo "  Database : ${DB_NAME}"
echo "  Role     : ${ROLE_NAME}"
echo "  Password : ${PASSWORD}"
echo ""
echo "  DSN: postgresql://${ROLE_NAME}:${PASSWORD}@127.0.0.1:${POSTGRES_PORT:-5432}/${DB_NAME}"
echo ""
echo "Store the password securely. It will not be shown again."
