#!/bin/bash

# Dal Mac: delega a deploy-remote.sh
# Sulla VM Oracle: docker compose up -d

if [ ! -f /etc/oracle-release ] && [ ! -d /etc/oracle-cloud-agent ]; then
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec "$ROOT/deploy-remote.sh" "$@"
fi

set -e

echo "🚀 Script di Deploy Leleg IPTV su Oracle Cloud"
echo "==============================================="

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ ! -f /etc/oracle-release ] && [ ! -d /etc/oracle-cloud-agent ]; then
    echo -e "${YELLOW}⚠️  Attenzione: Non sembra essere una VM Oracle Cloud${NC}"
    if [ -z "$NON_INTERACTIVE" ]; then
        read -p "Vuoi continuare comunque? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
fi

if [ "$EUID" -eq 0 ]; then
    SUDO_CMD=""
    DOCKER_GROUP_CMD="usermod -aG docker"
else
    SUDO_CMD="sudo"
    DOCKER_GROUP_CMD="sudo usermod -aG docker"
fi

if ! command -v docker &> /dev/null; then
    echo -e "${RED}❌ Docker non è installato${NC}"
    echo "Installazione Docker..."
    $SUDO_CMD yum update -y
    $SUDO_CMD yum install -y yum-utils
    $SUDO_CMD yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    $SUDO_CMD yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    $SUDO_CMD systemctl start docker
    $SUDO_CMD systemctl enable docker

    if $SUDO_CMD docker --version > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Docker installato e avviato correttamente${NC}"
    else
        echo -e "${RED}❌ Errore durante l'installazione di Docker${NC}"
        exit 1
    fi

    if [ "$EUID" -ne 0 ]; then
        $DOCKER_GROUP_CMD $USER
        echo -e "${YELLOW}⚠️  Devi riconnetterti per applicare i cambiamenti del gruppo${NC}"
        exit 0
    fi
elif ! $SUDO_CMD systemctl is-active --quiet docker 2>/dev/null; then
    echo -e "${YELLOW}⚠️  Docker installato ma non in esecuzione, avvio...${NC}"
    $SUDO_CMD systemctl start docker
    $SUDO_CMD systemctl enable docker
fi

if ! command -v docker-compose &> /dev/null && ! docker compose version > /dev/null 2>&1; then
    echo "Installazione Docker Compose..."
    $SUDO_CMD curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    $SUDO_CMD chmod +x /usr/local/bin/docker-compose
fi

if docker compose version > /dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
else
    DOCKER_COMPOSE_CMD="docker-compose"
fi

if [ ! -f "docker-compose.yml" ]; then
    echo -e "${RED}❌ File docker-compose.yml non trovato${NC}"
    exit 1
fi

if [ ! -f "dist/index.html" ]; then
    echo -e "${RED}❌ dist/index.html non trovato${NC}"
    echo "Esegui prima la build locale: pnpm build:pages"
    exit 1
fi

PUBLIC_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "localhost")
echo -e "${GREEN}📍 IP Pubblico rilevato: $PUBLIC_IP${NC}"
echo ""
echo "Il deploy procederà con:"
echo "  - IP Pubblico: $PUBLIC_IP"
echo "  - Porta: 80"
echo ""

if [ -z "$NON_INTERACTIVE" ]; then
    read -p "Vuoi procedere? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo "Modalità non interattiva: procedo automaticamente..."
fi

echo ""
echo -e "${YELLOW}🚀 Avvio container...${NC}"
$DOCKER_COMPOSE_CMD up -d

# firewalld Oracle Linux: apri HTTP (Security List Oracle non basta)
if command -v firewall-cmd &>/dev/null && $SUDO_CMD systemctl is-active --quiet firewalld 2>/dev/null; then
    $SUDO_CMD firewall-cmd --permanent --add-service=http 2>/dev/null || true
    $SUDO_CMD firewall-cmd --reload 2>/dev/null || true
fi

echo ""
echo -e "${YELLOW}⏳ Attendo che i container siano pronti...${NC}"
sleep 5

if $DOCKER_COMPOSE_CMD ps | grep -q "Up"; then
    echo -e "${GREEN}✅ Container avviati con successo!${NC}"
    echo ""
    $DOCKER_COMPOSE_CMD ps
    echo ""
    echo "📋 Log recenti:"
    $DOCKER_COMPOSE_CMD logs --tail=20
    echo ""
    echo -e "${GREEN}🎉 Deploy completato!${NC}"
    echo ""
    echo "App disponibile su: http://$PUBLIC_IP"
    echo ""
    echo "Comandi utili:"
    echo "  - Log: $DOCKER_COMPOSE_CMD logs -f"
    echo "  - Stop: $DOCKER_COMPOSE_CMD down"
    echo "  - Restart: $DOCKER_COMPOSE_CMD restart"
else
    echo -e "${RED}❌ Errore durante l'avvio dei container${NC}"
    $DOCKER_COMPOSE_CMD logs
    exit 1
fi
