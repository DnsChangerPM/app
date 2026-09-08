// DNS Changer - Cloudflare Worker (admin panel + license API + release API)
//
// Bindings required (see wrangler.toml):
//   LICENSES_KV  -> stores license:<KEY>
//   DEVICES_KV   -> stores device:<KEY>:<DEVICE_ID>
//   CONFIG_KV    -> stores "config"
//
// Secrets:  ADMIN_KEY (optional override of the admin key stored in KV)

const DEFAULT_CONFIG = {
  admin_key: '',          // set on first boot via /api/admin/config
  min_version: '1.0.0',  // app versions below this are forced to update
  killed_versions: [],    // explicit version tags that must update
  github_repo: 'DnsChangerPM/app',
  github_token: '',       // optional GitHub PAT to raise API rate limits
  last_release: null,
  last_release_at: 0,
};

const RELEASE_CACHE_MS = 5 * 60 * 1000;

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, x-admin-key',
    'Access-Control-Max-Age': '86400',
  };
}

function json(data, cors, status = 200, extra = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json;charset=UTF-8', ...(cors || {}), ...extra },
  });
}

function text(data, type, status = 200) {
  return new Response(data, { status, headers: { 'content-type': type } });
}

function normKey(k) {
  return String(k || '').trim().toUpperCase().replace(/[^A-Z0-9]/g, '');
}

function b64(str) {
  try { return btoa(String(str)); } catch (_) { return ''; }
}

async function getConfig(env) {
  const raw = await env.CONFIG_KV.get('config');
  if (!raw) return { ...DEFAULT_CONFIG };
  try { return { ...DEFAULT_CONFIG, ...JSON.parse(raw) }; } catch (_) { return { ...DEFAULT_CONFIG }; }
}

async function setConfig(env, cfg) {
  await env.CONFIG_KV.put('config', JSON.stringify(cfg));
  return cfg;
}

function adminKeyOf(cfg, request, url) {
  return (request.headers.get('x-admin-key') || url.searchParams.get('key') || '').trim();
}

