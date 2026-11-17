import avSession from '@ohos.multimedia.avsession';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { common } from '@kit.AbilityKit';
import { Track, RepeatMode } from '../model/Models';

/**
 * 媒体会话 + 长时任务。
 *
 * 作用：
 *  1. 应用退到后台 / 锁屏后音频继续播放（AUDIO_PLAYBACK 长时任务保活，避免被系统冻结）
 *  2. 系统控制中心、锁屏、蓝牙耳机按键出现本应用的媒体卡片，可播放/暂停/上下曲/拖进度
 *
 * 说明：鸿蒙的「实况窗」（Live View）能力需要受限权限 ohos.permission.LIVE_VIEW，
 * 仅对华为白名单应用开放，三方应用无法申请，因此这里用系统标准的媒体会话方案。
 */
export class MediaSession {
  /**
   * 歌词刷进系统卡片的最小间隔：每次 setAVMetadata 都会让灵动岛重建卡片。
   * 不能设太大——流行歌一行只有 2~3 秒，窗口过宽会整行整行地丢，
   * 表现为「卡片歌词比声音慢一句 / 跳着走」。
   */
  private static readonly LYRIC_META_MIN_MS: number = 1200;

  private session: avSession.AVSession | null = null;
  private ctx: common.UIAbilityContext | null = null;
  private bgRunning: boolean = false;
  private attached: boolean = false;
  // 记住最近一次的曲目信息，歌词行变化时用它重建 metadata
  private lastTrack: Track | null = null;
  private lastCover: string = '';
  private curLyric: string = '';
  /** 节流窗口内最新的一行歌词：到点补发，而不是丢弃 */
  private pendingLyric: string = '';
  /** 节流补发的定时器句柄（-1 表示没有待执行的定时器） */
  private lyricTimer: number = -1;
  /** 上一次真正推送歌词的时间戳（节流用） */
  private lastLyricAt: number = 0;
  /** 上一次 setAVMetadata 还没返回时跳过新的推送，避免 IPC 排队 */
  private metaBusy: boolean = false;
  /**
   * 被 metaBusy 挡下来的那份元数据（通常是切歌时正赶上歌词推送）。
   * 只留最新的一份：旧曲目的信息补发出去没有任何意义。
   */
  private pendingMeta: avSession.AVMetadata | null = null;
  // 最近一次播放状态：推送 loopMode 时要把 state/position 一起带上，否则系统会丢弃
  private lastPlaying: boolean = false;
  private lastLoading: boolean = false;
  private lastPos: number = 0;
  private lastPosAt: number = 0;
  /** 最近一次收藏状态：updateMode 推送时要一起带上，否则会被系统清空 */
  private lastFav: boolean = false;
  /**
   * 最近一次循环模式。
   * 系统卡片的「播放模式」按钮是按它自己缓存的 loopMode 去 supportedLoopModes 里取下一项的，
   * 所以每次 setAVPlaybackState 都必须回传当前 loopMode；只要有一次不带，
   * 系统就会重置成默认值，表现为点按钮永远回传同一个模式（列表循环）。
   */
  private lastMode: avSession.LoopMode = avSession.LoopMode.LOOP_MODE_LIST;

  // 由 PlayerCore 注入：系统侧操作 → 播放器实际动作
  onPlayCmd: (() => void) | null = null;
  onPauseCmd: (() => void) | null = null;
  onNextCmd: (() => void) | null = null;
  onPrevCmd: (() => void) | null = null;
  onStopCmd: (() => void) | null = null;
  onSeekCmd: ((ms: number) => void) | null = null;
  /** 锁屏/控制中心点「喜爱」按钮 */
  onFavCmd: (() => void) | null = null;
  /** 锁屏/控制中心切「播放模式」按钮（系统会传来目标 LoopMode） */
  onLoopModeCmd: ((mode: avSession.LoopMode) => void) | null = null;

