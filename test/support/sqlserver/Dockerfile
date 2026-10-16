FROM ubuntu:22.04

ENV ACCEPT_EULA=Y

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends apt-transport-https ca-certificates curl gnupg; \
    mkdir -p /usr/share/keyrings; \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/microsoft.gpg; \
    curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2022.list \
      -o /etc/apt/sources.list.d/mssql-server.list; \
    sed -i 's|^deb \[|deb [signed-by=/usr/share/keyrings/microsoft.gpg |' /etc/apt/sources.list.d/mssql-server.list; \
    curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/prod.list \
      -o /etc/apt/sources.list.d/microsoft-prod.list; \
    sed -i 's|^deb \[|deb [signed-by=/usr/share/keyrings/microsoft.gpg |' /etc/apt/sources.list.d/microsoft-prod.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends mssql-server mssql-server-fts mssql-tools18; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

EXPOSE 1433

USER mssql

CMD ["/opt/mssql/bin/sqlservr"]
