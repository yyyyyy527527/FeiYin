'use strict';

/**
 * 飞音（FeiYin）账号与数据同步服务
 *
 * 部署在用户自己的 NAS 上，零第三方依赖（只用 Node 内置模块）。
 *
 * 接口：
 *   GET  /v1/health              健康检查
 *   POST /v1/auth/login          用华为账号的 idToken 换取访问令牌
 *   POST /v1/auth/resume         用「恢复码」换取访问令牌（换机兜底，不需要华为账号）
 *   GET  /v1/sync                拉取该账号的云端数据
 *   POST /v1/sync                上传本地数据（服务端按规则合并后返回全量）
 *   POST /v1/auth/logout         注销令牌
 *
 * 数据：data/store.json 单文件，原子写入（临时文件 + rename）。
 * 隐私：服务端从不保存华为 idToken，只存 openid（华为侧唯一标识）与令牌哈希。
 */

const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const PORT = Number(process.env.PORT || 8787);
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const STORE_FILE = path.join(DATA_DIR, 'store.json');
/** 令牌有效期：90 天 */
const TOKEN_TTL_MS = 90 * 24 * 3600 * 1000;
/** 单次请求体上限，防止误传大文件把 NAS 撑爆 */
const MAX_BODY = 1024 * 1024;
/** 是否允许仅凭 openid 登录（不校验华为令牌）。默认关闭，仅调试用 */
const ALLOW_INSECURE_OPENID = process.env.ALLOW_INSECURE_OPENID === '1';
/**
 * 期望的 AGC Client ID（也就是 idToken 里的 aud）。
 * 设了它，就只有「明确发给本应用的」华为令牌能换到数据——
 * 否则别人拿自己应用的 idToken 来，也能在我们这儿换出一个合法账号。
 * 不设则跳过这项校验（方便先跑通，接通 AGC 后务必补上）。
 */
const EXPECTED_CLIENT_ID = process.env.EXPECTED_CLIENT_ID || '';
/** 日志文件。开机自启时没有终端，排查问题全靠它 */
const LOG_FILE = process.env.LOG_FILE || path.join(__dirname, 'logs', 'server.log');

/**
 * 把 console 输出同时写一份到 logs/server.log。
 * 超过 5MB 轮转成 server.log.1（保留一份就够，服务本身没什么日志量）。
 */
function setupFileLog() {
  try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
    try {
      if (fs.statSync(LOG_FILE).size > 5 * 1024 * 1024) {
        try { fs.unlinkSync(LOG_FILE + '.1'); } catch (e) {}
        fs.renameSync(LOG_FILE, LOG_FILE + '.1');
      }
    } catch (e) {
      // 文件还不存在，正常
    }
    const stream = fs.createWriteStream(LOG_FILE, { flags: 'a' });
    stream.on('error', () => {});
    const wrap = (orig) => function () {
      const args = Array.prototype.slice.call(arguments);
      orig.apply(console, args);
      try {
        const line = args
          .map((a) => {
            if (typeof a === 'string') return a;
            if (a instanceof Error) return a.stack || a.message;
            try { return JSON.stringify(a); } catch (e) { return String(a); }
          })
          .join(' ');
        stream.write(new Date().toISOString() + ' ' + line + '\n');
      } catch (e) {
        // 日志写失败不能影响服务
      }
    };
    console.log = wrap(console.log);
    console.warn = wrap(console.warn);
    console.error = wrap(console.error);
  } catch (e) {
    // 没权限写文件时静默降级为只在终端输出
  }
}

// ---------------------------------------------------------------- 存储

/** @type {{ users: Record<string, any> }} */
let db = { users: {} };

function loadDb() {
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    if (fs.existsSync(STORE_FILE)) {
      db = JSON.parse(fs.readFileSync(STORE_FILE, 'utf8'));
      if (!db.users) db.users = {};
    }
  } catch (e) {
    console.error('[store] 读取数据失败，使用空库：', e.message);
    db = { users: {} };
  }
}

let saveTimer = null;
function saveDbSoon() {
  // 播放统计会高频上报，攒 2 秒合并写一次
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try {
      const tmp = STORE_FILE + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify(db));
      fs.renameSync(tmp, STORE_FILE);
    } catch (e) {
      console.error('[store] 写入失败：', e.message);
    }
  }, 2000);
}

