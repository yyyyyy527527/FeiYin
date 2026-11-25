/**
 * 在线歌词兜底。
 *
 * 场景：Navidrome/OpenSubsonic 服务端自己没收录歌词（大半年这种情况），
 * 播放页就是一片空白。这里在服务端两条通道都没词时，按「歌手 + 歌名」
 * 去公开歌词接口匹配一份带时间轴的 LRC 回来。
 *
 * 设计要点：
 *  - **只在服务端没词时才调**，不改变现有歌词来源的优先级；
 *  - 搜索结果按「歌名匹配 + 歌手匹配 + 时长接近」打分挑最佳，
 *    不能无脑取第一条——实测「周杰伦 晴天」第一条是 RyaVocal 的翻唱；
 *  - 纯 GET、无鉴权、无签名，网易云公开接口；失败一律静默降级为空，
 *    绝不让一条歌词的失败影响播放；
 *  - 命中缓存（含空结果），切歌回来不重复打接口。
 *
 * 合规提醒：歌词版权归各自权利人，此功能面向个人自建曲库的补词，
 * 上架分发时需评估当地版权要求；设置里提供开关可关。
 */

import http from '@ohos.net.http';
import { LyricLine, LyricsResult } from '../model/Models';
import { parseLrc, normalizeTitle, normalizeArtist } from '../utils/LrcParser';

const SEARCH_API: string = 'https://music.163.com/api/search/get';
const LYRIC_API: string = 'https://music.163.com/api/song/lyric';
const UA: string = 'Mozilla/5.0 (Linux; Android) FeiYin/2.1';
const TIMEOUT_MS: number = 6000;
const CACHE_MAX: number = 300;

interface SongHit {
  id: string;
  name: string;
  artists: string;
  duration: number;
}

/** 内存缓存：key 用「歌手|歌名」小写，值为结果（含空结果） */
const cache: Map<string, LyricsResult> = new Map<string, LyricsResult>();

function cacheKey(artist: string, title: string): string {
  return normalizeArtist(artist) + '|' + normalizeTitle(title);
}

function cacheGet(key: string): LyricsResult | null {
  const v: LyricsResult | undefined = cache.get(key);
  return v === undefined ? null : v;
}

function cachePut(key: string, r: LyricsResult): void {
  if (cache.has(key)) {
    cache.delete(key);
  }
  cache.set(key, r);
  if (cache.size > CACHE_MAX) {
    const oldest: string | undefined = cache.keys().next().value;
    if (oldest !== undefined) {
      cache.delete(oldest);
    }
  }
}

/** 清空缓存（服务器地址切换/退出登录时调用，避免串号） */
export function clearOnlineLyricCache(): void {
  cache.clear();
}

/** 带 UA 的 GET，返回响应文本；任何异常返回空串由调用方降级 */
async function getText(url: string): Promise<string> {
  let req: http.HttpRequest | null = null;
  try {
    req = http.createHttp();
    const resp: http.HttpResponse = await req.request(url, {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': UA, 'Referer': 'https://music.163.com/' },
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: TIMEOUT_MS,
      readTimeout: TIMEOUT_MS
    });
    if (resp.responseCode !== 200 || resp.result === undefined) {
      return '';
    }
    const s: string = resp.result as string;
    return s;
  } catch (e) {
    return '';
  } finally {
    if (req !== null) {
      req.destroy();
    }
  }
}

/**
 * 从搜索结果里挑最匹配的一首。
 * 打分：歌名完全相等 3 分 / 包含 1 分；歌手相等 2 分 / 包含 1 分；
 * 时长差 < 8 秒 +1 分。分数相同取靠前（接口本身按相关度排）。
 */
function bestHit(songs: SongHit[], artist: string, title: string, durationMs: number): SongHit | null {
  const wantTitle: string = normalizeTitle(title);
  const wantArtist: string = normalizeArtist(artist);
  let best: SongHit | null = null;
  let bestScore: number = -1;
  for (const s of songs) {
    const gotTitle: string = normalizeTitle(s.name);
    const gotArtist: string = normalizeArtist(s.artists);
    let score: number = 0;
    if (gotTitle === wantTitle) {
      score += 3;
    } else if (wantTitle.length > 0 && (gotTitle.indexOf(wantTitle) >= 0 || wantTitle.indexOf(gotTitle) >= 0)) {
      score += 1;
    }
    if (wantArtist.length > 0) {
      if (gotArtist.length > 0 && gotArtist === wantArtist) {
        score += 2;
      } else if (gotArtist.length > 0 &&
        (gotArtist.indexOf(wantArtist) >= 0 || wantArtist.indexOf(gotArtist) >= 0)) {
        score += 1;
      } else {
        // 歌手字段不含目标歌手时，再看原始标题（保留括号）——
        // 「晴天 (原唱 周杰伦)」这类条目歌手栏是 RyaVocal，但标题标了原唱是谁，
        // 歌词就是原曲的，应算命中。注意不能用 normalizeTitle（它删括号，会漏掉）
        const rawTitle: string = s.name.toLowerCase().replace(/\s+/g, '');
        if (wantArtist.length > 0 && rawTitle.indexOf(wantArtist) >= 0) {
          score += 2;
        }
      }
    }
    if (durationMs > 0 && s.duration > 0 && Math.abs(s.duration - durationMs) < 8000) {
      score += 1;
    }
    // 纯伴奏/纯音乐多半没歌词，降权让有词的版本胜出
    if (/伴奏|纯音乐|inst\.?$|纯伴奏|卡拉ok|karaoke|钢琴版|吉他版/i.test(s.name)) {
      score -= 2;
    }
    if (score > bestScore) {
      bestScore = score;
      best = s;
    }
  }
  return bestScore > 0 ? best : null;
}

