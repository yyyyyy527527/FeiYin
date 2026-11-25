import preferences from '@ohos.data.preferences';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { ServerConfig, Track, AppSettings, DEFAULT_SETTINGS, PlayerSkin, WebDavEntry, ScanResult,
  Artist, Album, Genre, DataSourceType, configType,
  ArtistDetail, AlbumDetail, SearchResult, StarredResult, LyricsResult, TrackStat,
  Playlist, CacheUsage, PlayMode, SongsSort, QueueEntry, QueueArchive, DailyPickBox,
  SongProbe, RecentEntry } from '../model/Models';
import { WebDav } from '../net/WebDav';
import { Subsonic, bindSubsonic } from '../net/Subsonic';
import { CloudAccount, CloudData, SyncApi, SyncResult, LoginResult } from '../net/SyncApi';
import { PlayerCore } from '../player/PlayerCore';
import { Fmt, initTheme } from '../utils/Theme';
import { refreshSystemBar } from '../utils/WindowBar';

const PREF_NAME: string = 'feiyin_prefs';

/** 缓存清单条目：文件大小（容量淘汰用）+ 最近使用时间（LRU 排序用） */
export interface CacheEntry {
  href: string;
  size: number;
  at: number;
}

const KEY_SERVER: string = 'server_config';
const KEY_SETTINGS: string = 'app_settings';
/** 设置项最后一次被用户改动的本机时间：多设备同步靠它判断谁更新 */
const KEY_SETTINGS_AT: string = 'app_settings_at';
const KEY_CACHED: string = 'cached_tracks';
/** 缓存清单 v2：带文件大小与时间，供容量淘汰用。旧索引在 KEY_CACHED，首次启动迁移 */
const KEY_CACHE_MANIFEST: string = 'cache_manifest_v2';
/** 缓存容量上限。平均一首 5~10MB，1GB 约能放 100~200 首，
 *  再多「清空缓存」前磁盘就被吃光了；够一整天通勤离线听 */
const CACHE_MAX_BYTES: number = 1024 * 1024 * 1024;
const KEY_DARK: string = 'dark_mode';
const KEY_LISTEN: string = 'listen_stats';
/** 每天播放次数：{ 'YYYY-MM-DD': n }。日统计只记时长，统计页要按周期算次数 */
const KEY_PLAYS: string = 'listen_plays';
const KEY_TRACK_STATS: string = 'track_stats';
const KEY_ACCOUNT: string = 'cloud_account';
const KEY_SYNC_URL: string = 'cloud_sync_url';
/** 每日推荐的缓存：{ date: 'YYYY-MM-DD', songs: Track[] } */
const KEY_DAILY: string = 'daily_picks';
/** 搜索历史：最近用过的关键词，最近的在前 */
const KEY_SEARCH_HISTORY: string = 'search_history';
/** 播放队列存档：{ tracks, index, position } */
const KEY_QUEUE: string = 'play_queue';
/** 队列最多存多少首。全存会把 preferences 撑爆（几千首的专辑列表），
 *  而且真恢复了也没人会去翻第 800 首，取一段足够 */
const QUEUE_MAX: number = 300;
/** 搜索历史最多留几条 */
const SEARCH_HISTORY_MAX: number = 12;
/** 曲库/收藏列表的落盘缓存：冷启动先用它铺列表，不用每次都等全量网络请求 */
const KEY_SONGS_CACHE: string = 'songs_cache_v1';
const KEY_STARRED_CACHE: string = 'starred_cache_v1';
/** 曲库缓存上限（首）。再大解析会明显拖慢冷启动，两万首对 NAS 曲库已经很宽裕 */
const SONGS_CACHE_MAX: number = 20000;
/** 缓存最长有效期：超过就忽略缓存重建，避免服务器删歌后残影一直留在列表里 */
const CACHE_TTL_MS: number = 3 * 24 * 60 * 60 * 1000;
/** 歌词内存缓存条数上限 */
const LYRIC_CACHE_MAX: number = 50;
/** 最近播放最多留几条。一屏横向卡片放得下 4~5 张，留 40 条够翻好几天的记录 */
const RECENT_MAX: number = 40;
/** 歌词时间偏移的持久化表：songId → 秒。只存调过的，几十字节一条 */
const KEY_LYRIC_OFFSET: string = 'lyric_offsets_v1';
/** 最近播放 */
const KEY_RECENT: string = 'recent_tracks_v1';
/** 偏移表最多记多少首：调过轴的歌通常是同一批，300 首足够 */
const LYRIC_OFFSET_MAX: number = 300;
/** 听歌统计攒够多少秒才落盘（写盘过频会在播放中引起偶发卡顿） */
const STATS_FLUSH_SEC: number = 60;

/**
 * 全局状态管理：服务器配置、设置、缓存记录、播放器单例。
 * 支持两种数据源：飞牛 NAS (WebDAV) 与 Navidrome (Subsonic)。
 */
export class Store {
  private static _instance: Store | null = null;
  private pref: preferences.Preferences | null = null;
  private _cfg: ServerConfig | null = null;
  private _settings: AppSettings = {
    autoCache: true,
    volume: 80,
    playMode: 'loop',
    songsSort: 'default',
    radio: true,
    scrobble: true,
    playerSkin: 'classic'
  };
  private _dav: WebDav | null = null;
  private _subsonic: Subsonic | null = null;
  private _player: PlayerCore | null = null;
  /** 缓存清单：href → 大小 + 最近使用时间。容量淘汰与设置页统计都从这里来 */
  private _cacheManifest: Map<string, CacheEntry> = new Map();
  /** 歌词内存缓存：songId → 结果。几 KB 一份，重放不重新发请求 */
  private _lyricCache: Map<string, LyricsResult> = new Map();
  /** 最近播放：最新的在前，切歌/开播时置顶 */
  private _recent: RecentEntry[] = [];
  /** 歌词时间偏移（秒）：正数表示歌词提前。按 songId 记，不同歌的偏差不一样 */
  private _lyricOffsets: Record<string, number> = {};
  /** 偏移落盘防抖句柄：连点 ± 时只写最后一次 */
  private _offsetSaveTimer: number = -1;
  /** 队列存档里记的当前曲目下标与播放位置，由 loadQueue() 填充 */
  private _queuedIndex: number = -1;
  private _queuedPosition: number = 0;
  private _cacheDir: string = '';
  /** 「自动缓存」关闭时的临时下载目录：会话内复用，启动即清，不占长期空间 */
  private _tmpDir: string = '';
  private _filesDir: string = '';
  private _context: common.UIAbilityContext | null = null;
  /**
   * 本机设置最后一次被用户改动的时间。
   * 换机恢复时是 0，服务端的设置时间戳更大，云端值才会盖到本地；
   * 否则新设备的默认设置会把云端设置反向覆盖掉。
   */
  private _settingsAt: number = 0;
  /** 听歌时长：'YYYY-MM-DD' → 秒 */
  private _listen: Record<string, number> = {};
  /** 每天播放次数：'YYYY-MM-DD' → 次。统计页按周期汇总用 */
  private _plays: Record<string, number> = {};
  /** 尚未落盘的秒数，攒够一批再写，避免每次 tick 都 flush */
  private _listenPending: number = 0;
  /** 单曲统计：曲目 id → 次数/时长 */
  private _trackStats: Record<string, TrackStat> = {};
  /** 单曲时长待落盘秒数 */
  private _trackPending: number = 0;
  /** 播放次数等离散改动是否还没落盘 */
  private _statsDirty: boolean = false;
  /**
   * 统计数据的结构版本：只在「统计内容发生可观变化」时递增
   * （记一次播放、落盘、云同步合并），不随 addListenSeconds 的逐秒累加变化。
   * 统计页用它做缓存失效依据——如果用听歌总秒数做版本，
   * 播放中它每 200ms 都在涨，缓存等于每秒被作废 5 次。
   */
  private _statsVersion: number = 0;
  /** 云同步账号（未登录为 null） */
  private _account: CloudAccount | null = null;
  /** 自建同步服务地址 */
  private _syncUrl: string = '';
  /**
   * 本次进程内已经跑过每日推荐存活校验的日期。
   * 校验失败（NAS 掉线）时也记下来，免得用户来回切页把首页刷成请求风暴；
   * 但**不跨进程**——每次重新打开 App 都会再查一次，否则当天在 NAS 上删了歌，
   * 重启后还是推那几首死链。
   */
  private _dailyTry: string = '';

  static get(): Store {
    if (Store._instance === null) {
      Store._instance = new Store();
    }
    return Store._instance;
  }

  private _ready: Promise<void> | null = null;

  init(context: Context): Promise<void> {
    if (this._ready === null) {
      this._ready = this.doInit(context);
    }
    return this._ready;
  }

  /** 等待初始化完成（EntryAbility 用它决定首页，避免读取竞态） */
  ready(): Promise<void> {
    return this._ready === null ? Promise.resolve() : this._ready;
  }

  private async doInit(context: Context): Promise<void> {
    this._context = context as common.UIAbilityContext;
    this._filesDir = context.filesDir;
    this._cacheDir = context.cacheDir + '/music';
    try { fs.mkdirSync(this._cacheDir, true); } catch (e) {}
    // 「自动缓存」关闭时下载到这里：能播（播放器只认本地文件），
    // 但不进清单、不计占用，启动时整个清掉——开关的语义是
    // 「不留长期缓存」，而不是「没法播」
    this._tmpDir = context.cacheDir + '/tmp';
    try { fs.mkdirSync(this._tmpDir, true); } catch (e) {}
    this.wipeTmpDir();
    this.pref = await preferences.getPreferences(context, PREF_NAME);
    // 七项都是本地读取、相互独立，并行跑完；冷启动能省一截串行等待
    await Promise.all([
      this.loadDark(),
      this.loadConfig(),
      this.loadSettings(),
      this.loadCached(),
      this.loadListen(),
      this.loadPlays(),
      this.loadTrackStats(),
      this.loadRecent(),
      this.loadLyricOffsets(),
      this.loadAccount()
    ]);
    // 统计读完之后广播一次：页面有可能在 init 完成前就搭好，
    // 那时读到的是空表；没有这次通知，排行会一直停在我「还没有播放记录」。
    this.bumpStats();
  }

