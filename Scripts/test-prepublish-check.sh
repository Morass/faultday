#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -r "$scratch"' EXIT

git -C "$scratch" init -q
git -C "$scratch" config user.name Morass
git -C "$scratch" config user.email 7627986+Morass@users.noreply.github.com
mkdir "$scratch/Scripts"
cp "$source_dir/prepublish-check.sh" "$scratch/Scripts/prepublish-check.sh"
chmod +x "$scratch/Scripts/prepublish-check.sh"

# Build the private path at run time so this test does not contain one itself.
printf '/Users/%s/.ssh/id_rsa\n' privateperson > "$scratch/old-path.txt"
git -C "$scratch" add old-path.txt
git -C "$scratch" commit -qm 'Add temporary fixture'
git -C "$scratch" rm -q old-path.txt
git -C "$scratch" commit -qm 'Remove temporary fixture'

if (cd "$scratch" && Scripts/prepublish-check.sh > gate-result.txt 2>&1); then
    echo 'privacy gate missed a deleted home path' >&2
    exit 1
fi
rg -q 'home paths or IP addresses in past diffs' "$scratch/gate-result.txt"
printf '/Users/%s/\n' privateperson > "$scratch/.git/info/private-exceptions"
(cd "$scratch" && Scripts/prepublish-check.sh > gate-result.txt 2>&1)
rg -q 'nothing personal or private found' "$scratch/gate-result.txt"
printf 'privacy gate regression passed\n'
