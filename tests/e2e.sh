#!/usr/bin/env bash
# The whole loop, without the game, in a sandbox under tests/out:
#   1. the addon runs a simulated fishing session (tests/smoke.lua, a mock of the
#      game's API) and its SavedVariables are written the way the game writes them
#   2. creel stores the journal and writes Generated.lua
#   3. the addon loads again with that Generated.lua and the saved journal, and
#      fishes some more
#   4. creel stores only what is new
#   5. creel installs the addon into the sandbox game folder
#
# Needs luajit and cargo. Set TIGHTLINES_LFD to the game's AddOns folder to run
# the addon against the real LibForeverData as well (quests, trainers, pools).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
OUT="$ROOT/tests/out"
SV="$OUT/wow/WTF/Account/TEST/SavedVariables/TightLines.lua"

rm -rf "$OUT"
mkdir -p "$OUT/wow/WTF/Account/TEST/SavedVariables" "$OUT/wow/Interface/AddOns" "$OUT/addon"
cp -r "$ROOT/addon/TightLines" "$OUT/addon/TightLines"

cargo build --quiet --manifest-path "$ROOT/creel/Cargo.toml"
creel() {
  "$ROOT/creel/target/debug/creel" --wow "$OUT/wow" --db "$OUT/creel.db" --addon "$OUT/addon/TightLines" "$@"
}

echo "== 1. first session"
luajit "$ROOT/tests/smoke.lua" "$OUT/addon" "$SV"

echo "== 2. creel sync"
creel sync

echo "== 3. second session, with Generated.lua and the saved journal"
luajit "$ROOT/tests/smoke.lua" "$OUT/addon" "$SV" - "$SV"

echo "== 4. creel sync again (only the new events)"
creel sync

echo "== 5. creel install"
creel install
test -f "$OUT/wow/Interface/AddOns/TightLines/TightLines.toc"
test -f "$OUT/wow/Interface/AddOns/TightLines/Generated.lua"

echo "== 6. creel report"
creel report
echo "== 7. creel trips"
creel trips

echo
echo "END TO END PASSED"
