#!/bin/bash
# One-time setup of the MQTT broker on a fresh Ubuntu server. Run as root:
#   ./setup.sh mqtt.example.com admin@example.com
# The domain must already point to this server and ports 80 and 8883 must be open.
set -euo pipefail

DOMAIN="${1:?usage: setup.sh DOMAIN EMAIL}"
EMAIL="${2:?usage: setup.sh DOMAIN EMAIL}"
HERE="$(cd "$(dirname "$0")" && pwd)"

apt-get update -q
apt-get install -y -q mosquitto mosquitto-clients certbot

# RSA key: older Control4 controllers may not handle ECDSA certificates.
certbot certonly --standalone --non-interactive --agree-tos \
  --key-type rsa --rsa-key-size 2048 -m "$EMAIL" -d "$DOMAIN"

# Mosquitto cannot read /etc/letsencrypt, so copy the certificate after every renewal.
HOOK=/etc/letsencrypt/renewal-hooks/deploy/mosquitto.sh
cat > "$HOOK" <<HOOKEOF
#!/bin/sh
install -d -o mosquitto -g mosquitto -m 750 /etc/mosquitto/certs
install -o mosquitto -g mosquitto -m 640 /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/mosquitto/certs/fullchain.pem
install -o mosquitto -g mosquitto -m 640 /etc/letsencrypt/live/$DOMAIN/privkey.pem /etc/mosquitto/certs/privkey.pem
systemctl restart mosquitto
HOOKEOF
chmod 755 "$HOOK"

install -o root -g root -m 644 "$HERE/c4-gateway.conf" /etc/mosquitto/conf.d/c4-gateway.conf
install -o mosquitto -g mosquitto -m 640 "$HERE/acl" /etc/mosquitto/acl
if [ ! -f /etc/mosquitto/passwd ]; then
  install -o mosquitto -g mosquitto -m 640 /dev/null /etc/mosquitto/passwd
fi

# Account for the backend; the password is kept in a root-only file.
if ! grep -q '^backend:' /etc/mosquitto/passwd; then
  (umask 077; openssl rand -hex 24 > /root/c4-backend-password)
  mosquitto_passwd -b /etc/mosquitto/passwd backend "$(cat /root/c4-backend-password)"
fi

"$HOOK"
systemctl enable mosquitto
echo "Broker ready: $DOMAIN port 8883. Add controllers with ./add-unit.sh UNIT_ID"