  // ---------------- 听歌时长统计 ----------------

  /** 日期键：'YYYY-MM-DD'（本地时区） */
  static dayKey(d: Date): string {
    const m: number = d.getMonth() + 1;
    const day: number = d.getDate();
    return d.getFullYear() + '-' + (m < 10 ? '0' : '') + m + '-' + (day < 10 ? '0' : '') + day;
  }

  private async loadListen(): Promise<void> {
    if (this.pref === null) {
      return;
    }
    const raw: string = this.pref.getSync(KEY_LISTEN, '') as string;
    if (raw.length === 0) {
      return;
    }
    try {
      this._listen = JSON.parse(raw) as Record<string, number>;
    } catch (e) {
      this._listen = {};
    }
  }

  /**
   * 每天播放次数。
   * 旧版本只存了「单曲 playCount」，没有按天拆，历史次数补不回来；
   * 这里从 0 开始记，新数据准确，老数据只影响历史周期。
   */
  private async loadPlays(): Promise<void> {
    if (this.pref === null) {
      return;
    }
    const raw: string = this.pref.getSync(KEY_PLAYS, '') as string;
    if (raw.length === 0) {
      return;
    }
    try {
      this._plays = JSON.parse(raw) as Record<string, number>;
    } catch (e) {
      this._plays = {};
    }
  }

  /**
   * 累加当前这天的收听秒数。播放器每 500ms 喂一次。
   * 内存里实时累加，攒够 60 秒才落一次盘——写盘太频繁会在播放中造成偶发卡顿；
   * 暂停/切歌/退出时由 flushStats() 兜底补写，不会丢数据。
   */
  addListenSeconds(sec: number, track: Track | null = null): void {
    if (sec <= 0) {
      return;
    }
    const key: string = Store.dayKey(new Date());
    const old: number | undefined = this._listen[key];
    this._listen[key] = (old === undefined ? 0 : old) + sec;
    this._listenPending += sec;
    if (track !== null) {
      this.accumulateTrack(track, sec);
    }
    // 两套统计共用一次 flush，避免同一时刻写两遍磁盘
    if (this._listenPending >= STATS_FLUSH_SEC || this._trackPending >= STATS_FLUSH_SEC) {
      this._listenPending = 0;
      this._trackPending = 0;
      this.pruneListen();
      this.pruneTrackStats();
      this.persistStats();
    }
  }

  // ---------------- 单曲收听统计 ----------------

  private async loadTrackStats(): Promise<void> {
    if (this.pref === null) {
      return;
    }
    const raw: string = this.pref.getSync(KEY_TRACK_STATS, '') as string;
    if (raw.length === 0) {
      return;
    }
    try {
      this._trackStats = JSON.parse(raw) as Record<string, TrackStat>;
    } catch (e) {
      this._trackStats = {};
    }
  }

  /** 记一次播放：每次真正开始播放调用，立即落盘 */
  countTrackPlay(track: Track): void {
    const st: TrackStat = this.ensureTrackStat(track);
    st.plays = st.plays + 1;
    st.title = track.title;
    st.artist = track.artist;
    st.lastAt = Date.now();
    // 按天计数：统计页的「本周/本月播放次数」靠它，单曲的 plays 是累计值没法拆周期
    const day: string = Store.dayKey(new Date());
    const old: number | undefined = this._plays[day];
    this._plays[day] = (old === undefined ? 0 : old) + 1;
    this.pruneTrackStats();
    // 标脏即可：切歌/暂停时 stopPosTimer 会触发 flushStats 落盘
    this._statsDirty = true;
    this.bumpStats();
  }

  /**
   * 统计内容变了：版本号 + 一次全局广播。
   * 设置页的「播放排行」「近 7 天时长」和统计页都靠 statsVer 变化刷新——
   * 这些界面可能一直挂在后台（从设置页 push 进统计页再返回），
   * aboutToAppear 不会再跑一次，只靠进入时读一次就会一直是旧数字。
   */
  private bumpStats(): void {
    this._statsVersion++;
    AppStorage.setOrCreate('statsVer', this._statsVersion);
  }

  /** 取（或按曲目信息创建）一条统计记录 */
  private ensureTrackStat(track: Track): TrackStat {
    const id: string = this.trackStatKey(track);
    const old: TrackStat | undefined = this._trackStats[id];
    if (old !== undefined) {
      // 老记录没有音质字段：下一次播放时补上，统计页的音质分桶才能覆盖到老歌
      if (old.suffix === undefined && track.suffix.length > 0) {
        old.suffix = track.suffix;
        old.bitDepth = track.bitDepth;
        old.samplingRate = track.samplingRate;
      }
      return old;
    }
    const created: TrackStat = {
      id: id,
      title: track.title,
      artist: track.artist,
      plays: 0,
      seconds: 0,
      lastAt: Date.now(),
      suffix: track.suffix,
      bitDepth: track.bitDepth,
      samplingRate: track.samplingRate
    };
    this._trackStats[id] = created;
    return created;
  }

  /** 把播放秒数记到单曲上（只更新内存，攒批由 addListenSeconds 统一落盘） */
  private accumulateTrack(track: Track, sec: number): void {
    const st: TrackStat = this.ensureTrackStat(track);
    st.seconds = st.seconds + sec;
    this._trackPending += sec;
  }

  /** 立即把所有待落盘数据写入（暂停 / 切歌 / 退出前调用，避免丢最后一段时间） */
  flushStats(): void {
    const needSave: boolean = this._statsDirty || this._listenPending > 0.5 || this._trackPending > 0.5;
    if (!needSave) {
      return;
    }
    this._listenPending = 0;
    this._trackPending = 0;
    this.persistStats();
    // 落盘发生在暂停/切歌/退出这些「统计刚发生了可观变化」的节点，
    // 顺手 bump 版本，让统计页在下一次 build 时拿到新数据
    this.bumpStats();
  }

  /** 两套统计一次写入，只 flush 一次磁盘 */
  private async persistStats(): Promise<void> {
    if (this.pref === null) {
      return;
    }
    this._statsDirty = false;
    try {
      await this.pref.put(KEY_LISTEN, JSON.stringify(this._listen));
      await this.pref.put(KEY_PLAYS, JSON.stringify(this._plays));
      await this.pref.put(KEY_TRACK_STATS, JSON.stringify(this._trackStats));
      // 最近播放与歌词偏移搭同一趟车落盘，不额外 flush 一次
      await this.pref.put(KEY_RECENT, JSON.stringify(this._recent));
      await this.pref.put(KEY_LYRIC_OFFSET, JSON.stringify(this._lyricOffsets));
      await this.pref.flush();
    } catch (e) {
      this._statsDirty = true;
      console.error('[listen] 保存听歌统计失败：' + JSON.stringify(e));
    }
  }

  /** 统计用的曲目键：同一首歌在不同入口可能 id 不同，用「歌手 + 曲名」兜底去重 */
  private trackStatKey(track: Track): string {
    if (track.id.length > 0) {
      return track.id;
    }
    return (track.artist + '-' + track.title).toLowerCase();
  }

  /** 最多留 2000 首，按播放次数与时长淘汰冷门曲目（400 会在大曲库下把统计封顶） */
  private pruneTrackStats(): void {
    const keys: string[] = Object.keys(this._trackStats);
    if (keys.length <= 2000) {
      return;
    }
    const all: TrackStat[] = keys.map((k: string) => this._trackStats[k]);
    all.sort((a: TrackStat, b: TrackStat) => (b.plays - a.plays) || (b.seconds - a.seconds));
    const keep: Record<string, TrackStat> = {};
    for (let i = 0; i < 2000; i++) {
      keep[all[i].id] = all[i];
    }
    this._trackStats = keep;
  }

  /** 单曲排行：按播放次数降序，同次数按时长降序。只统计听满过阈值的（plays>=1） */
  topTracks(limit: number): TrackStat[] {
    const keys: string[] = Object.keys(this._trackStats);
    const all: TrackStat[] = [];
    for (const k of keys) {
      // 播放次数为 0 的记录只有「听了几秒就切走」的碎片时长，
      // 不算听过，排行/统计曲目/艺人都不应包含
      if (this._trackStats[k].plays > 0) {
        all.push(this._trackStats[k]);
      }
    }
    all.sort((a: TrackStat, b: TrackStat) => {
      if (b.plays !== a.plays) {
        return b.plays - a.plays;
      }
      return b.seconds - a.seconds;
    });
    return limit > 0 && all.length > limit ? all.slice(0, limit) : all;
  }

  /** 听过至少一次（听满阈值计入一次播放）的曲目数 */
  trackStatCount(): number {
    let n: number = 0;
    const keys: string[] = Object.keys(this._trackStats);
    for (const k of keys) {
      if (this._trackStats[k].plays > 0) {
        n++;
      }
    }
    return n;
  }

  /** 单曲统计（「最常播放」排序用）；没有记录返回 null */
  statOf(id: string): TrackStat | null {
    const st: TrackStat | undefined = this._trackStats[id];
    return st === undefined ? null : st;
  }

  // ---------------- 最近播放 ----------------

