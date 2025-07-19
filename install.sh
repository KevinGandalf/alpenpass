#!/bin/sh
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

# 2. Zweites Netzwerkinterface automatisch finden (nicht lo)
interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo)
second_if=$(echo "$interfaces" | sed -n '2p')
if [ -z "$second_if" ]; then
    echo "==> Kein zweites Netzwerkinterface gefunden. Abbruch."
    exit 1
fi
echo "==> Zweites Netzwerkinterface erkannt: $second_if"

# 3. IP und Netzmaske vom Nutzer abfragen
read -rp "Bitte statische IP für $second_if eingeben (z.B. 192.168.1.10): " ip_addr
read -rp "Bitte Netzmaske für $second_if eingeben (z.B. 255.255.255.0): " netmask
if [ -z "$ip_addr" ] || [ -z "$netmask" ]; then
    echo "==> Ungültige IP oder Netzmaske. Abbruch."
    exit 1
fi

# 4. IP auf Interface setzen
ip addr flush dev "$second_if"
ip addr add "$ip_addr"/"$netmask" dev "$second_if"
ip link set dev "$second_if" up
echo "==> IP-Adresse $ip_addr/$netmask auf $second_if gesetzt."

# 4.5 /etc/network/interfaces ergänzen (nicht überschreiben)
if ! grep -q "$second_if" /etc/network/interfaces; then
    echo "" >> /etc/network/interfaces
    echo "# Konfiguration für $second_if hinzugefügt durch Setup-Skript" >> /etc/network/interfaces
    echo "auto $second_if" >> /etc/network/interfaces
    echo "iface $second_if inet static" >> /etc/network/interfaces
    echo "    address $ip_addr" >> /etc/network/interfaces
    echo "    netmask $netmask" >> /etc/network/interfaces
    echo "==> Eintrag für $second_if in /etc/network/interfaces hinzugefügt."
else
    echo "==> $second_if ist bereits in /etc/network/interfaces vorhanden. Kein Eintrag vorgenommen."
fi

# 5. System aktualisieren und Pakete installieren
echo "==> System aktualisieren und Pakete installieren..."
apk update && apk upgrade
apk add --no-cache openvpn wireguard-tools iptables iptables-openrc bash iproute2 curl wget git htop net-tools
echo "==> Paketinstallation abgeschlossen."

# 6. Speicherplatz und aktive Ports anzeigen
echo ""
echo "==> Speicherplatzübersicht:"
df -h

echo ""
echo "==> Aktive Ports:"
netstat -tulpen || ss -tulpen

# 7. sysctl-Konfiguration für IP-Forwarding und IPv6 deaktivieren
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

# 8. VPN-Typ auswählen und Konfiguration einlesen
echo ""
echo "==> VPN-Typ auswählen:"
echo "1 = OpenVPN"
echo "2 = WireGuard"
echo "3 = PIA"
echo "4 = AdGuardVPN (Experimentel!)"
read -rp "Auswahl [1-4]: " vpn_type

vpn_if=""

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
        wg-quick up wg0
        echo "==> WireGuard-Konfiguration gespeichert und gestartet."
        vpn_if="wg0"
        ;;

    3)
        echo "==> Starte PIA Installations-Skript..."
        /opt/alpenpass/helper/provider/pia/pia_install.sh
        vpn_if="pia0"
        ;;

    4)
        echo "==> Starte AdGuardVPN Installations-Skript..."
        /opt/alpenpass/helper/provider/adguardvpn/adguardvpn_experimentell.sh
        vpn_if="tun0"
        ;;

    *)
        echo "==> Ungültige Auswahl. Abbruch."
        exit 1
        ;;
esac

# 9. sysctl nochmal laden
echo ""
echo "==> Lade sysctl-Konfiguration erneut..."
sysctl -p /etc/sysctl.d/99-forwarding.conf

# 10. SSH-Hostkeys neu generieren
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

# 11. iptables Setup
echo ""
echo "==> IPtables Setup..."

rc-update add iptables default

cat << EOF > /etc/iptables/rules.v4
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A FORWARD -s ${ip_addr}/32 -i ${second_if} -o ${vpn_if} -j ACCEPT
-A FORWARD -s ${ip_addr}/32 -p icmp -m icmp --icmp-type 8 -j ACCEPT
-A FORWARD -d ${ip_addr}/32 -p icmp -m icmp --icmp-type 0 -j ACCEPT
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

iptables-restore < /etc/iptables/rules.v4
echo "==> iptables-Regeln gesetzt und gespeichert."

# 12. Abschlussmeldung
echo ""
echo "==> Setup abgeschlossen. Bitte starte das System neu, damit alle Änderungen wirksam werden."
