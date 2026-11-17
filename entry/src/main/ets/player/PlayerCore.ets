import { BusinessError } from '@kit.BasicServicesKit';
import media from '@ohos.multimedia.media';
import audio from '@ohos.multimedia.audio';
import fs from '@ohos.file.fs';
import avSession from '@ohos.multimedia.avsession';
import { Track, RepeatMode, PlayMode, LyricLine } from '../model/Models';
import { WebDav } from '../net/WebDav';
import { Subsonic } from '../net/Subsonic';
import { Store } from '../store/Store';
import { MediaSession } from './MediaSession';
import { FormSync } from '../utils/FormSync';

type PlayerState = 'idle' | 'initialized' | 'prepared' | 'playing' | 'paused' | 'completed' | 'error';

/** 电台续播：每次向服务器要多少首相似歌 */
const RADIO_BATCH: number = 20;
/** 电台续播：一轮队列最多追加多少首。不设上限的话循环听一整天会把队列撑到几千首 */
const RADIO_MAX: number = 60;
/** 上报阈值：听完一半或满 4 分钟即计入一次播放（Last.fm 通行的口径） */
const SCROBBLE_MIN_MS: number = 240000;
/**
 * 乐观起播的宽限期。
 * 按下播放后界面立刻切成「播放中」，但底层 AVPlayer 还要一段时间才真的
 * 从 paused 转到 playing（蓝牙输出重建时更久）。这段时间里拒绝用底层状态回写，
 * 600ms 足够覆盖常见机型，也不至于把真正的「点了没反应」藏太久。
 */
const OPTIMISTIC_PLAY_MS: number = 600;

/**
 * 播放器核心：AVPlayer 封装 + 队列 + 缓存。
 * Subsonic 直接流式播放；WebDAV 下载到本地缓存后播放。
 * 同时接入媒体会话（MediaSession），实现后台播放与系统媒体卡片控制。
 */
export class PlayerCore {
  private avPlayer: media.AVPlayer | null = null;
  /** 音量 0~1。AVPlayer 的音量挂在实例上，每次重建都得重新贴回去 */
  private volumeLevel: number = 0.7;
  private session: media.AVMetadata | null = null;
  private queue: Track[] = [];
  private index: number = -1;
  private state: PlayerState = 'idle';
  private posTimer: number = -1;
  /** 上一次进度 tick 的时间戳（ms），用于累计听歌时长 */
  private lastTickAt: number = 0;
  private _position: number = 0;
  /** _position 这次采样的时间戳（ms）。livePosition 靠它把两次采样之间的时间补回来 */
  private _posSampledAt: number = 0;
  /** 上一次推给 AppStorage 的位置/时长，用于节流，避免 200ms 一次刷新全局状态 */
  private _lastPushedPos: number = -1;
  private _lastPushedDur: number = -1;
  /** 恢复队列后续播的起始位置。loadCurrent 走到 prepared 时 seek 过去，用完即清 */
  private _pendingStartPos: number = 0;
  /** 上次落盘存档时的播放位置。位置类写入按 5s 节流，900ms 一次 stringify+flush 太浪费 */
  private _lastSavedPos: number = -1;
  private _duration: number = 0;
  private shuffle: boolean = false;
  // 默认列表循环：与播放页默认显示的「循环」图标、以及系统卡片声明的 LOOP_MODE_LIST 保持一致
  private repeat: RepeatMode = 'all';
  /** 播放喜爱模式：队列被替换为收藏歌曲 */
  private favMode: boolean = false;
  /** 当前曲目的收藏状态（锁屏喜爱按钮与播放页共用） */
  private favState: boolean = false;
  private favTrackId: string = '';
  private shuffledOrder: number[] = [];
  private loadingTrack: Track | null = null;
  private media: MediaSession | null = null;
  // 当前曲目的歌词缓存：给灵动岛/迷你条同步当前歌词行
  private lyricLines: LyricLine[] = [];
  private lyricSynced: boolean = false;
  private curLyricLine: string = '';
  /**
   * 当前曲目的整份 LRC 文本：随 metadata 一次性交给系统（锁屏/播控中心/桌面歌词），
   * 系统自己按时间轴逐行滚，应用侧不用为歌词反复重建媒体卡片。无同步歌词时为空串。
   */
  private lrcText: string = '';
  /**
   * 是否被外部打断（来电、别的 App 抢音频焦点、蓝牙断开…）。
   * 打顿时按 true，恢复时才决定要不要自动续播。
   * 用户在被停顿期间自己按了播放/暂停，就把这个标记清掉，
   * 免得打断解除后系统又把他刚做的操作覆盖回去。
   */
  private interrupted: boolean = false;
  /**
   * 最近一次「暂停是被动发生的」原因。空串表示用户主动暂停。
   * 界面据此显示「已被其他应用暂停」之类的提示，而不是让人以为 App 自己抽风了。
   */
  private pauseReason: string = '';
  /**
   * 本会话是否已降级为「服务器转码 mp3」。
   * 触发条件只有一个：直连播放被系统判为格式不支持（5400106 / demux 失败）。
   * 一旦降级就保持，否则整个 Hi-Res 曲库会每首歌都先失败一遍再转码。
   */
  private forceTranscode: boolean = false;
  /** 已经因格式问题重试过的曲目，同一首只降级一次，避免来回打转 */
  private retriedTrackId: string = '';
  /**
   * 转码这条路已经验证走不通（服务器没装 ffmpeg、或参数不被接受）。
   * 一旦置位，本会话不再尝试转码，避免每首歌都先绕一圈死路。
   */
  private transcodeBroken: boolean = false;
  /** 最近一次 AVPlayer 的业务错误码。stateChange 的 error 分支只能拿到状态，码在这里补 */
  private lastErrorCode: string = '';
  /** 失败处理去重：stateChange 的 error 与 error 回调常常前后脚到达，只能算一次 */
  private failHandledAt: number = 0;
  /**
   * 最近一次彻底播不出来的曲目。
   * 界面已经不弹任何失败提示了，播放键就是唯一的重试入口：
   * 点击时发现还停在这首上，就重新取源准备一次。
   */
  private failedTrackId: string = '';

  /**
   * 媒体会话正在后台初始化。
   * 有了这个标记，连续快速切歌时不会并发 new 出两个 MediaSession
   * （两个都 init 会把系统卡片注册两遍，暂停指令可能被投递到已废弃的那个）。
   */
  private sessionPending: boolean = false;
  /** 上一次「乐观置为播放中」的时间戳，配合 OPTIMISTIC_PLAY_MS 做宽限期判断 */
  private optimisticPlayAt: number = 0;

  // ---------------- 电台续播 ----------------
  /** 本轮队列已追加的相似歌曲数，到 RADIO_MAX 就停 */
  private radioFetched: number = 0;
  /** 正在拉相似歌，防重入（tick 每 200ms 都会调用一次触发判断） */
  private radioBusy: boolean = false;
  /**
   * 本轮队列已经确认「拉不到相似歌」。
   * Navidrome 没配 Last.fm 时 getSimilarSongs 永远返回空，
   * 不记住这个结果就会每 200ms 发一次请求。
   */
  private radioDead: boolean = false;
  /** 拉取失败后的下一次重试时间：网络抖动不该把整轮电台判死 */
  private radioRetryAt: number = 0;

  // ---------------- 播放上报 ----------------
  /** 已发过「正在播放」的曲目 id */
  private scrobbleNowId: string = '';
  /** 已发过「听够了」的曲目 id，同一首只计一次 */
  private scrobbledId: string = '';
  /** 本次开播的时间戳，作为 scrobble 的 time 字段 */
  private scrobbleAt: number = 0;

  onStateChange: ((playing: boolean, loading: boolean) => void) | null = null;
  onTrackChange: ((track: Track | null) => void) | null = null;
  onProgress: ((position: number, duration: number) => void) | null = null;
  /** 收藏状态变化（含锁屏切换），播放页据此同步红心 */
  onFavChange: ((fav: boolean) => void) | null = null;
  /** 播放模式变化（含锁屏切换），播放页据此同步图标 */
  onPlayModeChange: ((mode: PlayMode) => void) | null = null;
  /**
   * 播放失败只在内部处理：先自动降级转码，仍不行就静默回到暂停态。
   * 不往界面抛提示——用户明确不要这类文案，重试由播放键本身承担。
   */

  /**
   * 启动时恢复上次的播放模式。
   * 只还原「怎么放」，不碰队列——队列本来就不落盘（见说明里的已知限制），
   * 强行恢复一个模式却没有曲目可放，界面上会显得很怪。
   */
  restorePlayMode(): void {
    const m: PlayMode = Store.get().settings.playMode ?? 'loop';
    this.favMode = false;
    this.shuffle = m === 'shuffle';
    this.repeat = m === 'one' ? 'one' : (m === 'seq' ? 'off' : 'all');
    AppStorage.setOrCreate('playerPlayMode', m);
    // 音量也在这里对齐一次：AVPlayer 的默认音量是满格，
    // 而播放页读的是设置里那个值。不同步的话，界面显示 70%，
    // 实际出来的却是 100%，用户点「−」第一下还会因为「值没变」被忽略。
    const sv: number = Store.get().settings.volume;
    // 0 是合法的（静音），不能按「没设置」处理成默认 0.7
    const lv: number = isFinite(sv) ? (sv <= 0 ? 0 : (sv >= 100 ? 1 : sv / 100)) : 0.8;
    this.volumeLevel = lv;
    AppStorage.setOrCreate('playerVolume', Math.round(lv * 100));
  }

