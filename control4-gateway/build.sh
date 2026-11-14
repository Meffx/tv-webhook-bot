#!/bin/sh
# Packs the driver into dist/building_gateway.c4z (a .c4z is a plain zip archive).
set -e
cd "$(dirname "$0")"
mkdir -p dist
rm -f dist/building_gateway.c4z
(cd driver && zip -q -X ../dist/building_gateway.c4z driver.xml driver.lua)
echo "Built dist/building_gateway.c4z"