// Constant-time string comparison so the admin key can't be brute-forced by timing.
function safeEqual(a, b) {
  const enc = new TextEncoder();
  const x = enc.encode(String(a));
  const y = enc.encode(String(b));
  if (x.byteLength !== y.byteLength) return false;
  if (crypto.subtle && typeof crypto.subtle.timingSafeEqual === 'function') {
    return crypto.subtle.timingSafeEqual(x, y);
  }
  let diff = 0;
  for (let i = 0; i < x.byteLength; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

// True when no admin key exists anywhere (neither the ADMIN_KEY secret nor KV config).
// In that state the panel is in "first boot" mode and the first key that is set wins.
function adminKeyConfigured(cfg, env) {
  return Boolean((cfg.admin_key && String(cfg.admin_key).trim()) || (env.ADMIN_KEY && String(env.ADMIN_KEY).trim()));
}

function authorized(cfg, request, url, env) {
  const key = adminKeyOf(cfg, request, url);
  if (!key) return false;
  if (cfg.admin_key && safeEqual(key, String(cfg.admin_key).trim())) return true;
  if (env.ADMIN_KEY && safeEqual(key, String(env.ADMIN_KEY).trim())) return true;
  return false;
}

async function getLicense(env, key) {
  const raw = await env.LICENSES_KV.get('license:' + key);
  return raw ? JSON.parse(raw) : null;
}

async function putLicense(env, lic) {
  await env.LICENSES_KV.put('license:' + lic.key, JSON.stringify(lic));
  return lic;
}

async function listDevices(env, key) {
  const list = await env.DEVICES_KV.list({ prefix: 'device:' + key + ':' });
  const out = [];
  for (const k of list.keys) {
    const raw = await env.DEVICES_KV.get(k.name);
    if (raw) {
      try { out.push(JSON.parse(raw)); } catch (_) {}
    }
  }
  out.sort((a, b) => (b.last_seen || 0) - (a.last_seen || 0));
  return out;
}

function isExpired(lic) {
  if (!lic.expires_at) return false;
  return Date.parse(lic.expires_at) < Date.now();
}

function licenseStatus(lic) {
  if (lic.status && lic.status !== 'active') return lic.status;
  if (isExpired(lic)) return 'expired';
  return 'active';
}

function pubLicense(lic) {
  return {
    key: lic.key,
    plan_name: lic.plan_name,
    device_limit: lic.device_limit,
    status: licenseStatus(lic),
    expires_at: lic.expires_at || null,
    dns_servers: lic.dns_servers || [],
    note: lic.note || '',
    created_at: lic.created_at || 0,
  };
}

function genLicenseKey() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let key = '';
  const rnd = crypto.getRandomValues(new Uint8Array(16));
  for (let i = 0; i < 16; i++) {
    key += chars[rnd[i] % chars.length];
    if (i % 4 === 3 && i < 15) key += '-';
  }
  return key;
}

// ---------------------------------------------------------------------------
// Client: license activate / check
// ---------------------------------------------------------------------------
async function handleClientLicense(request, env, cors) {
  let body = {};
  try { body = await request.json(); } catch (_) {}
  const action = body.action || 'activate';
  const key = normKey(body.license_key);
  if (!key) return json({ ok: false, status: 'invalid', message: 'License key is required.' }, cors, 400);

  const lic = await getLicense(env, key);
  if (!lic) return json({ ok: false, status: 'not_found', message: 'Invalid license key.' }, cors, 404);

  const status = licenseStatus(lic);
  const devices = await listDevices(env, key);
  const deviceCount = devices.length;
  const deviceLimit = lic.device_limit || 0;

  const data = {
    valid: status === 'active',
    status,
    license_key: key,
    plan_name: lic.plan_name,
    device_limit: deviceLimit,
    device_count: deviceCount,
    expires_at: lic.expires_at || null,
    dns_servers_b64: (lic.dns_servers || []).map(b64),
  };

  if (status !== 'active') {
    const msg = status === 'expired' ? 'License has expired.' : status === 'revoked' ? 'License was revoked.' : 'License is banned.';
    return json({ ok: false, status, message: msg, data }, cors, 200);
  }

  if (action === 'check') {
    return json({ ok: true, status: 'active', message: 'ok', data }, cors, 200);
  }

  // activate: register/refresh device
  const deviceId = String(body.device_id || '').trim();
  if (!deviceId) {
    return json({ ok: false, status: 'invalid', message: 'device_id is required.', data }, cors, 400);
  }
  const deviceKey = 'device:' + key + ':' + deviceId;
  const existing = await env.DEVICES_KV.get(deviceKey);
  if (!existing && deviceLimit > 0 && deviceCount >= deviceLimit) {
    data.device_count = deviceCount;
    return json({
      ok: false,
      status: 'limit_reached',
      message: `Device limit reached (${deviceCount}/${deviceLimit}). Remove a device from the admin panel.`,
      data,
    }, cors, 200);
  }
  const device = {
    id: deviceId,
    name: String(body.device_name || 'Android device'),
    ip: (request.headers.get('cf-connecting-ip') || ''),
    first_seen: existing ? (JSON.parse(existing).first_seen || Date.now()) : Date.now(),
    last_seen: Date.now(),
  };
  await env.DEVICES_KV.put(deviceKey, JSON.stringify(device));
  data.device_count = existing ? deviceCount : deviceCount + 1;

  return json({
    ok: true,
    status: 'active',
    message: 'License activated.',
    data,
  }, cors, 200);
}

// ---------------------------------------------------------------------------
// Client: latest release / forced update info
// ---------------------------------------------------------------------------
async function handleClientRelease(request, env, url, cors) {
  const version = url.searchParams.get('version') || '0.0.0';
  const cfg = await getConfig(env);
  const release = await getLatestRelease(env, cfg);
  const data = {
    latest: release,
    killed_versions: cfg.killed_versions || [],
    min_version: cfg.min_version || '0.0.0',
    current_version: version,
  };
  return json({ ok: true, data }, cors, 200, { 'cache-control': 'public, max-age=120' });
}

async function getLatestRelease(env, cfg) {
  const now = Date.now();
  if (cfg.last_release && now - (cfg.last_release_at || 0) < RELEASE_CACHE_MS) {
    return cfg.last_release;
  }
  try {
    const headers = {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'dns-changer-worker',
    };
    if (cfg.github_token) headers['Authorization'] = 'token ' + cfg.github_token;
    const res = await fetch(`https://api.github.com/repos/${cfg.github_repo}/releases/latest`, { headers });
    if (res.status === 200) {
      const rel = await res.json();
      const slim = {
        tag_name: rel.tag_name,
        name: rel.name || rel.tag_name,
        body: rel.body || '',
        published_at: rel.published_at,
        assets: (rel.assets || []).map((a) => ({
          name: a.name,
          browser_download_url: a.browser_download_url,
          size: a.size,
          digest: a.digest || null,
        })),
      };
      cfg.last_release = slim;
      cfg.last_release_at = now;
      await setConfig(env, cfg);
      return slim;
    }
  } catch (_) {}
  return cfg.last_release || null;
}

// ---------------------------------------------------------------------------
// Admin API
// ---------------------------------------------------------------------------
async function handleAdmin(request, env, url, cors, path) {
  const cfg = await getConfig(env);
  const configured = adminKeyConfigured(cfg, env);

  // /api/admin/status — public, tells the panel whether an admin key exists yet.
  // Never leaks the key itself; only a boolean.
  if (path === '/api/admin/status' && request.method === 'GET') {
    return json({ ok: true, data: { configured } }, cors);
  }

  // First boot: no admin key anywhere → allow setting it once via POST /api/admin/config.
  // Only admin_key is accepted in this call; everything else still requires auth.
  if (!configured) {
    if (path === '/api/admin/config' && request.method === 'POST') {
      const body = await request.json().catch(() => ({}));
      const newKey = typeof body.admin_key === 'string' ? body.admin_key.trim() : '';
      if (newKey.length < 8) {
        return json({ ok: false, message: 'Admin key must be at least 8 characters.' }, cors, 400);
      }
      // Re-read config right before writing to shrink the race window on first boot.
      const fresh = await getConfig(env);
      if (adminKeyConfigured(fresh, env)) {
        return json({ ok: false, message: 'Admin key was already set. Log in with it.' }, cors, 409);
      }
      fresh.admin_key = newKey;
      await setConfig(env, fresh);
      return json({ ok: true, message: 'Admin key set. You are now logged in.' }, cors);
    }
    return json({
      ok: false,
      code: 'not_configured',
      message: 'No admin key is configured yet. Open /admin to set one, or run: wrangler secret put ADMIN_KEY',
    }, cors, 401);
  }

  if (!authorized(cfg, request, url, env)) {
    return json({ ok: false, code: 'unauthorized', message: 'Unauthorized: missing or invalid admin key.' }, cors, 401);
  }

  // /api/admin/config
  if (path === '/api/admin/config') {
    if (request.method === 'GET') {
      const masked = {
        ...cfg,
        github_token: cfg.github_token ? '***set***' : '',
        // Never echo the real key back; the panel only needs to know whether one exists.
        admin_key: adminKeyConfigured(cfg, env) ? '***set***' : '',
      };
      return json({ ok: true, data: masked }, cors);
    }
    if (request.method === 'POST') {
      const body = await request.json().catch(() => ({}));
      if (typeof body.admin_key === 'string' && body.admin_key.trim()) {
        if (body.admin_key.trim().length < 8) {
          return json({ ok: false, message: 'Admin key must be at least 8 characters.' }, cors, 400);
        }
        cfg.admin_key = body.admin_key.trim();
      }
      if (typeof body.min_version === 'string') cfg.min_version = body.min_version.trim();
      if (typeof body.github_repo === 'string' && body.github_repo.trim()) cfg.github_repo = body.github_repo.trim();
      if (typeof body.github_token === 'string') cfg.github_token = body.github_token.trim();
      if (Array.isArray(body.killed_versions)) cfg.killed_versions = body.killed_versions.map(String);
      await setConfig(env, cfg);
      return json({ ok: true, message: 'Config saved.' }, cors);
    }
  }

  // /api/admin/stats
  if (path === '/api/admin/stats') {
    const licList = await env.LICENSES_KV.list({ prefix: 'license:' });
    const devList = await env.DEVICES_KV.list({ prefix: 'device:' });
    const now = Date.now();
    let active = 0;
    const licenses = [];
    for (const k of licList.keys) {
      const raw = await env.LICENSES_KV.get(k.name);
      if (!raw) continue;
      try {
        const lic = JSON.parse(raw);
        if (licenseStatus(lic) === 'active') active++;
        licenses.push(pubLicense(lic));
      } catch (_) {}
    }
    return json({ ok: true, data: { licenses: licenses.length, active, devices: devList.keys.length } }, cors);
  }

  // /api/admin/licenses
  if (path === '/api/admin/licenses') {
    if (request.method === 'GET') {
      const list = await env.LICENSES_KV.list({ prefix: 'license:' });
      const out = [];
      for (const k of list.keys) {
        const raw = await env.LICENSES_KV.get(k.name);
        if (!raw) continue;
        try {
          const lic = JSON.parse(raw);
          const devices = await listDevices(env, lic.key);
          out.push({ ...pubLicense(lic), device_count: devices.length });
        } catch (_) {}
      }
      out.sort((a, b) => (b.created_at || 0) - (a.created_at || 0));
      return json({ ok: true, data: out }, cors);
    }
    if (request.method === 'POST') {
      const body = await request.json().catch(() => ({}));
      const action = body.action;
      if (action === 'create') {
        const plan_name = String(body.plan_name || 'Subscription');
        const device_limit = Math.max(0, parseInt(body.device_limit || '1', 10) || 1);
        let dns_servers = body.dns_servers;
        if (typeof dns_servers === 'string') {
          dns_servers = dns_servers.split(/[,\n\s]+/).map((s) => s.trim()).filter(Boolean);
        }
        dns_servers = Array.isArray(dns_servers) ? dns_servers.filter(Boolean) : [];
        const days = parseInt(body.days || '0', 10);
        const expires_at = days > 0 ? new Date(Date.now() + days * 86400000).toISOString() : null;
        const lic = {
          key: genLicenseKey(),
          plan_name,
          device_limit,
          dns_servers,
          status: 'active',
          expires_at,
          note: String(body.note || ''),
          created_at: Date.now(),
        };
        await putLicense(env, lic);
        return json({ ok: true, message: 'License created.', data: pubLicense(lic) }, cors);
      }
      if (action === 'update') {
        const key = normKey(body.key);
        const lic = await getLicense(env, key);
        if (!lic) return json({ ok: false, message: 'License not found.' }, cors, 404);
        if (typeof body.plan_name === 'string') lic.plan_name = body.plan_name;
        if (typeof body.device_limit !== 'undefined') lic.device_limit = Math.max(0, parseInt(body.device_limit, 10) || 0);
        if (typeof body.status === 'string' && ['active', 'revoked', 'banned'].includes(body.status)) lic.status = body.status;
        if (typeof body.note === 'string') lic.note = body.note;
        if (typeof body.days === 'number' && body.days > 0) {
          lic.expires_at = new Date(Date.now() + body.days * 86400000).toISOString();
        }
        if (typeof body.expires_at === 'string' && body.expires_at) lic.expires_at = body.expires_at;
        if (typeof body.dns_servers === 'string') {
          lic.dns_servers = body.dns_servers.split(/[,\n\s]+/).map((s) => s.trim()).filter(Boolean);
        } else if (Array.isArray(body.dns_servers)) {
          lic.dns_servers = body.dns_servers.filter(Boolean);
        }
        await putLicense(env, lic);
        return json({ ok: true, message: 'License updated.', data: pubLicense(lic) }, cors);
      }
      if (action === 'delete') {
        const key = normKey(body.key);
        await env.LICENSES_KV.delete('license:' + key);
        const devs = await env.DEVICES_KV.list({ prefix: 'device:' + key + ':' });
        for (const k of devs.keys) await env.DEVICES_KV.delete(k.name);
        return json({ ok: true, message: 'License deleted.' }, cors);
      }
      if (action === 'revoke' || action === 'ban') {
        const key = normKey(body.key);
        const lic = await getLicense(env, key);
        if (!lic) return json({ ok: false, message: 'License not found.' }, cors, 404);
        lic.status = action === 'revoke' ? 'revoked' : 'banned';
        await putLicense(env, lic);
        return json({ ok: true, message: `License ${action}ed.` }, cors);
      }
      if (action === 'reactivate') {
        const key = normKey(body.key);
        const lic = await getLicense(env, key);
        if (!lic) return json({ ok: false, message: 'License not found.' }, cors, 404);
        lic.status = 'active';
        await putLicense(env, lic);
        return json({ ok: true, message: 'License reactivated.' }, cors);
      }
      return json({ ok: false, message: 'Unknown action.' }, cors, 400);
    }
  }

  // /api/admin/license/:key ...
  const licMatch = path.match(/^\/api\/admin\/license\/([A-Za-z0-9-]+)(\/devices(?:\/([^/]+))?)?$/);
  if (licMatch) {
    const key = normKey(licMatch[1]);
    const lic = await getLicense(env, key);
    if (!lic) return json({ ok: false, message: 'License not found.' }, cors, 404);

    if (!licMatch[2]) {
      // GET license detail
      const devices = await listDevices(env, key);
      return json({ ok: true, data: { ...pubLicense(lic), devices } }, cors);
    }

    // /devices and /devices/:id
    if (!licMatch[3]) {
      if (request.method === 'POST') {
        const body = await request.json().catch(() => ({}));
        const deviceId = String(body.device_id || '').trim();
        if (!deviceId) return json({ ok: false, message: 'device_id required.' }, cors, 400);
        const deviceKey = 'device:' + key + ':' + deviceId;
        const existing = await env.DEVICES_KV.get(deviceKey);
        const device = {
          id: deviceId,
          name: String(body.name || 'Manual device'),
          ip: String(body.ip || ''),
          first_seen: existing ? (JSON.parse(existing).first_seen || Date.now()) : Date.now(),
          last_seen: Date.now(),
        };
        await env.DEVICES_KV.put(deviceKey, JSON.stringify(device));
        return json({ ok: true, message: 'Device added.' }, cors);
      }
      return json({ ok: false, message: 'Bad request.' }, cors, 400);
    }

    const deviceId = decodeURIComponent(licMatch[3]);
    if (request.method === 'DELETE') {
      await env.DEVICES_KV.delete('device:' + key + ':' + deviceId);
      return json({ ok: true, message: 'Device removed.' }, cors);
    }
    return json({ ok: false, message: 'Bad request.' }, cors, 400);
  }

  // /api/admin/refresh_release
  if (path === '/api/admin/refresh_release' && request.method === 'POST') {
    cfg.last_release_at = 0;
    await setConfig(env, cfg);
    const release = await getLatestRelease(env, cfg);
    return json({ ok: true, message: 'Release refreshed.', data: release }, cors);
  }

  return json({ ok: false, message: 'Not found.' }, cors, 404);
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    const cors = corsHeaders();
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    try {
      if (path === '/' || path === '/admin') {
        return text(adminHtml(), 'text/html;charset=UTF-8');
      }
      if (path === '/api/public/health') {
        return json({ ok: true, service: 'dns-changer', time: Date.now() }, cors);
      }
      if (path === '/api/client/license' && request.method === 'POST') {
        return handleClientLicense(request, env, cors);
      }
      if (path === '/api/client/release' && request.method === 'GET') {
        return handleClientRelease(request, env, url, cors);
      }
      if (path.startsWith('/api/admin/')) {
        return handleAdmin(request, env, url, cors, path);
      }
      return json({ ok: false, message: 'Not found.' }, cors, 404);
    } catch (e) {
      return json({ ok: false, message: (e && e.message) || String(e) }, cors, 500);
    }
  },
};

