'use strict';
/**
 * 服务端端到端自测：登录 → 推送 → 拉取 → 合并规则 → 恢复码换机
 * 用法：node e2e-test.js http://127.0.0.1:8788
 */
const base = process.argv[2] || 'http://127.0.0.1:8788';
let pass = 0;
let fail = 0;

function ok(name, cond, extra) {
  if (cond) {
    pass++;
    console.log('  PASS  ' + name);
  } else {
    fail++;
    console.log('  FAIL  ' + name + (extra === undefined ? '' : '  -> ' + JSON.stringify(extra)));
  }
}

async function call(method, path, body, token) {
  const headers = {};
  if (body !== undefined) headers['content-type'] = 'application/json';
  if (token) headers['authorization'] = 'Bearer ' + token;
  const res = await fetch(base + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch (e) {}
  return { status: res.status, body: json, raw: text };
}

async function main() {
  console.log('== 1. 健康检查 ==');
  let r = await call('GET', '/v1/health');
  ok('GET /v1/health 200', r.status === 200 && r.body && r.body.ok === true, r.raw);

  console.log('== 2. 未登录访问同步接口应被拒 ==');
  r = await call('GET', '/v1/sync');
  ok('无令牌返回 401', r.status === 401, r.status);

  console.log('== 3. 登录（调试模式 openid 直登）==');
  r = await call('POST', '/v1/auth/login', { openid: 'e2e_openid_001', nickname: '测试机' });
  const token = r.body && r.body.token;
  const code = r.body && r.body.recoveryCode;
  ok('登录返回 200 + token', r.status === 200 && typeof token === 'string' && token.length === 64, r.body);
  ok('返回 16 位恢复码', typeof code === 'string' && code.length === 16, code);
  ok('新账号 hasCloudData=false', r.body.hasCloudData === false, r.body.hasCloudData);

  console.log('== 4. 推送数据 ==');
  const push1 = {
    updatedAt: 1000,
    dark: true,
    settings: { spatial: true, volume: 0.6 },
    server: { host: '192.168.1.116:4533', user: 'demo' },
    listen: { '2026-11-04': 300, '2026-11-05': 120 },
    trackStats: {
      t1: { id: 't1', title: '突然好想你', artist: '五月天', plays: 3, seconds: 600, lastAt: 1000 },
      t2: { id: 't2', title: '夜曲', artist: '周杰伦', plays: 1, seconds: 200, lastAt: 900 }
    }
  };
  r = await call('POST', '/v1/sync', push1, token);
  ok('推送 200', r.status === 200 && r.body.ok === true, r.raw);
  ok('云端记录 dark=true', r.body.data.dark === true, r.body.data && r.body.data.dark);
  ok('云端记录 listen 两天', Object.keys(r.body.data.listen).length === 2, r.body.data.listen);
  ok('云端记录 2 首单曲', Object.keys(r.body.data.trackStats).length === 2, r.body.data.trackStats);

  console.log('== 5. 拉取 ==');
  r = await call('GET', '/v1/sync', undefined, token);
  ok('拉取 200', r.status === 200, r.raw);
  ok('拉回 dark=true', r.body.data.dark === true);
  ok('拉回单曲次数 3', r.body.data.trackStats.t1.plays === 3);

  console.log('== 6. 合并规则：旧设置不覆盖，统计取 max ==');
  const push2 = {
    updatedAt: 500, // 比云端 1000 旧
    dark: false,
    settings: { spatial: false, volume: 0.1 },
    listen: { '2026-11-05': 900 }, // 同一天更大
    trackStats: { t1: { id: 't1', title: '突然好想你', artist: '五月天', plays: 5, seconds: 700, lastAt: 2000 } }
  };
  r = await call('POST', '/v1/sync', push2, token);
  ok('旧时间戳不改设置', r.body.data.dark === true && r.body.data.settings.spatial === true, r.body.data.settings);
  ok('日统计取较大值 900', r.body.data.listen['2026-11-05'] === 900, r.body.data.listen);
  ok('旧日期保留 300', r.body.data.listen['2026-11-04'] === 300, r.body.data.listen);
  ok('单曲次数取 max=5', r.body.data.trackStats.t1.plays === 5, r.body.data.trackStats.t1);
  ok('单曲时长取 max=700', r.body.data.trackStats.t1.seconds === 700, r.body.data.trackStats.t1);
  ok('其他单曲未被删', !!r.body.data.trackStats.t2, r.body.data.trackStats);

  console.log('== 7. 设置更新（时间戳更新时应覆盖）==');
  const push3 = { updatedAt: 3000, dark: false, settings: { spatial: false, volume: 0.2 } };
  r = await call('POST', '/v1/sync', push3, token);
  ok('新时间戳覆盖 dark=false', r.body.data.dark === false);
  ok('新设置生效 volume=0.2', r.body.data.settings.volume === 0.2);

  console.log('== 8. 恢复码换机 ==');
  r = await call('POST', '/v1/auth/resume', { code: code.toLowerCase() });
  ok('小写带格式也能登录', r.status === 200 && typeof r.body.token === 'string', r.raw);
  const token2 = r.body && r.body.token;
  ok('新令牌与旧的不同', token2 !== token);
  r = await call('GET', '/v1/sync', undefined, token2);
  ok('新设备能拉到同一份数据', r.status === 200 && r.body.data.trackStats.t1.plays === 5, r.raw);

  console.log('== 9. 错误路径 ==');
  r = await call('POST', '/v1/auth/resume', { code: 'ZZZZZZZZZZZZZZZZ' });
  ok('错误恢复码 401', r.status === 401, r.status);
  r = await call('POST', '/v1/auth/login', { openid: 'x' });
  ok('未开启调试模式时拒绝裸 openid', r.status === 400 || r.status === 401, r.status);
  r = await call('GET', '/v1/sync', undefined, 'a'.repeat(64));
  ok('伪造令牌 401', r.status === 401, r.status);
  r = await call('GET', '/v1/nope');
  ok('未知路径 404', r.status === 404, r.status);

  console.log('== 10. 注销 ==');
  r = await call('POST', '/v1/auth/logout', {}, token2);
  ok('注销 200', r.status === 200, r.raw);
  r = await call('GET', '/v1/sync', undefined, token2);
  ok('注销后令牌失效 401', r.status === 401, r.status);

  console.log('');
  console.log('结果：' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('测试异常：', e);
  process.exit(2);
});