  /**
   * 恢复上次的播放队列。
   *
   * 只恢复队列和「停在哪一首、停在哪个位置」，不会自动开始播放。
   * 理由：App 被系统清理之后再打开，用户预期是「接着上次听」，
   * 而不是「一打开就突然出声」——后者在会议室、地铁里都是灾难。
   *
   * 返回恢复的曲目数（0 表示没有可恢复的队列）。
   */
  async restoreQueue(): Promise<number> {
    const q: Track[] = await Store.get().loadQueue();
    if (q.length === 0) {
      return 0;
    }
    // 没有活动服务器就别恢复：恢复出来的曲目点哪首都播不了，
    // 界面上看着像 bug，实际是没连服务器
    if (Store.get().serverConfig === null) {
      return 0;
    }
    const savedIndex: number = Store.get().queuedIndex;
    const savedPos: number = Store.get().queuedPosition;
    // 恢复缓存标记：存档里不带 cached/cachedPath（路径换机会失效），
    // 但 WebDAV 的缓存文件名由 href 决定，按清单能重算出来——
    // 不补的话，重启后播已缓存的歌会整个重新下载一遍
    const store: Store = Store.get();
    for (const t of q) {
      // 老存档里可能没有 streamUrl 字段，直接 .length 会抛错，整个队列恢复就断了
      if ((t.streamUrl ?? '').length > 0) {
        continue;
      }
      if (store.isCached(t.href)) {
        t.cached = true;
        t.cachedPath = store.cachedPathFor(t.href);
      }
    }
    this.queue = q;
    this.index = savedIndex >= 0 && savedIndex < q.length ? savedIndex : 0;
    this._position = savedPos > 0 ? savedPos : 0;
    this._duration = q[this.index].duration;
    // 存档里的位置可能比当前时长还大（换过文件、服务器重新转码过）：
    // 不夹一下的话，恢复出来的播放页进度条会超过最大值，剩余时间显示成负数
    if (this._duration > 0 && this._position > this._duration) {
      this._position = this._duration;
    }
    this._lastSavedPos = this._position;
    this.state = 'paused';
    if (this.shuffle) {
      this.rebuildShuffleOrder();
    }
    // 先把封面/歌名推出去，进度条也要显示上次的位置。
    // 这里不能走 loadCurrent()——那会立刻开始加载并播放。
    const cur: Track | null = this.currentTrack;
    if (cur !== null) {
      this.notifyTrack(cur);
    }
    this.notifyState();
    this.notifyProgress();
    return q.length;
  }

  /** 队列变了就存一次（切歌、增删、清空都会走到这里） */
  private persistQueue(): void {
    Store.get().saveQueue(this.queue, this.index, this._position).catch(() => {
    });
  }

  get currentIndex(): number {
    return this.index;
  }

  get currentTrack(): Track | null {
    if (this.index < 0 || this.index >= this.queue.length) {
      return null;
    }
    return this.queue[this.index];
  }

  get isPlaying(): boolean {
    // 以 AVPlayer 的实时状态为最终依据。
    //
    // 只用 this.state 会漏：state 只在 stateChange 回调里赋值，
    // 而 playing 事件在某些时序下会丢（prepare() 后紧接着 play()，
    // 或暂停/播放快速切换时事件被后续状态顶掉）。
    // 一旦 state 卡在 prepared/paused，就会同时出现两个错：
    //   · 按钮显示「播放」三角，但音频其实在放
    //   · 进度定时器里 state !== 'playing'，_position 一直不更新，进度条停住
    // 所以这里再问一次播放器本体，两边任一为 playing 即认为在播。
    if (this.avPlayer !== null && this.avPlayer.state === 'playing') {
      return true;
    }
    return this.state === 'playing';
  }

  /** 同 isPlaying：以播放器实时状态为准，避免事件丢失导致进度不刷新 */
  private refreshStateFromPlayer(): void {
    if (this.avPlayer === null) {
      return;
    }
    const s: PlayerState = this.avPlayer.state as PlayerState;
    // 乐观起播的宽限期（见 play()）：state 已经置成 playing，但底层还要
    // 200~500ms 才真的转过去。这段时间里不要拿底层的 paused 覆盖回去，
    // 否则按钮会先弹成暂停、再跳回播放，比不响应还难看。
    if (this.state === 'playing' && s === 'paused' &&
      Date.now() - this.optimisticPlayAt < OPTIMISTIC_PLAY_MS) {
      return;
    }
    if (s !== this.state) {
      this.state = s;
    }
  }

  get isLoading(): boolean {
    return this.loadingTrack !== null;
  }

  get position(): number {
    return this._position;
  }

  /**
   * 当前真实播放位置（毫秒），已按「距上次采样过了多久」外推。
   *
   * _position 是每 200ms 采样一次的快照，直接拿它去比歌词，
   * 误差在 0~200ms 之间随机分布，每次都不同——
   * 这就是「同一首歌有时准、有时偏」的来源（而不是固定偏移）。
   * 这里用采样时间戳把这段时间补回来，误差收敛到 100ms 以内。
   */
  get livePosition(): number {
    if (this._posSampledAt <= 0 || !this.isPlaying) {
      return this._position;
    }
    const elapsed: number = Date.now() - this._posSampledAt;
    // 只补合理范围：卡顿、后台被冻结时 elapsed 会很大，不能整段补。
    // 上限取 4 个 tick，超过说明定时器被系统压制过，此时快照本身更可信。
    if (elapsed <= 0 || elapsed > 800) {
      return this._position;
    }
    let p: number = this._position + elapsed;
    if (this._duration > 0 && p > this._duration) {
      p = this._duration;
    }
    return p;
  }

  get duration(): number {
    return this._duration;
  }

  get queueSize(): number {
    return this.queue.length;
  }

  get shuffleOn(): boolean {
    return this.shuffle;
  }

  get repeatMode(): RepeatMode {
    return this.repeat;
  }

  setShuffle(on: boolean): void {
    this.shuffle = on;
    this.favMode = false;
    if (on) {
      this.rebuildShuffleOrder();
    }
    this.pushPlayMode();
  }

  toggleShuffle(): void {
    this.setShuffle(!this.shuffle);
  }

  setRepeat(mode: RepeatMode): void {
    this.repeat = mode;
    this.favMode = false;
    this.pushPlayMode();
  }

  /** 当前播放模式（供播放页同步显示） */
  get playMode(): PlayMode {
    if (this.repeat === 'one') {
      return 'one';
    }
    if (this.shuffle) {
      return 'shuffle';
    }
    return this.repeat === 'off' ? 'seq' : 'loop';
  }

  /**
   * 切换播放模式。
   *
   * 只改「怎么放」这一件事：顺序 / 循环 / 单曲 / 随机。
   * 之前这里还兼了一个「播放喜爱」——它会清空当前队列换成收藏歌曲，
   * 那是「换队列」而不是「换模式」，两件事混在一起导致两个问题：
   *   · 点一下模式按钮，正在听的专辑就没了
   *   · 从「播放喜爱」切到别的模式时，队列仍停留在收藏歌曲上，
   *     模式显示的是循环、实际放的是收藏，两者对不上
   * 现在拆出去了，见 playFavorites()。
   */
  async setPlayMode(mode: PlayMode): Promise<void> {
    this.favMode = false;
    this.shuffle = mode === 'shuffle';
    this.repeat = mode === 'one' ? 'one' : (mode === 'seq' ? 'off' : 'all');
    if (this.shuffle) {
      this.rebuildShuffleOrder();
    }
    // 模式要用到下次启动，写进设置（写失败不影响本次切换）
    Store.get().settings.playMode = mode;
    Store.get().saveSettings(Store.get().settings).catch(() => {
    });
    this.pushPlayMode();
  }

  /**
   * 播放喜爱：把收藏歌曲建成一个新队列并开始播。
   * 这是一个动作，不是模式；放完之后模式仍按当前的循环/随机走。
   */
  async playFavorites(): Promise<number> {
    let songs: Track[] = [];
    try {
      const r = await Store.get().listStarred();
      songs = r.songs;
    } catch (e) {
    }
    if (songs.length === 0) {
      console.info('[player] 没有收藏的歌曲，忽略「播放喜爱」');
      return 0;
    }
    this.favMode = true;
    await this.playQueue(songs, 0);
    this.pushPlayMode();
    return songs.length;
  }

  /** 把当前模式推给系统卡片与界面 */
  private pushPlayMode(): void {
    if (this.media !== null) {
      this.media.updateMode(this.shuffle, this.repeat, this.favMode);
    }
    if (this.onPlayModeChange !== null) {
      this.onPlayModeChange(this.playMode);
    }
    AppStorage.setOrCreate('playerPlayMode', this.playMode);
  }

  cycleRepeat(): void {
    if (this.repeat === 'off') {
      this.repeat = 'all';
    } else if (this.repeat === 'all') {
      this.repeat = 'one';
    } else {
      this.repeat = 'off';
    }
    if (this.media !== null) {
      this.media.updateMode(this.shuffle, this.repeat, this.favMode);
    }
  }

  private rebuildShuffleOrder(): void {
    const order: number[] = [];
    for (let i = 0; i < this.queue.length; i++) {
      order.push(i);
    }
    // Fisher-Yates
    for (let i = order.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const tmp: number = order[i];
      order[i] = order[j];
      order[j] = tmp;
    }
    // 把当前曲目放第一位
    if (this.index >= 0) {
      const curIdx: number = order.indexOf(this.index);
      if (curIdx > 0) {
        const tmp: number = order[0];
        order[0] = order[curIdx];
        order[curIdx] = tmp;
      }
    }
    this.shuffledOrder = order;
  }

  /** 设置播放队列并从指定曲目开始 */
  async playQueue(tracks: Track[], startIndex: number, startPos: number = -1): Promise<void> {
    if (tracks.length === 0) {
      return;
    }
    this.queue = tracks.slice(0);
    this.index = startIndex < 0 ? 0 : Math.min(startIndex, tracks.length - 1);
    // 换了队列就是新的一轮电台：额度、失败标记都要重来，
    // 否则上一张专辑拉不到相似歌，会把后面所有队列的续播一起关掉
    this.radioFetched = 0;
    this.radioDead = false;
    this.radioRetryAt = 0;
    if (this.shuffle) {
      this.rebuildShuffleOrder();
    }
    this.persistQueue();
    await this.loadCurrent(startPos);
  }

  addToQueue(track: Track): void {
    this.queue.push(track);
    if (this.shuffle) {
      this.shuffledOrder.push(this.queue.length - 1);
    }
    this.persistQueue();
  }

