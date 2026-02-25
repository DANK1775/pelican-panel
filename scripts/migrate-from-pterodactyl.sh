#!/bin/bash
set -euo pipefail

# ============================================================
# Migración de Pterodactyl Panel → Pelican Panel (Docker)
# ============================================================
# Este script:
#   1. Copia el .env de Pterodactyl y lo adapta
#   2. Hace backup de la base de datos
#   3. Importa la DB al contenedor MariaDB de Pelican
#   4. Ejecuta las migraciones de Pelican (artisan migrate)
#
# Pelican NO tiene un comando de migración especial.
# Su mecanismo es: apuntar a la misma DB y correr migraciones.
#
# Requisitos:
#   - Docker y docker compose instalados
#   - Acceso root o sudo
#   - Pterodactyl debe estar detenido antes de migrar
#   - El stack de Pelican (docker-compose.yml) debe estar UP
#     con DB y Redis corriendo
#
# Uso:
#   sudo bash scripts/migrate-from-pterodactyl.sh
#
# Variables de entorno opcionales:
#   PTERO_DIR       Ruta de Pterodactyl (default: /var/www/pterodactyl)
#   PTERO_ENV       Ruta del .env de Pterodactyl (default: $PTERO_DIR/.env)
#   COMPOSE_DIR     Ruta donde está docker-compose.yml de Pelican
#   BACKUP_DIR      Directorio para backups (default: /tmp/ptero-migration)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# --- Configuración ---
PTERO_DIR="${PTERO_DIR:-/var/www/pterodactyl}"
PTERO_ENV="${PTERO_ENV:-${PTERO_DIR}/.env}"
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
BACKUP_DIR="${BACKUP_DIR:-/tmp/ptero-migration}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo ""
echo "============================================"
echo " Migración: Pterodactyl → Pelican Panel"
echo "============================================"
echo ""
echo " Pterodactyl dir:  ${PTERO_DIR}"
echo " Pterodactyl .env: ${PTERO_ENV}"
echo " Compose dir:      ${COMPOSE_DIR}"
echo " Backup dir:       ${BACKUP_DIR}"
echo ""

# --- Validaciones ---
[ -f "${PTERO_ENV}" ] || error "No se encontró .env de Pterodactyl en: ${PTERO_ENV}"
[ -f "${COMPOSE_DIR}/docker-compose.yml" ] || error "No se encontró docker-compose.yml en: ${COMPOSE_DIR}"

# --- Leer variables del .env de Pterodactyl ---
get_env_var() {
    # Extrae el valor de la variable, eliminando comillas dobles o simples que la envuelvan,
    # pero preservando el contenido interno (como el padding '=' de base64).
    grep -E "^${1}=" "${PTERO_ENV}" | head -1 | cut -d'=' -f2- | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//'
}

PTERO_DB_HOST=$(get_env_var "DB_HOST")
PTERO_DB_PORT=$(get_env_var "DB_PORT")
PTERO_DB_DATABASE=$(get_env_var "DB_DATABASE")
PTERO_DB_USERNAME=$(get_env_var "DB_USERNAME")
PTERO_DB_PASSWORD=$(get_env_var "DB_PASSWORD")
PTERO_APP_KEY=$(get_env_var "APP_KEY")
PTERO_APP_URL=$(get_env_var "APP_URL")

[ -n "${PTERO_DB_DATABASE}" ] || error "No se pudo leer DB_DATABASE del .env de Pterodactyl"
[ -n "${PTERO_DB_PASSWORD}" ] || error "No se pudo leer DB_PASSWORD del .env de Pterodactyl"
[ -n "${PTERO_APP_KEY}" ]     || error "No se pudo leer APP_KEY del .env de Pterodactyl"

log "Variables de Pterodactyl leídas correctamente"
echo "  DB: ${PTERO_DB_DATABASE}@${PTERO_DB_HOST:-localhost}:${PTERO_DB_PORT:-3306}"
echo "  URL: ${PTERO_APP_URL}"
echo ""

# --- Confirmar ---
warn "IMPORTANTE: Pterodactyl debe estar DETENIDO antes de continuar."
warn "Este script importará la base de datos en el contenedor de Pelican."
echo ""
read -p "¿Deseas continuar? (y/N): " CONFIRM
[ "${CONFIRM}" = "y" ] || [ "${CONFIRM}" = "Y" ] || { echo "Cancelado."; exit 0; }