// ---------------------------------------------------------------- 工具

function json(res, code, body) {
  const text = JSON.stringify(body);
  res.writeHead(code, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(text)
  });
  res.end(text);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function sha256(s) {
  return crypto.createHash('sha256').update(s).digest('hex');
}

function newToken() {
  return crypto.randomBytes(32).toString('hex');
}

/**
 * 生成恢复码：16 位 Crockford Base32（去掉 I L O U，避免抄错），约 80 bit 熵。
 *
 * 为什么需要它：华为账号登录依赖设备已登录华为账号 + AGC 配置，
 * 换机、刷机、模拟器调试时可能拉不起来。恢复码是一条不依赖任何第三方的退路，
 * 只要把它抄到新设备就能取回云端数据。
 *
 * 说明：恢复码等同于长期密码，明文存在本机 store.json 里——这是你自己 NAS 上的文件，
 * 换来的好处是任何时候都能在 App 里重新看到自己的恢复码。
 */
function newRecoveryCode() {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  const bytes = crypto.randomBytes(16);
  let out = '';
  for (let i = 0; i < 16; i++) out += alphabet[bytes[i] % alphabet.length];
  return out;
}

/** 允许用户带连字符/空格、小写输入 */
function normalizeRecoveryCode(raw) {
  return String(raw || '').toUpperCase().replace(/[^0-9A-Z]/g, '');
}

/** 按用户输入的恢复码找账号（找不到返回 null） */
function findUserByRecoveryCode(code) {
  const want = normalizeRecoveryCode(code);
  if (want.length < 12) return null;
  for (const openid of Object.keys(db.users)) {
    const u = db.users[openid];
    if (u.recoveryCode && u.recoveryCode === want) return openid;
  }
  return null;
}

/** 签发令牌并返回给客户端的登录结果 */
function issueToken(openid, nickname) {
  const token = newToken();
  const exist = db.users[openid] || { data: emptyData(), createdAt: Date.now() };
  if (!exist.recoveryCode) exist.recoveryCode = newRecoveryCode();
  exist.tokenHash = sha256(token);
  exist.tokenExpireAt = Date.now() + TOKEN_TTL_MS;
  exist.lastLoginAt = Date.now();
  if (typeof nickname === 'string' && nickname.length > 0) {
    exist.nickname = nickname.slice(0, 40);
  }
  db.users[openid] = exist;
  saveDbSoon();
  return {
    token: token,
    userId: openid.slice(0, 12),
    nickname: exist.nickname || '',
    recoveryCode: exist.recoveryCode,
    expireAt: exist.tokenExpireAt,
    hasCloudData: !!exist.data && (exist.data.updatedAt || 0) > 0
  };
}

/** @returns {string|null} 已认证的 openid */
function authOpenId(req) {
  const h = req.headers['authorization'] || '';
  const m = /^Bearer\s+([a-f0-9]{64})$/i.exec(h);
  if (!m) return null;
  const hash = sha256(m[1]);
  const now = Date.now();
  for (const openid of Object.keys(db.users)) {
    const u = db.users[openid];
    if (u.tokenHash === hash) {
      if (u.tokenExpireAt && u.tokenExpireAt < now) return null;
      return openid;
    }
  }
  return null;
}

// ---------------------------------------------------------------- 华为 idToken 校验

/** 只解 JWT 的 payload 段，不做验签——验签是下面 tokeninfo 的活儿 */
function decodeJwtPayload(jwt) {
  const parts = String(jwt || '').split('.');
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const pad = b64.length % 4 === 0 ? '' : '='.repeat(4 - (b64.length % 4));
    return JSON.parse(Buffer.from(b64 + pad, 'base64').toString('utf8'));
  } catch (e) {
    return null;
  }
}

/**
 * 调华为的 tokeninfo 接口校验 idToken，返回 openid。
 * 拿不到合法 openid 就抛错——绝不相信客户端直接传来的 openid。
 */
