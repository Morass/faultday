#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
binary="${1:-.build/release/faultday}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/reports"
cat > "$work/reports/example.ips" <<'IPS'
{"app_name":"Example","timestamp":"2026-09-18 12:32:12.00 +0200","bug_type":"309","incident_id":"example-1","app_version":"1.0"}
{}
IPS
python3 - "$work/installs.plist" <<'PY'
import plistlib,sys,datetime
with open(sys.argv[1],'wb') as f:
 plistlib.dump([{'date':datetime.datetime(2026,9,18,10,0),'displayName':'Example Installer','displayVersion':'2.0'}],f)
PY
FAULTDAY_SELFTEST=scan FAULTDAY_REPORTS_DIR="$work/reports" FAULTDAY_INSTALL_HISTORY="$work/installs.plist" "$binary" > "$work/scan.txt"
rg -q 'crashes=1 installs=1 warnings=0' "$work/scan.txt"
FAULTDAY_SELFTEST=render FAULTDAY_REPORTS_DIR="$work/reports" FAULTDAY_INSTALL_HISTORY="$work/installs.plist" FAULTDAY_CAPTURE_PATH="$work/render.png" "$binary" > "$work/render.txt"
python3 - "$work/render.png" <<'PY'
from PIL import Image
import sys
im=Image.open(sys.argv[1]).convert('RGB')
assert im.size[0]>=790 and im.size[1]>=560
colors=im.resize((60,40)).getcolors(2400)
assert colors is not None and len(colors)>25, 'render appears blank'
right=im.crop((355,0,im.width,im.height))
pixels=list(right.resize((200,200)).getdata())
assert sum(1 for r,g,b in pixels if r<100 and g<100 and b<100)>20, 'event pane has no text'
assert sum(1 for r,g,b in pixels if r>180 and g>180 and b>180)>20000, 'event pane has no background'
PY
"$binary" --help | rg -q 'Usage: open Faultday.app'
mkdir "$work/empty"
if FAULTDAY_SELFTEST=scan FAULTDAY_REPORTS_DIR="$work/empty" "$binary" >/dev/null; then
 echo 'empty fixture passed unexpectedly' >&2; exit 1
fi
printf 'smoke: scan, render, help and negative control passed\n'
