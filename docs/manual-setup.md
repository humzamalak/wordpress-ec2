# Manual WordPress set-up on EC2 (console and shell)

These are the steps to do by hand once, so you know what each part does. `scripts/install-wordpress.sh` runs steps 4 to 9 in one go, and `terraform/` builds the AWS side. Region in the examples: `eu-west-2`.

## 1. Launch the instance (EC2 console)

1. EC2, **Launch instance**.
2. Name: `wordpress`. AMI: **Amazon Linux 2023**. Type: `t3.micro`.
3. Key pair: **Proceed without a key pair**. You connect with Session Manager instead of SSH.
4. Network: default VPC, a public subnet, **Auto-assign public IP: Enable**.
5. Security group: create `wordpress-web` with inbound **HTTP 80** and **HTTPS 443** from `0.0.0.0/0`. Do not add SSH 22.
6. Storage: 20 GiB **gp3**, **Encrypted**.
7. Advanced: IAM instance profile with the `AmazonSSMManagedInstanceCore` policy. Metadata: **IMDSv2 only**.
8. Launch.

## 2. Give it a fixed address

EC2, **Elastic IPs**, Allocate, then Associate with the instance. A normal public IP changes when the instance stops.

## 3. Connect

EC2, select the instance, **Connect**, **Session Manager**, Connect. Then `sudo -i`.

## 4. Install Apache, PHP and MariaDB

```bash
dnf -y upgrade --refresh
dnf -y install httpd php php-fpm php-mysqlnd php-gd php-mbstring php-xml php-intl php-zip mariadb105-server
systemctl enable --now mariadb httpd php-fpm
```

Check: `curl -sI http://localhost | head -1` returns `HTTP/1.1 403 Forbidden` (Apache test page, no content yet).

## 5. Secure MariaDB and create the database

```bash
mysql_secure_installation          # set root auth, remove anonymous users and the test database
mysql -u root -p
```

```sql
CREATE DATABASE wordpress CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'wordpress'@'localhost' IDENTIFIED BY '<long random password>';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'localhost';
FLUSH PRIVILEGES;
```

Make MariaDB listen on localhost only: add `bind-address = 127.0.0.1` under `[mysqld]` in `/etc/my.cnf.d/zz-local-only.cnf`, then `systemctl restart mariadb`.

## 6. Download WordPress and check the checksum

```bash
cd /tmp
curl -fsSLO https://wordpress.org/latest.tar.gz
curl -fsSLO https://wordpress.org/latest.tar.gz.sha1
echo "$(cat latest.tar.gz.sha1)  latest.tar.gz" | sha1sum -c -     # must print: latest.tar.gz: OK
tar -xzf latest.tar.gz
cp -a wordpress/. /var/www/html/
```

## 7. Configure wp-config.php

```bash
cd /var/www/html
cp wp-config-sample.php wp-config.php
vi wp-config.php
```

- Set `DB_NAME`, `DB_USER` and `DB_PASSWORD`.
- Replace the eight `put your unique phrase here` lines with fresh values from <https://api.wordpress.org/secret-key/1.1/salt/>.
- Add `define( 'DISALLOW_FILE_EDIT', true );` so the admin panel cannot edit PHP files.

## 8. Permissions and Apache settings

```bash
chown -R apache:apache /var/www/html
find /var/www/html -type d -exec chmod 755 {} +
find /var/www/html -type f -exec chmod 644 {} +
chmod 640 /var/www/html/wp-config.php
```

Create `/etc/httpd/conf.d/wordpress.conf`: allow `.htaccess` (`AllowOverride All`) for permalinks, hide the Apache version (`ServerTokens Prod`), and deny direct access to `wp-config.php`, `readme.html`, `license.txt` and `xmlrpc.php`. See the script for the exact file. Then `systemctl restart httpd`.

## 9. Finish in the browser

Open `http://<elastic-ip>/`, choose the language, site title, admin user (not `admin`) and a strong password.

## 10. HTTPS (needs a domain)

Point an `A` record at the Elastic IP, then:

```bash
dnf -y install python3-pip augeas-libs mod_ssl
python3 -m venv /opt/certbot && /opt/certbot/bin/pip install certbot certbot-apache
/opt/certbot/bin/certbot --apache -d blog.example.com
```

Certbot edits the Apache config and sets up redirection to HTTPS. Add a renewal timer or cron job for `certbot renew`.

## 11. Backups

Data Lifecycle Manager, **Create EBS snapshot policy**: target tag `Backup = daily`, every 24 hours, keep 7. Tag the instance `Backup = daily`. Test a restore once: create a volume from a snapshot and attach it to a test instance.

## What this set-up does not do

- One instance runs web and database. If it fails, the site is down. The next step is RDS for the database and an Auto Scaling group behind an ALB, with `wp-content/uploads` on S3 or EFS.
- Updates are manual: `dnf upgrade` for the OS and the WordPress dashboard for core, themes and plugins.
