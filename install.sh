#!/usr/bin/env bash
set -euo pipefail

echo "====================================="
echo "   n8n One-Click Production Installer"
echo "====================================="

#---------------------------------------
# 1) Ask for domain + email
#---------------------------------------
read -rp "Enter your domain (e.g. domain.com): " DOMAIN
read -rp "Enter admin email (for SSL notices): " ADMIN_EMAIL

#---------------------------------------
# 2) Update & install packages
#---------------------------------------
echo "[1/9] Updating system..."
apt update && apt upgrade -y

echo "[2/9] Installing dependencies..."
apt install -y curl git ufw nginx certbot python3-certbot-nginx awscli

#---------------------------------------
# 3) Install Docker
#---------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "[3/9] Installing Docker..."
    curl -fsSL https://get.docker.com | bash
fi
systemctl enable docker
systemctl start docker

#---------------------------------------
# 4) Install Docker Compose
#---------------------------------------
if ! command -v docker-compose >/dev/null 2>&1; then
    echo "[4/9] Installing Docker Compose..."
    DC_VER="2.24.5"
    curl -L "https://github.com/docker/compose/releases/download/v${DC_VER}/docker-compose-linux-x86_64" \
        -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

#---------------------------------------
# 5) Prepare directories
#---------------------------------------
echo "[5/9] Preparing directories..."
mkdir -p /var/n8n /var/n8n/db /var/n8n/n8n /var/n8n/backups
chown -R 1000:1000 /var/n8n/n8n

cd /var/n8n

#---------------------------------------
# 6) Generate .env
#---------------------------------------
gen_secret() { openssl rand -base64 32 | tr -d '\n'; }

POSTGRES_PASSWORD_VALUE=$(gen_secret)
N8N_ENCRYPTION_VALUE=$(gen_secret)

cat > .env <<EOF
DOMAIN=${DOMAIN}
ADMIN_EMAIL=${ADMIN_EMAIL}

N8N_HOST=${DOMAIN}
N8N_PORT=5678
N8N_PROTOCOL=https
WEBHOOK_URL=https://${DOMAIN}/
GENERIC_TIMEZONE=Asia/Kolkata
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_VALUE}

POSTGRES_USER=n8n
POSTGRES_PASSWORD=${POSTGRES_PASSWORD_VALUE}
POSTGRES_DB=n8n

BACKUP_DIR=/var/n8n/backups
BACKUP_RETENTION_DAYS=7

S3_BUCKET=
S3_PREFIX=n8n-backups
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_DEFAULT_REGION=ap-south-1
EOF

echo "[ OK ] .env created"

#---------------------------------------
# 7) Generate docker-compose.yml
#---------------------------------------
cat > docker-compose.yml <<'EOF'
version: "3.8"

services:
  postgres:
    image: postgres:15
    restart: always
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - ./db:/var/lib/postgresql/data

  n8n:
    image: n8nio/n8n:latest
    restart: always
    ports:
      - "5678:5678"
    environment:
      N8N_HOST: ${N8N_HOST}
      N8N_PORT: ${N8N_PORT}
      N8N_PROTOCOL: ${N8N_PROTOCOL}
      WEBHOOK_URL: ${WEBHOOK_URL}

      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}

      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}

    depends_on:
      - postgres
    volumes:
      - ./n8n:/home/node/.n8n
EOF

echo "[ OK ] docker-compose.yml created"

#---------------------------------------
# 8) Generate Nginx config
#---------------------------------------
cat > /etc/nginx/sites-available/n8n <<EOF
server {
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://localhost:5678/;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
    }

    client_max_body_size 50m;
}
EOF

ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
nginx -t && systemctl restart nginx
echo "[ OK ] Nginx config installed"

#---------------------------------------
# 9) Install backup script
#---------------------------------------
cat >/usr/local/bin/n8n-backup.sh <<'BKP'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/var/n8n/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
else
  echo "Missing $ENV_FILE"
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d-%H%M)"
mkdir -p "$BACKUP_DIR"

echo "[backup] Dumping Postgres..."
docker exec n8n-postgres-1 pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" | gzip > "$BACKUP_DIR/postgres-$TIMESTAMP.sql.gz"

echo "[backup] Archiving n8n config..."
tar -czf "$BACKUP_DIR/n8n-config-$TIMESTAMP.tar.gz" -C /var/n8n n8n

echo "[backup] Cleanup retention..."
find "$BACKUP_DIR" -type f -mtime +${BACKUP_RETENTION_DAYS} -delete || true

if [ -n "${S3_BUCKET:-}" ]; then
  aws s3 sync "$BACKUP_DIR" "s3://${S3_BUCKET}/${S3_PREFIX}" --only-show-errors
fi

echo "[backup] Done."
BKP

chmod +x /usr/local/bin/n8n-backup.sh
(crontab -l 2>/dev/null | grep -v 'n8n-backup.sh' ; echo "30 2 * * * /usr/local/bin/n8n-backup.sh >> /var/log/n8n-backup.log 2>&1") | crontab -

#---------------------------------------
# 10) Start Docker Stack
#---------------------------------------
echo "[Docker] Starting n8n..."
docker-compose pull
docker-compose up -d

chown -R 1000:1000 /var/n8n/n8n

#---------------------------------------
# 11) SSL (Let's Encrypt)
#---------------------------------------
echo "[SSL] Requesting certificate..."
certbot --nginx -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos -n || true

#---------------------------------------
# 12) Display Database Password ONCE
#---------------------------------------
DB_PASS=$(grep POSTGRES_PASSWORD /var/n8n/.env | cut -d= -f2-)

echo ""
echo "====================================="
echo "🔐 IMPORTANT — SAVE YOUR DB PASSWORD"
echo "====================================="
echo "PostgreSQL Password:"
echo "-------------------------------------"
echo "$DB_PASS"
echo "-------------------------------------"
echo "⚠️ You will NOT be shown this password again."
echo "It is stored securely in: /var/n8n/.env"
echo "====================================="
echo ""

#---------------------------------------
# 13) Done
#---------------------------------------
echo "====================================="
echo "   🎉 INSTALL COMPLETE!"
echo "====================================="
echo "URL: https://${DOMAIN}"
echo "Backups: /var/n8n/backups"
echo "Cron: Daily at 02:30"
echo "====================================="
