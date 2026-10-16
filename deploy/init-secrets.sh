#!/bin/sh
set -eu
cd "$(dirname "$0")"

VAULT=inventories/prom/group_vars/all/vault.yml
if [ -e "$VAULT" ]; then
  echo "$VAULT already exists, refusing to overwrite" >&2
  exit 1
fi

if [ -z "${ANSIBLE_VAULT_KEY:-}" ]; then
  ANSIBLE_VAULT_KEY=$(openssl rand -hex 32)
  export ANSIBLE_VAULT_KEY
  echo "Ключ ansible-vault (сохраните, в репозиторий не кладите):"
  echo "$ANSIBLE_VAULT_KEY"
fi

umask 077
cat >"$VAULT" <<EOF
---
vault_postgres_password: "$(openssl rand -hex 24)"
vault_audit_db_password: "$(openssl rand -hex 24)"
EOF

ansible-vault encrypt --vault-password-file ./vault-pass.sh "$VAULT"
echo "Создан зашифрованный $VAULT"
