#!/bin/sh
# Brief 009 / DECISIONS #19: the public SousLens app must not link Meta's DAT SDK or
# ExternalAccessory, nor carry any glasses-only Info.plist keys.
# Usage: check-no-dat.sh <path/to/SousLens.app>
set -eu
app="${1:?usage: check-no-dat.sh <path/to/SousLens.app>}"
[ -d "$app" ] || { echo "check-no-dat: $app not found" >&2; exit 2; }
plist="$app/Info.plist"
[ -f "$plist" ] || { echo "check-no-dat: FAIL: no Info.plist in $app" >&2; exit 2; }
fail=0
note() { echo "check-no-dat: FAIL: $*" >&2; fail=1; }

# 1. No DAT frameworks embedded (any file or folder named MWDAT*).
if [ -d "$app/Frameworks" ] && find "$app/Frameworks" -iname 'MWDAT*' | grep -q .; then
  note "MWDAT in Frameworks: $(find "$app/Frameworks" -maxdepth 1 -iname 'MWDAT*' | xargs -n1 basename | tr '\n' ' ')"
fi

# 2. The main executable must exist and be inspected (a missing binary must never pass).
exe_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null || true)
[ -n "$exe_name" ] || exe_name=$(basename "$app" .app)
main="$app/$exe_name"
[ -f "$main" ] || { echo "check-no-dat: FAIL: main executable $main missing" >&2; exit 1; }

inspected=0
for bin in "$main" "$app"/*.dylib; do
  [ -f "$bin" ] || continue
  inspected=$((inspected + 1))
  # Load commands.
  if otool -L "$bin" | grep -Eiq 'MWDAT|ExternalAccessory'; then
    note "$(basename "$bin") links: $(otool -L "$bin" | grep -Ei 'MWDAT|ExternalAccessory' | tr -s ' \t' ' ')"
  fi
  # Symbols (unstripped builds) and raw bytes (stripped Release binaries hide symbols from nm).
  if nm -m "$bin" 2>/dev/null | grep -q 'MWDAT'; then
    note "$(basename "$bin") references MWDAT symbols"
  fi
  if grep -aq 'MWDAT' "$bin"; then
    note "$(basename "$bin") contains the string MWDAT"
  fi
done
[ "$inspected" -ge 1 ] || { echo "check-no-dat: FAIL: no executable was inspected" >&2; exit 1; }

# 3. No DAT / glasses-only Info.plist keys or values.
for key in MWDAT UISupportedExternalAccessoryProtocols; do
  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    note "Info.plist has $key"
  fi
done
plist_has() { # <key> <value regex>
  /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null | grep -Eq "$2"
}
plist_has NSBonjourServices '_meta-datax' && note "NSBonjourServices has _meta-datax._tcp"
plist_has LSApplicationQueriesSchemes 'fb-viewapp' && note "LSApplicationQueriesSchemes has fb-viewapp"
plist_has UIBackgroundModes 'external-accessory|bluetooth-central' && note "UIBackgroundModes has external-accessory/bluetooth-central"
plist_has CFBundleURLTypes 'souslensglasses' && note "CFBundleURLTypes has the souslensglasses scheme"

[ "$fail" -eq 0 ] && echo "check-no-dat: OK — $(basename "$app") ($inspected binaries) links no DAT, no ExternalAccessory, no glasses plist keys."
exit "$fail"
