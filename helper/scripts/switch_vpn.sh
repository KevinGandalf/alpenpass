#!/bin/bash
set -e

echo "===== VPN Konfiguration aktualisieren & zwischen OpenVPN / WireGuard umschalten ====="

echo "Bitte wähle aus:"
echo "1) openvpn aktivieren"
echo "2) wireguard aktivieren"
echo "3) beenden"

read -p "Deine Wahl (1/2/3): " choice

case "$choice" in
    1)
        vpn_choice="openvpn"
        ;;
    2)
        vpn_choice="wireguard"
        ;;
    3)
        echo "Script wird beendet."
        exit 0
        ;;
    *)
        echo "Ungültige Eingabe! Script wird beendet."
        exit 1
        ;;
esac

echo
echo "Bitte füge jetzt die neue VPN-Konfiguration für $vpn_choice ein."
echo "Wenn fertig, drücke Ctrl+D (EOF)."
echo "-----------------------"

new_config=$(cat)

if [ -z "$new_config" ]; then
    echo "Fehler: Keine Konfiguration eingegeben."
    exit 2
fi

echo "-----------------------"
echo "Neue $vpn_choice-Konfiguration erhalten, schreibe Datei..."

openvpn_conf="/etc/openvpn/client.conf"
wireguard_conf="/etc/wireguard/wg0.conf"
credentials_file="/etc/openvpn/credentials"

# Backup der alten Konfigurationen (optional)
cp "$openvpn_conf" "${openvpn_conf}.bak.$(date +%F_%T)" 2>/dev/null || true
cp "$wireguard_conf" "${wireguard_conf}.bak.$(date +%F_%T)" 2>/dev/null || true
cp "$credentials_file" "${credentials_file}.bak.$(date +%F_%T)" 2>/dev/null || true

# Funktion: iptables Schnittstellen-Namen anpassen
# $1 = alter Schnittstellenname
# $2 = neuer Schnittstellenname
update_iptables_interface() {
    local old_if="$1"
    local new_if="$2"
    echo "Aktualisiere iptables-Regeln: $old_if -> $new_if ..."
    iptables-save > /tmp/iptables.rules.tmp
    # Ersetze Interface-Namen (z.B. -i wg0 oder -o tun0)
    sed -i "s/-i $old_if/-i $new_if/g" /tmp/iptables.rules.tmp
    sed -i "s/-o $old_if/-o $new_if/g" /tmp/iptables.rules.tmp
    iptables-restore < /tmp/iptables.rules.tmp
    rm /tmp/iptables.rules.tmp
    echo "iptables-Regeln aktualisiert."
}

if [ "$vpn_choice" == "openvpn" ]; then
    # Interaktive Abfrage Username/Passwort
    read -p "OpenVPN Benutzername: " ovpn_user
    read -s -p "OpenVPN Passwort: " ovpn_pass
    echo
    if [ -z "$ovpn_user" ] || [ -z "$ovpn_pass" ]; then
        echo "Benutzername oder Passwort darf nicht leer sein."
        exit 4
    fi

    echo -e "${ovpn_user}\n${ovpn_pass}" > "$credentials_file"
    chmod 600 "$credentials_file"
    echo "Benutzername/Passwort gespeichert in $credentials_file."

    # Prüfen ob config bereits auth-user-pass enthält
    if ! grep -q '^auth-user-pass' <<< "$new_config"; then
        new_config="$new_config"$'\n'"auth-user-pass $credentials_file"
    fi

    echo "$new_config" > "$openvpn_conf"
    echo "OpenVPN Config gespeichert."

    echo "Starte OpenVPN Dienst neu..."
    systemctl restart openvpn || rc-service openvpn restart || service openvpn restart

    echo "Stoppe WireGuard Interface wg0 (falls aktiv)..."
    wg-quick down wg0 2>/dev/null || true

    # iptables anpassen: wg0 -> tun0 (OpenVPN Interface)
    update_iptables_interface "wg0" "tun0"

    echo "VPN Umschaltung fertig. OpenVPN ist jetzt aktiv."

    echo
    echo "OpenVPN Status:"
    systemctl status openvpn --no-pager || rc-service openvpn status || service openvpn status

elif [ "$vpn_choice" == "wireguard" ]; then
    echo "$new_config" > "$wireguard_conf"
    echo "WireGuard Config gespeichert."

    echo "Stoppe OpenVPN Dienst..."
    systemctl stop openvpn 2>/dev/null || rc-service openvpn stop || service openvpn stop || true

    echo "Starte WireGuard Interface wg0 neu..."
    wg-quick down wg0 2>/dev/null || true
    wg-quick up wg0

    # iptables anpassen: tun0 -> wg0 (WireGuard Interface)
    update_iptables_interface "tun0" "wg0"

    echo "VPN Umschaltung fertig. WireGuard ist jetzt aktiv."

    echo
    echo "WireGuard Status:"
    wg show wg0

else
    echo "Fehlerhafte VPN-Auswahl"
    exit 3
fi
