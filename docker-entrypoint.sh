#!/bin/bash
set -e

IDEMPIERE_HOME="${IDEMPIERE_HOME:-/opt/idempiere-server}"
cd "$IDEMPIERE_HOME"

# Parámetros de conexión a la Base de Datos desde variables de entorno
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-idempiere}"
DB_USER="${DB_USER:-adempiere}"
DB_PASS="${DB_PASS:-adempiere}"
DB_ADMIN_USER="${DB_ADMIN_USER:-$DB_USER}"
DB_ADMIN_PASS="${DB_ADMIN_PASS:-$DB_PASS}"
MIGRATE_EXISTING_DATABASE="${MIGRATE_EXISTING_DATABASE:-true}"

echo "=========================================================="
echo "Iniciando LunaERP / iDempiere Container"
echo "Host BD: ${DB_HOST}:${DB_PORT} | BD: ${DB_NAME} | User: ${DB_USER}"
echo "=========================================================="

# 1. Esperar a que PostgreSQL esté disponible
echo "Esperando conexión a PostgreSQL en ${DB_HOST}:${DB_PORT}..."
until pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" >/dev/null 2>&1 || nc -z -w5 "$DB_HOST" "$DB_PORT" >/dev/null 2>&1; do
    echo "PostgreSQL no responde aún. Reintentando en 3 segundos..."
    sleep 3
done
echo "PostgreSQL está listo."

# 2. Configurar el entorno (idempiere.properties y myEnvironment.sh) si no existe
if [ ! -f "$IDEMPIERE_HOME/utils/myEnvironment.sh" ] || [ ! -f "$IDEMPIERE_HOME/idempiere.properties" ]; then
    echo "No se encontró configuración previa. Generando idempiereEnv.properties..."
    
    cat <<EOF > "$IDEMPIERE_HOME/idempiereEnv.properties"
IDEMPIERE_HOME=$IDEMPIERE_HOME
JAVA_HOME=$JAVA_HOME
IDEMPIERE_JAVA_OPTIONS=${JAVA_OPTS:--Xms512M -Xmx3072M -XX:+UseG1GC}
ADEMPIERE_DB_TYPE=PostgreSQL
ADEMPIERE_DB_EXISTS=Y
ADEMPIERE_DB_PATH=postgresql
ADEMPIERE_DB_SERVER=$DB_HOST
ADEMPIERE_DB_PORT=$DB_PORT
ADEMPIERE_DB_NAME=$DB_NAME
ADEMPIERE_DB_SYSTEM_USER=$DB_ADMIN_USER
ADEMPIERE_DB_SYSTEM=$DB_ADMIN_PASS
ADEMPIERE_DB_USER=$DB_USER
ADEMPIERE_DB_PASSWORD=$DB_PASS
ADEMPIERE_APPS_SERVER=0.0.0.0
ADEMPIERE_WEB_ALIAS=localhost
ADEMPIERE_WEB_PORT=8080
ADEMPIERE_SSL_PORT=8443
ADEMPIERE_KEYSTORE=$IDEMPIERE_HOME/keystore/myKeystore
ADEMPIERE_KEYSTOREWEBALIAS=adempiere
ADEMPIERE_KEYSTORECODEALIAS=adempiere
ADEMPIERE_KEYSTOREPASS=myPassword
ADEMPIERE_CERT_CN=localhost
ADEMPIERE_CERT_ORG=iDempiere
ADEMPIERE_CERT_ORG_UNIT=iDempiere
ADEMPIERE_CERT_LOCATION=Lima
ADEMPIERE_CERT_STATE=Lima
ADEMPIERE_CERT_COUNTRY=PE
ADEMPIERE_MAIL_SERVER=localhost
ADEMPIERE_ADMIN_EMAIL=admin@idempiere.org
ADEMPIERE_MAIL_USER=
ADEMPIERE_MAIL_PASSWORD=
ADEMPIERE_FTP_SERVER=localhost
ADEMPIERE_FTP_PREFIX=my
ADEMPIERE_FTP_USER=anonymous
ADEMPIERE_FTP_PASSWORD=user@host.com
EOF

    echo "Ejecutando silent-setup.sh para inicializar configuración y plantillas..."
    bash "$IDEMPIERE_HOME/silent-setup.sh"
    echo "Configuración generada exitosamente."
fi

# 3. Verificar si la base de datos ya cuenta con el esquema de iDempiere
TABLE_COUNT=$(PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='adempiere' OR table_name='ad_system';" 2>/dev/null || echo "0")

if [ "$TABLE_COUNT" = "0" ] || [ -z "$TABLE_COUNT" ]; then
    echo "Base de datos '$DB_NAME' vacía (0 tablas detectadas)."
    echo "Importando semilla oficial de iDempiere (Seed)..."
    cd "$IDEMPIERE_HOME/utils"
    echo "" | ./RUN_ImportIdempiere.sh
    echo "Semilla importada exitosamente."
else
    echo "Base de datos existente detectada (${TABLE_COUNT} tablas)."
    if [ "$MIGRATE_EXISTING_DATABASE" = "true" ] || [ "$MIGRATE_EXISTING_DATABASE" = "yes" ]; then
        echo "Aplicando migraciones pendientes (RUN_SyncDB.sh)..."
        cd "$IDEMPIERE_HOME/utils"
        ./RUN_SyncDB.sh || true
    fi
fi

cd "$IDEMPIERE_HOME"
echo "=========================================================="
echo "Arrancando servidor iDempiere..."
echo "=========================================================="

if [ "$#" -eq 0 ]; then
    exec "$IDEMPIERE_HOME/idempiere-server.sh"
else
    exec "$@"
fi

