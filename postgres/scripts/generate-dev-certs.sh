#!/usr/bin/env bash
#
# Generate self-signed SSL certificates for development use.
#
# Do NOT use these in production — get certificates from a real CA
# (e.g., Let's Encrypt, your organisation's PKI, or a managed service).
#
# After running this script:
#   1. Set ownership so the PostgreSQL process (UID 999) can read the key:
#        sudo chown 999:999 certs/server.key
#   2. Enable SSL in config/postgresql.conf (uncomment the ssl lines).
#   3. Enable hostssl in config/pg_hba.conf (uncomment the hostssl line).
#   4. Restart the container: docker compose restart

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
openssl genrsa -out "$CERTS_DIR/server.key" 4096 2>/dev/null
openssl req -new \
    -key "$CERTS_DIR/server.key" \
    -out "$CERTS_DIR/server.csr" \
    -subj "/CN=localhost/O=Dev/C=US"

# Sign with SANs so modern clients accept it.
openssl x509 -req -days 3650 \
    -in "$CERTS_DIR/server.csr" \
    -CA "$CERTS_DIR/ca.crt" \
    -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERTS_DIR/server.crt" \
    -extfile <(printf 'subjectAltName=IP:127.0.0.1,DNS:localhost')

# Clean up intermediaries.
rm -f "$CERTS_DIR/server.csr" "$CERTS_DIR/ca.srl"

# Set file permissions.  The private key must not be world-readable.
chmod 600 "$CERTS_DIR/server.key" "$CERTS_DIR/ca.key"
chmod 644 "$CERTS_DIR/server.crt" "$CERTS_DIR/ca.crt"

echo ""
echo "Generated in $CERTS_DIR:"
echo "  ca.crt      — CA certificate (distribute to clients for server verification)"
echo "  ca.key      — CA private key (keep secret, not needed at runtime)"
echo "  server.crt  — Server certificate"
echo "  server.key  — Server private key"
echo ""
echo "IMPORTANT: The server.key must be owned by the postgres user (UID 999):"
echo "  sudo chown 999:999 $CERTS_DIR/server.key"
echo ""
echo "Then enable SSL in config/postgresql.conf and config/pg_hba.conf."
