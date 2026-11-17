import { topInset, bottomInset } from '../utils/Theme';
import { APP_FONT, APP_FONT_BOLD } from '../utils/Fonts';
import { Store } from '../store/Store';
import { TrackStat } from '../model/Models';
import { Router } from '../utils/Router';

/**
 * 听歌统计（二级页）。
 *
 * 入口：设置 → 听歌统计 →「查看全部」。
 * 数据全部来自本机 Store：每日收听秒数（listen_stats）、每日播放次数（listen_plays）、
 * 单曲统计（track_stats，含音质快照）。不联网，断网也能看。
 *
 * 五个一级分段（今日 / 日历 / 统计 / 徽章 / 报告）对应五种看法，
 * 「统计」下面再分总览 / 时间 / 口味 / 音质 / 资料库五个视角。
 *
 * 性能：这页的 build 会在几十个位置读同一批聚合值。全都现算的话，
 * 一次 build 要把「365 天的日期表 + 400 首单曲的排序分桶」重跑几十遍，
 * 转场动画期间任何一次刷新都会把动画帧挤掉（表现为返回时掉帧）。
 * 所以统一走 ensure() 缓存：按「周期 + 锚点 + 30 秒时间片 + 数据版本」算一次，
 * 各取值方法只读缓存。正在播放时统计每 500ms 在涨，30 秒的延迟感知不到。
 */

const ACCENT_L: string = '#B01F3B';
const ACCENT_D: string = '#E4596F';
const FLAC_C: string = '#C0243E';
const MP3_C: string = '#2E6FC7';
const ALAC_C: string = '#1E9E6B';
const AAC_C: string = '#E5B03C';
const OTHER_C: string = '#9A9AA4';

const SEGS: string[] = ['今日', '日历', '统计', '徽章', '报告'];
const SUBS: string[] = ['总览', '时间', '口味', '音质', '资料库'];
const PERIODS: string[] = ['周', '月', '年', '全部'];

interface DayPoint {
  key: string;
  label: string;
  sec: number;
}

interface BigValue {
  v: string;
  u: string;
}

interface QualityPart {
  label: string;
  sec: number;
  color: string;
}

interface SpecCell {
  bits: string;
  khz: string;
  pct: number;
}

interface RankRow {
  name: string;
  sub: string;
  value: string;
  pct: number;
}

interface BadgeCell {
  title: string;
  sub: string;
  got: boolean;
  /** 图标名（对应 media/ic_badge_{key}_{on_on_d_g}.svg） */
  key: string;
}

interface CalCell {
  key: string;
  day: number;
  sec: number;
  blank: boolean;
  today: boolean;
}

@Entry
@Component
struct Stats {
  @StorageProp('isDark') private isDark: boolean = true;
  /**
   * 统计版本：Store 记一次播放 / 落盘 / 云合并都会递增。
   * 它同时干两件事——作废下面的计算缓存，以及给组件登记一个响应式依赖，
   * 这样「边听边看统计」时数字会自己跳，不用退出页面再进。
   */
  @StorageProp('statsVer') private statsVer: number = 0;
  @StorageLink('playerTitle') private playingTitle: string = '';
  @StorageLink('playerArtist') private playingArtist: string = '';
  @StorageLink('playerCoverUrl') private playingCover: string = '';
  @StorageLink('playerPlaying') private playing: boolean = false;

  /** 0 今日 / 1 日历 / 2 统计 / 3 徽章 / 4 报告 */
  @State private mode: number = 2;
  /** 统计分段下的视角：0 总览 / 1 时间 / 2 口味 / 3 音质 / 4 资料库 */
  @State private sub: number = 0;
  /** 周期：0 周 / 1 月 / 2 年 / 3 全部 */
  @State private period: number = 1;
  /** 周/月/年的锚点（任取周期内一天） */
  @State private anchor: number = Date.now();
  /** 日历里点选的那一天 */
  @State private selDay: string = '';