  private async loadRecent(): Promise<void> {
    if (this.pref === null) {
      return;
    }
    const raw: string = this.pref.getSync(KEY_RECENT, '') as string;
    if (raw.length === 0) {
      return;
    }
    try {
      const arr: RecentEntry[] = JSON.parse(raw) as RecentEntry[];
      this._recent = Array.isArray(arr) ? arr : [];
    } catch (e) {
      this._recent = [];
    }
  }

  /**
   * 记一条「最近播放」。
   * 同一首重复播时置顶而不是新增一条，否则循环听一首歌会把整个列表刷成同一首。
   * 位置清零：这是新的一次播放，还没听到任何地方。
   */
  noteRecent(track: Track): void {
    const list: RecentEntry[] = [];
    for (const e of this._recent) {
      if (e.track.id !== track.id) {
        list.push(e);
      }
    }
    list.unshift({ track: track, pos: 0, at: Date.now() });
    while (list.length > RECENT_MAX) {
      list.pop();
    }
    this._recent = list;
    this._statsDirty = true;
  }

  /**
   * 更新「上次听到哪」。
   * 只在整秒数变了 2 秒以上才写，且只改内存——真正落盘跟着统计那套
   * 「攒够 60 秒 / 暂停 / 切歌」的节奏走，不额外增加写盘次数。
   */
  updateRecentPos(trackId: string, pos: number): void {
    if (trackId.length === 0 || pos <= 0) {
      return;
    }
    for (const e of this._recent) {
      if (e.track.id === trackId) {
        // 2 秒粒度：tick 是 200ms，不设阈值会每 tick 都把统计标脏、
        // 顺带让首页进度线一直重绘；而位置本身也不需要 200ms 的精度
        if (Math.abs(e.pos - pos) >= 2000) {
          e.pos = pos;
          this._statsDirty = true;
        }
        return;
      }
    }
  }

  recentEntries(): RecentEntry[] {
    return this._recent.slice();
  }

  clearRecent(): void {
    this._recent = [];
    this._statsDirty = true;
    this.flushStats();
  }

  // ---------------- 歌词时间偏移 ----------------

  private async loadLyricOffsets(): Promise<void> {
    if (this.pref === null) {
      return;
    }
    const raw: string = this.pref.getSync(KEY_LYRIC_OFFSET, '') as string;
    if (raw.length === 0) {
      return;
    }
    try {
      this._lyricOffsets = JSON.parse(raw) as Record<string, number>;
    } catch (e) {
      this._lyricOffsets = {};
    }
  }

  /** 这首歌的歌词偏移（秒）；没调过返回 0 */
  lyricOffsetOf(songId: string): number {
    const v: number | undefined = this._lyricOffsets[songId];
    return v === undefined ? 0 : v;
  }

  /**
   * 记下这首歌的歌词偏移。
   * 调回 0 就删掉这一条，别让表里攒一堆无意义的 0。
   * 立即落盘：用户辛苦对上的轴，不能因为进程被杀就白调。
   */
  setLyricOffset(songId: string, sec: number): void {
    if (songId.length === 0) {
      return;
    }
    // ArkTS 不支持 delete，用重建对象的方式增删（表本身只有几十条，开销可忽略）
    const next: Record<string, number> = {};
    const oldKeys: string[] = Object.keys(this._lyricOffsets);
    for (const k of oldKeys) {
      if (k !== songId) {
        next[k] = this._lyricOffsets[k];
      }
    }
    if (Math.abs(sec) >= 0.01) {
      next[songId] = sec;
    }
    this._lyricOffsets = next;
    const keys: string[] = Object.keys(this._lyricOffsets);
    if (keys.length > LYRIC_OFFSET_MAX) {
      // 超上限就从最早记的那批开始丢：先记的通常是很久以前调过的歌
      const keep: Record<string, number> = {};
      for (let i = keys.length - LYRIC_OFFSET_MAX; i < keys.length; i++) {
        keep[keys[i]] = this._lyricOffsets[keys[i]];
      }
      this._lyricOffsets = keep;
    }
    this._statsDirty = true;
    // 连点 ± 时别每次都整份写盘：400ms 内只落最后一次，
    // 既省 IO，也避免多个异步 put 并发导致最终存下中间值
    if (this._offsetSaveTimer !== -1) {
      clearTimeout(this._offsetSaveTimer);
    }
    this._offsetSaveTimer = setTimeout(() => {
      this._offsetSaveTimer = -1;
      this.flushStats();
    }, 400);
  }

  /** 只留最近 90 天，避免不断长大 */
  /**
   * 只留最近两年。
   * 原来只留 90 天，统计页的「年」「全部」就永远凑不满，
   * 而一天一条记录不过几十字节，两年也就二十来 KB，没必要为此牺牲年度视图。
   */
  private pruneListen(): void {
    const keys: string[] = Object.keys(this._listen).sort();
    if (keys.length <= 730) {
      return;
    }
    const keep: Record<string, number> = {};
    const keepPlays: Record<string, number> = {};
    for (let i = keys.length - 730; i < keys.length; i++) {
      keep[keys[i]] = this._listen[keys[i]];
      const p: number | undefined = this._plays[keys[i]];
      if (p !== undefined) {
        keepPlays[keys[i]] = p;
      }
    }
    this._listen = keep;
    this._plays = keepPlays;
  }

  /** 某一天的收听秒数 */
  listenSecondsOn(key: string): number {
    const v: number | undefined = this._listen[key];
    return v === undefined ? 0 : v;
  }

  /** 每日时长表（只读；统计页按任意周期自己汇总） */
  listenMap(): Record<string, number> {
    return this._listen;
  }

  /** 每日播放次数表（只读） */
  playsMap(): Record<string, number> {
    return this._plays;
  }

  /** 统计数据的结构版本，见 _statsVersion 注释 */
  statsVersion(): number {
    return this._statsVersion;
  }

  /** 累计收听秒数 */
  listenTotalSeconds(): number {
    const keys: string[] = Object.keys(this._listen);
    let sum: number = 0;
    for (let i = 0; i < keys.length; i++) {
      sum += this._listen[keys[i]];
    }
    return sum;
  }

  /** UIAbilityContext：媒体会话与长时任务需要 */
  get abilityContext(): common.UIAbilityContext | null {
    return this._context;
  }

  /** 恢复明暗模式（默认深色） */
  private async loadDark(): Promise<void> {
    if (this.pref === null) return;
    const v: boolean = this.pref.getSync(KEY_DARK, true) as boolean;
    initTheme(v);
  }

  /** 持久化明暗模式（用户手动切换时才推进设置时间戳） */
  async saveDark(isDark: boolean, markChanged: boolean = true): Promise<void> {
    if (markChanged) {
      this._settingsAt = Date.now();
    }
    if (this.pref !== null) {
      await this.pref.put(KEY_DARK, isDark);
      if (markChanged) {
        await this.pref.put(KEY_SETTINGS_AT, this._settingsAt);
      }
      await this.pref.flush();
    }
  }

  get filesDir(): string {
    return this._filesDir;
  }

  get cacheDir(): string {
    return this._cacheDir;
  }

  get serverConfig(): ServerConfig | null {
    return this._cfg;
  }

  get settings(): AppSettings {
    return this._settings;
  }

  /** 当前播放页外观。非法/缺省一律当经典玻璃版 */
  get playerSkin(): PlayerSkin {
    const v: PlayerSkin | undefined = this._settings.playerSkin;
    return v === undefined ? 'classic' : v;
  }

  get isConfigured(): boolean {
    return this._cfg !== null && this._cfg.url.length > 0;
  }

  get sourceType(): DataSourceType {
    return configType(this._cfg);
  }

  get isSubsonic(): boolean {
    return this.sourceType === 'subsonic';
  }

  get isWebDav(): boolean {
    return this.sourceType === 'webdav';
  }

  player(): PlayerCore {
    if (this._player === null) {
      this._player = new PlayerCore();
      // PlayerCore 没有构造函数注入，第一次拿到实例时把上次的播放模式补回去。
      // 放在这里而不是页面 onAppear：多个页面都会取 player()，
      // 挂在页面上会出现「谁先出现谁决定初始模式」的不确定行为。
      this._player.restorePlayMode();
    }
    return this._player;
  }

  davClient(): WebDav | null {
    if (this._dav === null && this._cfg !== null && this.isWebDav) {
      this._dav = new WebDav(this._cfg);
    }
    return this._dav;
  }

  subsonicClient(): Subsonic | null {
    if (this._subsonic === null && this._cfg !== null && this.isSubsonic) {
      this._subsonic = new Subsonic(this._cfg);
      bindSubsonic(this._subsonic);
    }
    return this._subsonic;
  }

  /** 统一封面 URL：Subsonic 模式返回 getCoverArt URL，WebDAV 模式返回空 */
  coverUrlFor(track: Track, size: number): string {
    if (this.isSubsonic) {
      const s: Subsonic | null = this.subsonicClient();
      if (s !== null && track.coverArt.length > 0) {
        return s.coverUrl(track.coverArt, size);
      }
    }
    return '';
  }

  private async loadConfig(): Promise<void> {
    if (this.pref === null) return;
    const raw: string = this.pref.getSync(KEY_SERVER, '') as string;
    if (raw.length > 0) {
      try {
        const parsed: Object = JSON.parse(raw);
        const obj = parsed as Record<string, Object>;
        const t: string = asString(obj['type'], 'webdav');
        this._cfg = {
          type: t === 'subsonic' ? 'subsonic' : 'webdav',
          url: asString(obj['url'], ''),
          username: asString(obj['username'], ''),
          password: asString(obj['password'], ''),
          rootPath: asString(obj['rootPath'], '/')
        };
        this.buildClient();
      } catch (e) {
      }
    }
  }

