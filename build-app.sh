#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
app_dir="$script_dir/dist/Note Island.app"
archive_path="$script_dir/dist/Note-Island-macOS.zip"
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/note-island-build.XXXXXX")
staging_app="$staging_root/Note Island.app"
contents_dir="$staging_app/Contents"
trap 'rm -rf "$staging_root"' EXIT

cd "$script_dir"
swift build -c release

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
install -m 755 ".build/release/NoteIsland" "$contents_dir/MacOS/NoteIsland"
install -m 644 "App/Info.plist" "$contents_dir/Info.plist"

xattr -cr "$staging_app"
signing_identity=$(security find-identity -v -p codesigning \
    | sed -nE 's/^[[:space:]]*[0-9]+\) ([0-9A-F]+) "Apple Development:.*$/\1/p' \
    | head -1)
if [[ -z "$signing_identity" ]]; then
    signing_identity=-
fi
codesign --force --deep --options runtime --entitlements "App/NoteIsland.entitlements" --sign "$signing_identity" "$staging_app"
codesign --verify --deep --strict "$staging_app"
rm -f "$archive_path"
ditto -c -k --keepParent --norsrc "$staging_app" "$archive_path"
rm -rf "$app_dir"
ditto --norsrc "$staging_app" "$app_dir"
echo "$archive_path"