  /**
   * 下一首播放：插到当前曲目正后方。
   * 顺序播放时它会成为 next() 的目标；随机播放时要把它放到
   * shuffledOrder 里当前项的下一位，否则点了「下一首播放」却排到了别处。
   */
  insertNext(track: Track): void {
    if (this.queue.length === 0 || this.index < 0) {
      this.queue.push(track);
      if (this.shuffle) {
        this.shuffledOrder.push(this.queue.length - 1);
      }
      this.persistQueue();
      return;
    }
    const at: number = this.index + 1;
    const wasShuffle: boolean = this.shuffle;
    this.queue.splice(at, 0, track);
    if (wasShuffle) {
      const cur: number = this.index;
      // 重建会把当前曲目放到首位，这里把它挪回去，用户听到的队列才不会突然跳
      this.rebuildShuffleOrder();
      this.shuffledOrder = this.shuffledOrder.filter((i: number) => i !== cur);
      this.shuffledOrder.unshift(cur);
      // at 本身就是新曲目的索引，重建后的表里已经有了，直接从表里摘掉再插到当前曲目后
      this.shuffledOrder = this.shuffledOrder.filter((i: number) => i !== at);
      this.shuffledOrder.splice(1, 0, at);
    }
    // 队列变了就要落盘：之前这里漏了，「下一首播放」的歌重启后不见，
    // 而「加入队尾」那条路径是写了的，两种操作结果不一致
    this.persistQueue();
  }

  getQueue(): Track[] {
    return this.queue.slice(0);
  }

  /**
   * 从队列里摘掉一首（队列页的「移除」）。
   * 三条约束：
   *  1. 移除位置在当前曲目之前 → 当前曲目下标整体前移一位，否则会串到后一首；
   *  2. 移除的就是当前曲目 → 下标原地不动，天然指向「下一首」，需要重新加载播放；
   *  3. 随机表里大于该位置的下标全部减一，并把它摘掉，否则随机模式会指到错歌。
   * 返回移除后的队列长度，调用方据此判断是否已空。
   */
  removeAt(index: number): number {
    if (index < 0 || index >= this.queue.length) {
      return this.queue.length;
    }
    const wasCurrent: boolean = index === this.index;
    this.queue.splice(index, 1);

    // 随机表：先摘掉自己，再把后面的下标统一左移
    if (this.shuffle) {
      const rebuilt: number[] = [];
      for (const i of this.shuffledOrder) {
        if (i === index) {
          continue;
        }
        rebuilt.push(i > index ? i - 1 : i);
      }
      this.shuffledOrder = rebuilt;
    }

    if (wasCurrent) {
      // 当前曲目被删：下标保持不变即指向原「下一首」；删的是最后一首则回退一位
      if (this.index >= this.queue.length) {
        this.index = this.queue.length - 1;
      }
      if (this.queue.length === 0) {
        this.index = -1;
        this.stopAtEnd();
        return 0;
      }
      this.loadCurrent();
      this.persistQueue();
      return this.queue.length;
    }

    if (index < this.index) {
      this.index = this.index - 1;
    }
    // 落盘放在索引调整之后：提前存的话，「删的歌在当前曲前面」
    // 这种情况存档索引会差一，恢复时停在错的歌上
    this.persistQueue();
    return this.queue.length;
  }

  /** 清空队列并停止播放（队列页右上角「清空」） */
  async clearQueue(): Promise<void> {
    this.queue = [];
    this.shuffledOrder = [];
    this.index = -1;
    // 清空 = 用户明确不要了，存档也一起清掉
    Store.get().clearQueue().catch(() => {
    });
    await this.stopAtEnd();
    // 队列空了，迷你条/卡片上还挂着上一首的歌名与封面就说不通了：
    // 它会一直占着底部，点播放又什么都不发生。这里把全局展示字段一起清掉，
    // MiniPlayer 拿到空标题后自己会整块收起。
    this.clearNowPlayingInfo();
  }

  /**
   * 清掉「当前正在播放什么」的全局展示字段。
   * 只用于队列被清空 / 播放器释放这类「确实没有歌了」的场景，
   * 暂停、切歌都不该走这里。
   */
  private clearNowPlayingInfo(): void {
    AppStorage.setOrCreate('playerTitle', '');
    AppStorage.setOrCreate('playerArtist', '');
    AppStorage.setOrCreate('playerCoverUrl', '');
    AppStorage.setOrCreate('playerPosition', 0);
    AppStorage.setOrCreate('playerDuration', 0);
    AppStorage.setOrCreate('playerPlaying', false);
    AppStorage.setOrCreate('playerLoading', false);
    AppStorage.setOrCreate('miniLyric', '');
    this.lyricLines = [];
    this.curLyricLine = '';
  }

  private nextIndex(): number {
    if (this.queue.length === 0) {
      return -1;
    }
    if (this.shuffle) {
      const pos: number = this.shuffledOrder.indexOf(this.index);
      if (pos + 1 < this.shuffledOrder.length) {
        return this.shuffledOrder[pos + 1];
      }
      if (this.repeat === 'all') {
        return this.shuffledOrder[0];
      }
      return -1;
    }
    if (this.index + 1 < this.queue.length) {
      return this.index + 1;
    }
    if (this.repeat === 'all') {
      return 0;
    }
    return -1;
  }

  private prevIndex(): number {
    if (this.queue.length === 0) {
      return -1;
    }
    if (this.shuffle) {
      const pos: number = this.shuffledOrder.indexOf(this.index);
      if (pos > 0) {
        return this.shuffledOrder[pos - 1];
      }
      if (this.repeat === 'all') {
        return this.shuffledOrder[this.shuffledOrder.length - 1];
      }
      return -1;
    }
    if (this.index > 0) {
      return this.index - 1;
    }
    if (this.repeat === 'all') {
      return this.queue.length - 1;
    }
    return -1;
  }

  async next(): Promise<void> {
    const idx: number = this.nextIndex();
    if (idx < 0) {
      await this.stopAtEnd();
      return;
    }
    this.index = idx;
    // 索引变了立刻落盘：恢复时「停在哪首」比「停在哪个位置」更容易被注意到
    this.persistQueue();
    await this.loadCurrent();
  }

  /**
   * 设置音量 0~1。记住这个值：切歌会重建 AVPlayer，
   * 新实例必须重新贴一次，否则回落到系统默认音量。
   */
  public setVolume(v: number): void {
    const nv: number = v < 0 ? 0 : (v > 1 ? 1 : v);
    this.volumeLevel = nv;
    const p: media.AVPlayer | null = this.avPlayer;
    if (p === null) {
      return;
    }
    try {
      p.setVolume(nv);
    } catch (e) {
      // 播放器还没进 prepared 时设置会抛，忽略即可：initialized 阶段会补一次
    }
  }

  /**
   * 队列播完：暂停并把进度归零。
   * 必须显式同步状态，否则系统媒体卡片会一直停在「正在播放」，
   * 用户在控制中心点暂停时也不会得到任何响应。
   */
  private async stopAtEnd(): Promise<void> {
    if (this.avPlayer !== null) {
      try {
        await this.avPlayer.pause();
      } catch (e) {
      }
    }
    this.stopPosTimer();
    this.state = 'paused';
    this._position = 0;
    this.notifyState();
    this.notifyProgress();
    // 位置归零了，存档也要跟着归零，否则恢复出来还停在上次的进度
    this._lastSavedPos = 0;
    this.persistQueue();
  }

  async prev(): Promise<void> {
    // 如果播放超过 3 秒，先回到开头
    if (this._position > 3000) {
      await this.seek(0);
      return;
    }
    const idx: number = this.prevIndex();
    if (idx < 0) {
      await this.seek(0);
      return;
    }
    this.index = idx;
    // 索引变了立刻落盘：恢复时「停在哪首」比「停在哪个位置」更容易被注意到
    this.persistQueue();
    await this.loadCurrent();
  }

  /** 重新加载当前曲目（界面上的「重试」按钮用） */
  async reloadCurrent(): Promise<void> {
    await this.loadCurrent();
  }

  private async loadCurrent(startPos: number = -1): Promise<void> {
    const track: Track | null = this.currentTrack;
    if (track === null) {
      return;
    }
    // 每次进新的一次播放都重置上报状态。
    // 放在这里而不是「play 成功之后」：同一首重播（点最近播放、单曲循环换歌）
    // 也想重新计一次，而转码重试那种同一次加载内的重复 play 不该重复发。
    this.scrobbledId = '';
    this.scrobbleNowId = '';
    this.scrobbleAt = 0;
    this.loadingTrack = track;
    this.notifyState();
    this.notifyTrack(track);
    // 会话初始化不挡起播：MediaSession.init 要跨进程建通道，首次能吃掉 100ms 以上。
    // 起播只关心「多久出声」，系统卡片晚一两帧更新看不出来，好了再补一次元数据。
    this.ensureSessionAsync();
    // 歌词异步加载，不阻塞播放
    this.loadLyrics(track);
    // 收藏状态异步查询，推给锁屏/控制中心的喜爱按钮
    this.syncFav(track);

    try {
      const source: string = await this.ensureSource(track);
      // 取源期间用户又切了歌：这份结果已经过期，直接丢弃，避免两首歌同时出声
      if (this.currentTrack === null || this.currentTrack.id !== track.id) {
        return;
      }
      await this.playFromSource(source, track, startPos);
    } catch (err) {
      // 取源期间用户已经切走了：这次失败属于上一首，不能拿它去改写
      // 当前曲目的状态（否则刚点的新歌会被打成 error、进度定时器也会被停掉）
      const cur: Track | null = this.currentTrack;
      if (cur === null || cur.id !== track.id) {
        if (this.loadingTrack !== null && this.loadingTrack.id === track.id) {
          this.loadingTrack = null;
        }
        return;
      }
      if (this.loadingTrack !== null && this.loadingTrack.id === track.id) {
        this.loadingTrack = null;
      }
      this.stopPosTimer();
      this.state = 'error';
      this.failedTrackId = track.id;
      this.notifyState();
      const msg: string = err instanceof Error ? err.message : String(err);
      console.error('[player] 加载失败：' + msg);
      this.reportPlayError(msg);
    }
  }

