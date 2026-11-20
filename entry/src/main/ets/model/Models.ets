/** 数据源类型：当前仅支持 Navidrome（Subsonic 协议），WebDAV 保留底层实现但不再对外暴露 */
export type DataSourceType = 'webdav' | 'subsonic';

export interface ServerConfig {
  type: DataSourceType;
  url: string;
  username: string;
  password: string;
  rootPath: string;
}

export interface TestResult {
  ok: boolean;
  msg: string;
  count: number;
}

export interface ScanResult {
  folders: WebDavEntry[];
  tracks: Track[];
}

export interface WebDavEntry {
  href: string;
  displayName: string;
  isDirectory: boolean;
  size: number;
  contentType: string;
  lastModified: number;
}

/** Subsonic 歌手 */
export interface Artist {
  id: string;
  name: string;
  albumCount: number;
  coverArt: string;
}

/** Subsonic 专辑 */
export interface Album {
  id: string;
  name: string;
  artist: string;
  artistId: string;
  coverArt: string;
  songCount: number;
  year: number;
  genre: string;
}

/** Subsonic 风格 */
export interface Genre {
  value: string;
  songCount: number;
  albumCount: number;
}

/**
 * Subsonic 歌单。
 * owner 非空且不等于当前用户名时表示不是自己的歌单（Navidrome 的智能歌单 owner 为 navidrome），
 * 这类歌单只能看不能改删。
 */
export interface Playlist {
  id: string;
  name: string;
  /** 曲目数，列表页显示用；详情页以 songs 实际长度为准 */
  songCount: number;
  /** 总时长（毫秒），服务端不给时客户端累加 */
  duration: number;
  /** 封面 id，可能为空 */
  coverArt: string;
  owner: string;
  /** 创建时间戳（毫秒） */
  created: number;
  /** 最后修改时间戳（毫秒），用于「最近修改」排序 */
  changed: number;
  /** 是否可编辑：只有自己的歌单才能改名 / 加减曲目 / 删除 */
  editable: boolean;
  /** 曲目列表，仅 getPlaylist 详情接口返回 */
  songs: Track[];
}

/** 歌手详情（含专辑列表） */
export interface ArtistDetail {
  artist: Artist | null;
  albums: Album[];
}

/** 专辑详情（含歌曲列表） */
export interface AlbumDetail {
  album: Album | null;
  songs: Track[];
}

/** 搜索结果 */
export interface SearchResult {
  artists: Artist[];
  albums: Album[];
  songs: Track[];
}

/** 收藏列表 */
export interface StarredResult {
  artists: Artist[];
  albums: Album[];
  songs: Track[];
}

export interface Track {
  id: string;
  href: string;
  title: string;
  artist: string;
  album: string;
  folder: string;
  size: number;
  duration: number;
  cached: boolean;
  cachedPath: string;
  /** Subsonic 专属字段 */
  coverArt: string;
  albumId: string;
  suffix: string;
  bitRate: number;
  /** 采样率（Hz），Subsonic 返回；用于列表音质行显示 44.1kHz */
  samplingRate: number;
  /** 位深，无损格式才有值 */
  bitDepth: number;
  /** 流式播放 URL（Subsonic 模式直连，WebDAV 模式为空） */
  streamUrl: string;
  /** 入库时间（毫秒），Subsonic 返回；「最近添加」排序用 */
  created?: number;
  /** 服务端播放次数；「最常播放」排序用（服务端没给时回落到本机统计） */
  playCount?: number;
}

export interface PlayState {
  isPlaying: boolean;
  currentIndex: number;
  position: number;
  duration: number;
}

/** 一行歌词。start 为毫秒时间轴，纯文本歌词时统一为 0 */
export interface LyricLine {
  start: number;
  text: string;
}

/** 歌词结果。synced 为 true 表示带时间轴，可滚动高亮 */
export interface LyricsResult {
  lines: LyricLine[];
  synced: boolean;
}

export type RepeatMode = 'off' | 'all' | 'one';

/** 播放页四态播放模式：顺序循环 / 随机播放 / 单曲循环 / 播放喜爱 */
/**
 * 播放模式。
 *   seq    顺序播放：播到队尾就停
 *   loop   列表循环：播到队尾回到第一首
 *   one    单曲循环
 *   shuffle 随机播放（在循环队列里随机，不会重复到不放歌）
 * 「播放喜爱」不是播放模式，是一个「用收藏歌曲建立一个队列」的动作，
 * 单独放在 PlayerCore.playFavorites()，不再混进这里。
 */
