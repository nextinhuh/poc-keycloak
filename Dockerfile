FROM quay.io/keycloak/keycloak:26.0

USER root
RUN microdnf install -y curl jq && microdnf clean all

COPY realm-export.json /opt/keycloak/data/import/realm-export.json
# Desliga a exigencia de HTTPS no realm master (console admin) - nao ha
# dominio/ACM nesta POC, so HTTP mesmo. Ver README para o motivo.
COPY master-realm-override.json /opt/keycloak/data/import/master-realm-override.json

COPY entrypoint.sh /entrypoint.sh
COPY configure-token-exchange.sh /configure-token-exchange.sh
RUN chmod +x /entrypoint.sh /configure-token-exchange.sh && \
    chown 1000:0 /entrypoint.sh /configure-token-exchange.sh

USER 1000

# /opt/keycloak/data fica no volume EFS (ver terraform/efs.tf) - persiste o
# H2 (usuarios, realm, policies/permissions) entre deploys. O entrypoint.sh
# decide, com base num marcador nesse volume, se e a primeira execucao
# (importa o realm + roda a configuracao de token-exchange) ou nao.
VOLUME ["/opt/keycloak/data"]

ENTRYPOINT ["/entrypoint.sh"]