  private buildClient(): void {
    if (this._cfg === null) return;
    if (this.isWebDav) {
      this._dav = new WebDav(this._cfg);
    } else {
      this._subsonic = new Subsonic(this._cfg);
      bindSubsonic(this._subsonic);
    }
  }

  async saveConfig(cfg: ServerConfig): Promise<void> {
    // 旧作用域要在 _cfg 被覆盖前算出来，否则找不到旧缓存 key
    const oldScope: string = this.cacheScope();
    this._cfg = cfg;
    const newScope: string = this.cacheScope();
    this._dav = null;
    this._subsonic = null;
    // 服务器换了：同一个 songId 指向的可能完全是另一首歌，歌词缓存作废
    this._lyricCache.clear();
    // 曲库/收藏缓存同理：里面存的全是旧服务器的歌 id。
    // 只有作用域真的变了才删——同一台服务器改密码/根路径不该把缓存清掉
    if (oldScope.length > 0 && oldScope !== newScope) {
      try {
        const f1: string = this._cacheDir + '/' + KEY_SONGS_CACHE + '_' + oldScope + '.json';
        const f2: string = this._cacheDir + '/' + KEY_STARRED_CACHE + '_' + oldScope + '.json';
        if (fs.accessSync(f1)) {
          fs.unlinkSync(f1);
        }
        if (fs.accessSync(f2)) {
          fs.unlinkSync(f2);
        }
      } catch (e) {
      }
    }
    this.buildClient();
    if (this.pref !== null) {
      await this.pref.put(KEY_SERVER, JSON.stringify(cfg));
      await this.pref.flush();
    }
  }

  /**
   * 把存下来的字符串转成合法的播放模式。
   * 存的是用户上次选的模式，可能来自旧版本（那里还有 'fav'），
   * 也可能是被改坏的配置；一律回落到列表循环，不要让它变成非法值。
   */
  private parseMode(raw: string): PlayMode {
    if (raw === 'seq' || raw === 'one' || raw === 'shuffle' || raw === 'loop') {
      return raw as PlayMode;
    }
    return 'loop';
  }

  /** 播放页外观：非法值/老数据回落到经典玻璃版 */
  private parseSkin(raw: string): PlayerSkin {
    if (raw === 'vinyl') {
      return 'vinyl';
    }
    if (raw === 'clock') {
      return 'clock';
    }
    return 'classic';
  }

  /** 排序方式旧数据回落到「默认」；非法值同理 */
  private parseSongsSort(raw: string): SongsSort {
    if (raw === 'default' || raw === 'title' || raw === 'artist' || raw === 'album' ||
      raw === 'added' || raw === 'plays' || raw === 'random') {
      return raw as SongsSort;
    }
    return 'default';
  }

  private async loadSettings(): Promise<void> {
    if (this.pref === null) return;
    this._settingsAt = this.pref.getSync(KEY_SETTINGS_AT, 0) as number;
    const raw: string = this.pref.getSync(KEY_SETTINGS, '') as string;
    if (raw.length > 0) {
      try {
        const parsed: Object = JSON.parse(raw);
        const obj = parsed as Record<string, Object>;
        this._settings = {
          autoCache: (obj['autoCache'] as boolean) ?? true,
          volume: (obj['volume'] as number) ?? 80,
          // 老版本没有这个字段，默认列表循环；非法值也回落到 loop，
          // 避免坏数据让播放模式卡在一个不存在的状态上
          playMode: this.parseMode(obj['playMode'] as string),
          songsSort: this.parseSongsSort(obj['songsSort'] as string),
          radio: (obj['radio'] as boolean) ?? true,
          scrobble: (obj['scrobble'] as boolean) ?? true,
          playerSkin: this.parseSkin(obj['playerSkin'] as string)
        };
      } catch (e) {
      }
    }
  }

  /**
   * 保存设置。
   *
   * 必须是「合并」而不是「整份替换」：调用方常常只关心自己改的那一两项
   * （设置页的开关只构造 autoCache / volume 等项），
   * 直接覆盖会把 playMode、songsSort 写成 undefined。表现是——
   * 在设置里拨一下开关，下次启动播放模式回到「循环」、全部歌曲的排序被重置。
   */
  async saveSettings(settings: AppSettings, markChanged: boolean = true): Promise<void> {
    const prev: AppSettings = this._settings;
    const merged: AppSettings = {
      autoCache: settings.autoCache === undefined ? prev.autoCache : settings.autoCache,
      volume: settings.volume === undefined ? prev.volume : settings.volume,
      // 这两项允许由云同步写入，但调用方没给值时沿用本机现值
      playMode: settings.playMode === undefined
        ? (prev.playMode === undefined ? 'loop' : prev.playMode)
        : settings.playMode,
      songsSort: settings.songsSort === undefined
        ? (prev.songsSort === undefined ? 'default' : prev.songsSort)
        : settings.songsSort,
      // 这两个开关同理：调用方只改自己关心的项，没给值就沿用现值。
      // 用 === undefined 判断而不是 ||，否则用户明确关掉（false）会被读成「没给值」
      radio: settings.radio === undefined
        ? (prev.radio === undefined ? true : prev.radio)
        : settings.radio,
      scrobble: settings.scrobble === undefined
        ? (prev.scrobble === undefined ? true : prev.scrobble)
        : settings.scrobble,
      // 播放页外观：同样只改自己关心的项，没给值沿用现值
      playerSkin: settings.playerSkin === undefined
        ? (prev.playerSkin === undefined ? 'classic' : prev.playerSkin)
        : settings.playerSkin
    };
    this._settings = merged;
    // 只有用户真的动了开关才推进时间戳；换机恢复写入的云端值不能算「更新」，
    // 否则新设备会拿默认值把云端设置覆盖回去。
    if (markChanged) {
      this._settingsAt = Date.now();
    }
    if (this.pref !== null) {
      await this.pref.put(KEY_SETTINGS, JSON.stringify(merged));
      await this.pref.put(KEY_SETTINGS_AT, this._settingsAt);
      await this.pref.flush();
    }
  }

  /** 用户是否在这台设备上改过设置（0 表示没有，云端时间戳优先） */
  get settingsAt(): number {
    return this._settingsAt;
  }

  // ---------------- 定时关闭 ----------------
  //
  // 计时器必须挂在 Store（单例）上，不能挂在播放页里。
  // 页面版计时器有两个说不通的地方：
  //   · 退出播放页后旧页面的计时器仍在跑，回来再设一次就变成两个计时器，
  //     取消只能取消新的那个，旧的照样到点把歌停掉；
  //   · 页面销毁后回调还在改已销毁组件的 @State。
  // 这里用「截止时间戳 + 每秒检查」代替「每分钟减一」，
  // 不依赖定时器是否被系统掐过，也不会累积误差。
  private _sleepTimer: number = -1;
  private _sleepDeadline: number = 0;
  private _sleepShown: number = 0;

  /** 剩余分钟（向上取整）；0 表示未开启 */
  get sleepMinutes(): number {
    if (this._sleepDeadline <= 0) {
      return 0;
    }
    const left: number = this._sleepDeadline - Date.now();
    return left > 0 ? Math.ceil(left / 60000) : 0;
  }

  /** 设置定时关闭（分钟）；<=0 表示取消 */
  setSleepTimer(min: number): void {
    this.clearSleepTimer();
    if (min <= 0) {
      this._sleepDeadline = 0;
      this._sleepShown = 0;
      AppStorage.setOrCreate('sleepMin', 0);
      return;
    }
    this._sleepDeadline = Date.now() + Math.round(min * 60000);
    this._sleepShown = Math.ceil(min);
    AppStorage.setOrCreate('sleepMin', this._sleepShown);
    this._sleepTimer = setInterval(() => {
      this.tickSleep();
    }, 1000);
  }

  private clearSleepTimer(): void {
    if (this._sleepTimer !== -1) {
      clearInterval(this._sleepTimer);
      this._sleepTimer = -1;
    }
  }

  private tickSleep(): void {
    if (this._sleepDeadline <= 0) {
      this.clearSleepTimer();
      return;
    }
    const left: number = this._sleepDeadline - Date.now();
    if (left <= 0) {
      this._sleepDeadline = 0;
      this._sleepShown = 0;
      this.clearSleepTimer();
      AppStorage.setOrCreate('sleepMin', 0);
      AppStorage.setOrCreate('sleepFiredAt', Date.now());
      try {
        const p: PlayerCore = this.player();
        if (p.isPlaying) {
          p.pause().catch(() => {
          });
        }
      } catch (e) {
      }
      return;
    }
    const m: number = Math.ceil(left / 60000);
    if (m !== this._sleepShown) {
      this._sleepShown = m;
      AppStorage.setOrCreate('sleepMin', m);
    }
  }

  // ---------------- 账号与云同步 ----------------

  private async loadAccount(): Promise<void> {
    if (this.pref === null) {
      return;
    }
    this._syncUrl = this.pref.getSync(KEY_SYNC_URL, '') as string;
    const raw: string = this.pref.getSync(KEY_ACCOUNT, '') as string;
    if (raw.length === 0) {
      return;
    }
    try {
      this._account = JSON.parse(raw) as CloudAccount;
    } catch (e) {
      this._account = null;
    }
  }

  get account(): CloudAccount | null {
    return this._account;
  }

  get syncUrl(): string {
    return this._syncUrl;
  }

  get isLoggedIn(): boolean {
    return this._account !== null;
  }

  /** 是否具备真正跑云同步的条件（登录 + 服务令牌 + 地址） */
  get canSync(): boolean {
    return this._account !== null && this._account.token.length > 0 && this._syncUrl.length > 0;
  }

