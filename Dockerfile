FROM php:8.3.23-fpm-bookworm

LABEL description="PHP Symfony 5.4 + OpenTelemetry POC"

# Install minimal required packages
RUN apt-get update && apt-get install -y \
    libzip-dev \
    libicu-dev \
    unzip \
    gettext-base \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install PHP extensions (minimal set for Symfony)
RUN docker-php-ext-install \
    intl \
    opcache \
    zip

# Install OpenTelemetry auto-instrumentation extension
# See: https://opentelemetry.io/docs/zero-code/php/
RUN pecl install opentelemetry && \
    echo "extension=opentelemetry.so" > /usr/local/etc/php/conf.d/opentelemetry.ini

# Install protobuf for OTLP http/protobuf export (much faster than JSON)
RUN pecl install protobuf && \
    echo "extension=protobuf.so" > /usr/local/etc/php/conf.d/protobuf.ini

# Install Composer
COPY --from=composer:2.8.9 /usr/bin/composer /usr/local/bin/composer

# Set www-data home and workdir
RUN usermod -m -d /home/www-data www-data && \
    mkdir -p /var/www/html && \
    chown -R www-data:www-data /home/www-data /var/www/html

WORKDIR /var/www/html

# Copy composer files first for better layer caching
COPY --chown=www-data:www-data composer.json ./

# Install dependencies (no lock file yet, so this will resolve)
RUN composer install --optimize-autoloader --no-interaction --no-progress --no-dev 2>&1 || \
    composer update --optimize-autoloader --no-interaction --no-progress --no-dev 2>&1

# Copy application source
COPY --chown=www-data:www-data .env .env
COPY --chown=www-data:www-data web/ web/
COPY --chown=www-data:www-data src/ src/
COPY --chown=www-data:www-data config/ config/
COPY --chown=www-data:www-data bin/ bin/
RUN chmod +x bin/console

# Create var/ directory for Symfony cache/logs
RUN mkdir -p var/cache var/log && chown -R www-data:www-data var/

# Warm up Symfony cache
RUN php bin/console cache:warmup --env=prod --no-debug 2>/dev/null || true

# Copy PHP-FPM pool config template and entrypoint
COPY docker/www.conf.template /usr/local/etc/php-fpm.d/www.conf.template
COPY docker-php-entrypoint /usr/local/bin/docker-php-entrypoint
RUN chmod +x /usr/local/bin/docker-php-entrypoint

# Copy php.ini overrides (OTel extension config)
COPY php-ini-overrides.ini /usr/local/etc/php/conf.d/99-overrides.ini

# Default PHP-FPM worker count (overridable via env var)
ENV PHP_FPM_MAX_CHILDREN=4

EXPOSE 9000

USER www-data

ENTRYPOINT ["docker-php-entrypoint"]
CMD ["php-fpm"]