# --- Crear directorio de backup ---
mkdir -p "${BACKUP_DIR}"
log "Directorio de backup: ${BACKUP_DIR}"

# ===========================================
# Paso 1: Backup de la base de datos
# ===========================================
echo ""
echo "--- Paso 1/6: Backup de la base de datos de Pterodactyl ---"

DUMP_FILE="${BACKUP_DIR}/pterodactyl_${TIMESTAMP}.sql"

if [ "${PTERO_DB_HOST}" = "localhost" ] || [ "${PTERO_DB_HOST}" = "127.0.0.1" ] || [ -z "${PTERO_DB_HOST}" ]; then
    # DB local - usar mysqldump directo
    log "Exportando DB local..."
    mysqldump \
        -u "${PTERO_DB_USERNAME}" \
        -p"${PTERO_DB_PASSWORD}" \
        --port="${PTERO_DB_PORT:-3306}" \
        --single-transaction \
        --routines \
        --triggers \
        "${PTERO_DB_DATABASE}" > "${DUMP_FILE}" \
        || error "Falló el dump de la base de datos"
else
    # DB remota
    log "Exportando DB remota (${PTERO_DB_HOST})..."
    mysqldump \
        -h "${PTERO_DB_HOST}" \
        -u "${PTERO_DB_USERNAME}" \
        -p"${PTERO_DB_PASSWORD}" \
        --port="${PTERO_DB_PORT:-3306}" \
        --single-transaction \
        --routines \
        --triggers \
        "${PTERO_DB_DATABASE}" > "${DUMP_FILE}" \
        || error "Falló el dump de la base de datos"
fi

DUMP_SIZE=$(du -h "${DUMP_FILE}" | cut -f1)
log "Backup completado: ${DUMP_FILE} (${DUMP_SIZE})"

# ===========================================
# Paso 2: Verificar que los contenedores estén UP
# ===========================================
echo ""
echo "--- Paso 2/6: Verificando contenedores de Pelican ---"

cd "${COMPOSE_DIR}"

# Obtener nombre del servicio de DB
DB_CONTAINER=$(docker compose ps -q database 2>/dev/null) || error "No se encontró el contenedor 'database'. ¿Está corriendo el stack?"
[ -n "${DB_CONTAINER}" ] || error "El contenedor de database no está corriendo. Ejecuta: docker compose up -d database cache"

log "Contenedor de database encontrado: ${DB_CONTAINER}"

