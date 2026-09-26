FROM quay.io/keycloak/keycloak:26.0

COPY realm-export.json /opt/keycloak/data/import/realm-export.json

# start-dev usa H2 embarcado (sem Postgres) - decisao explicita da POC, sem
# banco de dados persistente. --import-realm cria o realm poc-terminal (e os
# clients poc-backend / step-ca-oidc) automaticamente no boot.
ENTRYPOINT ["/opt/keycloak/bin/kc.sh", "start-dev", "--import-realm", "--http-enabled=true", "--hostname-strict=false"]
