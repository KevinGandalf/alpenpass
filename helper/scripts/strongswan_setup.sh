#!/bin/sh
set -e

ENVFILE="/opt/alpenpass/setup.env"

echo "==> StrongSwan IKEv2 Client Setup starten"

# 1. Daten abfragen
read -rp "Verbindungsname (z.B. myvpn): " connection_name
if [ -z "$connection_name" ]; then
    echo "==> Fehler: Verbindungsname darf nicht leer sein."
    exit 1
fi

read -rp "VPN Server (z.B. 92-1-de.cg-dialup.net): " IPSECVPN_SERVER
read -rp "Username: " IPSECVPN_USER
read -rsp "Password: " IPSECVPN_PASS
echo ""
read -rp "Pre-shared Key (PSK): " IPSECVPN_PSK

if [ -z "$IPSECVPN_SERVER" ] || [ -z "$IPSECVPN_USER" ] || [ -z "$IPSECVPN_PASS" ] || [ -z "$IPSECVPN_PSK" ]; then
    echo "==> Fehler: Alle Felder müssen ausgefüllt sein!"
    exit 1
fi

# 2. Interface aus ENV lesen oder nachfragen
second_if=""
if [ -f "$ENVFILE" ]; then
    . "$ENVFILE"
fi

if [ -z "$second_if" ]; then
    read -rp "Netzwerkinterface für ausgehenden Traffic (z.B. eth0): " second_if
    if [ -z "$second_if" ]; then
        echo "==> Fehler: Netzwerkinterface darf nicht leer sein."
        exit 1
    fi
fi

# 3. Speichere alle Eingaben in /opt/alpenpass/setup.env (inkl. $second_if)
mkdir -p /opt/alpenpass
cat << EOF > "$ENVFILE"
# Automatisch erzeugte VPN- und Netzwerkeinstellungen
CONNECTION_NAME=$connection_name
IPSECVPN_SERVER=$IPSECVPN_SERVER
IPSECVPN_USER=$IPSECVPN_USER
IPSECVPN_PASS=$IPSECVPN_PASS
IPSECVPN_PSK=$IPSECVPN_PSK
second_if=$second_if
EOF
chmod 600 "$ENVFILE"
echo "==> Zugangsdaten und Interface in $ENVFILE gespeichert (chmod 600)"

# 4. Installiere strongswan und iptables-Module falls nicht vorhanden
if ! command -v ipsec >/dev/null 2>&1; then
    echo "==> strongSwan nicht gefunden, installiere..."
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache strongswan
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y strongswan
    elif command -v yum >/dev/null 2>&1; then
        yum install -y strongswan
    else
        echo "==> Paketmanager nicht erkannt. Bitte installiere strongswan manuell."
        exit 1
    fi
fi

if command -v apk >/dev/null 2>&1; then
    echo "==> Prüfe und installiere nötige iptables-Module..."
    apk add --no-cache iptables iptables-mod-tcpudp iptables-mod-nat
fi

# 5. Kernelmodule laden (optional)
for mod in iptable_filter iptable_nat ipt_REJECT ipt_MASQUERADE xfrm_user af_key; do
    if ! lsmod | grep -q "$mod"; then
        modprobe "$mod" 2>/dev/null || true
    fi
done

# 6. Backup vorhandener configs
[ -f /etc/ipsec.conf ] && mv /etc/ipsec.conf /etc/ipsec.conf.bak.$(date +%s)
[ -f /etc/ipsec.secrets ] && mv /etc/ipsec.secrets /etc/ipsec.secrets.bak.$(date +%s)

# 7. Schreibe ipsec.conf mit variabler Verbindungskennung
cat << EOF > /etc/ipsec.conf
config setup
    uniqueids=never
    charondebug="cfg 2, net 2, esp 2"

conn $connection_name
    keyexchange=ikev2
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256!
    dpdaction=clear
    dpddelay=300s
    dpdtimeout=1h
    rekey=no
    left=%defaultroute
    leftauth=psk
    leftid=%client
    right=$IPSECVPN_SERVER
    rightauth=psk
    rightid=$IPSECVPN_SERVER
    rightsubnet=0.0.0.0/0
    auto=add
EOF

# 8. Schreibe ipsec.secrets
cat << EOF > /etc/ipsec.secrets
: PSK "$IPSECVPN_PSK"
$IPSECVPN_USER : EAP "$IPSECVPN_PASS"
EOF

# 9. Schreibe einfache strongswan.conf für EAP, falls noch nicht vorhanden
if ! grep -q "eap-mschapv2" /etc/strongswan.conf 2>/dev/null; then
cat << EOF > /etc/strongswan.conf
charon {
    load_modular = yes
    plugins {
        include strongswan.d/charon/*.conf
        eap {
            eap-mschapv2 {
            }
        }
    }
}
EOF
fi

# 10. Dienste neu starten
echo "==> Starte strongSwan neu..."
ipsec restart

# 11. Verbindung starten
echo "==> Versuche VPN-Verbindung '$connection_name' aufzubauen..."
ipsec up "$connection_name"

# 12. iptables Regeln hinzufügen (nur, wenn noch nicht gesetzt)
if ! iptables -t nat -C POSTROUTING -o "$second_if" -m policy --dir out --pol ipsec -j ACCEPT >/dev/null 2>&1; then
    iptables -t nat -A POSTROUTING -o "$second_if" -m policy --dir out --pol ipsec -j ACCEPT
fi

if ! iptables -t nat -C POSTROUTING -o "$second_if" -j MASQUERADE >/dev/null 2>&1; then
    iptables -t nat -A POSTROUTING -o "$second_if" -j MASQUERADE
fi

if ! iptables -C FORWARD -i "$second_if" -o "$second_if" -m state --state RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1; then
    iptables -A FORWARD -i "$second_if" -o "$second_if" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

if ! iptables -C FORWARD -i "$second_if" -o "$second_if" -j ACCEPT >/dev/null 2>&1; then
    iptables -A FORWARD -i "$second_if" -o "$second_if" -j ACCEPT
fi

echo "==> iptables Regeln wurden gesetzt."

# 13. Einfaches Routing: Default Route über VPN-Tunnel (IPSec) hinzufügen
# Hinweis: IPSec baut keine eigenes tun/tap Device, deswegen hier nur Beispiel, wenn
# eine Route z.B. über VPN-Server-IP als Gateway gesetzt werden soll.

echo "==> Routing aktualisieren: Default-Route über VPN-Server $IPSECVPN_SERVER (via $second_if)"
ip route replace default via "$IPSECVPN_SERVER" dev "$second_if"

echo "==> Fertig. Prüfe den Status mit 'ipsec statusall' und teste das Routing."