  /**
   * 播放失败的统一出口。
   *
   * 先试着自救：Hi-Res ALAC / DSD 这类容器系统解码器不认（5400106），
   * 但服务器可以转码成 mp3 再送过来。同一首只降级一次；降级成功之后
   * 整个会话都走转码——否则一个 Hi-Res 曲库会变成「每首歌先失败一遍再重试」。
   * 救不回来才把原因交给界面。
   */
  private handlePlayFailure(raw: string, code: string): void {
    // stateChange 的 error 与 error 回调常常前后脚到达，只处理第一次
    if (Date.now() - this.failHandledAt < 700) {
      return;
    }
    this.failHandledAt = Date.now();
    this.loadingTrack = null;
    this.stopPosTimer();

    const track: Track | null = this.currentTrack;
    const mask: string = (raw + ' ' + code).toLowerCase();
    // 5400106 = Unsupported format；5400103 = IO 错误（读到的不是音频字节）
    const looksFormat: boolean = code === '5400106' || code === '5400103' ||
      mask.indexOf('unsupported') >= 0 || mask.indexOf('demux') >= 0 ||
      mask.indexOf('decode') >= 0 || mask.indexOf('format') >= 0;

    // 这一次走的就是转码，仍然失败（服务器没装 ffmpeg、或转码参数被拒）。
    // 必须立刻把开关复位：否则后面每一首都会继续走这条死路，
    // 表现就是「整库突然全都播不了」，比单曲失败严重得多。
    if (this.forceTranscode) {
      this.forceTranscode = false;
      this.transcodeBroken = true;
      this.retriedTrackId = '';
      console.warn('[player] 转码也没成功（' + code + '），停用转码并回退直连');
      // 不管还在不在同一首，这条失败都已经处理完了：
      // 之前这里在「曲目已切换」时继续往下走，会把 error 态写到新曲目上，
      // 表现就是刚点的新歌还没开始放就变成了失败。
      const cur: Track | null = this.currentTrack;
      if (track !== null && cur !== null && cur.id === track.id) {
        const back: number = this._position;
        this.loadCurrent(back > 0 ? back : -1).catch((e: Error) => {
          console.error('[player] 回退直连失败：' + e.message);
        });
      }
      return;
    }

    const canTranscode: boolean = !this.transcodeBroken && track !== null &&
      Store.get().sourceType === 'subsonic' && this.retriedTrackId !== track.id;

    if (looksFormat && canTranscode) {
      this.forceTranscode = true;
      this.retriedTrackId = track === null ? '' : track.id;
      console.warn('[player] 直连失败（' + code + '），改用服务器转码重试');
      const resume: number = this._position;
      this.loadCurrent(resume > 0 ? resume : -1).catch((e: Error) => {
        console.error('[player] 转码重试失败：' + e.message);
      });
      return;
    }

    this.state = 'error';
    // 记下这首：界面不再提示，播放键按下即重试
    this.failedTrackId = this.currentTrack === null ? '' : this.currentTrack.id;
    this.notifyState();
    this.reportPlayError(raw, code);
  }

  /**
   * 把底层异常翻译成用户能看懂的一句话。
   *
   * 直接把原始报错抛到界面上没有意义：那多半是一串
   * "Curl error 28" 或者 "status 401"，用户既不知道发生了什么，
   * 也不知道该做什么。这里按「用户下一步该干嘛」分类。
   */
  private reportPlayError(raw: string, code: string = ''): void {
    const low: string = raw.toLowerCase();
    let reason: string = '这首歌暂时无法播放';
    // 服务器明确说「没有这首」时，顺手把它从每日推荐池里剔掉，
    // 否则用户下次进首页还会看到这条死链，而且一整天都不会变
    let missing: boolean = false;
    // 注意顺序与匹配方式：
    //   · 'auth' 这种裸子串太宽，会误伤 author / authority 之类，
    //     改成匹配 'unauthorized' / '401' / '403' 这些真正有意义的串
    //   · 先判断 "连不上" 再判断 "超时"：ENOTFOUND 往往也伴随超时文案，
    //     但根因是解析不了域名，提示「检查 NAS 是否在线」更有用
    if (low.indexOf('enotfound') >= 0 || low.indexOf('econnrefused') >= 0 ||
      low.indexOf('unreachable') >= 0 || low.indexOf('未连接') >= 0 ||
      low.indexOf('no server') >= 0) {
      reason = '连不上服务器，检查网络或 NAS 是否在线';
    } else if (code === '5400104' || low.indexOf('timeout') >= 0 ||
      low.indexOf('timed out') >= 0) {
      reason = '连接超时，检查一下网络';
    } else if (low.indexOf('401') >= 0 || low.indexOf('403') >= 0 ||
      low.indexOf('unauthorized') >= 0) {
      reason = '服务器拒绝访问，登录可能已过期';
    } else if (low.indexOf('404') >= 0 || low.indexOf('not found') >= 0) {
      reason = '服务器上找不到这首歌';
      missing = true;
    } else if (code === '5400106' || low.indexOf('demux') >= 0 ||
      low.indexOf('unsupported') >= 0 || low.indexOf('decode') >= 0) {
      // 走到这里说明已经尝试过转码，服务器也没能给出一份能解的流
      reason = '这个格式解不了，服务器也没能转码';
    } else if (code === '5400103') {
      reason = '音频数据读到一半断了，换首试试或检查网络';
    } else if (code === '5400105') {
      reason = '播放服务异常，稍后再试';
    } else if (low.indexOf('network') >= 0) {
      reason = '网络异常，稍后再试';
    } else if (code.length > 0 && code !== '?') {
      // 没见过的码：文案保持中性，码单独交给界面上那行小字，
      // 一眼能看出「不是所有歌都同一个毛病」
      reason = '这首歌暂时播不了';
    }
    if (missing) {
      const t: Track | null = this.currentTrack;
      if (t !== null) {
        Store.get().dropDailyPick(t.id).then((hit: boolean) => {
          if (hit) {
            // 首页正摆着这首，回来时得重取一次才会把它换掉
            AppStorage.setOrCreate('dailyDirty', true);
          }
        }).catch(() => {
        });
      }
    }
    // 只留诊断日志：界面不再出现任何播放失败文案
    console.warn('[player] 播放失败：' + reason +
      (code.length > 0 && code !== '?' ? '（错误码 ' + code + '）' : ''));
  }

  /** 首次播放时创建媒体会话，把系统侧的控制命令接到播放器上 */
  private async ensureSession(): Promise<void> {
    if (this.media !== null) {
      return;
    }
    const ctx = Store.get().abilityContext;
    if (ctx === null) {
      return;
    }
    const m: MediaSession = new MediaSession();
    m.onPlayCmd = () => { this.play(); };
    m.onPauseCmd = () => { this.pause(); };
    m.onNextCmd = () => { this.next(); };
    m.onPrevCmd = () => { this.prev(); };
    m.onStopCmd = () => { this.pause(); };
    m.onSeekCmd = (ms: number) => { this.seek(ms); };
    m.onFavCmd = () => { this.toggleFavorite(); };
    m.onLoopModeCmd = (mode: avSession.LoopMode) => { this.applyLoopMode(mode); };
    await m.init(ctx);
    this.media = m;
  }

  /**
   * 后台起会话：调用方不 await，起播链上少一次跨进程往返。
   *
   * init 完成后补一次 syncSessionMeta —— 第一次播放时 loadCurrent 早跑过去了，
   * 那时 media 还是 null，系统卡片拿不到标题封面。
   */
  private ensureSessionAsync(): void {
    if (this.media !== null || this.sessionPending) {
      return;
    }
    this.sessionPending = true;
    this.ensureSession().then(() => {
      this.sessionPending = false;
      const t: Track | null = this.currentTrack;
      if (t !== null) {
        this.syncSessionMeta(t);
        this.notifyState();
      }
    }).catch((e: Error) => {
      this.sessionPending = false;
      console.warn('[player] 媒体会话初始化失败：' + e.message);
    });
  }

  /** 查询当前曲目收藏状态并推给系统卡片（锁屏/控制中心的喜爱按钮） */
  private syncFav(track: Track): void {
    this.favTrackId = track.id;
    this.favState = false;
    Store.get().isStarred(track.id).then((v: boolean) => {
      const cur: Track | null = this.currentTrack;
      if (cur !== null && cur.id === track.id) {
        this.favState = v;
        if (this.media !== null) {
          this.media.updateFavorite(v);
        }
      }
    });
  }

  /** 收藏/取消收藏当前曲目（锁屏、控制中心点「喜爱」） */
  private async toggleFavorite(): Promise<void> {
    const t: Track | null = this.currentTrack;
    if (t === null || t.id !== this.favTrackId) {
      return;
    }
    const next: boolean = !this.favState;
    this.favState = next;
    if (this.media !== null) {
      this.media.updateFavorite(next);
    }
    if (this.onFavChange !== null) {
      this.onFavChange(next);
    }
    const store: Store = Store.get();
    const ok: boolean = next ? await store.starSong(t.id) : await store.unstarSong(t.id);
    if (!ok) {
      // 服务器操作失败就回滚，避免按钮状态与实际不符
      this.favState = !next;
      if (this.media !== null) {
        this.media.updateFavorite(!next);
      }
      if (this.onFavChange !== null) {
        this.onFavChange(!next);
      }
      return;
    }
    AppStorage.setOrCreate('starredDirty', true);
  }

  /**
   * 外部页面（「喜爱的歌」列表）取消收藏后，把当前曲目的收藏状态同步过来。
   * 只响应当前正在播放的这首，其它歌的状态与本播放器无关。
   */
  syncFavoriteFromExternal(songId: string, fav: boolean): void {
    if (songId !== this.favTrackId || this.favState === fav) {
      return;
    }
    this.favState = fav;
    if (this.media !== null) {
      this.media.updateFavorite(fav);
    }
    if (this.onFavChange !== null) {
      this.onFavChange(fav);
    }
  }

  /**
   * 锁屏播放模式按钮：系统只认标准循环模式，映射回应用三态。
   * 必须走 setPlayMode，保证「随机 + 列表循环」这类组合被彻底拆开，
   * 否则从随机切到列表循环时 shuffle 仍然为 true，页面图标与锁屏图标会对不上。
   * 系统能表达的只有三项（列表/单曲/随机），App 内的「顺序播放」在
   * 系统侧没有对应值，所以不会通过这条路径进入。
   *
   * 实测坑：系统按下按钮时先读自己缓存的 loopMode，再算「下一个」下发；由于应用每次
   * 都会把当前模式回传给系统，系统认为目标 == 当前，于是原样下发同一个值（日志连续
   * `recv setLoopMode 2`）。这种情况下按下等于没反应，所以这里把「收到与当前相同的模式」
   * 当作「用户要切下一个」，按应用自己的顺序前进一格。
   */
  private applyLoopMode(mode: avSession.LoopMode): void {
    const cur: avSession.LoopMode = this.currentLoopMode();
    console.info('[session] applyLoopMode recv=' + mode + ' cur=' + cur);
    if (mode === cur) {
      this.advancePlayMode();
      return;
    }
    if (mode === avSession.LoopMode.LOOP_MODE_SEQUENCE) {
      this.setPlayMode('seq');
      return;
    }
    if (mode === avSession.LoopMode.LOOP_MODE_SINGLE) {
      this.setPlayMode('one');
      return;
    }
    if (mode === avSession.LoopMode.LOOP_MODE_SHUFFLE) {
      this.setPlayMode('shuffle');
      return;
    }
    // LOOP_MODE_LIST：列表循环
    this.setPlayMode('loop');
  }

