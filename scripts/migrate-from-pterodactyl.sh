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
#   PTERO_DIR       Ruta de Pterodactyl (default: /etc/www/pterodactyl)
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
PTERO_DIR="${PTERO_DIR:-/etc/www/pterodactyl}"
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
    grep -E "^${1}=" "${PTERO_ENV}" | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'"
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
echo "--- Paso 1/5: Backup de la base de datos de Pterodactyl ---"

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
echo "--- Paso 2/5: Verificando contenedores de Pelican ---"

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
echo "--- Paso 3/5: Importando base de datos en contenedor ---"

# Copiar dump al contenedor
docker cp "${DUMP_FILE}" "${DB_CONTAINER}:/tmp/pterodactyl.sql"
log "Dump copiado al contenedor"

# Importar usando root
docker exec -i "${DB_CONTAINER}" mariadb \
    -u root \
    -p"${MYSQL_ROOT_PASSWORD}" \
    "${PELICAN_DB_DATABASE}" < "${DUMP_FILE}" \
    || error "Falló la importación de la base de datos"

log "Base de datos importada correctamente"

# Limpiar dump del contenedor
docker exec "${DB_CONTAINER}" rm -f /tmp/pterodactyl.sql

# ===========================================
# Paso 4: Preparar .env para Pelican
# ===========================================
echo ""
echo "--- Paso 4/5: Configurando .env de Pelican ---"

# Obtener volumen panel-data
PANEL_CONTAINER=$(docker compose ps -q panel 2>/dev/null || echo "")

# Escribir el .env en el volumen de pelican-data
# Usamos el APP_KEY original de Pterodactyl para no romper datos encriptados
PELICAN_ENV_CONTENT="APP_KEY=${PTERO_APP_KEY}
APP_URL=${PTERO_APP_URL}
APP_ENV=production
APP_DEBUG=false
APP_INSTALLED=true

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
PANEL_VOLUME=$(docker volume ls -q --filter "name=panel-data" | head -1)
[ -n "${PANEL_VOLUME}" ] || error "No se encontró el volumen panel-data. ¿Está creado el stack?"

echo "${PELICAN_ENV_CONTENT}" | docker run --rm -i \
    -v "${PANEL_VOLUME}:/pelican-data" \
    alpine sh -c "cat > /pelican-data/.env"

log ".env de Pelican configurado con APP_KEY de Pterodactyl"

# ===========================================
# Paso 5: Ejecutar migraciones de Pelican
# ===========================================
echo ""
echo "--- Paso 5/5: Ejecutando migraciones de Pelican ---"

warn "Reiniciando el panel para que tome el nuevo .env y ejecute migraciones..."

docker compose up -d --force-recreate panel

echo ""
log "Esperando a que el panel arranque y ejecute migraciones..."
sleep 10

# Verificar logs para confirmar migración
echo ""
echo "--- Últimos logs del panel ---"
docker compose logs --tail=30 panel

echo ""
echo "============================================"
echo ""
log "¡Migración completada!"
echo ""
echo "  Próximos pasos:"
echo "  1. Verifica que el panel esté accesible en: ${PTERO_APP_URL}"
echo "  2. Inicia sesión con tus credenciales de Pterodactyl"
echo "  3. Revisa que los servidores, nodos y usuarios estén correctos"
echo "  4. Actualiza las URLs de Wings/Daemon si es necesario"
echo ""
echo "  Backup de la DB guardado en: ${DUMP_FILE}"
echo ""
warn "Recuerda: Wings/Daemon debe ser compatible con Pelican."
warn "Consulta: https://pelican.dev/docs para más información."
echo ""
