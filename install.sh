#!/bin/bash
set -e

echo "==> Starte Setup..."

# 1. Hostname setzen
echo "==> Bitte neuen Hostname eingeben:"
read -rp "Hostname: " new_hostname
if [ -n "$new_hostname" ]; then
    echo "$new_hostname" > /etc/hostname
    hostname "$new_hostname"
    echo "==> Hostname wurde auf '$new_hostname' gesetzt."
else
    echo "==> Kein Hostname eingegeben, keine Änderung."
fi

# 2. eth0 automatisch erkennen und in Variable $iface setzen
iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^eth0$' | head -n 1)
if [ -z "$iface" ]; then
    echo "==> Fehler: eth0 nicht gefunden. Abbruch."
    exit 1
fi
echo "==> Netzwerkschnittstelle eth0 erkannt: $iface"

# IP-Adresse, Netzmaske und Standard-Gateway ausgeben
ip_cidr=$(ip -4 addr show "$iface" | awk '/inet / {print $2}' | head -n 1)
if [ -z "$ip_cidr" ]; then
    echo "==> Fehler: Keine IPv4-Adresse für $iface gefunden."
    exit 1
fi
ip_addr=$(echo "$ip_cidr" | cut -d'/' -f1)
prefix=$(echo "$ip_cidr" | cut -d'/' -f2)
if [ -z "$prefix" ]; then
    echo "==> Fehler: Kein Netzwerkpräfix für $iface gefunden."
    exit 1
fi
netmask=$(ipcalc -m "$ip_addr/$prefix" | grep NETMASK | cut -d'=' -f2)
if [ -z "$netmask" ]; then
    echo "==> Fehler: Konnte Netzmaske für $iface nicht ermitteln."
    exit 1
fi
gateway=$(ip route show default | awk '/default via/ {print $3}' | head -n 1)
if [ -z "$gateway" ]; then
    echo "==> Fehler: Konnte Standard-Gateway für $iface nicht ermitteln."
    exit 1
fi
echo "==> Netzwerkdetails für $iface:"
echo "    IP-Adresse: $ip_addr"
echo "    Netzmaske: $netmask"
echo "    Standard-Gateway: $gateway"

# 3. Zweites Netzwerkinterface automatisch finden (nicht lo oder eth0)
interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E 'lo|^eth0$')
second_if=$(echo "$interfaces" | head -n 1)
if [ -z "$second_if" ]; then
    echo "==> Kein zweites Netzwerkinterface gefunden. Abbruch."
    exit 1
fi
echo "==> Zweites Netzwerkinterface erkannt: $second_if"

# 4. IP und Netzmaske vom Nutzer abfragen
read -rp "Bitte statische IP für $second_if eingeben (z.B. 192.168.1.10): " second_ip_addr
read -rp "Bitte Netzmaske für $second_if eingeben (z.B. 255.255.255.0): " second_netmask
if [ -z "$second_ip_addr" ] || [ -z "$second_netmask" ]; then
    echo "==> Ungültige IP oder Netzmaske. Abbruch."
    exit 1
fi

# 5. IP auf zweites Interface setzen
ip addr flush dev "$second_if"
ip addr add "$second_ip_addr"/"$second_netmask" dev "$second_if"
ip link set dev "$second_if" up
echo "==> IP-Adresse $second_ip_addr/$second_netmask auf $second_if gesetzt."

# 6. /etc/network/interfaces ergänzen (nicht überschreiben)
if ! grep -q "$second_if" /etc/network/interfaces; then
    echo "" >> /etc/network/interfaces
    echo "# Konfiguration für $second_if hinzugefügt durch Setup-Skript" >> /etc/network/interfaces
    echo "auto $second_if" >> /etc/network/interfaces
    echo "iface $second_if inet static" >> /etc/network/interfaces
    echo "    address $second_ip_addr" >> /etc/network/interfaces
    echo "    netmask $second_netmask" >> /etc/network/interfaces
    echo "==> Eintrag für $second_if in /etc/network/interfaces hinzugefügt."
else
    echo "==> $second_if ist bereits in /etc/network/interfaces vorhanden. Kein Eintrag vorgenommen."
fi

