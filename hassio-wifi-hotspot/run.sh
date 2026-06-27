#!/bin/bash
set -euo pipefail

CONFIG_PATH=/data/options.json

INTERFACE=$(jq -r '.interface' "$CONFIG_PATH")
SSID=$(jq -r '.ssid' "$CONFIG_PATH")
WPA_PASSPHRASE=$(jq -r '.wpa_passphrase' "$CONFIG_PATH")
CHANNEL=$(jq -r '.channel' "$CONFIG_PATH")
ADDRESS=$(jq -r '.address' "$CONFIG_PATH")
NETWORK=$(jq -r '.network' "$CONFIG_PATH")
NETMASK=$(jq -r '.netmask' "$CONFIG_PATH")
BROADCAST=$(jq -r '.broadcast' "$CONFIG_PATH")
FIXED_IPS=$(jq -c '.fixed_ips // []' "$CONFIG_PATH")

UPSTREAM="end0"           # wired LAN interface inside HAOS
ROUTER_IP="192.168.1.1"   # your main router on the LAN

required_vars=(INTERFACE SSID CHANNEL ADDRESS NETWORK NETMASK BROADCAST)
for required_var in "${required_vars[@]}"; do
    if [[ -z "${!required_var}" || "${!required_var}" == "null" ]]; then
        echo >&2 "Error: $required_var is not set."
        exit 1
    fi
done

term_handler() {
    echo "Stopping..."
    pkill dnsmasq 2>/dev/null || true
    pkill hostapd 2>/dev/null || true
    iptables -F || true
    iptables -t nat -F || true
    ip link set "$INTERFACE" down || true
    ip addr flush dev "$INTERFACE" || true
    exit 0
}
trap 'term_handler' SIGTERM SIGINT

echo "Starting hotspot on $INTERFACE"

if command -v nmcli >/dev/null 2>&1; then
    echo "Setting NetworkManager unmanaged for $INTERFACE"
    nmcli dev set "$INTERFACE" managed no || true
fi

echo "Stopping any existing dnsmasq..."
pkill dnsmasq 2>/dev/null || true

echo "Configuring interface $INTERFACE..."
ip link set "$INTERFACE" down || true
ip addr flush dev "$INTERFACE" || true
ip addr add "${ADDRESS}/24" broadcast "$BROADCAST" dev "$INTERFACE"
ip link set "$INTERFACE" up
ip addr show "$INTERFACE"

echo "Creating hostapd config..."
cat > /hostapd.conf <<EOF
interface=$INTERFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=$CHANNEL
wmm_enabled=1
EOF

if [[ -n "$WPA_PASSPHRASE" && "$WPA_PASSPHRASE" != "null" ]]; then
cat >> /hostapd.conf <<EOF
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$WPA_PASSPHRASE
EOF
else
    echo "WARNING: creating open access point"
fi

RANGE_START="$(echo "$NETWORK" | cut -d . -f 1-3).10"
RANGE_END="$(echo "$NETWORK" | cut -d . -f 1-3).200"

echo "Creating dnsmasq config..."
cat > /etc/dnsmasq.conf <<EOF
interface=$INTERFACE
bind-dynamic
except-interface=lo
dhcp-range=$RANGE_START,$RANGE_END,$NETMASK,12h
dhcp-option=3,$ADDRESS
dhcp-option=6,$ADDRESS
log-queries
log-dhcp
EOF

echo "$FIXED_IPS" | jq -c '.[]' | while read -r row; do
    MAC=$(echo "$row" | jq -r '.mac_address')
    IP=$(echo "$row" | jq -r '.ip')
    if [[ -n "$MAC" && "$MAC" != "null" && -n "$IP" && "$IP" != "null" ]]; then
        echo "dhcp-host=$MAC,$IP" >> /etc/dnsmasq.conf
    fi
done

echo "Starting dnsmasq..."
dnsmasq \
  --keep-in-foreground \
  --log-facility=- \
  --interface="$INTERFACE" &


echo "Enabling LAN-only forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward

iptables -F
iptables -t nat -F

# Allow hotspot clients to reach 192.168.1.0/24 (LAN including Home Assistant)
iptables -A FORWARD -i "$INTERFACE" -o "$UPSTREAM" -d 192.168.1.0/24 -j ACCEPT
iptables -A FORWARD -i "$UPSTREAM" -o "$INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT

# Block hotspot clients from reaching the router IP (no direct internet)
iptables -A FORWARD -i "$INTERFACE" -o "$UPSTREAM" -d "$ROUTER_IP" -j DROP
# Block any other traffic from hotspot to upstream (paranoid default)
iptables -A FORWARD -i "$INTERFACE" -o "$UPSTREAM" -j DROP

echo "Starting dnsmasq..."
dnsmasq --keep-in-foreground --log-facility=- --interface="$INTERFACE" --bind-interfaces &

sleep 2

echo "Starting hostapd..."
exec hostapd -d /hostapd.conf
