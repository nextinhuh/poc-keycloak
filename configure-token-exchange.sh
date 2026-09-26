#!/bin/sh
set -eu

# Configura, via Admin REST API do Keycloak, exatamente o que antes era
# feito na mao no console (ver historico do README):
#   1. Habilita "Permissions" no client poc-backend e anexa uma policy
#      liberando ele mesmo na permissao "token-exchange".
#   2. Habilita "Permissions" no recurso Users do realm e anexa a mesma
#      policy na permissao "impersonate".
# So roda uma vez (chamado pelo entrypoint.sh so na primeira execucao do
# volume EFS). Idempotente: pode ser reexecutado manualmente sem duplicar
# policy nem quebrar nada, caso precise depurar/reaplicar.

KC_URL="http://localhost:8080"
REALM="poc-terminal"
BACKEND_CLIENT_ID="poc-backend"
POLICY_NAME="poc-backend-pode-exchange"

echo "==> Aguardando o Keycloak ficar pronto..."
i=0
until curl -sf "${KC_URL}/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "ERRO: Keycloak nao respondeu apos 2 minutos"
    exit 1
  fi
  sleep 2
done
echo "==> Keycloak pronto."

ADMIN_TOKEN=$(curl -sS -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  -d "username=${KC_BOOTSTRAP_ADMIN_USERNAME}" \
  -d "password=${KC_BOOTSTRAP_ADMIN_PASSWORD}" \
  | jq -r .access_token)

if [ -z "${ADMIN_TOKEN}" ] || [ "${ADMIN_TOKEN}" = "null" ]; then
  echo "ERRO: nao consegui autenticar como admin"
  exit 1
fi

auth_get() { curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "$1"; }
auth_put() { curl -sS -X PUT -H "Authorization: Bearer ${ADMIN_TOKEN}" -H "Content-Type: application/json" -d "$2" "$1"; }
auth_post() { curl -sS -X POST -H "Authorization: Bearer ${ADMIN_TOKEN}" -H "Content-Type: application/json" -d "$2" "$1"; }

BACKEND_UUID=$(auth_get "${KC_URL}/admin/realms/${REALM}/clients?clientId=${BACKEND_CLIENT_ID}" | jq -r '.[0].id')
REALM_MGMT_UUID=$(auth_get "${KC_URL}/admin/realms/${REALM}/clients?clientId=realm-management" | jq -r '.[0].id')

if [ -z "${BACKEND_UUID}" ] || [ "${BACKEND_UUID}" = "null" ]; then
  echo "ERRO: client ${BACKEND_CLIENT_ID} nao encontrado no realm ${REALM}"
  exit 1
fi

echo "==> Habilitando fine-grained permissions no client ${BACKEND_CLIENT_ID}"
CLIENT_PERMS=$(auth_put "${KC_URL}/admin/realms/${REALM}/clients/${BACKEND_UUID}/management/permissions" '{"enabled": true}')
TOKEN_EXCHANGE_PERM_ID=$(echo "${CLIENT_PERMS}" | jq -r '.scopePermissions."token-exchange"')

echo "==> Habilitando fine-grained permissions no recurso Users do realm"
USERS_PERMS=$(auth_put "${KC_URL}/admin/realms/${REALM}/users-management-permissions" '{"enabled": true}')
IMPERSONATE_PERM_ID=$(echo "${USERS_PERMS}" | jq -r '.scopePermissions.impersonate')

echo "==> Garantindo a policy '${POLICY_NAME}' (client=${BACKEND_CLIENT_ID})"
POLICY_ID=$(auth_get "${KC_URL}/admin/realms/${REALM}/clients/${REALM_MGMT_UUID}/authz/resource-server/policy/client?name=${POLICY_NAME}" \
  | jq -r '.[0].id // empty')

if [ -z "${POLICY_ID}" ]; then
  POLICY_ID=$(auth_post "${KC_URL}/admin/realms/${REALM}/clients/${REALM_MGMT_UUID}/authz/resource-server/policy/client" \
    "{\"name\":\"${POLICY_NAME}\",\"clients\":[\"${BACKEND_UUID}\"],\"logic\":\"POSITIVE\"}" \
    | jq -r .id)
  echo "    policy criada: ${POLICY_ID}"
else
  echo "    policy ja existia: ${POLICY_ID}"
fi

attach_policy() {
  permission_id="$1"
  label="$2"
  perm_json=$(auth_get "${KC_URL}/admin/realms/${REALM}/clients/${REALM_MGMT_UUID}/authz/resource-server/permission/scope/${permission_id}")
  updated=$(echo "${perm_json}" | jq --arg pid "${POLICY_ID}" '.policies = ((.policies // []) + [$pid] | unique)')
  auth_put "${KC_URL}/admin/realms/${REALM}/clients/${REALM_MGMT_UUID}/authz/resource-server/permission/scope/${permission_id}" \
    "${updated}" >/dev/null
  echo "==> Policy anexada na permissao '${label}' (${permission_id})"
}

attach_policy "${TOKEN_EXCHANGE_PERM_ID}" "token-exchange (client ${BACKEND_CLIENT_ID})"
attach_policy "${IMPERSONATE_PERM_ID}" "impersonate (Users)"

echo "==> Configuracao de token-exchange concluida."
