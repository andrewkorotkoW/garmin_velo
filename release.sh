#!/usr/bin/env bash
# .iq для Connect IQ Store (все устройства из manifest): ./release.sh [watchface|ridefield]
set -euo pipefail
cd "$(dirname "$0")"
APP="${1:-watchface}"
SDK="$(cat "$HOME/Library/Application Support/Garmin/ConnectIQ/current-sdk.cfg")"
KEY="$HOME/.Garmin/ConnectIQ/developer_key"
mkdir -p bin
"$SDK/bin/monkeyc" -e -f "$APP/monkey.jungle" -o "bin/$APP.iq" -y "$KEY" -w -r -l 1
echo "ok: bin/$APP.iq"
