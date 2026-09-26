#!/bin/sh
set -eu

# Subida nativa do Keycloak - sem import de realm, sem script de
# configuracao automatica. Toda a configuracao (realm, clients, usuarios,
# permissoes de token-exchange) e feita manualmente pelo console admin.
# O volume EFS persiste essa configuracao entre deploys.
exec /opt/keycloak/bin/kc.sh start-dev \
  --http-enabled=true --hostname-strict=false \
  --features=token-exchange,admin-fine-grained-authz
