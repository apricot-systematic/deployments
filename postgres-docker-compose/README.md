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
├── secrets/                    # mounted secret files (not committed)
│   └── .gitkeep                #   db_superuser_username, db_superuser_password, backup.env
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

The superuser credentials are delivered as **mounted docker secrets**, so the
secret files must exist before the first `docker compose up` (compose fails to
start a service whose `secrets:` source file is missing).

```bash
cp .env.example .env                                   # non-secret config

# Superuser credentials -> mounted secret files (no trailing newline needed;
# the postgres image strips it):
mkdir -p secrets
printf 'postgres' > secrets/db_superuser_username
openssl rand -base64 24 | tr -d '/+=' | head -c 32 > secrets/db_superuser_password
chmod 600 secrets/db_superuser_*

docker compose up -d
```

The data volume (`postgres_data`) persists across restarts and container recreation.  The `config/` directory is mounted read-only; restart the container to pick up config changes.

> **Note:** Scripts in `init/` run only once, when the data volume is first initialised.  Editing them after the first `docker compose up` has no effect unless the volume is wiped.

## Secrets

Secrets are **never** stored in `.env`.  They are files under `./secrets/`
(gitignored), mounted into the container as docker secrets:

| File                            | Purpose                                                        |
|---------------------------------|---------------------------------------------------------------|
| `secrets/db_superuser_username` | Superuser name -> `POSTGRES_USER_FILE` (required)             |
| `secrets/db_superuser_password` | Superuser password -> `POSTGRES_PASSWORD_FILE` (required)    |
| `secrets/backup.env`            | Backup encryption keys (optional -- see Backup encryption)    |

`POSTGRES_*_FILE` is honored by the postgres image only on **first volume init**;
it seeds the superuser and is not a password-rotation mechanism.  The helper
scripts (`backup.sh`, `restore.sh`, `create-database.sh`) read the superuser name
from `secrets/db_superuser_username` when `POSTGRES_USER` is not set in their
environment.

## Environment variables (`.env`)

`.env` holds non-secret runtime configuration only.

| Variable                    | Default          | Description                                         |
|-----------------------------|------------------|-----------------------------------------------------|
| `POSTGRES_VERSION`          | `17`             | PostgreSQL image tag                                |
| `POSTGRES_DB`               | `postgres`       | Default database created at init                    |
| `POSTGRES_BIND`             | `127.0.0.1`      | IPv4 host interface to bind the port to             |
| `POSTGRES_BIND6`            | `::1`            | IPv6 host interface to bind the port to             |
| `POSTGRES_PORT`             | `5432`           | Host port to expose                                 |
| `POSTGRES_NETWORK`          | `postgres_net`   | Compose network name (change per instance)          |
| `POSTGRES_ALLOWED_NETWORKS` | _(empty)_        | External client CIDRs -> hostssl rules (SSL)        |

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

The script is idempotent: re-running it updates the role's password and leaves an
existing database in place, so it is safe to run from automation.

To use a specific password, pass it as the third argument, or — to keep it out of
the process list — via the `DB_ROLE_PASSWORD` environment variable:

```bash
./scripts/create-database.sh myapp myapp_role 'MyStr0ngPassword'

# Or, without exposing the password in argv:
DB_ROLE_PASSWORD='MyStr0ngPassword' ./scripts/create-database.sh myapp myapp_role
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

Output goes to `./backups/`.  The filename encodes what's inside:

| Filename | Encrypted |
|----------|-----------|
| `myapp_20240115_143000.sql.gz` | No |
| `myapp_20240115_143000_enc_key_2024.sql.gz.enc` | Yes — key ID `key_2024` |

### Restore

The restore script detects encryption automatically from the filename and looks up the correct key — no manual key selection required.

```bash
# Restore into a specific database
./scripts/restore.sh backups/myapp_20240115_143000.sql.gz myapp

# Restore everything from a pg_dumpall backup
./scripts/restore.sh backups/all_20240115_143000.sql.gz

# Encrypted backups work identically — key is found from the filename
./scripts/restore.sh backups/myapp_20240115_143000_enc_key_2024.sql.gz.enc myapp
```

> **Warning:** Restoring into an existing database merges objects.  For a clean restore, drop and recreate the database first:
> ```sql
> DROP DATABASE myapp;
> CREATE DATABASE myapp OWNER myapp_role;
> ```

### Backup encryption

The encryption keys are secrets, so they live in `secrets/backup.env` (sourced
by `backup.sh`/`restore.sh` if present).  Set two variables there to encrypt all
backups before they touch disk:

```bash
# secrets/backup.env  (chmod 600)
# Which key to use for new backups:
BACKUP_ENCRYPTION_KEY_ID=key-2025-01

