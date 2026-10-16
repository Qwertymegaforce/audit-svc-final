#!/bin/sh
: "${ANSIBLE_VAULT_KEY:?ANSIBLE_VAULT_KEY is not set}"
printf '%s\n' "$ANSIBLE_VAULT_KEY"
