import http from '@ohos.net.http';
import { AppSettings, TrackStat } from '../model/Models';

/**
 * 与自建同步服务（NAS 上的 feiyin-sync）通信。
 *
 * 设计原则：
 *  - 只做「登录 / 拉取 / 推送」三件事，合并规则放在服务端，客户端拿到全量直接覆盖本地；
 *  - 网络失败一律以返回值表达，不抛到界面层，避免把设置页点崩；
 *  - 令牌（token）只存在本机 preferences，绝不打印到日志。
 */

/** 登录后的账号信息 */
export interface CloudAccount {
  openid: string;
  userId: string;
  nickname: string;
  token: string;
  /** 换机兜底凭证：不依赖华为账号，抄到新设备即可恢复 */
  recoveryCode: string;
  /** 登录方式：huawei（华为账号）/ code（恢复码） */
  via: string;
  expireAt: number;
  lastSyncAt: number;
}

/** 上传/下发的数据体 */
export interface CloudData {
  updatedAt: number;
  dark: boolean;
  settings: AppSettings;
  server: CloudServer;
  listen: Record<string, number>;
  trackStats: Record<string, TrackStat>;
}

/** 服务器地址与用户名（密码不同步，换机重新输入） */
export interface CloudServer {
  url: string;
  username: string;
}

export interface LoginResult {
  ok: boolean;
  msg: string;
  account: CloudAccount | null;
  hasCloudData: boolean;
}

export interface SyncResult {
  ok: boolean;
  msg: string;
  data: CloudData | null;
}

type JsonObj = Record<string, Object>;

/**
 * @param base 同步服务地址，例如 https://nas.example.com:8787 或 http://192.168.1.10:8787
 */
export class SyncApi {
  private base: string;

  constructor(base: string) {
    this.base = base.replace(/\/+$/, '');
  }

  static normalizeBase(raw: string): string {
    let s: string = raw.trim();
    if (s.length === 0) {
      return '';
    }
    if (s.indexOf('http://') !== 0 && s.indexOf('https://') !== 0) {
      s = 'https://' + s;
    }
    return s.replace(/\/+$/, '');
  }

  /** 用华为账号凭证换取访问令牌 */
  async login(idToken: string, openid: string, nickname: string, base: string): Promise<LoginResult> {
    const body: JsonObj = {
      'idToken': idToken,
      'openid': openid,
      'nickname': nickname
    };
    return this.takeLoginResult(await this.post('/v1/auth/login', body, ''), openid, nickname, 'huawei');
  }

  /**
   * 用恢复码换取访问令牌（换机兜底）。
   * 华为账号在模拟器、未登录华为账号的设备、或 AGC 未配置时都拉不起来，
   * 恢复码是唯一还能把云端数据取回来的路径。
   */
  async resume(code: string, nickname: string): Promise<LoginResult> {
    const body: JsonObj = {
      'code': code.replace(/[^0-9a-zA-Z]/g, ''),
      'nickname': nickname
    };
    return this.takeLoginResult(await this.post('/v1/auth/resume', body, ''), '', nickname, 'code');
  }

  private takeLoginResult(r: NetworkJson, openid: string, nickname: string, via: string): LoginResult {
    if (!r.ok) {
      return { ok: false, msg: r.msg, account: null, hasCloudData: false };
    }
    const obj: JsonObj = r.obj;
    const token: string = asStr(obj['token'], '');
    if (token.length === 0) {
      return { ok: false, msg: '服务器未返回令牌', account: null, hasCloudData: false };
    }
    const account: CloudAccount = {
      openid: openid,
      userId: asStr(obj['userId'], ''),
      nickname: asStr(obj['nickname'], nickname),
      token: token,
      recoveryCode: asStr(obj['recoveryCode'], ''),
      via: via,
      expireAt: asNum(obj['expireAt'], 0),
      lastSyncAt: 0
    };
    return {
      ok: true,
      msg: '',
      account: account,
      hasCloudData: obj['hasCloudData'] === true
    };
  }

  async logout(token: string): Promise<void> {
    await this.post('/v1/auth/logout', {}, token);
  }