  /** 内容滚动器：切分段时把位置归零，避免沿用上一页的滚动位置 */
  private scroller: Scroller = new Scroller();
  /** 「和上期比」面积图。ArkUI 的 Canvas 坐标就是 vp，直接按 64 高来画 */
  private areaCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));

  // ---------------- 计算缓存 ----------------

  private _ck: string = '';
  private _cAll: TrackStat[] = [];
  private _cRangeKeys: string[] = [];
  private _cPrevKeys: string[] = [];
  private _cPoints: DayPoint[] = [];
  private _cRangeStats: TrackStat[] = [];
  private _cQuality: QualityPart[] = [];
  private _cSpec: SpecCell[] = [];
  private _cArtists: RankRow[] = [];
  private _cWeekday: number[] = [];
  private _cBadges: BadgeCell[] = [];
  private _cCal: CalCell[][] = [];
  private _cCalMax: number = 0;
  private _cToday: TrackStat[] = [];
  private _cWeekPts: DayPoint[] = [];
  private _cStreak: number = 0;
  private _cTotalPlays: number = 0;
  private _cKnown: number = 0;
  private _cLoss: number = 0;
  private _cHiRes: number = 0;
  private _cChartTop: number = 1800;
  private _cMaxDay: number = 0;

  aboutToAppear(): void {
    const now: Date = new Date();
    this.anchor = now.getTime();
    this.selDay = Store.dayKey(now);
    // 进页面前把攒着的统计落一次盘，保证本页看到的是最新数字
    Store.get().flushStats();
  }

  // 不再自定义 pageTransition：带位移/透明度的整页转场对这棵重树每帧全量合成，
  // 是返回卡顿的直接来源；系统默认转场走快照优化，对重页面稳定得多。

  /** 缓存失效时机：周期/锚点变化、每 30 秒一个时间片、统计结构版本变化。
   *  版本号读 this.statsVer（响应式）：Store 每记一次播放/落盘/合并都会 +1，
   *  组件跟着登记依赖，播放中停留本页也能看到排行变化。
   *  不能用听歌总秒数——播放中它每 200ms 都在涨，缓存每秒会被作废 5 次，
   *  转场动画期间随便撞上一次全量重算（400 首排序 + 365 天日期表）就是一帧掉帧，
   *  这正是返回动画卡顿的最后一个活跃刷新源。 */
  private ensure(): void {
    const key: string = this.period + '|' + this.anchor + '|' +
      Math.floor(Date.now() / 30000) + '|' +
      this.statsVer;
    if (key === this._ck) {
      return;
    }
    this._ck = key;
    this._cAll = Store.get().topTracks(0);
    this._cRangeKeys = this.buildRangeKeys();
    this._cPrevKeys = this.buildPrevKeys();
    this._cPoints = this.buildPoints();
    this._cRangeStats = this.pickRange(this._cRangeKeys, this._cAll);
    this._cQuality = this.buildQuality(this._cAll);
    this._cSpec = this.buildSpec(this._cAll);
    this._cKnown = this.sumQuality(this._cQuality);
    this._cLoss = this.buildLoss(this._cAll);
    this._cHiRes = this.buildHiRes(this._cAll);
    this._cArtists = this.buildArtistRows(this._cAll);
    this._cWeekday = this.buildWeekday(this._cRangeKeys);
    this._cBadges = this.buildBadges();
    this._cCal = this.buildCalRows();
    this._cCalMax = this.buildCalMax();
    this._cToday = this.buildTodayTracks();
    this._cWeekPts = this.buildWeekPoints();
    this._cStreak = this.buildStreak();
    this._cTotalPlays = this.buildTotalPlays();
    this._cMaxDay = 0;
    for (let i = 0; i < this._cPoints.length; i++) {
      if (this._cPoints[i].sec > this._cMaxDay) {
        this._cMaxDay = this._cPoints[i].sec;
      }
    }
    const mx: number = this._cMaxDay < 600 ? 600 : this._cMaxDay;
    if (mx <= 1800) {
      this._cChartTop = 1800;
    } else if (mx <= 3600) {
      this._cChartTop = 3600;
    } else if (mx <= 7200) {
      this._cChartTop = 7200;
    } else {
      this._cChartTop = Math.ceil(mx / 3600) * 3600;
    }
  }

  private allStats(): TrackStat[] {
    this.ensure();
    return this._cAll;
  }

  // ---------------- 配色 ----------------

  private pageBg(): string {
    return this.isDark ? '#0F1014' : '#F3F2F7';
  }

  private cardBg(): string {
    return this.isDark ? '#1C1D23' : '#FFFFFF';
  }

  private ink(): string {
    return this.isDark ? '#ECECF0' : '#14141A';
  }

  private subText(): string {
    return this.isDark ? '#9A9AA4' : '#7C7C88';
  }

  private faintText(): string {
    return this.isDark ? '#6A6A74' : '#A5A5B0';
  }

  private trackBg(): string {
    return this.isDark ? '#2A2B33' : '#E9E8EF';
  }

  private barIdle(): string {
    return this.isDark ? '#3B3C46' : '#DCDBE4';
  }

  private accent(): string {
    return this.isDark ? ACCENT_D : ACCENT_L;
  }

  private accentSoft(): string {
    return this.isDark ? '#22E4596F' : '#12B01F3B';
  }

  private divider(): string {
    return this.isDark ? '#1FFFFFFF' : '#0E000000';
  }

  // ---------------- 日期工具 ----------------

  private keyOf(d: Date): string {
    return Store.dayKey(d);
  }

  private startOfDay(d: Date): Date {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate());
  }

  private addDays(d: Date, n: number): Date {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
  }

  /** 周一为一周之始 */
  private weekStart(d: Date): Date {
    const wd: number = (d.getDay() + 6) % 7;
    return this.addDays(this.startOfDay(d), -wd);
  }

  private monthDays(y: number, m: number): string[] {
    const total: number = new Date(y, m, 0).getDate();
    const out: string[] = [];
    for (let i = 1; i <= total; i++) {
      out.push(this.keyOf(new Date(y, m - 1, i)));
    }
    return out;
  }

  // ---------------- 周期取数 ----------------

  private rangeKeys(): string[] {
    this.ensure();
    return this._cRangeKeys;
  }

  private buildRangeKeys(): string[] {
    const a: Date = new Date(this.anchor);
    if (this.period === 0) {
      const s: Date = this.weekStart(a);
      const out: string[] = [];
      for (let i = 0; i < 7; i++) {
        out.push(this.keyOf(this.addDays(s, i)));
      }
      return out;
    }
    if (this.period === 1) {
      return this.monthDays(a.getFullYear(), a.getMonth() + 1);
    }
    if (this.period === 2) {
      const out: string[] = [];
      for (let m = 1; m <= 12; m++) {
        const ds: string[] = this.monthDays(a.getFullYear(), m);
        for (let i = 0; i < ds.length; i++) {
          out.push(ds[i]);
        }
      }
      return out;
    }
    // 全部：从最早一条记录到今天（最长两年，和 Store 的保留期一致）
    const map: Record<string, number> = Store.get().listenMap();
    const keys: string[] = Object.keys(map).sort();
    const today: Date = this.startOfDay(new Date());
    const from: Date = keys.length > 0 ? new Date(keys[0] + 'T00:00:00') : this.addDays(today, -29);
    const out: string[] = [];
    let cur: Date = from;
    let guard: number = 0;
    while (cur.getTime() <= today.getTime() && guard < 740) {
      out.push(this.keyOf(cur));
      cur = this.addDays(cur, 1);
      guard++;
    }
    return out;
  }

  private prevKeys(): string[] {
    this.ensure();
    return this._cPrevKeys;
  }

  private buildPrevKeys(): string[] {
    if (this.period === 3) {
      return [];
    }
    const a: Date = new Date(this.anchor);
    if (this.period === 0) {
      const s: Date = this.addDays(this.weekStart(a), -7);
      const out: string[] = [];
      for (let i = 0; i < 7; i++) {
        out.push(this.keyOf(this.addDays(s, i)));
      }
      return out;
    }
    if (this.period === 1) {
      const y: number = a.getMonth() === 0 ? a.getFullYear() - 1 : a.getFullYear();
      const m: number = a.getMonth() === 0 ? 12 : a.getMonth();
      return this.monthDays(y, m);
    }
    const out: string[] = [];
    for (let m = 1; m <= 12; m++) {
      const ds: string[] = this.monthDays(a.getFullYear() - 1, m);
      for (let i = 0; i < ds.length; i++) {
        out.push(ds[i]);
      }
    }
    return out;
  }

  private points(): DayPoint[] {
    this.ensure();
    return this._cPoints;
  }

  /** 图表数据点：周=7 天，月=当月每天，年=12 个月，全部=近 30 天 */
  private buildPoints(): DayPoint[] {
    const out: DayPoint[] = [];
    const a: Date = new Date(this.anchor);
    if (this.period === 0) {
      const s: Date = this.weekStart(a);
      const names: string[] = ['一', '二', '三', '四', '五', '六', '日'];
      for (let i = 0; i < 7; i++) {
        const d: Date = this.addDays(s, i);
        const k: string = this.keyOf(d);
        out.push({ key: k, label: names[i], sec: Store.get().listenSecondsOn(k) });
      }
      return out;
    }
    if (this.period === 1) {
      const y: number = a.getFullYear();
      const m: number = a.getMonth() + 1;
      const total: number = new Date(y, m, 0).getDate();
      for (let i = 1; i <= total; i++) {
        const k: string = this.keyOf(new Date(y, m - 1, i));
        out.push({ key: k, label: String(i), sec: Store.get().listenSecondsOn(k) });
      }
      return out;
    }
    if (this.period === 2) {
      const y: number = a.getFullYear();
      for (let m = 1; m <= 12; m++) {
        const keys: string[] = this.monthDays(y, m);
        out.push({ key: y + '-' + m, label: m + '月', sec: this.sumSec(keys) });
      }
      return out;
    }
    const today: Date = this.startOfDay(new Date());
    for (let i = 29; i >= 0; i--) {
      const d: Date = this.addDays(today, -i);
      const k: string = this.keyOf(d);
      out.push({
        key: k,
        label: (d.getMonth() + 1) + '/' + d.getDate(),
        sec: Store.get().listenSecondsOn(k)
      });
    }
    return out;
  }

  private sumSec(keys: string[]): number {
    const map: Record<string, number> = Store.get().listenMap();
    let sum: number = 0;
    for (let i = 0; i < keys.length; i++) {
      const v: number | undefined = map[keys[i]];
      if (v !== undefined) {
        sum += v;
      }
    }
    return sum;
  }

  private sumPlays(keys: string[]): number {
    const map: Record<string, number> = Store.get().playsMap();
    let sum: number = 0;
    for (let i = 0; i < keys.length; i++) {
      const v: number | undefined = map[keys[i]];
      if (v !== undefined) {
        sum += v;
      }
    }
    return sum;
  }

  private activeDays(keys: string[]): number {
    const map: Record<string, number> = Store.get().listenMap();
    let n: number = 0;
    for (let i = 0; i < keys.length; i++) {
      const v: number | undefined = map[keys[i]];
      if (v !== undefined && v > 0) {
        n++;
      }
    }
    return n;
  }

  private pickRange(keys: string[], all: TrackStat[]): TrackStat[] {
    if (keys.length === 0) {
      return [];
    }
    const start: number = new Date(keys[0] + 'T00:00:00').getTime();
    const last: string = keys[keys.length - 1];
    const end: number = new Date(last + 'T23:59:59').getTime();
    const out: TrackStat[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].lastAt >= start && all[i].lastAt <= end) {
        out.push(all[i]);
      }
    }
    return out;
  }

  /** 统计周期内播放过的曲目（按 lastAt 落在周期内近似） */
  private rangeStats(): TrackStat[] {
    this.ensure();
    return this._cRangeStats;
  }

  private songCount(stats: TrackStat[]): number {
    const seen: Record<string, boolean> = {};
    let n: number = 0;
    for (let i = 0; i < stats.length; i++) {
      if (seen[stats[i].id] !== true) {
        seen[stats[i].id] = true;
        n++;
      }
    }
    return n;
  }

  private artistCount(stats: TrackStat[]): number {
    const seen: Record<string, boolean> = {};
    let n: number = 0;
    for (let i = 0; i < stats.length; i++) {
      const a: string = stats[i].artist.length > 0 ? stats[i].artist : '未知歌手';
      if (seen[a] !== true) {
        seen[a] = true;
        n++;
      }
    }
    return n;
  }

  private streakDays(): number {
    this.ensure();
    return this._cStreak;
  }

  /** 连续听歌天数：从今天往前数，遇到空白天就停（今天还没听不算断） */
  private buildStreak(): number {
    const map: Record<string, number> = Store.get().listenMap();
    let d: Date = this.startOfDay(new Date());
    let n: number = 0;
    for (let i = 0; i < 740; i++) {
      const v: number | undefined = map[this.keyOf(d)];
      if (v === undefined || v <= 0) {
        if (i === 0) {
          d = this.addDays(d, -1);
          continue;
        }
        break;
      }
      n++;
      d = this.addDays(d, -1);
    }
    return n;
  }

  private totalTrackPlays(): number {
    this.ensure();
    return this._cTotalPlays;
  }

  private buildTotalPlays(): number {
    let n: number = 0;
    for (let i = 0; i < this._cAll.length; i++) {
      n += this._cAll[i].plays;
    }
    return n;
  }

  // ---------------- 文案 ----------------

  private durText(sec: number): string {
    if (sec < 60) {
      return Math.round(sec) + ' 秒';
    }
    const h: number = Math.floor(sec / 3600);
    const m: number = Math.floor((sec % 3600) / 60);
    if (h === 0) {
      return m + ' 分钟';
    }
    return m === 0 ? h + ' 小时' : h + ' 小时 ' + m + ' 分';
  }

  private durShort(sec: number): string {
    if (sec < 60) {
      return '0';
    }
    const h: number = Math.floor(sec / 3600);
    const m: number = Math.floor((sec % 3600) / 60);
    if (h === 0) {
      return m + '分';
    }
    return m === 0 ? h + '时' : h + '时' + m + '分';
  }

  /** 大数字 + 单位：不足 10 小时保留一位小数 */
  private bigTime(sec: number): BigValue {
    if (sec < 3600) {
      return { v: String(Math.floor(sec / 60)), u: '分钟' };
    }
    if (sec < 36000) {
      const v: number = Math.round(sec / 360) / 10;
      return { v: String(v), u: '小时' };
    }
    return { v: String(Math.round(sec / 3600)), u: '小时' };
  }

  private cmpText(cur: number, prev: number): string {
    if (prev <= 0) {
      return cur > 0 ? '比上期 新增' : '比上期 持平';
    }
    const d: number = Math.round((cur - prev) / prev * 100);
    if (d === 0) {
      return '比上期 持平';
    }
    return '比上期 ' + (d > 0 ? '+' : '') + d + '%';
  }

  private periodLabel(): string {
    const a: Date = new Date(this.anchor);
    if (this.period === 0) {
      const s: Date = this.weekStart(a);
      const e: Date = this.addDays(s, 6);
      return (s.getMonth() + 1) + '月' + s.getDate() + '日 - ' +
        (e.getMonth() + 1) + '月' + e.getDate() + '日';
    }
    if (this.period === 1) {
      return a.getFullYear() + '年' + (a.getMonth() + 1) + '月';
    }
    if (this.period === 2) {
      return a.getFullYear() + '年';
    }
    return '全部时间';
  }

  private shiftPeriod(dir: number): void {
    if (this.period === 3) {
      return;
    }
    const a: Date = new Date(this.anchor);
    if (this.period === 0) {
      this.anchor = this.addDays(a, 7 * dir).getTime();
    } else if (this.period === 1) {
      this.anchor = new Date(a.getFullYear(), a.getMonth() + dir, 1).getTime();
    } else {
      this.anchor = new Date(a.getFullYear() + dir, 0, 1).getTime();
    }
  }

  private chartTop(): number {
    this.ensure();
    return this._cChartTop;
  }

  private maxDaySec(): number {
    this.ensure();
    return this._cMaxDay;
  }

  private barH(sec: number): number {
    const top: number = this.chartTop();
    const h: number = sec / top * 100;
    return h < 2 ? 2 : h;
  }

  private avgPerActiveDay(): number {
    const days: number = this.activeDays(this.rangeKeys());
    return days === 0 ? 0 : this.sumSec(this.rangeKeys()) / days;
  }

  /** 4 个横轴刻度：首、1/3、2/3、末 */
  private axisLabels(): string[] {
    const pts: DayPoint[] = this.points();
    if (pts.length === 0) {
      return ['', '', '', ''];
    }
    const a: number = Math.floor((pts.length - 1) / 3);
    const b: number = Math.floor((pts.length - 1) * 2 / 3);
    return [pts[0].label, pts[a].label, pts[b].label, pts[pts.length - 1].label];
  }

  /** 7 格迷你趋势（卡片右上角） */
  private spark(pts: DayPoint[]): number[] {
    const out: number[] = [];
    if (pts.length === 0) {
      return [0, 0, 0, 0, 0, 0, 0];
    }
    const step: number = Math.max(1, Math.ceil(pts.length / 7));
    for (let i = 0; i < 7; i++) {
      const from: number = Math.min(pts.length - 1, i * step);
      const to: number = Math.min(pts.length, from + step);
      let s: number = 0;
      for (let j = from; j < to; j++) {
        s += pts[j].sec;
      }
      out.push(s);
    }
    return out;
  }

  private sparkH(v: number, series: number[]): number {
    let mx: number = 1;
    for (let i = 0; i < series.length; i++) {
      if (series[i] > mx) {
        mx = series[i];
      }
    }
    const h: number = 4 + v / mx * 13;
    return h < 4 ? 4 : h;
  }

  // ---------------- 音质 ----------------

  private fmtOf(st: TrackStat): string {
    const s: string = st.suffix === undefined ? '' : st.suffix.toLowerCase();
    return s.length === 0 ? '未知' : s.toUpperCase();
  }

  private isLossless(s: string): boolean {
    return s === 'FLAC' || s === 'ALAC' || s === 'WAV' || s === 'AIFF' || s === 'DSF' || s === 'DFF';
  }

  private qualityParts(): QualityPart[] {
    this.ensure();
    return this._cQuality;
  }

  /** 统计曲目的音质切片（按累计时长加权） */
  private buildQuality(all: TrackStat[]): QualityPart[] {
    let flac: number = 0;
    let alac: number = 0;
    let mp3: number = 0;
    let aac: number = 0;
    let other: number = 0;
    for (let i = 0; i < all.length; i++) {
      const st: TrackStat = all[i];
      if (st.suffix === undefined || st.suffix.length === 0) {
        continue;
      }
      const f: string = this.fmtOf(st);
      if (f === 'ALAC') {
        alac += st.seconds;
      } else if (f === 'FLAC' || f === 'WAV' || f === 'AIFF' || f === 'DSF' || f === 'DFF') {
        flac += st.seconds;
      } else if (f === 'MP3') {
        mp3 += st.seconds;
      } else if (f === 'AAC' || f === 'M4A') {
        aac += st.seconds;
      } else {
        other += st.seconds;
      }
    }
    const out: QualityPart[] = [];
    out.push({ label: 'FLAC', sec: flac, color: FLAC_C });
    out.push({ label: 'MP3', sec: mp3, color: MP3_C });
    out.push({ label: 'ALAC', sec: alac, color: ALAC_C });
    out.push({ label: 'AAC', sec: aac, color: AAC_C });
    if (other > 0) {
      out.push({ label: '其他', sec: other, color: OTHER_C });
    }
    return out;
  }

  private qualityKnownSec(): number {
    this.ensure();
    return this._cKnown;
  }

  private sumQuality(parts: QualityPart[]): number {
    let total: number = 0;
    for (let i = 0; i < parts.length; i++) {
      total += parts[i].sec;
    }
    return total;
  }

  private losslessSec(): number {
    this.ensure();
    return this._cLoss;
  }

  private buildLoss(all: TrackStat[]): number {
    let s: number = 0;
    for (let i = 0; i < all.length; i++) {
      if (this.isLossless(this.fmtOf(all[i]))) {
        s += all[i].seconds;
      }
    }
    return s;
  }

  private hiResSec(): number {
    this.ensure();
    return this._cHiRes;
  }

  private buildHiRes(all: TrackStat[]): number {
    let s: number = 0;
    for (let i = 0; i < all.length; i++) {
      const st: TrackStat = all[i];
      if (!this.isLossless(this.fmtOf(st))) {
        continue;
      }
      const bits: number = st.bitDepth === undefined ? 16 : st.bitDepth;
      const rate: number = st.samplingRate === undefined ? 44100 : st.samplingRate;
      if (bits >= 24 || rate > 48000) {
        s += st.seconds;
      }
    }
    return s;
  }

  private pct(part: number, whole: number): number {
    if (whole <= 0) {
      return 0;
    }
    return Math.round(part / whole * 100);
  }

  private specCells(): SpecCell[] {
    this.ensure();
    return this._cSpec;
  }

  /** 规格矩阵：2 位深 × 4 采样率，占比按已知音质的时长算 */
  private buildSpec(all: TrackStat[]): SpecCell[] {
    const bitsList: string[] = ['16 bit', '24 bit'];
    const khzList: string[] = ['44.1', '48', '96', '192'];
    const buckets: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
    let total: number = 0;
    for (let i = 0; i < all.length; i++) {
      const st: TrackStat = all[i];
      if (st.bitDepth === undefined || st.bitDepth <= 0) {
        continue;
      }
      const row: number = st.bitDepth >= 24 ? 1 : 0;
      const rate: number = st.samplingRate === undefined ? 44100 : st.samplingRate;
      let col: number = 3;
      if (rate <= 44100) {
        col = 0;
      } else if (rate <= 48000) {
        col = 1;
      } else if (rate <= 96000) {
        col = 2;
      }
      buckets[row * 4 + col] += st.seconds;
      total += st.seconds;
    }
    const out: SpecCell[] = [];
    for (let r = 0; r < 2; r++) {
      for (let c = 0; c < 4; c++) {
        out.push({
          bits: bitsList[r],
          khz: khzList[c],
          pct: this.pct(buckets[r * 4 + c], total)
        });
      }
    }
    return out;
  }

  /** 热度色：0% 空格，越高越接近品牌红 */
  private heatBg(p: number): string {
    if (p <= 0) {
      return this.isDark ? '#24252C' : '#EEEDF3';
    }
    const a: number = Math.round(Math.min(1, p / 45) * 0.88 * 255);
    const hex: string = a < 16 ? '0' + a.toString(16) : a.toString(16);
    return '#' + hex + (this.isDark ? 'E4596F' : 'B01F3B');
  }

  private heatInk(p: number): string {
    return p / 45 > 0.42 ? '#FFFFFF' : this.ink();
  }

  // ---------------- 排行与徽章 ----------------

  private artistRows(): RankRow[] {
    this.ensure();
    return this._cArtists;
  }

  private buildArtistRows(all: TrackStat[]): RankRow[] {
    const sums: Record<string, number> = {};
    let total: number = 0;
    for (let i = 0; i < all.length; i++) {
      const a: string = all[i].artist.length > 0 ? all[i].artist : '未知歌手';
      const old: number | undefined = sums[a];
      sums[a] = (old === undefined ? 0 : old) + all[i].seconds;
      total += all[i].seconds;
    }
    const names: string[] = Object.keys(sums);
    names.sort((x: string, y: string) => sums[y] - sums[x]);
    const out: RankRow[] = [];
    const n: number = Math.min(5, names.length);
    for (let i = 0; i < n; i++) {
      const name: string = names[i];
      out.push({
        name: name,
        sub: this.durText(sums[name]),
        value: this.pct(sums[name], total) + '%',
        pct: this.pct(sums[name], total)
      });
    }
    return out;
  }

  private badges(): BadgeCell[] {
    this.ensure();
    return this._cBadges;
  }

  private buildBadges(): BadgeCell[] {
    const totalSec: number = Store.get().listenTotalSeconds();
    const totalPlays: number = this.buildTotalPlays();
    const songs: number = Store.get().trackStatCount();
    const streak: number = this.buildStreak();
    const known: number = this._cKnown;
    const lossless: number = this._cLoss;
    const out: BadgeCell[] = [];
    out.push({ title: '初次聆听', sub: '完成第一次播放', got: totalPlays > 0, key: 'first' });
    out.push({ title: '十小时', sub: '累计听满 10 小时', got: totalSec >= 36000, key: 'ten' });
    out.push({ title: '五十小时', sub: '累计听满 50 小时', got: totalSec >= 180000, key: 'fifty' });
    out.push({ title: '百小时', sub: '累计听满 100 小时', got: totalSec >= 360000, key: 'hundred' });
    out.push({ title: '千次播放', sub: '累计播放 1000 次', got: totalPlays >= 1000, key: 'thousand' });
    out.push({ title: '五百首', sub: '听过 500 首不同的歌', got: songs >= 500, key: 'fivehundred' });
    out.push({ title: '连续七天', sub: '连续 7 天都有听歌', got: streak >= 7, key: 'streak' });
    out.push({ title: '无损爱好者', sub: '无损时长占比过半', got: known > 0 && lossless / known >= 0.5, key: 'hires' });
    return out;
  }

  private topFive(): TrackStat[] {
    this.ensure();
    return this._cAll.length > 5 ? this._cAll.slice(0, 5) : this._cAll;
  }

  // ---------------- 时间视角 ----------------

  private weekdaySums(): number[] {
    this.ensure();
    return this._cWeekday;
  }

  private buildWeekday(keys: string[]): number[] {
    const out: number[] = [0, 0, 0, 0, 0, 0, 0];
    for (let i = 0; i < keys.length; i++) {
      const d: Date = new Date(keys[i] + 'T00:00:00');
      const wd: number = (d.getDay() + 6) % 7;
      out[wd] += Store.get().listenSecondsOn(keys[i]);
    }
    return out;
  }

  private weekdayMax(): number {
    const arr: number[] = this.weekdaySums();
    let mx: number = 1;
    for (let i = 0; i < arr.length; i++) {
      if (arr[i] > mx) {
        mx = arr[i];
      }
    }
    return mx;
  }

  private weekdayH(v: number): number {
    const h: number = v / this.weekdayMax() * 100;
    return h < 3 ? 3 : h;
  }

  private bestWeekday(): string {
    const arr: number[] = this.weekdaySums();
    const names: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    let idx: number = 0;
    for (let i = 1; i < arr.length; i++) {
      if (arr[i] > arr[idx]) {
        idx = i;
      }
    }
    return arr[idx] > 0 ? names[idx] : '还没开始听';
  }

  // ---------------- 日历视角 ----------------

  private calRows(): CalCell[][] {
    this.ensure();
    return this._cCal;
  }

  private buildCalRows(): CalCell[][] {
    const a: Date = new Date(this.anchor);
    const y: number = a.getFullYear();
    const m: number = a.getMonth() + 1;
    const total: number = new Date(y, m, 0).getDate();
    const lead: number = (new Date(y, m - 1, 1).getDay() + 6) % 7;
    const todayK: string = this.todayKey();
    const cells: CalCell[] = [];
    for (let i = 0; i < lead; i++) {
      cells.push({ key: 'b' + i, day: 0, sec: 0, blank: true, today: false });
    }
    for (let d = 1; d <= total; d++) {
      const k: string = this.keyOf(new Date(y, m - 1, d));
      cells.push({ key: k, day: d, sec: Store.get().listenSecondsOn(k), blank: false, today: k === todayK });
    }
    while (cells.length % 7 !== 0) {
      cells.push({ key: 'e' + cells.length, day: 0, sec: 0, blank: true, today: false });
    }
    const rows: CalCell[][] = [];
    for (let r = 0; r < cells.length / 7; r++) {
      const row: CalCell[] = [];
      for (let c = 0; c < 7; c++) {
        row.push(cells[r * 7 + c]);
      }
      rows.push(row);
    }
    return rows;
  }

  private calMax(): number {
    this.ensure();
    return this._cCalMax;
  }

  private buildCalMax(): number {
    const a: Date = new Date(this.anchor);
    const keys: string[] = this.monthDays(a.getFullYear(), a.getMonth() + 1);
    let mx: number = 0;
    for (let i = 0; i < keys.length; i++) {
      const v: number = Store.get().listenSecondsOn(keys[i]);
      if (v > mx) {
        mx = v;
      }
    }
    return mx;
  }

  private selDayLabel(): string {
    if (this.selDay.length < 10) {
      return '选一天';
    }
    return this.selDay.substring(5, 7) + '月' + this.selDay.substring(8, 10) + '日';
  }

  private selDayPlays(): number {
    const v: number | undefined = Store.get().playsMap()[this.selDay];
    return v === undefined ? 0 : v;
  }

  // ---------------- 今日视角 ----------------

  private todayKey(): string {
    return Store.dayKey(new Date());
  }

  private weekPoints(): DayPoint[] {
    this.ensure();
    return this._cWeekPts;
  }

  private buildWeekPoints(): DayPoint[] {
    const s: Date = this.weekStart(new Date());
    const names: string[] = ['一', '二', '三', '四', '五', '六', '日'];
    const out: DayPoint[] = [];
    for (let i = 0; i < 7; i++) {
      const d: Date = this.addDays(s, i);
      const k: string = this.keyOf(d);
      out.push({ key: k, label: names[i], sec: Store.get().listenSecondsOn(k) });
    }
    return out;
  }

  private todayTracks(): TrackStat[] {
    this.ensure();
    return this._cToday;
  }

  private buildTodayTracks(): TrackStat[] {
    const start: number = this.startOfDay(new Date()).getTime();
    const out: TrackStat[] = [];
    for (let i = 0; i < this._cAll.length; i++) {
      if (this._cAll[i].lastAt >= start) {
        out.push(this._cAll[i]);
      }
    }
    out.sort((a: TrackStat, b: TrackStat) => b.seconds - a.seconds);
    return out;
  }

  private todayPlays(): number {
    const v: number | undefined = Store.get().playsMap()[this.todayKey()];
    return v === undefined ? 0 : v;
  }

  private weekBarH(sec: number): number {
    const pts: DayPoint[] = this.weekPoints();
    let mx: number = 600;
    for (let i = 0; i < pts.length; i++) {
      if (pts[i].sec > mx) {
        mx = pts[i].sec;
      }
    }
    const h: number = sec / mx * 76;
    return h < 3 ? 3 : h;
  }

  // ---------------- 报告视角 ----------------

  /** 报告固定看「锚点所在月」，不受统计页的周期选择影响 */
  private reportKeys(): string[] {
    const a: Date = new Date(this.anchor);
    return this.monthDays(a.getFullYear(), a.getMonth() + 1);
  }

  private reportStats(): TrackStat[] {
    return this.pickRange(this.reportKeys(), this.allStats());
  }

  private reportPoints(): DayPoint[] {
    const keys: string[] = this.reportKeys();
    const out: DayPoint[] = [];
    for (let i = 0; i < keys.length; i++) {
      out.push({
        key: keys[i],
        label: String(i + 1),
        sec: Store.get().listenSecondsOn(keys[i])
      });
    }
    return out;
  }

  private topTitle(): string {
    const arr: TrackStat[] = this.reportStats();
    if (arr.length === 0) {
      return '暂无记录';
    }
    let best: TrackStat = arr[0];
    for (let i = 1; i < arr.length; i++) {
      if (arr[i].plays > best.plays) {
        best = arr[i];
      }
    }
    return '《' + best.title + '》';
  }

  private topArtist(): string {
    const rows: RankRow[] = this.artistRows();
    return rows.length === 0 ? '暂无记录' : rows[0].name;
  }

  private topDayLabel(): string {
    const pts: DayPoint[] = this.reportPoints();
    let best: DayPoint | null = null;
    for (let i = 0; i < pts.length; i++) {
      if (best === null || pts[i].sec > best.sec) {
        best = pts[i];
      }
    }
    if (best === null || best.sec <= 0) {
      return '暂无记录';
    }
    return best.label + '，' + this.durText(best.sec);
  }

  // ---------------- 资料库视角 ----------------

  private totalListenSec(): number {
    return Store.get().listenTotalSeconds();
  }

  private pctWidth(p: number): string {
    const v: number = p < 4 ? 4 : p;
    return v + '%';
  }

  // ---------------- 页面骨架 ----------------

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.header()
        this.segmentBar()
        Scroll(this.scroller) {
          Column() {
            this.contentPanel()
            // 给底部悬浮的正在播放条留位
            Column().height(118)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        // 左右滑动切换一级分段。不用 Swiper：它会把五页内容全部挂进组件树，
        // 返回转场时整棵树参与合成，正是返回卡顿的主因。
        // 这里树上永远只有当前一页，滑动到位后带动画切换。
        .gesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 24 })
          .onActionEnd((e: GestureEvent) => {
            const dx: number = e.offsetX;
            if (dx < -56 && this.mode < 4) {
              this.switchTo(this.mode + 1);
            } else if (dx > 56 && this.mode > 0) {
              this.switchTo(this.mode - 1);
            }
          }))
      }
      .width('100%')
      .height('100%')

      this.nowBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  /**
   * 切换一级分段。
   *
   * 这里刻意不做过渡动画：之前用「旧页淡出 + 新页淡入」的交叉渐变，
   * 两层在同一位置叠加，录屏里就是明显的重影（日历格子压在统计卡片上）；
   * 而且整页透明度合成对这几百个节点每帧都要做一遍，滑一次掉一次帧。
   * 直接瞬切：旧页立即移除、新页直接渲染，没有叠影，也没有额外合成。
   */
  private switchTo(next: number): void {
    if (next === this.mode || next < 0 || next > 4) {
      return;
    }
    this.mode = next;
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }

  /** 当前分段的内容，条件渲染——组件树里只有一页 */
  @Builder
  contentPanel() {
    if (this.mode === 0) {
      Column() { this.todayPanel() }
        .width('100%')
    } else if (this.mode === 1) {
      Column() { this.calendarPanel() }
        .width('100%')
    } else if (this.mode === 2) {
      Column() {
        this.periodRow()
        this.subTabs()
        if (this.sub === 0) {
          this.overviewPanel()
        } else if (this.sub === 1) {
          this.timePanel()
        } else if (this.sub === 2) {
          this.tastePanel()
        } else if (this.sub === 3) {
          this.qualityPanel()
        } else {
          this.libraryPanel()
        }
      }
      .width('100%')
    } else if (this.mode === 3) {
      Column() { this.badgePanel() }
        .width('100%')
    } else {
      Column() { this.reportPanel() }
        .width('100%')
    }
  }

  @Builder
  header() {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        Image(this.isDark ? $r('app.media.ic_back') : $r('app.media.ic_back_d'))
          .width(19).height(19)
      }
      .width(38).height(38)
      .borderRadius(19)
      .backgroundColor(this.cardBg())
      .onClick(() => { Router.back(); })

      Text('听歌统计')
        .fontSize(17).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
        .fontColor(this.ink())
        .textAlign(TextAlign.Center)
        .layoutWeight(1)

      Stack({ alignContent: Alignment.Center }) {
        Image(this.isDark ? $r('app.media.ic_settings') : $r('app.media.ic_settings_d'))
          .width(20).height(20)
      }
      .width(38).height(38)
      .borderRadius(19)
      .backgroundColor(this.cardBg())
      .onClick(() => { Router.push('pages/Settings'); })
    }
    .width('100%')
    .height(50 + topInset())
    .padding({ left: 18, right: 18, top: topInset() })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  segmentBar() {
    Column() {
      Row() {
        ForEach(SEGS, (label: string, idx: number) => {
          Text(label)
            .fontSize(12.5).fontFamily(APP_FONT)
            .fontWeight(this.mode === idx ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.mode === idx ? this.ink() : this.subText())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(29)
            .borderRadius(9)
            .backgroundColor(this.mode === idx ? this.cardBg() : Color.Transparent)
            .onClick(() => { this.switchTo(idx); })
        }, (label: string) => label)
      }
      .width('100%')
      .padding(3)
      .backgroundColor(this.trackBg())
      .borderRadius(12)
    }
    .width('100%')
    .padding({ left: 18, right: 18 })
  }

  @Builder
  periodRow() {
    Row() {
      Row() {
        Image(this.isDark ? $r('app.media.ic_back') : $r('app.media.ic_back_d'))
          .width(14).height(14)
          .opacity(this.period === 3 ? 0.25 : 0.75)
          .onClick(() => { this.shiftPeriod(-1); })
        Text(this.periodLabel())
          .fontSize(13.5).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
          .fontColor(this.ink())
          .margin({ left: 8, right: 8 })
        Stack({ alignContent: Alignment.Center }) {
          Image(this.isDark ? $r('app.media.ic_back') : $r('app.media.ic_back_d'))
            .width(14).height(14)
            .rotate({ angle: 180 })
        }
        .opacity(this.period === 3 ? 0.25 : 0.75)
        .onClick(() => { this.shiftPeriod(1); })
      }
      .alignItems(VerticalAlign.Center)
      .layoutWeight(1)

      Row() {
        ForEach(PERIODS, (p: string, idx: number) => {
          Text(p)
            .fontSize(12.5).fontFamily(APP_FONT)
            .fontWeight(this.period === idx ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.period === idx ? this.accent() : this.subText())
            .margin({ left: 9, right: 9 })
            .onClick(() => { this.period = idx; })
        }, (p: string) => p)
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 16, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  subTabs() {
    Column() {
      Row() {
        ForEach(SUBS, (label: string, idx: number) => {
          Column() {
            Text(label)
              .fontSize(13).fontFamily(APP_FONT)
              .fontWeight(this.sub === idx ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.sub === idx ? this.ink() : this.subText())
            Column()
              .width(18).height(2.5)
              .borderRadius(2)
              .backgroundColor(this.sub === idx ? this.accent() : Color.Transparent)
              .margin({ top: 6 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 10, bottom: 7 })
          .onClick(() => { this.sub = idx; })
        }, (label: string) => label)
      }
      .width('100%')
      Column().width('100%').height(0.5).backgroundColor(this.divider())
    }
    .width('100%')
    .padding({ left: 8, right: 8 })
    .margin({ top: 4 })
  }

  // ---------------- 总览 ----------------

  @Builder
  overviewPanel() {
    Column() {
      Row() {
        this.statCard('听歌时长', this.bigTime(this.sumSec(this.rangeKeys())).v,
          this.bigTime(this.sumSec(this.rangeKeys())).u,
          this.cmpText(this.sumSec(this.rangeKeys()), this.sumSec(this.prevKeys())),
          this.spark(this.points()))
        Column().width(10)
        this.statCard('播放次数', String(this.playsForPeriod()), '',
          this.period === 3 ? '累计播放次数'
            : this.cmpText(this.sumPlays(this.rangeKeys()), this.sumPlays(this.prevKeys())),
          this.spark(this.points()))
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Column().height(10)

      Row() {
        this.statCard('歌曲', String(this.songCount(this.rangeStats())), '首',
          this.artistCount(this.rangeStats()) + ' 位艺人',
          this.spark(this.points()))
        Column().width(10)
        this.statCard('天数', String(this.activeDays(this.rangeKeys())), '天',
          this.period === 3 ? '累计有记录的天数'
            : this.cmpText(this.activeDays(this.rangeKeys()), this.activeDays(this.prevKeys())),
          this.spark(this.points()))
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Column().height(10)
      this.dailyCard()
      if (this.period !== 3) {
        Column().height(10)
        this.compareCard()
      }
      Column().height(10)
      this.topCard()
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12 })
  }

  /** 全部周期用单曲累计次数（历史完整）；周/月/年用按天计数 */
  private playsForPeriod(): number {
    if (this.period === 3) {
      return this.totalTrackPlays();
    }
    return this.sumPlays(this.rangeKeys());
  }

  @Builder
  statCard(label: string, value: string, unit: string, sub: string, series: number[]) {
    Column() {
      Text(label)
        .fontSize(11.5).fontFamily(APP_FONT).fontColor(this.subText())
        .maxLines(1)

      Row() {
        Text(value)
          .fontSize(25).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
          .maxLines(1)
        if (unit.length > 0) {
          Text(unit)
            .fontSize(11).fontFamily(APP_FONT).fontColor(this.subText())
            .margin({ left: 2, bottom: 3 })
        }
        Row().layoutWeight(1)
        this.sparkBars(series)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 2 })

      Text(sub)
        .fontSize(10.5).fontFamily(APP_FONT).fontColor(this.faintText())
        .maxLines(1)
        .margin({ top: 3 })
    }
    .layoutWeight(1)
    .padding({ left: 14, right: 12, top: 12, bottom: 12 })
    .backgroundColor(this.cardBg())
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  /** 卡片里的迷你趋势：7 根细柱，末位用品牌色做「当前」落点 */
  @Builder
  sparkBars(series: number[]) {
    Row() {
      ForEach(series, (v: number, idx: number) => {
        Column()
          .width(2.6)
          .height(this.sparkH(v, series))
          .borderRadius(1.3)
          .backgroundColor(idx === series.length - 1 ? this.accent() : this.barIdle())
          .margin({ left: 1.6 })
      }, (v: number, idx: number) => idx.toString() + '-' + v)
    }
    .height(20)
    .alignItems(VerticalAlign.Bottom)
    .margin({ left: 4 })
  }

  @Builder
  dailyCard() {
    Column() {
      Row() {
        Text('每天听了多久')
          .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
        Row().layoutWeight(1)
        Text(this.period === 3 ? '近 30 天' : '平均 ' + this.durText(this.avgPerActiveDay()))
          .fontSize(10.5).fontFamily(APP_FONT).fontColor(this.subText())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Column() {
          Text(this.durShort(this.chartTop()))
            .fontSize(9).fontFamily(APP_FONT).fontColor(this.faintText())
          Text(this.durShort(this.chartTop() / 2))
            .fontSize(9).fontFamily(APP_FONT).fontColor(this.faintText())
          Text('0')
            .fontSize(9).fontFamily(APP_FONT).fontColor(this.faintText())
        }
        .height(104)
        .width(34)
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(HorizontalAlign.Start)

        Stack({ alignContent: Alignment.BottomStart }) {
          Column() {
            Column().width('100%').height(0.5).backgroundColor(this.divider())
            Column().width('100%').height(0.5).backgroundColor(this.divider())
            Column().width('100%').height(0.5).backgroundColor(this.divider())
          }
          .width('100%').height(104)
          .justifyContent(FlexAlign.SpaceBetween)

          Row() {
            ForEach(this.points(), (p: DayPoint) => {
              Column() {
                Column()
                  .width('56%')
                  .height(this.barH(p.sec))
                  .borderRadius(2.5)
                  .backgroundColor(p.sec >= this.maxDaySec() && p.sec > 0 ? this.accent() : this.barIdle())
              }
              .layoutWeight(1)
              .height(104)
              .justifyContent(FlexAlign.End)
              .alignItems(HorizontalAlign.Center)
            }, (p: DayPoint) => p.key)
          }
          .width('100%')
          .height(104)
          .alignItems(VerticalAlign.Bottom)
        }
        .layoutWeight(1)
        .height(104)
      }
      .width('100%')
      .margin({ top: 14 })

      Row() {
        ForEach(this.axisLabels(), (s: string) => {
          Text(s)
            .fontSize(9).fontFamily(APP_FONT).fontColor(this.faintText())
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
        }, (s: string, i: number) => s + i.toString())
      }
      .width('100%')
      .padding({ left: 34 })
      .margin({ top: 6 })

      Row() {
        Text('单日最多')
          .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
        Text(this.durText(this.maxDaySec()))
          .fontSize(10).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
          .fontColor(this.accent())
          .margin({ left: 4 })
        Row().layoutWeight(1)
        Text(this.songCount(this.rangeStats()) + ' 首曲目')
          .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
      }
      .width('100%').margin({ top: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.cardBg())
    .borderRadius(16)
  }

  @Builder
  compareCard() {
    Column() {
      Row() {
        Text('和上期比')
          .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
        Row().layoutWeight(1)
        Text(this.cmpText(this.sumSec(this.rangeKeys()), this.sumSec(this.prevKeys())))
          .fontSize(10.5).fontFamily(APP_FONT).fontColor(this.subText())
      }
      .width('100%')

      Row() {
        Text('上期 ' + this.durText(this.sumSec(this.prevKeys())))
          .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
        Row().layoutWeight(1)
        Text('本期 ' + this.durText(this.sumSec(this.rangeKeys())))
          .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
      }
      .width('100%')
      .margin({ top: 3 })

      // 周期 / 锚点 / 主题任一变化都重建 Canvas，保证曲线跟着重画
      Column() {
        ForEach([this.period.toString() + '|' + this.anchor.toString() + '|' + this.isDark],
          (k: string) => {
            Canvas(this.areaCtx)
              .width('100%')
              .height(64)
              .onReady(() => { this.drawArea(); })
          }, (k: string) => k)
      }
      .width('100%')
      .height(64)
      .margin({ top: 10 })

      Row() {
        Text(this.period === 0 ? '周一' : '起始')
          .fontSize(9).fontFamily(APP_FONT).fontColor(this.faintText())
        Row().layoutWeight(1)
        Text(this.period === 0 ? '周日' : '至今')
          .fontSize(9).fontFamily(APP_FONT).fontColor(this.faintText())
      }
      .width('100%')
      .margin({ top: 2 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.cardBg())
    .borderRadius(16)
  }

  /** 本期累计曲线：面积图的数据源 */
  private areaSeries(): number[] {
    const pts: DayPoint[] = this.points();
    const out: number[] = [];
    let sum: number = 0;
    for (let i = 0; i < pts.length; i++) {
      sum += pts[i].sec;
      out.push(sum);
    }
    return out;
  }

  private drawArea(): void {
    const ctx: CanvasRenderingContext2D = this.areaCtx;
    const w: number = ctx.width;
    const h: number = ctx.height;
    ctx.clearRect(0, 0, w, h);
    const pts: number[] = this.areaSeries();
    if (pts.length < 2 || w <= 0) {
      return;
    }
    let mx: number = 1;
    for (let i = 0; i < pts.length; i++) {
      if (pts[i] > mx) {
        mx = pts[i];
      }
    }
    const step: number = (w - 2) / (pts.length - 1);
    const top: number = 6;
    const usable: number = h - top - 2;
    // 先铺一条渐变面，再压一条 1.6vp 的实线
    ctx.beginPath();
    ctx.moveTo(0, h);
    for (let i = 0; i < pts.length; i++) {
      const x: number = i * step;
      const y: number = h - 2 - pts[i] / mx * usable;
      ctx.lineTo(x, y);
    }
    ctx.lineTo((pts.length - 1) * step, h);
    ctx.closePath();
    const g: CanvasGradient = ctx.createLinearGradient(0, top, 0, h);
    g.addColorStop(0, this.isDark ? 'rgba(228,89,111,0.30)' : 'rgba(176,31,59,0.22)');
    g.addColorStop(1, this.isDark ? 'rgba(228,89,111,0.02)' : 'rgba(176,31,59,0.01)');
    ctx.fillStyle = g;
    ctx.fill();

    ctx.beginPath();
    for (let i = 0; i < pts.length; i++) {
      const x: number = i * step;
      const y: number = h - 2 - pts[i] / mx * usable;
      if (i === 0) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.strokeStyle = this.isDark ? 'rgba(228,89,111,0.95)' : 'rgba(176,31,59,0.9)';
    ctx.lineWidth = 1.6;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.stroke();
  }

  @Builder
  topCard() {
    Column() {
      Row() {
        Text('最常播放')
          .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
        Row().layoutWeight(1)
        Text('TOP 5')
          .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
      }
      .width('100%')

      if (this.topFive().length === 0) {
        Text('还没有播放记录，听几首歌就会出现在这里')
          .fontSize(11.5).fontFamily(APP_FONT).fontColor(this.faintText())
          .width('100%').margin({ top: 12 })
      } else {
        ForEach(this.topFive(), (st: TrackStat, idx: number) => {
          Row() {
            Text(String(idx + 1))
              .fontSize(11).fontFamily(APP_FONT_BOLD)
              .fontColor(idx === 0 ? this.accent() : this.faintText())
              .width(18)
            Column() {
              Text(st.title)
                .fontSize(13).fontFamily(APP_FONT).fontColor(this.ink())
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text((st.artist.length > 0 ? st.artist : '未知歌手') + ' · ' + this.durText(st.seconds))
                .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 1 })
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 6 })
            Text(st.plays + ' 次')
              .fontSize(11).fontFamily(APP_FONT).fontColor(this.subText())
          }
          .width('100%')
          .margin({ top: idx === 0 ? 12 : 10 })
          .alignItems(VerticalAlign.Center)
        }, (st: TrackStat) => st.id)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.cardBg())
    .borderRadius(16)
  }

  // ---------------- 时间 ----------------

  @Builder
  timePanel() {
    Column() {
      Column() {
        Text('一周里什么时候听')
          .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
        Text('把选中的周期按星期几摊开，看你的听歌节奏')
          .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
          .margin({ top: 3 })

        Row() {
          ForEach(['一', '二', '三', '四', '五', '六', '日'], (w: string, idx: number) => {
            Column() {
              Column()
                .width('52%')
                .height(this.weekdayH(this.weekdaySums()[idx]))
                .borderRadius(3)
                .backgroundColor(this.weekdaySums()[idx] >= this.weekdayMax()
                  && this.weekdaySums()[idx] > 0 ? this.accent() : this.barIdle())
            }
            .layoutWeight(1)
            .height(104)
            .justifyContent(FlexAlign.End)
            .alignItems(HorizontalAlign.Center)
          }, (w: string) => w)
        }
        .width('100%')
        .height(104)
        .margin({ top: 16 })
        .alignItems(VerticalAlign.Bottom)

        Row() {
          ForEach(['一', '二', '三', '四', '五', '六', '日'], (w: string) => {
            Text(w)
              .fontSize(9.5).fontFamily(APP_FONT).fontColor(this.faintText())
              .layoutWeight(1).textAlign(TextAlign.Center)
          }, (w: string) => w)
        }
        .width('100%')
        .margin({ top: 6 })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.cardBg())
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)

      Column().height(10)

      Column() {
        Text('节奏')
          .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
        this.infoRow('最活跃的一天', this.bestWeekday())
        this.infoRow('有听歌的天数', this.activeDays(this.rangeKeys()) + ' / ' + this.rangeKeys().length + ' 天')
        this.infoRow('平均每天', this.durText(this.sumSec(this.rangeKeys()) / Math.max(1, this.rangeKeys().length)))
        this.infoRow('本周期合计', this.durText(this.sumSec(this.rangeKeys())))
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.cardBg())
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12 })
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12).fontFamily(APP_FONT).fontColor(this.subText())
      Row().layoutWeight(1)
      Text(value)
        .fontSize(12.5).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
        .fontColor(this.ink())
    }
    .width('100%')
    .padding({ top: 12, bottom: 2 })
    .alignItems(VerticalAlign.Center)
  }

  // ---------------- 口味 ----------------

  @Builder
  tastePanel() {
    Column() {
      Column() {
        Row() {
          Text('常听歌手')
            .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Bold)
            .fontColor(this.ink())
          Row().layoutWeight(1)
          Text('按时长')
            .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
        }
        .width('100%')

        if (this.artistRows().length === 0) {
          Text('还没有足够的播放记录')
            .fontSize(11.5).fontFamily(APP_FONT).fontColor(this.faintText())
            .width('100%').margin({ top: 12 })
        } else {
          ForEach(this.artistRows(), (r: RankRow, idx: number) => {
            Column() {
              Row() {
                Text(String(idx + 1))
                  .fontSize(11).fontFamily(APP_FONT_BOLD)
                  .fontColor(idx === 0 ? this.accent() : this.faintText())
                  .width(18)
                Text(r.name)
                  .fontSize(13).fontFamily(APP_FONT).fontColor(this.ink())
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1).margin({ left: 6 })
                Text(r.value)
                  .fontSize(11).fontFamily(APP_FONT).fontColor(this.subText())
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Stack({ alignContent: Alignment.Start }) {
                Column().width('100%').height(3).borderRadius(2).backgroundColor(this.barIdle())
                Column().width(this.pctWidth(r.pct)).height(3).borderRadius(2)
                  .backgroundColor(this.accent()).opacity(idx === 0 ? 1 : 0.55)
              }
              .width('100%').height(3).margin({ top: 7 })
            }
            .width('100%')
            .margin({ top: 13 })
          }, (r: RankRow) => r.name)
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.cardBg())
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)

      Column().height(10)

      Column() {
        Text('常听单曲')
          .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
        ForEach(this.topFive(), (st: TrackStat, idx: number) => {
          Row() {
            Text(String(idx + 1))
              .fontSize(11).fontFamily(APP_FONT_BOLD)
              .fontColor(idx === 0 ? this.accent() : this.faintText())
              .width(18)
            Column() {
              Text(st.title)
                .fontSize(13).fontFamily(APP_FONT).fontColor(this.ink())
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(st.artist.length > 0 ? st.artist : '未知歌手')
                .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 1 })
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 6 })
            Text(st.plays + ' 次')
              .fontSize(11).fontFamily(APP_FONT).fontColor(this.subText())
          }
          .width('100%')
          .margin({ top: idx === 0 ? 12 : 10 })
          .alignItems(VerticalAlign.Center)
        }, (st: TrackStat) => st.id)
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.cardBg())
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12 })
  }

  // ---------------- 音质 ----------------

  @Builder
  qualityPanel() {
    Column() {
      if (this.qualityKnownSec() <= 0) {
        Column() {
          Text('还没有音质记录')
            .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
            .fontColor(this.ink())
          Text('播放几首歌之后，这里会按格式、位深和采样率统计你听了多久。')
            .fontSize(11.5).fontFamily(APP_FONT).fontColor(this.faintText())
            .margin({ top: 6 })
            .lineHeight(18)
        }
        .width('100%')
        .padding(20)
        .backgroundColor(this.cardBg())
        .borderRadius(16)
        .alignItems(HorizontalAlign.Start)
      } else {
        Column() {
          Row() {
            Column() {
              Text(this.pct(this.losslessSec(), this.qualityKnownSec()) + '%')
                .fontSize(32).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Bold)
                .fontColor(this.ink())
              Text('无损时长占比')
                .fontSize(10.5).fontFamily(APP_FONT).fontColor(this.subText())
                .margin({ top: 2 })
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start)

            Column() {
              Text(this.pct(this.hiResSec(), this.qualityKnownSec()) + '%')
                .fontSize(32).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Bold)
                .fontColor(this.ink())
              Text('Hi-Res 时长占比')
                .fontSize(10.5).fontFamily(APP_FONT).fontColor(this.subText())
                .margin({ top: 2 })
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start)
          }
          .width('100%')

          // 堆叠条：每段按时长占比分配宽度
          Row() {
            ForEach(this.qualityParts(), (q: QualityPart) => {
              if (q.sec > 0) {
                Stack({ alignContent: Alignment.Center }) {
                  Row()
                    .width('100%').height(26)
                    .backgroundColor(q.color)
                  if (this.pct(q.sec, this.qualityKnownSec()) >= 10) {
                    Text(this.pct(q.sec, this.qualityKnownSec()) + '%')
                      .fontSize(10.5).fontFamily(APP_FONT_BOLD)
                      .fontColor('#FFFFFF')
                  }
                }
                .layoutWeight(Math.max(1, this.pct(q.sec, this.qualityKnownSec())))
                .height(26)
              }
            }, (q: QualityPart) => q.label)
          }
          .width('100%')
          .height(26)
          .borderRadius(6)
          .clip(true)
          .margin({ top: 14 })

          Row() {
            ForEach(this.qualityParts(), (q: QualityPart) => {
              if (q.sec > 0) {
                Row() {
                  Column().width(6).height(6).borderRadius(3).backgroundColor(q.color)
                  Text(q.label)
                    .fontSize(9.5).fontFamily(APP_FONT).fontColor(this.subText())
                    .margin({ left: 4 })
                }
                .margin({ right: 10 })
                .alignItems(VerticalAlign.Center)
              }
            }, (q: QualityPart) => q.label)
          }
          .width('100%')
          .margin({ top: 10 })
        }
        .width('100%')
        .padding(16)
        .backgroundColor(this.cardBg())
        .borderRadius(16)
        .alignItems(HorizontalAlign.Start)

        Column().height(10)

        Column() {
          Row() {
            Text('规格')
              .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Bold)
              .fontColor(this.ink())
            Row().layoutWeight(1)
            Text('kHz × bit')
              .fontSize(9.5).fontFamily(APP_FONT).fontColor(this.faintText())
          }
          .width('100%')

          Row() {
            Text('')
              .width(34)
            ForEach(['44.1', '48', '96', '192'], (k: string) => {
              Text(k)
                .fontSize(9.5).fontFamily(APP_FONT).fontColor(this.faintText())
                .layoutWeight(1).textAlign(TextAlign.Center)
            }, (k: string) => k)
          }
          .width('100%')
          .margin({ top: 12 })

          ForEach(['16 bit', '24 bit'], (bits: string, row: number) => {
            Row() {
              Text(bits)
                .fontSize(9.5).fontFamily(APP_FONT).fontColor(this.faintText())
                .width(34)
              ForEach(this.specCells(), (c: SpecCell) => {
                if (c.bits === bits) {
                  Stack({ alignContent: Alignment.Center }) {
                    Row()
                      .width('100%').height(40)
                      .borderRadius(5)
                      .backgroundColor(this.heatBg(c.pct))
                    if (c.pct > 0) {
                      Text(c.pct + '%')
                        .fontSize(10.5).fontFamily(APP_FONT_BOLD)
                        .fontColor(this.heatInk(c.pct))
                    }
                  }
                  .layoutWeight(1)
                  .height(40)
                  .margin({ left: 3 })
                }
              }, (c: SpecCell) => c.bits + c.khz)
            }
            .width('100%')
            .margin({ top: 6 })
          }, (bits: string) => bits)

          Text('仅统计带位深 / 采样率信息的曲目，按累计收听时长加权')
            .fontSize(9.5).fontFamily(APP_FONT).fontColor(this.faintText())
            .margin({ top: 12 })
            .lineHeight(15)
        }
        .width('100%')
        .padding(16)
        .backgroundColor(this.cardBg())
        .borderRadius(16)
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12 })
  }

  // ---------------- 资料库 ----------------

  @Builder
  libraryPanel() {
    Column() {
      Column() {
        Text('资料库')
          .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
        Row() {
          this.libCell('统计曲目', String(Store.get().trackStatCount()), '首')
          this.libCell('艺人', String(this.artistCount(this.allStats())), '位')
        }
        .width('100%').margin({ top: 14 })
        Row() {
          this.libCell('累计播放', String(this.totalTrackPlays()), '次')
          this.libCell('缓存曲目', String(Store.get().cachedCount), '首')
        }
        .width('100%').margin({ top: 14 })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.cardBg())
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)

      Column().height(10)

      Column() {
        Row() {
          Text('音质信息覆盖')
            .fontSize(13).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
            .fontColor(this.ink())
          Row().layoutWeight(1)
          Text(this.pct(this.qualityKnownSec(), this.totalListenSec()) + '%')
            .fontSize(12).fontFamily(APP_FONT).fontColor(this.accent())
        }
        .width('100%')
        Stack({ alignContent: Alignment.Start }) {
          Column().width('100%').height(5).borderRadius(3).backgroundColor(this.barIdle())
          Column().width(this.pctWidth(this.pct(this.qualityKnownSec(), this.totalListenSec())))
            .height(5).borderRadius(3).backgroundColor(this.accent())
        }
        .width('100%').height(5).margin({ top: 10 })
        Text('有些老记录只存了时长，没有格式与规格；重新播放一次就会补上。')
          .fontSize(9.5).fontFamily(APP_FONT).fontColor(this.faintText())
          .margin({ top: 10 }).lineHeight(15)
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.cardBg())
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12 })
  }

  @Builder
  libCell(label: string, value: string, unit: string) {
    Column() {
      Text(label)
        .fontSize(10.5).fontFamily(APP_FONT).fontColor(this.subText())
      Row() {
        Text(value)
          .fontSize(21).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
        Text(unit)
          .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
          .margin({ left: 2, bottom: 2 })
      }
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  // ---------------- 今日 ----------------

  @Builder
  todayPanel() {
    Column() {
      Column() {
        Text('今天')
          .fontSize(11.5).fontFamily(APP_FONT).fontColor(this.subText())
        Row() {
          Text(this.bigTime(Store.get().listenSecondsOn(this.todayKey())).v)
            .fontSize(40).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Bold)
            .fontColor(this.ink())
          Text(this.bigTime(Store.get().listenSecondsOn(this.todayKey())).u)
            .fontSize(13).fontFamily(APP_FONT).fontColor(this.subText())
            .margin({ left: 4, bottom: 6 })
        }
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 2 })

        Row() {
          this.todayMini('播放', this.todayPlays() + ' 次')
          this.todayMini('曲目', this.todayTracks().length + ' 首')
          this.todayMini('连续', this.streakDays() + ' 天')
        }
        .width('100%')
        .margin({ top: 16 })
      }
      .width('100%')
      .padding(18)
      .backgroundColor(this.cardBg())
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)

      Column().height(10)

      Column() {
        Row() {
          Text('最近 7 天')
            .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Bold)
            .fontColor(this.ink())
          Row().layoutWeight(1)
          Text('周一起算')
            .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
        }
        .width('100%')

        Row() {
          ForEach(this.weekPoints(), (p: DayPoint) => {
            Column() {
              Column()
                .width('56%')
                .height(this.weekBarH(p.sec))
                .borderRadius(3)
                .backgroundColor(p.key === this.todayKey() ? this.accent() : this.barIdle())
              Text(p.label)
                .fontSize(9).fontFamily(APP_FONT)
                .fontColor(p.key === this.todayKey() ? this.accent() : this.faintText())
                .margin({ top: 6 })
            }
            .layoutWeight(1)
            .height(92)
            .justifyContent(FlexAlign.End)
            .alignItems(HorizontalAlign.Center)
          }, (p: DayPoint) => p.key)
        }
        .width('100%')
        .height(112)
        .margin({ top: 14 })
        .alignItems(VerticalAlign.Bottom)
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.cardBg())
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)

      Column().height(10)

      Column() {
        Row() {
          Text('今天在听')
            .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Bold)
            .fontColor(this.ink())
          Row().layoutWeight(1)
          Text(this.todayTracks().length > 0 ? '按收听时长' : '')
            .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
        }
        .width('100%')

        if (this.todayTracks().length === 0) {
          Text('今天还没有播放记录')
            .fontSize(11.5).fontFamily(APP_FONT).fontColor(this.faintText())
            .width('100%').margin({ top: 12 })
        } else {
          ForEach(this.todayTracks().slice(0, 5), (st: TrackStat, idx: number) => {
            Row() {
              Text(String(idx + 1))
                .fontSize(11).fontFamily(APP_FONT_BOLD)
                .fontColor(idx === 0 ? this.accent() : this.faintText())
                .width(18)
              Column() {
                Text(st.title)
                  .fontSize(13).fontFamily(APP_FONT).fontColor(this.ink())
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(st.artist.length > 0 ? st.artist : '未知歌手')
                  .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 1 })
              }
              .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 6 })
              Text(this.durText(st.seconds))
                .fontSize(11).fontFamily(APP_FONT).fontColor(this.subText())
            }
            .width('100%')
            .margin({ top: idx === 0 ? 12 : 10 })
            .alignItems(VerticalAlign.Center)
          }, (st: TrackStat) => st.id)
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.cardBg())
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12 })
  }

  @Builder
  todayMini(label: string, value: string) {
    Column() {
      Text(label)
        .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
      Text(value)
        .fontSize(13).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
        .fontColor(this.ink())
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  // ---------------- 日历 ----------------

  @Builder
  calendarPanel() {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          Image(this.isDark ? $r('app.media.ic_back') : $r('app.media.ic_back_d'))
            .width(15).height(15)
        }
        .width(30).height(30)
        .onClick(() => {
          const a: Date = new Date(this.anchor);
          this.anchor = new Date(a.getFullYear(), a.getMonth() - 1, 1).getTime();
          this.selDay = Store.dayKey(new Date(this.anchor));
        })

        Text(new Date(this.anchor).getFullYear() + '年' + (new Date(this.anchor).getMonth() + 1) + '月')
          .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
          .fontColor(this.ink())
          .layoutWeight(1).textAlign(TextAlign.Center)

        Stack({ alignContent: Alignment.Center }) {
          Image(this.isDark ? $r('app.media.ic_back') : $r('app.media.ic_back_d'))
            .width(15).height(15)
            .rotate({ angle: 180 })
        }
        .width(30).height(30)
        .onClick(() => {
          const a: Date = new Date(this.anchor);
          this.anchor = new Date(a.getFullYear(), a.getMonth() + 1, 1).getTime();
          this.selDay = Store.dayKey(new Date(this.anchor));
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        ForEach(['一', '二', '三', '四', '五', '六', '日'], (w: string) => {
          Text(w)
            .fontSize(9.5).fontFamily(APP_FONT).fontColor(this.faintText())
            .layoutWeight(1).textAlign(TextAlign.Center)
        }, (w: string) => w)
      }
      .width('100%')
      .margin({ top: 16 })

      ForEach(this.calRows(), (row: CalCell[], ri: number) => {
        Row() {
          ForEach(row, (c: CalCell) => {
            Stack({ alignContent: Alignment.Center }) {
              if (!c.blank) {
                Column()
                  .width('100%').height(36)
                  .borderRadius(7)
                  .backgroundColor(c.sec > 0
                    ? this.heatBg(Math.round(c.sec / Math.max(1, this.calMax()) * 50))
                    : this.trackBg())
                Text(String(c.day))
                  .fontSize(11).fontFamily(APP_FONT)
                  .fontColor(c.sec > 0 && c.sec / Math.max(1, this.calMax()) > 0.5
                    ? '#FFFFFF' : this.subText())
                if (c.today) {
                  Column()
                    .width('100%').height(36)
                    .borderRadius(7)
                    .border({ width: 1.5, color: this.accent() })
                }
                if (c.key === this.selDay) {
                  Column()
                    .width('100%').height(36)
                    .borderRadius(7)
                    .border({ width: 1.5, color: this.ink() })
                }
              }
            }
            .layoutWeight(1)
            .height(36)
            .margin({ left: 2, right: 2 })
            .onClick(() => {
              if (!c.blank) {
                this.selDay = c.key;
              }
            })
          }, (c: CalCell) => c.key)
        }
        .width('100%')
        .margin({ top: ri === 0 ? 10 : 6 })
      }, (row: CalCell[], ri: number) => 'row' + ri.toString())

      Column() {
        Row() {
          Text(this.selDayLabel())
            .fontSize(12.5).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
            .fontColor(this.ink())
          Row().layoutWeight(1)
          Text(this.durText(Store.get().listenSecondsOn(this.selDay)))
            .fontSize(15).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Bold)
            .fontColor(this.accent())
        }
        .width('100%')
        Row() {
          Text('播放 ' + this.selDayPlays() + ' 次')
            .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
          Row().layoutWeight(1)
          Text(this.selDay.length > 0 && this.selDay === this.todayKey() ? '今天' : '')
            .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
        }
        .width('100%').margin({ top: 6 })
      }
      .width('100%')
      .padding(14)
      .backgroundColor(this.cardBg())
      .borderRadius(14)
      .margin({ top: 14 })
      .alignItems(HorizontalAlign.Start)

      Text('颜色越深听得越久；点击某天查看当天时长')
        .fontSize(9.5).fontFamily(APP_FONT).fontColor(this.faintText())
        .margin({ top: 10 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14 })
  }

  // ---------------- 徽章 ----------------

  private badgeOn(): number {
    const arr: BadgeCell[] = this.badges();
    let n: number = 0;
    for (let i = 0; i < arr.length; i++) {
      if (arr[i].got) {
        n++;
      }
    }
    return n;
  }

  /** 徽章图标：未点亮灰色版，点亮按深浅色主题取两档红 */
  private badgeIcon(key: string, got: boolean): Resource {
    if (key === 'ten') {
      return !got ? $r('app.media.ic_badge_ten_g')
        : (this.isDark ? $r('app.media.ic_badge_ten_on_d') : $r('app.media.ic_badge_ten_on'));
    }
    if (key === 'fifty') {
      return !got ? $r('app.media.ic_badge_fifty_g')
        : (this.isDark ? $r('app.media.ic_badge_fifty_on_d') : $r('app.media.ic_badge_fifty_on'));
    }
    if (key === 'hundred') {
      return !got ? $r('app.media.ic_badge_hundred_g')
        : (this.isDark ? $r('app.media.ic_badge_hundred_on_d') : $r('app.media.ic_badge_hundred_on'));
    }
    if (key === 'thousand') {
      return !got ? $r('app.media.ic_badge_thousand_g')
        : (this.isDark ? $r('app.media.ic_badge_thousand_on_d') : $r('app.media.ic_badge_thousand_on'));
    }
    if (key === 'fivehundred') {
      return !got ? $r('app.media.ic_badge_fivehundred_g')
        : (this.isDark ? $r('app.media.ic_badge_fivehundred_on_d') : $r('app.media.ic_badge_fivehundred_on'));
    }
    if (key === 'streak') {
      return !got ? $r('app.media.ic_badge_streak_g')
        : (this.isDark ? $r('app.media.ic_badge_streak_on_d') : $r('app.media.ic_badge_streak_on'));
    }
    if (key === 'hires') {
      return !got ? $r('app.media.ic_badge_hires_g')
        : (this.isDark ? $r('app.media.ic_badge_hires_on_d') : $r('app.media.ic_badge_hires_on'));
    }
    return !got ? $r('app.media.ic_badge_first_g')
      : (this.isDark ? $r('app.media.ic_badge_first_on_d') : $r('app.media.ic_badge_first_on'));
  }

  @Builder
  badgePanel() {
    Column() {
      Text('已点亮 ' + this.badgeOn() + ' / ' + this.badges().length)
        .fontSize(11).fontFamily(APP_FONT).fontColor(this.subText())
        .width('100%')
        .margin({ bottom: 10 })

      Grid() {
        ForEach(this.badges(), (b: BadgeCell) => {
          GridItem() {
            Column() {
              Stack({ alignContent: Alignment.Center }) {
                Column()
                  .width(44).height(44).borderRadius(22)
                  .backgroundColor(b.got ? this.accentSoft() : this.trackBg())
                Image(this.badgeIcon(b.key, b.got))
                  .width(24).height(24)
              }
              Text(b.title)
                .fontSize(12).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
                .fontColor(b.got ? this.ink() : this.faintText())
                .margin({ top: 8 })
              Text(b.sub)
                .fontSize(9.5).fontFamily(APP_FONT).fontColor(this.faintText())
                .margin({ top: 2 })
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .backgroundColor(this.cardBg())
            .borderRadius(16)
            .alignItems(HorizontalAlign.Center)
          }
        }, (b: BadgeCell) => b.title)
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .width('100%')
      .height(478)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14 })
  }

  // ---------------- 报告 ----------------

  @Builder
  reportPanel() {
    Column() {
      Column() {
        Text(new Date(this.anchor).getFullYear() + ' 年 ' + (new Date(this.anchor).getMonth() + 1) + ' 月')
          .fontSize(11).fontFamily(APP_FONT).fontColor(this.subText())
        Text('这个月，你听了\n' + this.bigTime(this.sumSec(this.reportKeys())).v + ' ' +
          this.bigTime(this.sumSec(this.reportKeys())).u)
          .fontSize(22).fontFamily(APP_FONT).fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
          .lineHeight(30)
          .margin({ top: 6 })

        Row() {
          this.reportCell('播放', this.sumPlays(this.reportKeys()) + ' 次')
          this.reportCell('曲目', this.songCount(this.reportStats()) + ' 首')
          this.reportCell('艺人', this.artistCount(this.reportStats()) + ' 位')
        }
        .width('100%')
        .margin({ top: 16 })
      }
      .width('100%')
      .padding(18)
      .backgroundColor(this.cardBg())
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)

      Column().height(10)

      Column() {
        Text('这一月')
          .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
        this.reportLine('最常听', this.topTitle())
        this.reportLine('最常听歌手', this.topArtist())
        this.reportLine('听得最多的一天', this.topDayLabel())
        this.reportLine('无损占比', this.qualityKnownSec() > 0
          ? this.pct(this.losslessSec(), this.qualityKnownSec()) + '%'
          : '暂无音质信息')
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.cardBg())
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14 })
  }

  @Builder
  reportCell(label: string, value: string) {
    Column() {
      Text(label)
        .fontSize(10).fontFamily(APP_FONT).fontColor(this.faintText())
      Text(value)
        .fontSize(13).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
        .fontColor(this.ink())
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  reportLine(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(11.5).fontFamily(APP_FONT).fontColor(this.subText())
      Row().layoutWeight(1)
      Text(value)
        .fontSize(12).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
        .fontColor(this.ink())
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 16 })
    }
    .width('100%')
    .padding({ top: 12, bottom: 2 })
    .alignItems(VerticalAlign.Center)
  }

  // ---------------- 底部正在播放 ----------------

  @Builder
  nowBar() {
    if (this.playingTitle.length > 0) {
      Column() {
        Row() {
          if (this.playingCover.length > 0) {
            Image(this.playingCover)
              .width(38).height(38).borderRadius(9)
              .objectFit(ImageFit.Cover)
          } else {
            Stack({ alignContent: Alignment.Center }) {
              Column().width(38).height(38).borderRadius(9).backgroundColor(this.trackBg())
              Image(this.isDark ? $r('app.media.ic_note') : $r('app.media.ic_note_d')).width(18).height(18)
            }
          }
          Column() {
            Text(this.playingTitle)
              .fontSize(12.5).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
              .fontColor(this.ink())
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.playingArtist.length > 0 ? this.playingArtist : '正在播放')
              .fontSize(9.5).fontFamily(APP_FONT).fontColor(this.faintText())
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 10 })

          Image(this.isDark
            ? (this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
            : (this.playing ? $r('app.media.ic_pause_d') : $r('app.media.ic_play_d')))
            .width(22).height(22)
            .margin({ right: 16 })
            .onClick(() => { Store.get().player().togglePlayPause(); })
          Image(this.isDark ? $r('app.media.ic_next') : $r('app.media.ic_next_d'))
            .width(22).height(22)
            .onClick(() => { Store.get().player().next(); })
        }
        .width('100%')
        .height(56)
        .padding({ left: 10, right: 14 })
        .backgroundColor(this.isDark ? '#24252C' : '#FFFFFF')
        .borderRadius(16)
        .alignItems(VerticalAlign.Center)
        .onClick(() => { Router.push('pages/NowPlaying'); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: bottomInset() + 10 })
    }
  }
}