/** 解析搜索 JSON；结构不标准时返回空数组 */
function parseSearch(json: string): SongHit[] {
  if (json.length === 0) {
    return [];
  }
  try {
    const root = JSON.parse(json) as Record<string, Object>;
    const result = root['result'] as Record<string, Object> | undefined;
    if (result === undefined) {
      return [];
    }
    const songs = result['songs'] as Object[] | undefined;
    if (songs === undefined || !Array.isArray(songs)) {
      return [];
    }
    const out: SongHit[] = [];
    for (const item of songs) {
      const o = item as Record<string, Object>;
      const idNum: Object | undefined = o['id'];
      if (idNum === undefined) {
        continue;
      }
      const arts = o['artists'] as Object[] | undefined;
      const names: string[] = [];
      if (arts !== undefined) {
        for (const a of arts) {
          const ao = a as Record<string, Object>;
          const n: Object | undefined = ao['name'];
          if (typeof n === 'string') {
            names.push(n as string);
          }
        }
      }
      out.push({
        id: String(idNum),
        name: typeof o['name'] === 'string' ? o['name'] as string : '',
        artists: names.join('/'),
        duration: typeof o['duration'] === 'number' ? o['duration'] as number : 0
      });
    }
    return out;
  } catch (e) {
    return [];
  }
}

/** 过滤掉歌词正文里的制作信息行（作词/作曲/编曲/混音…），它们带时间戳但不是唱词 */
function stripMeta(lrc: string): string {
  const lines: string[] = lrc.split('\n');
  const kept: string[] = [];
  for (const line of lines) {
    // 形如 [00:03.00] 作词 : 周杰伦 —— 时间标签之后紧接着制作信息
    if (/^\s*\[\d+:\d+(?:[.:]\d+)?\]\s*(作词|作曲|编曲|制作人|监制|演唱|录音|混音|母带|和声|吉他|贝斯|鼓|出品|发行|OP|SP|原唱|翻唱)\s*[:：]/.test(line)) {
      continue;
    }
    kept.push(line);
  }
  return kept.join('\n');
}

/**
 * 取在线歌词（服务端没词时才调用）。
 * @param artist 歌手（ NAS 曲库里通常是「歌手名」，多个用 / 或 、分隔）
 * @param title 歌名
 * @param durationMs 曲长（毫秒，用于消歧；0 表示未知）
 * @returns 解析好的歌词；任何环节失败返回空结果（lines 为空、synced=false）
 */
export async function fetchOnlineLyrics(artist: string, title: string, durationMs: number): Promise<LyricsResult> {
  const empty: LyricsResult = { lines: [], synced: false };
  if (title.trim().length === 0) {
    return empty;
  }
  const key: string = cacheKey(artist, title);
  const hit: LyricsResult | null = cacheGet(key);
  if (hit !== null) {
    return hit;
  }
  // 关键词：歌手 + 歌名；歌手为空时只搜歌名
  const keyword: string = artist.length > 0 ? (artist + ' ' + title) : title;
  const searchUrl: string = SEARCH_API + '?s=' + encodeURIComponent(keyword) + '&type=1&limit=8';
  const songs: SongHit[] = parseSearch(await getText(searchUrl));
  const best: SongHit | null = bestHit(songs, artist, title, durationMs);
  if (best === null || best.id.length === 0) {
    cachePut(key, empty);
    return empty;
  }
  const lyricUrl: string = LYRIC_API + '?id=' + encodeURIComponent(best.id) + '&lv=1&kv=1&tv=-1';
  const json: string = await getText(lyricUrl);
  if (json.length === 0) {
    cachePut(key, empty);
    return empty;
  }
  try {
    const root = JSON.parse(json) as Record<string, Object>;
    const lrcBox = root['lrc'] as Record<string, Object> | undefined;
    if (lrcBox === undefined) {
      cachePut(key, empty);
      return empty;
    }
    const value: Object | undefined = lrcBox['lyric'];
    if (typeof value !== 'string' || (value as string).length === 0) {
      cachePut(key, empty);
      return empty;
    }
    const parsed: LyricsResult = parseLrc(stripMeta(value as string));
    if (parsed.lines.length === 0) {
      cachePut(key, empty);
      return empty;
    }
    // 打上来源与命中版本，播放页据此标注「在线匹配」并可点击查看是哪一个版本
    parsed.source = 'online';
    parsed.sourceName = best.artists.length > 0
      ? (best.artists + ' - ' + best.name)
      : best.name;
    cachePut(key, parsed);
    return parsed;
  } catch (e) {
    cachePut(key, empty);
    return empty;
  }
}