# 7. Speichere die Netzwerkeinstellungen in setup.env
cat > /opt/alpenpass/setup.env << EOF
# Automatisch erzeugte Netzwerkeinstellungen
IFACE=$iface
IP_ADDR=$ip_addr
NETMASK=$netmask
GATEWAY=$gateway
SECOND_IF=$second_if
SECOND_IP_ADDR=$second_ip_addr
SECOND_NETMASK=$second_netmask
EOF
echo "==> Netzwerkeinstellungen in setup.env gespeichert."

# 8. System aktualisieren und Pakete installieren
echo "==> System aktualisieren und Pakete installieren..."
apk update && apk upgrade
apk add --no-cache openvpn wireguard-tools iptables iptables-openrc bash iproute2 curl wget git htop net-tools nano linux-lts jq bc coreutils gawk ipcalc
echo "==> Paketinstallation abgeschlossen."

# 9. Speicherplatz und aktive Ports anzeigen
echo ""
echo "==> Speicherplatzübersicht:"
df -h

echo ""
echo "==> Aktive Ports:"
netstat -tulpen || ss -tulpen

# 10. sysctl-Konfiguration für IP-Forwarding und IPv6 deaktivieren
echo ""
echo "==> Erstelle /etc/sysctl.d/99-forwarding.conf mit IP-Forwarding und IPv6 Deaktivierung..."
cat << 'EOF' > /etc/sysctl.d/99-forwarding.conf
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
echo "==> sysctl-Konfiguration gespeichert."
echo ""
echo "==> Lade sysctl-Konfiguration jetzt sofort..."
sysctl -p /etc/sysctl.d/99-forwarding.conf
echo "==> Füge sysctl zu Systemstart hinzu..."
rc-update add sysctl default

# Variablen für VPN-Interface merken
last_vpn_if=""

# 11. VPN-Typ auswählen und Konfiguration einlesen
echo ""
echo "==> VPN-Typ auswählen:"
echo "1 = OpenVPN"
echo "2 = WireGuard"
echo ""
echo "==> Anbieter auswählen:"
echo "3 = PIA"
echo "4 = AdGuardVPN (Experimentell!)"
echo "5 = NordVPN Wireguard"
echo ""
echo "==> Weiteres:"
echo "6 = Multihop --> VPN --> Socks5 --> Internet"
echo "7 = IPsec Client (StrongSwan, zum Beispiel Cyberghost)"
read -rp "Auswahl [1-7]: " vpn_type

vpn_if=""
run_socks5_multihop=0

case "$vpn_type" in
    1)
        echo ""
        echo "==> OpenVPN-Konfiguration eingeben (per Paste). Mit ENTER und STRG+D abschließen."
        mkdir -p /etc/openvpn
        cat > /etc/openvpn/client.conf
        echo "==> Erstelle OpenVPN Autostart-Skript /etc/local.d/openvpn.start ..."
        mkdir -p /etc/local.d
        cat << 'EOF' > /etc/local.d/openvpn.start
#!/bin/sh
rc-service openvpn start
EOF
        chmod +x /etc/local.d/openvpn.start
        rc-update add openvpn default
        rc-update add local default
        rc-service openvpn start
        echo "==> OpenVPN-Konfiguration gespeichert und Dienst gestartet."
        vpn_if="tun0"
        last_vpn_if="$vpn_if"
        ;;
    2)
        echo ""
        echo "==> WireGuard-Konfiguration eingeben (per Paste). Mit ENTER und STRG+D abschließen."
        mkdir -p /etc/wireguard
        cat > /etc/wireguard/wg0.conf
        echo "==> Erstelle WireGuard Autostart-Skript /etc/local.d/wg0.start ..."
        mkdir -p /etc/local.d
        cat << 'EOF' > /etc/local.d/wg0.start
