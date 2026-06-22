# Deployment Templates

This repository is the canonical description of how we deploy our services.
Each top-level directory is a self-contained template for one service: the
config, scripts, and compose files needed to stand it up, plus a README that
documents the edge cases and options we care about.

Real deployments will drift from these templates -- that is fine. The templates
are the skeleton we copy from and the reference we keep current as things
change. Their second job is to keep deployments *consistent*: every service
handles config, secrets, TLS, networking, and backups the same way, so once you
know one you know them all.

## Using a template

Copy the directory into your deployment location and customize it there. Do not
deploy from inside this repo.

```bash
cp -r postgres-docker-compose /srv/postgres
cd /srv/postgres
cp .env.example .env          # then edit
# follow that template's README from here
```

Each template's own README is the authoritative guide for that service. This
file only covers the conventions they share.

## Naming: `<service>-<layer>`

A template is named for the service it deploys and the *layer* it deploys on,
because the same service can run on different layers and the differences matter:

- `*-docker-compose` -- a Docker Compose stack
- `*-helm` -- a Helm chart for Kubernetes
- `*-native` -- installed and run directly on the host

So `postgres-docker-compose` is Postgres on Compose; a future `postgres-native`
or `postgres-helm` would deploy the same service a different way. Pick the layer
that matches where the rest of that deployment runs.

## Templates

| Template | Status | Description |
|----------|--------|-------------|
| [`postgres-docker-compose`](postgres-docker-compose/) | Ready | PostgreSQL via Docker Compose: secrets, TLS, network-scoped auth, encrypted backups, Vault dynamic credentials |
| `redis` | Planned | placeholder |
| `telegraf` | Planned | placeholder |

## Shared conventions

These hold across every template. New templates should follow them.

- **`.env` is non-secret config only.** Copy `.env.example` to `.env` and edit.
  Never put credentials or keys in `.env`.
- **Secrets live in `secrets/`.** That directory is gitignored and its files are
  mounted into the container as Docker secrets. Create the secret files before
  the first `docker compose up` -- Compose refuses to start a service whose
  secret source file is missing.
- **TLS certs live in `certs/`** (gitignored) and use the certbot / Let's
  Encrypt filenames `fullchain.pem` and `privkey.pem`, so the same config works
  for self-signed dev certs and production certs.
- **Service-to-service traffic stays within the deployment layer.** Services on
  the same layer use that layer's private networking -- a shared Docker network
  for Compose, cluster networking for Kubernetes, the host/LAN for native -- and
  do not expose a port to do it. Only clients *outside* the layer connect over a
  published, TLS-protected endpoint from an explicitly allowed network.
- **Persistent data lives in named Docker volumes**, which survive container
  recreation.
- **Operational tasks are scripts in `scripts/`** (backup, restore, provisioning)
  and are written to be idempotent and safe to run from automation.
- **Config is mounted read-only**; change a file under `config/` and restart the
  container to apply it.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
