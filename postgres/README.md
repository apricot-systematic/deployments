# PostgreSQL Service Template

A Docker Compose template for a self-contained PostgreSQL service.  It is designed to be copied into a deployment directory and customised for each environment.

## Directory layout

```
postgres/
├── docker-compose.yml          # service definition
├── .env.example                # runtime config template (copy to .env)
├── config/
│   ├── postgresql.conf         # main PostgreSQL config (mounted read-only)
│   ├── pg_hba.conf             # client authentication rules
│   └── pg_ident.conf           # username maps (usually empty)
├── certs/                      # SSL certificates (not committed)
│   └── .gitkeep
├── init/
│   └── 01-bootstrap.sql        # runs once on first container init
├── scripts/
│   ├── create-database.sh      # provision a new database + role
│   ├── create-vault-manager.sh # create the vault_manager PostgreSQL role
│   ├── backup.sh               # dump one or all databases
│   ├── restore.sh              # restore from a backup
│   ├── generate-dev-certs.sh   # generate self-signed certs (dev only)
│   └── vault-setup.sh          # configure Vault database secrets engine
└── vault/
    └── policy-template.hcl     # Vault policy template for app credential access
```

## Quick start

```bash
cp .env.example .env
# Edit .env and set POSTGRES_USER and POSTGRES_PASSWORD
docker compose up -d
```

The data volume (`postgres_data`) persists across restarts and container recreation.  The `config/` directory is mounted read-only; restart the container to pick up config changes.

> **Note:** Scripts in `init/` run only once, when the data volume is first initialised.  Editing them after the first `docker compose up` has no effect unless the volume is wiped.

## Environment variables (`.env`)

| Variable           | Default              | Description                                    |
|--------------------|----------------------|------------------------------------------------|
| `POSTGRES_VERSION` | `17`                 | PostgreSQL image tag                           |
| `POSTGRES_USER`    | _(required)_         | Superuser username                             |
| `POSTGRES_PASSWORD`| _(required)_         | Superuser password                             |
| `POSTGRES_DB`      | `postgres`           | Default database created at init               |
| `POSTGRES_BIND`    | `127.0.0.1`          | Host interface to bind the port to             |
| `POSTGRES_PORT`    | `5432`               | Host port to expose                            |

Set `POSTGRES_BIND=0.0.0.0` to expose the port on all interfaces (e.g., when other hosts must reach this service directly).

## Creating databases for applications

Each application should have its own database and a dedicated role that can access only that database.

```bash
./scripts/create-database.sh myapp myapp_role
```

This creates:
- Database `myapp` owned by `myapp_role`
- Role `myapp_role` with login, scoped to `myapp` only
- Public schema locked down (no `CREATE` for arbitrary users)

The generated password is printed once and not stored — save it in your secrets manager.

To use a specific password:

```bash
./scripts/create-database.sh myapp myapp_role 'MyStr0ngPassword'
```

## Data persistence and backups

Data lives in the `postgres_data` Docker named volume — it survives container recreation.

### Backup

```bash
# All databases
./scripts/backup.sh

# One database
./scripts/backup.sh myapp
```

Output goes to `./backups/` with a timestamp in the filename (e.g., `myapp_20240115_143000.sql.gz`).

### Restore

```bash
# Restore into a specific database
./scripts/restore.sh backups/myapp_20240115_143000.sql.gz myapp

# Restore everything from a pg_dumpall backup
./scripts/restore.sh backups/all_20240115_143000.sql.gz
```

> **Warning:** Restoring into an existing database merges objects.  For a clean restore, drop and recreate the database first:
> ```sql
> DROP DATABASE myapp;
> CREATE DATABASE myapp OWNER myapp_role;
> ```

### Scheduled backups

Run `backup.sh` from cron or a systemd timer on the Docker host.  Rotate old backups with `find backups/ -name '*.sql.gz' -mtime +30 -delete`.

## SSL / TLS

SSL is disabled by default.  To enable it:

### Development (self-signed certificates)

```bash
./scripts/generate-dev-certs.sh
# Set key ownership so PostgreSQL (UID 999) can read it:
sudo chown 999:999 certs/server.key
```

### Production (real certificates)

Place your certificates in `certs/`:

| File         | Contents                                |
|--------------|-----------------------------------------|
| `server.crt` | Server certificate (+ intermediate chain if needed) |
| `server.key` | Server private key                      |
| `ca.crt`     | CA certificate (optional, for client cert auth) |

Set permissions:

```bash
chmod 600 certs/server.key
chmod 644 certs/server.crt certs/ca.crt
# Linux hosts: set ownership so the postgres process (UID 999) can read the key.
sudo chown 999:999 certs/server.key
# macOS / Docker Desktop: ownership of bind-mounted files is managed by the VM —
# chmod 600 is usually sufficient; chown to 999 may have no effect.
```

Then in `config/postgresql.conf`, uncomment the SSL block:

