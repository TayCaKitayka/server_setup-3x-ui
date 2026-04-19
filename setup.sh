#!/bin/bash

# ============================================================
#  Скрипт настройки сервера (базовый)
#  Автор: Vyacheslav
#  ОС: Ubuntu 22.04
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[ИНФО]${NC} $1"; }
log_success() { echo -e "${GREEN}[ОК]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"; }
log_error()   { echo -e "${RED}[ОШИБКА]${NC} $1"; exit 1; }

# ============================================================
# КОНФИГУРАЦИЯ — заполните перед запуском
# ============================================================

SSH_PORT=22663
SSH_PUB_KEY="ВАШ_ПУБЛИЧНЫЙ_SSH_КЛЮЧ"

OPEN_PORTS=(80 443 8443)

# ============================================================

if [[ $EUID -ne 0 ]]; then
    log_error "Скрипт должен запускаться от root!"
fi

# ============================================================
# 0. ОТКЛЮЧЕНИЕ NEEDRESTART
# ============================================================

log_info "Отключение интерактивных запросов needrestart..."

export NEEDRESTART_MODE=a
export DEBIAN_FRONTEND=noninteractive

mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/99-auto.conf << 'EOF'
$nrconf{restart} = 'a';
$nrconf{kernelhints} = 0;
EOF

log_success "Интерактивные запросы needrestart отключены"

# ============================================================
# 1. ОБНОВЛЕНИЕ СИСТЕМЫ И УСТАНОВКА ПАКЕТОВ
# ============================================================

log_info "Обновление системы..."
DEBIAN_FRONTEND=noninteractive apt update -y
DEBIAN_FRONTEND=noninteractive apt upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
log_success "Система обновлена"

log_info "Установка пакетов: ufw, nano..."
DEBIAN_FRONTEND=noninteractive apt install -y ufw nano
log_success "Пакеты установлены"

# ============================================================
# 2. SSH КЛЮЧ
# ============================================================

log_info "Настройка SSH ключа для root..."

SSH_DIR="/root/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if ! grep -qF "$SSH_PUB_KEY" "$AUTH_KEYS" 2>/dev/null; then
    echo "$SSH_PUB_KEY" >> "$AUTH_KEYS"
    log_success "SSH ключ добавлен"
else
    log_warning "SSH ключ уже существует, пропускаем"
fi

chmod 600 "$AUTH_KEYS"
log_success "Права на authorized_keys установлены (600)"

# ============================================================
# 3. НАСТРОЙКА SSH
# ============================================================

log_info "Настройка конфига SSH..."

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Бэкап sshd_config создан"

set_ssh_param() {
    local param="$1"
    local value="$2"
    if grep -qE "^#?[[:space:]]*${param}" "$SSHD_CONFIG"; then
        sed -i "s|^#\?[[:space:]]*${param}.*|${param} ${value}|" "$SSHD_CONFIG"
    else
        echo "${param} ${value}" >> "$SSHD_CONFIG"
    fi
}

set_ssh_param "Port"                            "$SSH_PORT"
set_ssh_param "PubkeyAuthentication"            "yes"
set_ssh_param "PasswordAuthentication"          "no"
set_ssh_param "PermitEmptyPasswords"            "no"
set_ssh_param "ChallengeResponseAuthentication" "no"
set_ssh_param "KbdInteractiveAuthentication"    "no"
set_ssh_param "UsePAM"                          "no"
set_ssh_param "PermitRootLogin"                 "prohibit-password"
set_ssh_param "AuthorizedKeysFile"              ".ssh/authorized_keys"
set_ssh_param "X11Forwarding"                   "no"
set_ssh_param "PrintMotd"                       "no"

log_success "Конфиг SSH настроен"

log_info "Проверка конфига SSH..."
if sshd -t; then
    log_success "Конфиг SSH валиден"
else
    log_error "Ошибка в конфиге SSH! Восстановите бэкап из $SSHD_CONFIG.bak.*"
fi

# ============================================================
# 4. ОТКЛЮЧЕНИЕ IPv6
# ============================================================

log_info "Отключение IPv6..."

cat > /etc/sysctl.d/99-disable-ipv6.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv4.icmp_echo_ignore_all = 1
EOF

sysctl -w net.ipv6.conf.all.disable_ipv6=1     > /dev/null 2>&1
sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.lo.disable_ipv6=1      > /dev/null 2>&1

log_success "IPv6 отключён через sysctl (навсегда)"

sed -i 's/IPV6=yes/IPV6=no/' /etc/default/ufw
log_success "IPv6 отключён в UFW"

# ============================================================
# 5. НАСТРОЙКА UFW
# ============================================================

log_info "Настройка UFW..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw deny 22/tcp
log_success "Порт 22 (SSH старый) — закрыт"

ufw allow "${SSH_PORT}/tcp" comment 'SSH'
log_success "Порт ${SSH_PORT} (SSH) — открыт"

for port in "${OPEN_PORTS[@]}"; do
    ufw allow "${port}/tcp" comment "Порт ${port}"
    log_success "Порт ${port} — открыт"
done

ufw --force enable
log_success "UFW включён"

# ============================================================
# 6. БЛОКИРОВКА PING (iptables — навсегда)
# ============================================================

log_info "Блокировка ICMP (ping) через iptables..."

echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | \
    debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | \
    debconf-set-selections

DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent

iptables -I INPUT -p icmp --icmp-type echo-request -j DROP

netfilter-persistent save
log_success "Ping заблокирован навсегда (iptables + netfilter-persistent)"

sysctl --system > /dev/null 2>&1
log_success "Ping заблокирован через sysctl (двойная защита)"

# ============================================================
# 7. ПЕРЕЗАПУСК SSH
# ============================================================

log_info "Перезапуск SSH..."
systemctl restart sshd
log_success "SSH перезапущен на порту ${SSH_PORT}"

# ============================================================
# ИТОГ
# ============================================================

SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}          НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${YELLOW}  SSH подключение:${NC}"
echo -e "  ssh -p ${SSH_PORT} root@${SERVER_IP}"
echo ""
echo -e "${YELLOW}  Включено:${NC}"
echo -e "  ${GREEN}✓${NC} Вход только по SSH ключу"
echo ""
echo -e "${YELLOW}  Отключено:${NC}"
echo -e "  ${RED}✗${NC} IPv6"
echo -e "  ${RED}✗${NC} Ping"
echo -e "  ${RED}✗${NC} SSH порт 22"
echo ""
echo -e "${YELLOW}  Открытые порты:${NC}"
echo -e "  ${GREEN}✓${NC} ${SSH_PORT} — SSH"
for port in "${OPEN_PORTS[@]}"; do
    echo -e "  ${GREEN}✓${NC} ${port}"
done
echo ""
echo -e "  Статус UFW:"
ufw status numbered
echo ""
echo -e "${RED}  НЕ ЗАКРЫВАЙТЕ текущую сессию, пока не убедитесь${NC}"
echo -e "${RED}  что можете зайти на порту ${SSH_PORT}!${NC}"
echo -e "${GREEN}============================================================${NC}"
