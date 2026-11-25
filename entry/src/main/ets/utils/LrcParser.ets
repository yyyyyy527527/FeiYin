/**
 * LRC 文本解析（纯函数，无副作用）。
 *
 * 从 Subsonic.ets 抽出来独立成文件：服务端 getLyrics 返回的内嵌 LRC
 * 与在线歌词兜底拿到的 LRC 都要走同一套解析，放在同一处才不会出现
 * 「两个来源的高亮行为不一致」。
 *
 * 处理两个现实中的坑：
 *   1) 头部元数据 [ar:...] [offset:...] 不是歌词，得跳过；
 *   2) 时间轴不保证升序，输出前必须排序，否则二分查找会漏掉乱序点之后的句子。
 */

import { LyricLine, LyricsResult } from '../model/Models';

export function parseLrc(text: string): LyricsResult {
  const rawLines: string[] = text.split('\n');
  const out: LyricLine[] = [];
  // 无时间戳的行先暂存：整段都没时间轴就当纯文本按顺序展示；
  // 有时间轴时它们是制作信息/翻译备注，丢弃（给猜测时间点会和邻句抢同一时刻）
  const orphan: string[] = [];
  let synced: boolean = false;
  for (const raw of rawLines) {
    const line: string = raw.replace(/\r$/, '');
    if (line.trim().length === 0) {
      continue;
    }
    // LRC 头部元数据：不是歌词
    if (/^\[(ar|ti|al|by|offset|re|ve|length|au|kana):/i.test(line)) {
      continue;
    }
    // 从行首连续吃时间标签，支持 [mm:ss.xx] 与 [mm:ss:xx]
    const stamps: number[] = [];
    let cursor: number = 0;
    while (true) {
      const head: RegExpMatchArray | null =
        line.substring(cursor).match(/^\[(\d+):(\d+)(?:[.:](\d+))?\]/);
      if (head === null) {
        break;
      }
      const min: number = Number(head[1]);
      const sec: number = Number(head[2]);
      let ms: number = 0;
      if (head.length > 3 && head[3] !== undefined) {
        const frac: string = head[3];
        const f: number = Number(frac);
        if (isFinite(f) && frac.length > 0) {
          ms = Math.round(f / Math.pow(10, frac.length) * 1000);
        }
      }
      stamps.push((min * 60 + sec) * 1000 + ms);
      cursor += head[0].length;
    }
    if (stamps.length > 0) {
      const content: string = line.substring(cursor).trim();
      if (content.length > 0) {
        for (const st of stamps) {
          const tl: LyricLine = { start: st, text: content };
          out.push(tl);
        }
        synced = true;
      }
    } else {
      orphan.push(line.trim());
    }
  }
  if (synced) {
    // 有歌词时间轴就不保留无戳行；排序保证二分查找成立
    out.sort((a: LyricLine, b: LyricLine) => a.start - b.start);
  } else {
    for (const o of orphan) {
      const pl: LyricLine = { start: 0, text: o };
      out.push(pl);
    }
  }
  const result: LyricsResult = { lines: out, synced: synced };
  return result;
}

/**
 * 归一化用于歌名/歌手匹配的字符串：
 * 转小写、去空白与标点、去括号里的「翻唱/原唱/live/cover」等修饰，
 * 让「晴天 (原唱 周杰伦)」和「晴天」能对上。
 */
export function normalizeTitle(s: string): string {
  let t: string = s.toLowerCase();
  // 去掉中英文括号及其内容（含封面常见的 (Live) / （DJ版） / [原唱:xxx]）
  t = t.replace(/[\(（\[【][^)）\]】]*[\)）\]】]/g, '');
  // 去掉分隔标点与空白
  t = t.replace(/[\s\-_'’"“”、,，.!！?？:：;；/\\|]+/g, '');
  return t;
}

/** 歌手名归一化：只去空白与常见后缀，保留「周杰伦」「Jay Chou」本体 */
export function normalizeArtist(s: string): string {
  let t: string = s.toLowerCase();
  t = t.replace(/\s*\(?原唱[:：]?.*$/, '');
  t = t.replace(/[\s'’"“”、,，.!/\\|]+/g, '');
  return t;
}
