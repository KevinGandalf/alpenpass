#!/bin/sh

set -e

echo "==> [Multihop Setup] VPN → SOCKS5 → Internet"

# setup.env laden (muss existieren)
SETUP_ENV="/opt/alpenpass/setup.env"
if [ ! -f "$SETUP_ENV" ]; then
  echo "==> Fehler: $SETUP_ENV nicht gefunden. Bitte vorher erstellen."
  exit 1
fi
. "$SETUP_ENV"

if [ -z "$ip_addr" ] || [ -z "$second_if" ] || [ -z "$vpn_if" ]; then
  echo "==> Fehler: setup.env muss ip_addr, second_if und vpn_if definieren."
  exit 1
fi

echo "-> Netzwerk-Parameter aus setup.env geladen:"
echo "   IP-Adresse: $ip_addr"
echo "   Netzwerkinterface: $second_if"
echo "   VPN-Interface: $vpn_if"

echo "-> Installiere notwendige Pakete..."
apk add --no-cache redsocks iptables bind-tools

# 1. SOCKS5-Proxy-Daten abfragen
read -p "Mullvad SOCKS5 Host (z. B. nl1-wg.socks5.relays.mullvad.net): " SOCKS_HOST
read -p "Port (Standard: 1080): " SOCKS_PORT
SOCKS_PORT=${SOCKS_PORT:-1080}

read -p "Mullvad Account-Nummer (Login, kann leer bleiben): " SOCKS_USER

read -p "Lokaler redsocks Port (Standard: 12345): " LOCAL_REDSOCKS_PORT
LOCAL_REDSOCKS_PORT=${LOCAL_REDSOCKS_PORT:-12345}

# Funktion: Wert in setup.env setzen (neu oder überschreiben)
set_env_var() {
  VAR_NAME=$1
  VAR_VALUE=$2
  # Wenn Variable existiert, ersetze sie, sonst anhängen
  if grep -q "^${VAR_NAME}=" "$SETUP_ENV"; then
    sed -i "s/^${VAR_NAME}=.*/${VAR_NAME}=${VAR_VALUE}/" "$SETUP_ENV"
  else
    echo "${VAR_NAME}=${VAR_VALUE}" >> "$SETUP_ENV"
  fi
}

# Werte in setup.env schreiben
set_env_var "SOCKS_HOST" "$SOCKS_HOST"
set_env_var "SOCKS_PORT" "$SOCKS_PORT"
set_env_var "LOCAL_REDSOCKS_PORT" "$LOCAL_REDSOCKS_PORT"

echo "-> Werte in $SETUP_ENV gespeichert: SOCKS_HOST, SOCKS_PORT, LOCAL_REDSOCKS_PORT"

# 2. Erstelle redsocks-Konfigurationsdatei
echo "-> Erstelle /etc/redsocks.conf ..."
{
  echo "base {"
  echo "  log_debug = on;"
  echo "  log_info = on;"
  echo "  log = \"file:/var/log/redsocks.log\";"
  echo "  daemon = on;"
  echo "  redirector = iptables;"
  echo "}"
  echo ""
  echo "redsocks {"
  echo "  local_ip = 127.0.0.1;"
  echo "  local_port = $LOCAL_REDSOCKS_PORT;"
  echo "  ip = $SOCKS_HOST;"
  echo "  port = $SOCKS_PORT;"
  echo "  type = socks5;"
  if [ -n "$SOCKS_USER" ]; then
    echo "  login = $SOCKS_USER;"
  fi
  echo "}"
} > /etc/redsocks.conf

# 3. Init-Skript für redsocks (falls nicht vorhanden)
if [ ! -f /etc/init.d/redsocks ]; then
  echo "-> Erstelle /etc/init.d/redsocks ..."
  cat <<'EOF' > /etc/init.d/redsocks
#!/sbin/openrc-run
command="/usr/bin/redsocks"
command_args="-c /etc/redsocks.conf"
pidfile="/run/redsocks.pid"
name="redsocks"
EOF
  chmod +x /etc/init.d/redsocks
  rc-update add redsocks default
fi

# 4. Starte redsocks
echo "-> Starte redsocks..."
rc-service redsocks restart

# 5. iptables-Regeln setzen — prüfen und nur fehlende ergänzen
echo "-> Setze iptables-Regeln (Filter und NAT)..."

# Funktion, die eine iptables-Regel prüft und ggf. hinzufügt
add_iptables_rule() {
  table=$1
  chain=$2
  shift 2
  # Prüfen, ob Regel existiert
  if ! iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
    echo "   -> Regel hinzufügen: iptables -t $table -A $chain $*"
    iptables -t "$table" -A "$chain" "$@"
  else
    echo "   -> Regel bereits vorhanden: iptables -t $table -C $chain $*"
  fi
}

# Filter-Regeln (FORWARD)
add_iptables_rule filter FORWARD -s "${ip_addr}/32" -i "${second_if}" -o "${vpn_if}" -j ACCEPT
add_iptables_rule filter FORWARD -s "${ip_addr}/32" -p icmp --icmp-type 8 -j ACCEPT
add_iptables_rule filter FORWARD -d "${ip_addr}/32" -p icmp --icmp-type 0 -j ACCEPT
add_iptables_rule filter FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

# NAT-Regeln
add_iptables_rule nat POSTROUTING -o "${vpn_if}" -j MASQUERADE

# OUTPUT-Traffic Umleitung über redsocks, mit Ausnahmen für lokale Netze & DNS
add_iptables_rule nat OUTPUT -d 127.0.0.1/8 -j RETURN
add_iptables_rule nat OUTPUT -d 10.0.0.0/8 -j RETURN
add_iptables_rule nat OUTPUT -d 192.168.0.0/16 -j RETURN

add_iptables_rule nat OUTPUT -p udp --dport 53 -j RETURN
add_iptables_rule nat OUTPUT -p tcp --dport 53 -j RETURN

add_iptables_rule nat OUTPUT -p tcp -j REDIRECT --to-ports "$LOCAL_REDSOCKS_PORT"

# Regeln persistent speichern
echo "-> Speichere iptables-Regeln in /etc/iptables/rules.v4 ..."
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

echo ""
echo "==> Multihop-Modus aktiv. iptables-Regeln gesetzt."
iptables -t nat -L -n --line-numbers

echo ""
echo "==> Fertig. Alle TCP-Verbindungen laufen jetzt über VPN → SOCKS5 → Internet."