```
ssl          = on
ssl_cert_file = '/etc/postgresql/certs/server.crt'
ssl_key_file  = '/etc/postgresql/certs/server.key'
ssl_ca_file   = '/etc/postgresql/certs/ca.crt'
```

And in `config/pg_hba.conf`, replace the remote `host` rule with `hostssl`:

```
hostssl all  all  0.0.0.0/0  scram-sha-256
```

Restart the container: `docker compose restart`

## Connecting other Docker Compose stacks

### Option 1 — exposed host port (different hosts or simple setups)

Set `POSTGRES_BIND=0.0.0.0` (or a specific interface) in `.env`.  Other services connect using the Docker host's IP and `POSTGRES_PORT`.

### Option 2 — shared Docker network (same host, cross-stack)

Add an external network to this compose file:

```yaml
networks:
  shared_db:
    external: true

services:
  postgres:
    networks:
      - shared_db
```

Create it once:

```bash
docker network create shared_db
```

In the application's `docker-compose.yml`:

```yaml
networks:
  shared_db:
    external: true

services:
  app:
    networks:
      - shared_db
    environment:
      DATABASE_URL: postgresql://myapp_role:password@postgres:5432/myapp
```

Using a shared network avoids exposing the port on the host and lets containers reach Postgres by service name (`postgres`).

## HashiCorp Vault integration

Vault's [database secrets engine](https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql) issues short-lived, automatically-rotated credentials.  Vault itself runs externally — this template only provisions the PostgreSQL side.

### SSL prerequisite

`vault-setup.sh` defaults to `sslmode=disable` so the initial setup works before SSL is configured.  Once SSL is enabled (see [SSL / TLS](#ssl--tls) above), set `POSTGRES_SSLMODE=require` in `.env` and re-run `vault-setup.sh` to update the Vault connection config.

Also set `POSTGRES_HOST` in `.env` to the address Vault uses to reach this PostgreSQL instance — `127.0.0.1` works only if Vault runs on the same host.  On Docker Desktop use `host.docker.internal`.

### Setup sequence

**1. Create the application database and base role**

```bash
./scripts/create-database.sh myapp myapp_role_base
```

The base role holds the actual privileges.  Vault's dynamic users inherit from it.

**2. Create the `vault_manager` PostgreSQL role**

```bash
VAULT_POSTGRES_PASSWORD='StrongPassword' ./scripts/create-vault-manager.sh
```

**3. Allow `vault_manager` to grant the base role**

```sql
-- Run as superuser:
GRANT "myapp_role_base" TO vault_manager WITH ADMIN OPTION;
```

**4. Configure the Vault secrets engine**

```bash
export VAULT_ADDR=https://vault.example.com:8200
export VAULT_TOKEN=...
export VAULT_POSTGRES_PASSWORD='StrongPassword'
./scripts/vault-setup.sh myapp myapp_role
```

This registers the connection and creates a Vault role (`myapp_role`) that issues dynamic credentials inheriting from `myapp_role_base`.

**5. Apply the Vault policy for your application**

Edit `vault/policy-template.hcl` — replace `APP_ROLE` with `myapp_role` — then:

```bash
vault policy write myapp vault/policy-template.hcl
```

**6. Test**

```bash
vault read database/creds/myapp_role
```

### Dynamic credential flow

```
Application → Vault (reads database/creds/myapp_role)
Vault → PostgreSQL (CREATE ROLE v-xxx INHERIT; GRANT myapp_role_base TO v-xxx)
Vault → Application (returns username v-xxx, password, lease)
Application → PostgreSQL (connects as v-xxx)
Lease expires → Vault → PostgreSQL (DROP ROLE v-xxx)
```

## Configuration tuning

`config/postgresql.conf` ships with only the settings that must differ from defaults for a networked container:

- `listen_addresses = '*'`
- HBA and ident file paths
- Basic logging (`log_connections`, `log_disconnections`, log prefix)

For environment-specific tuning (memory, connections, WAL settings) add the parameters to `config/postgresql.conf` after copying this template.  Refer to the [PostgreSQL configuration documentation](https://www.postgresql.org/docs/current/runtime-config.html) and tools like [PGTune](https://pgtune.leopard.in.ua/) for sizing guidance.

## Production checklist

- [ ] Set a strong `POSTGRES_PASSWORD` and store it in a secrets manager
- [ ] Enable SSL and provide real certificates from a CA
- [ ] Bind to a specific interface (`POSTGRES_BIND`), not `0.0.0.0` unless necessary
- [ ] Schedule regular backups and verify restore works
- [ ] Set `POSTGRES_BIND=127.0.0.1` and use a shared Docker network for app access
- [ ] Lock `pg_hba.conf` to the minimum required address ranges
- [ ] Review and tune `postgresql.conf` for your workload
- [ ] Set up log shipping or a log aggregator (the container writes to stderr)
- [ ] If using Vault, rotate the `vault_manager` password after initial setup
