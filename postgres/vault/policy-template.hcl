# Vault policy template — grants an application the ability to read dynamic
# PostgreSQL credentials and renew them before they expire.
#
# Replace APP_ROLE with the role name you passed to vault-setup.sh.
#
# Apply with:
#   vault policy write myapp vault/policy-template.hcl

# Read (generate) credentials for this application's database role.
path "database/creds/APP_ROLE" {
  capabilities = ["read"]
}

# Renew leases so long-running processes can extend credential lifetime.
path "sys/leases/renew" {
  capabilities = ["update"]
}

# Allow the application to look up its own lease for expiry checking.
path "sys/leases/lookup" {
  capabilities = ["update"]
}
