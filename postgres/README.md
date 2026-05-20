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
├── docker/
│   └── entrypoint.sh           # container entrypoint: generates pg_hba allowlist from env
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

SSL is disabled by default.  Cert filenames follow the **certbot / Let's Encrypt convention** (`fullchain.pem`, `privkey.pem`) so the same config works for both dev self-signed certs and production Let's Encrypt certs.  A separate CA file is not needed — `fullchain.pem` includes the full chain and clients verify against their trusted public CA roots.

### Development (self-signed certificates)

```bash
./scripts/generate-dev-certs.sh
chmod 600 certs/privkey.pem
# Linux only — Docker Desktop manages file ownership through a VM:
sudo chown 999:999 certs/privkey.pem
```

The script produces `fullchain.pem` (cert + dev CA chain) and `privkey.pem`, plus `ca.crt` which dev clients need to verify the self-signed server cert.

### Production (certbot / Let's Encrypt)

Certbot writes live certificates to `/etc/letsencrypt/live/<domain>/`.  Symlink or copy them into `certs/`:

```bash
# As root on the host — copy so Docker can read without running as root:
install -m 644 /etc/letsencrypt/live/db.example.com/fullchain.pem certs/fullchain.pem
install -m 600 /etc/letsencrypt/live/db.example.com/privkey.pem   certs/privkey.pem
# Linux: the postgres process (UID 999) must own the key:
chown 999:999 certs/privkey.pem
```

Add a deploy hook so certbot refreshes the copies on renewal:

```bash
# /etc/letsencrypt/renewal-hooks/deploy/postgres-certs.sh
#!/bin/bash
install -m 644 /etc/letsencrypt/live/db.example.com/fullchain.pem \
    /path/to/postgres/certs/fullchain.pem
install -m 600 /etc/letsencrypt/live/db.example.com/privkey.pem \
    /path/to/postgres/certs/privkey.pem
chown 999:999 /path/to/postgres/certs/privkey.pem
docker compose -f /path/to/postgres/docker-compose.yml restart
```

### Enabling SSL in config

In `config/postgresql.conf`, uncomment:

```
ssl          = on
ssl_cert_file = '/etc/postgresql/certs/fullchain.pem'
ssl_key_file  = '/etc/postgresql/certs/privkey.pem'
```

In `config/pg_hba.conf`, uncomment the `hostssl` line:

```
hostssl all  all  0.0.0.0/0  scram-sha-256
```

Then restart: `docker compose restart`

## Connecting other services — Docker vs. external

PostgreSQL listens on all interfaces (`listen_addresses = '*'`), but **authentication rules in `pg_hba.conf` enforce SSL selectively by source address**.  This lets Docker-internal services connect without SSL while requiring SSL for any connection arriving from outside the Docker network.

```
# pg_hba.conf evaluation order (first match wins):
host     ...  172.16.0.0/12  scram-sha-256   ← Docker bridge, no SSL required
host     ...  10.0.0.0/8     scram-sha-256   ← Docker bridge, no SSL required
hostssl  ...  0.0.0.0/0      scram-sha-256   ← everything else, SSL required
```

`hostssl` only matches connections that are actually using SSL — a non-SSL connection from outside the Docker subnets will not match any rule and will be rejected.

### Docker services on the same host (shared network)

This is the recommended path for same-host stacks.  The `postgres_net` network is **defined and created by this compose file** — no manual `docker network create` needed.  Other stacks join it as an external network and reach Postgres by the service name `postgres` without SSL.

In the application stack's `docker-compose.yml`:

```yaml
networks:
  postgres_net:
    external: true      # created by the postgres stack, not by this file

services:
  app:
    networks:
      - postgres_net
    environment:
      # Connect by service name — no SSL needed over the Docker bridge
      DATABASE_URL: postgresql://myapp_role:password@postgres:5432/myapp
```

The network name defaults to `postgres_net`.  If you changed `POSTGRES_NETWORK` in `.env`, use that name here instead.

> **Note:** `docker compose down` will attempt to remove `postgres_net`.  If application containers are still attached it will warn and leave the network in place — a useful reminder not to tear down Postgres while apps are running.

### External clients (non-Docker)

External access is controlled by two independent settings that work together:

**1. Which interface to expose** — set `POSTGRES_BIND` in `.env`:

```bash
# Specific public IP (recommended):
POSTGRES_BIND=203.0.113.10

# All interfaces (less precise, but acceptable behind a firewall):
POSTGRES_BIND=0.0.0.0
```

**2. Which source networks are allowed** — set `POSTGRES_ALLOWED_NETWORKS` in `.env`:

```bash
# Single trusted host:
POSTGRES_ALLOWED_NETWORKS=203.0.113.42/32

# Office + VPN:
POSTGRES_ALLOWED_NETWORKS=203.0.113.0/24,198.51.100.128/25
```

At container startup, `docker/entrypoint.sh` reads `POSTGRES_ALLOWED_NETWORKS` and generates `hostssl` rules in `/tmp/pg_hba_external.conf`, which `pg_hba.conf` pulls in via `@include_if_exists`.  If the variable is empty or unset, no external connections are permitted — the safe default.

To update the allowlist: edit `POSTGRES_ALLOWED_NETWORKS` in `.env` and run `docker compose restart`.

> SSL must also be configured in `config/postgresql.conf` for `hostssl` rules to take effect.

### Both at the same time

The two mechanisms are fully independent and work simultaneously with no conflict:

| Client | Path | SSL |
|--------|------|-----|
| Docker container on `postgres_net` | `postgres:5432` (service name) | not required — matched by subnet rule in `pg_hba.conf` |
| External host / Vault / admin tool | `<host-ip>:5432` (exposed port) | required — matched by generated `hostssl` rule; source must be in `POSTGRES_ALLOWED_NETWORKS` |
| External host not in allowlist | `<host-ip>:5432` | rejected — no matching rule |

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
- [ ] Enable SSL: deploy certbot certs (`fullchain.pem`, `privkey.pem`) and uncomment ssl lines in `postgresql.conf` and `pg_hba.conf`
- [ ] Add a certbot deploy hook to refresh `certs/` and restart the container on renewal
- [ ] Use a shared Docker network for same-host app access (no port exposure needed)
- [ ] For external access, set `POSTGRES_BIND` to a specific IP and `POSTGRES_ALLOWED_NETWORKS` to the exact CIDRs that need access
- [ ] Tighten the Docker subnet ranges in `pg_hba.conf` to match your actual network
- [ ] Schedule regular backups and verify restore works
- [ ] Review and tune `postgresql.conf` for your workload (connections, memory)
- [ ] Set up log shipping or a log aggregator (the container writes to stderr)
- [ ] If using Vault, rotate the `vault_manager` password after initial setup
