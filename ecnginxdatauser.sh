#!/bin/bash

set -e

echo "=============================="
echo "  UBUNTU EC2 BOOTSTRAP START"
echo "=============================="

# ==============================
# Update system
# ==============================
apt update -y
apt upgrade -y

# ==============================
# Install Docker if missing
# ==============================
if ! command -v docker >/dev/null 2>&1; then
    echo "[INFO] Installing Docker..."

    apt install -y ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list

    apt update -y

    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
    echo "[INFO] Docker already installed"
fi

systemctl enable docker
systemctl start docker

usermod -aG docker ubuntu || true

# ==============================
# Verify Docker Compose
# ==============================
if ! docker compose version >/dev/null 2>&1; then
    echo "[ERROR] Docker Compose not found!"
    exit 1
fi

# ==============================
# App directory
# ==============================
mkdir -p /opt/demo/nginx
cd /opt/demo

# ==============================
# Nginx config
# ==============================
cat > nginx/default.conf <<'EOF'
server {
    listen 80;

    location / {
        proxy_pass http://app:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

# ==============================
# docker-compose.yml
# ==============================
cat > docker-compose.yml <<'EOF'
services:

  kafka:
    image: bitnami/kafka:latest
    container_name: kafka
    restart: unless-stopped

    environment:
      - KAFKA_CFG_NODE_ID=1
      - KAFKA_CFG_PROCESS_ROLES=broker,controller
      - KAFKA_CFG_CONTROLLER_LISTENER_NAMES=CONTROLLER
      - KAFKA_CFG_LISTENERS=PLAINTEXT://:9092,CONTROLLER://:9093
      - KAFKA_CFG_ADVERTISED_LISTENERS=PLAINTEXT://kafka:9092
      - KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
      - KAFKA_CFG_CONTROLLER_QUORUM_VOTERS=1@kafka:9093
      - KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE=true
      - KAFKA_KRAFT_CLUSTER_ID=abcdefghijklmnopqrstuv

    volumes:
      - kafka_data:/bitnami/kafka

    mem_limit: 2g

  app:
    image: springio/gs-spring-boot-docker
    container_name: app
    restart: unless-stopped

    depends_on:
      - kafka

    expose:
      - "8080"

    mem_limit: 1g

  nginx:
    image: nginx:alpine
    container_name: nginx
    restart: unless-stopped

    depends_on:
      - app

    ports:
      - "80:80"

    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro

    mem_limit: 256m

volumes:
  kafka_data:
EOF

# ==============================
# Start stack
# ==============================
echo "[INFO] Starting containers..."

cd /opt/demo

docker compose up -d

# ==============================
# Done
# ==============================
echo "=============================="
echo "  DEPLOY COMPLETE"
echo "=============================="

docker ps
