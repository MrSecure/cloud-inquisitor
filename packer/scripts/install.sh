#!/bin/bash -e

validate_environment() {
    echo "Validating environment"
    if [ -z "${APP_TEMP_BASE}" ]; then echo "Missing APP_TEMP_BASE environment variable" && exit -1; fi
    if [ -z "${APP_DEBUG}" ]; then echo "Missing APP_DEBUG environment variable" && exit -1; fi
    if [ -z "${APP_PYENV_PATH}" ]; then echo "Missing APP_PYENV_PATH environment variable" && exit -1; fi
    if [ -z "${APP_FRONTEND_BASE_PATH}" ]; then echo "Missing APP_FRONTEND_BASE_PATH environment variable" && exit -1; fi
    if [ -z "${APP_CONFIG_BASE_PATH}" ]; then echo "Missing APP_CONFIG_BASE_PATH environment variable" && exit -1; fi
    if [ -z "${APP_DB_URI}" ]; then echo "Missing APP_DB_URI environment variable" && exit -1; fi
    if [ -z "${APP_SSL_ENABLED}" ]; then echo "Missing APP_SSL_ENABLED environment variable" && exit -1; fi
    if [ -z "${APP_WORKER_PROCS}" ]; then echo "Missing APP_WORKER_PROCS environment variable" && exit -1; fi
    if [ -z "${APP_USE_USER_DATA}" ]; then echo "Missing APP_USE_USER_DATA environment variable" && exit -1; fi
    if [ -z "${APP_KMS_ACCOUNT_NAME}" ]; then echo "Missing APP_KMS_ACCOUNT_NAME environment variable" && exit -1; fi
    if [ -z "${APP_KMS_REGION}" ]; then echo "Missing APP_KMS_REGION environment variable" && exit -1; fi
    if [ -z "${APP_USER_DATA_URL}" ]; then echo "Missing APP_USER_DATA_URL environment variable" && exit -1; fi
}

create_virtualenv() {
    echo "Setting up python virtualenv"

    if [ -d "${APP_PYENV_PATH}" ]; then
        echo "VirtualEnv folder already exists, skipping"
    else
        virtualenv -p python3 "${APP_PYENV_PATH}"
    fi
}

install_backend() {
    python=${APP_PYENV_PATH}/bin/python3
    pip=${APP_PYENV_PATH}/bin/pip3

    echo "Installing backend"
    mkdir -p ${APP_CONFIG_BASE_PATH}/ssl
    mkdir -p /var/log/cloud-inquisitor
    touch /var/log/cloud-inquisitor/apiserver.log \
          /var/log/cloud-inquisitor/default.log \
          /var/log/cloud-inquisitor/scheduler.log \
          ${APP_CONFIG_BASE_PATH}/aws_regions.json

    chown www-data:www-data -R /var/log/cloud-inquisitor \
                               ${APP_CONFIG_BASE_PATH}/aws_regions.json

    $pip install cloud-inquisitor
}

install_frontend() {
    mkdir -p ${APP_FRONTEND_BASE_PATH}
    curl -L http://releases.cloud-inquisitor.io/cinq-frontend-latest.tar.gz | tar -C ${APP_FRONTEND_BASE_PATH} -xzf -
}

configure_application() {
    echo "Configuring backend"

    mkdir -p ${APP_CONFIG_BASE_PATH}
    SECRET_KEY=$(openssl rand -hex 32)

    sed -e "s|APP_DB_URI|${APP_DB_URI}|" \
        -e "s|APP_SECRET_KEY|${SECRET_KEY}|" \
        -e "s|APP_USE_USER_DATA|${APP_USE_USER_DATA,,}|" \
        -e "s|APP_USER_DATA_URL|${APP_USER_DATA_URL}|" \
        -e "s|APP_KMS_ACCOUNT_NAME|${APP_KMS_ACCOUNT_NAME}|" \
        -e "s|APP_KMS_REGION|${APP_KMS_REGION}|" \
        -e "s|APP_AWS_API_ACCESS_KEY|${APP_AWS_API_ACCESS_KEY}|" \
        -e "s|APP_AWS_API_SECRET_KEY|${APP_AWS_API_SECRET_KEY}|" \
        -e "s|APP_INSTANCE_ROLE_ARN|${APP_INSTANCE_ROLE_ARN}|" \
        files/backend-config.json > ${APP_CONFIG_BASE_PATH}/config.json

    cp files/logging.json ${APP_CONFIG_BASE_PATH}/logging.json
}

install_certs() {
    if [ -z "$APP_SSL_CERT_DATA" -o -z "$APP_SSL_KEY_DATA" ]; then
        echo "Certificate or key data missing, installing self-signed cert"
        generate_self_signed_certs
    else
        echo "Installing certificates"
        CERTDATA=$(echo "$APP_SSL_CERT_DATA" | base64 -d)
        KEYDATA=$(echo "$APP_SSL_KEY_DATA" | base64 -d)

        echo "$CERTDATA" > $APP_CONFIG_BASE_PATH/ssl/cinq-frontend.crt
        echo "$KEYDATA" > $APP_CONFIG_BASE_PATH/ssl/cinq-frontend.key
    fi
}

function generate_jwt_key() {
    echo "Generating JWT private key"
    openssl genrsa -out ${APP_CONFIG_BASE_PATH}/ssl/private.key 2048
}

generate_self_signed_certs() {
    CERTINFO="/C=US/ST=CA/O=Your Company/localityName=Your City/commonName=localhost/organizationalUnitName=Operations/emailAddress=someone@example.com"
    openssl req -x509 -subj "$CERTINFO" -days 3650 -newkey rsa:2048 -nodes \
        -keyout ${APP_CONFIG_BASE_PATH}/ssl/cinq-frontend.key \
        -out ${APP_CONFIG_BASE_PATH}/ssl/cinq-frontend.crt
}

configure_nginx() {
    if [ "${APP_SSL_ENABLED}" = "True" ]; then
        echo "Configuring nginx with ssl"
        NGINX_CFG="nginx-ssl.conf"
    else
        echo "Configuring nginx without ssl"
        NGINX_CFG="nginx-nossl.conf"
    fi

    sed -e "s|APP_FRONTEND_BASE_PATH|${APP_FRONTEND_BASE_PATH}|g" \
        -e "s|APP_CONFIG_BASE_PATH|${APP_CONFIG_BASE_PATH}|g" \
        files/${NGINX_CFG} > /etc/nginx/sites-available/cinq.conf

    rm -f /etc/nginx/sites-enabled/default;
    ln -sf /etc/nginx/sites-available/cinq.conf /etc/nginx/sites-enabled/cinq.conf
    # redirect output to assign in-function stdout/err to global
    service nginx restart 1>&1 2>&2
}

configure_supervisor() {
    echo "Configuring supervisor"
    sed -e "s|APP_CONFIG_BASE_PATH|${APP_CONFIG_BASE_PATH}|g" \
        -e "s|APP_PYENV_PATH|${APP_PYENV_PATH}|g" \
        -e "s|APP_WORKER_PROCS|${APP_WORKER_PROCS}|g" \
        files/supervisor.conf > /etc/supervisor/conf.d/cinq.conf

    # If running on a systemd enabled system, ensure the service is enabled and running
    if [ ! -z "$(which systemctl)" ]; then
        systemctl enable supervisor.service
    else
        update-rc.d supervisor enable
    fi
}

cd ${APP_TEMP_BASE}

validate_environment
create_virtualenv
install_frontend
install_backend
install_certs
generate_jwt_key
configure_application
configure_supervisor
configure_nginx
