#!/bin/bash
# Creates (or resets) the broker account of one controller. Run as root:
#   ./add-unit.sh 101
# Prints the values to enter in the driver properties in Composer.
set -euo pipefail

UNIT="${1:?usage: add-unit.sh UNIT_ID}"
if ! [[ "$UNIT" =~ ^[A-Za-z0-9_-]+$ ]] || [ "$UNIT" = backend ]; then
  echo "Unit ID may contain only letters, digits, '-' and '_'." >&2
  exit 1
fi

PASSWORD="$(openssl rand -hex 16)"
mosquitto_passwd -b /etc/mosquitto/passwd "$UNIT" "$PASSWORD"
systemctl reload mosquitto

echo "Unit ID:  $UNIT"
echo "Username: $UNIT"
echo "Password: $PASSWORD"
