# A imagem oficial do Keycloak (estagio final) e baseada num RHEL9 minimal
# SEM gerenciador de pacotes nenhum (nem microdnf) - por isso curl/jq
# precisam ser instalados numa imagem builder a parte (mesma familia RHEL9,
# glibc/OpenSSL compativeis) e copiados manualmente, junto com as libs
# compartilhadas que eles precisam (validado localmente com `ldd` antes de
# escrever isso, ver historico do projeto).
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS tools
RUN microdnf install -y jq --setopt=install_weak_deps=0 --setopt=tsflags=nodocs

FROM quay.io/keycloak/keycloak:26.0

USER root
COPY --from=tools /usr/bin/curl /usr/bin/curl
COPY --from=tools /usr/bin/jq /usr/bin/jq
COPY --from=tools \
  /usr/lib64/libcurl.so.4* \
  /usr/lib64/libnghttp2.so.14* \
  /usr/lib64/libssl.so.3* \
  /usr/lib64/libcrypto.so.3* \
  /usr/lib64/libgssapi_krb5.so.2* \
  /usr/lib64/libkrb5.so.3* \
  /usr/lib64/libk5crypto.so.3* \
  /usr/lib64/libcom_err.so.2* \
  /usr/lib64/libkrb5support.so.0* \
  /usr/lib64/libkeyutils.so.1* \
  /usr/lib64/libjq.so.1* \
  /usr/lib64/libonig.so.5* \
  /usr/lib64/

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
