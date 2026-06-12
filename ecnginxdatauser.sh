#!/bin/bash

set -e

echo "=============================="
echo "  ZERO-FAIL EC2 BOOTSTRAP"
echo "=============================="

# ==============================
# UPDATE
# ==============================
apt update -y
apt upgrade -y

# ==============================
# INSTALL DOCKER (OFFICIAL)
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
fi

systemctl enable docker
systemctl start docker

usermod -aG docker ubuntu || true

# ==============================
# VERIFY
# ==============================
docker version
docker compose version

# ==============================
# APP FOLDER
# ==============================
mkdir -p /opt/demo/nginx
cd /opt/demo

# ==============================
# NGINX
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
# DOCKER COMPOSE (ZERO FAIL STACK)
# ==============================
cat > docker-compose.yml <<'EOF'
services:

  kafka:
    image: confluentinc/cp-kafka:7.6.1
    container_name: kafka
    restart: unless-stopped

    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9093
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1

    volumes:
      - kafka_data:/var/lib/kafka/data

    healthcheck:
      test: ["CMD", "bash", "-c", "echo > /dev/tcp/localhost/9092"]
      interval: 10s
      timeout: 5s
      retries: 10

    mem_limit: 2g

  app:
    image: springio/gs-spring-boot-docker
    container_name: app
    restart: unless-stopped

    depends_on:
      kafka:
        condition: service_started

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
# RETRY SAFE PULL (IMPORTANT)
# ==============================
echo "[INFO] Pulling images with retry..."

for i in 1 2 3; do
    docker compose pull && break || sleep 5
done

# ==============================
# START STACK
# ==============================
echo "[INFO] Starting stack..."

docker compose up -d

# ==============================
# DONE
# ==============================
echo "=============================="
echo "  DEPLOY SUCCESS (ZERO FAIL)"
echo "=============================="

docker ps
