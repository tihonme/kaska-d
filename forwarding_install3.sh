#!/usr/bin/env bash
set -euo pipefail

#################################
# TRAP
#################################
trap 'echo -e "\033[1;31m[ERROR]\033[0m Ошибка в строке $LINENO"; exit 1' ERR

#################################
# HELPERS
#################################
log() { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

[[ $EUID -eq 0 ]] || die "Запускать нужно от root"

# Check OS and set release variable
. /etc/os-release
if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    die "Этот скрипт поддерживает только Ubuntu или Debian: $ID"
fi

#################################
# Определяем ORIGIN_IP
#################################
ORIGIN_IP=${ORIGIN_IP:-false}
if [[ "$ORIGIN_IP" == "false" ]]; then
    die "Переменная ORIGIN_IP не задана. Установите её перед запуском: export ORIGIN_IP=x.x.x.x"
fi

#################################
# UFW NAT
#################################
LOCAL_IP=$(hostname -I | awk '{print $1}')

if ! command -v ufw >/dev/null 2>&1; then
    log "UFW не установлен. Устанавливаю..."
    apt update -qq && apt install -y ufw
fi

if LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
    log "UFW уже активен."
else
    warn "UFW выключен или не настроен. Включаю..."
    
    ufw allow OpenSSH >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1
    
    if LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
        log "UFW успешно включён."
    else
        die "Не удалось включить UFW. Проверьте вручную!"
    fi
fi

log "Оптимизация сетевого стека ядра..."
cat <<EOF > /etc/sysctl.d/99-relay-optimization.conf
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.netfilter.nf_conntrack_max = 2000000
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.ipv4.conf.all.accept_local = 1
net.ipv4.conf.all.route_localnet = 1
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
EOF
sysctl --system >/dev/null 2>&1

log "Настройка правил перенаправления (before.rules)..."
cp /etc/ufw/before.rules /etc/ufw/before.rules.bak

cat <<EOF > /tmp/ufw_nat_rules
*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

# Переадресация DNS (TCP и UDP отдельно)
-A PREROUTING -p tcp --dport 53 -j DNAT --to-destination $ORIGIN_IP
-A PREROUTING -p udp --dport 53 -j DNAT --to-destination $ORIGIN_IP

# Переадресация диапазона 30000:60000
-A PREROUTING -p tcp --dport 30000:60000 -j DNAT --to-destination $ORIGIN_IP
-A PREROUTING -p udp --dport 30000:60000 -j DNAT --to-destination $ORIGIN_IP

# Маскировка (SNAT) для обратного трафика
-A POSTROUTING -p tcp -d $ORIGIN_IP --dport 53 -j SNAT --to-source $LOCAL_IP
-A POSTROUTING -p udp -d $ORIGIN_IP --dport 53 -j SNAT --to-source $LOCAL_IP
-A POSTROUTING -p tcp -d $ORIGIN_IP --dport 30000:60000 -j SNAT --to-source $LOCAL_IP
-A POSTROUTING -p udp -d $ORIGIN_IP --dport 30000:60000 -j SNAT --to-source $LOCAL_IP
COMMIT

*filter
:FORWARD ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]

# Разрешаем пересылку для уже установленных соединений
-A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

# Явно разрешаем прохождение трафика ТОЛЬКО для DNS и диапазона 30000:60000
-A FORWARD -d $ORIGIN_IP -p tcp --dport 53 -j ACCEPT
-A FORWARD -d $ORIGIN_IP -p udp --dport 53 -j ACCEPT
-A FORWARD -d $ORIGIN_IP -p tcp --dport 30000:60000 -j ACCEPT
-A FORWARD -d $ORIGIN_IP -p udp --dport 30000:60000 -j ACCEPT
-A FORWARD -s $ORIGIN_IP -j ACCEPT

COMMIT

*mangle
:FORWARD ACCEPT [0:0]
-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
COMMIT
EOF

sed -i '/\*nat/,/COMMIT/d' /etc/ufw/before.rules
sed -i '/\*mangle/,/COMMIT/d' /etc/ufw/before.rules

cat /tmp/ufw_nat_rules /etc/ufw/before.rules > /etc/ufw/before.rules.new
mv /etc/ufw/before.rules.new /etc/ufw/before.rules

log "Открытие портов в фаерволе..."
ufw allow 53/tcp
ufw allow 53/udp
ufw allow 30000:60000/tcp
ufw allow 30000:60000/udp

sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

log "Перезапуск UFW..."
ufw reload

rm -f /tmp/ufw_nat_rules

log "Готово! Система оптимизирована."
log "Переадресация: DNS (53) + диапазон 30000:60000 → $ORIGIN_IP"
log "Локальные порты вне этого диапазона (например, 60001) НЕ переадресуются."
