#!/usr/bin/env node
// ============================================================================
//  acs-proxy.mjs - Codex 本地协议翻译代理（Responses API → Chat Completions）
//  场景: Codex 只支持 Responses API，而智谱 GLM 等端点只实现 Chat Completions。
//  生命周期: 随 acs 会话启动，父进程(PowerShell/Bash)退出后 3 秒内自动自杀，
//           任何终端关闭方式都不会残留。
//  用法: node acs-proxy.mjs --port 0 --upstream <base> --ppid <pid> --portfile <path> [--debug]
// ============================================================================

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

// ---- 参数解析 ----
const args = process.argv.slice(2);
const get = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
const PORT = parseInt(get('port', '0'), 10);
const UPSTREAM = (get('upstream', '') || '').replace(/\/+$/, '');
const PPID = parseInt(get('ppid', '0'), 10);
const PORTFILE = get('portfile', '');
const DEBUG = args.includes('--debug');

if (!UPSTREAM) { console.error('[acs-proxy] 缺少 --upstream'); process.exit(1); }

// ---- 父进程监控: 每 3 秒探测一次，父进程死亡(关窗/崩溃/被杀)即自杀 ----
if (PPID > 0) {
  const guard = setInterval(() => {
    try { process.kill(PPID, 0); } catch { if (DEBUG) console.error('[acs-proxy] 父进程已退出，自动关闭'); process.exit(0); }
  }, 3000);
  guard.unref();
}

const maskKey = (s) => String(s).replace(/(Bearer\s+\S{6})\S+/g, '$1***');

// ============================================================================
// 请求转换: Responses API 请求体 → Chat Completions 请求体
// ============================================================================
function reqToChat(req) {
  const messages = [];
  if (req.instructions) messages.push({ role: 'system', content: String(req.instructions) });
  const pushText = (role, content) => {
    if (typeof content === 'string') { messages.push({ role, content }); return; }
    const texts = (Array.isArray(content) ? content : []).map(c => {
      if (typeof c === 'string') return c;
      if (c && (c.type === 'input_text' || c.type === 'output_text' || c.type === 'text' || c.type === 'refusal')) return c.text || c.refusal || '';
      return '';
    }).filter(Boolean);
    if (texts.length) messages.push({ role, content: texts.join('\n') });
  };
  const input = req.input;
  if (typeof input === 'string') {
    pushText('user', input);
  } else if (Array.isArray(input)) {
    for (const item of input) {
      if (!item || typeof item !== 'object') continue;
      if (item.type === 'message') pushText(item.role || 'user', item.content);
      else if (item.type === 'function_call_output') {
        messages.push({ role: 'tool', tool_call_id: item.call_id || 'call_0', content: String(item.output ?? '') });
      } else if (item.type === 'function_call') {
        messages.push({ role: 'assistant', content: null, tool_calls: [{ id: item.call_id || 'call_0', type: 'function', function: { name: item.name, arguments: item.arguments || '{}' } }] });
      } else if (item.role) {
        pushText(item.role, item.content);
      }
    }
  }
  if (messages.length === 0) messages.push({ role: 'user', content: 'ping' });
  const body = { model: req.model || 'default', messages, stream: !!req.stream };
  if (Array.isArray(req.tools) && req.tools.length) {
    body.tools = req.tools.filter(t => t.type === 'function').map(t => ({
      type: 'function',
      function: { name: t.name, description: t.description || '', parameters: t.parameters || { type: 'object', properties: {} } }
    }));
    body.tool_choice = req.tool_choice === 'none' ? 'none' : 'auto';
  }
  if (req.temperature != null) body.temperature = req.temperature;
  if (req.top_p != null) body.top_p = req.top_p;
  if (req.max_output_tokens != null) body.max_tokens = req.max_output_tokens;
  return body;
}

// ============================================================================
// 响应转换: Chat Completions 响应 → Responses API 响应
// ============================================================================
let respSeq = 0;
function chatToResp(chat, respId, streamedText, streamedTools) {
  const ch = (chat.choices && chat.choices[0]) || {};
  const msg = ch.message || {};
  const output = [];
  const text = streamedText != null ? streamedText : (typeof msg.content === 'string' ? msg.content : (msg.content == null ? '' : JSON.stringify(msg.content)));
  if (text) {
    output.push({ type: 'message', id: 'msg_' + respId, role: 'assistant', status: 'completed', content: [{ type: 'output_text', text, annotations: [] }] });
  }
  const toolCalls = streamedTools != null ? streamedTools : (msg.tool_calls || []).map((tc, i) => ({ id: tc.id || 'call_' + i, name: (tc.function && tc.function.name) || '', args: (tc.function && tc.function.arguments) || '{}' }));
  toolCalls.forEach((agg, i) => {
    output.push({ type: 'function_call', id: 'fc_' + respId + '_' + i, call_id: agg.id, name: agg.name, arguments: agg.args || '{}', status: 'completed' });
  });
  const u = chat.usage || {};
  return {
    id: 'resp_' + respId, object: 'response', created_at: Math.floor(Date.now() / 1000),
    status: 'completed', model: chat.model || '', output,
    usage: { input_tokens: (u.prompt_tokens || u.input_tokens || 0), output_tokens: (u.completion_tokens || u.output_tokens || 0), total_tokens: (u.total_tokens || 0) },
    parallel_tool_calls: true, tool_choice: 'auto', temperature: 1, top_p: 1, tools: []
  };
}

function sseWrite(res, type, payload) {
  res.write('event: ' + type + '\ndata: ' + JSON.stringify(payload) + '\n\n');
}