# All keys — current and retired — as comma-separated id:value pairs:
BACKUP_ENCRYPTION_KEYS=key-2025-01:<base64-key>
```

> For backward compatibility these variables are still honored if set in `.env`,
> but `secrets/backup.env` is preferred so no secret lives in `.env`.

Generate a key: `openssl rand -base64 32 | tr -d '\n'`

Encryption uses AES-256-CBC with PBKDF2 key derivation (600 000 iterations).  The pipeline is `pg_dump | gzip | openssl enc > file` — plaintext is never written to disk.  The key is passed to OpenSSL via an environment variable so it does not appear in the process list.

**Key ID rules:** no colons, commas, or whitespace.  Hyphens are fine.  The ID is embedded in the backup filename (`_enc_<keyid>.sql.gz.enc`).

### Key rotation

`BACKUP_ENCRYPTION_KEYS` holds every key the system has ever used.  `BACKUP_ENCRYPTION_KEY_ID` is just a pointer into that list — changing it switches which key is used for new backups.  Old backups remain readable as long as their key stays in the list.

```bash
# secrets/backup.env -- after rotating from key-2024-01 to key-2025-01:
BACKUP_ENCRYPTION_KEY_ID=key-2025-01
BACKUP_ENCRYPTION_KEYS=key-2025-01:<new-key>,key-2024-01:<old-key>,key-2023-06:<older-key>
```

**Rotation procedure:**
1. Generate a new key: `openssl rand -base64 32 | tr -d '\n'`
2. Append the new entry to `BACKUP_ENCRYPTION_KEYS`
3. Update `BACKUP_ENCRYPTION_KEY_ID` to the new key's ID
4. Done — no keys need to be moved or removed

When restoring, `restore.sh` extracts the key ID from the filename, searches `BACKUP_ENCRYPTION_KEYS` for a matching entry, and decrypts.  If the key is not found it prints exactly what to add to `secrets/backup.env` and exits.

**Retiring old keys:** remove an entry from `BACKUP_ENCRYPTION_KEYS` only when you are certain no remaining backup was encrypted with it.

**Future Vault migration:** the `find_backup_key` logic is isolated in both scripts.  Replacing it with a `vault kv get` call is straightforward — the rest of the backup and restore pipelines are unchanged.

### Scheduled backups

Run `backup.sh` from cron or a systemd timer on the Docker host.  Rotate old backups with:
```bash
find backups/ -name '*.sql.gz' -mtime +30 -delete
find backups/ -name '*.sql.gz.enc' -mtime +30 -delete
```

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

Add a deploy hook so certbot refreshes the copies on renewal.  Certbot runs
every script in `renewal-hooks/deploy/` after **any** renewal and exports
`RENEWED_LINEAGE` (the live dir of the cert that renewed) — filter on it so an
unrelated cert's renewal does not bounce this service:

```bash
# /etc/letsencrypt/renewal-hooks/deploy/postgres-certs.sh
#!/usr/bin/env bash
set -euo pipefail

LINEAGE=/etc/letsencrypt/live/db.example.com
DEST=/path/to/postgres

# When invoked by certbot, act only on this service's own cert.
if [[ -n "${RENEWED_LINEAGE:-}" && "${RENEWED_LINEAGE%/}" != "$LINEAGE" ]]; then
    exit 0
fi

install -m 644 "$LINEAGE/fullchain.pem" "$DEST/certs/fullchain.pem"
install -m 600 -o 999 -g 999 "$LINEAGE/privkey.pem" "$DEST/certs/privkey.pem"
docker compose -f "$DEST/docker-compose.yml" restart
```

### Enabling SSL in config

In `config/postgresql.conf`, uncomment:

```
ssl          = on
ssl_cert_file = '/etc/ssl/postgresql/fullchain.pem'
ssl_key_file  = '/etc/ssl/postgresql/privkey.pem'
```

In `config/pg_hba.conf`, uncomment the `hostssl` line:

```
hostssl all  all  0.0.0.0/0  scram-sha-256
```

Then restart: `docker compose restart`

## Connecting other services — Docker vs. external

PostgreSQL listens on all interfaces (`listen_addresses = '*'`), but **`pg_hba.conf` enforces SSL selectively by source address**.  Docker-internal services connect without SSL; external connections require SSL and must come from a declared network.  Both work simultaneously with no conflict.

At container startup, `docker/entrypoint.sh` reads the kernel routing table and generates two `pg_hba.conf` include files in `/tmp/`:

| File | Generated from | Rule type |
|------|----------------|-----------|
| `pg_hba_docker.conf` | kernel routing table — automatic, IPv4 + IPv6 | `host` — no SSL required |
| `pg_hba_external.conf` | `POSTGRES_ALLOWED_NETWORKS` in `.env` | `hostssl` — SSL required |

### Docker services on the same host (shared network)

No configuration needed beyond joining the network.  The `postgres_net` network is **created by this compose file** — no manual `docker network create` required.  At startup the entrypoint reads the directly-attached kernel routes (both IPv4 and IPv6) and writes a `host` rule for each, so any Docker service sharing a network with this container can connect without SSL.

In the application stack's `docker-compose.yml`:

```yaml
networks:
  postgres_net:
    external: true      # created by the postgres stack, not this file

