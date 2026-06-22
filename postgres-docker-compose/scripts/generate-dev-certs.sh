#!/usr/bin/env bash
#
# Generate self-signed SSL certificates for development use.
#
# Output filenames match the certbot / Let's Encrypt convention so the same
# postgresql.conf works in both dev and production:
#   fullchain.pem — server cert + CA chain (analogous to certbot's fullchain.pem)
#   privkey.pem   — server private key    (analogous to certbot's privkey.pem)
#
# A local CA is also generated so dev clients can verify the server certificate.
# In production the CA is a public root already trusted by clients, so ca.crt
# is not deployed there.
#
# Do NOT use these certificates in production — obtain real certificates from
# Let's Encrypt (certbot), your organisation's PKI, or another CA.
#
# After running this script:
#   1. chmod 600 certs/privkey.pem
#      Linux: sudo chown 999:999 certs/privkey.pem
#   2. Uncomment the ssl lines in config/postgresql.conf.
#   3. Uncomment the hostssl line in config/pg_hba.conf.
#   4. docker compose restart

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$(dirname "$SCRIPT_DIR")/certs"

mkdir -p "$CERTS_DIR"

echo "Generating self-signed CA..."
openssl genrsa -out "$CERTS_DIR/ca.key" 4096 2>/dev/null
openssl req -new -x509 -days 3650 \
    -key "$CERTS_DIR/ca.key" \
    -out "$CERTS_DIR/ca.crt" \
    -subj "/CN=PostgreSQL Dev CA/O=Dev/C=US"

echo "Generating server certificate..."
openssl genrsa -out "$CERTS_DIR/privkey.pem" 4096 2>/dev/null
openssl req -new \
    -key "$CERTS_DIR/privkey.pem" \
    -out "$CERTS_DIR/server.csr" \
    -subj "/CN=localhost/O=Dev/C=US"

# Sign with SANs so modern TLS clients accept it.
openssl x509 -req -days 3650 \
    -in "$CERTS_DIR/server.csr" \
    -CA "$CERTS_DIR/ca.crt" \
    -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERTS_DIR/server.crt" \
    -extfile <(printf 'subjectAltName=IP:127.0.0.1,DNS:localhost')

# Produce fullchain.pem = server cert + CA cert, matching certbot's layout.
cat "$CERTS_DIR/server.crt" "$CERTS_DIR/ca.crt" > "$CERTS_DIR/fullchain.pem"

# Clean up intermediaries.
rm -f "$CERTS_DIR/server.csr" "$CERTS_DIR/server.crt" "$CERTS_DIR/ca.srl"

# Set file permissions.  The private key must not be world-readable.
chmod 600 "$CERTS_DIR/privkey.pem" "$CERTS_DIR/ca.key"
chmod 644 "$CERTS_DIR/fullchain.pem" "$CERTS_DIR/ca.crt"

echo ""
echo "Generated in $CERTS_DIR:"
echo "  fullchain.pem — server cert + CA chain (used by PostgreSQL)"
echo "  privkey.pem   — server private key (keep secret)"
echo "  ca.crt        — CA certificate (give to dev clients for server verification)"
echo "  ca.key        — CA private key (keep secret, not needed at runtime)"
echo ""
echo "Set permissions so PostgreSQL (UID 999) can read the key:"
echo "  chmod 600 $CERTS_DIR/privkey.pem"
echo "  # Linux only:"
echo "  sudo chown 999:999 $CERTS_DIR/privkey.pem"
echo ""
echo "Then uncomment the ssl lines in config/postgresql.conf"
echo "and the hostssl line in config/pg_hba.conf, then: docker compose restart"