export type PlayMode = 'seq' | 'loop' | 'one' | 'shuffle';

/**
 * 「全部歌曲」页的排序方式。
 *   default 服务器默认顺序（search3 原始返回）
 *   title  标题 A–Z
 *   artist 按歌手
 *   album  按专辑
 *   added  最近添加（created 降序）
 *   plays  最常播放（服务端次数优先，回落本机统计；降序）
 *   random 随机（对已加载列表洗牌一次）
 * 除 default 外都在客户端排：曲库会后台预载全量，本地排序比让服务器排更通用。
 */
export type SongsSort = 'default' | 'title' | 'artist' | 'album' | 'added' | 'plays' | 'random';

/** 播放队列存档里单条曲目的精简形态（不含 cachedPath 这类本机路径） */
export interface QueueEntry {
  id: string;
  href: string;
  title: string;
  artist: string;
  album: string;
  duration: number;
  coverArt: string;
  albumId: string;
  suffix: string;
  bitRate: number;
  samplingRate: number;
  bitDepth: number;
  streamUrl: string;
  size: number;
  folder: string;
}

/** 完整的队列存档 */
export interface QueueArchive {
  tracks: QueueEntry[];
  index: number;
  position: number;
}

/**
 * 单曲存活探测结果。
 * state: 'ok'     → 还在，track 是服务器刚返回的最新数据（用来刷新本地旧快照）
 *        'gone'   → 服务器明确回答没有这首
 *        'unknown'→ 网络/鉴权问题，判断不了，调用方不能当成删除
 */
export interface SongProbe {
  state: string;
  track: Track | null;
}

/**
 * 「每日推荐」的本地存档。
 * songs 是整个候选池（比首页展示的 4 首要大），删歌后能在池内补位、不用重新随机。
 */
export interface DailyPickBox {
  /** 抽池日期（YYYY-MM-DD），跨天就重抽 */
  date: string;
  songs: Track[];
}

/** 播放页外观：classic = 银灰余音玻璃版（默认）；vinyl = 唱片封套版；clock = 时计机芯版 */
export type PlayerSkin = 'classic' | 'vinyl' | 'clock';

export interface AppSettings {
  autoCache: boolean;
  volume: number;
  /** 上次的播放模式，启动时恢复。老版本数据里没有这个字段，按 'loop' 处理 */
  playMode?: PlayMode;
  /** 「全部歌曲」页的排序方式，启动时恢复。老版本数据没有这个字段，按 'default' 处理 */
  songsSort?: SongsSort;
  /** 电台续播：队列快放完时自动追加相似歌曲。老版本没有这个字段，默认开启 */
  radio?: boolean;
  /** 播放上报：把正在播放 / 已听够 提交给服务器（scrobble）。默认开启 */
  scrobble?: boolean;
  /** 播放页外观。老版本没有这个字段，按经典玻璃版处理 */
  playerSkin?: PlayerSkin;
}

/** 单曲收听统计：一首歌被播放了几次、一共听了多久 */
/** 本地缓存占用：字节数与文件数，设置页「清空缓存」展示用 */
export interface CacheUsage {
  bytes: number;
  files: number;
}

export interface TrackStat {
  id: string;
  title: string;
  artist: string;
  /** 播放次数（每次开始播放计一次） */
  plays: number;
  /** 累计收听秒数 */
  seconds: number;
  /** 最后一次播放时间戳，用于同分排序与淘汰 */
  lastAt: number;
  /** 音质快照：统计页按格式/位深/采样率分桶用。老记录没有这几个字段，缺失即不计入 */
  suffix?: string;
  bitDepth?: number;
  samplingRate?: number;
}

/**
 * 最近播放的一条记录。
 * 存整份 Track 快照而不是只存 id：列表要立刻能画（封面、时长、音质都在里面），
 * 点进去也要能直接播——只有 id 的话还得回服务器再查一次。
 */
export interface RecentEntry {
  track: Track;
  /** 上次听到第几秒；0 表示从头放 */
  pos: number;
  /** 这次播放的时间戳 */
  at: number;
}

export const DEFAULT_SETTINGS: AppSettings = {
  autoCache: true,
  volume: 80,
  playMode: 'loop',
  songsSort: 'default',
  radio: true,
  scrobble: true,
  playerSkin: 'classic',
};

/** 当前仅支持 Navidrome（Subsonic 协议），统一返回 subsonic */
export function configType(cfg: ServerConfig | null): DataSourceType {
  return 'subsonic';
}
