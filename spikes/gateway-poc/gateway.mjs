// Throwaway PoC: pass-through Anthropic Messages gateway that rewrites selected
// tool_result blocks in outgoing requests, with a per-tool_use_id replay cache.
import http from 'node:http';
import https from 'node:https';
import zlib from 'node:zlib';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const PORT = Number(process.env.PORT || 8787);
const UPSTREAM = new URL(process.env.UPSTREAM || 'https://api.anthropic.com');
const LOG_DIR = process.env.LOG_DIR || path.resolve('logs');
const REWRITE_TOOLS = (process.env.REWRITE_TOOLS || 'WebFetch,WebSearch').split(',');
// MODE=stable (cache + replay) | unstable (rewrite only on first sight, to show the failure mode)
const MODE = process.env.MODE || 'stable';

fs.mkdirSync(LOG_DIR, { recursive: true });
const cache = new Map(); // tool_use_id -> rewritten content
let seq = 0;

const REDACT = new Set(['authorization', 'x-api-key', 'cookie']);
const redactHeaders = (h) =>
  Object.fromEntries(Object.entries(h).map(([k, v]) => [k, REDACT.has(k) ? '<redacted>' : v]));

function decode(buf, enc) {
  if (!enc || enc === 'identity') return buf;
  if (enc === 'gzip') return zlib.gunzipSync(buf);
  if (enc === 'br') return zlib.brotliDecompressSync(buf);
  if (enc === 'deflate') return zlib.inflateSync(buf);
  if (enc === 'zstd' && zlib.zstdDecompressSync) return zlib.zstdDecompressSync(buf);
  throw new Error(`unsupported content-encoding ${enc}`);
}

function textOf(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((b) => (b.type === 'text' ? b.text : `[${b.type}]`)).join('\n');
  return JSON.stringify(content);
}

function rewriteContent(content, toolName) {
  // Deterministic stand-in for the rewrite agent.
  const original = textOf(content);
  const changed = `[MORPH-POC rewrote ${toolName} result]\n` +
    original.replace(/Example Domain/g, 'Morph Test Domain');
  if (typeof content === 'string') return changed;
  return [{ type: 'text', text: changed }];
}

function transform(body, audit) {
  if (!Array.isArray(body.messages)) return false;
  const toolNames = new Map();
  for (const m of body.messages) {
    if (m.role === 'assistant' && Array.isArray(m.content)) {
      for (const b of m.content) if (b.type === 'tool_use' || b.type === 'server_tool_use') toolNames.set(b.id, b.name);
    }
  }
  let changed = false;
  for (const m of body.messages) {
    if (m.role !== 'user' || !Array.isArray(m.content)) continue;
    for (const b of m.content) {
      if (b.type !== 'tool_result') continue;
      const name = toolNames.get(b.tool_use_id);
      audit.toolResults.push({ id: b.tool_use_id, name, keys: Object.keys(b), contentKind: Array.isArray(b.content) ? 'blocks' : typeof b.content, hasCacheControl: !!b.cache_control });
      if (!REWRITE_TOOLS.includes(name)) continue;
      let next = cache.get(b.tool_use_id);
      if (next === undefined) {
        next = rewriteContent(b.content, name);
        cache.set(b.tool_use_id, next);
        audit.rewrites.push({ id: b.tool_use_id, name, kind: 'fresh', before: textOf(b.content).slice(0, 300), after: textOf(next).slice(0, 300) });
      } else if (MODE === 'unstable') {
        audit.rewrites.push({ id: b.tool_use_id, name, kind: 'skipped-replay (unstable mode)' });
        continue;
      } else {
        audit.rewrites.push({ id: b.tool_use_id, name, kind: 'replay' });
      }
      b.content = next;
      changed = true;
    }
  }
  return changed;
}

http.createServer((req, res) => {
  const id = String(++seq).padStart(3, '0');
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    let raw = Buffer.concat(chunks);
    const headers = { ...req.headers };
    delete headers.host;
    delete headers.connection;
    const audit = { id, method: req.method, url: req.url, reqHeaders: redactHeaders(req.headers), encoding: req.headers['content-encoding'] || null, toolResults: [], rewrites: [] };

    if (req.method === 'POST' && req.url.startsWith('/v1/messages') && raw.length) {
      try {
        const body = JSON.parse(decode(raw, headers['content-encoding']).toString('utf8'));
        audit.model = body.model;
        audit.stream = body.stream;
        audit.topLevelKeys = Object.keys(body);
        audit.msgCount = body.messages?.length;
        audit.thinkingBlocks = (body.messages || []).flatMap((m) => Array.isArray(m.content) ? m.content : []).filter((b) => b.type === 'thinking' || b.type === 'redacted_thinking').length;
        fs.writeFileSync(path.join(LOG_DIR, `${id}-req-original.json`), JSON.stringify(body, null, 2));
        if (transform(body, audit)) {
          raw = Buffer.from(JSON.stringify(body));
          delete headers['content-encoding'];
          fs.writeFileSync(path.join(LOG_DIR, `${id}-req-modified.json`), JSON.stringify(body, null, 2));
        }
        audit.bodySha = crypto.createHash('sha256').update(raw).digest('hex').slice(0, 12);
      } catch (e) {
        audit.parseError = String(e);
      }
      headers['content-length'] = String(raw.length);
    }

    const up = (UPSTREAM.protocol === 'https:' ? https : http).request(
      { protocol: UPSTREAM.protocol, hostname: UPSTREAM.hostname, port: UPSTREAM.port || undefined, method: req.method, path: req.url, headers },
      (upRes) => {
        audit.status = upRes.statusCode;
        audit.resHeaders = upRes.headers;
        res.writeHead(upRes.statusCode, upRes.headers);
        const resChunks = [];
        let firstByteAt;
        const t0 = Date.now();
        upRes.on('data', (c) => { firstByteAt ??= Date.now() - t0; resChunks.push(c); res.write(c); });
        upRes.on('end', () => {
          res.end();
          audit.firstByteMs = firstByteAt;
          audit.chunks = resChunks.length;
          let out = Buffer.concat(resChunks);
          try { out = decode(out, upRes.headers['content-encoding']); } catch {}
          fs.writeFileSync(path.join(LOG_DIR, `${id}-res.txt`), out);
          fs.writeFileSync(path.join(LOG_DIR, `${id}-audit.json`), JSON.stringify(audit, null, 2));
          console.log(`${id} ${req.method} ${req.url} -> ${upRes.statusCode} model=${audit.model ?? '-'} msgs=${audit.msgCount ?? '-'} toolResults=${audit.toolResults.length} rewrites=${audit.rewrites.map((r) => r.kind).join('|') || '-'}`);
        });
      },
    );
    up.on('error', (e) => { console.error(id, 'upstream error', e); res.writeHead(502).end(); });
    up.end(raw);
  });
}).listen(PORT, '127.0.0.1', () => console.log(`gateway on :${PORT} -> ${UPSTREAM.origin} mode=${MODE}`));