function verifyHuaweiIdToken(idToken) {
  // 先看 aud：令牌是不是发给本应用的。本地判断，省一次网络往返
  if (EXPECTED_CLIENT_ID.length > 0) {
    const payload = decodeJwtPayload(idToken);
    const aud = payload ? payload.aud : undefined;
    const matched = Array.isArray(aud)
      ? aud.indexOf(EXPECTED_CLIENT_ID) >= 0
      : aud === EXPECTED_CLIENT_ID;
    if (!matched) {
      return Promise.reject(new Error('华为账号令牌不属于本应用'));
    }
  }

  const form = 'id_token=' + encodeURIComponent(idToken);
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: 'oauth-login.cloud.huawei.com',
        path: '/oauth2/v3/tokeninfo',
        method: 'POST',
        headers: {
          'content-type': 'application/x-www-form-urlencoded',
          'content-length': Buffer.byteLength(form)
        },
        timeout: 8000
      },
      (res) => {
        let text = '';
        res.on('data', (c) => (text += c));
        res.on('end', () => {
          if (res.statusCode !== 200) {
            reject(new Error('华为账号校验失败 HTTP ' + res.statusCode));
            return;
          }
          try {
            const data = JSON.parse(text);
            const openid = data.openid || data.sub;
            if (!openid) {
              reject(new Error('华为账号校验未返回 openid'));
              return;
            }
            resolve(openid);
          } catch (e) {
            reject(new Error('华为账号校验返回格式异常'));
          }
        });
      }
    );
    req.on('timeout', () => {
      req.destroy(new Error('华为账号校验超时'));
    });
    req.on('error', reject);
    req.write(form);
    req.end();
  });
}

// ---------------------------------------------------------------- 合并规则

/** 日统计：同一天取较大值，避免两台设备各报一份翻倍 */
function mergeListen(local, remote) {
  const out = Object.assign({}, remote || {});
  for (const k of Object.keys(local || {})) {
    const a = Number(local[k]) || 0;
    const b = Number(out[k]) || 0;
    out[k] = Math.max(a, b);
  }
  // 只保留最近 120 天
  const keys = Object.keys(out).sort();
  if (keys.length > 120) {
    const keep = {};
    for (let i = keys.length - 120; i < keys.length; i++) keep[keys[i]] = out[keys[i]];
    return keep;
  }
  return out;
}

/** 单曲统计：逐字段取较大值（次数、时长都不翻倍） */
function mergeTrackStats(local, remote) {
  const out = Object.assign({}, remote || {});
  for (const id of Object.keys(local || {})) {
    const a = local[id] || {};
    const b = out[id];
    if (!b) {
      out[id] = a;
      continue;
    }
    const pick = (Number(a.lastAt) || 0) >= (Number(b.lastAt) || 0) ? a : b;
    out[id] = {
      id: id,
      title: pick.title || b.title || a.title || '',
      artist: pick.artist || b.artist || a.artist || '',
      plays: Math.max(Number(a.plays) || 0, Number(b.plays) || 0),
      seconds: Math.max(Number(a.seconds) || 0, Number(b.seconds) || 0),
      lastAt: Math.max(Number(a.lastAt) || 0, Number(b.lastAt) || 0)
    };
  }
  // 最多留 400 首，按次数、时长淘汰
  const ids = Object.keys(out);
  if (ids.length > 400) {
    ids.sort((x, y) => (out[y].plays - out[x].plays) || (out[y].seconds - out[x].seconds));
    const keep = {};
    for (let i = 0; i < 400; i++) keep[ids[i]] = out[ids[i]];
    return keep;
  }
  return out;
}

function emptyData() {
  return { updatedAt: 0, dark: null, settings: null, server: null, listen: {}, trackStats: {} };
}

// ---------------------------------------------------------------- 路由

