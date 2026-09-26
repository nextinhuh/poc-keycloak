FROM quay.io/keycloak/keycloak:26.0

COPY realm-export.json /opt/keycloak/data/import/realm-export.json
# Desliga a exigencia de HTTPS no realm master (console admin) - nao ha
# dominio/ACM nesta POC, so HTTP mesmo. Ver README para o motivo.
COPY master-realm-override.json /opt/keycloak/data/import/master-realm-override.json

# start-dev usa H2 embarcado (sem Postgres) - decisao explicita da POC, sem
# banco de dados persistente. --import-realm cria o realm poc-terminal (e os
# clients poc-backend / step-ca-oidc) automaticamente no boot.
# --features=token-exchange,admin-fine-grained-authz: sem isso, as telas de
# permissao (Users -> Permissions, Clients -> Advanced -> Permissions) nem
# aparecem no console, e o grant_type token-exchange e recusado pelo servidor.
ENTRYPOINT ["/opt/keycloak/bin/kc.sh", "start-dev", "--import-realm", "--http-enabled=true", "--hostname-strict=false", "--features=token-exchange,admin-fine-grained-authz"]
