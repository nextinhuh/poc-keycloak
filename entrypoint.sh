#!/bin/sh
set -eu

# /opt/keycloak/data fica no volume EFS (ver terraform/efs.tf). Um marcador
# ali dentro diz se esse volume ja foi inicializado numa execucao anterior -
# se sim, NAO passamos --import-realm de novo (evita o Keycloak reprocessar
# o realm-export.json por cima de dados ja existentes, o que apagaria
# usuarios/policies/permissions criados depois do boot inicial).
DATA_DIR="/opt/keycloak/data"
MARKER="${DATA_DIR}/.poc-mtls-initialized"

if [ -f "${MARKER}" ]; then
  echo "==> Volume ja inicializado - subindo sem --import-realm (dados persistidos preservados)"
  IMPORT_FLAG=""
else
  echo "==> Primeira execucao (volume vazio) - vai importar o realm poc-terminal"
  IMPORT_FLAG="--import-realm"
fi

/opt/keycloak/bin/kc.sh start-dev ${IMPORT_FLAG} \
  --http-enabled=true --hostname-strict=false \
  --features=token-exchange,admin-fine-grained-authz &
KC_PID=$!

if [ ! -f "${MARKER}" ]; then
  # Roda so na primeira vez: espera o Keycloak subir e configura, via Admin
  # REST API, as permissoes de token-exchange que antes eram feitas na mao
  # no console (ver README, secao "papel deste servico"). Se falhar, NAO
  # derruba o container - so avisa no log, pra poder ser corrigido/reexecutado
  # manualmente sem perder o boot do Keycloak em si.
  /configure-token-exchange.sh || echo "AVISO: configuracao automatica de token-exchange falhou - ver log acima e revisar manualmente"
  mkdir -p "${DATA_DIR}"
  touch "${MARKER}"
fi

wait "${KC_PID}"