  /** 当前状态对应的标准循环模式（用于和系统下发值比较） */
  private currentLoopMode(): avSession.LoopMode {
    if (this.shuffle) {
      return avSession.LoopMode.LOOP_MODE_SHUFFLE;
    }
    if (this.repeat === 'one') {
      return avSession.LoopMode.LOOP_MODE_SINGLE;
    }
    // repeat off（顺序播放）在系统侧没有对应值，只能报列表循环：
    // 系统卡片上的按钮只表达「列表/单曲/随机」，播完停不停它管不着
    return avSession.LoopMode.LOOP_MODE_LIST;
  }

  /**
   * 系统卡片上的模式按钮被按下时的循环顺序。
   * 这四项是系统能表达的全集，所以不包含「顺序播放」——
   * 顺序播放只能在 App 内的模式菜单里选。
   */
  private advancePlayMode(): void {
    const cur: avSession.LoopMode = this.currentLoopMode();
    if (cur === avSession.LoopMode.LOOP_MODE_LIST) {
      this.setPlayMode('one');
    } else if (cur === avSession.LoopMode.LOOP_MODE_SINGLE) {
      this.setPlayMode('shuffle');
    } else if (cur === avSession.LoopMode.LOOP_MODE_SHUFFLE) {
      this.setPlayMode('loop');
    } else {
      this.setPlayMode('loop');
    }
  }

  /**
   * 获取播放源：
   * - Subsonic 模式：直接返回流式 URL（AVPlayer 支持 http URL，边下边播）
   * - WebDAV 模式：下载到本地缓存后返回本地路径（离线可用）
   */
  /**
   * 取流式播放地址。
   * 从本地存档读出来的 Track 有两种坏法：字段根本不存在（老版本的快照），
   * 或者带着上一套登录态生成的旧地址。两种都回落到「用当前客户端现拼」。
   */
  private streamUrlOf(track: Track): string {
    const store: Store = Store.get();
    const s: Subsonic | null = store.sourceType === 'subsonic' ? store.subsonicClient() : null;
    if (s !== null && track.id.length > 0) {
      // Subsonic 模式一律现拼，不再信任存档里的地址：
      // 那条地址可能来自旧版本（带 f=json）、旧域名或旧登录态。
      // 用它播放的典型症状就是「封面能显示、音频却解不出来」——
      // 封面走的是另一套 URL，不受影响，于是看着像播放器坏了。
      return s.streamUrl(track.id, this.forceTranscode);
    }
    return track.streamUrl ?? '';
  }

  private async ensureSource(track: Track): Promise<string> {
    // Subsonic 流式 URL 直接播放。
    // 注意不能直接读 track.streamUrl：从本地存档恢复的队列、以及早期版本写下的
    // 每日推荐快照里，这个字段可能根本不存在，`undefined.length` 会直接抛错，
    // 表现就是「点了一首歌没有任何反应」。所以统一走 streamUrlOf 兜一层。
    const url: string = this.streamUrlOf(track);
    if (url.length > 0) {
      return url;
    }
    const store: Store = Store.get();
    // WebDAV：缓存文件名只由 href 决定（见 Store.cachedPathFor），是确定性的。
    // 队列存档不带缓存标记，重启后标记全丢——与其信标记，
    // 不如直接 stat 确定性路径，文件在就用，顺手把标记补回来
    if (track.cached && track.cachedPath.length > 0) {
      if (await fileExists(track.cachedPath)) {
        return track.cachedPath;
      }
    }
    const useCache: boolean = store.settings.autoCache;
    const localPath: string = useCache
      ? store.cachedPathFor(track.href)
      : store.tmpPathFor(track.href);
    if (await fileExists(localPath)) {
      track.cached = useCache;
      track.cachedPath = localPath;
      if (useCache && !store.isCached(track.href)) {
        store.markTrackCached(track);
      }
      return localPath;
    }
    const dav: WebDav | null = store.davClient();
    if (dav === null) {
      throw new Error('未连接 NAS');
    }
    await dav.download(track.href, localPath);
    track.cached = useCache;
    track.cachedPath = localPath;
    if (useCache) {
      // 进清单 + 容量检查（内部异步淘汰最旧的，不阻塞播放）
      store.markTrackCached(track);
    }
    return localPath;
  }

  private async playFromSource(source: string, track: Track, startPos: number = -1): Promise<void> {
    await this.resetPlayer();
    // 新一次加载：清掉上一首留下的错误码与去重时间窗，
    // 否则紧接着重试时会被 700ms 窗口直接吞掉，界面永远不更新
    this.lastErrorCode = '';
    this.failHandledAt = 0;
    // 开始新一轮准备：重试标记作废，若这次仍失败会在 handlePlayFailure 里重新记上
    this.failedTrackId = '';
    // 续播起始位置要在 resetPlayer 之后落：它会把残留值清掉，
    // 恢复队列加载失败后再点别的歌，也不会被旧位置污染
    this._pendingStartPos = startPos > 0 ? startPos : 0;
    const player: media.AVPlayer = await media.createAVPlayer();
    this.avPlayer = player;
    // 音量是实例级属性：新建的播放器默认满音量，
    // 不贴回去的话，用户调小的音量会在每次切歌后被悄悄放大。
    // 此刻实例还在 idle，setVolume 可能被判非法操作，所以只做「尽力而为」，
    // 真正生效靠 initialized 里那次——绝不能让它抛出去打断后面的 url 赋值
    try {
      player.setVolume(this.volumeLevel);
    } catch (e) {
    }

    player.on('stateChange', async (s: string) => {
      // 旧播放器（已被切歌替换/释放）的回调一律丢弃：
      // 否则它的 prepared 会把 state、时长、进度定时器、播放次数写到新曲目上。
      if (this.avPlayer !== player) {
        return;
      }
      this.state = s as PlayerState;
      if (s === 'initialized') {
        // 音频用途必须在 prepare 之前设，否则不生效。
        // 声明成 MUSIC 之后，系统才知道这是个音乐 App：
        // 手机静音时仍出声、来电时按音乐规则处理停/续。
        this.applyRendererInfo(player);
        // 音量也要在 initialized 补一次：createAVPlayer 之后实例还是 idle，
        // 那时设的音量不一定落到新会话上
        player.setVolume(this.volumeLevel);
        // 网络流播先给足缓冲，避免网速抖动时出现偶发卡顿（只能在 initialized 状态设置）
        await this.applyBufferStrategy(player);
        // prepare 抛错时若不管，这是一个没人接的 Promise：
        // 界面会永远停在「加载中」，既不报错也不能重试。必须自己接住
        try {
          await player.prepare();
        } catch (e) {
          const be: BusinessError = e as BusinessError;
          const pc: string = String(be.code ?? '?');
          console.error('[player] prepare 失败：' + (be.message ?? '') + ' code=' + pc);
          this.lastErrorCode = pc;
          this.handlePlayFailure(be.message ?? 'prepare error', pc);
        }
      } else if (s === 'prepared') {
        this._duration = player.duration || 0;
        track.duration = this._duration;
        // 恢复队列后续播：先定位再播，否则「接着上次听」变成从头听。
        // 位置越界（存档在曲尾）就放弃，正常从头播
        if (this._pendingStartPos > 0 && this._pendingStartPos < this._duration) {
          try {
            await player.seek(this._pendingStartPos);
            this._position = this._pendingStartPos;
            this._posSampledAt = Date.now();
          } catch (e) {
          }
        }
        this._pendingStartPos = 0;
        // 先启动定时器，再调用 play()。
        // 定时器里每 tick 会 refreshStateFromPlayer()，
        // 所以即使下面的 playing 事件丢了，进度也照样会推进。
        this.startPosTimer();
        try {
          await player.play();
          // 真正开始播放才算一次（加载失败、切走都不计）
          Store.get().countTrackPlay(track);
          // 「最近播放」只在真的出声后记：点进来又立刻切走的，不算听过
          Store.get().noteRecent(track);
          // 上报「正在播放」：服务器的「正在播放」列表与推荐权重都靠它
          this.scrobbleStart(track);
        } catch (e) {
          const be: BusinessError = e as BusinessError;
          console.error('[player] play 失败：' + (be.message ?? '') + ' code=' + String(be.code ?? '?'));
          this.lastErrorCode = String(be.code ?? '?');
          this.handlePlayFailure(be.message ?? 'play error', this.lastErrorCode);
          return;
        }
        // play() 返回即认为进入播放态，不依赖 stateChange 事件是否送达（详见 play() 注释）
        if (this.avPlayer === player) {
          this.state = 'playing';
          this.loadingTrack = null;
          this.notifyState();
          this.notifyProgress();
          // 时长此时才准，重新同步一次系统卡片的元数据与进度锚点
          this.syncSessionMeta(track);
        }
      } else if (s === 'playing') {
        // 系统真的出声了，说明打断确实结束了；清掉标记，
        // 避免下一次恢复时误判成「还在被打断」。
        this.interrupted = false;
        this.pauseReason = '';
        this.notifyState();
      } else if (s === 'paused') {
        // 被动暂停的原因已经在 handleInterrupt 里标好了，这里只需刷新界面，
        // 让悬浮提示能弹出来。
        this.notifyState();
      } else if (s === 'completed') {
        this.stopPosTimer();
        // 整首放完了但还没到「一半 / 4 分钟」的唯一可能是超短曲；
        // 这里补一次判断，保证真正听完的歌不会漏报
        this.maybeScrobbleSubmit(this._duration);
        if (this.repeat === 'one') {
          // 单曲循环：回到开头重新播。
          // seek 已允许 completed 态（见 seek 注释），否则这里会静默失败，
          // 表现就是「单曲循环只响了一遍」。
          try {
            await this.seek(0);
            await player.play();
            if (this.avPlayer === player) {
              this.state = 'playing';
              this.startPosTimer();
              this.notifyState();
            }
          } catch (e) {
            console.error('[player] 单曲循环重播失败：' + (e instanceof Error ? e.message : String(e)));
            this.state = 'paused';
            this.notifyState();
          }
        } else {
          await this.next();
        }
      } else if (s === 'error') {
        // 状态机只告诉我们「出错了」，真正的业务码在 error 回调里，它通常晚几十毫秒。
        // 以前这里直接甩一句硬编码的 'prepare failed'，于是不管真实原因是 401、
        // 超时还是格式不支持，界面上永远显示「文件无法解码」——这就是
        // 「每首歌都提示同一句」的来源。现在等一拍，用真实的码去解释。
        setTimeout(() => {
          if (this.avPlayer !== player) {
            return;
          }
          this.handlePlayFailure('avplayer state error', this.lastErrorCode);
        }, 240);
      }
    });

    player.on('error', (err: BusinessError) => {
      if (this.avPlayer !== player) {
        return;
      }
      // AVPlayer 的 error 回调带 BusinessError，code 比 message 更能定位问题
      const msg: string = err === undefined || err === null ? 'unknown' : (err.message ?? '');
      const code: string = err === undefined || err === null ? '?' : String(err.code ?? '?');
      console.error('[player] AVPlayer error: ' + msg + ' code=' + code);
      this.lastErrorCode = code;
      this.handlePlayFailure(msg, code);
    });

    this.bindInterrupt(player);

    // 设置 url 触发 initialized → prepare → play。
    // 这里必须自己接住异常：地址为空、URL 非法时赋值是同步抛出的，
    // 抛出后既没有 error 回调也没有状态变化，界面会永远停在「加载中」。
    try {
      player.url = source;
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      const code: string = String(be.code ?? '?');
      console.error('[player] 设置播放地址失败：' + (be.message ?? '') + ' code=' + code);
      this.lastErrorCode = code;
      this.handlePlayFailure(be.message ?? 'invalid url', code);
    }
  }

