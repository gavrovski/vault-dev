#!/bin/sh
# VAULT_CONFIG_DIR isn't exposed as a volume but you can compose additional
# config files in there if you use this image as a base, or use
# VAULT_LOCAL_CONFIG below.
VAULT_CONFIG_DIR=/vault/config

VAULT_SECRETS_FILE=${VAULT_SECRETS_FILE:-"/opt/secrets.json"}
VAULT_APP_ROLE_FILE=${VAULT_APP_ROLE_FILE:-"/opt/app-role.json"}
VAULT_POLICIES_FILE=${VAULT_POLICIES_FILE:-"/opt/policies.json"}

# You can also set the VAULT_LOCAL_CONFIG environment variable to pass some
# Vault configuration JSON without having to bind any volumes.
if [ -n "$VAULT_LOCAL_CONFIG" ]; then
	echo "$VAULT_LOCAL_CONFIG" > "$VAULT_CONFIG_DIR/local.json"
fi

vault server \
	-config="$VAULT_CONFIG_DIR" \
	-dev-root-token-id="${VAULT_DEV_ROOT_TOKEN_ID:-root}" \
	-dev-listen-address="${VAULT_DEV_LISTEN_ADDRESS:-"0.0.0.0:8200"}" \
	-dev "$@" &

# Poll until Vault is ready
for i in {1..10}; do (vault status) > /dev/null 2>&1 && break || if [ "$i" -lt 11 ]; then sleep $((i * 2)); else echo 'Timeout waiting for Vault to be ready' && exit 1; fi; done

# parse JSON array, populate Vault
if [[ -f "$VAULT_SECRETS_FILE" ]]; then
	for path in $(jq -r 'keys[]' < "$VAULT_SECRETS_FILE"); do
		value=$(jq -rj ".\"${path}\"" < "$VAULT_SECRETS_FILE")
		type=$(jq -rj ".\"${path}\" | \"\(. | type)\"" < "$VAULT_SECRETS_FILE")
		echo "writing ${type} value to ${path}"
		if [ $type = 'object' ] || [ $type = 'array' ]; then
			echo "$value" | vault kv put "${path}" -
		else
			echo "$value" | vault kv put "${path}" value=-
		fi
	done
else
	echo "$VAULT_SECRETS_FILE not found, skipping"
fi

# Optionally install the approle backend.
if [ -n "$VAULT_USE_APP_ROLE" ]; then
	vault auth enable approle
	if [[ -f "$VAULT_APP_ROLE_FILE" ]]; then
		for appID in $(jq -rc '.[]' < "$VAULT_APP_ROLE_FILE"); do

			name=$(echo "$appID" | jq -r ".name")
			secret_id_ttl=$(echo "$appID" | jq -r ".secret_id_ttl")
			token_num_uses=$(echo "$appID" | jq -r ".token_num_uses")
			token_ttl=$(echo "$appID" | jq -r ".token_ttl")
			token_max_ttl=$(echo "$appID" | jq -r ".token_max_ttl")
			secret_id_num_uses=$(echo "$appID" | jq -r ".secret_id_num_uses")

			echo "creating AppRole policy with role name $name for policy $policy"

			vault write auth/approle/role/$name \
				secret_id_ttl=$secret_id_ttl \
				token_num_uses=$token_num_uses \
				token_ttl=$token_ttl \
				token_max_ttl=$token_max_ttl \
				secret_id_num_uses=$secret_id_num_uses
	done
	else
		echo "$VAULT_APP_ROLE_FILE not found, skipping"
	fi
fi

# Create any policies.
if [[ -f "$VAULT_POLICIES_FILE" ]]; then
	for policy in $(jq -r 'keys[]' < "$VAULT_POLICIES_FILE"); do
		jq -rj ".\"${policy}\"" < "$VAULT_POLICIES_FILE" > /tmp/value
		echo "creating vault policy $policy"
		# vault policy-write "${policy}" /tmp/value
		vault policy write "${policy}" /tmp/value
		rm -f /tmp/value
	done
else
	echo "$VAULT_POLICIES_FILE not found, skipping"
fi

# docker healthcheck
touch /opt/healthcheck

echo 'Vault server is listening...'

# block forever
tail -f /dev/null