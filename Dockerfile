# syntax=docker.io/docker/dockerfile:1.13-labs

# ================================
# Stage 1-1: Composer Install
# ================================
FROM --platform=$TARGETOS/$TARGETARCH composer:2.7 AS composer
WORKDIR /build
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --no-autoloader --no-scripts --ignore-platform-reqs

# ================================
# Stage 1-2: Yarn Install
# ================================
FROM --platform=$BUILDPLATFORM node:20-alpine AS yarn
WORKDIR /build
COPY package.json yarn.lock ./
RUN yarn config set network-timeout 300000 && yarn install --frozen-lockfile

# ================================
# Stage 2-1: Composer Optimize
# ================================
FROM --platform=$TARGETOS/$TARGETARCH composer:2.7 AS composerbuild
COPY --exclude=docker/ . /build/
WORKDIR /build
# Copiamos los vendors de la etapa 1
COPY --from=composer /build/vendor ./vendor
RUN composer dump-autoload --optimize

# ================================
# Stage 2-2: Build Frontend Assets
# ================================
FROM --platform=$BUILDPLATFORM node:20-alpine AS yarnbuild
WORKDIR /build
COPY --exclude=docker/ . ./
# CRÍTICO: Copiar vendor/ ANTES de hacer el build
COPY --from=composerbuild /build/vendor ./vendor
COPY --from=yarn /build/node_modules ./node_modules
RUN yarn run build

# ================================
# Stage 3: Build Final Application Image
# ================================
FROM --platform=$TARGETOS/$TARGETARCH php:8.3-fpm-alpine AS final

WORKDIR /var/www/html

RUN apk add --no-cache \
    caddy ca-certificates supervisor supercronic fcgi \
    zip unzip 7zip bzip2-dev yarn git icu-dev \
    libzip-dev libpng-dev libjpeg-turbo-dev freetype-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install pdo_mysql bcmath gd zip intl

COPY --from=composer:2.7 /usr/bin/composer /usr/local/bin/composer
COPY --chown=root:www-data --chmod=770 --from=composerbuild /build .
COPY --chown=root:www-data --chmod=770 --from=yarnbuild /build/public ./public

RUN mkdir -p /pelican-data/storage /pelican-data/plugins /var/run/supervisord \
    && rm -rf /var/www/html/plugins \
    && ln -s  /pelican-data/.env /var/www/html/.env \
    && ln -s  /pelican-data/database/database.sqlite ./database/database.sqlite \
    && ln -s  /pelican-data/storage /var/www/html/public/storage \
    && ln -s  /pelican-data/storage /var/www/html/storage/app/public \
    && ln -s  /pelican-data/plugins /var/www/html/plugins \
    && chown -R www-data: /pelican-data .env ./storage ./plugins ./bootstrap/cache /var/run/supervisord /var/www/html/public/storage \
    && chmod -R 770 /pelican-data ./storage ./bootstrap/cache /var/run/supervisord \
    && chown -R www-data: /usr/local/etc/php/ /usr/local/etc/php-fpm.d/ /var/www/html/composer.json /var/www/html/composer.lock

COPY docker/supervisord.conf /etc/supervisord.conf
COPY docker/Caddyfile /etc/caddy/Caddyfile
COPY docker/crontab /etc/crontabs/crontab
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/healthcheck.sh /healthcheck.sh

HEALTHCHECK --interval=5m --timeout=10s --start-period=5s --retries=3 \
    CMD /bin/ash /healthcheck.sh

EXPOSE 80 443
VOLUME /pelican-data
USER www-data

ENTRYPOINT [ "/bin/ash", "/entrypoint.sh" ]
CMD [ "supervisord", "-n", "-c", "/etc/supervisord.conf" ]
