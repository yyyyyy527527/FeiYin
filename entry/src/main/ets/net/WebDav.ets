import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import buffer from '@ohos.buffer';
import { WebDavEntry, ServerConfig, TestResult } from '../model/Models';
import { Fmt } from '../utils/Theme';

/**
 * WebDAV 客户端：通过 PROPFIND 浏览飞牛 NAS 上的音乐目录。
 * 飞牛 fnOS 在「系统设置 → 文件共享协议 → WebDAV」中开启后即可使用。
 * 远程地址格式：https://dav.{id}.fnos.net:443 或局域网 http://{ip}:{port}
 */
export class WebDav {
  private cfg: ServerConfig;
  private authHeader: string;

  constructor(cfg: ServerConfig) {
    this.cfg = cfg;
    this.authHeader = 'Basic ' + buffer.from(cfg.username + ':' + cfg.password, 'utf-8').toString('base64');
  }

  fullUrl(href: string): string {
    const base: string = this.cfg.url.replace(/\/+$/, '');
    let p: string = href;
    if (p.startsWith('/')) {
      p = p.substring(1);
    }
    return base + '/' + p;
  }

  /** 列出目录内容。使用 PROPFIND (Depth: 1) */
  async list(path: string): Promise<WebDavEntry[]> {
    const url: string = this.fullUrl(path);
    const req = http.createHttp();
    try {
      const propfindBody: string = '<?xml version="1.0" encoding="utf-8"?>' +
        '<D:propfind xmlns:D="DAV:">' +
        '<D:prop><D:displayname/><D:getcontentlength/><D:getcontenttype/><D:getlastmodified/><D:resourcetype/></D:prop>' +
        '</D:propfind>';
      const resp = await req.request(url, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': this.authHeader,
          'Depth': '1',
          'Content-Type': 'application/xml; charset=utf-8'
        },
        extraData: propfindBody,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 15000
      } as http.HttpRequestOptions);
      if (resp.responseCode >= 400) {
        throw new Error('WebDAV 请求失败：HTTP ' + resp.responseCode);
      }
      const xml: string = typeof resp.result === 'string' ? resp.result : '';
      return parseMultiStatus(xml, path);
    } finally {
      req.destroy();
    }
  }

  /** 测试连接 */
  async test(): Promise<TestResult> {
    try {
      const entries: WebDavEntry[] = await this.list(this.cfg.rootPath || '/');
      const folders: number = entries.filter((e: WebDavEntry) => e.isDirectory).length;
      const files: number = entries.length - folders;
      const result: TestResult = {
        ok: true,
        msg: '连接成功，发现 ' + folders + ' 个文件夹 / ' + files + ' 个文件',
        count: entries.length
      };
      return result;
    } catch (err) {
      const msg: string = err instanceof Error ? err.message : String(err);
      const result: TestResult = { ok: false, msg: msg, count: 0 };
      return result;
    }
  }

  /** 下载文件到本地 */
  async download(href: string, localPath: string): Promise<void> {
    const url: string = this.fullUrl(href);
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'Authorization': this.authHeader },
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 60000
      } as http.HttpRequestOptions);
      if (resp.responseCode >= 400) {
        throw new Error('下载失败：HTTP ' + resp.responseCode);
      }
      const buf: ArrayBuffer = resp.result as ArrayBuffer;
      const fd: number = fs.openSync(localPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE).fd;
      fs.writeSync(fd, buf);
      fs.closeSync(fd);
    } finally {
      req.destroy();
    }
  }
}

function parseMultiStatus(xml: string, requestPath: string): WebDavEntry[] {
  const entries: WebDavEntry[] = [];
  const responses: string[] = splitAll(xml, '<D:response>', '</D:response>');
  if (responses.length === 0) {
    // 兼容小写命名空间
    const lower: string[] = splitAll(xml, '<d:response>', '</d:response>');
    for (const r of lower) {
      responses.push(r);
    }
  }
  for (let i = 0; i < responses.length; i++) {
    const resp: string = responses[i];
    const href: string = textBetween(resp, '<D:href>', '</D:href>') ||
      textBetween(resp, '<d:href>', '</d:href>') || '';
    if (href.length === 0) {
      continue;
    }
    const decodedHref: string = decodeURIComponent(href);
    if (i === 0) {
      const selfPath: string = requestPath.replace(/\/+$/, '');
      const cleanHref: string = decodedHref.replace(/\/+$/, '');
      if (cleanHref.endsWith(selfPath) || selfPath.endsWith(cleanHref)) {
        continue;
      }
    }
    const isDir: boolean = resp.indexOf('<D:collection') >= 0 || resp.indexOf('<d:collection') >= 0 ||
      resp.indexOf('collection/>') >= 0;
    const displayName: string = textBetween(resp, '<D:displayname>', '</D:displayname>') ||
      textBetween(resp, '<d:displayname>', '</d:displayname>') || Fmt.basename(decodedHref);
    const sizeStr: string = textBetween(resp, '<D:getcontentlength>', '</D:getcontentlength>') ||
      textBetween(resp, '<d:getcontentlength>', '</d:getcontentlength>') || '0';
    const ct: string = textBetween(resp, '<D:getcontenttype>', '</D:getcontenttype>') ||
      textBetween(resp, '<d:getcontenttype>', '</d:getcontenttype>') || '';
    const lmStr: string = textBetween(resp, '<D:getlastmodified>', '</D:getlastmodified>') ||
      textBetween(resp, '<d:getlastmodified>', '</d:getlastmodified>') || '';
    entries.push({
      href: decodedHref,
      displayName: decodeXmlEntities(displayName),
      isDirectory: isDir,
      size: parseInt(sizeStr, 10) || 0,
      contentType: ct,
      lastModified: parseHttpDate(lmStr)
    });
  }
  entries.sort((a: WebDavEntry, b: WebDavEntry) => {
    if (a.isDirectory !== b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    return a.displayName.localeCompare(b.displayName);
  });
  return entries;
}

function splitAll(xml: string, open: string, close: string): string[] {
  const out: string[] = [];
  let pos: number = 0;
  const ol: string = open.toLowerCase();
  const cl: string = close.toLowerCase();
  const xl: string = xml.toLowerCase();
  while (true) {
    const s: number = xl.indexOf(ol, pos);
    if (s < 0) break;
    const e: number = xl.indexOf(cl, s + ol.length);
    if (e < 0) break;
    out.push(xml.substring(s + open.length, e));
    pos = e + close.length;
  }
  return out;
}

function textBetween(xml: string, open: string, close: string): string {
  const ol: string = open.toLowerCase();
  const cl: string = close.toLowerCase();
  const xl: string = xml.toLowerCase();
  const s: number = xl.indexOf(ol);
  if (s < 0) return '';
  const e: number = xl.indexOf(cl, s + ol.length);
  if (e < 0) return '';
  return xml.substring(s + open.length, e).trim();
}

function decodeXmlEntities(s: string): string {
  return s
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
}

function parseHttpDate(s: string): number {
  if (s.length === 0) return 0;
  const d: Date = new Date(s);
  const t: number = d.getTime();
  return isNaN(t) ? 0 : t;
}
