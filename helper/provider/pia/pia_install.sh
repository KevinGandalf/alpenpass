#!/bin/sh
set -e

CRED_DIR="/opt/alpenpass/helper/provider/pia"
CRED_FILE="$CRED_DIR/.pia_credentials"
MANUAL_DIR="$CRED_DIR/manual-connections"

KEEPALIVE_SCRIPT="/opt/alpenpass/helper/provider/pia/pia_keepalive.sh"
OPENRC_SERVICE="/etc/init.d/pia_keepalive"

mkdir -p "$CRED_DIR"
touch "$CRED_FILE"
chmod 600 "$CRED_FILE"

echo "==> Bitte PIA-Zugangsdaten eingeben."

echo -n "PIA Benutzername: "
read PIA_USER

echo -n "PIA Passwort: "
if command -v stty >/dev/null 2>&1; then
  stty -echo
  read PIA_PASS
  stty echo
  echo
else
  read PIA_PASS
fi

# Schreibe PIA_USER und PIA_PASS nur, wenn noch nicht vorhanden
grep -q '^PIA_USER=' "$CRED_FILE" || echo "PIA_USER='$PIA_USER'" >> "$CRED_FILE"
grep -q '^PIA_PASS=' "$CRED_FILE" || echo "PIA_PASS='$PIA_PASS'" >> "$CRED_FILE"

echo "==> Generiere PIA-Token..."
cd "$MANUAL_DIR"
PIA_TOKEN_OUTPUT=$(PIA_USER="$PIA_USER" PIA_PASS="$PIA_PASS" ./get_token.sh)

PIA_TOKEN=$(echo "$PIA_TOKEN_OUTPUT" | grep -o 'PIA_TOKEN=[a-z0-9]*' | cut -d= -f2)

if [ -z "$PIA_TOKEN" ]; then
  echo "==> Fehler: Token konnte nicht generiert werden."
  exit 1
fi

# Aktualisiere oder füge PIA_TOKEN in der Credentials-Datei hinzu
if grep -q '^PIA_TOKEN=' "$CRED_FILE"; then
  sed -i "s/^PIA_TOKEN=.*/PIA_TOKEN='$PIA_TOKEN'/" "$CRED_FILE"
else
  echo "PIA_TOKEN='$PIA_TOKEN'" >> "$CRED_FILE"
fi

echo "==> PIA-Zugangsdaten und Token wurden sicher gespeichert in $CRED_FILE"

echo ""
echo "==> Hinweis: Das offizielle PIA Setup wird nun gestartet. Bitte folge den Anweisungen zur Einrichtung."
read -rp "Drücke ENTER, um fortzufahren..."

echo "==> Starte run_setup.sh mit den Zugangsdaten..."
PIA_TOKEN="$PIA_TOKEN" PIA_USER="$PIA_USER" PIA_PASS="$PIA_PASS" ./run_setup.sh

echo "==> run_setup.sh wurde ausgeführt."

# WireGuard-Konfiguration umbenennen
WG_CONF_DIR="/etc/wireguard"
if [ -f "$WG_CONF_DIR/pia.conf" ]; then
  mv -f "$WG_CONF_DIR/pia.conf" "$WG_CONF_DIR/wg0.conf"
  echo "==> WireGuard-Konfiguration pia.conf wurde nach wg0.conf umbenannt."
else
  echo "==> Keine pia.conf in $WG_CONF_DIR gefunden, kein Umbenennen nötig."
fi

# Erstelle Keepalive-Skript
cat > "$KEEPALIVE_SCRIPT" << 'EOF'
#!/bin/sh
TARGET_IP="8.8.8.8"
INTERVAL=20

while true; do
  # Ping über wg0 Interface
  ping -I wg0 -c 1 -W 1 "$TARGET_IP" >/dev/null 2>&1
  sleep "$INTERVAL"
done
EOF

chmod +x "$KEEPALIVE_SCRIPT"
echo "==> Keepalive-Skript wurde erstellt unter $KEEPALIVE_SCRIPT"

# Erstelle OpenRC-Service
cat > "$OPENRC_SERVICE" << 'EOF'
#!/sbin/openrc-run

name="pia_keepalive"
description="PIA WireGuard VPN Keepalive via ping over wg0"

command="/opt/alpenpass/helper/provider/pia/pia_keepalive.sh"
command_background=true
pidfile="/run/pia_keepalive.pid"

depend() {
  after net
  after wireguard
}

start_pre() {
  # Prüfe ob wg0 existiert
  if ! ip link show wg0 >/dev/null 2>&1; then
    eerror "wg0 Interface existiert nicht. Keepalive startet nicht."
    return 1
  fi
}

stop_post() {
  rm -f /run/pia_keepalive.pid
}
EOF

chmod +x "$OPENRC_SERVICE"
echo "==> OpenRC-Service wurde erstellt unter $OPENRC_SERVICE"

echo ""
echo "==> Um den Keepalive-Service zu starten und beim Boot zu aktivieren, führe bitte aus:"
echo "    rc-update add pia_keepalive default"
echo "    rc-service pia_keepalive start"