# Leer credenciales del .env del compose (o del environment)
PELICAN_DB_DATABASE=$(grep -E "^DB_DATABASE=" "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
PELICAN_DB_USERNAME=$(grep -E "^DB_USERNAME=" "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
PELICAN_DB_PASSWORD=$(grep -E "^DB_PASSWORD=" "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
MYSQL_ROOT_PASSWORD=$(grep -E "^MYSQL_ROOT_PASSWORD=" "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")

[ -n "${PELICAN_DB_DATABASE}" ] || error "No se encontró DB_DATABASE en ${COMPOSE_DIR}/.env"
[ -n "${MYSQL_ROOT_PASSWORD}" ] || error "No se encontró MYSQL_ROOT_PASSWORD en ${COMPOSE_DIR}/.env"

log "Credenciales de Pelican DB leídas correctamente"

# ===========================================
# Paso 3: Importar dump en la DB del contenedor
# ===========================================
echo ""
echo "--- Paso 3/6: Importando base de datos en contenedor ---"

# Importar usando root (stdin desde el host)
docker exec -i "${DB_CONTAINER}" mariadb \
    -u root \
    -p"${MYSQL_ROOT_PASSWORD}" \
    "${PELICAN_DB_DATABASE}" < "${DUMP_FILE}" \
    || error "Falló la importación de la base de datos"

log "Base de datos importada correctamente"

# ===========================================
# Paso 4: Preparar .env para Pelican
# ===========================================
echo ""
echo "--- Paso 4/6: Configurando .env de Pelican ---"

# --- Verificar APP_URL: https sin LE_EMAIL no arranca Caddy con TLS ---
LE_EMAIL=$(grep -E "^LE_EMAIL=" "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
BEHIND_PROXY_VAL=$(grep -E "^BEHIND_PROXY=" "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
PANEL_APP_URL="${PTERO_APP_URL}"
if echo "${PTERO_APP_URL}" | grep -q "^https://" && [ -z "${LE_EMAIL}" ]; then
    if [ "${BEHIND_PROXY_VAL}" = "true" ]; then
        # Detrás de proxy: mantener https, asegurar que BEHIND_PROXY esté en .env
        log "APP_URL es https:// y BEHIND_PROXY=true — manteniendo HTTPS"
    else
        PANEL_APP_URL=$(echo "${PTERO_APP_URL}" | sed 's|^https://|http://|')
        warn "APP_URL era https:// pero no hay LE_EMAIL ni BEHIND_PROXY=true"
        warn "Convirtiendo automáticamente a: ${PANEL_APP_URL}"
        warn "Para HTTPS, añade LE_EMAIL=tu@email.com o BEHIND_PROXY=true en tu .env"
    fi
fi

# --- Propagar APP_URL al .env del compose (docker-compose lee de aquí) ---
# El entrypoint NO lee APP_URL de pelican-data/.env; lo recibe como variable
# de entorno del docker-compose, que a su vez lo toma del .env del host.
if grep -q "^APP_URL=" "${COMPOSE_DIR}/.env" 2>/dev/null; then
    sed -i "s|^APP_URL=.*|APP_URL=${PANEL_APP_URL}|" "${COMPOSE_DIR}/.env"
else
    echo "APP_URL=${PANEL_APP_URL}" >> "${COMPOSE_DIR}/.env"
fi
log "APP_URL actualizado en ${COMPOSE_DIR}/.env → ${PANEL_APP_URL}"

# Escribir el .env en el volumen de pelican-data
# Usamos el APP_KEY original de Pterodactyl para no romper datos encriptados
PELICAN_ENV_CONTENT="APP_KEY=${PTERO_APP_KEY}
APP_URL=${PANEL_APP_URL}
APP_ENV=production
APP_DEBUG=false
APP_INSTALLED=true
BEHIND_PROXY=${BEHIND_PROXY_VAL:-false}

DB_CONNECTION=mariadb
DB_HOST=database
DB_PORT=3306
DB_DATABASE=${PELICAN_DB_DATABASE}
DB_USERNAME=${PELICAN_DB_USERNAME:-${PTERO_DB_USERNAME}}
DB_PASSWORD=${PELICAN_DB_PASSWORD:-${PTERO_DB_PASSWORD}}

CACHE_STORE=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
REDIS_HOST=cache
REDIS_PASSWORD=$(grep -E "^REDIS_PASSWORD=" "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")"

# Escribir .env al volumen via contenedor temporal
# Resolver nombre real del volumen (prefijo del proyecto compose)
# Si no existe aún, crearlo arrancando el servicio en modo --no-start
PANEL_VOLUME=$(docker volume ls -q --filter "name=panel-data" | head -1)
if [ -z "${PANEL_VOLUME}" ]; then
    warn "Volumen panel-data no encontrado, creándolo..."
    docker compose up --no-start panel 2>/dev/null || true
    PANEL_VOLUME=$(docker volume ls -q --filter "name=panel-data" | head -1)
fi
[ -n "${PANEL_VOLUME}" ] || error "No se pudo crear el volumen panel-data. Verifica el docker-compose.yml."
log "Volumen encontrado: ${PANEL_VOLUME}"

echo "${PELICAN_ENV_CONTENT}" | docker run --rm -i \
    -v "${PANEL_VOLUME}:/pelican-data" \
    alpine sh -c "cat > /pelican-data/.env"

log ".env de Pelican configurado con APP_KEY de Pterodactyl"

# ===========================================
# Paso 5/6: Compatibilidad automática de esquema Pterodactyl → Pelican
# ===========================================
# Enfoque genérico (funciona con cualquier versión de Pelican/Pterodactyl):
#
#   A) Escanea TODAS las migraciones pendientes de Pelican
#   B) Detecta las que hacen Schema::create('tabla')
#   C) Si la tabla ya existe en la DB → registra la migración como ejecutada
#   D) Aplica parches mínimos para bugs conocidos de Pelican
#
# Así no dependemos de nombres de tablas hardcodeados: cualquier conflicto
# "Table already exists" se resuelve automáticamente.
echo ""
echo "--- Paso 5/6: Compatibilidad automática de esquema ---"

run_sql() {
    docker exec "${DB_CONTAINER}" mariadb \
        -u root -p"${MYSQL_ROOT_PASSWORD}" "${PELICAN_DB_DATABASE}" \
        -e "$1" 2>/dev/null
}

run_sql_silent() {
    docker exec "${DB_CONTAINER}" mariadb \
        -u root -p"${MYSQL_ROOT_PASSWORD}" "${PELICAN_DB_DATABASE}" \
        -sNe "$1" 2>/dev/null
}

NEXT_BATCH=$(run_sql_silent "SELECT COALESCE(MAX(batch) + 1, 1) FROM migrations;")

# Obtener la imagen del panel
PANEL_IMAGE=$(docker compose config 2>/dev/null \
    | awk '/^services:/{s=1} s && /^ *panel:/{p=1} p && /^ *image:/{print $2; exit}')

# ─────────────────────────────────────────────────────────
# A) Obtener archivos de migración desde la imagen Docker
# ─────────────────────────────────────────────────────────
MIGRATIONS_DIR="/var/www/html/database/migrations"
MIGRATION_SOURCE="image"

if [ -n "${PANEL_IMAGE}" ]; then
    log "Escaneando migraciones desde imagen: ${PANEL_IMAGE}"
    ALL_MIGRATION_FILES=$(docker run --rm --entrypoint "" "${PANEL_IMAGE}" \
        ls "${MIGRATIONS_DIR}/" 2>/dev/null | grep '\.php$' || true)
else
    # Fallback: código fuente local (desarrollo)
    log "Escaneando migraciones desde código local"
    MIGRATION_SOURCE="local"
    ALL_MIGRATION_FILES=$(ls "${COMPOSE_DIR}/database/migrations/"*.php 2>/dev/null \
        | xargs -I{} basename {} || true)
fi

[ -n "${ALL_MIGRATION_FILES}" ] || error "No se encontraron archivos de migración"
TOTAL_MIGRATIONS=$(echo "${ALL_MIGRATION_FILES}" | wc -l | tr -d '[:space:]')
log "Encontradas ${TOTAL_MIGRATIONS} migraciones totales"

# Obtener migraciones ya ejecutadas
EXECUTED_MIGRATIONS=$(run_sql_silent "SELECT migration FROM migrations;" | tr '\n' '|')

# ─────────────────────────────────────────────────────────
# B) Parche específico: tabla 'permissions' heredada de Pterodactyl
# ─────────────────────────────────────────────────────────
# Pterodactyl tenía una tabla 'permissions' con columnas (user_id, server_id,
# permissions) que se eliminó en 2020. Pero al importar la DB, sigue ahí.
# Pelican crea una tabla 'permissions' NUEVA (Spatie) con columnas diferentes
# (name, guard_name). Si la vieja existe, hay que eliminarla.
OLD_PERM=$(run_sql_silent "SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema='${PELICAN_DB_DATABASE}'
      AND table_name='permissions'
      AND column_name='user_id';")
if [ "${OLD_PERM}" = "1" ]; then
    log "Eliminando tabla 'permissions' heredada de Pterodactyl (esquema incompatible)..."
    run_sql "DROP TABLE IF EXISTS permissions;" \
        && log "  OK" || warn "  No se pudo eliminar"
fi

# ─────────────────────────────────────────────────────────
# C) Parche específico: webhook_configurations necesita deleted_at
# ─────────────────────────────────────────────────────────
# El modelo WebhookConfiguration usa SoftDeletes. Durante las migraciones,
# la migración remove_root_admin_column dispara syncRoles → eventos Eloquent
# → DispatchWebhooks → WebhookConfiguration::pluck('events') → WHERE
# deleted_at IS NULL. Pero deleted_at se añade en una migración POSTERIOR.
# Solución: asegurar que la tabla exista con deleted_at ANTES de migrar.
WEBHOOK_EXISTS=$(run_sql_silent "SELECT COUNT(*) FROM information_schema.tables
    WHERE table_schema='${PELICAN_DB_DATABASE}'
      AND table_name='webhook_configurations';")

if [ "${WEBHOOK_EXISTS}" = "1" ]; then
    # Añadir columnas que falten
    run_sql "ALTER TABLE webhook_configurations ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP NULL DEFAULT NULL;" || true
    run_sql "ALTER TABLE webhook_configurations ADD COLUMN IF NOT EXISTS type VARCHAR(255) NULL AFTER id;" || true
    run_sql "ALTER TABLE webhook_configurations ADD COLUMN IF NOT EXISTS payload JSON NULL AFTER type;" || true
    run_sql "ALTER TABLE webhook_configurations ADD COLUMN IF NOT EXISTS headers JSON NULL AFTER payload;" || true
    log "webhook_configurations: columnas actualizadas"
else
    # Crearla con el esquema final completo
    run_sql "CREATE TABLE webhook_configurations (
        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
        type VARCHAR(255) NULL,
        payload JSON NULL,
        endpoint VARCHAR(255) NOT NULL,
        description VARCHAR(255) NOT NULL,
        events JSON NOT NULL,
        headers JSON NULL,
        created_at TIMESTAMP NULL,
        updated_at TIMESTAMP NULL,
        deleted_at TIMESTAMP NULL
    ) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
        && log "webhook_configurations: creada con esquema completo" \
        || warn "webhook_configurations: no se pudo crear"

    run_sql "CREATE TABLE IF NOT EXISTS webhooks (
        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
        webhook_configuration_id BIGINT UNSIGNED NOT NULL,
        event VARCHAR(255) NOT NULL,
        endpoint VARCHAR(255) NOT NULL,
        successful_at TIMESTAMP NULL,
        payload JSON NOT NULL,
        created_at TIMESTAMP NULL,
        updated_at TIMESTAMP NULL,
        CONSTRAINT webhooks_wc_id_fk FOREIGN KEY (webhook_configuration_id)
            REFERENCES webhook_configurations (id)
    ) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || true
fi

# Registrar TODAS las migraciones de webhook para que artisan las salte
# (ya que hemos creado/alterado la tabla manualmente con todas las columnas)
WEBHOOK_PATTERN="create_webhook_config|create_webhooks_table|webhook.*soft.?delete|add_webhook.*type|add_headers_webhook"
WEBHOOK_MIGRATIONS=$(echo "${ALL_MIGRATION_FILES}" | grep -E "${WEBHOOK_PATTERN}" | sed 's/\.php$//' || true)
for M in ${WEBHOOK_MIGRATIONS}; do
    run_sql "INSERT IGNORE INTO migrations (migration, batch) VALUES ('${M}', ${NEXT_BATCH});"
done
log "webhook_configurations: migraciones pre-registradas"

# ─────────────────────────────────────────────────────────
# D) Escaneo genérico: pre-registrar migraciones conflictivas
# ─────────────────────────────────────────────────────────
# Para cada migración pendiente que haga Schema::create('tabla'),
# si la tabla ya existe en la BD, registrarla como ejecutada
# para que artisan migrate la salte.
log "Analizando migraciones pendientes por conflictos de tablas..."

SKIPPED=0
CHECKED=0

read_migration_file() {
    local FILE="$1"
    if [ "${MIGRATION_SOURCE}" = "image" ]; then
        docker run --rm --entrypoint "" "${PANEL_IMAGE}" \
            cat "${MIGRATIONS_DIR}/${FILE}" 2>/dev/null
    else
        cat "${COMPOSE_DIR}/database/migrations/${FILE}" 2>/dev/null
    fi
}

for MFILE in ${ALL_MIGRATION_FILES}; do
    MNAME=$(echo "${MFILE}" | sed 's/\.php$//')

    # Saltar migraciones ya ejecutadas
    if echo "${EXECUTED_MIGRATIONS}" | grep -qF "${MNAME}"; then
        continue
    fi

    CHECKED=$((CHECKED + 1))

    # Extraer tablas que crea esta migración: Schema::create('tabla_name'
    CONTENT=$(read_migration_file "${MFILE}")

    # Manejo especial para la migración de Spatie que usa variables en lugar de strings literales
    if echo "${MNAME}" | grep -q "create_permission_tables"; then
        CREATED_TABLES="permissions roles model_has_permissions model_has_roles role_has_permissions"
    else
        CREATED_TABLES=$(echo "${CONTENT}" \
            | grep -oP "Schema::create\(\s*['\"]\\K[^'\"]+" 2>/dev/null || true)
    fi

    [ -n "${CREATED_TABLES}" ] || continue

    # Verificar si TODAS las tablas creadas ya existen
    ALL_EXIST=true
    for TABLE in ${CREATED_TABLES}; do
        EXISTS=$(run_sql_silent "SELECT COUNT(*) FROM information_schema.tables
            WHERE table_schema='${PELICAN_DB_DATABASE}' AND table_name='${TABLE}';")
        if [ "${EXISTS}" != "1" ]; then
            ALL_EXIST=false
            break
        fi
    done

    if [ "${ALL_EXIST}" = "true" ]; then
        run_sql "INSERT IGNORE INTO migrations (migration, batch) VALUES ('${MNAME}', ${NEXT_BATCH});"
        SKIPPED=$((SKIPPED + 1))
        log "  Pre-registrada (tablas ya existen): ${MNAME}"
    fi
done

log "Análisis completado: ${CHECKED} pendientes revisadas, ${SKIPPED} pre-registradas"

# ─────────────────────────────────────────────────────────
# E) Parche específico: egg_variables.sort
# ─────────────────────────────────────────────────────────
# Pterodactyl ya tenía esta columna, pero Pelican intenta crearla de nuevo
# en la migración 2024_04_20_214441_add_egg_var_sort.php
EGG_SORT_EXISTS=$(run_sql_silent "SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema='${PELICAN_DB_DATABASE}'
      AND table_name='egg_variables'
      AND column_name='sort';")

if [ "${EGG_SORT_EXISTS}" = "1" ]; then
    # Registrar la migración para que la salte
    EGG_SORT_MIGRATION=$(echo "${ALL_MIGRATION_FILES}" | grep "add_egg_var_sort" | sed 's/\.php$//' || true)
    if [ -n "${EGG_SORT_MIGRATION}" ]; then
        run_sql "INSERT IGNORE INTO migrations (migration, batch) VALUES ('${EGG_SORT_MIGRATION}', ${NEXT_BATCH});"
        log "  Pre-registrada (columna ya existe): ${EGG_SORT_MIGRATION}"
    fi
else
    # Si no existe, la creamos con IF NOT EXISTS por seguridad
    run_sql "ALTER TABLE egg_variables ADD COLUMN IF NOT EXISTS sort TINYINT UNSIGNED NULL AFTER egg_id;" 2>/dev/null || true
fi

# ===========================================
# Paso 6/6: Arrancar el panel
# ===========================================
echo ""
echo "--- Paso 6/6: Arrancando el panel ---"

warn "Iniciando el panel (las migraciones ya están aplicadas)..."

docker compose up -d --force-recreate panel

echo ""
log "Esperando a que el panel arranque..."
sleep 10

# ===========================================
# Paso 7: Corregir tokens encriptados (Payload is invalid)
# ===========================================
echo ""
echo "--- Paso 7: Corrigiendo tokens de Nodos y 2FA ---"
log "Generando nuevos tokens temporales para evitar errores de desencriptación..."

docker compose exec -T panel php artisan tinker <<EOF
DB::table('nodes')->update(['daemon_token' => encrypt('temp_token_please_regenerate'), 'daemon_token_id' => 'temp_id']);
if (Schema::hasColumn('users', 'totp_secret')) {
    DB::table('users')->update(['totp_secret' => null]);
}
if (Schema::hasColumn('users', 'two_factor_secret')) {
    DB::table('users')->update(['two_factor_secret' => null]);
}
EOF

docker compose exec -T panel php artisan cache:clear
docker compose exec -T panel php artisan view:clear
docker compose exec -T panel php artisan config:clear

# Verificar logs para confirmar arranque
echo ""
echo "--- Últimos logs del panel ---"
docker compose logs --tail=100 panel

echo ""
echo "============================================"
echo ""
log "¡Migración completada!"
echo ""
echo "  Próximos pasos:"
echo "  1. Verifica que el panel esté accesible en: ${PANEL_APP_URL}"
echo "  2. Inicia sesión con tus credenciales de Pterodactyl"
echo "  3. Revisa que los servidores, nodos y usuarios estén correctos"
echo "  4. Actualiza las URLs de Wings/Daemon si es necesario"
echo ""
echo "  Backup de la DB guardado en: ${DUMP_FILE}"
echo ""
warn "Recuerda: Wings/Daemon debe ser compatible con Pelican."
warn "Consulta: https://pelican.dev/docs para más información."
echo ""
