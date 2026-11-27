#!/bin/bash

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "======================================"
echo " ZABBIX 8.0 LTS - INSTALACE"
echo " Debian 13"
echo "======================================"

# --------------------------------------
# 1. Aktualizace systému
# --------------------------------------

echo "[1/10] Aktualizace systému"

# Oprava GRUB: box může mít nastavený neexistující instalační disk.

if dpkg -s grub-pc >/dev/null 2>&1; then
    BOOT_SOURCE=$(findmnt -no SOURCE --target /boot)
    BOOT_DISK=$(lsblk -slnpo NAME,TYPE "$BOOT_SOURCE" | awk '$2 == "disk" && !d { d = $1 } END { print d }')

    if [ -z "$BOOT_DISK" ]; then
        echo "CHYBA: Nepodařilo se zjistit systémový disk pro GRUB."
        exit 1
    fi

    echo "GRUB disk: $BOOT_DISK"
    echo "grub-pc grub-pc/install_devices multiselect $BOOT_DISK" | debconf-set-selections
fi

# Dokončení případné přerušené instalace balíčků.

dpkg --configure -a

apt-get update
apt-get upgrade -y

# --------------------------------------
# 2. Instalace základních balíčků
# --------------------------------------

echo "[2/10] Instalace základních balíčků"

apt-get install -y \
    wget \
    curl \
    ca-certificates \
    openssl \
    mariadb-server \
    apache2 \
    php \
    php-mysql \
    php-gd \
    php-xml \
    php-bcmath \
    php-mbstring \
    php-ldap \
    php-curl \
    php-zip

# --------------------------------------
# 3. Přidání oficiálního repozitáře
# --------------------------------------

echo "[3/10] Přidání Zabbix 8.0 repozitáře"

cd /tmp

wget -q -O zabbix-release.deb \
https://repo.zabbix.com/zabbix/8.0/release/debian/pool/main/z/zabbix-release/zabbix-release_latest+debian13_all.deb

dpkg -i zabbix-release.deb

apt-get update

# --------------------------------------
# 4. Instalace Zabbix balíčků
# --------------------------------------

echo "[4/10] Instalace Zabbix Serveru a Agenta"

apt-get install -y \
    zabbix-server-mysql \
    zabbix-frontend-php \
    zabbix-apache-conf \
    zabbix-sql-scripts \
    zabbix-agent2

# --------------------------------------
# 5. Databáze a heslo
# --------------------------------------

echo "[5/10] Nastavení MariaDB"

systemctl enable --now mariadb

# Heslo se vygeneruje pouze při prvním spuštění.

if [ ! -s /root/.zabbix-db-password ]; then
    openssl rand -hex 24 > /root/.zabbix-db-password
    chmod 600 /root/.zabbix-db-password
fi

DB_PASSWORD=$(cat /root/.zabbix-db-password)

# Vytvoření databáze a uživatele.

mariadb <<SQL

CREATE DATABASE IF NOT EXISTS zabbix
CHARACTER SET utf8mb4
COLLATE utf8mb4_bin;

CREATE USER IF NOT EXISTS 'zabbix'@'localhost'
IDENTIFIED BY '${DB_PASSWORD}';

ALTER USER 'zabbix'@'localhost'
IDENTIFIED BY '${DB_PASSWORD}';

GRANT ALL PRIVILEGES ON zabbix.*
TO 'zabbix'@'localhost';

FLUSH PRIVILEGES;

SQL

# --------------------------------------
# 6. Import SQL schématu
# --------------------------------------

echo "[6/10] Import databázového schématu"

mkdir -p /var/lib/zabbix

# Přístupové údaje pro databázového klienta.

cat > /root/.zabbix-client.cnf <<EOF
[client]
user=zabbix
password=${DB_PASSWORD}
EOF

chmod 600 /root/.zabbix-client.cnf

SCHEMA_FILE="/usr/share/zabbix/sql-scripts/mysql/server.sql.gz"
IMPORT_MARKER="/var/lib/zabbix/.database-initialized"

