#!/bin/bash

set -e

API_RECOMMENDED="https://api.nordvpn.com/v1/servers/recommendations"
API_CREDENTIALS="https://api.nordvpn.com/v1/users/services/credentials"
WG_CONFIG_DIR="./wg_configs"
RESPONSE_DIR="./api_responses"
OUTPUT_JSON="$RESPONSE_DIR/recommended_servers.json"
FILTERED_JSON="$RESPONSE_DIR/recommended_german_servers.json"
WG_PORT=51820
INTERFACE_IP="10.5.0.2/16"

mkdir -p "$WG_CONFIG_DIR" "$RESPONSE_DIR"

log() {
  echo "[INFO] $1"
}

# Token eingeben
read -rsp "Bitte NordVPN Access Token eingeben: " TOKEN
echo

if [ -z "$TOKEN" ]; then
  echo "Access Token darf nicht leer sein."
  exit 1
fi

# Private Key abrufen
log "Authentifiziere und hole Private Key..."
TOKEN_ENCODED=$(echo -n "token:$TOKEN" | base64 -w0)

PRIVATE_KEY_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
  -H "Authorization: Basic $TOKEN_ENCODED" \
  "$API_CREDENTIALS")

HTTP_STATUS=$(echo "$PRIVATE_KEY_RESPONSE" | grep "^HTTP_STATUS:" | cut -d':' -f2)
PRIVATE_KEY_RESPONSE=$(echo "$PRIVATE_KEY_RESPONSE" | grep -v "^HTTP_STATUS:")
echo "$PRIVATE_KEY_RESPONSE" > "$RESPONSE_DIR/private_key_response.txt"

PRIVATE_KEY=$(echo "$PRIVATE_KEY_RESPONSE" | jq -r '.nordlynx_private_key // empty')

if [ -z "$PRIVATE_KEY" ]; then
  echo "[ERROR] Private Key konnte nicht abgerufen werden (Status $HTTP_STATUS)."
  echo "Antwort gespeichert in: $RESPONSE_DIR/private_key_response.txt"
  exit 1
fi

log "Private Key erfolgreich abgerufen."

# Empfohlene Server laden
log "Lade empfohlene NordVPN-Server..."
curl -s -H "Authorization: Bearer $TOKEN" "$API_RECOMMENDED" > "$OUTPUT_JSON"

# Nur DE + WireGuard
jq '[.[] | select(.locations[].country.code == "DE") | select(.technologies[]?.identifier == "wireguard_udp")]' "$OUTPUT_JSON" > "$FILTERED_JSON"

SERVER_COUNT=$(jq length "$FILTERED_JSON")
log "Gefundene deutsche WireGuard-Server: $SERVER_COUNT"

if [ "$SERVER_COUNT" -eq 0 ]; then
  echo "[WARNUNG] Keine passenden Server gefunden."
  exit 1
fi

# Konfigurationen schreiben
jq -c '.[]' "$FILTERED_JSON" | while read -r server; do
  HOSTNAME=$(echo "$server" | jq -r '.hostname')
  ENDPOINT=$(echo "$server" | jq -r '.station')
  PUBKEY=$(echo "$server" | jq -r '.technologies[] | select(.identifier=="wireguard_udp") | .metadata[]? | select(.name=="public_key") | .value')

  if [ -z "$ENDPOINT" ] || [ -z "$PUBKEY" ]; then
    log "Unvollständige Daten bei $HOSTNAME, überspringe."
    continue
  fi

  cat > "$WG_CONFIG_DIR/$HOSTNAME.conf" << EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $INTERFACE_IP
DNS = 103.86.96.100, 103.86.99.100

[Peer]
PublicKey = $PUBKEY
Endpoint = $ENDPOINT:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  log "WireGuard-Config für $HOSTNAME erstellt."
done

log "Alle Konfigurationen gespeichert in $WG_CONFIG_DIR."
