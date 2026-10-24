// Stand-in for the parts of Supabase that cannot run here: GoTrue (login/user) and the Realtime WebSocket.
// /rest/v1 is proxied to a REAL PostgREST over the REAL database, so RPCs and RLS are the real thing.
// Realtime events are decided by the real RLS policy: for every change we run "select 1 from notifications
// where id = $1" as role authenticated with the subscriber's JWT claims — the same check Supabase Realtime applies.
import http from 'node:http';
import { WebSocketServer } from 'ws';
import jwt from 'jsonwebtoken';
import pg from 'pg';

const SECRET = 'super-secret-jwt-token-with-at-least-32-characters-long';
const db = new pg.Pool({ connectionString: 'postgres://postgres:postgres@localhost:5432/kayan_ui' });
const listener = new pg.Client({ connectionString: 'postgres://postgres:postgres@localhost:5432/kayan_ui' });
await listener.connect(); await listener.query('listen ntf');

const sign = (u) => jwt.sign({ sub: u.id, email: u.email, role: 'authenticated', aud: 'authenticated', session_id: u.id }, SECRET, { expiresIn: '1h' });
const session = (u) => ({ access_token: sign(u), token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, refresh_token: 'r-' + u.id, user: userObj(u) });
const userObj = (u) => ({ id: u.id, aud: 'authenticated', role: 'authenticated', email: u.email, app_metadata: {}, user_metadata: {}, created_at: '2026-01-01T00:00:00Z' });
const cors = { 'access-control-allow-origin': 'http://localhost:3100', 'access-control-allow-credentials': 'true', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'access-control-expose-headers': '*' };
let blockWs = false;
const sockets = new Set();
const stats = { joins: 0, events: 0, denied: 0 };

const body = (req) => new Promise((r) => { let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => r(b)); });
const json = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json', ...cors }); res.end(JSON.stringify(obj)); };

const server = http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end(); }
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/__ctl') {
    const a = url.searchParams.get('a');
    if (a === 'drop') { for (const s of sockets) s.terminate(); blockWs = url.searchParams.get('block') === '1'; }
    if (a === 'allow') blockWs = false;
    return json(res, 200, { ok: true, sockets: sockets.size, ...stats });
  }
  if (url.pathname === '/auth/v1/token') {
    const b = JSON.parse((await body(req)) || '{}');
    const grant = url.searchParams.get('grant_type');
    let u;
    if (grant === 'password') u = (await db.query('select id, email from auth.users where email = $1', [b.email])).rows[0];
    else { const id = String(b.refresh_token || '').slice(2); u = (await db.query('select id, email from auth.users where id = $1', [id])).rows[0]; }
    if (!u) return json(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials' });
    return json(res, 200, session(u));
  }
  if (url.pathname === '/auth/v1/user') {
    try { const c = jwt.verify((req.headers.authorization || '').slice(7), SECRET); return json(res, 200, userObj({ id: c.sub, email: c.email })); }
    catch { return json(res, 401, { msg: 'invalid JWT' }); }
  }
  if (url.pathname === '/auth/v1/logout') { res.writeHead(204, cors); return res.end(); }
  if (url.pathname.startsWith('/rest/v1/')) {
    const headers = { ...req.headers, host: 'localhost:3000' }; delete headers.origin;
    const p = http.request({ host: 'localhost', port: 3000, path: url.pathname.slice(8) + url.search, method: req.method, headers }, (r) => {
      res.writeHead(r.statusCode, { ...r.headers, ...cors }); r.pipe(res);
    });
    p.on('error', (e) => json(res, 502, { message: String(e) }));
    return req.pipe(p);
  }
  json(res, 404, { message: 'not mocked: ' + url.pathname });
});

const wss = new WebSocketServer({ noServer: true });
server.on('upgrade', (req, socket, head) => {
  if (!req.url.startsWith('/realtime/v1/websocket') || blockWs) { socket.destroy(); return; }
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
});

wss.on('connection', (ws) => {
  sockets.add(ws);
  const subs = new Map();      // topic -> { token, joinRef, bindings:[{id, filter}] }
  ws.on('close', () => sockets.delete(ws));
  ws.subs = subs;
  ws.on('message', (raw) => {
    let [joinRef, ref, topic, event, payload] = JSON.parse(raw.toString());
    const send = (ev, pl, r = ref) => ws.send(JSON.stringify([joinRef, r, topic, ev, pl]));
    if (event === 'phx_join') {
      stats.joins++;
      const pcs = (payload.config?.postgres_changes ?? []).map((f, i) => ({ id: 1000 + i, ...f }));
      subs.set(topic, { token: payload.access_token, joinRef, bindings: pcs });
      send('phx_reply', { status: 'ok', response: { postgres_changes: pcs } });
    } else if (event === 'access_token') {
      const s = subs.get(topic); if (s) s.token = payload.access_token;
      send('phx_reply', { status: 'ok', response: {} });
    } else if (event === 'heartbeat') {
      ws.send(JSON.stringify([null, ref, 'phoenix', 'phx_reply', { status: 'ok', response: {} }]));
    } else if (event === 'phx_leave') { subs.delete(topic); send('phx_reply', { status: 'ok', response: {} }); }
  });
});

listener.on('notification', async (m) => {
  const { id, op } = JSON.parse(m.payload);
  for (const ws of sockets) for (const [topic, s] of ws.subs) {
    let claims; try { claims = jwt.verify(s.token, SECRET); } catch { continue; }
    for (const b of s.bindings) {
      if (b.table !== 'notifications') continue;
      if (b.event !== '*' && b.event !== op) continue;
      const c = await db.connect();
      try {
        await c.query('begin'); await c.query('set local role authenticated');
        await c.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims)]);
        // the filter the client asked for AND the table's RLS policy, evaluated as the subscriber
        const f = b.filter ? b.filter.match(/^(\w+)=eq\.(.+)$/) : null;
        const q = f ? `select * from notifications where id = $1 and ${f[1]} = $2` : 'select * from notifications where id = $1';
        const r = await c.query(q, f ? [id, f[2]] : [id]);
        await c.query('commit');
        if (r.rowCount === 1) {
          stats.events++;
          ws.send(JSON.stringify([s.joinRef, null, topic, 'postgres_changes', { ids: [b.id], data: { schema: 'public', table: 'notifications', commit_timestamp: new Date().toISOString(), type: op, record: r.rows[0], old_record: {}, columns: [], errors: null } }]));
        } else stats.denied++;
      } catch (e) { console.error('rls check failed', e.message); try { await c.query('rollback'); } catch {} }
      finally { c.release(); }
    }
  }
});

server.listen(54321, () => console.log('mock supabase on 54321'));