  /**
   * 绑定音频打断事件 —— 「播放中被其他应用打断」的核心接入口。
   *
   * 系统给的三段信息要分开看：
   *   eventType  BEGIN / END     打断开始还是结束
   *   forceType  FORCE / SHARE   强制（系统已经替你停了）/ 协商（要自己处理）
   *   hintType   PAUSE / STOP / DUCK / UNDUCK / RESUME / MUTE / UNMUTE
   *
   * 最容易写错的地方：FORCE 的情况下系统已经动过手了，
   * 这时再调一次 pause() 属于多余操作，还可能把状态搅乱；
   * 只需要把界面同步过来。SHARE 才是自己必须主动 pause。
   */
  private bindInterrupt(player: media.AVPlayer): void {
    try {
      player.on('audioInterrupt', (evt: audio.InterruptEvent) => {
        if (this.avPlayer !== player) {
          return;
        }
        this.handleInterrupt(evt, player);
      });
    } catch (e) {
      // 老设备或没有音频子系统时注册可能失败，不影响播放本身
      console.warn('[player] 注册音频打断事件失败（忽略）');
    }
  }

  private handleInterrupt(evt: audio.InterruptEvent, player: media.AVPlayer): void {
    const began: boolean = evt.eventType === audio.InterruptType.INTERRUPT_TYPE_BEGIN;
    const forced: boolean = evt.forceType === audio.InterruptForceType.INTERRUPT_FORCE;

    if (began) {
      // 压低音量 / 静音这两类不算「打断播放」，时间轴还在走
      if (evt.hintType === audio.InterruptHint.INTERRUPT_HINT_DUCK ||
        evt.hintType === audio.InterruptHint.INTERRUPT_HINT_MUTE) {
        return;
      }
      const wasPlaying: boolean = this.state === 'playing' || this.state === 'prepared';
      this.interrupted = wasPlaying;
      if (!wasPlaying) {
        // 本来就没在播（用户自己停的）：不要写提示文案，也不要动状态，
        // 只把界面同步一次。之前无条件写 pauseReason，暂停状态下插拔耳机
        // 也会弹「已被其他应用暂停」，看着像 App 自己出了问题。
        // 已有原因（上一次真打断留下的）保持不动。
        this.notifyState();
        return;
      }
      this.pauseReason = this.interruptText(evt.hintType);
      this.stopPosTimer();
      this.state = 'paused';
      if (!forced) {
        // 协商式打断：系统没动手，得自己停
        player.pause().catch(() => {
        });
      }
      // 立刻把采样时间归零，避免 livePosition 在暂停后继续外推
      this._posSampledAt = 0;
      this.notifyState();
      this.notifyProgress();
      return;
    }

    // 打断结束。END 事件里也可能夹着 PAUSE 之类的 hint，
    // 但那是「刚刚发生了什么」，真正的恢复信号只有下面三种。
    const resumeHint: boolean = evt.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME ||
      evt.hintType === audio.InterruptHint.INTERRUPT_HINT_UNDUCK ||
      evt.hintType === audio.InterruptHint.INTERRUPT_HINT_UNMUTE;
    if (!resumeHint) {
      return;
    }
    if (!this.interrupted) {
      // 用户在被停顿期间自己操作过了，尊重用户意图，不抢回来
      this.pauseReason = '';
      this.notifyState();
      return;
    }
    this.interrupted = false;
    this.pauseReason = '';
    player.play().then(() => {
      if (this.avPlayer !== player) {
        return;
      }
      this._posSampledAt = Date.now();
      this.startPosTimer();
      this.state = 'playing';
      this.notifyState();
    }).catch(() => {
      // 恢复失败（资源已被回收等）：老实停在暂停态，别让界面显示「在播」
      this.stopPosTimer();
      this.state = 'paused';
      this.notifyState();
    });
  }

  /** 把打断类型翻译成一句人能看懂的话，给界面显示用 */
  private interruptText(hint: audio.InterruptHint): string {
    if (hint === audio.InterruptHint.INTERRUPT_HINT_STOP) {
      return '音频焦点已被其他应用接管';
    }
    return '已被其他应用暂停';
  }

