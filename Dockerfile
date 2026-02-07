FROM php:8.3.23-fpm-bookworm AS base

LABEL version="8.3.23-fpm-bookworm-8"

ARG project_root=.
ENV REDIS_PREFIX=''
ENV NVM_DIR=/usr/local/nvm
ENV NODE_VERSION=24.12.0

# install required tools
# git for computing diffs
# wget for installation of other tools
# gnupg and g++ for gd extension
# locales for locale-gen command
# apt-utils so package configuartion does not get delayed
# unzip to ommit composer zip packages corruption
# dialog for apt-get to be
# git for computing diffs and for npm to download packages
RUN apt-get update && apt-get install -y wget gnupg g++ locales unzip dialog apt-utils git cron && apt-get clean

# create dir for Node Version Manager (NVM)
RUN mkdir -p $NVM_DIR

# install nvm
# https://github.com/creationix/nvm#install-script
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash

# install node and npm
RUN echo "source $NVM_DIR/nvm.sh && \
    nvm install $NODE_VERSION && \
    nvm alias default $NODE_VERSION && \
    nvm use default && \
    npm install -g npm@11.7.0" | bash

# add node and npm to path so the commands are available
ENV NODE_PATH=$NVM_DIR/v$NODE_VERSION/lib/node_modules
ENV PATH=$NVM_DIR/versions/node/v$NODE_VERSION/bin:$PATH

# install Composer
COPY --from=composer:2.8.9 /usr/bin/composer /usr/local/bin/composer

# libpng-dev needed by "gd" extension
# libzip-dev needed by "zip" extension
# libicu-dev for intl extension
# libpg-dev for connection to postgres database
# libpng-dev needed by "gd" extension
# lsb-release needed by postgres client to install
# autoconf needed by "redis" extension
# libffi-dev needed by "ffi" extension
RUN apt-get update && \
    apt-get install -y \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libzip-dev \
    libicu-dev \
    libpq-dev \
    fontforge \
    libpng-dev \
    lsb-release \
    libxslt-dev \
    bash \
    ca-certificates \
    vim \
    mc \
    nano \
    htop \
    autoconf \
    libffi-dev && \
    apt-get clean

# "gd" extension needs to have specified jpeg and freetype dir for jpg/jpeg images support
RUN docker-php-ext-configure gd --with-freetype=/usr/include/ --with-jpeg=/usr/include/

# install necessary tools for running application
RUN docker-php-ext-install \
    bcmath \
    ffi \
    gd \
    intl \
    opcache \
    pgsql \
    pdo_pgsql \
    xsl \
    zip

# install PostgreSQl client for dumping database
RUN wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - && \
    sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -sc)-pgdg main" > /etc/apt/sources.list.d/PostgreSQL.list' && \
    apt-get update && apt-get install -y postgresql-17 postgresql-client-17 && apt-get clean

# install redis extension
RUN pecl install redis-6.0.2 && \
    docker-php-ext-enable redis

RUN pecl install apcu && \
    docker-php-ext-enable apcu

# install OpenTelemetry auto-instrumentation extension
# The extension is installed via pecl. It will be enabled through php-ini-overrides.ini
# See: https://opentelemetry.io/docs/zero-code/php/
RUN pecl install opentelemetry

# install locales and switch to en_US.utf8 in order to enable UTF-8 support
# see http://jaredmarkell.com/docker-and-locales/ from where was this code taken
RUN sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# copy php.ini configuration
COPY ${project_root}/docker/php-fpm/php-ini-overrides.ini /usr/local/etc/php/php.ini

# overwrite the original entry-point from the PHP Docker image with our own
COPY ${project_root}/docker/php-fpm/docker-php-entrypoint /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-php-entrypoint

# set www-data user his home directory
# the user "www-data" is used when running the image, and therefore should own the workdir
RUN usermod -m -d /home/www-data www-data && \
    mkdir -p /var/www/html && \
    chown -R www-data:www-data /home/www-data /var/www/html

# set COMPOSER_MEMORY_LIMIT to -1 (i.e. unlimited - this is a hotfix until https://github.com/shopsys/shopsys/issues/634 is solved)
ENV COMPOSER_MEMORY_LIMIT=-1

ENV TZ=Europe/Prague

RUN ln -fs /usr/share/zoneinfo/$TZ /etc/localtime && dpkg-reconfigure -f noninteractive tzdata

USER www-data

########################################################################################################################

FROM slondevs/php-fpm-base:8.3.23-fpm-bookworm-8 AS development

ENV PHPSTAN_MAX_PROCS 8

USER root
RUN echo "ffi.enable=1" > /usr/local/etc/php/conf.d/99-ffi.ini

# Install php-memprof for memory leak profiling
# Extension is loaded but profiling is only active when MEMPROF_PROFILE env var is set
# Usage: MEMPROF_PROFILE=dump_on_limit php phing your-command
# Profile will be saved to /tmp/memprof.callgrind.* when memory limit is exceeded
RUN apt-get update && apt-get install -y libjudy-dev && apt-get clean && \
    pecl install memprof && \
    echo "extension=memprof.so" > /usr/local/etc/php/conf.d/memprof.ini && \
    echo "memprof.output_dir=/tmp" >> /usr/local/etc/php/conf.d/memprof.ini

# Install pcntl extension for periodic memory snapshots (used by bin/memprof-snapshots.php)
RUN docker-php-ext-install pcntl

# allow overwriting UID and GID o the user "www-data" to help solve issues with permissions in mounted volumes
# if the GID is already in use, we will assign GID 33 instead (33 is the standard uid/gid for "www-data" in Debian)
ARG www_data_uid
ARG www_data_gid
RUN if [ -n "$www_data_uid" ]; then deluser www-data && (addgroup --gid $www_data_gid www-data || addgroup --gid 33 www-data) && adduser --system --home /home/www-data --uid $www_data_uid --disabled-password --group www-data; fi;

# as the UID and GID might have changed, change the ownership of the home directory workdir again
RUN chown -R www-data:www-data /home/www-data /var/www/html

ARG TIMEZONE
RUN if [ -n "$TIMEZONE" ]; then echo "date.timezone = ${TIMEZONE}" > /usr/local/etc/php/conf.d/timezone.ini; fi

RUN echo "expose_php = Off" > /usr/local/etc/php/conf.d/security.ini

USER www-data

########################################################################################################################

FROM slondevs/php-fpm-base:8.3.23-fpm-bookworm-8 AS production

ENV TIMEZONE="UTC"
# CI=true disables cache:clear in composer auto-scripts (requires running services)
ENV CI=true

# optionally install php-memprof in production when ARG is set
ARG INSTALL_DEBUGTOOLS

COPY --chown=www-data:www-data / /var/www/html

USER root
RUN echo "ffi.enable=1" > /usr/local/etc/php/conf.d/99-ffi.ini
RUN if [ -n "$INSTALL_DEBUGTOOLS" ]; then \
    apt-get update && apt-get install -y libjudy-dev && apt-get clean && \
    pecl install memprof && \
    echo "extension=memprof.so" > /usr/local/etc/php/conf.d/memprof.ini && \
    echo "memprof.output_dir=/tmp" >> /usr/local/etc/php/conf.d/memprof.ini; \
    fi
USER www-data

RUN composer install --optimize-autoloader --no-interaction --no-progress --no-dev

RUN php phing build-deploy-part-1-db-independent clean-var

RUN chmod +x ./deploy/deploy-project.sh && ./deploy/deploy-project.sh merge

USER root

RUN echo "expose_php = Off" > /usr/local/etc/php/conf.d/security.ini

USER www-data