if [ ! -f "$IMPORT_MARKER" ]; then

    # Tabulky bez značky = předchozí import mohl skončit v polovině.

    TABLE_EXISTS=$(mariadb \
        --defaults-extra-file=/root/.zabbix-client.cnf \
        zabbix \
        -Nse "SHOW TABLES;")

    if [ -n "$TABLE_EXISTS" ]; then
        echo "CHYBA: Databáze zabbix obsahuje tabulky, ale import není označen jako dokončený."
        echo "Zkontrolujte ji, případně ji smažte a spusťte skript znovu."
        exit 1
    fi

    # Díky set -e a pipefail se při chybě importu značka nevytvoří.

    zcat "$SCHEMA_FILE" | mariadb \
        --defaults-extra-file=/root/.zabbix-client.cnf \
        --default-character-set=utf8mb4 \
        zabbix

    touch "$IMPORT_MARKER"

    echo "Databázové schéma je připraveno."

else

    echo "Databázové schéma již bylo importováno."

fi

# --------------------------------------
# 7. Konfigurace Zabbix Serveru
# --------------------------------------

echo "[7/10] Konfigurace Zabbix Serveru"

SERVER_CONF="/etc/zabbix/zabbix_server.conf"

set_server_option() {

    local key="$1"
    local value="$2"

    if grep -qE "^#?${key}=" "$SERVER_CONF"; then
        sed -i -E \
            "s|^#?${key}=.*|${key}=${value}|" \
            "$SERVER_CONF"
    else
        echo "${key}=${value}" >> "$SERVER_CONF"
    fi
}

set_server_option DBHost localhost
set_server_option DBName zabbix
set_server_option DBUser zabbix
set_server_option DBPassword "$DB_PASSWORD"

chmod 640 "$SERVER_CONF"
chown root:zabbix "$SERVER_CONF"

# --------------------------------------
# 8. Konfigurace webového rozhraní
# --------------------------------------

echo "[8/10] Konfigurace Zabbix Frontendu"

mkdir -p /etc/zabbix/web

cat > /etc/zabbix/web/zabbix.conf.php <<PHP
<?php

// Automaticky vytvořený konfigurační soubor.

\$DB['TYPE'] = 'MYSQL';
\$DB['SERVER'] = 'localhost';
\$DB['PORT'] = '0';
\$DB['DATABASE'] = 'zabbix';
\$DB['USER'] = 'zabbix';
\$DB['PASSWORD'] = '${DB_PASSWORD}';
\$DB['SCHEMA'] = '';

\$ZBX_SERVER = 'localhost';
\$ZBX_SERVER_PORT = '10051';

\$ZBX_SERVER_NAME = 'Andreovsky_ZB8_Server';

\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;

PHP

chown root:www-data /etc/zabbix/web/zabbix.conf.php
chmod 640 /etc/zabbix/web/zabbix.conf.php

# --------------------------------------
# 9. PHP, Apache a Agent 2
# --------------------------------------

echo "[9/10] Konfigurace PHP, Apache a Agenta"

# Časové pásmo PHP.

PHP_INI=$(find /etc/php -path '*/apache2/php.ini' | head -n 1)

if [ -n "$PHP_INI" ]; then
    sed -i \
        's|^;*date.timezone =.*|date.timezone = Europe/Prague|' \
        "$PHP_INI"
fi

# Nastavení Agenta 2.

AGENT_CONF="/etc/zabbix/zabbix_agent2.conf"

set_agent_option() {

    local key="$1"
    local value="$2"

    # Odstranění původní aktivní i zakomentované varianty.

    sed -i "/^[[:space:]]*#*[[:space:]]*${key}=/d" \
        "$AGENT_CONF"

    echo "${key}=${value}" >> "$AGENT_CONF"
}

set_agent_option Server 127.0.0.1
set_agent_option ServerActive 127.0.0.1
set_agent_option Hostname "Andreovsky_ZB8_Server"

# --------------------------------------
# 10. Spuštění služeb
# --------------------------------------

echo "[10/10] Spuštění služeb"

systemctl enable --now mariadb
systemctl enable --now apache2
systemctl enable --now zabbix-server
systemctl enable --now zabbix-agent2

# Restart pro načtení konfigurace.

systemctl restart mariadb
systemctl restart apache2
systemctl restart zabbix-server
systemctl restart zabbix-agent2

echo "======================================"
echo " INSTALACE DOKONČENA"
echo "======================================"

systemctl is-active mariadb
systemctl is-active apache2
systemctl is-active zabbix-server
systemctl is-active zabbix-agent2

echo "Web: http://127.0.0.1:8080/zabbix"