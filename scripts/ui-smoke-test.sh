#!/bin/zsh
# UI smoke test: launches the bundled app against a fresh, empty data directory, lets it
# render every section and every sheet off-screen (self-snapshot mode), and checks that each
# screen produced a non-trivial image. Needs a GUI session (works on the self-hosted runner).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Diorama.app"
WORK="$(mktemp -d)"
export DIORAMA_HOME="$WORK/home" DIORAMA_SNAPSHOT_DIR="$WORK/shots" DIORAMA_SNAPSHOT_OFFSCREEN=1
cleanup() {
  "$APP/Contents/Helpers/diorama" daemon stop > /dev/null 2>&1 || true
  pkill -f "$WORK/home" > /dev/null 2>&1 || true
}
trap cleanup EXIT

# Ignore saved window state: if Diorama was last left in the menu bar with its window closed,
# it would start without a window and render nothing.
"$APP/Contents/MacOS/Diorama" -ApplePersistenceIgnoreState YES > "$WORK/app.log" 2>&1 &
APP_PID=$!
EXPECTED=(sessions experiments profiles settings getting-started sheet-new-session sheet-prompt-assist sheet-new-session-desktop sheet-edit-connected sheet-new-profile sheet-new-experiment menu-bar-panel mcp-connect sheet-export-data sheet-review menu-review sheet-profile-compare model-compare sheet-playground)
# The app quits by itself once every screen is rendered; give up after two minutes.
for i in {1..120}; do
  sleep 1
  kill -0 $APP_PID 2> /dev/null || break
done
kill $APP_PID 2> /dev/null || true

FAIL=0
for name in $EXPECTED; do
  f="$DIORAMA_SNAPSHOT_DIR/$name.png"
  if [[ ! -f "$f" ]]; then echo "✗ $name: not rendered"; FAIL=1; continue; fi
  size=$(stat -f %z "$f")
  if (( size < 15000 )); then echo "✗ $name: image too small ($size bytes), probably blank"; FAIL=1; else echo "✓ $name ($size bytes)"; fi
done
if (( FAIL )); then
  echo "--- app log"; tail -20 "$WORK/app.log"
  exit 1
fi
echo "✓ UI smoke test passed (snapshots: $DIORAMA_SNAPSHOT_DIR)"