  /** 拉取云端数据 */
  async pull(token: string): Promise<SyncResult> {
    const r: NetworkJson = await this.get('/v1/sync', token);
    if (!r.ok) {
      return { ok: false, msg: r.msg, data: null };
    }
    return { ok: true, msg: '', data: parseCloudData(r.obj['data']) };
  }

  /** 推送本地数据，服务端合并后返回全量 */
  async push(token: string, data: CloudData): Promise<SyncResult> {
    const r: NetworkJson = await this.post('/v1/sync', data as Object as JsonObj, token);
    if (!r.ok) {
      return { ok: false, msg: r.msg, data: null };
    }
    return { ok: true, msg: '', data: parseCloudData(r.obj['data']) };
  }

  /** 连通性检查 */
  async ping(): Promise<boolean> {
    const r: NetworkJson = await this.get('/v1/health', '');
    return r.ok;
  }

  private async get(path: string, token: string): Promise<NetworkJson> {
    return this.request(path, http.RequestMethod.GET, '', token);
  }

  private async post(path: string, body: JsonObj, token: string): Promise<NetworkJson> {
    return this.request(path, http.RequestMethod.POST, JSON.stringify(body), token);
  }

  private async request(path: string, method: http.RequestMethod, body: string,
    token: string): Promise<NetworkJson> {
    if (this.base.length === 0) {
      return { ok: false, msg: '还没填写同步服务地址', obj: {} };
    }
    const headers: Record<string, string> = {
      'content-type': 'application/json'
    };
    if (token.length > 0) {
      headers['authorization'] = 'Bearer ' + token;
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(this.base + path, {
        method: method,
        header: headers,
        extraData: body.length > 0 ? body : undefined,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 15000
      } as http.HttpRequestOptions);
      const text: string = typeof resp.result === 'string' ? resp.result as string : '';
      if (resp.responseCode >= 400) {
        const err: string = extractError(text);
        return {
          ok: false,
          msg: err.length > 0 ? err : ('请求失败：HTTP ' + resp.responseCode),
          obj: {}
        };
      }
      try {
        return { ok: true, msg: '', obj: JSON.parse(text) as JsonObj };
      } catch (e) {
        return { ok: false, msg: '服务器返回格式异常', obj: {} };
      }
    } catch (e) {
      return { ok: false, msg: '连不上同步服务，检查地址与网络', obj: {} };
    } finally {
      req.destroy();
    }
  }
}

interface NetworkJson {
  ok: boolean;
  msg: string;
  obj: JsonObj;
}

function extractError(text: string): string {
  try {
    const o = JSON.parse(text) as JsonObj;
    return asStr(o['error'], '');
  } catch (e) {
    return '';
  }
}

function asStr(v: Object | undefined, def: string): string {
  return typeof v === 'string' ? v as string : def;
}

function asNum(v: Object | undefined, def: number): number {
  return typeof v === 'number' ? v as number : def;
}

/** 云端数据结构宽松解析：字段缺失时给默认值，避免老数据把新版打挂 */
export function parseCloudData(raw: Object | undefined): CloudData {
  const o: JsonObj = (raw === undefined || raw === null) ? {} : raw as JsonObj;
  const settingsObj: JsonObj = (o['settings'] === undefined || o['settings'] === null)
    ? {} : o['settings'] as JsonObj;
  const serverObj: JsonObj = (o['server'] === undefined || o['server'] === null)
    ? {} : o['server'] as JsonObj;
  return {
    updatedAt: asNum(o['updatedAt'], 0),
    dark: o['dark'] === true,
    settings: {
      autoCache: settingsObj['autoCache'] !== false,
      volume: asNum(settingsObj['volume'], 80)
    },
    server: {
      url: asStr(serverObj['url'], ''),
      username: asStr(serverObj['username'], '')
    },
    listen: (o['listen'] === undefined || o['listen'] === null)
      ? {} : o['listen'] as Record<string, number>,
    trackStats: (o['trackStats'] === undefined || o['trackStats'] === null)
      ? {} : o['trackStats'] as Record<string, TrackStat>
  };
}