  async saveSyncUrl(url: string): Promise<void> {
    this._syncUrl = SyncApi.normalizeBase(url);
    if (this.pref !== null) {
      await this.pref.put(KEY_SYNC_URL, this._syncUrl);
      await this.pref.flush();
    }
  }

  private async saveAccount(): Promise<void> {
    if (this.pref === null) {
      return;
    }
    if (this._account === null) {
      await this.pref.delete(KEY_ACCOUNT);
    } else {
      await this.pref.put(KEY_ACCOUNT, JSON.stringify(this._account));
    }
    await this.pref.flush();
  }

  private syncApi(): SyncApi {
    return new SyncApi(this._syncUrl);
  }

  /** 只检查同步服务是否可达 */
  async pingSyncServer(): Promise<boolean> {
    if (this._syncUrl.length === 0) {
      return false;
    }
    return this.syncApi().ping();
  }

  /**
   * 只登录华为账号，不依赖任何同步服务：账号身份记在本机。
   * 以后填了同步地址，再走 loginCloud 把这份身份升级成云端账号。
   */
  async loginHuaweiLocal(idToken: string, openid: string, nickname: string): Promise<LoginResult> {
    const acc: CloudAccount = {
      openid: openid,
      userId: nickname.length > 0 ? nickname : this.maskOpenid(openid),
      nickname: nickname,
      token: '',
      recoveryCode: '',
      via: 'huawei',
      expireAt: Date.now() + 90 * 86400000,
      lastSyncAt: 0
    };
    this._account = acc;
    await this.saveAccount();
    return { ok: true, msg: '', account: acc, hasCloudData: false };
  }

  /** openID 很长，界面只展示首尾几位 */
  private maskOpenid(openid: string): string {
    if (openid.length <= 10) {
      return openid;
    }
    return openid.substring(0, 4) + '····' + openid.substring(openid.length - 4);
  }

  /** 用华为账号令牌换同步服务令牌；没填同步地址时退化为纯本地登录 */
  async loginCloud(idToken: string, openid: string, nickname: string): Promise<LoginResult> {
    if (this._syncUrl.length === 0) {
      return this.loginHuaweiLocal(idToken, openid, nickname);
    }
    const r: LoginResult = await this.syncApi().login(idToken, openid, nickname, this._syncUrl);
    if (r.ok && r.account !== null) {
      this._account = r.account;
      await this.saveAccount();
    }
    return r;
  }

  /** 用恢复码登录：换机时不需要华为账号也能取回数据 */
  async loginCloudByCode(code: string): Promise<LoginResult> {
    const clean: string = code.replace(/[^0-9a-zA-Z]/g, '');
    if (clean.length < 12) {
      return { ok: false, msg: '恢复码是 16 位字母数字', account: null, hasCloudData: false };
    }
    if (this._syncUrl.length === 0) {
      return { ok: false, msg: '请先填写同步服务地址', account: null, hasCloudData: false };
    }
    const r: LoginResult = await this.syncApi().resume(clean, '');
    if (r.ok && r.account !== null) {
      this._account = r.account;
      await this.saveAccount();
    }
    return r;
  }

  async logoutCloud(): Promise<void> {
    const a: CloudAccount | null = this._account;
    if (a !== null && this._syncUrl.length > 0) {
      await this.syncApi().logout(a.token);
    }
    this._account = null;
    await this.saveAccount();
    // 退出同时清掉地址：下次打开设置页会重新按 Navidrome 主机名派生默认值，
    // 免得换了一台机器后还指着上一台的同步服务。
    this._syncUrl = '';
    if (this.pref !== null) {
      await this.pref.put(KEY_SYNC_URL, '');
      await this.pref.flush();
    }
  }

  /** 采集要上云的本地数据 */
  private collectCloudData(): CloudData {
    const cfg: ServerConfig | null = this._cfg;
    return {
      // 用「设置最后改动时间」而不是 Date.now()：从没改过设置的设备
      // 不该在同步时把云端设置覆盖成默认值。
      updatedAt: this._settingsAt,
      dark: AppStorage.get<boolean>('isDark') === true,
      settings: this._settings,
      server: {
        url: cfg !== null ? cfg.url : '',
        username: cfg !== null ? cfg.username : ''
      },
      listen: this._listen,
      trackStats: this._trackStats
    };
  }

  /** 推本地 → 服务端合并 → 拉回并应用 */
  async syncNow(): Promise<SyncResult> {
    const a: CloudAccount | null = this._account;
    if (a === null) {
      return { ok: false, msg: '还没登录', data: null };
    }
    if (a.token.length === 0) {
      return { ok: false, msg: '未连接同步服务，数据只存在本机', data: null };
    }
    if (this._syncUrl.length === 0) {
      return { ok: false, msg: '未配置同步服务，数据只存在本机', data: null };
    }
    const r: SyncResult = await this.syncApi().push(a.token, this.collectCloudData());
    if (r.ok && r.data !== null) {
      await this.applyCloud(r.data);
      a.lastSyncAt = Date.now();
      await this.saveAccount();
    } else if (!r.ok && r.msg.indexOf('未登录') >= 0) {
      // 令牌失效（换了服务地址或服务端清了数据）：退出本地账号状态
      this._account = null;
      await this.saveAccount();
    }
    return r;
  }

  /** 前台自动同步的最小间隔：太频繁会白耗流量，也可能和手动同步打架 */
  private _lastAutoSyncAt: number = 0;

  /**
   * 自动同步：应用启动、切回前台时调用。
   * 已登录才生效，一分钟内只跑一次，失败静默（不打扰正在听歌的人）。
   */
  async autoSync(): Promise<void> {
    if (!this.isLoggedIn || this._syncUrl.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (now - this._lastAutoSyncAt < 60000) {
      return;
    }
    this._lastAutoSyncAt = now;
    await this.syncNow();
  }

  /** 把服务端合并后的数据落到本地（统计取较大值，不会翻倍） */
  private async applyCloud(d: CloudData): Promise<void> {
    // 设置项：只有云端确实比本机新才覆盖，避免用默认值把云端冲掉
    if (d.updatedAt > this._settingsAt) {
      this._settingsAt = d.updatedAt;
      await this.saveSettings(d.settings, false);

      // 深浅色
      initTheme(d.dark);
      AppStorage.setOrCreate('isDark', d.dark);
      await this.saveDark(d.dark, false);
      refreshSystemBar(d.dark);
    }

    // 日统计
    const days: string[] = Object.keys(d.listen);
    for (let i = 0; i < days.length; i++) {
      const k: string = days[i];
      const cur: number | undefined = this._listen[k];
      const remote: number = d.listen[k];
      this._listen[k] = Math.max(cur === undefined ? 0 : cur, remote);
    }
    this.pruneListen();

    // 单曲统计
    const ids: string[] = Object.keys(d.trackStats);
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      const remote: TrackStat | undefined = d.trackStats[id];
      if (remote === undefined) {
        continue;
      }
      const local: TrackStat | undefined = this._trackStats[id];
      if (local === undefined) {
        this._trackStats[id] = remote;
      } else {
        local.plays = Math.max(local.plays, remote.plays);
        local.seconds = Math.max(local.seconds, remote.seconds);
        local.lastAt = Math.max(local.lastAt, remote.lastAt);
        if (remote.title.length > 0) {
          local.title = remote.title;
        }
        if (remote.artist.length > 0) {
          local.artist = remote.artist;
        }
        // 音质快照：本机没有就补上，已有不覆盖（同一首歌格式不会变）
        if (local.suffix === undefined && remote.suffix !== undefined) {
          local.suffix = remote.suffix;
          local.bitDepth = remote.bitDepth;
          local.samplingRate = remote.samplingRate;
        }
      }
    }
    this.pruneTrackStats();

    await this.persistStats();
    this.bumpStats();
  }

  /**
   * 读缓存清单。首次启动从旧版索引（纯 href 数组）迁移：
   * 大小和时间不知道，逐个 stat 补齐——文件已经不在的直接丢掉，
   * 顺带把旧索引清了。
   */
  private async loadCached(): Promise<void> {
    if (this.pref === null) return;
    let loaded = false;
    const raw2: string = this.pref.getSync(KEY_CACHE_MANIFEST, '') as string;
    if (raw2.length > 0) {
      try {
        const arr: CacheEntry[] = JSON.parse(raw2) as CacheEntry[];
        for (const e of arr) {
          if (e.href !== undefined && e.href.length > 0) {
            this._cacheManifest.set(e.href, {
              href: e.href,
              size: e.size ?? 0,
              at: e.at ?? 0
            });
          }
        }
        loaded = true;
      } catch (e) {
      }
    }
    if (!loaded) {
      // 旧索引迁移。文件与清单一一对应（缓存路径由 href 决定），
      // stat 得到真实大小；清了缓存或丢了的文件不再进清单
      const raw: string = this.pref.getSync(KEY_CACHED, '') as string;
      if (raw.length > 0) {
        try {
          const arr: string[] = JSON.parse(raw) as string[];
          for (const href of arr) {
            const fp: string = this.cachedPathFor(href);
            if (!fs.accessSync(fp)) {
              continue;
            }
            let size: number = 0;
            try {
              size = fs.statSync(fp).size;
            } catch (e) {
            }
            this._cacheManifest.set(href, { href: href, size: size, at: Date.now() });
          }
          await this.persistCacheManifest();
        } catch (e) {
        }
      }
    }
    try {
      await this.pref.delete(KEY_CACHED);
    } catch (e) {
    }
  }

