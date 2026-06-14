#!/bin/bash

# Deploy remoto su Oracle Cloud — stesso flusso di xstream-server/deploy-remote.sh
# 1. build locale  2. rsync sulla VM  3. docker compose up -d

set -e

ORACLE_IP="84.8.248.50"
ORACLE_USER="opc"
SSH_KEY="ssh-key-2025-11-23.key"
PROJECT_DIR="extreme-infinitv"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Fallback chiave da xstream-server
if [ ! -f "$SSH_KEY" ] && [ -f "../xstream-server/$SSH_KEY" ]; then
    SSH_KEY="../xstream-server/$SSH_KEY"
fi

echo "🚀 Deploy Remoto Leleg IPTV su Oracle Cloud"
echo "==========================================="
echo ""

if [ ! -f "$SSH_KEY" ]; then
    echo -e "${RED}❌ Chiave SSH non trovata: $SSH_KEY${NC}"
    exit 1
fi

chmod 600 "$SSH_KEY"

# Estendi PATH per pnpm
for extra in \
  "$HOME/.nvm/versions/node/$(ls "$HOME/.nvm/versions/node/" 2>/dev/null | sort -V | tail -1)/bin" \
  "/opt/homebrew/bin" "/usr/local/bin"
do [ -d "$extra" ] && export PATH="$extra:$PATH"; done

PNPM="pnpm"
command -v pnpm &>/dev/null || \
  { [ -x "$ROOT/node_modules/.bin/pnpm" ] && PNPM="$ROOT/node_modules/.bin/pnpm"; } || \
  { echo -e "${RED}❌ pnpm non trovato${NC}"; exit 1; }

echo -e "${YELLOW}🔨 Build locale...${NC}"
$PNPM build:pages
[ -f "dist/index.html" ] || { echo -e "${RED}❌ Build fallita: dist/index.html mancante${NC}"; exit 1; }
echo -e "${GREEN}✅ Build completata${NC}"
echo ""

echo -e "${YELLOW}🔍 Verifica connessione SSH...${NC}"
if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$ORACLE_USER@$ORACLE_IP" "echo 'Connessione OK'" 2>/dev/null; then
    echo -e "${GREEN}✅ Connessione SSH riuscita${NC}"
else
    echo -e "${RED}❌ Impossibile connettersi alla VM${NC}"
    echo "Verifica:"
    echo "  - IP corretto: $ORACLE_IP"
    echo "  - Utente Oracle Linux: opc (non ubuntu)"
    echo "  - Security Rules: porta 22 TCP"
    echo "  - Chiave SSH: $SSH_KEY"
    exit 1
fi

echo -e "${YELLOW}📦 Caricamento file sulla VM...${NC}"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$ORACLE_USER@$ORACLE_IP" "mkdir -p ~/$PROJECT_DIR"

if command -v rsync &> /dev/null; then
    echo "Usando rsync per il trasferimento..."
    rsync -avz --progress \
        --exclude='node_modules/' \
        --exclude='.git/' \
        --exclude='.wrangler/' \
        --exclude='src-tauri/' \
        --exclude='.astro/' \
        --exclude='*.apk' \
        --exclude='*.zip' \
        --exclude='*.log' \
        --exclude='.env' \
        --exclude='ssh-key-*.key' \
        -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
        ./ "$ORACLE_USER@$ORACLE_IP:~/$PROJECT_DIR/"
else
    echo "Usando scp per il trasferimento..."
    tar --exclude='node_modules' \
        --exclude='.git' \
        --exclude='.wrangler' \
        --exclude='src-tauri' \
        --exclude='.astro' \
        --exclude='*.apk' \
        --exclude='*.zip' \
        --exclude='*.log' \
        --exclude='.env' \
        --exclude='ssh-key-*.key' \
        -czf /tmp/extreme-infinitv-deploy.tar.gz .
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/extreme-infinitv-deploy.tar.gz "$ORACLE_USER@$ORACLE_IP:~/$PROJECT_DIR/"
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$ORACLE_USER@$ORACLE_IP" "cd ~/$PROJECT_DIR && tar -xzf extreme-infinitv-deploy.tar.gz && rm extreme-infinitv-deploy.tar.gz"
    rm /tmp/extreme-infinitv-deploy.tar.gz
fi

echo -e "${GREEN}✅ File caricati sulla VM${NC}"

echo ""
echo -e "${YELLOW}🔧 Verifica installazione Docker...${NC}"
DOCKER_NEEDS_FIX=false
if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$ORACLE_USER@$ORACLE_IP" "command -v docker > /dev/null 2>&1 && sudo systemctl is-active --quiet docker 2>/dev/null" 2>/dev/null; then
    DOCKER_NEEDS_FIX=true
fi

if [ "$DOCKER_NEEDS_FIX" = true ]; then
    echo "Docker non è installato correttamente, correzione in corso..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$ORACLE_USER@$ORACLE_IP" << 'ENDSSH'
    sudo yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
    sudo yum install -y yum-utils
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl start docker
    sudo systemctl enable docker
    sudo usermod -aG docker opc
    echo "✅ Docker installato correttamente!"
ENDSSH
else
    echo "✅ Docker è già installato e funzionante"
fi

echo ""
echo -e "${YELLOW}🚀 Esecuzione deploy sulla VM...${NC}"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$ORACLE_USER@$ORACLE_IP" << ENDSSH
cd ~/$PROJECT_DIR
chmod +x deploy.sh 2>/dev/null || true

if docker ps > /dev/null 2>&1; then
    NON_INTERACTIVE=1 ./deploy.sh
else
    echo "Docker richiede sudo, esecuzione manuale..."

    if ! command -v docker-compose &> /dev/null && ! docker compose version > /dev/null 2>&1; then
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi

    if docker compose version > /dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    else
        DOCKER_COMPOSE_CMD="docker-compose"
    fi

    sudo \$DOCKER_COMPOSE_CMD up -d
    sleep 5

    if sudo \$DOCKER_COMPOSE_CMD ps | grep -q "Up"; then
        echo "✅ Container avviati con successo!"
        sudo \$DOCKER_COMPOSE_CMD ps
        sudo \$DOCKER_COMPOSE_CMD logs --tail=20
    else
        echo "❌ Errore durante l'avvio dei container"
        sudo \$DOCKER_COMPOSE_CMD logs
        exit 1
    fi
fi
ENDSSH

echo ""
echo -e "${GREEN}🎉 Deploy completato!${NC}"
echo ""
echo "L'applicazione è disponibile su:"
echo "  http://$ORACLE_IP"
echo ""
echo "Per controllare i log:"
echo "  ssh -i $SSH_KEY $ORACLE_USER@$ORACLE_IP 'cd ~/$PROJECT_DIR && docker compose logs -f'"
