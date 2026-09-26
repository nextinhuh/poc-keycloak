FROM quay.io/keycloak/keycloak:26.0

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER 1000

# /opt/keycloak/data fica no volume EFS (ver terraform/efs.tf) - persiste o
# H2 (realm, usuarios, clients, permissoes) entre deploys. Configuracao e
# 100% manual pelo console admin; nao ha import automatico de realm.
VOLUME ["/opt/keycloak/data"]

ENTRYPOINT ["/entrypoint.sh"]
