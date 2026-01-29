#!/bin/bash
set -e
rm -f /tmp/.X99-lock /run/cloudflare-warp/warp_service.sock || true
./warp.sh c || true
Xvfb :99 -screen 0 1366x768x24 -ac +extension RANDR &
sleep 5
export DISPLAY=:99
exec python -u main.py
