#!/usr/bin/env bash
# Сборка и запуск в симуляторе: ./run.sh [watchface|ridefield] [device]
set -euo pipefail
cd "$(dirname "$0")"
APP="${1:-watchface}"
DEVICE="${2:-fenix847mm}"
SDK="$(cat "$HOME/Library/Application Support/Garmin/ConnectIQ/current-sdk.cfg")"
./build.sh "$APP" "$DEVICE"
pgrep -f "ConnectIQ.app" >/dev/null || ("$SDK/bin/connectiq" & sleep 4)
"$SDK/bin/monkeydo" "bin/$APP-$DEVICE.prg" "$DEVICE"
