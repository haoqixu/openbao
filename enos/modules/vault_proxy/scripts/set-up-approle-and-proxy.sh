#!/usr/bin/env bash
# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0


set -e

binpath=${VAULT_INSTALL_DIR}/vault

fail() {
  echo "$1" 1>&2
  return 1
}

test -x "$binpath" || fail "unable to locate vault binary at $binpath"

export VAULT_ADDR='http://127.0.0.1:8200'
[[ -z "$VAULT_TOKEN" ]] && fail "VAULT_TOKEN env variable has not been set"

# If approle was already enabled, disable it as we're about to re-enable it (the || true is so we don't fail if it doesn't already exist)
$binpath auth disable approle || true

$binpath auth enable approle

$binpath write auth/approle/role/proxy-role secret_id_ttl=700h token_num_uses=1000 token_ttl=600h token_max_ttl=700h secret_id_num_uses=1000

ROLEID=$($binpath read --format=json auth/approle/role/proxy-role/role-id   | jq -r '.data.role_id')

if [[ "$ROLEID" == '' ]]; then
  fail "expected ROLEID to be nonempty, but it is empty"
fi

SECRETID=$($binpath write -f --format=json  auth/approle/role/proxy-role/secret-id  | jq -r '.data.secret_id')

if [[ "$SECRETID" == '' ]]; then
  fail "expected SECRETID to be nonempty, but it is empty"
fi

echo "$ROLEID" > /tmp/role-id
echo "$SECRETID" > /tmp/secret-id

# Write the Vault Proxy's configuration to /tmp/vault-proxy.hcl
#   The Proxy references the fixed Vault server address of http://127.0.0.1:8200
#   The Proxy itself listens at the address http://127.0.0.1:8100
cat > /tmp/vault-proxy.hcl <<- EOM
pid_file = "${VAULT_PROXY_PIDFILE}"

vault {
  address = "http://127.0.0.1:8200"
  tls_skip_verify = true
  retry {
    num_retries = 10
  }
}

api_proxy {
  enforce_consistency = "always"
  use_auto_auth_token = true
}

listener "tcp" {
    address = "${VAULT_PROXY_ADDRESS}"
    tls_disable = true
}

auto_auth {
  method {
    type      = "approle"
    config = {
      role_id_file_path = "/tmp/role-id"
      secret_id_file_path = "/tmp/secret-id"
    }
  }
  sink {
    type = "file"
    config = {
      path = "/tmp/token"
    }
  }
}
EOM

# If Proxy is still running from a previous run, kill it
pkill -F "${VAULT_PROXY_PIDFILE}" || true

# Run proxy in the background
$binpath proxy -config=/tmp/vault-proxy.hcl > /tmp/proxy-logs.txt 2>&1 &