async function handle(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname.replace(/\/+$/, '');
  console.log('[http] ' + req.method + ' ' + p);

  if (req.method === 'GET' && p === '/v1/health') {
    json(res, 200, { ok: true, users: Object.keys(db.users).length, time: Date.now() });
    return;
  }

  if (req.method === 'POST' && p === '/v1/auth/login') {
    let body;
    try {
      body = JSON.parse(await readBody(req));
    } catch (e) {
      json(res, 400, { error: '请求格式错误' });
      return;
    }
    const idToken = typeof body.idToken === 'string' ? body.idToken : '';
    const rawOpenId = typeof body.openid === 'string' ? body.openid : '';
    let openid = '';
    try {
      if (idToken.length > 0) {
        openid = await verifyHuaweiIdToken(idToken);
      } else if (ALLOW_INSECURE_OPENID && rawOpenId.length > 0) {
        openid = rawOpenId;
        console.warn('[auth] 使用不校验 openid 的调试模式登录');
      } else {
        json(res, 400, { error: '缺少华为账号凭证' });
        return;
      }
    } catch (e) {
      json(res, 401, { error: e.message || '华为账号校验失败' });
      return;
    }

    const payload = issueToken(openid, typeof body.nickname === 'string' ? body.nickname : '');
    console.log('[auth] 登录成功 openid=' + openid.slice(0, 6) + '***');
    json(res, 200, payload);
    return;
  }

  // 换机兜底：凭恢复码取回同一份云端数据，不需要华为账号
  if (req.method === 'POST' && p === '/v1/auth/resume') {
    let body;
    try {
      body = JSON.parse(await readBody(req));
    } catch (e) {
      json(res, 400, { error: '请求格式错误' });
      return;
    }
    const openid = findUserByRecoveryCode(body.code);
    if (!openid) {
      json(res, 401, { error: '恢复码不正确' });
      return;
    }
    const r = issueToken(openid, typeof body.nickname === 'string' ? body.nickname : '');
    console.log('[auth] 恢复码登录成功 openid=' + openid.slice(0, 6) + '***');
    json(res, 200, r);
    return;
  }

  if (req.method === 'POST' && p === '/v1/auth/logout') {
    const openid = authOpenId(req);
    if (!openid) {
      json(res, 401, { error: '未登录' });
      return;
    }
    db.users[openid].tokenHash = '';
    saveDbSoon();
    json(res, 200, { ok: true });
    return;
  }

  if (p === '/v1/sync') {
    const openid = authOpenId(req);
    if (!openid) {
      json(res, 401, { error: '未登录或登录已过期' });
      return;
    }
    const user = db.users[openid];
    if (!user.data) user.data = emptyData();

    if (req.method === 'GET') {
      json(res, 200, { ok: true, data: user.data });
      return;
    }

    if (req.method === 'POST') {
      let body;
      try {
        body = JSON.parse(await readBody(req));
      } catch (e) {
        json(res, 400, { error: '请求格式错误' });
        return;
      }
      const cloud = user.data;
      const incomingAt = Number(body.updatedAt) || 0;

      // 设置类：后写覆盖（客户端带的是「设置最后改动时间」，不是当前时间）。
      // 用严格大于：时间戳相同说明云端已经是这份数据，重复推送不该改动任何东西。
      if (incomingAt > (Number(cloud.updatedAt) || 0)) {
        if (body.dark !== undefined && body.dark !== null) cloud.dark = !!body.dark;
        if (body.settings) cloud.settings = body.settings;
        if (body.server) cloud.server = body.server;
        cloud.updatedAt = incomingAt;
      }
      // 统计类：永远累进合并，跟时间戳无关
      if (body.listen) cloud.listen = mergeListen(body.listen, cloud.listen);
      if (body.trackStats) cloud.trackStats = mergeTrackStats(body.trackStats, cloud.trackStats);

      user.data = cloud;
      saveDbSoon();
      json(res, 200, { ok: true, data: cloud });
      return;
    }
  }

  json(res, 404, { error: '接口不存在' });
}

setupFileLog();
loadDb();

const server = http.createServer((req, res) => {
  handle(req, res).catch((e) => {
    console.error('[http] 处理失败：', e);
    if (!res.headersSent) json(res, 500, { error: '服务器内部错误' });
  });
});

server.listen(PORT, () => {
  console.log('[feiyin-sync] 监听 0.0.0.0:' + PORT + '，数据目录 ' + DATA_DIR);
  if (ALLOW_INSECURE_OPENID) console.warn('[feiyin-sync] 警告：已开启 openid 直登（仅调试）');
  if (EXPECTED_CLIENT_ID.length === 0) {
    console.warn('[feiyin-sync] 未设置 EXPECTED_CLIENT_ID：不校验令牌归属，接通 AGC 后建议补上');
  } else {
    console.log('[feiyin-sync] 只接受 aud=' + EXPECTED_CLIENT_ID + ' 的华为令牌');
  }
});

process.on('SIGTERM', () => {
  try {
    fs.writeFileSync(STORE_FILE + '.tmp', JSON.stringify(db));
    fs.renameSync(STORE_FILE + '.tmp', STORE_FILE);
  } catch (e) {}
  process.exit(0);
});