  /**
   * 声明音频用途。不设也能出声，但设了系统才会把它当音乐处理：
   * 静音模式下照常播放、来电结束后按音乐的规则恢复。
   * 只能在 initialized 状态设，且必须在 prepare() 之前。
   */
  private applyRendererInfo(player: media.AVPlayer): void {
    try {
      const info: audio.AudioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      };
      player.audioRendererInfo = info;
    } catch (e) {
      console.warn('[player] 设置音频用途失败（忽略）');
    }
  }

  /**
   * 设置播放缓冲策略。
   *
   * 原来是 8 秒——当时为了「网速一抖不断音」，代价是起播要先把 8 秒音频拿到本地：
   * 24bit/48k 的 FLAC 约 230KB/s，8 秒就是近 2MB，家庭宽带上也要一秒多才凑齐，
   * 这段时间播放器一直停在 prepared，用户看到的就是「点了不响」。
   * 收到 2 秒：起播需要的数据降到四分之一，而 2 秒的余量已经能吸收绝大多数抖动
   * （真断网时靠的是缓存重试与错误提示，不是这 8 秒）。
   * 只允许在 initialized 状态调用，失败不影响正常播放。
   */
  private async applyBufferStrategy(player: media.AVPlayer): Promise<void> {
    try {
      const strategy: media.PlaybackStrategy = { preferredBufferDuration: 2 };
      await player.setPlaybackStrategy(strategy);
    } catch (e) {
      console.warn('[player] 设置缓冲策略失败（忽略）');
    }
  }

  private async resetPlayer(): Promise<void> {
    this.stopPosTimer();
    if (this.avPlayer !== null) {
      try {
        this.avPlayer.release();
      } catch (e) {
      }
      this.avPlayer = null;
    }
    this._position = 0;
    this._posSampledAt = 0;
    this._duration = 0;
    // 切歌重置节流基准，保证新曲目的第一个进度一定推出去
    this._lastPushedPos = -1;
    this._lastPushedDur = -1;
    // 残留的续播位置必须清掉：恢复队列后加载失败、又去点别的歌，
    // 不清的话新歌会被 seek 到旧歌的进度上
    this._pendingStartPos = 0;
    this.state = 'idle';
  }

  private startPosTimer(): void {
    this.stopPosTimer();
    this.lastTickAt = 0;
    this.posTimer = setInterval(() => {
      // 每次 tick 先用播放器实时状态校正一次 state。
      // 这是「偶发进度条不动」的正面修复：之前 state 一旦漏掉 playing 事件，
      // 这里就会一直走 else 分支，进度永远不推。
      this.refreshStateFromPlayer();
      if (this.avPlayer !== null && this.state === 'playing') {
        // 按真实时间差累计听歌时长（暂停/卡顿时不计，单次最多补 2 秒）
        const now: number = Date.now();
        if (this.lastTickAt > 0) {
          let delta: number = (now - this.lastTickAt) / 1000;
          if (delta > 2) {
            delta = 2;
          }
          Store.get().addListenSeconds(delta, this.currentTrack);
        }
        this.lastTickAt = now;
        const pos: number = this.avPlayer.currentTime;
        // 进度出现跳变（尚未拿到 prepared 的时长、或 seek 之后瞬时值异常）时，
        // 不把 0 或负数写回去，避免进度条被拽回开头。
        if (isFinite(pos) && pos >= 0) {
          this._position = pos;
          this._posSampledAt = now;
          // 记下「上次听到哪」，回首页的最近播放能接着听
          const cur: Track | null = this.currentTrack;
          if (cur !== null) {
            Store.get().updateRecentPos(cur.id, pos);
          }
          // 听够一半就上报一次；队列快见底就先续上相似歌
          this.maybeScrobbleSubmit(pos);
          this.maybeRadioExtend(pos);
        }
        this.notifyProgress();
        this.syncLyric();
      } else {
        this.lastTickAt = 0;
        this._posSampledAt = 0;
      }
    }, 200);
  }

  // ---------------- 播放上报（scrobble） ----------------

  /**
   * 开播上报：告诉服务器「我现在在听这首」。
   *
   * 只做「旁路通知」，失败一律吞掉。这里最忌讳 await：NAS 卡一下
   * 就会把整条播放链拖住，而这条信息丢了完全不影响听歌。
   */
  private scrobbleStart(track: Track): void {
    // 同一次加载里 play 可能被调用两次（转码降级重试），只报一次
    if (this.scrobbleNowId === track.id) {
      return;
    }
    if (Store.get().settings.scrobble === false || !Store.get().isSubsonic) {
      return;
    }
    const s: Subsonic | null = Store.get().subsonicClient();
    if (s === null) {
      return;
    }
    const at: number = Date.now();
    this.scrobbleNowId = track.id;
    this.scrobbleAt = at;
    s.scrobble(track.id, false, at).catch(() => {
    });
  }

  /**
   * 听够了就计一次播放。
   *
   * 口径取 Last.fm 的通行规则：听完一半，或听满 4 分钟（长曲不必等完）。
   * 短于 30 秒的片段（试听、报错重试）不计——否则一首失败的歌
   * 会在「最近播放」与服务器统计里反复刷次数。
   */
  private maybeScrobbleSubmit(pos: number): void {
    if (Store.get().settings.scrobble === false || !Store.get().isSubsonic) {
      return;
    }
    const cur: Track | null = this.currentTrack;
    if (cur === null || this.scrobbledId === cur.id) {
      return;
    }
    const dur: number = this._duration > 0 ? this._duration : cur.duration;
    if (dur <= 0 || dur < 30000) {
      return;
    }
    const need: number = Math.min(dur * 0.5, SCROBBLE_MIN_MS);
    if (pos < need) {
      return;
    }
    const s: Subsonic | null = Store.get().subsonicClient();
    if (s === null) {
      return;
    }
    this.scrobbledId = cur.id;
    s.scrobble(cur.id, true, this.scrobbleAt > 0 ? this.scrobbleAt : Date.now()).catch(() => {
    });
  }

  // ---------------- 电台续播 ----------------

  /** 当前位置之后还剩几首（随机模式下按 shuffledOrder 算，不能直接拿队列长度减下标） */
  private remainingInQueue(): number {
    if (this.queue.length === 0 || this.index < 0) {
      return 0;
    }
    if (this.shuffle) {
      const pos: number = this.shuffledOrder.indexOf(this.index);
      return pos < 0 ? 0 : this.shuffledOrder.length - 1 - pos;
    }
    return this.queue.length - 1 - this.index;
  }

  /**
   * 快放到队尾时续上相似歌。
   *
   * 触发条件刻意收紧成「只剩 1 首以内 + 当前这首已过 40%」：
   * 提前太多会把用户精心排的队列冲淡，太晚又会在切歌那一刻卡住等网络。
   * 剩下的 60% 就是留给请求的窗口，正常情况下歌还没放完，新歌已经在队里了。
   */
  private maybeRadioExtend(pos: number): void {
    if (this.radioBusy || this.radioDead) {
      return;
    }
    if (Date.now() < this.radioRetryAt) {
      return;
    }
    if (Store.get().settings.radio === false || !Store.get().isSubsonic) {
      return;
    }
    if (this.currentTrack === null) {
      return;
    }
    if (this.radioFetched >= RADIO_MAX) {
      return;
    }
    if (this.remainingInQueue() > 1) {
      return;
    }
    const dur: number = this._duration;
    if (dur > 0 && pos < dur * 0.4) {
      return;
    }
    this.extendRadio();
  }

  /** 向服务器要一批相似歌，去重后追加到队尾。失败或没有结果就本轮收手 */
  private async extendRadio(): Promise<void> {
    const seed: Track | null = this.currentTrack;
    if (seed === null) {
      return;
    }
    const s: Subsonic | null = Store.get().subsonicClient();
    if (s === null) {
      return;
    }
    const qRef: Track[] = this.queue;
    this.radioBusy = true;
    try {
      const got: Track[] = await s.getSimilarSongs(seed.id, RADIO_BATCH);
      // 请求期间用户换了队列：结果属于上一轮，丢掉
      if (this.queue !== qRef) {
        return;
      }
      if (got.length === 0) {
        this.radioDead = true;
        return;
      }
      const have: Record<string, boolean> = {};
      for (const t of this.queue) {
        have[t.id] = true;
      }
      const add: Track[] = [];
      for (const t of got) {
        // 同一首可能因为不同专辑版本重复出现，按 id 去重；
        // 一次只放 RADIO_BATCH 里的一半，留点余量给下一轮，避免总是同一批
        if (have[t.id] === true) {
          continue;
        }
        have[t.id] = true;
        add.push(t);
        if (add.length >= 10) {
          break;
        }
      }
      if (add.length === 0) {
        // 相似歌全在队列里了，说明这个种子已经挖干净：本轮不再续
        this.radioDead = true;
        return;
      }
      const base: number = this.queue.length;
      for (let i = 0; i < add.length; i++) {
        this.queue.push(add[i]);
        if (this.shuffle) {
          this.shuffledOrder.push(base + i);
        }
      }
      this.radioFetched += add.length;
      // 一次追加十首，只落盘一次；addToQueue 逐首写会把 10 次 IO 摊在播放间隙里
      this.persistQueue();
      console.info('[radio] 续播 +' + add.length.toString() + ' 首，累计 ' +
        this.radioFetched.toString() + ' 首');
    } catch (e) {
      // 连不上、鉴权失败：隔 30 秒再试。区别于「服务器说没有相似歌」——
      // 后者才是真的没得续，直接收手，不要一直发请求
      this.radioRetryAt = Date.now() + 30000;
      console.info('[radio] 相似歌曲拉取失败，30 秒后重试');
    } finally {
      this.radioBusy = false;
    }
  }

  /** 拉取当前曲目歌词（带时间轴优先），失败静默 */
  private async loadLyrics(track: Track): Promise<void> {
    this.lyricLines = [];
    this.lyricSynced = false;
    this.curLyricLine = '';
    this.lrcText = '';
    AppStorage.setOrCreate('miniLyric', '');
    try {
      const r = await Store.get().lyricsFor(track);
      // 请求期间可能已切歌
      if (this.currentTrack !== null && this.currentTrack.id === track.id) {
        this.lyricLines = r.lines;
        this.lyricSynced = r.synced;
        // 有时间轴的歌词才转成标准 LRC 交给系统：纯文本歌词没有时间点，
        // 系统解析不了，塞进去只会让锁屏显示一团无效文本
        if (r.synced) {
          this.lrcText = buildLrc(r.lines);
        }
        this.syncLyric();
        // 歌词是异步到的：到手后把带歌词的元数据补推给系统媒体卡片
        this.syncSessionMeta(track);
      }
    } catch (e) {
    }
  }

  /** 根据当前播放位置算出歌词行，变化时推给迷你条与系统媒体卡片 */
  private syncLyric(): void {
    let line: string = '';
    if (this.lyricSynced && this.lyricLines.length > 0) {
      // 用外推后的真实位置，而不是 500ms 快照。
      // 之前这里写 pos + 250 来「补偿平均滞后」，但那是在猜——
      // 每次 tick 的实际滞后在 0~500ms 之间随机，补固定值只会让
      // 一部分歌看起来刚好、另一部分偏。外推是按实际经过时间算的。
      const at: number = this.livePosition;
      // 二分查找 + 向上找最近的非空行。
      // 与播放页 updateCurLine 用同一套规则，避免两处显示不一致
      // （迷你条显示 A 句、播放页高亮 B 句）。
      // 不用「顺序扫描 + break」是因为它要求时间轴严格升序且无空行，
      // 实际歌词里这两条都不一定成立。
      let lo: number = 0;
      let hi: number = this.lyricLines.length - 1;
      // -1：歌首前奏阶段没有任何一行该亮
      let idx: number = -1;
      while (lo <= hi) {
        const mid: number = (lo + hi) >> 1;
        if (this.lyricLines[mid].start <= at) {
          idx = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      while (idx > 0 && this.lyricLines[idx].text.trim().length === 0) {
        idx = idx - 1;
      }
      if (idx >= 0) {
        const t: string = this.lyricLines[idx].text.trim();
        if (t.length > 0) {
          line = this.lyricLines[idx].text;
        }
      }
    }
    if (line !== this.curLyricLine) {
      this.curLyricLine = line;
      AppStorage.setOrCreate('miniLyric', line);
      if (this.media !== null) {
        this.media.updateLyric(line);
      }
      // 桌面卡片同步当前歌词行（FormSync 内部节流，1 秒最多一次）
      const t2: Track | null = this.currentTrack;
      FormSync.push({
        title: t2 !== null ? t2.title : '',
        artist: t2 !== null ? t2.artist : '',
        playing: this.isPlaying,
        lyric: line
      });
    }
  }

  private stopPosTimer(): void {
    if (this.posTimer >= 0) {
      clearInterval(this.posTimer);
      this.posTimer = -1;
    }
    // 暂停/切歌/退出时把还没攒满一批的秒数立刻写盘，避免丢掉最后十几秒
    Store.get().flushStats();
  }

  async play(): Promise<void> {
    if (this.avPlayer === null) {
      // 队列刚从存档恢复时还没有播放器实例，但 state 是 paused——
      // 不补这个分支的话，恢复出来的队列点播放、蓝牙/耳机播放键全都无反应。
      // 加载中不重复触发（用户快速连点时避免两次 loadCurrent 竞争）
      if (this.currentTrack !== null && this.loadingTrack === null) {
        // 把恢复的位置作为起始偏移传下去；直接 loadCurrent 会从 0:00 开始
        await this.loadCurrent(this._position);
      }
      return;
    }
    // 上一次彻底失败了（界面上不会有任何提示）：播放键就是重试键。
    // 播放器此时通常停在 prepared/error，直接 play() 不会出声，
    // 必须重新取源、重新准备一遍。
    // 条件里带上 state === 'error'：失败标记有可能在别处被清掉（比如转码回退），
    // 只认标记的话会出现「停在 error 态，点播放什么都不做」。
    if (this.loadingTrack === null &&
      ((this.failedTrackId.length > 0 && this.currentTrack !== null &&
        this.failedTrackId === this.currentTrack.id) || this.state === 'error')) {
      this.failedTrackId = '';
      await this.loadCurrent(this._position > 0 ? this._position : -1);
      return;
    }
    // 先用播放器实时状态校正，避免 state 落后于真实状态而误判
    this.refreshStateFromPlayer();
    // 播完后再点播放：先回到开头
    if (this.state === 'completed') {
      try {
        await this.avPlayer.seek(0);
      } catch (e) {
      }
      this._position = 0;
      this._posSampledAt = Date.now();
    }
    if (this.state === 'paused' || this.state === 'completed') {
      // 乐观更新：先把界面切成「播放中」，再去要声音。
      //
      // avPlayer.play() 的 Promise 要等到音频管线真正跑起来才 resolve——
      // 从长时间暂停恢复、或输出切到蓝牙耳机时，这一步要 200~500ms。
      // 之前是 await 完才改 state，这段时间按钮还是「播放」三角、封面不动，
      // 用户以为没点上，会再点一次（于是又暂停了），观感就是「点了半天才反应」。
      // 先置位、失败再回退，跟手得多：声音该什么时候出来还是什么时候出来。
      this.state = 'playing';
      this.optimisticPlayAt = Date.now();
      // 用户主动播放：清掉打断标记与提示，之后系统不要再替他"恢复"一次
      this.interrupted = false;
      this.pauseReason = '';
      this._posSampledAt = Date.now();
      this.startPosTimer();
      this.notifyState();
      this.notifyProgress();
      try {
        await this.avPlayer.play();
      } catch (e) {
        // 播放器可能已被系统打回异常态：先把界面回退成暂停，
        // 再重新走一遍取源 + prepare，别让按钮停在「播放中」却一点声都没有
        console.warn('[player] play() 失败，重新加载：' +
          (e instanceof Error ? e.message : String(e)));
        this.state = 'paused';
        this.stopPosTimer();
        this.notifyState();
        await this.loadCurrent(this._position > 0 ? this._position : -1);
        return;
      }
    }
  }

  async pause(): Promise<void> {
    if (this.avPlayer === null) {
      return;
    }
    // 用户主动暂停：清掉打断标记，免得打断结束时系统自作主张接上播放
    this.interrupted = false;
    this.pauseReason = '';
    this.refreshStateFromPlayer();
    if (this.state === 'playing') {
      await this.avPlayer.pause();
      // 同样立刻落地，不等事件；否则快速连点时状态会错位
      this.state = 'paused';
      this.stopPosTimer();
      this.notifyState();
      // 暂停是用户最容易杀 App 的时机，立刻落盘一次，
      // 不依赖 5s 节流点——否则暂停后马上杀进程会丢最后一段进度
      this.persistQueue();
    } else if (this.state === 'completed') {
      // 已自然播完：只同步状态，让系统卡片收起「正在播放」
      this.stopPosTimer();
      this.state = 'paused';
      this.notifyState();
    }
  }

  togglePlayPause(): Promise<void> {
    // 进来先校正：用户点按钮的那一刻，播放器的真实状态才可信。
    // 不校正的话，state 卡在 paused 而实际在播时，这个按钮会再调一次 play()，
    // 表现为「按了没反应」。
    this.refreshStateFromPlayer();
    if (this.state === 'playing') {
      return this.pause();
    }
    if (this.state === 'paused' || this.state === 'completed') {
      return this.play();
    }
    if (this.state === 'error') {
      // 播失败后停在 error：播放键就是重试键。
      // 之前没有这个分支，界面上的播放键会「按了完全没反应」——
      // 既不出声也不再重试，只能退出去重进播放页。
      return this.play();
    }
    if (this.state === 'idle' && this.queue.length > 0) {
      return this.loadCurrent();
    }
    // prepared / initialized 阶段点了播放：直接让播放器走
    if ((this.state === 'prepared' || this.state === 'initialized') && this.avPlayer !== null) {
      return this.play();
    }
    return Promise.resolve();
  }

  async seek(target: number): Promise<void> {
    this.refreshStateFromPlayer();
    // prepared 也要允许：起播前用户拖了进度条，直接丢掉会让滑块先跳过去再弹回来。
    // completed 必须允许：单曲循环回到开头走的就是这条路，之前这个分支被
    // 挡在状态判断外，结果「单曲循环只响一遍」。
    if (this.avPlayer !== null &&
      (this.state === 'playing' || this.state === 'paused' ||
        this.state === 'prepared' || this.state === 'completed')) {
      let to: number = target > 0 ? target : 0;
      if (this._duration > 0 && to > this._duration) {
        to = this._duration;
      }
      await this.avPlayer.seek(to);
      this._position = to;
      // 跳转后重置采样基准，否则 livePosition 会在新位置基础上
      // 继续叠加「距上次采样」的时间，歌词瞬间超前一段
      this._posSampledAt = Date.now();
      this.notifyProgress();
      this.syncLyric();
      if (this.media !== null) {
        this.media.updateState(this.isPlaying, this.isLoading, to);
      }
      return;
    }
    // 恢复队列后还没有播放器实例：seek 被上面的条件挡掉会让滑块弹回原位。
    // 把位置记下来并入档，之后按播放会从这个位置续播
    if (this.avPlayer === null && this.currentTrack !== null) {
      let to: number = target > 0 ? target : 0;
      if (this._duration > 0 && to > this._duration) {
        to = this._duration;
      }
      this._position = to;
      this._lastSavedPos = to;
      this.persistQueue();
      this.notifyProgress();
    }
  }


  /** 当前是否处于「被外部打断而暂停」的状态，界面据此显示提示 */
  get interruptedBy(): string {
    return this.pauseReason;
  }

  private notifyState(): void {
    if (this.onStateChange !== null) {
      this.onStateChange(this.isPlaying, this.isLoading);
    }
    // 同步到 AppStorage 供卡片/闪控窗读取
    AppStorage.setOrCreate('playerPlaying', this.isPlaying);
    AppStorage.setOrCreate('playerLoading', this.isLoading);
    // 被动暂停的原因。空串 = 用户自己停的或正在播，界面不用提示
    AppStorage.setOrCreate('playerPauseReason', this.pauseReason);
    const t: Track | null = this.currentTrack;
    if (t !== null) {
      AppStorage.setOrCreate('playerTitle', t.title);
      AppStorage.setOrCreate('playerArtist', t.artist);
      AppStorage.setOrCreate('playerPosition', this._position);
      AppStorage.setOrCreate('playerDuration', this._duration);
      AppStorage.setOrCreate('playerCoverUrl', Store.get().coverUrlFor(t, 600));
    }
    // 同步系统媒体卡片；开始播放即申请长时任务，保证后台不被冻结
    if (this.media !== null) {
      this.media.updateState(this.isPlaying, this.isLoading, this._position);
      if (this.isPlaying) {
        this.media.startBackground();
      }
    }
    // 推给桌面卡片（FormSync 内部节流，1 秒最多一次）
    FormSync.push({
      title: t !== null ? t.title : '',
      artist: t !== null ? t.artist : '',
      playing: this.isPlaying,
      lyric: this.curLyricLine
    });
  }

  private notifyTrack(track: Track): void {
    if (this.onTrackChange !== null) {
      this.onTrackChange(track);
    }
    this.syncSessionMeta(track);
  }

  /** 把曲目信息推给系统媒体卡片 */
  private syncSessionMeta(track: Track): void {
    if (this.media !== null) {
      // 系统卡片/灵动岛里的封面只有百来像素，没必要传 600px 大图（解码更重）
      this.media.updateMetadata(track, Store.get().coverUrlFor(track, 300), this.lrcText);
      this.media.updateMode(this.shuffle, this.repeat, this.favMode);
    }
  }

  private notifyProgress(): void {
    if (this.onProgress !== null) {
      this.onProgress(this._position, this._duration);
    }
    // 采样间隔已缩到 200ms，若每次都写 AppStorage，
    // 所有绑定 playerPosition 的组件一秒要重算 5 次，纯属浪费。
    // 迷你条/卡片只需要「大致进度」，按秒级粒度更新足够，
    // 播放页的歌词高亮走 onProgress 回调，不受这里影响。
    if (Math.abs(this._position - this._lastPushedPos) >= 900 ||
        this._position < this._lastPushedPos) {
      this._lastPushedPos = this._position;
      AppStorage.setOrCreate('playerPosition', this._position);
    }
    // 存档单独节流：每次落盘要对最多 300 首做 stringify 再 flush 磁盘，
    // 跟着 900ms 的刷新点走太浪费。5s 的粒度足够「接着上次听」；
    // 暂停/播完/切歌这些关键节点会立刻补一次，不依赖这里
    if (Math.abs(this._position - this._lastSavedPos) >= 5000 ||
        this._position < this._lastSavedPos) {
      this._lastSavedPos = this._position;
      this.persistQueue();
    }
    // 时长在 prepared 之后才准，这里补同步，否则迷你条的进度比例会一直是 0
    if (this._duration !== this._lastPushedDur) {
      this._lastPushedDur = this._duration;
      AppStorage.setOrCreate('playerDuration', this._duration);
    }
  }

  async release(): Promise<void> {
    this.stopPosTimer();
    await this.resetPlayer();
    this.queue = [];
    this.index = -1;
    this.shuffledOrder = [];
    // 应用退出时通知栏/锁屏卡片要跟着消失，不然会留一张点不动的空卡片
    this.clearNowPlayingInfo();
    if (this.media !== null) {
      await this.media.destroy();
      this.media = null;
    }
  }
}

async function fileExists(path: string): Promise<boolean> {
  try {
    await fs.access(path);
    return true;
  } catch (e) {
    return false;
  }
}

/**
 * 把内部歌词行转成标准 LRC 文本，交给系统媒体会话（锁屏/播控中心/桌面歌词）。
 * 系统按时间轴自行逐行高亮，应用不用再为歌词反复重建卡片。
 * start 是毫秒；LRC 时间轴格式为 [mm:ss.xx]。
 */
function buildLrc(lines: LyricLine[]): string {
  let out: string = '';
  for (let i = 0; i < lines.length; i++) {
    const ms: number = lines[i].start;
    if (ms < 0) {
      continue;
    }
    const m: number = Math.floor(ms / 60000);
    const s: number = Math.floor(ms % 60000 / 1000);
    const cs: number = Math.floor(ms % 1000 / 10);
    const text: string = lines[i].text.trim();
    if (text.length === 0) {
      continue;
    }
    const pad = (n: number, w: number): string => {
      let str: string = n.toString();
      while (str.length < w) {
        str = '0' + str;
      }
      return str;
    };
    out += '[' + pad(m, 2) + ':' + pad(s, 2) + '.' + pad(cs, 2) + ']' + text + '\n';
  }
  return out;
}