services:
  app:
    networks:
      - postgres_net
    environment:
      # Connect by service name — no SSL needed over the Docker bridge
      DATABASE_URL: postgresql://myapp_role:password@postgres:5432/myapp
```

The network name defaults to `postgres_net`.  If you changed `POSTGRES_NETWORK` in `.env`, use that name here instead.

> **Note:** `docker compose down` will attempt to remove `postgres_net`.  If application containers are still attached it will warn and leave the network in place — a useful signal not to tear down Postgres while apps are running.

### External clients (non-Docker) — IPv4 and IPv6

Three settings work together.  **Do not list Docker subnets in `POSTGRES_ALLOWED_NETWORKS`** — those are handled automatically.

**1. Which interfaces to expose:**

```bash
# IPv4 — specific public IP (recommended) or 0.0.0.0 for all interfaces:
POSTGRES_BIND=10.0.1.10

# IPv6 — :: listens on all IPv6 interfaces (Tailscale, LAN, etc.):
POSTGRES_BIND6=::
```

**2. Which external networks are trusted** (`POSTGRES_ALLOWED_NETWORKS`):

Both IPv4 and IPv6 CIDRs are accepted in the same comma-separated list:

```bash
POSTGRES_ALLOWED_NETWORKS=10.0.1.0/24,100.64.0.0/10,fd7a:115c:a1e0::/48
```

At startup the entrypoint writes one `hostssl` rule per CIDR.  A connection whose source address does not match any rule is rejected — no rule, no access.

To update the allowlist: edit `POSTGRES_ALLOWED_NETWORKS` in `.env` and run `docker compose restart`.

> SSL must be configured in `config/postgresql.conf` for `hostssl` rules to take effect.

#### Tailscale

Tailscale assigns each node both an IPv4 address (`100.64.0.0/10`) and an IPv6 address (`fd7a:115c:a1e0::/48`).  Include both if you want clients to be able to use either.  Set `POSTGRES_BIND6=::` so the container's IPv6 port binding covers the Tailscale interface on the host.

Tailscale's WireGuard layer already encrypts all traffic, so the PostgreSQL SSL layer is redundant protection — but it keeps the auth model consistent and costs nothing in practice.

#### Inspecting the generated rules

After starting the container, confirm what was generated:

```bash
docker compose exec postgres cat /tmp/pg_hba_docker.conf
docker compose exec postgres cat /tmp/pg_hba_external.conf
```

### Summary

| Client | Path | SSL enforced |
|--------|------|-------------|
| Docker service on `postgres_net` | `postgres:5432` (service name) | No — subnet auto-detected |
| External IPv4 host in allowlist | `<host-ip>:5432` | Yes — `hostssl` rule |
| External IPv6 host in allowlist | `[<host-ipv6>]:5432` | Yes — `hostssl` rule |
| Any host **not** in allowlist | either port | Rejected — no matching rule |

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

- [ ] Set a strong superuser password in `secrets/db_superuser_password` (mode `0600`) and store a copy in your secrets manager
- [ ] Enable SSL: deploy certbot certs (`fullchain.pem`, `privkey.pem`) and uncomment ssl lines in `postgresql.conf` and `pg_hba.conf`
- [ ] Add a certbot deploy hook to refresh `certs/` and restart the container on renewal
- [ ] Use a shared Docker network for same-host app access (no port exposure needed)
- [ ] For external access, set `POSTGRES_BIND` to a specific IP and `POSTGRES_ALLOWED_NETWORKS` to the exact CIDRs that need access
- [ ] Tighten the Docker subnet ranges in `pg_hba.conf` to match your actual network
- [ ] Enable backup encryption: set `BACKUP_ENCRYPTION_KEY_ID` and `BACKUP_ENCRYPTION_KEYS` in `secrets/backup.env`
- [ ] Schedule regular backups and verify encrypted restore works end-to-end
- [ ] Store retired backup keys (`BACKUP_KEY_*`) securely — losing them makes old backups unreadable
- [ ] Review and tune `postgresql.conf` for your workload (connections, memory)
- [ ] Set up log shipping or a log aggregator (the container writes to stderr)
- [ ] If using Vault, rotate the `vault_manager` password after initial setup