function adminHtml() {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>DNS Changer Admin</title>
<style>
  :root { --bg:#0b1220; --card:#111b2e; --line:#1e2b45; --accent:#3aa6ff; --green:#00d1b2; --red:#ff5c5c; --yellow:#ffc107; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:system-ui,Segoe UI,Roboto,sans-serif; background:var(--bg); color:#e6edf6; }
  header { padding:16px 20px; display:flex; align-items:center; justify-content:space-between; border-bottom:1px solid var(--line); }
  header h1 { font-size:18px; margin:0; }
  .wrap { max-width:980px; margin:0 auto; padding:20px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:16px; margin-bottom:16px; }
  .row { display:flex; gap:10px; flex-wrap:wrap; align-items:center; }
  input, select, textarea { background:#0b1424; border:1px solid var(--line); color:#e6edf6; border-radius:8px; padding:9px 11px; font-size:14px; min-width:0; }
  input:focus, textarea:focus { outline:1px solid var(--accent); }
  button { background:var(--accent); color:#06121f; border:0; border-radius:8px; padding:9px 14px; font-weight:600; cursor:pointer; font-size:14px; }
  button.ghost { background:transparent; color:var(--accent); border:1px solid var(--accent); }
  button.danger { background:transparent; color:var(--red); border:1px solid var(--red); }
  button.green { background:var(--green); }
  table { width:100%; border-collapse:collapse; font-size:13px; }
  th, td { text-align:left; padding:9px 8px; border-bottom:1px solid var(--line); vertical-align:top; }
  th { color:#8fa3c0; font-weight:600; font-size:12px; text-transform:uppercase; }
  .badge { padding:2px 8px; border-radius:20px; font-size:11px; font-weight:700; }
  .badge.active { background:rgba(0,209,178,.15); color:var(--green); }
  .badge.expired { background:rgba(255,193,7,.15); color:var(--yellow); }
  .badge.revoked, .badge.banned { background:rgba(255,92,92,.15); color:var(--red); }
  code { background:#0b1424; padding:2px 6px; border-radius:6px; font-size:12px; }
  .muted { color:#8fa3c0; font-size:12px; }
  .hidden { display:none; }
  a { color:var(--accent); }
  .tabs { display:flex; gap:8px; margin-bottom:16px; }
  .tabs button { background:transparent; color:#8fa3c0; border:1px solid var(--line); }
  .tabs button.on { background:var(--accent); color:#06121f; border-color:var(--accent); }
  .grid2 { display:grid; grid-template-columns:1fr 1fr; gap:10px; }
  @media (max-width:640px){ .grid2{grid-template-columns:1fr;} }
  .modal { position:fixed; inset:0; background:rgba(0,0,0,.6); display:none; align-items:center; justify-content:center; padding:20px; z-index:50; }
  .modal.open { display:flex; }
  .modal .box { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:20px; width:100%; max-width:520px; max-height:86vh; overflow:auto; }
  .toast { position:fixed; bottom:20px; left:50%; transform:translateX(-50%); background:var(--green); color:#06121f; padding:10px 16px; border-radius:10px; font-weight:600; z-index:99; display:none; }
</style>
</head>
<body>
<header>
  <h1>🛡️ DNS Changer Admin</h1>
  <div class="row">
    <button class="ghost" id="logoutBtn">Logout</button>
  </div>
</header>
<div class="wrap">
  <div id="loginView">
    <div class="card" style="max-width:420px;margin:60px auto;">
      <h2>Admin login</h2>
      <p class="muted">Enter the admin key (the <code>ADMIN_KEY</code> secret, or the key you set on first boot).</p>
      <input id="adminKey" type="password" placeholder="Admin key" style="width:100%;margin-bottom:10px;" onkeydown="if(event.key==='Enter')login()" />
      <button id="loginBtn" style="width:100%" onclick="login()">Login</button>
      <p id="loginError" class="muted hidden" style="color:var(--red);margin-top:10px;"></p>
    </div>
  </div>

  <div id="setupView" class="hidden">
    <div class="card" style="max-width:420px;margin:60px auto;">
      <h2>🚀 First boot — set admin key</h2>
      <p class="muted">No admin key is configured yet (no <code>ADMIN_KEY</code> secret and nothing saved in KV). Choose a strong key now — it is required to open this panel from now on.</p>
      <input id="setupKey" type="password" placeholder="New admin key (min 8 chars)" style="width:100%;margin-bottom:10px;" />
      <input id="setupKey2" type="password" placeholder="Repeat admin key" style="width:100%;margin-bottom:10px;" onkeydown="if(event.key==='Enter')setupKey()" />
      <button id="setupBtn" style="width:100%" onclick="setupKey()">Set admin key &amp; login</button>
      <p id="setupError" class="muted hidden" style="color:var(--red);margin-top:10px;"></p>
    </div>
  </div>

  <div id="appView" class="hidden">
    <div class="tabs">
      <button id="tabLicenses" class="on" onclick="showTab('licenses')">Licenses</button>
      <button id="tabConfig" onclick="showTab('config')">Settings</button>
      <button id="tabHelp" onclick="showTab('help')">Help</button>
    </div>

    <div id="tab-licenses">
      <div class="card">
        <h3>➕ Create license</h3>
        <div class="grid2">
          <input id="cPlan" placeholder="Plan name (e.g. Pro 1 month)" />
          <input id="cLimit" type="number" min="0" placeholder="Device limit (0 = unlimited)" value="1" />
          <input id="cDays" type="number" min="0" placeholder="Duration in days (0 = lifetime)" value="30" />
          <input id="cDns" placeholder="DNS servers (1.1.1.1, 1.0.0.1)" />
        </div>
        <div class="row" style="margin-top:10px;">
          <button class="green" onclick="createLicense()">Generate license key</button>
        </div>
      </div>

      <div class="card">
        <h3>📋 Licenses</h3>
        <table>
          <thead><tr><th>Key</th><th>Plan</th><th>Devices</th><th>Status</th><th>Expires</th><th>DNS</th><th>Actions</th></tr></thead>
          <tbody id="licTable"></tbody>
        </table>
      </div>
    </div>

    <div id="tab-config" class="hidden">
      <div class="card">
        <h3>🔐 Security</h3>
        <label class="muted">Admin key (used to open this panel)</label>
        <input id="cfgAdminKey" placeholder="Change admin key" style="width:100%;margin-bottom:10px;" />
        <label class="muted">GitHub token (optional, raises API limits for release checks)</label>
        <input id="cfgToken" type="password" placeholder="ghp_..." style="width:100%;margin-bottom:10px;" />
      </div>
      <div class="card">
        <h3>📦 Forced updates</h3>
        <label class="muted">Minimum required version (apps below this are forced to update)</label>
        <input id="cfgMinVersion" placeholder="1.0.0" style="width:100%;margin-bottom:10px;" />
        <label class="muted">Killed versions (comma separated) — apps on these versions are disabled</label>
        <input id="cfgKilled" placeholder="1.0.0, 1.0.1" style="width:100%;margin-bottom:10px;" />
        <div class="row">
          <button onclick="saveConfig()">Save settings</button>
          <button class="ghost" onclick="refreshRelease()">Refresh release cache</button>
        </div>
      </div>
      <div class="card">
        <h3>📥 Latest release</h3>
        <div id="releaseBox" class="muted">Loading…</div>
      </div>
    </div>

    <div id="tab-help" class="hidden">
      <div class="card">
        <h3>How it works</h3>
        <ol style="line-height:1.8">
          <li>Deploy this Worker to Cloudflare (free plan) with the three KV namespaces.</li>
          <li>Set the admin key: <code>wrangler secret put ADMIN_KEY</code> (or, on first boot, the panel asks you to create one). Then open this page with <code>?key=YOUR_ADMIN_KEY</code> or paste the key on login.</li>
          <li>Create a license: set a plan, device limit, duration and the private DNS servers (IPs).</li>
          <li>Share the generated key with your users. They enter it in the app → the DNS is unlocked.</li>
          <li>The app never shows the real subscription DNS — only an "active" switch.</li>
          <li>When you publish a new release, set the new <b>minimum version</b> (or kill the old one). Users on older builds get a forced-update screen with a direct APK download.</li>
        </ol>
        <p class="muted">Client endpoint: <code>POST /api/client/license</code> • Release endpoint: <code>GET /api/client/release</code></p>
      </div>
    </div>
  </div>
</div>

<div class="modal" id="devicesModal">
  <div class="box">
    <h3 id="devicesTitle">Devices</h3>
    <table>
      <thead><tr><th>Device</th><th>ID</th><th>Last seen</th><th>IP</th><th></th></tr></thead>
      <tbody id="devicesTable"></tbody>
    </table>
    <div class="row" style="margin-top:12px;">
      <button class="ghost" onclick="closeModal()">Close</button>
    </div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
let KEY = localStorage.getItem('admin_key') || '';
let currentLicenseKey = '';

// Support opening the panel as /admin?key=YOUR_ADMIN_KEY (then scrub it from the URL/history).
(function pickKeyFromUrl() {
  try {
    const u = new URL(location.href);
    const k = (u.searchParams.get('key') || '').trim();
    if (k) {
      KEY = k;
      localStorage.setItem('admin_key', KEY);
      u.searchParams.delete('key');
      history.replaceState(null, '', u.pathname + (u.search || '') + u.hash);
    }
  } catch (_) {}
})();

async function api(path, opts = {}) {
  const res = await fetch('/api/admin' + path, {
    ...opts,
    headers: { 'Content-Type': 'application/json', 'x-admin-key': KEY, ...(opts.headers || {}) },
  });
  let data = {};
  try { data = await res.json(); } catch (_) {}
  if (res.status === 401) {
    logout(data.code === 'not_configured'
      ? 'No admin key is configured on the server yet.'
      : 'Unauthorized: wrong admin key.');
    const err = new Error(data.message || 'Unauthorized');
    err.code = data.code || 'unauthorized';
    throw err;
  }
  if (!data.ok && data.message) throw new Error(data.message);
  return data;
}

function show(id, on) { document.getElementById(id).classList.toggle('hidden', !on); }
function setError(id, msg) {
  const el = document.getElementById(id);
  el.textContent = msg || '';
  el.classList.toggle('hidden', !msg);
}

async function serverConfigured() {
  try {
    const res = await fetch('/api/admin/status', { cache: 'no-store' });
    const data = await res.json();
    return data && data.ok ? Boolean(data.data.configured) : true;
  } catch (_) { return true; }
}

async function setupKey() {
  const k1 = document.getElementById('setupKey').value.trim();
  const k2 = document.getElementById('setupKey2').value.trim();
  setError('setupError', '');
  if (k1.length < 8) return setError('setupError', 'Admin key must be at least 8 characters.');
  if (k1 !== k2) return setError('setupError', 'Keys do not match.');
  const btn = document.getElementById('setupBtn');
  btn.disabled = true;
  try {
    const res = await fetch('/api/admin/config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ admin_key: k1 }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || !data.ok) throw new Error(data.message || ('HTTP ' + res.status));
    KEY = k1;
    localStorage.setItem('admin_key', KEY);
    toast('Admin key set');
    await boot();
  } catch (e) {
    setError('setupError', e.message);
  } finally {
    btn.disabled = false;
  }
}

function toast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg; t.style.display = 'block';
  setTimeout(() => t.style.display = 'none', 2500);
}

async function login() {
  const key = document.getElementById('adminKey').value.trim();
  setError('loginError', '');
  if (!key) return setError('loginError', 'Enter the admin key.');
  const btn = document.getElementById('loginBtn');
  btn.disabled = true;
  try {
    // Verify the key against the server before entering the panel.
    const res = await fetch('/api/admin/config', { headers: { 'x-admin-key': key }, cache: 'no-store' });
    const data = await res.json().catch(() => ({}));
    if (res.status === 401) {
      throw new Error(data.code === 'not_configured'
        ? 'No admin key is configured on the server yet. Reload this page to set one.'
        : 'Wrong admin key.');
    }
    if (!res.ok || !data.ok) throw new Error(data.message || ('Server error (HTTP ' + res.status + ')'));
    KEY = key;
    localStorage.setItem('admin_key', KEY);
    await boot();
  } catch (e) {
    setError('loginError', e.message);
  } finally {
    btn.disabled = false;
  }
}

function logout(reason) {
  KEY = ''; localStorage.removeItem('admin_key');
  show('appView', false);
  show('setupView', false);
  show('loginView', true);
  setError('loginError', reason || '');
}

function showTab(name) {
  ['licenses','config','help'].forEach(t => {
    document.getElementById('tab-' + t).classList.toggle('hidden', t !== name);
    document.getElementById('tab' + t[0].toUpperCase() + t.slice(1)).classList.toggle('on', t === name);
  });
  if (name === 'licenses') loadLicenses();
  if (name === 'config') loadConfig();
}

async function boot() {
  show('appView', false);
  const configured = await serverConfigured();
  if (!configured) {
    // First boot: no ADMIN_KEY secret and nothing in KV → show the setup form.
    show('loginView', false);
    show('setupView', true);
    return;
  }
  show('setupView', false);
  if (!KEY) { show('loginView', true); return; }
  show('loginView', false);
  show('appView', true);
  try { await loadLicenses(); await loadConfig(); } catch (e) { if (e.code !== 'unauthorized' && e.code !== 'not_configured') toast(e.message); }
}

function fmtDate(ts) {
  if (!ts) return '—';
  const d = new Date(ts);
  return d.toISOString().slice(0, 16).replace('T', ' ');
}

async function loadLicenses() {
  const data = await api('/licenses');
  const rows = data.data.map(l => {
    const statusClass = l.status;
    return \`<tr>
      <td><code>\${l.key}</code></td>
      <td>\${l.plan_name}</td>
      <td>\${l.device_count}/\${l.device_limit || '∞'}</td>
      <td><span class="badge \${statusClass}">\${l.status}</span></td>
      <td>\${l.expires_at ? fmtDate(l.expires_at) : 'Lifetime'}</td>
      <td class="muted">\${(l.dns_servers || []).join(', ') || '—'}</td>
      <td>
        <button class="ghost" onclick="showDevices('\${l.key}')">Devices</button>
        <button class="ghost" onclick="copyKey('\${l.key}')">Copy</button>
        <button class="danger" onclick="deleteLicense('\${l.key}')">Delete</button>
      </td>
    </tr>\`;
  }).join('');
  document.getElementById('licTable').innerHTML = rows || '<tr><td colspan="7" class="muted">No licenses yet.</td></tr>';
}

async function createLicense() {
  const body = {
    action: 'create',
    plan_name: document.getElementById('cPlan').value || 'Subscription',
    device_limit: parseInt(document.getElementById('cLimit').value || '1', 10),
    days: parseInt(document.getElementById('cDays').value || '0', 10),
    dns_servers: document.getElementById('cDns').value,
  };
  const data = await api('/licenses', { method: 'POST', body: JSON.stringify(body) });
  toast('License created: ' + data.data.key);
  await loadLicenses();
}

async function deleteLicense(key) {
  if (!confirm('Delete license ' + key + ' and all its devices?')) return;
  await api('/licenses', { method: 'POST', body: JSON.stringify({ action: 'delete', key }) });
  toast('License deleted');
  await loadLicenses();
}

async function showDevices(key) {
  currentLicenseKey = key;
  const data = await api('/license/' + key);
  document.getElementById('devicesTitle').textContent = 'Devices of ' + key + ' (' + data.data.devices.length + '/' + (data.data.device_limit || '∞') + ')';
  document.getElementById('devicesTable').innerHTML = data.data.devices.map(d => \`<tr>
    <td>\${d.name}</td>
    <td><code>\${d.id}</code></td>
    <td>\${fmtDate(d.last_seen)}</td>
    <td class="muted">\${d.ip || '—'}</td>
    <td><button class="danger" onclick="removeDevice('\${d.id}')">Remove</button></td>
  </tr>\`).join('') || '<tr><td colspan="5" class="muted">No devices.</td></tr>';
  document.getElementById('devicesModal').classList.add('open');
}

function closeModal() { document.getElementById('devicesModal').classList.remove('open'); }

async function removeDevice(id) {
  if (!confirm('Remove device ' + id + '?')) return;
  await api('/license/' + currentLicenseKey + '/devices/' + encodeURIComponent(id), { method: 'DELETE' });
  toast('Device removed');
  await showDevices(currentLicenseKey);
}

function copyKey(key) {
  navigator.clipboard.writeText(key).then(() => toast('Key copied'));
}

async function loadConfig() {
  const data = await api('/config');
  const c = data.data;
  document.getElementById('cfgMinVersion').value = c.min_version || '';
  document.getElementById('cfgKilled').value = (c.killed_versions || []).join(', ');
  document.getElementById('cfgToken').placeholder = c.github_token ? '*** set ***' : 'ghp_...';
  document.getElementById('cfgAdminKey').placeholder = c.admin_key ? '*** set ***' : 'Set admin key';
  document.getElementById('cfgAdminKey').value = '';
  document.getElementById('cfgToken').value = '';
  const rel = c.last_release;
  document.getElementById('releaseBox').innerHTML = rel
    ? \`Latest: <b>\${rel.tag_name}</b> — APK: \${rel.assets && rel.assets.length ? '<a href="' + rel.assets[0].browser_download_url + '">' + rel.assets[0].name + '</a>' : 'none'}\`
    : 'No release found yet.';
}

async function saveConfig() {
  const body = {
    min_version: document.getElementById('cfgMinVersion').value.trim(),
    killed_versions: document.getElementById('cfgKilled').value.split(',').map(s => s.trim()).filter(Boolean),
  };
  const ak = document.getElementById('cfgAdminKey').value.trim();
  if (ak) body.admin_key = ak;
  const tk = document.getElementById('cfgToken').value.trim();
  if (tk) body.github_token = tk;
  await api('/config', { method: 'POST', body: JSON.stringify(body) });
  toast('Settings saved');
}

async function refreshRelease() {
  await api('/refresh_release', { method: 'POST' });
  await loadConfig();
  toast('Release refreshed');
}

document.getElementById('logoutBtn').addEventListener('click', logout);
boot();
</script>
</body>
</html>`;
}
