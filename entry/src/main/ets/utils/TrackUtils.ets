import { Track } from '../model/Models';

/**
 * 曲目列表相关的纯计算。
 *
 * 单独成文件的原因：
 *   SubsonicLibrary.ets 已经三千多行，里面混着一批「不读也不写任何组件状态」
 *   的纯函数。它们和界面无关，放在页面里既占地方又没法单独测。
 *   这里集中放，页面只负责调。
 *
 * 约定：本文件里的函数不引用 AppStorage、不引用 Theme、不弹提示，
 * 输入输出都是普通值，可以直接在 node 里跑测试。
 */

/**
 * 音质后缀文案，用于「歌手 · FLAC 1024k」这类副标题。
 * 没有码率也没有格式时返回空串，调用方不必再判空。
 */
export function qualityText(t: Track): string {
  if (t.suffix.length === 0 && t.bitRate <= 0) {
    return '';
  }
  let s: string = ' · ';
  if (t.suffix.length > 0) {
    s += t.suffix.toUpperCase();
  }
  if (t.bitRate > 0) {
    s += (t.suffix.length > 0 ? ' ' : '') + t.bitRate.toString() + 'k';
  }
  return s;
}

/**
 * 把一维列表两两分成行，用于首页 2×2 网格。
 * 奇数个时最后一行只有一首，调用方按 row.length 决定是否补占位。
 */
export function pairTracks(list: Track[]): Track[][] {
  const rows: Track[][] = [];
  let i: number = 0;
  while (i < list.length) {
    const row: Track[] = [list[i]];
    if (i + 1 < list.length) {
      row.push(list[i + 1]);
    }
    rows.push(row);
    i += 2;
  }
  return rows;
}

/**
 * 网格行的 ForEach key。
 *
 * 必须把两首歌的收藏状态都编进去：只带 id 时，点第二列的红心不会触发重建，
 * 图标会停在旧状态。前面的行号也不能省 —— 同一个 key 出现在不同行会
 * 让 ForEach 复用错误的节点。liked 由调用方查好后传入，保持本函数无副作用。
 */
export function pairKey(prefix: string, rowIdx: number, row: Track[], liked: boolean[]): string {
  let k: string = prefix + rowIdx.toString();
  for (let i: number = 0; i < row.length; i++) {
    k += '_' + row[i].id + (liked[i] ? '1' : '0');
  }
  return k;
}

/**
 * 把异常转成能直接显示给用户的文案。
 *
 * 原生侧抛出来的经常是普通对象而不是 Error，直接 String() 会显示 [object Object]，
 * 所以这里按 message → code → 兜底 的顺序取。
 */
export function errText(e: Object): string {
  if (e instanceof Error && e.message.length > 0) {
    return e.message;
  }
  const box: Record<string, Object> = e as Record<string, Object>;
  const msg: Object | undefined = box['message'];
  if (typeof msg === 'string' && (msg as string).length > 0) {
    return msg as string;
  }
  const code: Object | undefined = box['code'];
  if (typeof code === 'number') {
    return '加载失败（错误码 ' + (code as number).toString() + '）';
  }
  return '加载失败，请检查网络与服务器设置';
}

export function primaryArtist(name: string): string {
  // 斜杠不拆：AC/DC、A/B 这类是歌手本名的一部分，拆了就查不到
  const seps: string[] = ['、', '&', ',', '，', ';', '；', ' feat.', ' Feat.', ' ft.'];
  let head: string = name;
  for (const s of seps) {
    const i: number = head.indexOf(s);
    if (i > 0) {
      head = head.substring(0, i);
    }
  }
  return head.trim();
}
