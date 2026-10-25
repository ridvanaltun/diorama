// Scripted fake Anthropic Messages API for scripts/demo-screenshots.sh (no account, no API
// calls). Main loop: WebFetch example.com -> WebFetch example.org -> a final answer that echoes
// every tool_result it received (i.e. what "the model saw").
import http from 'node:http';
import zlib from 'node:zlib';

const PORT = Number(process.env.PORT || 8788);
let n = 0;
const runId = Math.random().toString(36).slice(2, 8);

const textOf = (c) => typeof c === 'string' ? c : Array.isArray(c) ? c.map((b) => b.text ?? `[${b.type}]`).join('\n') : '';

function plan(body) {
  const tools = (body.tools || []).map((t) => t.name);
  // Claude Code loads WebFetch on demand, so it may be missing from `tools`; requests without
  // any tools are its helper calls (WebFetch's summarizer, titles).
  if (tools.length === 0) {
    if (body.output_config?.format) return { text: '{"title":"poc"}' };
    return { text: 'Heading: Example Domain. This domain is for use in documentation examples.' };
  }
  const results = body.messages.flatMap((m) => (m.role === 'user' && Array.isArray(m.content) ? m.content : [])).filter((b) => b.type === 'tool_result');
  if (results.length === 0) return { tool: { name: 'WebFetch', input: { url: 'https://example.com', prompt: 'What is the main heading?' } } };
  if (results.length === 1) return { tool: { name: 'WebFetch', input: { url: 'https://example.org', prompt: 'What is the main heading?' } } };
  return { text: 'MODEL SAW:\n' + results.map((r, i) => `#${i + 1} ${textOf(r.content).slice(0, 160)}`).join('\n') };
}

function sse(res, ev, data) { res.write(`event: ${ev}\ndata: ${JSON.stringify({ type: ev, ...data })}\n\n`); }

http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    if (req.method === 'HEAD' || !req.url.startsWith('/v1/messages')) return res.writeHead(200).end();
    let raw = Buffer.concat(chunks);
    if (req.headers['content-encoding'] === 'gzip') raw = zlib.gunzipSync(raw);
    const body = JSON.parse(raw.toString('utf8'));
    if (req.url.startsWith('/v1/messages/count_tokens')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ input_tokens: 1234 }));
    }
    const p = plan(body);
    const id = `msg_poc_${++n}`;
    const usage = { input_tokens: 100, output_tokens: 20, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };
    const block = p.tool
      ? { type: 'tool_use', id: `toolu_poc_${runId}_${n}`, name: p.tool.name, input: p.tool.input }
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