  get isReady(): boolean {
    return this.session !== null;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.session !== null) {
      return;
    }
    this.ctx = context;
    try {
      this.session = await avSession.createAVSession(context, 'FeiYin', 'audio');
      this.registerCommands();
      await this.session.activate();
      // 声明支持的循环模式，系统卡片的「播放模式」按钮才会在这几个模式间循环
      await this.declareLoopModes();
      // 桌面歌词（HarmonyOS 系统能力，since 23）：支持时开启后，
      // 系统会把 metadata.lyric 里的 LRC 解析成逐行歌词展示在系统桌面上。
      // 不支持/未开启权益时报错都无所谓，静默降级即可。
      this.tryEnableDesktopLyric();
    } catch (err) {
      console.error('[session] 创建媒体会话失败：' + errText(err));
      this.session = null;
    }
  }

  /**
   * 桌面歌词：系统把这个会话登记成「可显示桌面歌词」的应用。
   * 显示内容由 metadata.lyric（标准 LRC）驱动，系统自己逐行滚动，
   * 应用侧不再需要逐行推送（那套节流推送仍然保留，给不支持的系统兜底）。
   */
  private async tryEnableDesktopLyric(): Promise<void> {
    const s: avSession.AVSession | null = this.session;
    if (s === null) {
      return;
    }
    try {
      const supported: boolean = await avSession.isDesktopLyricSupported();
      if (!supported) {
        console.info('[session] 桌面歌词不支持，跳过');
        return;
      }
      await s.enableDesktopLyric(true);
      console.info('[session] 桌面歌词已启用');
    } catch (e) {
      console.error('[session] 启用桌面歌词失败（忽略）：' + errText(e));
    }
  }

  /**
   * 声明本应用支持的循环模式。
   * 不声明的话，锁屏/控制中心的「播放模式」按钮点下去只会重复上报同一个值，
   * 因为系统不知道还能切到哪些模式。
   * 这里列应用真正支持的四态：列表循环、单曲循环、随机播放、
   * 以及借用顺序模式承载的「播放喜爱」（系统侧 CUSTOM 的图标与随机重复，故不用）。
   */
  private async declareLoopModes(): Promise<void> {
    const s: avSession.AVSession | null = this.session;
    if (s === null) {
      return;
    }
    try {
      await s.setSupportedLoopModes([
        avSession.LoopMode.LOOP_MODE_LIST,
        avSession.LoopMode.LOOP_MODE_SINGLE,
        avSession.LoopMode.LOOP_MODE_SHUFFLE,
        avSession.LoopMode.LOOP_MODE_SEQUENCE
      ]);
      console.info('[session] 已声明支持的循环模式（四态）');
    } catch (e) {
      // 个别系统版本拒绝四态声明，降级为三态，至少保证循环按钮可用
      console.error('[session] 声明四态失败，降级三态');
      try {
        await s.setSupportedLoopModes([
          avSession.LoopMode.LOOP_MODE_LIST,
          avSession.LoopMode.LOOP_MODE_SINGLE,
          avSession.LoopMode.LOOP_MODE_SHUFFLE
        ]);
        console.info('[session] 已声明支持的循环模式（三态）');
      } catch (e2) {
        console.error('[session] 声明循环模式失败（忽略）');
      }
    }
  }

  /** 注册系统侧控制命令。逐条 try-catch，避免个别命令在低版本不存在时整体失效 */
  private registerCommands(): void {
    const s: avSession.AVSession | null = this.session;
    if (s === null) {
      return;
    }
    try {
      s.on('play', () => {
        console.info('[session] recv play');
        this.fire(this.onPlayCmd);
      });
    } catch (e) {
      console.error('[session] on(play) 注册失败');
    }
    try {
      s.on('pause', () => {
        console.info('[session] recv pause');
        this.fire(this.onPauseCmd);
      });
    } catch (e) {
      console.error('[session] on(pause) 注册失败');
    }
    try {
      s.on('stop', () => {
        console.info('[session] recv stop');
        this.fire(this.onStopCmd);
      });
    } catch (e) {
      console.error('[session] on(stop) 注册失败');
    }
    try {
      s.on('playNext', () => {
        console.info('[session] recv playNext');
        this.fire(this.onNextCmd);
      });
    } catch (e) {
      console.error('[session] on(playNext) 注册失败');
    }
    try {
      s.on('playPrevious', () => {
        console.info('[session] recv playPrevious');
        this.fire(this.onPrevCmd);
      });
    } catch (e) {
      console.error('[session] on(playPrevious) 注册失败');
    }
    try {
      s.on('seek', (time: number) => {
        console.info('[session] recv seek ' + time);
        if (this.onSeekCmd !== null) {
          this.onSeekCmd(time);
        }
      });
    } catch (e) {
      console.error('[session] on(seek) 注册失败');
    }
    // 注册「喜爱」命令后，锁屏/控制中心的媒体卡片才会出现喜爱按钮
    try {
      s.on('toggleFavorite', () => {
        console.info('[session] recv toggleFavorite');
        this.fire(this.onFavCmd);
      });
    } catch (e) {
      console.error('[session] on(toggleFavorite) 注册失败');
    }
    // 注册「循环模式」命令后，锁屏/控制中心才会出现播放模式按钮
    try {
      s.on('setLoopMode', (mode: avSession.LoopMode) => {
        console.info('[session] recv setLoopMode ' + mode);
        if (this.onLoopModeCmd !== null) {
          this.onLoopModeCmd(mode);
        }
      });
    } catch (e) {
      console.error('[session] on(setLoopMode) 注册失败');
    }
    console.info('[session] 系统控制命令已注册');
  }

  private fire(cb: (() => void) | null): void {
    if (cb !== null) {
      cb();
    }
  }

  /**
   * 更新曲目信息（标题/歌手/专辑/时长/封面）。
   * lyrics 是整份标准 LRC 文本：系统（锁屏/播控中心/桌面歌词）会自己解析、
   * 逐行高亮，应用不再需要为歌词逐行重建卡片。没有同步歌词时传空串。
   */
  async updateMetadata(track: Track, coverUrl: string, lyrics: string = ''): Promise<void> {
    const s: avSession.AVSession | null = this.session;
    if (s === null) {
      return;
    }
    this.lastTrack = track;
    this.lastCover = coverUrl;
    this.curLyric = '';
    // 切歌时清掉上一首残留的待发歌词，否则会把旧歌的句子写到新卡片上
    this.pendingLyric = '';
    if (this.lyricTimer !== -1) {
      clearTimeout(this.lyricTimer);
      this.lyricTimer = -1;
    }
    // 新曲目立即放行一次歌词推送
    this.lastLyricAt = 0;
    const meta: avSession.AVMetadata = {
      assetId: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: track.duration
    };
    if (coverUrl.length > 0) {
      meta.mediaImage = coverUrl;
    }
    // 整份 LRC 交给系统：支持它的系统版本（锁屏/播控/桌面歌词）会自动逐行滚，
    // 不支持的字段会被忽略，不影响其余元数据
    if (lyrics.length > 0) {
      meta.lyric = lyrics;
    }
    // 之前这里是「忙就丢弃」：切歌时恰好正在推歌词，新歌名就永远发不出去，
    // 锁屏/控制中心会一直停在上首。现在改成排队补发（只留最新一份）。
    this.pendingMeta = meta;
    await this.drainMeta();
  }

  /** 把排队中的元数据依次推完（同一时刻只有一次 setAVMetadata 在飞） */
  private async drainMeta(): Promise<void> {
    const s: avSession.AVSession | null = this.session;
    if (s === null) {
      this.pendingMeta = null;
      return;
    }
    if (this.metaBusy) {
      // 正在推送：它结束时会再调一次本方法
      return;
    }
    while (this.pendingMeta !== null) {
      const m: avSession.AVMetadata = this.pendingMeta;
      this.pendingMeta = null;
      this.metaBusy = true;
      try {
        await s.setAVMetadata(m);
      } catch (err) {
        console.error('[session] 设置曲目信息失败：' + errText(err));
      } finally {
        this.metaBusy = false;
      }
    }
  }

  /**
   * 歌词行同步到系统媒体卡片（灵动岛 / 控制中心 / 锁屏）。
   * 三方应用无法用实况窗，这里借 metadata 的 artist 字段滚动显示当前歌词行。
   *
   * 注意：每次 setAVMetadata 都会让系统重建整张卡片（含封面解码），
   * 逐句刷新会造成灵动岛反复重绘、播放偶发卡顿，因此这里做两层保护：
   *  1. 最小间隔 1.2 秒，窗口内的变化只保留最新一行，到点补发（不丢弃）；
   *  2. 上一次 IPC 还没返回时先记下来，等它返回后再补，避免调用在队列里堆积。
   */
  async updateLyric(line: string): Promise<void> {
    const t: Track | null = this.lastTrack;
    const s: avSession.AVSession | null = this.session;
    if (t === null || s === null || line === this.curLyric) {
      return;
    }
    this.pendingLyric = line;
    if (this.metaBusy) {
      // 正在推送：稍后再试。直接 return 的话，这一行就丢了——
      // 只有在 flushLyric 里排队时才保证补发，元数据推送占着锁时没人接手。
      this.scheduleLyricFlush(300);
      return;
    }
    const wait: number = MediaSession.LYRIC_META_MIN_MS - (Date.now() - this.lastLyricAt);
    if (wait > 0) {
      this.scheduleLyricFlush(wait + 20);
      return;
    }
    await this.flushLyric();
  }

  /** 在指定延迟后补发待同步的歌词（同一时刻只保留一个定时器） */
  private scheduleLyricFlush(delay: number): void {
    if (this.lyricTimer !== -1) {
      return;
    }
    this.lyricTimer = setTimeout(() => {
      this.lyricTimer = -1;
      this.flushLyric();
    }, delay);
  }

  /** 把 pendingLyric 真正写进卡片元数据 */
  private async flushLyric(): Promise<void> {
    const t: Track | null = this.lastTrack;
    const s: avSession.AVSession | null = this.session;
    const line: string = this.pendingLyric;
    if (t === null || s === null || this.metaBusy || line === this.curLyric) {
      // 上一次 IPC 还没回来：等一会儿重试，别把这一行丢掉
      if (this.metaBusy && line !== this.curLyric) {
        this.scheduleLyricFlush(300);
      }
      return;
    }
    this.curLyric = line;
    this.lastLyricAt = Date.now();
    console.info('[session] lyric -> ' + line);
    const meta: avSession.AVMetadata = {
      assetId: t.id,
      title: t.title,
      artist: line.length > 0 ? line : t.artist,
      album: t.album,
      duration: t.duration
    };
    // 当前行歌词单独给一份（since 17）：支持这个字段的系统面板会拿它做
    // 「当前句」的展示，不需要再解析整份 LRC 的时间轴
    if (line.length > 0) {
      meta.singleLyricText = line;
    }
    if (this.lastCover.length > 0) {
      meta.mediaImage = this.lastCover;
    }
    this.metaBusy = true;
    try {
      await s.setAVMetadata(meta);
    } catch (err) {
      console.error('[session] 同步歌词失败：' + errText(err));
    } finally {
      this.metaBusy = false;
      // 推送期间切了歌：先把新曲目的元数据补上，否则卡片会一直停在上首
      if (this.pendingMeta !== null) {
        this.drainMeta();
      }
      // 推送期间可能又跳了一行：这里再补一次，避免一直落后
      if (this.pendingLyric !== this.curLyric) {
        const wait: number = MediaSession.LYRIC_META_MIN_MS - (Date.now() - this.lastLyricAt);
        this.scheduleLyricFlush(wait > 0 ? wait + 20 : 0);
      }
    }
  }

  /** 更新播放状态与进度锚点（系统会据此自行推算进度，不用逐帧同步） */
  async updateState(playing: boolean, loading: boolean, position: number): Promise<void> {
    const s: avSession.AVSession | null = this.session;
    if (s === null) {
      return;
    }
    this.lastPlaying = playing;
    this.lastLoading = loading;
    this.lastPos = position > 0 ? position : 0;
    this.lastPosAt = Date.now();
    let st: avSession.PlaybackState = avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    if (loading) {
      st = avSession.PlaybackState.PLAYBACK_STATE_BUFFERING;
    } else if (playing) {
      st = avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    }
    const pos: avSession.PlaybackPosition = {
      elapsedTime: position > 0 ? Math.round(position) : 0,
      updateTime: Date.now()
    };
    // 只传 state + position：speed 传 0 会被系统判为非法参数
    // （报错 SetAVPlaybackState failed : native invalid parameters）
    // 但 loopMode / isFavorite 必须一起带上，否则系统会把自己的缓存重置成默认值。
    const state: avSession.AVPlaybackState = {
      state: st,
      position: pos,
      loopMode: this.lastMode,
      isFavorite: this.lastFav
    };
    try {
      await s.setAVPlaybackState(state);
    } catch (err) {
      console.error('[session] 设置播放状态失败：' + errText(err));
    }
  }

  /**
   * 同步循环/随机模式到系统卡片。
   * fav 为 true 时用 LOOP_MODE_SEQUENCE 承载应用自定义的「播放喜爱」：
   * 系统只内置 循环/单曲/列表/随机 四张图标，LOOP_MODE_CUSTOM 会被渲染成「随机」图标，
   * 与真正的随机无法区分；顺序播放的图标是独立的，用它当第四态至少视觉上能分辨。
   */
  async updateMode(shuffle: boolean, repeat: RepeatMode, fav: boolean = false): Promise<void> {
    const s: avSession.AVSession | null = this.session;
    if (s === null) {
      return;
    }
    let mode: avSession.LoopMode = avSession.LoopMode.LOOP_MODE_LIST;
    if (fav) {
      mode = avSession.LoopMode.LOOP_MODE_SEQUENCE;
    } else if (shuffle) {
      mode = avSession.LoopMode.LOOP_MODE_SHUFFLE;
    } else if (repeat === 'one') {
      mode = avSession.LoopMode.LOOP_MODE_SINGLE;
    } else if (repeat === 'all') {
      mode = avSession.LoopMode.LOOP_MODE_LIST;
    }
    // 必须带上 state + position：只传 loopMode 会被系统当成参数不全而丢弃，
    // 表现为卡片的模式图标永远不变、点按钮一直回传同一个值。
    this.lastMode = mode;
    const st: avSession.PlaybackState = this.lastLoading
      ? avSession.PlaybackState.PLAYBACK_STATE_BUFFERING
      : (this.lastPlaying
        ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE);
    const pos: avSession.PlaybackPosition = {
      elapsedTime: Math.round(this.lastPos + (this.lastPlaying ? Date.now() - this.lastPosAt : 0)),
      updateTime: Date.now()
    };
    try {
      await s.setAVPlaybackState({
        state: st,
        position: pos,
        loopMode: mode,
        isFavorite: this.lastFav
      } as avSession.AVPlaybackState);
      console.info('[session] loopMode pushed ' + mode + ' fav=' + this.lastFav);
    } catch (err) {
      console.error('[session] 设置循环模式失败：' + errText(err));
    }
  }

  /** 同步收藏状态到系统卡片（锁屏/控制中心的喜爱按钮高亮） */
  async updateFavorite(fav: boolean): Promise<void> {
    const s: avSession.AVSession | null = this.session;
    if (s === null) {
      return;
    }
    this.lastFav = fav;
    // 与 loopMode 同理：只传 isFavorite 会被系统判为参数不全而丢弃，
    // 表现为锁屏点红心后按钮不变实心。这里把当前 state/position 一起带上。
    const st: avSession.PlaybackState = this.lastLoading
      ? avSession.PlaybackState.PLAYBACK_STATE_BUFFERING
      : (this.lastPlaying
        ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE);
    const pos: avSession.PlaybackPosition = {
      elapsedTime: Math.round(this.lastPos + (this.lastPlaying ? Date.now() - this.lastPosAt : 0)),
      updateTime: Date.now()
    };
    try {
      await s.setAVPlaybackState({
        state: st,
        position: pos,
        loopMode: this.lastMode,
        isFavorite: fav
      } as avSession.AVPlaybackState);
    } catch (err) {
      console.error('[session] 设置收藏状态失败：' + errText(err));
    }
  }

  /**
   * 申请音频播放长时任务。申请成功后进程在后台不会被冻结，
   * 系统通知栏会出现「正在播放」的常驻任务提示。
   */
  async startBackground(): Promise<void> {
    if (this.bgRunning || this.ctx === null) {
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: this.ctx.abilityInfo.bundleName,
            abilityName: this.ctx.abilityInfo.name
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(this.ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.bgRunning = true;
      this.attached = true;
      console.info('[session] 后台播放长时任务已启动');
    } catch (err) {
      console.error('[session] 启动长时任务失败：' + errText(err));
    }
  }

  async stopBackground(): Promise<void> {
    if (!this.bgRunning || this.ctx === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.ctx);
    } catch (err) {
      console.error('[session] 停止长时任务失败：' + errText(err));
    }
    this.bgRunning = false;
  }

  get backgroundRunning(): boolean {
    return this.bgRunning;
  }

  async destroy(): Promise<void> {
    await this.stopBackground();
    // 退出/重建会话时把待发的歌词与元数据都丢掉，
    // 否则定时器还会在会话销毁后再跑一拍
    if (this.lyricTimer !== -1) {
      clearTimeout(this.lyricTimer);
      this.lyricTimer = -1;
    }
    this.pendingLyric = '';
    this.pendingMeta = null;
    const s: avSession.AVSession | null = this.session;
    this.session = null;
    if (s !== null) {
      try {
        await s.deactivate();
      } catch (e) {
      }
      try {
        await s.destroy();
      } catch (e) {
      }
    }
  }
}

function errText(err: Object): string {
  if (err instanceof Error) {
    return err.message;
  }
  return JSON.stringify(err);
}
