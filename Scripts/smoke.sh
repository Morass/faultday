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
rg -q 'crashes=1 installs=1 other=0 warnings=0' "$work/scan.txt"
FAULTDAY_SELFTEST=render FAULTDAY_REPORTS_DIR="$work/reports" FAULTDAY_INSTALL_HISTORY="$work/installs.plist" FAULTDAY_CAPTURE_PATH="$work/render.png" "$binary" > "$work/render.txt"
FAULTDAY_SELFTEST=render FAULTDAY_CAPTURE_SCHEME=light FAULTDAY_REPORTS_DIR="$work/reports" FAULTDAY_INSTALL_HISTORY="$work/installs.plist" FAULTDAY_CAPTURE_PATH="$work/light.png" "$binary" > "$work/light.txt"
python3 - "$work/render.png" "$work/light.png" <<'PY'
from PIL import Image
import sys
im=Image.open(sys.argv[1]).convert('RGB')
assert im.size[0]>=1000 and im.size[1]>=680
colors=im.resize((60,40)).getcolors(2400)
assert colors is not None and len(colors)>25, 'render appears blank'
right=im.crop((338,0,im.width,im.height))
pixels=list(right.resize((200,200)).getdata())
assert sum(1 for r,g,b in pixels if r>170 and g>170 and b>170)>50, 'event pane has no text'
assert sum(1 for r,g,b in pixels if r<70 and g<85 and b<100)>20000, 'dark background missing'
chart=im.crop((360,160,im.width-15,325))
chartpixels=list(chart.getdata())
assert sum(1 for r,g,b in chartpixels if r>170 and r>g*1.4 and r>b*1.2)>80, 'crash graph missing'
assert sum(1 for r,g,b in chartpixels if b>130 and b>r*1.3 and b>g)>40, 'install graph missing'
light=Image.open(sys.argv[2]).convert('RGB')
assert light.size==im.size
assert sum(1 for r,g,b in light.resize((200,200)).getdata() if r>225 and g>225 and b>225)>20000, 'light background missing'
assert im.getpixel((20,20))[0] < 100, 'dark background missing'
assert light.getpixel((20,20))[0] > 220, 'light background missing'
PY
"$binary" --help | rg -q 'Usage: open Faultday.app'
mkdir "$work/empty"
if FAULTDAY_SELFTEST=scan FAULTDAY_REPORTS_DIR="$work/empty" "$binary" >/dev/null; then
 echo 'empty fixture passed unexpectedly' >&2; exit 1
fi
printf 'smoke: scan, render, help and negative control passed\n'
