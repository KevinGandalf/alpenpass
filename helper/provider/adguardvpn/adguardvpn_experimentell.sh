#!/bin/sh
set -e

CRED_DIR="/opt/alpenpass/helper/provider/adguardvpn"
CRED_FILE="$CRED_DIR/.adguard_credentials"

apk add --no-cache curl iptables

mkdir -p "$CRED_DIR"
cd "$CRED_DIR"

echo "==> AdGuardVPNCLI installieren..."
curl -fsSL https://raw.githubusercontent.com/AdguardTeam/AdGuardVPNCLI/master/scripts/nightly/install.sh | sh -s -- -v

# Zugangsdaten abfragen, falls noch nicht gespeichert
if [ ! -f "$CRED_FILE" ]; then
  echo -n "AdGuardVPN Benutzername: "
  read ADGUARD_USER

  echo -n "AdGuardVPN Passwort: "
  if command -v stty >/dev/null 2>&1; then
    stty -echo
    read ADGUARD_PASS
    stty echo
    echo
  else
    read ADGUARD_PASS
  fi

  echo "ADGUARD_USER='$ADGUARD_USER'" > "$CRED_FILE"
  echo "ADGUARD_PASS='$ADGUARD_PASS'" >> "$CRED_FILE"
  chmod 600 "$CRED_FILE"
fi

. "$CRED_FILE"

echo "==> Login zu AdGuardVPN..."

if adguardvpn-cli login -u "$ADGUARD_USER" -p "$ADGUARD_PASS"; then
  echo "Login erfolgreich."
else
  echo "Login fehlgeschlagen."
  exit 1
fi

echo ""
echo "==> Du wirst jetzt durch die CLI geführt, um verfügbare Standorte anzuzeigen."
read -rp "Drücke ENTER, um fortzufahren..."

/usr/local/bin/adguardvpn-cli list-locations

echo ""
echo "==> VPN Verbindung aufbauen..."

if adguardvpn-cli connect; then
  echo "VPN erfolgreich verbunden."
else
  echo "Verbindung konnte nicht hergestellt werden."
  exit 1
fi

# Eingabe der nötigen Variablen für iptables
echo -n "Bitte IP-Adresse der Verbindung eingeben (z.B. 10.8.0.2): "
read ip_addr

echo -n "Bitte Name des zweiten Interfaces eingeben (z.B. eth0): "
read second_if

echo "==> Setze iptables Regeln..."

cat << EOF > /etc/iptables/rules.v4
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A FORWARD -s ${ip_addr}/32 -i ${second_if} -o tun0 -j ACCEPT
-A FORWARD -s ${ip_addr}/32 -p icmp -m icmp --icmp-type 8 -j ACCEPT
-A FORWARD -d ${ip_addr}/32 -p icmp -m icmp --icmp-type 0 -j ACCEPT
-A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o tun0 -j MASQUERADE
COMMIT
EOF

echo "==> iptables Regeln wurden gesetzt und in /etc/iptables/rules.v4 gespeichert."

echo "Du kannst die Regeln mit 'iptables-restore < /etc/iptables/rules.v4' laden oder den iptables-Reload-Dienst verwenden."