// ============================================================================
// HTTP 服务: 只处理 POST /responses，其余一律 404
// ============================================================================
const server = http.createServer((req, res) => {
  if (!req.url || !req.url.includes('/responses')) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: { message: 'acs-proxy: only /responses is proxied' } }));
    return;
  }
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    let reqObj = {};
    try { reqObj = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); } catch { }
    const auth = req.headers['authorization'] || '';
    const chatBody = reqToChat(reqObj);
    if (DEBUG) {
      console.error('[acs-proxy] --> ' + UPSTREAM + '/chat/completions  model=' + chatBody.model + ' stream=' + chatBody.stream + ' auth=' + maskKey(auth));
    }
    fetch(UPSTREAM + '/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': auth },
      body: JSON.stringify(chatBody)
    }).then(async up => {
      if (DEBUG) console.error('[acs-proxy] <-- upstream ' + up.status);
      // 上游错误（含 429 余额不足等）：原样透传状态码与响应体，让错误可见
      if (!up.ok) {
        const t = await up.text();
        if (DEBUG) console.error('[acs-proxy] <-- ' + up.status + ' ' + maskKey(t.slice(0, 400)));
        res.writeHead(up.status, { 'Content-Type': 'application/json' });
        res.end(t);
        return;
      }
      const rid = (++respSeq).toString(36) + Date.now().toString(36);
      if (!chatBody.stream) {
        const t = await up.text();
        let chat = {}; try { chat = JSON.parse(t); } catch { }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(chatToResp(chat, rid)));
        return;
      }
      // ---- 流式: web stream 逐行读取 chat SSE，翻译为 responses 事件流 ----
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive' });
      sseWrite(res, 'response.created', { type: 'response.created', response: { id: 'resp_' + rid, object: 'response', status: 'in_progress', model: '', output: [] } });
      let buf = '';
      let textOpened = false;
      let streamedText = '';
      let usage = null;
      const toolAgg = new Map();
      const flushLine = (line) => {
        line = line.trim();
        if (!line.startsWith('data:')) return;
        const data = line.slice(5).trim();
        if (!data || data === '[DONE]') return;
        let j; try { j = JSON.parse(data); } catch { return; }
        if (j.usage) usage = j.usage;
        const d = (j.choices && j.choices[0] && j.choices[0].delta) || {};
        if (typeof d.content === 'string' && d.content) {
          if (!textOpened) {
            textOpened = true;
            sseWrite(res, 'response.output_item.added', { type: 'response.output_item.added', output_index: 0, item: { type: 'message', id: 'msg_' + rid, role: 'assistant', status: 'in_progress', content: [] } });
          }
          streamedText += d.content;
          sseWrite(res, 'response.output_text.delta', { type: 'response.output_text.delta', item_id: 'msg_' + rid, delta: d.content });
        }
        for (const tc of d.tool_calls || []) {
          const i = (tc.index != null) ? tc.index : 0;
          const agg = toolAgg.get(i) || { id: tc.id || ('call_' + i), name: '', args: '' };
          if (tc.id) agg.id = tc.id;
          if (tc.function && tc.function.name) agg.name += tc.function.name;
          if (tc.function && tc.function.arguments) agg.args += tc.function.arguments;
          toolAgg.set(i, agg);
        }
      };
      try {
        const reader = up.body.getReader();
        const decoder = new TextDecoder();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          buf += decoder.decode(value, { stream: true });
          let idx;
          while ((idx = buf.indexOf('\n')) >= 0) { flushLine(buf.slice(0, idx)); buf = buf.slice(idx + 1); }
        }
        if (buf.trim()) flushLine(buf);
        let outIndex = 0;
        if (textOpened) {
          sseWrite(res, 'response.output_item.done', { type: 'response.output_item.done', output_index: 0, item: { type: 'message', id: 'msg_' + rid, role: 'assistant', status: 'completed', content: [] } });
          outIndex = 1;
        }
        let i = 0;
        for (const agg of toolAgg.values()) {
          sseWrite(res, 'response.output_item.added', { type: 'response.output_item.added', output_index: outIndex, item: { type: 'function_call', id: 'fc_' + rid + '_' + i, call_id: agg.id, name: agg.name, arguments: '', status: 'in_progress' } });
          sseWrite(res, 'response.output_item.done', { type: 'response.output_item.done', output_index: outIndex, item: { type: 'function_call', id: 'fc_' + rid + '_' + i, call_id: agg.id, name: agg.name, arguments: agg.args || '{}', status: 'completed' } });
          outIndex++; i++;
        }
        const resp = chatToResp({ model: '', usage: usage || {}, choices: [{ message: {} }] }, rid, streamedText, [...toolAgg.values()]);
        sseWrite(res, 'response.completed', { type: 'response.completed', response: resp });
      } catch (e) {
        if (DEBUG) console.error('[acs-proxy] 流式收尾异常: ' + e.message);
      }
      res.end();
    }).catch(err => {
      if (DEBUG) console.error('[acs-proxy] 上游失败: ' + err.message);
      if (res.headersSent) { try { res.end(); } catch { } return; }
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: { message: 'acs-proxy: 上游请求失败 - ' + err.message } }));
    });
  });
});

server.listen(PORT, '127.0.0.1', () => {
  const actual = server.address().port;
  if (PORTFILE) {
    try { fs.mkdirSync(path.dirname(PORTFILE), { recursive: true }); fs.writeFileSync(PORTFILE, String(actual)); } catch (e) { console.error('[acs-proxy] 端口文件写入失败: ' + e.message); }
  }
  if (DEBUG) console.error('[acs-proxy] listening 127.0.0.1:' + actual + ' -> ' + UPSTREAM);
});