  private async persistCacheManifest(): Promise<void> {
    if (this.pref === null) {
      return;
    }
    try {
      const arr: CacheEntry[] = [];
      this._cacheManifest.forEach((e: CacheEntry) => {
        arr.push(e);
      });
      await this.pref.put(KEY_CACHE_MANIFEST, JSON.stringify(arr));
      await this.pref.flush();
    } catch (e) {
    }
  }

  isCached(href: string): boolean {
    return this._cacheManifest.has(href);
  }

  /** 已缓存曲目数量，设置页显示用 */
  get cachedCount(): number {
    return this._cacheManifest.size;
  }

  /**
   * WebDAV 缓存文件的确定性路径。
   * 文件名只由 href 决定，与「曲目列表页」的 safeName 规则一致——
   * 存档恢复、缓存命中判断都靠它，不依赖任何标记。
   */
  cachedPathFor(href: string): string {
    const safeName: string = href.replace(/[^a-zA-Z0-9._-]/g, '_') + '.' + Fmt.ext(href);
    return this._cacheDir + '/' + safeName;
  }

  /** 「自动缓存」关闭时的临时下载路径（会话内复用，启动即清） */
  tmpPathFor(href: string): string {
    const safeName: string = href.replace(/[^a-zA-Z0-9._-]/g, '_') + '.' + Fmt.ext(href);
    return this._tmpDir + '/' + safeName;
  }

  /** 启动时清空临时目录。失败不影响启动 */
  private wipeTmpDir(): void {
    try {
      const files: string[] = fs.listFileSync(this._tmpDir);
      for (const f of files) {
        try { fs.unlinkSync(this._tmpDir + '/' + f); } catch (e) {}
      }
    } catch (e) {
    }
  }

  /**
   * 缓存目录占用。异步版：设置页打开时调用，
   * 之前是 listFileSync + 逐文件 statSync 在主线程上同步遍历，
   * 缓存文件一多（无淘汰策略时能积到几千个）打开设置页就冻一下。
   */
  async cacheUsage(): Promise<CacheUsage> {
    const r: CacheUsage = { bytes: 0, files: 0 };
    try {
      const files: string[] = await fs.listFile(this._cacheDir);
      r.files = files.length;
      for (const f of files) {
        try {
          const st = await fs.stat(this._cacheDir + '/' + f);
          r.bytes += st.size;
        } catch (e) {
        }
      }
    } catch (e) {
    }
    return r;
  }

  /**
   * 记录一首进缓存清单并落盘。
   * 大小从下载好的文件 stat 出来：track.size 在 WebDAV 列表里
   * 可能还没填，目录清单那侧无所谓，容量淘汰需要真实值。
   */
  markTrackCached(track: Track): void {
    let size: number = track.size;
    try {
      size = fs.statSync(track.cachedPath).size;
    } catch (e) {
    }
    this._cacheManifest.set(track.href, {
      href: track.href, size: size, at: Date.now()
    });
    this.persistCacheManifest().catch(() => {
    });
    // 下载后顺手检查容量；淘汰是异步的，不阻塞播放
    this.enforceCacheLimit(track.href).catch(() => {
    });
  }

  /**
   * 容量淘汰：超过上限时从最旧的开始删，直到回到限内。
   * keepHref 是刚下载正要播的那首，绝不淘汰。
   */
  private async enforceCacheLimit(keepHref: string): Promise<void> {
    if (this._cacheManifest.size === 0) {
      return;
    }
    const items: CacheEntry[] = [];
    let total: number = 0;
    this._cacheManifest.forEach((e: CacheEntry) => {
      items.push(e);
      total += e.size;
    });
    if (total <= CACHE_MAX_BYTES) {
      return;
    }
    // 最旧的先走；大小未知（旧数据迁移时 stat 失败）的按 0 算，
    // 排序上它们 at=迁移时刻，天然靠前
    items.sort((a: CacheEntry, b: CacheEntry) => a.at - b.at);
    for (const e of items) {
      if (total <= CACHE_MAX_BYTES) {
        break;
      }
      if (e.href === keepHref) {
        continue;
      }
      try {
        fs.unlinkSync(this.cachedPathFor(e.href));
      } catch (err) {
        // 文件可能已不在：清单里删掉即可，别让总量卡住
      }
      total -= e.size;
      this._cacheManifest.delete(e.href);
    }
    await this.persistCacheManifest();
  }

  // ================ WebDAV 数据源 ================

  /** 把 WebDAV 条目转换成 Track */
  entriesToTracks(entries: WebDavEntry[], folderName: string): Track[] {
    const tracks: Track[] = [];
    for (const e of entries) {
      if (e.isDirectory || !Fmt.isAudio(e.displayName)) {
        continue;
      }
      const name: string = Fmt.stripExt(e.displayName);
      const parts: string[] = name.split(/\s*[-—–]\s*/);
      let title: string = name;
      let artist: string = folderName;
      if (parts.length >= 2) {
        artist = parts[0].trim();
        title = parts.slice(1).join(' - ').trim();
      }
      const cached: boolean = this.isCached(e.href);
      const safeName: string = (e.href.replace(/[^a-zA-Z0-9._-]/g, '_')) + '.' + Fmt.ext(e.href);
      const track: Track = {
        id: safeName,
        href: e.href,
        title: title,
        artist: artist,
        album: folderName,
        folder: folderName,
        size: e.size,
        duration: 0,
        cached: cached,
        cachedPath: cached ? (this._cacheDir + '/' + safeName) : '',
        coverArt: '',
        albumId: '',
        suffix: Fmt.ext(e.href),
        bitRate: 0,
        samplingRate: 0,
        bitDepth: 0,
        streamUrl: ''
      };
      tracks.push(track);
    }
    return tracks;
  }

  /** 扫描一个文件夹下所有音乐文件 */
  async scanFolder(path: string): Promise<ScanResult> {
    const dav: WebDav | null = this.davClient();
    if (dav === null) {
      const empty: ScanResult = { folders: [], tracks: [] };
      return empty;
    }
    const entries: WebDavEntry[] = await dav.list(path);
    const folders: WebDavEntry[] = entries.filter((e: WebDavEntry) => e.isDirectory);
    const folderName: string = path === '/' || path === '' ? '根目录' : Fmt.basename(path);
    const tracks: Track[] = this.entriesToTracks(entries, folderName);
    const result: ScanResult = { folders: folders, tracks: tracks };
    return result;
  }

  // ================ Subsonic 数据源 ================