#!/bin/sh
wg-quick up wg0
EOF
        chmod +x /etc/local.d/wg0.start
        rc-update add local default
        echo "==> WireGuard-Konfiguration gespeichert und gestartet."
        vpn_if="wg0"
        last_vpn_if="$vpn_if"
        ;;
    3)
        echo "==> Starte PIA Installations-Skript..."
        /opt/alpenpass/helper/provider/pia/pia_install.sh
        vpn_if="pia"
        last_vpn_if="$vpn_if"
        ;;
    4)
        echo "==> Starte AdGuardVPN Installations-Skript..."
        /opt/alpenpass/helper/provider/adguardvpn/adguardvpn_experimentell.sh
        vpn_if="tun0"
        last_vpn_if="$vpn_if"
        ;;
    5)
        echo "==> Starte NordVPN Wireguard Script..."
        /opt/alpenpass/helper/provider/nordvpn/get_nordvpnserver.sh
        vpn_if="wg0"
        last_vpn_if="$vpn_if"
        ;;
    6)
        echo "==> Multihop Setup ausgewählt."
        if [ -n "$last_vpn_if" ]; then
            vpn_if="$last_vpn_if"
        else
            echo "==> Fehler: Multihop wurde gewählt, aber kein VPN-Interface gefunden."
            exit 1
        fi
        run_socks5_multihop=1
        ;;
    7)
        echo "==> Starte IPsec Client Setup (StrongSwan)..."
        /opt/alpenpass/helper/scripts/strongswan_setup.sh
        vpn_if="ipsec0"
        last_vpn_if="$vpn_if"
        ;;
    *)
        echo "==> Ungültige Auswahl. Abbruch."
        exit 1
        ;;
esac

# VPN-Interface und Multihop-Flag in setup.env speichern
cat >> /opt/alpenpass/setup.env << EOF
VPN_IF=$vpn_if
RUN_SOCKS5_MULTIHOP=$run_socks5_multihop
EOF
echo "==> VPN-Interface ($vpn_if) und Multihop-Flag ($run_socks5_multihop) in setup.env gespeichert."

# 12. sysctl nochmal laden
echo ""
echo "==> Lade sysctl-Konfiguration erneut..."
sysctl -p /etc/sysctl.d/99-forwarding.conf

# 13. SSH-Hostkeys neu generieren
echo ""
echo "==> Möchtest du SSH-Hostkeys neu generieren? (z.B. bei geklonter VM empfohlen) [j/N]:"
read -r regenerate_ssh_keys
if echo "$regenerate_ssh_keys" | grep -iq '^j'; then
    echo "==> SSH-Hostkeys werden neu generiert..."
    rm -f /etc/ssh/ssh_host_*
    ssh-keygen -A
    rc-service sshd restart
    echo "==> SSH-Dienst wurde neu gestartet."
else
    echo "==> SSH-Hostkeys bleiben unverändert."
fi

# 14. Dynamisch das Interface mit IPv4 bestimmen
ip_cidr=$(ip -4 addr show "$iface" | awk '/inet / {print $2; exit}')
if [ -z "$ip_cidr" ]; then
    echo "Fehler: Keine IPv4-Adresse für $iface gefunden."
    exit 1
fi

# Netzwerkadresse ermitteln
network=$(ip route show dev "$iface" | awk '/proto kernel/ {print $1; exit}')
if [ -z "$network" ]; then
    echo "Fehler: konnte Subnetz von $iface nicht ermitteln."
    exit 1
fi

if [ "$vpn_type" != "6" ]; then
    echo ""
    echo "==> IPtables Setup..."
    rc-update add iptables default
    cat << EOF > /etc/iptables/rules.v4
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A FORWARD -s ${network} -i ${second_if} -o ${vpn_if} -j ACCEPT
-A FORWARD -s ${network} -p icmp -m icmp --icmp-type 8 -j ACCEPT
-A FORWARD -d ${network} -p icmp -m icmp --icmp-type 0 -j ACCEPT
-A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o ${vpn_if} -j MASQUERADE
COMMIT
EOF
fi

# 15. Multihop Socks5 Script am Ende ausführen (wenn Multihop gewählt)
if [ "$run_socks5_multihop" -eq 1 ]; then
    echo ""
    echo "==> Führe socks5_multihop.sh Script aus..."
    if [ -x ./socks5_multihop.sh ]; then
        ./socks5_multihop.sh
        echo "==> socks5_multihop.sh wurde ausgeführt."
    else
        echo "==> Fehler: socks5_multihop.sh Script nicht gefunden oder nicht ausführbar!"
        exit 1
    fi
fi

# 16. Abschlussmeldung
echo ""
echo "==> Setup abgeschlossen. Bitte starte das System neu, damit alle Änderungen wirksam werden."

