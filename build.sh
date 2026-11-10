#!/usr/bin/env bash
# Сборка одного приложения под одно устройство:
#   ./build.sh watchface [device]   циферблат «Вело»
#   ./build.sh ridefield [device]   поле данных «Вело заезд»
set -euo pipefail
cd "$(dirname "$0")"
APP="${1:-watchface}"
DEVICE="${2:-fenix847mm}"
SDK="$(cat "$HOME/Library/Application Support/Garmin/ConnectIQ/current-sdk.cfg")"
KEY="$HOME/.Garmin/ConnectIQ/developer_key"
mkdir -p bin
"$SDK/bin/monkeyc" -d "$DEVICE" -f "$APP/monkey.jungle" -o "bin/$APP-$DEVICE.prg" -y "$KEY" -w -l 1
echo "ok: bin/$APP-$DEVICE.prg"
