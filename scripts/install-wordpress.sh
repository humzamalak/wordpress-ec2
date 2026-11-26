#!/usr/bin/env bash
# Install WordPress on Amazon Linux 2023 (Apache, PHP, MariaDB on one host).
# These are the same steps as docs/manual-setup.md, in one script.
# Run as root:  sudo bash install-wordpress.sh
set -euo pipefail

DB_NAME=wordpress
DB_USER=wordpress
WEB_ROOT=/var/www/html
CREDS=/root/wordpress-db.txt

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

echo "1/6 Install packages"
dnf -y upgrade --refresh
dnf -y install httpd php php-fpm php-mysqlnd php-gd php-mbstring php-xml php-intl php-zip mariadb105-server

echo "2/6 Start services"
systemctl enable --now mariadb httpd php-fpm

echo "3/6 Secure MariaDB and create the WordPress database"
if [[ ! -f "$CREDS" ]]; then
  DB_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
  umask 077
  printf 'DB_NAME=%s\nDB_USER=%s\nDB_PASS=%s\n' "$DB_NAME" "$DB_USER" "$DB_PASS" > "$CREDS"
fi
# shellcheck source=/dev/null
source "$CREDS"
mysql --protocol=socket <<SQL
DELETE FROM mysql.global_priv WHERE User='';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
# MariaDB listens on localhost only; nothing outside the instance can reach it.
cat > /etc/my.cnf.d/zz-local-only.cnf <<'CNF'
[mysqld]
bind-address = 127.0.0.1
CNF
systemctl restart mariadb

echo "4/6 Download and verify WordPress"
if [[ ! -f "$WEB_ROOT/wp-settings.php" ]]; then
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/latest.tar.gz" https://wordpress.org/latest.tar.gz
  curl -fsSL -o "$tmp/latest.tar.gz.sha1" https://wordpress.org/latest.tar.gz.sha1
  echo "$(cat "$tmp/latest.tar.gz.sha1")  $tmp/latest.tar.gz" | sha1sum -c -
  tar -xzf "$tmp/latest.tar.gz" -C "$tmp"
  cp -a "$tmp/wordpress/." "$WEB_ROOT/"
  rm -rf "$tmp"
fi

echo "5/6 Configure wp-config.php"
if [[ ! -f "$WEB_ROOT/wp-config.php" ]]; then
  cp "$WEB_ROOT/wp-config-sample.php" "$WEB_ROOT/wp-config.php"
  sed -i "s/database_name_here/${DB_NAME}/; s/username_here/${DB_USER}/; s/password_here/${DB_PASS}/" "$WEB_ROOT/wp-config.php"
  # Replace the placeholder keys and salts with fresh random values.
  salts=$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/)
  python3 - "$WEB_ROOT/wp-config.php" "$salts" <<'PY'
import re, sys
path, salts = sys.argv[1], sys.argv[2]
text = open(path).read()
text, n = re.subn(r"define\( 'AUTH_KEY'.*?define\( 'NONCE_SALT',\s*'put your unique phrase here' \);", lambda m: salts, text, flags=re.S)
if n != 1:
    sys.exit("could not find the key and salt block in wp-config.php")
text = text.replace("/* That's all, stop editing!", "define( 'DISALLOW_FILE_EDIT', true );\n\n/* That's all, stop editing!")
open(path, "w").write(text)
PY
fi

echo "6/6 File permissions and Apache settings"
chown -R apache:apache "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod 755 {} +
find "$WEB_ROOT" -type f -exec chmod 644 {} +
chmod 640 "$WEB_ROOT/wp-config.php"
cat > /etc/httpd/conf.d/wordpress.conf <<'CONF'
ServerTokens Prod
ServerSignature Off
<Directory /var/www/html>
    AllowOverride All
    Require all granted
</Directory>
# Block direct access to sensitive files.
<FilesMatch "^(wp-config\.php|readme\.html|license\.txt|xmlrpc\.php)$">
    Require all denied
</FilesMatch>
CONF
systemctl restart httpd

echo
echo "Done. Open http://<public-ip>/ and finish the WordPress set-up wizard."
echo "Database credentials are in $CREDS (root only)."
