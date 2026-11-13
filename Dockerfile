FROM eclipse-temurin:17-jdk-jammy

ARG BUILD_NUMBER=local
LABEL maintainer="EGS-GROUP <dev@egs-group.com>" \
    org.opencontainers.image.title="LunaERP (iDempiere Custom)" \
    org.opencontainers.image.version="${BUILD_NUMBER}"

# Instalar utilitarios requeridos por los scripts de iDempiere (setup, cliente PostgreSQL y timezone)
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    jq \
    netcat-openbsd \
    postgresql-client \
    tzdata \
    unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Crear usuario no-root dedicado para ejecutar iDempiere
RUN groupadd -r idempiere && useradd -r -g idempiere -d /opt/idempiere-server -s /bin/bash idempiere

WORKDIR /opt/idempiere-server

# Copiar el producto compilado por Maven/Tycho (soporta tanto x86_64 como aarch64 automáticamente)
COPY org.idempiere.p2/target/products/org.adempiere.server.product/linux/gtk/*/ /opt/idempiere-server/

# Copiar script de inicialización desatendido
COPY docker-entrypoint.sh /opt/idempiere-server/docker-entrypoint.sh

# Asignar permisos de ejecución a los scripts de iDempiere y propiedad al usuario no-root
RUN chmod +x /opt/idempiere-server/*.sh /opt/idempiere-server/utils/*.sh /opt/idempiere-server/docker-entrypoint.sh 2>/dev/null || true \
    && chown -R idempiere:idempiere /opt/idempiere-server

USER idempiere

# Puertos estándar de iDempiere (8080 HTTP, 8443 HTTPS, 12612 OSGi Console)
EXPOSE 8080 8443 12612

# Variables de entorno por defecto para la JVM de producción de iDempiere
ENV JAVA_OPTIONS="-Xms1g -Xmx3g -XX:+UseG1GC" \
    IDEMPIERE_HOME="/opt/idempiere-server"

# Punto de entrada desatendido que autoconfigura la BD antes de arrancar
ENTRYPOINT ["/opt/idempiere-server/docker-entrypoint.sh"]
CMD ["/opt/idempiere-server/idempiere-server.sh"]