  async listArtists(): Promise<Artist[]> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return [];
    return s.getArtists();
  }

  async listAlbums(type: string): Promise<Album[]> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return [];
    // 分页拉全：服务器曲库常超过单页 500 的上限
    const PAGE: number = 500;
    let all: Album[] = [];
    let offset: number = 0;
    for (let i = 0; i < 20; i++) {
      const page: Album[] = await this.listAlbumsPage(type, PAGE, offset);
      all = all.concat(page);
      if (page.length < PAGE) {
        break;
      }
      offset += PAGE;
    }
    return all;
  }

  /** 专辑单页（首页分阶段加载用：先取一页立即渲染，剩余后台补齐） */
  async listAlbumsPage(type: string, limit: number, offset: number): Promise<Album[]> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return [];
    return s.getAlbumList(type, limit, offset);
  }

  /** 全部歌曲（分页取，逐页追加） */
  async listSongs(limit: number, offset: number): Promise<Track[]> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return [];
    return s.getSongsPage(limit, offset);
  }

  // ============ 曲库/收藏落盘缓存 ============

  /** 缓存作用域：服务器地址 + 用户名。换服务器或换账号后旧缓存自动作废 */
  private cacheScope(): string {
    if (this._cfg === null) {
      return '';
    }
    const raw: string = this._cfg.url + '|' + this._cfg.username;
    let out: string = '';
    for (let i = 0; i < raw.length; i++) {
      const code: number = raw.charCodeAt(i);
      const alnum: boolean = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122);
      out += alnum ? raw.charAt(i) : '_';
    }
    return out;
  }

  loadSongsCache(): Track[] {
    return this.readTrackCache(KEY_SONGS_CACHE);
  }

  loadStarredCache(): Track[] {
    return this.readTrackCache(KEY_STARRED_CACHE);
  }

  saveSongsCache(tracks: Track[]): void {
    this.writeTrackCache(KEY_SONGS_CACHE, tracks);
  }

  saveStarredCache(tracks: Track[]): void {
    this.writeTrackCache(KEY_STARRED_CACHE, tracks);
  }

  private readTrackCache(base: string): Track[] {
    const scope: string = this.cacheScope();
    if (scope.length === 0 || !this.isSubsonic) {
      return [];
    }
    // 落盘用文件而不是 preferences：几千上万首序列化后是 MB 级，
    // preferences 是整值读写，塞进去会把每次 flush 都拖慢
    try {
      const path: string = this._cacheDir + '/' + base + '_' + scope + '.json';
      if (!fs.accessSync(path)) {
        return [];
      }
      const raw: string = fs.readTextSync(path);
      if (raw.length === 0) {
        return [];
      }
      const parsed: Object = JSON.parse(raw);
      const obj = parsed as Record<string, Object>;
      const at: number = this.cacheNum(obj['at']);
      if (at > 0 && Date.now() - at > CACHE_TTL_MS) {
        return [];
      }
      const arr: Object[] = obj['songs'] as Object[];
      if (arr === undefined || arr === null) {
        return [];
      }
      const out: Track[] = [];
      for (const item of arr) {
        const o = item as Record<string, Object>;
        const id: string = asString(o['id'], '');
        if (id.length === 0) {
          continue;
        }
        const album: string = asString(o['album'], '');
        // streamUrl 不存：播放内核会按当前登录态现场拼，存了反而可能过期
        out.push({
          id: id,
          href: id,
          title: asString(o['title'], '未知曲目'),
          artist: asString(o['artist'], ''),
          album: album,
          folder: album,
          size: this.cacheNum(o['size']),
          duration: this.cacheNum(o['duration']),
          cached: false,
          cachedPath: '',
          coverArt: asString(o['coverArt'], ''),
          albumId: asString(o['albumId'], ''),
          suffix: asString(o['suffix'], ''),
          bitRate: this.cacheNum(o['bitRate']),
          samplingRate: this.cacheNum(o['samplingRate']),
          bitDepth: this.cacheNum(o['bitDepth']),
          streamUrl: '',
          created: this.cacheNum(o['created']),
          playCount: this.cacheNum(o['playCount'])
        });
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  private writeTrackCache(base: string, tracks: Track[]): void {
    const scope: string = this.cacheScope();
    if (scope.length === 0 || !this.isSubsonic) {
      return;
    }
    // 空列表不存（会把有效缓存顶掉）；超上限不存（解析太慢）
    if (tracks.length === 0 || tracks.length > SONGS_CACHE_MAX) {
      return;
    }
    const arr: Record<string, Object>[] = [];
    for (const t of tracks) {
      arr.push({
        'id': t.id, 'title': t.title, 'artist': t.artist, 'album': t.album,
        'albumId': t.albumId, 'coverArt': t.coverArt, 'suffix': t.suffix,
        'size': t.size, 'duration': t.duration, 'bitRate': t.bitRate,
        'samplingRate': t.samplingRate, 'bitDepth': t.bitDepth,
        'created': t.created === undefined ? 0 : t.created,
        'playCount': t.playCount === undefined ? 0 : t.playCount
      } as Record<string, Object>);
    }
    const payload: Record<string, Object> = {
      'at': Date.now(), 'songs': arr
    } as Record<string, Object>;
    try {
      const path: string = this._cacheDir + '/' + base + '_' + scope + '.json';
      const fd: number = fs.openSync(path,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC).fd;
      fs.writeSync(fd, JSON.stringify(payload));
      fs.closeSync(fd);
    } catch (e) {
      // 存不下就算了：缓存只是加速，不能因为写缓存失败影响列表
    }
  }

  private cacheNum(v: Object | undefined): number {
    if (v === undefined || v === null) {
      return 0;
    }
    const n: number = Number(v);
    return isFinite(n) ? n : 0;
  }

  /** 曲库歌曲总数（服务器扫描到的音乐文件数），页头用它显示完整数量 */
  async getScanCount(): Promise<number> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return 0;
    return s.getScanCount();
  }

  async getArtist(id: string): Promise<ArtistDetail> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) {
      const empty: ArtistDetail = { artist: null, albums: [] };
      return empty;
    }
    return s.getArtist(id);
  }

  async getAlbumSongs(albumId: string): Promise<AlbumDetail> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) {
      const empty: AlbumDetail = { album: null, songs: [] };
      return empty;
    }
    return s.getAlbum(albumId);
  }

  async search(query: string): Promise<SearchResult> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) {
      const empty: SearchResult = { artists: [], albums: [], songs: [] };
      return empty;
    }
    return s.search3(query);
  }

  async listStarred(): Promise<StarredResult> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) {
      const empty: StarredResult = { artists: [], albums: [], songs: [] };
      return empty;
    }
    return s.getStarred2();
  }

  async listGenres(): Promise<Genre[]> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return [];
    return s.getGenres();
  }

  async randomSongs(size: number): Promise<Track[]> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return [];
    return s.getRandomSongs(size);
  }

  /**
   * 每日推荐：同一天内固定不变，跨天自动换一批。
   * 结果写进本地 preferences，否则每次进首页都会重新随机，失去「每日」的含义。
   *
   * 「固定」不等于「锁死」：歌在服务器上被删掉之后，旧存档会把死链一直推到首页，
   * 点了就报「找不到这首歌」，而且一整天都不会自己好。所以每天第一次调用时，
   * 对展示的那几首做一次存活校验，删掉的用候选池里其他的补上。
   */
  async getDailyPicks(showSize: number, poolSize: number): Promise<Track[]> {
    const today: string = dayKey();
    if (this.pref !== null) {
      const raw: string = this.pref.getSync(KEY_DAILY, '') as string;
      if (raw.length > 0) {
        try {
          const box: DailyPickBox = JSON.parse(raw) as DailyPickBox;
          if (box.date === today) {
            const pool: Track[] = box.songs;
            if (pool.length >= showSize) {
              // 本次运行内已经查过就不再查；重启 App 会重新查一次
              if (this._dailyTry === today) {
                return pool.slice(0, showSize);
              }
              this._dailyTry = today;
              const fixed: Track[] | null = await this.verifyDaily(pool, showSize, poolSize);
              if (fixed === null) {
                return pool.slice(0, showSize);
              }
              await this.saveDaily(today, fixed);
              return fixed.slice(0, showSize);
            }
          }
        } catch (e) {
        }
      }
    }
    const pool: Track[] = await this.randomSongs(poolSize);
    if (pool.length > 0) {
      // 刚抽出来的池子，服务端此刻还在，直接记成今天已校验，省掉一次回查
      await this.saveDaily(today, pool);
    }
    return pool.slice(0, showSize);
  }

  /** 写每日推荐存档：日期 + 候选池 */
  private async saveDaily(today: string, pool: Track[]): Promise<void> {
    if (this.pref === null) {
      return;
    }
    try {
      const box: DailyPickBox = { date: today, songs: pool };
      await this.pref.put(KEY_DAILY, JSON.stringify(box));
      await this.pref.flush();
    } catch (e) {
    }
  }

  /**
   * 校验推荐池：剔掉服务器上已经删掉的歌，同时把还在的歌换成服务器当前的数据。
   *
   * 后一件事和「删歌」同样重要：存档里的 Track 是抽池那天的快照，
   * 里面的 streamUrl / coverArt 由当时的登录状态生成。版本升级、换服务器地址、
   * 改密码之后这些字段就可能失效，表现为「点了不播、封面空白」——
   * 而列表其他位置每次都从服务器拉、所以只有每日推荐出问题。顺手刷新一遍即可。
   *
   * 返回 null 表示「不用改」（全都问不出来，或既没有删除也没有新数据）；
   * 返回新池表示已修好，由调用方落盘。
   */
  private async verifyDaily(pool: Track[], showSize: number, poolSize: number): Promise<Track[] | null> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) {
      return null;
    }
    // 多查几首：只查展示的 4 首的话，补位补进来的第 5 首可能也是死链，
    // 下次还得再发现一次。查 8 首能留出补位余量，成本只是多四个小请求
    const head: Track[] = pool.slice(0, Math.min(pool.length, showSize + 4));
    const probes: SongProbe[] = await Promise.all(head.map((t: Track) => s.probeSong(t.id)));
    const gone: string[] = [];
    const fresh: Map<string, Track> = new Map();
    let known: number = 0;
    for (let i = 0; i < head.length; i++) {
      const p: SongProbe = probes[i];
      if (p.state === 'unknown') {
        continue;
      }
      known++;
      if (p.state === 'gone') {
        gone.push(head[i].id);
      } else if (p.track !== null) {
        fresh.set(p.track.id, p.track);
      }
    }
    // 一首都没问出结果：多半是 NAS 掉线或登录过期。这时候整池原样保留——
    // 因为连不上就把推荐清空，比留着几首可能失效的歌糟糕得多
    if (known === 0) {
      return null;
    }
    if (gone.length === 0 && fresh.size === 0) {
      return null;
    }
    const alive: Track[] = [];
    for (const t of pool) {
      if (gone.indexOf(t.id) >= 0) {
        continue;
      }
      if (alive.some((x: Track) => x.id === t.id)) {
        continue;
      }
      // 回查到的最新数据优先，没回查到的（网络失败那几首）沿用旧快照
      const f: Track | undefined = fresh.get(t.id);
      alive.push(f !== undefined ? f : t);
    }
    // 池子被删得不够展示了，重新抽一批补进来（新抽的也可能和池内重复，去重后再说）
    if (alive.length < showSize) {
      try {
        const extra: Track[] = await this.randomSongs(poolSize);
        for (const t of extra) {
          if (alive.length >= poolSize) {
            break;
          }
          if (gone.indexOf(t.id) >= 0 || alive.some((x: Track) => x.id === t.id)) {
            continue;
          }
          alive.push(t);
        }
      } catch (e) {
      }
    }
    if (alive.length === 0) {
      return null;
    }
    return alive;
  }

  /**
   * 播放时发现这首歌在服务器上没了，立刻把它从当天的推荐池里踢掉，
   * 免得用户下次进首页还看到同一首死链。跨天的存档本来就该重抽，不动。
   */
  async dropDailyPick(trackId: string): Promise<boolean> {
    if (this.pref === null) {
      return false;
    }
    const today: string = dayKey();
    const raw: string = this.pref.getSync(KEY_DAILY, '') as string;
    if (raw.length === 0) {
      return false;
    }
    try {
      const box: DailyPickBox = JSON.parse(raw) as DailyPickBox;
      if (box.date !== today) {
        return false;
      }
      let hit: boolean = false;
      const kept: Track[] = [];
      for (const t of box.songs) {
        if (t.id === trackId) {
          hit = true;
        } else {
          kept.push(t);
        }
      }
      if (!hit) {
        return false;
      }
      // 池子少了一首，让下一次进首页重新校验并补位
      await this.saveDaily(today, kept);
      this._dailyTry = '';
      return true;
    } catch (e) {
      return false;
    }
  }

  async starSong(songId: string): Promise<boolean> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return false;
    return s.star(songId);
  }

  /** 查询歌曲当前收藏状态 */
  async isStarred(songId: string): Promise<boolean> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return false;
    return s.getSongStarred(songId);
  }

  /** 取歌词（带时间轴优先） */
  async lyricsFor(track: Track): Promise<LyricsResult> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) {
      const empty: LyricsResult = { lines: [], synced: false };
      return empty;
    }
    // 歌词就几 KB，按 songId 在内存里存一份：重放同一首不再发请求，
    // 切歌回来也不用等。空结果也缓存——没歌词的歌每次播放都白打一遍接口
    const hit: LyricsResult | undefined = this._lyricCache.get(track.id);
    if (hit !== undefined) {
      return hit;
    }
    const r: LyricsResult = await s.getLyrics(track.id, track.artist, track.title);
    if (this._lyricCache.has(track.id)) {
      this._lyricCache.delete(track.id);
    }
    this._lyricCache.set(track.id, r);
    if (this._lyricCache.size > LYRIC_CACHE_MAX) {
      // Map 迭代按插入序，最前面的是最久没用的
      const oldest: string | undefined = this._lyricCache.keys().next().value;
      if (oldest !== undefined) {
        this._lyricCache.delete(oldest);
      }
    }
    return r;
  }

  async unstarSong(songId: string): Promise<boolean> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return false;
    return s.unstar(songId);
  }

  // ================ 歌单 ================

  /** 全部歌单（只有元信息，不含曲目） */
  async listPlaylists(): Promise<Playlist[]> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return [];
    return s.getPlaylists();
  }

  /** 歌单详情（含曲目）；失败返回 null 由界面提示 */
  async getPlaylist(id: string): Promise<Playlist | null> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return null;
    return s.getPlaylist(id);
  }

  /** 新建歌单，返回新 id（失败为空串） */
  async createPlaylist(name: string, songIds: string[]): Promise<string> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return '';
    return s.createPlaylist(name, songIds);
  }

  /** 改名 / 加歌 / 删歌，返回是否成功 */
  async updatePlaylist(playlistId: string, name: string,
    addIds: string[], removeIndexes: number[]): Promise<boolean> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return false;
    return s.updatePlaylist(playlistId, name, addIds, removeIndexes);
  }

  async deletePlaylist(playlistId: string): Promise<boolean> {
    const s: Subsonic | null = this.subsonicClient();
    if (s === null) return false;
    return s.deletePlaylist(playlistId);
  }

  // ================ 搜索历史 ================

  /** 读搜索历史，最近的在前。读失败就当空历史，不影响搜索本身 */
  searchHistory(): string[] {
    if (this.pref === null) {
      return [];
    }
    try {
      const raw: string = this.pref.getSync(KEY_SEARCH_HISTORY, '') as string;
      if (raw.length === 0) {
        return [];
      }
      return JSON.parse(raw) as string[];
    } catch (e) {
      return [];
    }
  }

  /**
   * 记一条搜索历史。
   * 重复关键词提到最前（而不是留两条），超过上限丢最旧的。
   */
  async addSearchHistory(word: string): Promise<void> {
    const w: string = word.trim();
    if (w.length === 0 || this.pref === null) {
      return;
    }
    const old: string[] = this.searchHistory();
    const next: string[] = [w];
    for (const k of old) {
      if (k !== w && next.length < SEARCH_HISTORY_MAX) {
        next.push(k);
      }
    }
    try {
      await this.pref.put(KEY_SEARCH_HISTORY, JSON.stringify(next));
      await this.pref.flush();
    } catch (e) {
    }
  }

  /** 删一条搜索历史 */
  async removeSearchHistory(word: string): Promise<void> {
    if (this.pref === null) {
      return;
    }
    const next: string[] = [];
    for (const k of this.searchHistory()) {
      if (k !== word) {
        next.push(k);
      }
    }
    try {
      await this.pref.put(KEY_SEARCH_HISTORY, JSON.stringify(next));
      await this.pref.flush();
    } catch (e) {
    }
  }

  /**
   * 保存播放队列。
   *
   * 只存「重建队列所需的最小信息」，不存整个 Track：
   * 队列里可能有几百首，每个 Track 带 streamUrl（很长）、
   * cachedPath（绝对路径，换机就失效），全存进去又大又没意义。
   * 恢复时用 id 回查，查不到的跳过——服务器换了、歌删了都能自然退化。
   */
  async saveQueue(tracks: Track[], index: number, position: number): Promise<void> {
    if (this.pref === null) {
      return;
    }
    try {
      // 截断：从当前曲目往前留一段、往后留 2 倍，保证「上一首」还能用
      let list: Track[] = tracks;
      let idx: number = index;
      if (list.length > QUEUE_MAX) {
        const from: number = Math.max(0, index - Math.floor(QUEUE_MAX / 3));
        list = tracks.slice(from, from + QUEUE_MAX);
        idx = index - from;
      }
      const slim: QueueEntry[] = [];
      for (const t of list) {
        slim.push({
          id: t.id, href: t.href, title: t.title, artist: t.artist,
          album: t.album, duration: t.duration, coverArt: t.coverArt,
          albumId: t.albumId, suffix: t.suffix, bitRate: t.bitRate,
          samplingRate: t.samplingRate, bitDepth: t.bitDepth,
          streamUrl: t.streamUrl, size: t.size, folder: t.folder
        });
      }
      const data: QueueArchive = { tracks: slim, index: idx, position: position };
      await this.pref.put(KEY_QUEUE, JSON.stringify(data));
      await this.pref.flush();
    } catch (e) {
    }
  }

  /** 读取队列存档。数据损坏或版本不匹配时一律当作空队列，不抛异常 */
  async loadQueue(): Promise<Track[]> {
    this._queuedIndex = -1;
    this._queuedPosition = 0;
    if (this.pref === null) {
      return [];
    }
    try {
      const raw: string = this.pref.getSync(KEY_QUEUE, '') as string;
      if (raw.length === 0) {
        return [];
      }
      const data = JSON.parse(raw) as QueueArchive;
      if (data === null || data.tracks === undefined || data.tracks.length === 0) {
        return [];
      }
      this._queuedIndex = typeof data.index === 'number' ? data.index : 0;
      this._queuedPosition = typeof data.position === 'number' ? data.position : 0;
      const out: Track[] = [];
      for (const e of data.tracks) {
        if (e.id === undefined || e.id.length === 0) {
          continue;
        }
        out.push({
          id: e.id,
          href: e.href ?? '',
          title: e.title ?? '',
          artist: e.artist ?? '',
          album: e.album ?? '',
          folder: e.folder ?? '',
          size: e.size ?? 0,
          duration: e.duration ?? 0,
          cached: false,
          cachedPath: '',
          coverArt: e.coverArt ?? '',
          albumId: e.albumId ?? '',
          suffix: e.suffix ?? '',
          bitRate: e.bitRate ?? 0,
          samplingRate: e.samplingRate ?? 0,
          bitDepth: e.bitDepth ?? 0,
          streamUrl: e.streamUrl ?? ''
        });
      }
      // 存档里的下标可能超出（中间删过歌、或者截断过），夹一下
      if (this._queuedIndex < 0 || this._queuedIndex >= out.length) {
        this._queuedIndex = 0;
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  async clearQueue(): Promise<void> {
    this._queuedIndex = -1;
    this._queuedPosition = 0;
    if (this.pref === null) {
      return;
    }
    try {
      await this.pref.put(KEY_QUEUE, '');
      await this.pref.flush();
    } catch (e) {
    }
  }

  /** 存档里记的当前曲目下标（restoreQueue 用） */
  get queuedIndex(): number {
    return this._queuedIndex;
  }

  /** 存档里记的播放位置（毫秒） */
  get queuedPosition(): number {
    return this._queuedPosition;
  }

  /** 清空搜索历史 */
  async clearSearchHistory(): Promise<void> {
    if (this.pref === null) {
      return;
    }
    try {
      await this.pref.put(KEY_SEARCH_HISTORY, '[]');
      await this.pref.flush();
    } catch (e) {
    }
  }

  async clearCache(): Promise<void> {
    try {
      const files: string[] = fs.listFileSync(this._cacheDir);
      for (const f of files) {
        const fp: string = this._cacheDir + '/' + f;
        try { fs.unlinkSync(fp); } catch (e) {}
      }
    } catch (e) {}
    this._cacheManifest.clear();
    if (this.pref !== null) {
      try {
        await this.pref.put(KEY_CACHE_MANIFEST, '[]');
        await this.pref.delete(KEY_CACHED);
        await this.pref.flush();
      } catch (e) {
      }
    }
    // 正在播放的那首：文件已经删了，缓存的本地路径必须一起失效，
    // 否则 PlayerCore.ensureSource 会先命中 cachedPath、再因文件不存在回退。
    // 回退本身没坏，但会让首次播放多一次失败的 stat，顺手清干净更稳。
    try {
      const cur: Track | null = this._player === null ? null : this._player.currentTrack;
      if (cur !== null && cur.cached) {
        cur.cached = false;
        cur.cachedPath = '';
      }
    } catch (e) {
    }
  }
}

/** 本地日期键（YYYY-MM-DD），用于判定「每日推荐」是否跨天 */
function dayKey(): string {
  const d: Date = new Date();
  const m: number = d.getMonth() + 1;
  const day: number = d.getDate();
  return d.getFullYear().toString() + '-' + (m < 10 ? '0' : '') + m.toString() +
    '-' + (day < 10 ? '0' : '') + day.toString();
}

function asString(v: Object | undefined, def: string): string {  if (v === undefined || v === null) {
    return def;
  }
  const s: string = String(v);
  return s.length > 0 ? s : def;
}
