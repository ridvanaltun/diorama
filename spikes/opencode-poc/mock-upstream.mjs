// Throwaway PoC: scripted fake Anthropic Messages API for inspecting OpenCode's requests.
// Main loop: read the file named in the prompt -> final answer echoing every tool_result
// it received (i.e. what "the model saw"). Logs path, headers (redacted) and bodies.
import http from 'node:http';
import zlib from 'node:zlib';
import fs from 'node:fs';
import path from 'node:path';

const PORT = Number(process.env.PORT || 8788);
const LOG_DIR = process.env.LOG_DIR || 'logs';
fs.mkdirSync(LOG_DIR, { recursive: true });
let n = 0;
const runId = Math.random().toString(36).slice(2, 8);
const SECRET = /^(authorization|x-api-key|cookie)$/i;

const textOf = (c) => typeof c === 'string' ? c : Array.isArray(c) ? c.map((b) => b.text ?? `[${b.type}]`).join('\n') : '';

function plan(body) {
  const read = (body.tools || []).find((t) => t.name === 'read');
  if (!read) return { text: 'poc title' };
  const results = body.messages.flatMap((m) => (m.role === 'user' && Array.isArray(m.content) ? m.content : [])).filter((b) => b.type === 'tool_result');
  const shell = (body.tools || []).find((t) => t.name === 'shell');
  if (process.env.SHELL_COMMAND && shell && results.length === 0) {
    const props = Object.keys(shell.input_schema?.properties || {});
    const key = props.find((p) => /command/i.test(p)) || props[0];
    return { tool: { name: 'shell', input: { [key]: process.env.SHELL_COMMAND, description: 'fetch' } } };
  }
  if (results.length === 0) {
    const props = Object.keys(read.input_schema?.properties || {});
    const key = props.find((p) => /path/i.test(p)) || props[0];
    return { tool: { name: 'read', input: { [key]: process.env.TARGET_FILE } } };
  }
  return { text: 'MODEL SAW:\n' + results.map((r, i) => `#${i + 1} ${textOf(r.content).slice(0, 300)}`).join('\n') };
}

function sse(res, ev, data) { res.write(`event: ${ev}\ndata: ${JSON.stringify({ type: ev, ...data })}\n\n`); }

http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const i = ++n;
    const headers = Object.fromEntries(Object.entries(req.headers).map(([k, v]) => [k, SECRET.test(k) ? '<redacted>' : v]));
    let raw = Buffer.concat(chunks);
    if (req.headers['content-encoding'] === 'gzip') raw = zlib.gunzipSync(raw);
    fs.writeFileSync(path.join(LOG_DIR, `${String(i).padStart(3, '0')}.json`), JSON.stringify({ method: req.method, url: req.url, headers, body: raw.length ? JSON.parse(raw.toString('utf8')) : null }, null, 2));
    console.log(`#${i} ${req.method} ${req.url}`);
    if (req.method !== 'POST' || !/\/messages$/.test(req.url.split('?')[0])) return res.writeHead(200, { 'content-type': 'application/json' }).end('{}');
    const body = JSON.parse(raw.toString('utf8'));
    const p = plan(body);
    const id = `msg_poc_${i}`;
    const usage = { input_tokens: 100, output_tokens: 20, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };
    const block = p.tool
      ? { type: 'tool_use', id: `toolu_poc_${runId}_${i}`, name: p.tool.name, input: p.tool.input }
      : { type: 'text', text: p.text };
    const stop = p.tool ? 'tool_use' : 'end_turn';
    if (!body.stream) {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ id, type: 'message', role: 'assistant', model: body.model, content: [block], stop_reason: stop, stop_sequence: null, usage }));
    }
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
    sse(res, 'message_start', { message: { id, type: 'message', role: 'assistant', model: body.model, content: [], stop_reason: null, stop_sequence: null, usage } });
    if (p.tool) {
      sse(res, 'content_block_start', { index: 0, content_block: { ...block, input: {} } });
      sse(res, 'content_block_delta', { index: 0, delta: { type: 'input_json_delta', partial_json: JSON.stringify(p.tool.input) } });
    } else {
      sse(res, 'content_block_start', { index: 0, content_block: { type: 'text', text: '' } });
      sse(res, 'content_block_delta', { index: 0, delta: { type: 'text_delta', text: p.text } });
    }
    sse(res, 'content_block_stop', { index: 0 });
    sse(res, 'message_delta', { delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 20 } });
    sse(res, 'message_stop', {});
    res.end();
  });
}).listen(PORT, '127.0.0.1', () => console.log(`mock upstream on :${PORT}`));
