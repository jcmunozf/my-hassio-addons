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

required_vars=(INTERFACE SSID CHANNEL ADDRESS NETWORK NETMASK BROADCAST)
for required_var in "${required_vars[@]}"; do
    if [[ -z "${!required_var}" || "${!required_var}" == "null" ]]; then
        echo >&2 "Error: $required_var is not set."
        exit 1
    fi
done

term_handler() {
    echo "Stopping..."
    pkill dnsmasq || true
    pkill hostapd || true
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

echo "Configuring interface $INTERFACE..."
ip link set "$INTERFACE" down || true
ip addr flush dev "$INTERFACE" || true
ip addr add 192.168.99.1/24 dev "$INTERFACE"
ip link set "$INTERFACE" up
ip addr show "$INTERFACE"

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

RANGE_START="$(echo "$NETWORK" | cut -d . -f 1-3).2"
RANGE_END="$(echo "$NETWORK" | cut -d . -f 1-3).100"

RANGE_START="192.168.99.2"
RANGE_END="192.168.99.100"

cat > /etc/dnsmasq.conf <<EOF
interface=$INTERFACE
bind-interfaces
dhcp-range=$RANGE_START,$RANGE_END,255.255.255.0,12h
dhcp-option=3,192.168.99.1
dhcp-option=6,192.168.99.1
log-queries
log-dhcp
EOF

echo "Starting dnsmasq..."
dnsmasq --no-daemon &

echo "$FIXED_IPS" | jq -c '.[]' | while read -r row; do
    NAME=$(echo "$row" | jq -r '.name')
    MAC=$(echo "$row" | jq -r '.mac_address')
    IP=$(echo "$row" | jq -r '.ip')
    echo "dhcp-host=$MAC,$IP" >> /etc/dnsmasq.conf
done

echo "Starting dnsmasq..."
dnsmasq --keep-in-foreground &

echo "Starting hostapd..."
exec hostapd -d /hostapd.conf


echo 1 > /proc/sys/net/ipv4/ip_forward

UPSTREAM="end0"
DOWNSTREAM="$INTERFACE"  # wlan0

# Allow forwarding between hotspot and LAN
iptables -F
iptables -t nat -F

iptables -A FORWARD -i "$DOWNSTREAM" -o "$UPSTREAM" -j ACCEPT
iptables -A FORWARD -i "$UPSTREAM" -o "$DOWNSTREAM" -m state --state RELATED,ESTABLISHED -j ACCEPT
