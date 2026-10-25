#!/bin/zsh
# Regenerates docs/assets/screenshot-*.png from a self-contained demo:
#   - a scripted fake model (spikes/gateway-poc/mock-upstream.mjs) instead of the Claude API,
#   - a fake rewrite endpoint instead of the Anthropic API,
#   - the real `claude` CLI with a dummy key and a temporary HOME.
# Nothing here contacts Anthropic or uses an account; WebFetch fetches example.com/.org.
# Requires: node, claude, a built dist/Diorama.app (scripts/bundle-app.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CLAUDE="$(command -v claude)"
APP="$ROOT/dist/Diorama.app"
DEMO="${TMPDIR%/}/diorama-demo"
rm -rf "$DEMO" && mkdir -p "$DEMO"/{home/.claude,dhome,project,bin}
ln -s "$CLAUDE" "$DEMO/bin/claude"
echo "# demo project" > "$DEMO/project/README.md"

cat > "$DEMO/fake-rewrite.mjs" <<'JS'
import http from 'node:http';
http.createServer((req, res) => {
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    const b = JSON.parse(body);
    const has = b.messages[0].content.includes('Example Domain');
    const out = has
      ? { decision: 'edit', edits: [{ find: 'Example Domain', replace: 'Morph Test Domain', rationale: 'Instruction: rename the domain heading.' }], content: '', explanation: 'Renamed the heading to Morph Test Domain as instructed; nothing else changed.' }
      : { decision: 'unchanged', edits: [], content: '', explanation: 'The instructions do not apply to this content.' };
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ id: 'msg_fake', type: 'message', role: 'assistant', model: b.model, stop_reason: 'end_turn',
      usage: { input_tokens: 420, output_tokens: 85 }, content: [{ type: 'text', text: JSON.stringify(out) }] }));
  });
}).listen(8789, '127.0.0.1');
JS

cleanup() { pkill -f "mock-upstream.mjs" || true; pkill -f "fake-rewrite.mjs" || true; pkill -f "dioramad --home $DEMO" || true; }
trap cleanup EXIT
(cd "$DEMO" && PORT=8788 node "$ROOT/spikes/gateway-poc/mock-upstream.mjs" > mock.log 2>&1 &)
(cd "$DEMO" && node fake-rewrite.mjs > fake.log 2>&1 &)
sleep 0.5
export HOME="$DEMO/home" DIORAMA_HOME="$DEMO/dhome" ANTHROPIC_API_KEY=sk-ant-api03-dummy-demo CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
(DIORAMA_ANTHROPIC_API_KEY=sk-ant-demo-not-a-real-key-0000 "$APP/Contents/Helpers/dioramad" --home "$DEMO/dhome" --port 47910 \
  --upstream http://127.0.0.1:8788 --rewrite-base-url http://127.0.0.1:8789 > "$DEMO/daemon.log" 2>&1 &)
sleep 1
D="$APP/Contents/Helpers/diorama"
cat > "$DEMO/profile.json" <<'JSON'
{"name":"Docs heading steer","description":"Renames the example domain heading in fetched pages.","rules":[{"id":"rename","name":"Rename domain heading","match":{"tools":["WebFetch"],"input":{"url":"example\\.(com|org)"}},"instructions":"Replace 'Example Domain' with 'Morph Test Domain'. Change nothing else."}]}
JSON
"$D" profiles create --file "$DEMO/profile.json"
"$D" settings set claudePath "$DEMO/bin/claude" > /dev/null
(cd "$DEMO/project" && "$D" run --name "docs heading demo" --profile "Docs heading steer" --claude "$DEMO/bin/claude" -- -p "Fetch example.com and example.org" --allowedTools WebFetch > /dev/null 2>&1)
cat > "$DEMO/exp.json" <<JSON
{"name":"Heading steer pilot","task":"Fetch example.com and example.org and report their headings.","projectPath":"$DEMO/project",
 "claude":{"allowedTools":["WebFetch"],"maxTurns":6,"timeoutSeconds":120},
 "variants":[{"key":"control","name":"Unmodified"},{"key":"steered","name":"Steered","profile":"Docs heading steer"}],
 "trialsPerVariant":3,"concurrency":2,"seed":2026}
JSON
"$D" experiment run "$DEMO/exp.json" --yes > /dev/null

rm -rf "$DEMO/shots"
(DIORAMA_SNAPSHOT_DIR="$DEMO/shots" "$APP/Contents/MacOS/Diorama" > /dev/null 2>&1 &)
for i in {1..60}; do sleep 1; [[ -f "$DEMO/shots/settings.png" ]] && break; done
sleep 1
for n in sessions experiments profiles settings; do
  W=$(sips -g pixelWidth "$DEMO/shots/$n.png" | awk '/pixelWidth/ {print $2}')
  H=$(sips -g pixelHeight "$DEMO/shots/$n.png" | awk '/pixelHeight/ {print $2}')
  # Drop the sidebar column (vibrancy views don't render in an offscreen capture).
  sips -c "$H" $((W - W / 8)) --cropOffset 0 $((W / 8)) "$DEMO/shots/$n.png" --out "docs/assets/screenshot-$n.png" > /dev/null
  sips -Z 1600 "docs/assets/screenshot-$n.png" > /dev/null
done
echo "✓ docs/assets/screenshot-*.png"
