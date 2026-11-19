import { pasteboard } from '@kit.BasicServicesKit';
import { Track, PlayMode, LyricLine, LyricsResult, PlayerSkin } from '../model/Models';
import { APP_FONT, APP_FONT_SCRIPT, registerAppFonts } from '../utils/Fonts';
import { Store } from '../store/Store';
import { Router } from '../utils/Router';
import { Motion } from '../utils/Motion';
import { Theme, Fmt, toast, topInset, bottomInset } from '../utils/Theme';
import { refreshSystemBar, holdScreenOn } from '../utils/WindowBar';
import { ClockDial } from '../components/ClockDial';
import { pickCoverColor, tone, recolor, DEFAULT_ACCENT } from '../utils/CoverColor';

/**
 * 全应用统一字体见 utils/Fonts：Tinos（Times New Roman 的度量兼容开源替代）。
 * 中文在该字体里没有字形，会自动回退到系统中文字体。
 */

/**
 * 播放页布局（银灰余音 / 唱片机版 v3）。
 *
 * 版式来自参考设计（"银灰余音"刊头），并按需求做了三处产品化：
 * 唱片盘心放封面、左上卡片放歌词、歌名移到原来那句歌词的位置。
 *
 *   Let A Melody Hold This Moment.    vol. 01
 *   ┌──────────┐   ╭──────────────╮
 *   │ LYRICS   │   │  银色黑胶     │
 *   │ 上一句    │   │  ╭──────╮    │ ← 盘心 = 专辑封面（随盘转）
 *   │ 当前句…   │   │  │ 封面  │    │
 *   │ 下一句    │   ╰──┴──────┴────╯
 *   │ — 03     │  ╲  ← 唱臂（播放搭下、暂停抬起）
 *   └──────────┘
 *        —— 专 辑 名 ——            ← 中线细线
 *              哪 怕                ← 歌名（原歌词行的位置）
 *             莫文蔚
 *   ╭──────────────────────────────╮
 *   │ ▮▮▮ 歌名      ♥             │
 *   │ 00:07 ────●──────────  04:17 │
 *   │ ↻    ⏮  ( ▶ )  ⏭      SIDE C │
 *   │ STEREO/33⅓  some things… 01—03│
 *   ╰──────────────────────────────╯
 *
 * 所有几何以 360vp 为基准、按实测屏宽等比缩放；歌词卡行数按剩余高度自适应，
 * 高屏不会在中间留一大片空白。
 *
 * 配色不再跟主题走深/浅两套——参考稿的银灰卡片自带底色，
 * 直接压在模糊封面上就是参考图的观感；只有直接落在背景上的文字分两档亮度。
 */

// ---------------- 场景区几何（360vp 设计基准，按实测宽度等比缩放） ----------------
/** 歌词卡宽 178（竖版卡片），高度由「行数 × 行高」决定，与 214 的圆盘呼应 */
const CARD_W0: number = 178;
const CARD_X0: number = 10;
/** 只收 3°：再斜歌词就看着累，3° 还能留住"随手一放"的味道 */
const CARD_TILT: number = -3;
/**
 * 唱片周围的「轨道尾迹」：六道极细弧线，从盘左下缘外绕到右侧，
 * 由内向外逐层变淡、两端都收进全透明，只在中段露出可见的一段。
 * 每项：[向外偏移(vp), 起始角, 结束角, 峰值不透明度, 线宽(vp), 纵向压扁比]
 * 角度沿用 canvas 习惯：0° 向右、顺时针为正，故 152° ≈ 左下、270° ≈ 正上、374° ≈ 右侧偏下。
 */
const ORBIT_ARCS: number[][] = [
  [9, 168, 374, 0.30, 0.58, 0.97],
  [15, 160, 378, 0.44, 0.66, 0.96],
  [22, 152, 383, 0.52, 0.72, 0.95],
  [29, 145, 387, 0.40, 0.66, 0.95],
  [35, 139, 391, 0.27, 0.60, 0.94],
  [40, 134, 395, 0.17, 0.55, 0.93]
];
/** 弧线之间的细光点：[偏移, 角度, 直径(vp), 不透明度, 压扁比] */
const ORBIT_DOTS: number[][] = [
  [15, 228, 1.3, 0.55, 0.96],
  [15, 250, 1.0, 0.42, 0.96],
  [22, 224, 1.1, 0.47, 0.95],
  [22, 264, 1.2, 0.43, 0.95],
  [15, 300, 0.9, 0.35, 0.96],
  [35, 236, 1.1, 0.33, 0.94],
  [29, 316, 0.9, 0.30, 0.95]
];
/** 回形针 */
const CLIP_W: number = 15;
const CLIP_H: number = 37;
const CLIP_TILT: number = -19;
const CLIP_DX: number = 14;
const CLIP_DY: number = -8;
/** 唱片：直径 214，盘心是封面 */
const DISC_D0: number = 214;
const DISC_X0: number = 5;
/** 封套版：封套 230 见方、左缘 22、微斜 1.6°；黑胶右缘距屏 22 */
const SLV_W0: number = 218;
const SLV_X0: number = 16;
const SLV_TILT: number = -1.6;
/** 封套下方留白：黑胶下缘与投影都在这一块里 */
const SLV_GAP0: number = 14;
const DISC_RIGHT0: number = 18;
/** 场景上下留白 */
const SCENE_PAD0: number = 18;
/** 播放控制盘直径：卡内宽度约 306，盘 + 两侧模式键（34×2）正好排开 */
const DIAL_D: number = 156;
/** 卡内歌词：行高 30，行数按屏幕剩余高度自适应（5~7 行） */
const LYRIC_LH0: number = 30;
const LYRIC_ROWS_MIN: number = 5;
const LYRIC_ROWS_MAX: number = 7;
/** 唱臂（绘制盒 62×132，支点在盒内 26,30，整组绕支点旋转） */
const ARM_BOX_W: number = 62;
const ARM_BOX_H: number = 134;
const ARM_PIVOT_X: number = 26;
const ARM_PIVOT_Y: number = 30;
const ARM_REST: number = 18;     // 待机抬起角（臂靠向盘外沿）
const ARM_PLAY: number = 40;     // 播放时搭到音轨上的角

/** 唱片分面字母：档案行 SIDE ? 用 */
const SIDE_LETTERS: string[] = ['A', 'B', 'C', 'D'];

@Entry
@Component
struct NowPlaying {
  @StorageProp('isDark') private isDark: boolean = true;
  @State private title: string = '';
  @State private artist: string = '';
  @State private album: string = '';
  @State private isPlaying: boolean = false;
  /** 音律条比例（0.3~1），左组与右组相位镜像；暂停时全部压回 0.3 */
  @State private eqL: number[] = [0.3, 0.3, 0.3, 0.3, 0.3, 0.3];
  @State private eqR: number[] = [0.3, 0.3, 0.3, 0.3, 0.3, 0.3];
  private eqTimer: number = -1;
  private eqTick: number = 0;
  @State private isLoading: boolean = false;
  /** 播放球被按住的瞬间缩一点。起播有网络与音频管线的固有延迟，按下去先有回应 */
  @State private playPress: boolean = false;
  @State private playPos: number = 0;
  @State private duration: number = 0;
  @State private playMode: PlayMode = 'loop';
  @State private immersiveOn: boolean = false;
  @State private liked: boolean = false;
  @State private coverUrl: string = '';
  /** 封面主色：时计皮肤的环、字、背景光全部由它派生 */
  @State private accent: string = DEFAULT_ACCENT;
  /** 取色请求的封面地址，用来丢弃上一首迟到回来的结果 */
  private accentSrc: string = '';
  @State private seekValue: number = 0;
  @State private isSeeking: boolean = false;
  /**
   * 已提交、但播放器还没走到的 seek 目标（ms）；-1 表示没有在途 seek。
   *
   * 回弹的根因：`seek()` 里 `await avPlayer.seek()` 要 100~300ms，
   * 这段窗口里 200ms 的进度回调还在报**旧位置**，会把滑块"啪"地写回原处。
   * 因此提交后要开一个保护窗口，直到播放器真的到位才允许进度覆盖滑块。
   */
  private seekPending: number = -1;
  /** 保护窗口的兜底截止时间：播放器迟迟不到位（缓冲/出错）也不能永远压着滑块 */
  private seekGuardUntil: number = 0;
  /** 唱片当前旋转角（度）：播放时累加。不取模——回绕会让 rotate 反转一整圈 */
  @State private discAngle: number = 0;
  /** 场景实测宽度（vp）：卡片与唱片按它等比缩放 */
  @State private sceneW: number = 360;
  /** 场景可用高度（vp）：歌词卡行数按它自适应，避免高屏上留一大片空 */
  @State private sceneAreaH: number = 380;
  /**
   * 播放页外观：classic 经典玻璃版 / vinyl 唱片封套版。
   * 字段初始化就直接读设置，而不是先给 'classic' 再在 aboutToAppear 改正——
   * 否则选封套版的用户每次进页面都会先闪一帧经典版
   */
  @State private skin: PlayerSkin = Store.get().playerSkin;
  /** 唱臂角度：播放时搭到盘上（ARM_PLAY），暂停抬起（ARM_REST），700ms 缓动 */
  @State private armAngle: number = ARM_REST;

  /** 底部四根跳动音柱的高度系数（0.35~1），暂停时齐齐落回 0.35 */
  @State private barsVal: number[] = [0.35, 0.35, 0.35, 0.35];
  /** 星芒透明度：沉浸光感开启且播放时缓慢脉动（对应参考稿 echo-glow） */
  @State private sparkGlow: number = 1;
  /** 队列序号（1 起）与总数：footer 右侧 01 — 03 */
  @State private trackNo: number = 0;
  @State private queueLen: number = 0;

  // ---------------- 档案行 / 次级操作（1.1.0 加料） ----------------
  /** 顶栏音质徽章文案：FLAC · 24/48。取不到格式时为空，徽章整块不显示 */
  @State private qual: string = '';
  /** 定时关闭剩余分钟；0 = 未开启。计时器由 Store 持有（跨页存活、可取消） */
  @StorageLink('sleepMin') @Watch('onSleepMinChanged') private sleepMin: number = 0;
  /** 当前曲目是否已在本地缓存（决定底部状态行写"本地"还是"流式"） */
  @State private cachedNow: boolean = false;
  /** 当前曲目规格：位深 / 采样率 / 码率，状态行用 */
  @State private depth: number = 0;
  @State private khz: number = 0;
  @State private kbps: number = 0;
  /** 音量 0~100。跟播放器实例同步，换曲重建后由 PlayerCore 自己贴回去 */
  @State private volume: number = 70;
  /** 音量落盘防抖句柄 */
  private volSaveTimer: number = -1;

  private tickTimer: number = -1;
  private tickT: number = 0;
  /** 页面是否还活着（aboutToAppear 置真、aboutToDisappear 置假）。回到前台时据此决定要不要重启动画 */
  private pageAlive: boolean = false;
  /**
   * 应用前后台。切到后台时把场景动画（60ms 一格）和均衡器（130ms 一格）停掉：
   * 后台播放靠长时任务维持，界面根本不可见，这些定时器只是空转烧电。
   */
  @StorageProp('appForeground') @Watch('onAppForeground') private appFg: boolean = true;

  // ---------------- 场景装饰：唱片周围的轨道线（Canvas 画，见 drawOrbits） ----------------
  private orbitCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private orbitReady: boolean = false;
  private orbitTimer: number = -1;

  // ---------------- 下拉返回（跟手） ----------------
  @State private dragY: number = 0;
  @State private dragScale: number = 1;
  private dragFlying: boolean = false;
  private flyTimer: number = -1;

  // ---------------- 歌词（当前句显示在场景下方） ----------------
  @State private lyrics: LyricLine[] = [];
  @State private lyricsSynced: boolean = false;
  @State private lyricsLoading: boolean = false;
  /** 歌词请求抛异常，与「服务器确实没收录」区分开 */
  @State private lyricsFailed: boolean = false;
  @State private curLine: number = -1;
  private lyricsTrackId: string = '';

  /**
   * 歌词时间偏移（秒），正数 = 歌词提前出现。
   * 服务器给的歌词轴经常整体偏 1~2 秒，这里让人手动校正；按歌曲记住。
   */
  @State private lyricOffset: number = 0;
  /** 微调面板是否展开：长按歌词卡呼出，松手后 5 秒自动收起 */
  @State private offsetBar: boolean = false;
  private offsetBarTimer: number = -1;

  // 控制卡（deck）在窗口里的位置：下拉手势的 judge 用它把这块区域让给进度条/按钮。
  private deckRectX: number = -1;
  private deckRectY: number = -1;
  private deckRectW: number = 0;
  private deckRectH: number = 0;

  /** 最近一次查询收藏状态的歌曲 id，防止换歌后旧结果串台 */
  private likedSongId: string = '';

  /** 从服务器同步当前曲目的收藏状态（getSong.starred） */
  private syncLiked(songId: string): void {
    this.likedSongId = songId;
    Store.get().isStarred(songId).then((v: boolean) => {
      if (this.likedSongId === songId) {
        this.liked = v;
      }
    });
  }

  /** 用当前播放器状态刷新队列序号（footer 右侧 01 — 03） */
  private syncQueuePos(): void {
    const p = Store.get().player();
    this.trackNo = p.currentIndex + 1;
    this.queueLen = p.queueSize;
  }

  // ---------------- 档案行 / 音质 ----------------

  /** 从当前曲目同步音质徽章与规格数字；字段缺失时优雅降级，不显示假数据 */
  private syncQuality(t: Track | null): void {
    if (t === null) {
      this.qual = '';
      this.depth = 0;
      this.khz = 0;
      this.kbps = 0;
      this.cachedNow = false;
      return;
    }
    const ext: string = (t.suffix ?? '').toUpperCase();
    this.depth = t.bitDepth > 0 ? t.bitDepth : 0;
    this.khz = t.samplingRate > 0 ? Math.round(t.samplingRate / 1000) : 0;
    // Subsonic 的 bitRate 单位本来就是 kbps（Hi-Res 能到四五千），
    // 再除 1000 会显示成「5 kbps」这种自相矛盾的数
    this.kbps = t.bitRate > 0 ? Math.round(t.bitRate) : 0;
    this.cachedNow = Store.get().isCached(t.href);
    if (ext.length === 0) {
      this.qual = '';
    } else if (this.depth > 0 && this.khz > 0) {
      this.qual = ext + ' ' + this.depth + '/' + this.khz;
    } else if (this.kbps > 0) {
      this.qual = ext + ' ' + this.kbps + 'k';
    } else {
      this.qual = ext;
    }
  }

  /** 唱片的一面：8 首一面，A~D 循环 */
  private sideLabel(): string {
    const n: number = this.trackNo > 0 ? this.trackNo : 0;
    if (n === 0) {
      return 'SIDE C';
    }
    const idx: number = Math.min(3, Math.floor((n - 1) / 8));
    return 'SIDE ' + SIDE_LETTERS[idx];
  }

  /**
   * 两位序号：7 → 07，75 → 75，100 → 100。
   * 老写法 ('0' + n).slice(-2) 会把 100 截成 00，底栏就成了「75 — 00」。
   */
  private pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  private trackLabel(): string {
    // 队列长度拿不到时只写当前序号，不要出现「TRACK 32 / 00」这种半截数据
    if (this.trackNo <= 0) {
      return 'TRACK';
    }
    if (this.queueLen <= 0) {
      return 'TRACK ' + this.pad2(this.trackNo);
    }
    return 'TRACK ' + this.pad2(this.trackNo) + ' / ' + this.pad2(this.queueLen);
  }

  /**
   * 卡片页脚的规格缩写：`FLAC 24/48`。
   *
   * 原来底部那枚胶囊写的是全量规格（FLAC · 24 BIT · 48 kHz · 1411 kbps · 流式），
   * 和卡内页脚的 STEREO / 33⅓ 说的是同一件事，却分散在两个视觉层。胶囊已经删掉，
   * 规格收进页脚左段——但页脚只有 7vp，撑不下五个词，所以只留「格式 + 位深/采样率」。
   * 码率、本地/流式都去掉：前者是听感无关的虚荣数字，后者不该以文字占位。
   * 元数据缺失时退回原铭牌，不留空串（空着会让中间那句往左塌）。
   */
  private specBadge(): string {
    const ext: string = this.qual.length > 0 ? this.qual.split(' ')[0] : '';
    let num: string = '';
    if (this.depth > 0 && this.khz > 0) {
      num = this.depth + '/' + this.khz;
    } else if (this.depth > 0) {
      num = this.depth + ' BIT';
    } else if (this.khz > 0) {
      num = this.khz + ' kHz';
    }
    if (ext.length > 0 && num.length > 0) {
      return ext + ' ' + num;
    }
    if (ext.length > 0) {
      return ext;
    }
    if (num.length > 0) {
      return num;
    }
    return 'STEREO / 33⅓';
  }

  /**
   * 音量：写播放器 + 记在设置里（下次启动沿用）。
   *
   * 之前只写 AppStorage，进程一退就丢，下次启动又回到设置里那个 80%。
   * 这里做 600ms 防抖再落盘：连点几下「+」不该触发几次磁盘写入。
   */
  private applyVolume(v: number): void {
    const nv: number = Math.round(v < 0 ? 0 : (v > 100 ? 100 : v));
    if (nv === this.volume) {
      return;
    }
    this.volume = nv;
    AppStorage.setOrCreate('playerVolume', nv);
    Store.get().player().setVolume(nv / 100);
    if (this.volSaveTimer !== -1) {
      clearTimeout(this.volSaveTimer);
    }
    this.volSaveTimer = setTimeout(() => {
      this.volSaveTimer = -1;
      const st = Store.get();
      st.settings.volume = nv;
      st.saveSettings(st.settings).catch(() => {
      });
    }, 600);
  }

  /** 剩余时长文案：-01:42。拖动态跟着滑块走，松手前就能看到结果 */
  private remainLabel(): string {
    const pos: number = this.isSeeking ? this.seekValue : this.playPos;
    const rest: number = this.duration - pos;
    return '-' + Fmt.time(rest > 0 ? rest : 0);
  }

  // ---------------- 次级操作 ----------------

  /**
   * 定时关闭：关 → 15 → 30 → 60 → 关，到点暂停播放。
   *
   * 1.1.35 起底部的圆钮行被整体移除，这个循环暂时没有界面入口；
   * 逻辑与倒计时（Store 每秒校正）都保留着，等把入口迁到设置页或长按菜单再用。
   */
  private cycleSleep(): void {
    let next: number = 0;
    if (this.sleepMin === 0) {
      next = 15;
    } else if (this.sleepMin <= 15) {
      next = 30;
    } else if (this.sleepMin <= 30) {
      next = 60;
    }
    this.setSleep(next);
  }

  /**
   * 定时关闭交给 Store：页面可能被销毁重建，计时器必须只有一个。
   * 这里只负责提示文案，倒计时本身由 Store 每秒校正并写回 sleepMin。
   */
  private setSleep(min: number): void {
    Store.get().setSleepTimer(min);
    if (min <= 0) {
      toast('定时关闭已取消');
      return;
    }
    toast(min + ' 分钟后暂停播放');
  }

  /** 定时到点：Store 会把 sleepMin 置 0 并写一个 sleepFiredAt 标记 */
  private onSleepMinChanged(): void {
    if (this.sleepMin !== 0) {
      return;
    }
    const fired: number = Number(AppStorage.get<number>('sleepFiredAt') ?? 0);
    if (fired > 0 && Date.now() - fired < 4000) {
      AppStorage.setOrCreate('sleepFiredAt', 0);
      toast('已按定时暂停');
    }
  }

  /**
   * 分享：把「歌名 — 歌手 · 专辑」放进剪贴板（本地播放器没有外链，复制文本最实在）。
   * 同 cycleSleep：1.1.35 移除底部圆钮后暂无入口，实现留着备用。
   */
  private shareTrack(): void {
    if (this.title.length === 0) {
      return;
    }
    let text: string = this.title + ' — ' + this.artist;
    if (this.album.length > 0) {
      text = text + ' · ' + this.album;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      toast('歌曲信息已复制');
    }).catch(() => {
      toast('复制失败');
    });
  }

  aboutToAppear(): void {
    this.prepareLyricFonts();
    // 播放页底色恒为炭黑，状态栏与导航栏图标必须是白的；
    // 系统若是浅色模式，这里要强制转白，否则黑图标压在深底上看不见
    refreshSystemBar(true);
    const p = Store.get().player();
    const s = Store.get().settings;
    this.immersiveOn = s.immersiveLight;
    this.skin = Store.get().playerSkin;
    this.playMode = p.playMode;
    this.syncQueuePos();
    // 定时关闭由 Store 持有，sleepMin 已通过 @StorageLink 绑定，这里不再手动读一次
    // 音量跟设置里的值走；播放器实例在切歌时会重建，由 PlayerCore 自己贴回去。
    // 0 是合法的静音值，不能像以前那样用 `vol > 0 ? vol : 70` 把它顶回 70
    //（那会让界面显示 70、实际却是静音）。
    const vol: number = Number(AppStorage.get<number>('playerVolume') ?? s.volume);
    this.volume = isFinite(vol) ? Math.max(0, Math.min(100, Math.round(vol))) : 70;

    // 进入页面时当前可能已有曲目在播/暂停，先同步一次，否则封面与播放态都是空的
    const cur: Track | null = p.currentTrack;
    if (cur !== null) {
      this.title = cur.title;
      this.artist = cur.artist;
      this.album = cur.album;
      this.coverUrl = Store.get().coverUrlFor(cur, 600);
      this.refreshAccent(cur);
      this.syncLiked(cur.id);
      this.syncQuality(cur);
      this.loadLyrics(cur);
    }
    this.isPlaying = p.isPlaying;
    this.isLoading = p.isLoading;
    this.syncEq(p.isPlaying);
    this.playPos = p.position;
    this.duration = p.duration;
    this.seekValue = p.position;

    p.onTrackChange = (track: Track | null) => {
      if (track !== null) {
        // 换歌必须清掉上一首在途的 seek，否则保护窗口会压着新歌的进度不更新
        this.seekPending = -1;
        this.isSeeking = false;
        this.seekValue = 0;
        this.playPos = 0;
        // 时长也要清零：新歌的 duration 要到 prepared 才有，
        // 留着上一首的值会让进度条最大值错一截，右侧「剩余」还会显示成负数
        this.duration = 0;
        this.title = track.title;
        this.artist = track.artist;
        this.album = track.album;
        this.coverUrl = Store.get().coverUrlFor(track, 600);
        this.refreshAccent(track);
        this.liked = false;
        this.syncLiked(track.id);
        this.syncQuality(track);
        this.loadLyrics(track);
        this.syncQueuePos();
      }
    };
    p.onStateChange = (playing: boolean, loading: boolean) => {
      this.isPlaying = playing;
      this.isLoading = loading;
      this.syncEq(playing);
      // 播放中才常亮：暂停后放开，别让手机停在播放页一直亮着
      holdScreenOn(playing);
    };
    // 锁屏/控制中心点了喜爱，播放页的红心跟着变
    p.onFavChange = (fav: boolean) => {
      this.liked = fav;
    };
    // 锁屏/控制中心切了播放模式，播放页的图标跟着变
    p.onPlayModeChange = (mode: PlayMode) => {
      this.playMode = mode;
    };
    // 播放失败不往界面上抛文案：控制器会先自动降级转码，
    // 仍不成功就静默回到暂停态，让用户再点一次播放键重试
    p.onProgress = (pos: number, dur: number) => {
      this.duration = dur;
      // 拖动中：主线程要留给手势
      if (this.isSeeking) {
        return;
      }
      // 在途 seek：播放器尚未走到目标前，报的还是旧位置，不能写回滑块
      if (this.seekPending >= 0) {
        if (Math.abs(pos - this.seekPending) <= 800 || Date.now() > this.seekGuardUntil) {
          this.seekPending = -1;
        } else {
          return;
        }
      }
      this.playPos = pos;
      this.seekValue = pos;
      // 高亮用外推后的真实位置：pos 是 200ms 前的快照，直接用歌词会稳定慢半拍
      this.updateCurLine(p.livePosition);
    };

    this.startSceneTick();
    // 常亮：进页面时可能已经在放，先按当前播放态申请一次
    this.pageAlive = true;
    holdScreenOn(this.isPlaying);
  }

  aboutToDisappear(): void {
    // 回到列表页：系统栏图标按全局主题恢复
    refreshSystemBar(this.isDark);
    // 离开播放页立刻交还常亮，列表页停留不该阻止系统息屏
    this.pageAlive = false;
    holdScreenOn(false);
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
    this.stopEq();
    this.stopOffsetBarTimer();
    if (this.orbitTimer !== -1) {
      clearTimeout(this.orbitTimer);
      this.orbitTimer = -1;
    }
    this.orbitReady = false;
    if (this.flyTimer !== -1) {
      clearTimeout(this.flyTimer);
      this.flyTimer = -1;
    }
    // 音量还在防抖窗口里：立刻落一次，别让最后一档音量丢掉
    if (this.volSaveTimer !== -1) {
      clearTimeout(this.volSaveTimer);
      this.volSaveTimer = -1;
      const st = Store.get();
      st.settings.volume = this.volume;
      st.saveSettings(st.settings).catch(() => {
      });
    }
    const p = Store.get().player();
    p.onTrackChange = null;
    p.onStateChange = null;
    p.onProgress = null;
    p.onFavChange = null;
    p.onPlayModeChange = null;
  }

  /**
   * 场景动画总驱动（60ms 一格）：
   *   · 唱片：26s/圈（参考稿 echo-spin），每格 0.83°，80ms 线性动画平滑追赶；
   *   · 唱臂：播放搭下 / 暂停抬起（值不变时写状态不触发 diff）；
   *   · 音柱：四根小柱按 1.15s 周期交替缩放（echo-bars），暂停齐落 0.35；
   *   · 星芒：沉浸光感开启且播放时透明度 5.5s 周期脉动（echo-glow）。
   */
  private startSceneTick(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
    }
    this.tickTimer = setInterval(() => {
      // 拖动进度条时让出主线程
      if (this.isSeeking) {
        return;
      }
      const now: number = Date.now();
      const dt: number = this.tickT > 0 ? Math.min((now - this.tickT) / 1000, 0.2) : 0;
      this.tickT = now;

      if (this.isPlaying) {
        this.discAngle = this.discAngle + 360 * dt / 26;
      } else {
        // 暂停后让唱片自己滑到下一个整圈：封面停正，像真转盘收尾
        const target: number = Math.ceil(this.discAngle / 360) * 360;
        const gap: number = target - this.discAngle;
        if (gap > 0.15) {
          this.discAngle = this.discAngle + Math.max(gap * 0.16, 0.25);
        } else if (gap > 0) {
          this.discAngle = target;
        }
      }
      this.armAngle = this.isPlaying ? ARM_PLAY : ARM_REST;

      if (this.isPlaying && !this.isLoading) {
        // @State 数组元素级赋值不触发 UI，整组替换
        const v: number[] = [0, 0, 0, 0];
        for (let i = 0; i < 4; i++) {
          // 每根柱独立相位，1.15s 周期在 1 ↔ 0.35 之间交替
          const ph: number = [0, 0.8, 0.4, 0.2][i];
          const w: number = (this.tickT / 1150 + ph) % 1;
          const tri: number = 1 - Math.abs(w * 2 - 1);
          v[i] = 0.35 + 0.65 * tri;
        }
        this.barsVal = v;
      } else if (this.barsVal[0] !== 0.35 || this.barsVal[1] !== 0.35
        || this.barsVal[2] !== 0.35 || this.barsVal[3] !== 0.35) {
        // 暂停时只在真的还没落回基线时写一次：每 60ms 新建一个相同内容的数组
        // 会触发一轮无意义的 diff 与重绘
        this.barsVal = [0.35, 0.35, 0.35, 0.35];
      }

      if (this.isPlaying && this.immersiveOn) {
        this.sparkGlow = 0.55 + 0.45 * Math.sin(this.tickT / 5500 * Math.PI * 2);
      } else {
        this.sparkGlow = 1;
      }
    }, 60);
  }

  private stopSceneTick(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  /**
   * 前后台切换：后台停场景动画与均衡器，回前台且页面还在时接着跑。
   * 唱片旋转、音柱跳动、星芒脉动都是纯装饰，屏幕看不见时继续以 60ms/130ms
   * 的节奏改状态、走 animateTo，只会白耗电和 CPU。
   */
  private onAppForeground(): void {
    if (!this.appFg) {
      this.stopSceneTick();
      this.stopEq();
      return;
    }
    if (this.pageAlive) {
      this.tickT = 0;
      this.startSceneTick();
      this.syncEq(Store.get().player().isPlaying);
    }
  }

  // ---------------- 歌词逻辑 ----------------

  private async loadLyrics(track: Track): Promise<void> {
    // 偏移跟着歌走：不同歌的轴偏差不一样，切歌先取回这首歌上次调好的值
    if (this.lyricsTrackId !== track.id) {
      this.lyricOffset = Store.get().lyricOffsetOf(track.id);
      this.offsetBar = false;
      this.stopOffsetBarTimer();
    }
    if (this.lyricsTrackId === track.id && this.lyrics.length > 0) {
      return;
    }
    this.lyricsTrackId = track.id;
    this.lyrics = [];
    this.lyricsSynced = false;
    this.lyricsFailed = false;
    this.curLine = -1;
    this.lyricsLoading = true;
    try {
      const res: LyricsResult = await Store.get().lyricsFor(track);
      // 加载期间可能已经切歌，丢弃过期结果
      if (this.lyricsTrackId !== track.id) {
        return;
      }
      this.lyrics = res.lines;
      this.lyricsSynced = res.synced;
    } catch (e) {
      this.lyrics = [];
      this.lyricsSynced = false;
      this.lyricsFailed = true;
    }
    this.lyricsLoading = false;
    if (this.lyricsSynced) {
      this.updateCurLine(Store.get().player().position, true);
    }
  }

  /** 重试取歌词：清掉本曲缓存标记后重走一遍请求 */
  private retryLyrics(): void {
    const cur: Track | null = Store.get().player().currentTrack;
    if (cur === null) {
      return;
    }
    this.lyricsTrackId = '';
    this.loadLyrics(cur);
  }

  /**
   * 依据播放进度定位当前歌词行（二分查找），显示在场景下方的 note 行。
   */
  private updateCurLine(pos: number, force: boolean = false): void {
    if (!this.lyricsSynced || this.lyrics.length === 0) {
      return;
    }
    // 偏移存的是「秒」（界面上按 ±0.5s 调），时间轴是毫秒，必须乘 1000。
    // 之前直接把秒加到毫秒上，+0.5 实际只挪了 0.5 毫秒，等于没调。
    // 偏移为正 = 歌词提前：拿「比实际进度更靠后」的位置去匹配时间轴
    const at: number = pos + this.lyricOffset * 1000;
    let lo: number = 0;
    let hi: number = this.lyrics.length - 1;
    // -1：歌首前奏阶段不高亮任何一行
    let idx: number = -1;
    while (lo <= hi) {
      const mid: number = (lo + hi) >> 1;
      if (this.lyrics[mid].start <= at) {
        idx = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    // 命中空文本行（间隔占位）时往上找最近一句有字的
    while (idx > 0 && this.lyrics[idx].text.trim().length === 0) {
      idx = idx - 1;
    }
    if (idx < 0 || this.lyrics[idx].text.trim().length === 0) {
      idx = -1;
    }
    if (idx >= 0) {
      if (this.curLine !== idx) {
        this.curLine = idx;
      }
    } else {
      if (this.curLine !== -1) {
        this.curLine = -1;
      }
    }
  }

  /** 彩色模糊背景上的次级文字色 */
  private onBg2(): string {
    return this.isDark ? '#D2D2DC' : '#3B3B46';
  }

  /** 直接压在模糊背景上的银蓝文字：深色主题提亮一档，浅色用参考稿原色 */
  private silverText(): string {
    // 播放页底色恒为炭黑，顶栏文字固定冷银灰，不随系统明暗切
    return '#98A5B8';
  }

  private seekToLine(line: LyricLine): void {
    if (!this.lyricsSynced || line.start <= 0) {
      return;
    }
    // 点歌词要跳到「这句真的开口」的位置：歌词轴被整体平移过，
    // 直接 seek 到 line.start 会偏 lyricOffset 那么多。
    // 同样是秒 → 毫秒，和 updateCurLine 的方向必须一致，
    // 否则调完偏移再点歌词会双倍偏移（甚至跳回同一句）
    const target: number = Math.max(0, line.start - this.lyricOffset * 1000);
    // 走统一的提交口：同样要开保护窗口，否则点完歌词滑块会先弹回原处再跳过去
    this.seekValue = target;
    this.commitSeek(target);
  }

  // ---------------- 歌词时间微调 ----------------

  private stopOffsetBarTimer(): void {
    if (this.offsetBarTimer !== -1) {
      clearTimeout(this.offsetBarTimer);
      this.offsetBarTimer = -1;
    }
  }

  /** 呼出微调条，并重置 5 秒自动收起 */
  private showOffsetBar(): void {
    if (!this.lyricsSynced) {
      // 没有时间轴的歌词没得对，别给出一个调了也没反应的面板
      return;
    }
    this.offsetBar = true;
    this.stopOffsetBarTimer();
    this.offsetBarTimer = setTimeout(() => {
      this.offsetBar = false;
      this.offsetBarTimer = -1;
    }, 5000);
  }

  /** 偏移文案：+0.5s / -1.5s / 0.0s */
  private offsetText(): string {
    const v: number = Math.round(this.lyricOffset * 10) / 10;
    if (Math.abs(v) < 0.05) {
      return '0.0s';
    }
    return (v > 0 ? '+' : '') + v.toFixed(1) + 's';
  }

  /** 调一格：0.5 秒，范围 ±5 秒（再多就不是对轴而是换了首歌） */
  private nudgeOffset(step: number): void {
    let v: number = Math.round((this.lyricOffset + step) * 10) / 10;
    if (v > 5) {
      v = 5;
    }
    if (v < -5) {
      v = -5;
    }
    this.lyricOffset = v;
    Store.get().setLyricOffset(this.lyricsTrackId, v);
    // 立刻重算当前行，调的时候能当场看见高亮跳到哪
    this.updateCurLine(Store.get().player().position, true);
    this.showOffsetBar();
  }

  private resetOffset(): void {
    if (Math.abs(this.lyricOffset) < 0.05) {
      return;
    }
    this.lyricOffset = 0;
    Store.get().setLyricOffset(this.lyricsTrackId, 0);
    this.updateCurLine(Store.get().player().position, true);
    this.showOffsetBar();
  }

  // ---------------- 播放控制 ----------------

  private async togglePlay(): Promise<void> {
    await Store.get().player().togglePlayPause();
  }

  /**
   * 左右横滑切歌（Apple Music 的经典交互）：向左滑 = 下一首，向右滑 = 上一首。
   * 阈值 70vp：太敏感会在调进度条时误切，太钝又像「没手势」。
   */
  private swipeToTrack(dx: number): void {
    if (dx <= -70) {
      Store.get().player().next();
    } else if (dx >= 70) {
      Store.get().player().prev();
    }
  }

  /**
   * 播放键当前该画哪种图标：加载 / 暂停（正在播）/ 播放。
   * 只给 ForEach 当 key 用——值一变，整块键帽连同图标一起重建，
   * 就不会出现旧图标和新图标叠在一起的情况。
   */
  private playIconKey(): string {
    if (this.isLoading) {
      return 'load';
    }
    return this.isPlaying ? 'pause' : 'play';
  }

  private async next(): Promise<void> {
    await Store.get().player().next();
  }

  private async prev(): Promise<void> {
    await Store.get().player().prev();
  }

  /** 切模式：不弹提示文字，按钮自身高亮就是反馈 */
  private choosePlayMode(m: PlayMode): void {
    Store.get().player().setPlayMode(m);
    this.playMode = m;
  }

  /**
   * 进度条拖动。Begin/Moving 只改本地值，松手（End/Click）才真正下发 seek。
   */
  private onSeek(value: number, mode: SliderChangeMode): void {
    if (mode === SliderChangeMode.Moving || mode === SliderChangeMode.Begin) {
      this.isSeeking = true;
      this.seekValue = value;
      return;
    }
    this.seekValue = value;
    this.commitSeek(value);
  }

  /** 松手后真正 seek。带保护窗口 + 去重 */
  private commitSeek(value: number): void {
    this.isSeeking = false;
    const p = Store.get().player();
    const cur: number = p.position;
    if (this.seekPending >= 0 && Math.abs(value - this.seekPending) < 400) {
      return;
    }
    if (Math.abs(value - cur) < 400) {
      this.seekPending = -1;
      this.seekValue = cur;
      this.playPos = cur;
      return;
    }
    this.seekPending = value;
    this.seekGuardUntil = Date.now() + 1500;
    this.playPos = value;
    this.updateCurLine(value, true);
    p.seek(value).then(() => {
      if (this.seekPending === value && Math.abs(p.position - value) <= 800) {
        this.seekPending = -1;
      }
    }).catch(() => {
      if (this.seekPending === value) {
        this.seekPending = -1;
        this.seekValue = p.position;
        this.playPos = p.position;
      }
    });
  }

  // ---------------- 下拉返回：跟手 ----------------

  /** 垫底色：跟列表页当前页签一致 */
  private baseBg(): string {
    const tab: string = AppStorage.get<string>('navTab') ?? 'home';
    return Theme.pageBg(this.isDark, tab);
  }

  /** 手指在动：页面跟着走。只处理向下，向上不动 */
  private applyDrag(dy: number): void {
    if (this.dragFlying) {
      return;
    }
    const h: number = Number(AppStorage.get<number>('winHeight') ?? 780);
    const d: number = Math.max(0, dy);
    this.dragY = d;
    this.dragScale = 1 - Math.min(d / h, 1) * 0.06;
  }

  /** 松手：够远 / 够快就走，否则弹回原位 */
  private endDrag(dy: number, vy: number): void {
    if (this.dragFlying) {
      return;
    }
    const h: number = Number(AppStorage.get<number>('winHeight') ?? 780);
    const d: number = Math.max(0, dy);
    if (d > h * 0.22 || (vy > 900 && d > 24)) {
      this.flyOut();
      return;
    }
    this.getUIContext().animateTo(Motion.modalSnapBack(), () => {
      this.dragY = 0;
      this.dragScale = 1;
    });
  }

  /** 松手后飞出屏幕；页面完全离屏后才退路由（防系统转场把页面拽回原位再滑一遍） */
  private flyOut(): void {
    if (this.dragFlying) {
      return;
    }
    this.dragFlying = true;
    const h: number = Number(AppStorage.get<number>('winHeight') ?? 780);
    const remain: number = Math.max(1, h - this.dragY);
    const ms: number = Math.round(Math.min(240, Math.max(120, remain / 2)));
    this.getUIContext().animateTo(Motion.modalFling(ms), () => {
      this.dragY = h;
      this.dragScale = 0.92;
    });
    this.flyTimer = setTimeout(() => {
      this.flyTimer = -1;
      try {
        Router.back('pages/SubsonicLibrary');
      } catch (e) {
        this.dragFlying = false;
        this.getUIContext().animateTo(Motion.modalSnapBack(), () => {
          this.dragY = 0;
          this.dragScale = 1;
        });
      }
    }, ms + 16);
  }

  onBackPress(): boolean {
    if (this.dragFlying) {
      return true;
    }
    return false;
  }

  // ---------------- 视图 ----------------

  /** 全应用统一字体（Tinos）：进程内只需注册一次 */
  private prepareLyricFonts(): void {
    registerAppFonts(this.getUIContext());
  }

  /**
   * 刊头：Let A Melody Hold This Moment.
   * 用 Playfair Display Italic，首字母放大 2vp、句末点染成与 vol.01 同色的紫，
   * 三段明暗（灰蓝 → 亮银 → 紫点）让长句有呼吸，不靠加粗硬撑。
   */
  @Builder
  topBar() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        Text() {
          Span('L').fontSize(14.5).fontFamily(APP_FONT_SCRIPT).fontColor('#E4EBF4')
          Span('et A Melody ').fontSize(12.5).fontFamily(APP_FONT_SCRIPT).fontColor('#AEBBCC')
          Span('Hold This Moment').fontSize(12.5).fontFamily(APP_FONT_SCRIPT).fontColor('#D6DEEA')
          Span('.').fontSize(12.5).fontFamily(APP_FONT_SCRIPT).fontColor('#ADA2BB')
        }
        .letterSpacing(0.4)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

        Text('vol. 01')
          .fontSize(9.5).fontFamily(APP_FONT)
          .fontStyle(FontStyle.Italic)
          .fontColor('#ADA2BB')
          .margin({ left: 10 })
        // 音质徽章：格式 + 位深/采样率，取不到就不显示（不留空胶囊）
        if (this.qual.length > 0) {
          Text(this.qual)
            .fontSize(6.8).fontFamily(APP_FONT)
            .letterSpacing(1.5)
            .fontColor('#B9C4D5')
            .padding({ left: 7, right: 7, top: 2.5, bottom: 2.5 })
            .border({ width: 1, color: '#4DBECBE2' })
            .borderRadius(20)
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .height(22)
      .padding({ left: 22, right: 22 })

      // 刊头规则线：两端渐隐的 1px 细线。
      // 不做成实线：实线会把刊头框成一个「标题栏」，和下面拍立得式的场景冲突；
      // 两端收到全透明，线像是从纸面里浮出来又淡回去，只负责收口。
      // 宽度跟着刊头的左右 22 内边距走，右端正好落在 vol.01 的下方。
      Row() {
        Column()
          .layoutWeight(1)
          .height(1)
          .linearGradient({
            angle: 90,
            colors: [['#00C3CEDD', 0.0], ['#99C3CEDD', 0.5], ['#00C3CEDD', 1.0]]
          })
      }
      .width('100%')
      .height(1)
      .padding({ left: 22, right: 22 })
      // Stack 的 alignContent 对所有子元素一致生效，线不能靠对齐贴底，
      // 直接定在 topBar 的最后 1vp 上（高 26 → y=25）
      .position({ x: 0, y: 25 })
    }
    .width('100%')
    .height(26)
  }

  /**
   * 曲目档案行：SIDE C ——— TRACK 03 / 12 ——— 04:17
   * 三段信息把场景与控制卡之间的空白填住，读起来像唱片内页的一行标注。
   */
  @Builder
  archiveRow() {
    Row() {
      Text(this.sideLabel())
        .fontSize(7).fontFamily(APP_FONT)
        .letterSpacing(2.0)
        .fontColor('#9DABBF')
      Column()
        .layoutWeight(1)
        .height(1)
        .backgroundColor('#33B2C0D5')
        .margin({ left: 9, right: 9 })
      Text(this.trackLabel())
        .fontSize(7).fontFamily(APP_FONT)
        .letterSpacing(2.0)
        .fontColor('#9DABBF')
      Column()
        .layoutWeight(1)
        .height(1)
        .backgroundColor('#33B2C0D5')
        .margin({ left: 9, right: 9 })
      Text(Fmt.time(this.duration))
        .fontSize(7).fontFamily(APP_FONT)
        .letterSpacing(2.0)
        .fontColor('#9DABBF')
    }
    .width('100%')
    .padding({ left: 26, right: 26 })
  }

  /**
   * 底部留白。
   *
   * 1.1.51 曾在这里放过「定时关闭 / 复制歌曲信息」胶囊行，按用户反馈撤掉：
   * 播放控件要往下坐。外层是 SpaceBetween 均分，空盒越矮控制卡越贴底、
   * 上方各段被撑得越开——高度 92 → 14，控制卡明显下沉，页面底部只留一线呼吸。
   * 定时关闭 / 复制歌曲信息回到无入口状态（实现仍在 cycleSleep / shareTrack）。
   */
  @Builder
  bottomBreath() {
    Column().width('100%').height(14)
  }

  /** 四角星芒（参考稿 .echo-spark）：装饰，不参与交互 */
  @Builder
  spark(size: number, filled: boolean, opacity: number, px: string, py: number) {
    // 四角星用两条正交细菱形拼出，比找现成图标更贴参考稿的形状
    Stack() {
      Column()
        .width(size).height(size)
        .rotate({ angle: 45 })
        .border({ width: filled ? 0 : 1.1, color: '#DCE3EF' })
        .backgroundColor(filled ? '#E0E6F1' : Color.Transparent)
        .borderRadius(2)
      Column()
        .width(size * 0.30).height(size)
        .backgroundColor(filled ? '#E0E6F1' : Color.Transparent)
        .borderRadius(size * 0.15)
      Column()
        .width(size).height(size * 0.30)
        .backgroundColor(filled ? '#E0E6F1' : Color.Transparent)
        .borderRadius(size * 0.15)
    }
    .width(size).height(size)
    .opacity(opacity * this.sparkGlow)
    .position({ x: px, y: py })
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 几何换算：所有尺寸都以 360vp 设计稿为基准，乘上实测宽度比。
   * 这样 360 和 430 的屏上，卡片与圆盘的相对大小完全一致。
   */
  private k(): number {
    const v: number = this.sceneW / 360;
    return v < 0.86 ? 0.86 : (v > 1.22 ? 1.22 : v);
  }

  // ================= 时计皮肤（clock）的几何与文案 =================

  /**
   * 环盘边长：宽按 93%（360 屏 → 335，环直径 323）。
   * 这一页只有环和字，环就该顶到两边；高度上只留 24 的余量。
   */
  private clockDialSize(): number {
    const byW: number = this.sceneW * 0.93;
    const byH: number = this.sceneAreaH - 24 * this.k();
    let v: number = Math.min(byW, byH);
    if (v < 232) {
      v = 232;
    }
    return v;
  }

  /**
   * 抓封面主色。用 64px 的小图——只为了算一个颜色，没必要下 600px 的大图。
   * 切歌快时会有多个请求在飞，这里只认最后一次发出去的那张。
   */
  private refreshAccent(track: Track): void {
    const small: string = Store.get().coverUrlFor(track, 64);
    if (small === this.accentSrc) {
      return;
    }
    this.accentSrc = small;
    const stamp: string = small;
    pickCoverColor(small).then((c: string) => {
      if (this.accentSrc === stamp) {
        this.accent = c;
      }
    });
  }

  /**
   * 当前句的句内进度 0~1。
   * 歌词只有行级时间轴，没有逐字时间——按「本行到下一行」的进度线性摊开，
   * 慢歌基本准，快歌会略微提前亮完，这是行级轴能做到的上限。
   */
  private clockProgress(): number {
    const i: number = this.curLine;
    if (i < 0 || i >= this.lyrics.length) {
      return 0;
    }
    const line: LyricLine = this.lyrics[i];
    const next: number = i + 1 < this.lyrics.length ? this.lyrics[i + 1].start : line.start + 6000;
    const at: number = this.playPos + this.lyricOffset * 1000;
    // 下限 600ms：两句挨得极近时，也不能一进这句就整行亮起来
    const span: number = Math.max(600, next - line.start);
    let p: number = (at - line.start) / span;
    if (p < 0) {
      p = 0;
    }
    if (p > 1) {
      p = 1;
    }
    return p;
  }

  /** 当前句文本；前奏（curLine = -1）时给一句占位 */
  private clockText(): string {
    if (this.curLine >= 0 && this.curLine < this.lyrics.length) {
      return this.lyrics[this.curLine].text;
    }
    return '♪';
  }

  private cardW(): number {
    return CARD_W0 * this.k();
  }

  /** 卡内可显示几行歌词：按剩余高度算，5~7 行之间 */
  private lyricRows(): number {
    const lh: number = this.lyricLH();
    // 卡片除歌词窗口以外的固定开销：padding 20 + 卡头 14 + 间距 14 + 卡脚 14
    const overhead: number = 62 * this.k();
    const avail: number = this.sceneAreaH - SCENE_PAD0 * 2 * this.k();
    let rows: number = Math.floor((avail - overhead) / lh);
    if (rows < LYRIC_ROWS_MIN) {
      rows = LYRIC_ROWS_MIN;
    }
    if (rows > LYRIC_ROWS_MAX) {
      rows = LYRIC_ROWS_MAX;
    }
    return rows;
  }

  private cardH(): number {
    return 62 * this.k() + this.lyricRows() * this.lyricLH();
  }

  private discD(): number {
    return DISC_D0 * this.k();
  }

  /** 圆盘与卡片共用一条水平中线 */
  private discY(): number {
    return SCENE_PAD0 * this.k() + (this.cardH() - this.discD()) / 2;
  }

  private sceneH(): number {
    return this.cardH() + SCENE_PAD0 * 2 * this.k();
  }

  // ================= 唱片封套皮肤（vinyl）的几何 =================

  /**
   * 封套边长：常规 230 等比；小屏上最多吃掉场景高度的 58%，
   * 否则封套一撑满，下面那几行歌词就没地方放了。
   */
  private vSlvSide(): number {
    const want: number = SLV_W0 * this.k();
    const cap: number = this.sceneAreaH * 0.58;
    return want > cap ? (cap < 150 ? 150 : cap) : want;
  }

  /** 封套区高度 = 封套 + 下缘留白（黑胶下沿与投影都在这一块里） */
  private vSlvAreaH(): number {
    return this.vSlvSide() + SLV_GAP0 * this.k();
  }

  /** 曲目表行数：场景高度减掉封套区后的剩余，4~7 行 */
  private vLyricRows(): number {
    const lh: number = this.lyricLH();
    const overhead: number = 32 * this.k();
    const avail: number = this.sceneAreaH - this.vSlvAreaH();
    let rows: number = Math.floor((avail - overhead) / lh);
    if (rows < 4) {
      rows = 4;
    }
    if (rows > LYRIC_ROWS_MAX) {
      rows = LYRIC_ROWS_MAX;
    }
    return rows;
  }

  private vTrackH(): number {
    return 32 * this.k() + this.vLyricRows() * this.lyricLH();
  }

  private vSceneH(): number {
    return this.vSlvAreaH() + this.vTrackH();
  }

  /** 黑胶直径：不超过封套的 96%，否则抽出来比封套还大，像两张碟 */
  private vDiscD(): number {
    const d: number = DISC_D0 * this.k();
    const cap: number = this.vSlvSide() * 0.96;
    return d > cap ? cap : d;
  }

  /** 黑胶左缘：右缘贴屏边 22 */
  private vDiscLeft(): number {
    return this.sceneW - DISC_RIGHT0 * this.k() - this.vDiscD();
  }

  /** 黑胶与封套垂直居中，略高 2vp：像被手抬着抽出来一点 */
  private vDiscTop(): number {
    return (this.vSlvSide() - this.vDiscD()) / 2 - 2 * this.k();
  }

  /** 曲目表歌词位移：当前句停在窗口正中 */
  private vShift(): number {
    if (!this.lyricsSynced) {
      return 0;
    }
    const lh: number = this.lyricLH();
    const idx: number = this.curLine < 0 ? 0 : this.curLine;
    return (this.vLyricRows() - 1) / 2 * lh - idx * lh;
  }

  private lyricLH(): number {
    return LYRIC_LH0 * this.k();
  }

  private lyricBodyH(): number {
    return this.lyricRows() * this.lyricLH();
  }

  /** 歌词行亮度：以当前句为中心向外渐隐，顺带柔化窗口上下边缘的硬切 */
  private lineAlpha(i: number): number {
    // 纯文本歌词（没有时间轴）不做「以当前句为中心」的渐隐：
    // 那种歌词根本不会随播放滚动，套上渐隐只会让第一行很亮、
    // 越往下越淡，看起来像整段被压暗了。统一给一档可读的亮度。
    if (!this.lyricsSynced) {
      return 0.86;
    }
    const cur: number = this.curLine < 0 ? 0 : this.curLine;
    const d: number = Math.abs(i - cur);
    if (d === 0) {
      return 1;
    }
    // 当前句有了左侧竖条作为「落点」，其余行可以再压一档：
    // 原先 0.72/0.5/0.32 在玻璃卡上读起来仍然和当前句太接近，
    // 尤其当前句正好压在深色封面背后时，两者几乎同权。
    return d === 1 ? 0.64 : (d === 2 ? 0.44 : 0.26);
  }

  /** 歌词窗口位移：当前句恒停正中，换句整窗平移 */
  private lyricShift(): number {
    // 纯文本歌词从第一行开始排，不做居中平移，
    // 否则顶部会空出 (rows-1)/2 行的白，看着像「歌词缺了开头」
    if (!this.lyricsSynced) {
      return 0;
    }
    const lh: number = this.lyricLH();
    const idx: number = this.curLine < 0 ? 0 : this.curLine;
    return (this.lyricRows() - 1) / 2 * lh - idx * lh;
  }

  /**
   * 歌词时间微调面板：长按歌词卡呼出，盖在歌词窗口上。
   * 不做成常驻控件——这块卡片本来就只有 178 宽，多两个按钮会挤掉歌词。
   */
  @Builder
  offsetPanel() {
    Column() {
      Row() {
        Text('−')
          .width(36 * this.k()).height(36 * this.k())
          .textAlign(TextAlign.Center)
          .fontSize(19 * this.k()).fontFamily(APP_FONT)
          .fontColor('#3D4A61')
          .borderRadius(18 * this.k())
          .backgroundColor('#123D4A61')
          .onClick(() => { this.nudgeOffset(-0.5); })

        Column() {
          Text(this.offsetText())
            .fontSize(14 * this.k()).fontFamily(APP_FONT)
            .fontWeight(FontWeight.Bold)
            .fontColor('#3D4A61')
          Text('歌词偏移')
            .fontSize(7 * this.k()).fontFamily(APP_FONT)
            .letterSpacing(1.1 * this.k())
            .fontColor('#8493A9')
            .margin({ top: 2 * this.k() })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => { this.resetOffset(); })

        Text('+')
          .width(36 * this.k()).height(36 * this.k())
          .textAlign(TextAlign.Center)
          .fontSize(19 * this.k()).fontFamily(APP_FONT)
          .fontColor('#3D4A61')
          .borderRadius(18 * this.k())
          .backgroundColor('#123D4A61')
          .onClick(() => { this.nudgeOffset(0.5); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('点中间归零 · 5 秒后收起')
        .fontSize(6.8 * this.k()).fontFamily(APP_FONT)
        .letterSpacing(0.6 * this.k())
        .fontColor('#8A98AD')
        .margin({ top: 8 * this.k() })
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#F7F1F3F8')
    .borderRadius(8 * this.k())
    // 吃掉空白处的点击：否则会穿透到底下那行歌词，一点就把进度跳走了
    .onClick(() => {})
  }

  /**
   * 场景区：左上歌词卡 + 右侧唱片（盘心即封面）+ 回形针 + 唱臂 + 星芒。
   * 卡片在前、唱片在后，左缘压住盘沿一小条，形成前后景深。
   */
  @Builder
  scene() {
    Stack({ alignContent: Alignment.Center }) {
      Stack({ alignContent: Alignment.TopStart }) {
        // 轨道线画在唱片底下：只在盘沿外侧露出一截细弧
        this.orbits()

        // 唱片在卡片之下：卡片的左缘压住盘沿
        this.vinylDisc()

        // 歌词卡
        this.lyricCard()

        // 回形针
        this.paperClip()

        // 唱臂
        this.toneArm()

        // 星芒：场景底部那颗空心描边的＋盘上方两颗小的，点缀轨道线
        // 原先右上角那颗实心白星（spark(19, true, '86%', 2)）正好落在唱臂支点左上方，
        // 45° 旋转的方块叠在浅背景上看着就是个菱形白块，一直被误认成唱臂配重——去掉。
        this.spark(15, false, 0.7, '47%', this.sceneH() - 44 * this.k())
        this.spark(9, false, 0.72, '55%', 20 * this.k())
        this.spark(5, false, 0.5, '84%', 33 * this.k())
      }
      .width('100%')
      .height(this.sceneH())
    }
    .width('100%')
    .height(this.sceneH())
    // 宽度变化时重算几何（只比一次，避免反复重排）
    .onAreaChange((_o: Area, n: Area) => {
      const w: number = Number(n.width);
      const h: number = Number(n.height);
      if (w > 0 && Math.abs(w - this.sceneW) > 0.5) {
        this.sceneW = w;
        this.scheduleOrbitRedraw();
      }
      if (h > 0 && Math.abs(h - this.sceneAreaH) > 0.5) {
        this.sceneAreaH = h;
        this.scheduleOrbitRedraw();
      }
    })
  }

  /** 盘心在场景坐标系里的位置（vp） */
  private discCx(): number {
    return this.sceneW - DISC_X0 - this.discD() / 2;
  }

  private discCy(): number {
    return this.discY() + this.discD() / 2;
  }

  /**
   * 唱片周围的轨道线：六道贴着盘沿外侧走行的极细弧线 + 几颗细光点。
   *
   * 用 Canvas 而不是 Path / Shape：Path.commands 的单位是 px（3x 屏上会被当成 1/3 大小），
   * 而 Canvas 2D 的坐标系就是 vp，几何换算出来的数值可以直接画。
   *
   * 每道弧按 96 段描，透明度乘一个 sin 包络——两端收进全透明，
   * 所以弧线是从卡片后面/画面右侧「淡出」的，而不是断在那里留个线头。
   */
  private drawOrbits(): void {
    if (!this.orbitReady) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.orbitCtx;
    ctx.clearRect(0, 0, this.sceneW, this.sceneH());
    const cx: number = this.discCx();
    const cy: number = this.discCy();
    const r0: number = this.discD() / 2;
    const k: number = this.k();
    ctx.lineCap = 'round';

    for (let n: number = 0; n < ORBIT_ARCS.length; n++) {
      const spec: number[] = ORBIT_ARCS[n];
      const rr: number = r0 + spec[0] * k;
      const a0: number = spec[1] * Math.PI / 180;
      const a1: number = spec[2] * Math.PI / 180;
      const amax: number = spec[3];
      const sq: number = spec[5];
      const lw: number = spec[4] * k;
      ctx.lineWidth = lw < 0.4 ? 0.4 : lw;
      const steps: number = 96;
      for (let i: number = 0; i < steps; i++) {
        const t0: number = i / steps;
        const alpha: number = amax * Math.pow(Math.sin(Math.PI * t0), 1.15);
        if (alpha < 0.006) {
          continue;
        }
        const t1: number = (i + 1) / steps;
        const g0: number = a0 + (a1 - a0) * t0;
        const g1: number = a0 + (a1 - a0) * t1;
        ctx.beginPath();
        ctx.strokeStyle = 'rgba(255,255,255,' + alpha.toFixed(3) + ')';
        ctx.moveTo(cx + rr * Math.cos(g0), cy + rr * sq * Math.sin(g0));
        ctx.lineTo(cx + rr * Math.cos(g1), cy + rr * sq * Math.sin(g1));
        ctx.stroke();
      }
    }

    for (let n: number = 0; n < ORBIT_DOTS.length; n++) {
      const spec: number[] = ORBIT_DOTS[n];
      const rr: number = r0 + spec[0] * k;
      const g: number = spec[1] * Math.PI / 180;
      ctx.beginPath();
      ctx.fillStyle = 'rgba(255,255,255,' + spec[3].toFixed(3) + ')';
      ctx.arc(cx + rr * Math.cos(g), cy + rr * spec[4] * Math.sin(g),
        spec[2] * k / 2, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  /** 尺寸变了要重画；等一帧再画，否则会画到旧高度的画布上被裁掉 */
  private scheduleOrbitRedraw(): void {
    if (this.orbitTimer >= 0) {
      clearTimeout(this.orbitTimer);
    }
    this.orbitTimer = setTimeout(() => {
      this.orbitTimer = -1;
      this.drawOrbits();
    }, 80);
  }

  @Builder
  orbits() {
    Canvas(this.orbitCtx)
      .width('100%')
      .height(this.sceneH())
      .hitTestBehavior(HitTestMode.None)
      .onReady(() => {
        this.orbitReady = true;
        this.drawOrbits();
      })
  }

  /**
   * 陶瓷盘：sweepGradient 釉面盘身 + 同心细纹 + 盘心封面。
   *
   * 1.1.36 之前是银色金属盘：9 段冷蓝灰交替、对比拉开，靠「反光跳变」撑质感。
   * 换成陶瓷后思路反过来——釉面靠的不是反差，是**低对比的暖白环带**：
   * 象牙白打底，相邻色段的明度差压到个位数，只有非常轻的环形光晕变化，
   * 远看是一整块温润的奶白，近看才见釉面的环形流光。段色全部带暖调
   * （偏黄偏米），没有一个纯灰蓝，这是陶瓷和银器最根本的色性差别。
   *
   * 盘心就是这张专辑的封面（用户要求：唱片机显示封面），随盘一起转。
   * 盘面干净无印字：整盘只有盘身、纹路与盘心封面。
   */
  @Builder
  vinylDisc() {
    Stack({ alignContent: Alignment.Center }) {
      Stack({ alignContent: Alignment.Center }) {
        // 盘身：釉面
        Column()
          .width(this.discD()).height(this.discD())
          .borderRadius(this.discD() / 2)
          .border({ width: 1, color: '#EDE7DB' })
          .sweepGradient({
            center: ['50%', '50%'],
            start: 20,
            end: 380,
            colors: [
              ['#F6F1E8', 0.0], ['#FEFCF8', 0.125], ['#EFE9DE', 0.25],
              ['#FCF9F3', 0.375], ['#EDE7DB', 0.5], ['#FFFFFB', 0.625],
              ['#F1EBE0', 0.75], ['#FBF8F2', 0.875], ['#F6F1E8', 1.0]
            ]
          })

        // 纹路：由外向内 7 道细环。
        // 釉面上音轨只留一点影子：比银盘那版更淡、更细，
        // 色也换成暖灰——冷灰环在奶白底上会发脏。
        ForEach([0.92, 0.865, 0.81, 0.755, 0.70, 0.645, 0.59], (f: number) => {
          Column()
            .width(this.discD() * f).height(this.discD() * f)
            .borderRadius(this.discD() * f / 2)
            .border({ width: 0.7, color: '#22B4A691' })
        }, (f: number) => f.toString())

        // 内环：盘纹与标签之间的一圈釉边
        Column()
          .width(this.discD() * 0.76).height(this.discD() * 0.76)
          .borderRadius(this.discD() * 0.38)
          .border({ width: 1, color: '#F9F6F0' })
          .shadow({ radius: 3, color: '#24C9BBA4', offsetX: 0, offsetY: 0 })
          .shadow({ radius: 5, color: '#2EFFFDF6', offsetX: 0, offsetY: 0 })

        // 盘心：封面
        this.discLabel()
      }
      .width(this.discD()).height(this.discD())
      .rotate({ angle: this.discAngle })
      .animation({ duration: 80, curve: Curve.Linear })
      // 不给圆盘加投影：Stack 自身没有圆角，shadow 是按容器边界框投的，
      // 出来是一块带直边的方影子，压在封面上特别显眼。盘面靠边框与盘纹立住即可。

    }
    .width(this.discD()).height(this.discD())
    .position({ x: '100%', y: this.discY() })
    .markAnchor({ x: this.discD() + DISC_X0, y: 0 })
  }

  /**
   * 盘心标签：封面圆形裁切 + 暖白釉边 + 中心轴孔；无封面时落回陶色圆钮。
   *
   * 标签直径 0.52 盘径。原先封面缩得偏小，盘心四周留出一大圈空盘面，
   * 远看像一颗扣子别在盘上；放大后盘心才是整张盘的视觉中心。
   *
   * 边 1.5vp、#FFFEFA：银盘时代那条冷白边在奶白釉面上会显出一圈青灰，
   * 换成带暖的釉白之后，边和盘身是同一色系，封面靠 4vp 投影浮起。
   * 无封面占位与轴孔同步换成暖调，避免冷银色块嵌在陶瓷盘上。
   */
  @Builder
  discLabel() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.coverUrl.length > 0) {
        Image(this.coverUrl)
          .width(this.discD() * 0.52).height(this.discD() * 0.52)
          .borderRadius(this.discD() * 0.26)
          .objectFit(ImageFit.Cover)
          .border({ width: 1.5 * this.k(), color: '#FFFEFA' })
          .shadow({ radius: 4 * this.k(), color: '#33000000', offsetX: 0, offsetY: 1 * this.k() })
      } else {
        Column()
          .width(this.discD() * 0.52).height(this.discD() * 0.52)
          .borderRadius(this.discD() * 0.26)
          .border({ width: 1.5 * this.k(), color: '#FFFEFA' })
          .shadow({ radius: 4 * this.k(), color: '#33000000', offsetX: 0, offsetY: 1 * this.k() })
          .radialGradient({
            center: ['40%', '30%'],
            radius: '85%',
            colors: [['#F3EDE2', 0.0], ['#D2C6B3', 1.0]]
          })
      }
      // 轴孔
      Column()
        .width(this.discD() * 0.052).height(this.discD() * 0.052)
        .borderRadius(this.discD() * 0.026)
        .backgroundColor('#FAF7F0')
        .border({ width: 1, color: '#A99D8B' })
        .shadow({ radius: 2, color: '#33000000', offsetX: 0, offsetY: 1 })
    }
    .width(this.discD()).height(this.discD())
  }

  /**
   * 唱臂：四个部件——① 底座（径向渐变外环 + 轴芯）② 主杆（一根整管直插唱头）
   * ③ 杆身高光 ④ 唱头（斜置壳体 + 针杆 + 针尖）。配重块已去掉，臂尾不收东西。
   *
   * 几何：支点在盘外右上方（距盘心约 1.3R），整组绕支点旋转；播放 40° 时唱头
   * 落在外圈音轨上（距盘心约 0.51R），待机 18° 抬向盘外沿。
   *
   * 杆长从 79.6 收到 68：原来那根管子几乎横跨半个盘面，播放角度下臂尾会压到
   * 歌词卡右缘，视觉上像一根斜插进来的支架。缩短后唱头仍在最外圈音轨，
   * 只是不再「够到」盘心——真唱臂本来也够不到中心。
   *
   * 全部用 Column + position（vp 单位）拼装，不用 Path——Path.commands 的单位是
   * px，真机 3x 屏上会被当成 1/3 大小并贴到容器左上角，杆和唱头就散了。
   */
  @Builder
  toneArm() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ③ 主杆：一根整管从支点直插唱头（(26,30)→(15,97)），不留任何接缝
      Column()
        .width(4.2 * this.k()).height(68 * this.k())
        .borderRadius(2.1 * this.k())
        .linearGradient({
          angle: 0,
          colors: [['#C4D0E0', 0.0], ['#93A1B6', 0.45], ['#6C7A90', 1.0]]
        })
        .position({ x: 17.9 * this.k(), y: 29.3 * this.k() })
        .rotate({ angle: 8.5 })
      // ④ 杆身高光：贴左侧的一条细亮线
      Column()
        .width(1.2 * this.k()).height(65.4 * this.k())
        .borderRadius(0.6 * this.k())
        .backgroundColor('#EFF4FB')
        .opacity(0.7)
        .position({ x: 18.3 * this.k(), y: 30.4 * this.k() })
        .rotate({ angle: 8.5 })
      // ⑤ 唱头：壳体顺着臂管向左下斜 30°（契合唱头补偿角），前端带针
      Column()
        .width(19 * this.k()).height(9.5 * this.k())
        .borderRadius(2.2 * this.k())
        .linearGradient({
          angle: 135,
          colors: [['#5E6B82', 0.0], ['#3A4455', 1.0]]
        })
        .border({ width: 0.8 * this.k(), color: '#E9EFF8' })
        .rotate({ angle: -30 })
        .shadow({ radius: 2.5 * this.k(), color: '#3D000000', offsetX: 0, offsetY: 1 * this.k() })
        .position({ x: 3 * this.k(), y: 95.7 * this.k() })
      Column()
        .width(1.3 * this.k()).height(6 * this.k())
        .borderRadius(0.65 * this.k())
        .backgroundColor('#39424F')
        .rotate({ angle: 20 })
        .position({ x: 4.9 * this.k(), y: 104 * this.k() })
      Column()
        .width(3.6 * this.k()).height(3.6 * this.k())
        .borderRadius(1.8 * this.k())
        .backgroundColor('#1F2733')
        .border({ width: 0.6 * this.k(), color: '#B9C5D6' })
        .shadow({ radius: 2 * this.k(), color: '#33000000', offsetX: 0, offsetY: 0.5 * this.k() })
        .position({ x: 3.7 * this.k(), y: 108.2 * this.k() })

      // ② 底座：径向渐变外环 + 轴芯（整个臂的转轴，压住杆顶）
      Column()
        .width(14 * this.k()).height(14 * this.k())
        .borderRadius(7 * this.k())
        .radialGradient({
          center: ['35%', '30%'],
          radius: '90%',
          colors: [['#C3CEDF', 0.0], ['#8494AB', 1.0]]
        })
        .border({ width: 1.6 * this.k(), color: '#EEF2F8' })
        .shadow({ radius: 3 * this.k(), color: '#2E000000', offsetX: 0, offsetY: 1 * this.k() })
        .position({ x: 19 * this.k(), y: 23 * this.k() })
      Column()
        .width(4.4 * this.k()).height(4.4 * this.k())
        .borderRadius(2.2 * this.k())
        .backgroundColor('#66748C')
        .border({ width: 0.8 * this.k(), color: '#D8E0EC' })
        .position({ x: 23.8 * this.k(), y: 27.8 * this.k() })
    }
    .width(ARM_BOX_W * this.k()).height(ARM_BOX_H * this.k())
    .rotate({
      angle: this.armAngle,
      centerX: ARM_PIVOT_X * this.k(),
      centerY: ARM_PIVOT_Y * this.k()
    })
    .animation({ duration: 700, curve: Curve.EaseInOut })
    .position({ x: '100%', y: this.discY() - ARM_PIVOT_Y * this.k() })
    .markAnchor({ x: 26 + ARM_PIVOT_X * this.k(), y: 0 })
    .hitTestBehavior(HitTestMode.None)
  }

  /** 回形针：两层圆角框叠出来的金属别针，别在卡片左上角 */
  @Builder
  paperClip() {
    Stack() {
      Column()
        .width(CLIP_W - 5).height(CLIP_H - 9)
        .borderRadius(7)
        .border({ width: 1.6, color: '#A3B0C4' })
        .shadow({ radius: 3, color: '#26FFFFFF', offsetX: 1, offsetY: 0 })
      Column()
        .width(CLIP_W - 10).height(CLIP_H - 16)
        .borderRadius(4)
        .border({ width: 1, color: '#F2F6FC' })
        .position({ x: 2.5, y: 4 })
    }
    .width(CLIP_W).height(CLIP_H)
    .rotate({ angle: CLIP_TILT })
    .position({ x: CARD_X0 + CLIP_DX, y: SCENE_PAD0 * this.k() + CLIP_DY })
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 歌词卡（左上角那张拍立得）：卡头 LYRICS、卡内 7 行滚动歌词、卡脚曲目序号。
   * 当前句加粗染墨、其余压淡；点任意一句跳过去。
   */
  @Builder
  lyricCard() {
    Column() {
      // 卡头
      Row() {
        Text('L Y R I C S')
          .fontSize(7.5 * this.k()).fontFamily(APP_FONT)
          .letterSpacing(1.5 * this.k())
          .fontColor('#7B8AA1')
        Row()
          .layoutWeight(1)
          .height(1)
          .backgroundColor('#33697A93')
          .margin({ left: 8 * this.k(), right: 8 * this.k() })
        Text('♪')
          .fontSize(8.5 * this.k()).fontFamily(APP_FONT)
          .fontColor('#7B8AA1')
      }
      .width('100%')
      .height(14 * this.k())
      .alignItems(VerticalAlign.Center)

      // 歌词窗口
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.lyrics.length > 0) {
          Column() {
            ForEach(this.lyrics, (l: LyricLine, i: number) => {
              Row() {
                // 当前句的左侧竖条。占位始终存在（只是透明的），
                // 换句时文字不会横向跳动——只靠颜色和加粗区分时，
                // 当前句压在半透明玻璃上几乎隐形，扫读找不到落点。
                Column()
                  .width(2 * this.k())
                  .height(15 * this.k())
                  .borderRadius(1 * this.k())
                  .backgroundColor(i === this.curLine ? '#2A6CA8' : '#00000000')

                Text(l.text.trim().length > 0 ? l.text : '· · ·')
                  .layoutWeight(1)
                  .height(this.lyricLH())
                  .margin({ left: 5 * this.k() })
                  .fontSize(11.5 * this.k()).fontFamily(APP_FONT)
                  .lineHeight(15 * this.k())
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor(i === this.curLine ? '#25323F' : '#7B8A9D')
                  .fontWeight(i === this.curLine ? FontWeight.Bold : FontWeight.Normal)
                  .opacity(this.lineAlpha(i))
                  .textAlign(TextAlign.Start)
                  .onClick(() => { this.seekToLine(l); })
              }
              .width('100%')
              .height(this.lyricLH())
              .alignItems(VerticalAlign.Center)
            }, (l: LyricLine, i: number) => i.toString() + '_' + l.start.toString())
          }
          .width('100%')
          .translate({ y: this.lyricShift() })
          // 换句时整窗平移，480ms 缓出，读感跟着走
          .animation({ duration: 480, curve: Curve.EaseOut })
        } else {
          Column() {
            Text(this.lyricsLoading ? '歌词加载中…'
              : (this.lyricsFailed ? '歌词获取失败' : '暂无歌词'))
              .fontSize(10.5 * this.k()).fontFamily(APP_FONT)
              .letterSpacing(1.2 * this.k())
              .fontColor('#8493A9')
            if (this.lyricsFailed) {
              Text('点此重试')
                .fontSize(9 * this.k()).fontFamily(APP_FONT)
                .fontColor('#65758F')
                .margin({ top: 6 * this.k() })
                .decoration({ type: TextDecorationType.Underline, color: '#65758F' })
            }
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .onClick(() => {
            if (this.lyricsFailed) {
              this.retryLyrics();
            }
          })
        }

        // 歌词时间微调：盖在歌词窗口上，不占常驻空间
        if (this.offsetBar) {
          this.offsetPanel()
        }
      }
      .width('100%')
      .height(this.lyricBodyH())
      .clip(true)
      .margin({ top: 8 * this.k(), bottom: 6 * this.k() })

      // 卡脚：曲目序号 + 同步状态
      Row() {
        Text(this.trackNo > 0 ? ('— ' + this.pad2(this.trackNo)) : '— 001')
          .fontSize(7 * this.k()).fontFamily(APP_FONT)
          .letterSpacing(1.4 * this.k())
          .fontColor('#8A98AD')
        Row().layoutWeight(1)
        Text(this.lyricsLoading ? 'S Y N C I N G'
          : (this.lyricsSynced
            // 调过轴就把偏移直接写在脚注上，否则用户不知道这首歌被平移过
            ? (Math.abs(this.lyricOffset) < 0.05 ? 'S Y N C E D' : 'S Y N C ' + this.offsetText())
            // 有词但没有时间轴：以前这里也写 NO LYRICS，
            // 卡片里明明显示着歌词，脚注却说没有，自相矛盾
            : (this.lyrics.length > 0 ? 'U N S Y N C E D' : 'N O  L Y R I C S')))
          .fontSize(7 * this.k()).fontFamily(APP_FONT)
          .letterSpacing(1.1 * this.k())
          .fontColor('#8A98AD')
      }
      .width('100%')
      .height(14 * this.k())
      .alignItems(VerticalAlign.Center)
    }
    .width(this.cardW())
    .height(this.cardH())
    .padding({
      left: 13 * this.k(), right: 13 * this.k(),
      top: 10 * this.k(), bottom: 10 * this.k()
    })
    .borderRadius(12 * this.k())
    // 强玻璃（1.1.53）：渐变只保留三成多不透明度当「色纸」，真正的质感交给
    // backgroundBlurStyle——把封面光实时模糊进来，透着背后流动的彩色
    .border({ width: 1, color: '#D8FFFFFF' })
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .linearGradient({
      angle: 45,
      colors: [['#6EF4F1F4', 0.0], ['#66F2E7EC', 0.6], ['#5CF0DCE3', 1.0]]
    })
    .shadow({ radius: 22 * this.k(), color: '#5C000000', offsetX: 4, offsetY: 12 })
    .rotate({ angle: CARD_TILT })
    .position({ x: CARD_X0, y: SCENE_PAD0 * this.k() })
    // 长按歌词卡 = 对轴。做成隐藏入口而不是常驻按钮：
    // 卡片只有 178 宽，多两个控件就得压掉一整行歌词
    .gesture(
      LongPressGesture({ repeat: false, duration: 480 })
        .onAction(() => { this.showOffsetBar(); })
    )
  }

  // ================= 唱片封套皮肤（vinyl）的渲染 =================

  /**
   * 封套版场景：上「封套 + 抽出的黑胶」，下「曲目表式歌词」。
   * 黑胶在下、封套在上：封套从左边压住唱片，只把右缘一截露出来，
   * 读起来就是「唱片正插在封套里」。全页只留封套一个倾角，
   * 黑胶保持水平匀速旋转，一动一静。
   */
  // ================= 时计皮肤（clock） =================

  /**
   * 时计场景：环盘 + 环心压字。
   * 参考稿里字是沿环走的，所以这里不再另起歌词区——
   * 环就是歌词区，多铺一行都是抢戏。
   */
  @Builder
  clockScene() {
    Stack({ alignContent: Alignment.Center }) {
      ClockDial({
        dialSize: this.clockDialSize(),
        coverUrl: this.coverUrl,
        accent: this.accent,
        text: this.clockText(),
        progress: this.clockProgress(),
        playing: this.isPlaying
      })

      // 环心只剩封面本身，歌名放到封面下沿之外、环内底部那一小块空地，
      // 不压在封面上——封面是这一屏的实物，不该被字盖住
      Text(this.title.length > 0 ? this.title : '音律')
        .fontSize(10.5).fontFamily(APP_FONT)
        .letterSpacing(1.4)
        .fontColor('rgba(255,252,254,0.72)')
        .textShadow({ radius: 8, color: 'rgba(0,0,0,0.55)', offsetX: 0, offsetY: 1 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: this.clockDialSize() * 0.40 })
        .translate({ y: this.clockDialSize() * 0.385 })
    }
    .width('100%')
    .layoutWeight(1)
    .onAreaChange((_o: Area, n: Area) => {
      const w: number = Number(n.width);
      const h: number = Number(n.height);
      if (w > 0 && Math.abs(w - this.sceneW) > 0.5) {
        this.sceneW = w;
      }
      if (h > 0 && Math.abs(h - this.sceneAreaH) > 0.5) {
        this.sceneAreaH = h;
      }
    })
  }

  @Builder
  vScene() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 黑胶在下：封套从左边盖住它
        this.vDisc()

        // 封套在上
        this.vSleeve()
      }
      .width('100%')
      .height(this.vSlvAreaH())

      // 曲目表式歌词：封套下方，占满剩余高度
      this.vTrackList()
    }
    .width('100%')
    // 不再写死高度：吃掉顶栏与控制卡之间的剩余空间。
    // 写死 vSceneH() 时，小屏（720 高）上封套会顶到控制卡里；
    // 交给 Column 分配，实测高度回填后封套与行数自动收一档
    .layoutWeight(1)
    .onAreaChange((_o: Area, n: Area) => {
      const w: number = Number(n.width);
      const h: number = Number(n.height);
      if (w > 0 && Math.abs(w - this.sceneW) > 0.5) {
        this.sceneW = w;
      }
      // 实测高度回填：封套边长与曲目表行数都按它算。
      // 只会收敛一次（拿到 396 就按 396 重排，行数不变即不再触发）
      if (h > 0 && Math.abs(h - this.sceneAreaH) > 0.5) {
        this.sceneAreaH = h;
      }
    })
  }

  /**
   * 黑胶：炭黑盘身 + 同心音轨细纹 + 盘心标签。
   *
   * 封套版露出来的那截必须是黑胶才成立——陶白盘会像一块瓷片插在纸里。
   * 质感靠「深到发亮」：径向渐变左上收光、右下入黑；
   * 音轨 9 道极淡白环，环距由外向内收紧，模拟真实唱片外密内疏的刻纹。
   * 斜向高光固定不随盘转，那是灯打在盘上的反光，不是盘面上的印字。
   */
  @Builder
  vDisc() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(this.vDiscD()).height(this.vDiscD())
        .borderRadius(this.vDiscD() / 2)
        .radialGradient({
          center: ['36%', '28%'],
          radius: '82%',
          colors: [['#3A3A42', 0.0], ['#1E1E23', 0.42], ['#111115', 0.78], ['#08080A', 1.0]]
        })
        .border({ width: 1, color: '#3DFFFFFF' })
        .shadow({ radius: 14 * this.k(), color: '#66000000', offsetX: 2 * this.k(), offsetY: 6 * this.k() })

      // 音轨：外圈密、内圈疏
      ForEach([0.955, 0.905, 0.855, 0.80, 0.745, 0.69, 0.635, 0.58, 0.525], (f: number) => {
        Column() {
          Column()
            .width(this.vDiscD() * f).height(this.vDiscD() * f)
            .borderRadius(this.vDiscD() * f / 2)
            .border({ width: 0.6, color: '#14FFFFFF' })
        }
      }, (f: number) => f.toString())

      // 盘面反光
      Column()
        .width(this.vDiscD() * 0.92).height(this.vDiscD() * 0.92)
        .borderRadius(this.vDiscD() * 0.46)
        .linearGradient({
          angle: 135,
          colors: [['#12FFFFFF', 0.0], ['#00FFFFFF', 0.40], ['#00FFFFFF', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)

      // 盘心标签：封面圆 + 米白边 + 轴孔
      Stack({ alignContent: Alignment.Center }) {
        if (this.coverUrl.length > 0) {
          Image(this.coverUrl)
            .width(this.vDiscD() * 0.34).height(this.vDiscD() * 0.34)
            .borderRadius(this.vDiscD() * 0.17)
            .objectFit(ImageFit.Cover)
            // 细铜边而不是米白宽边：封套只遮住盘心一半时，
            // 白描边会露出半圈高对比弧线，看着像一只眼睛
            .border({ width: 0.8 * this.k(), color: '#66C9A96A' })
        } else {
          Column()
            .width(this.vDiscD() * 0.34).height(this.vDiscD() * 0.34)
            .borderRadius(this.vDiscD() * 0.17)
            .border({ width: 0.8 * this.k(), color: '#66C9A96A' })
            .radialGradient({
              center: ['38%', '30%'],
              radius: '85%',
              colors: [['#8A7A62', 0.0], ['#4A4034', 1.0]]
            })
        }
        Column()
          .width(this.vDiscD() * 0.05).height(this.vDiscD() * 0.05)
          .borderRadius(this.vDiscD() * 0.025)
          .backgroundColor('#0A0A0C')
          .border({ width: 1, color: '#7AFFFFFF' })
      }
      .width(this.vDiscD()).height(this.vDiscD())
    }
    .width(this.vDiscD()).height(this.vDiscD())
    .rotate({ angle: this.discAngle })
    .animation({ duration: 80, curve: Curve.Linear })
    .position({ x: this.vDiscLeft(), y: this.vDiscTop() })
  }

  /**
   * 唱片封套：砖红纸板（有封面时换成专辑图），左缘一道黑书脊，
   * 底部细线把歌名与出版信息分开——Blue Note 那套印刷语言。
   *
   * 封面图下半部压一层渐暗，保证歌名在任何封面上都读得清；
   * 整体略斜 1.6°，像随手搁在桌上。
   */
  @Builder
  vSleeve() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.coverUrl.length > 0) {
        Image(this.coverUrl)
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width('100%').height('100%')
          .linearGradient({
            angle: 155,
            colors: [['#C4512F', 0.0], ['#B8452F', 0.55], ['#9B3625', 1.0]]
          })
      }

      // 下半部渐暗：给歌名兜底，不指望「封面上正好是深色」
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], ['#00000000', 0.34], ['#8C0B0A0C', 0.78], ['#E00B0A0C', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)

      // 左缘书脊
      Column()
        .width(11 * this.k()).height('100%')
        .backgroundColor('#131216')

      // 顶部编号
      Text('FY—074  ·  STEREO')
        .fontSize(6.2 * this.k()).fontFamily(APP_FONT)
        .letterSpacing(1.8 * this.k())
        .fontColor('#CCFDF6EE')
        .textShadow({ radius: 3, color: '#99000000', offsetX: 0, offsetY: 1 })
        .position({ x: 22 * this.k(), y: 13 * this.k() })

      // 底部：歌名 → 细线 → 歌手 / 年份
      Column() {
        Text(this.title.length > 0 ? this.title : '未知曲目')
          .fontSize(19 * this.k()).fontFamily(APP_FONT)
          .fontWeight(FontWeight.Bold)
          .letterSpacing(1.1 * this.k())
          .fontColor('#FDF6EE')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Column()
          .width('100%').height(1)
          .backgroundColor('#66FDF6EE')
          .margin({ top: 8 * this.k(), bottom: 7 * this.k() })
        Text((this.artist.length > 0 ? this.artist : '未知歌手') + '   ·   ' +
          (this.album.length > 0 ? this.album : '未知专辑'))
          .fontSize(6.4 * this.k()).fontFamily(APP_FONT)
          .letterSpacing(1.1 * this.k())
          .fontColor('#D9FDF6EE')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .width(this.vSlvSide() - 46 * this.k())
      .alignItems(HorizontalAlign.Start)
      .padding({ bottom: 15 * this.k() })
      .position({ x: 22 * this.k(), y: '100%' })
      .markAnchor({ x: 0, y: '100%' })
    }
    .width(this.vSlvSide()).height(this.vSlvSide())
    .border({ width: 1, color: '#26FFFFFF' })
    .shadow({ radius: 18 * this.k(), color: '#8C000000', offsetX: 4 * this.k(), offsetY: 12 * this.k() })
    .rotate({ angle: SLV_TILT })
    .position({ x: SLV_X0 * this.k(), y: 0 })
  }

  /**
   * 曲目表式歌词：封套下方的开放排版，没有卡片、没有玻璃底。
   *
   * 表头 SIDE A / LYRICS，行首两位序号，当前行前面一枚朱红菱形、
   * 文字提亮加粗——借用封套背面曲目表的排法，但内容是歌词。
   * 点任意一行跳转，长按呼出对轴面板（和经典版一致）。
   */
  @Builder
  vTrackList() {
    Column() {
      // 表头
      Row() {
        Text('SIDE A')
          .fontSize(7.2 * this.k()).fontFamily(APP_FONT)
          .letterSpacing(1.6 * this.k())
          .fontColor('#8FA0B4')
        Row()
          .layoutWeight(1)
          .height(1)
          .backgroundColor('#26FFFFFF')
          .margin({ left: 9 * this.k(), right: 9 * this.k() })
        Text(this.lyricsLoading ? 'S Y N C I N G'
          : (this.lyricsSynced
            ? (Math.abs(this.lyricOffset) < 0.05 ? 'L Y R I C S' : 'S Y N C ' + this.offsetText())
            : (this.lyrics.length > 0 ? 'U N S Y N C E D' : 'N O  L Y R I C S')))
          .fontSize(7.2 * this.k()).fontFamily(APP_FONT)
          .letterSpacing(1.2 * this.k())
          .fontColor('#8FA0B4')
      }
      .width('100%')
      .height(22 * this.k())
      .alignItems(VerticalAlign.Center)

      // 歌词窗口
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.lyrics.length > 0) {
          Column() {
            ForEach(this.lyrics, (l: LyricLine, i: number) => {
              Row() {
                // 当前行的菱形游标；占位始终存在，换行时文字不横跳
                Column()
                  .width(4 * this.k()).height(4 * this.k())
                  .backgroundColor(i === this.curLine ? '#D0512F' : '#00000000')
                  .rotate({ angle: 45 })
                  .margin({ right: 7 * this.k() })

                Text(this.pad2(i + 1))
                  .width(18 * this.k())
                  .fontSize(7.6 * this.k()).fontFamily(APP_FONT)
                  .letterSpacing(0.8 * this.k())
                  .fontColor(i === this.curLine ? '#C9D6E6' : '#5F708A')

                Text(l.text.trim().length > 0 ? l.text : '· · ·')
                  .layoutWeight(1)
                  .height(this.lyricLH())
                  .fontSize(11.8 * this.k()).fontFamily(APP_FONT)
                  .lineHeight(15.5 * this.k())
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor(i === this.curLine ? '#F2F6FB' : '#93A2B6')
                  .fontWeight(i === this.curLine ? FontWeight.Bold : FontWeight.Normal)
                  .opacity(this.lineAlpha(i))
                  .textAlign(TextAlign.Start)
                  .onClick(() => { this.seekToLine(l); })
              }
              .width('100%')
              .height(this.lyricLH())
              .alignItems(VerticalAlign.Center)
            }, (l: LyricLine, i: number) => 'v_' + i.toString() + '_' + l.start.toString())
          }
          .width('100%')
          .translate({ y: this.vShift() })
          .animation({ duration: 480, curve: Curve.EaseOut })
        } else {
          Column() {
            Text(this.lyricsLoading ? '歌词加载中…'
              : (this.lyricsFailed ? '歌词获取失败' : '暂无歌词'))
              .fontSize(10.5 * this.k()).fontFamily(APP_FONT)
              .letterSpacing(1.2 * this.k())
              .fontColor('#8493A9')
            if (this.lyricsFailed) {
              Text('点此重试')
                .fontSize(9 * this.k()).fontFamily(APP_FONT)
                .fontColor('#7C8CA4')
                .margin({ top: 6 * this.k() })
                .decoration({ type: TextDecorationType.Underline, color: '#7C8CA4' })
            }
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .onClick(() => {
            if (this.lyricsFailed) {
              this.retryLyrics();
            }
          })
        }

        // 对轴面板：和经典版共用同一个 builder
        if (this.offsetBar) {
          this.offsetPanel()
        }
      }
      .width('100%')
      .height(this.vLyricRows() * this.lyricLH())
      .clip(true)
    }
    .width('100%')
    .height(this.vTrackH())
    .padding({ left: 16 * this.k(), right: 16 * this.k() })
    .gesture(
      LongPressGesture({ repeat: false, duration: 480 })
        .onAction(() => { this.showOffsetBar(); })
    )
  }

  /**
   * 控制台（参考稿 .echo-deck）：银色渐变圆角卡。
   * 信息行（音柱 + 歌名 + 收藏）→ 细进度条 → 控制行 → footer。
   */
  /**
   * 音律条：盘与模式键之间那段空隙里，左右各三根细柱。
   *
   * 高度按正弦走，两组相位镜像 —— 左边涨的时候右边落，是一段对称的呼吸。
   * 只有真的在出声才动；暂停时压回 4vp 静止，不做无意义动画。
   */
  @Builder
  eqBars(left: boolean) {
    Row({ space: 1 }) {
      if (this.k() > 1.02) {
        // 宽屏 6 根
      Row()
        .width(2.4)
        .height(8 + (left ? this.eqL[0] : this.eqR[0]) * 22)
        .borderRadius(1.2)
        .backgroundColor(tone(this.accent, 0.56))
      Row()
        .width(2.4)
        .height(8 + (left ? this.eqL[1] : this.eqR[1]) * 22)
        .borderRadius(1.2)
        .backgroundColor(tone(this.accent, 0.72))
      Row()
        .width(2.4)
        .height(8 + (left ? this.eqL[2] : this.eqR[2]) * 22)
        .borderRadius(1.2)
        .backgroundColor(tone(this.accent, 0.84))
      Row()
        .width(2.4)
        .height(8 + (left ? this.eqL[3] : this.eqR[3]) * 22)
        .borderRadius(1.2)
        .backgroundColor(tone(this.accent, 0.94))
      Row()
        .width(2.4)
        .height(8 + (left ? this.eqL[4] : this.eqR[4]) * 22)
        .borderRadius(1.2)
        .backgroundColor(tone(this.accent, 0.64))
      Row()
        .width(2.4)
        .height(8 + (left ? this.eqL[5] : this.eqR[5]) * 22)
        .borderRadius(1.2)
        .backgroundColor(tone(this.accent, 0.78))
      } else {
        // 窄屏 4 根：卡内放不下 6 根，硬塞会顶到球和盘
      Row()
        .width(2.4)
        .height(8 + (left ? this.eqL[0] : this.eqR[0]) * 22)
        .borderRadius(1.2)
        .backgroundColor(tone(this.accent, 0.56))
      Row()
        .width(2.4)
        .height(8 + (left ? this.eqL[1] : this.eqR[1]) * 22)
        .borderRadius(1.2)
        .backgroundColor(tone(this.accent, 0.72))
      Row()
        .width(2.4)
        .height(8 + (left ? this.eqL[2] : this.eqR[2]) * 22)
        .borderRadius(1.2)
        .backgroundColor(tone(this.accent, 0.84))
      Row()
        .width(2.4)
        .height(8 + (left ? this.eqL[3] : this.eqR[3]) * 22)
        .borderRadius(1.2)
        .backgroundColor(tone(this.accent, 0.94))
      }
    }
    .height(32)
    .alignItems(VerticalAlign.Center)
    .hitTestBehavior(HitTestMode.None)
  }

  private syncEq(playing: boolean): void {
    if (playing) {
      this.startEq();
    } else {
      this.stopEq();
    }
  }

  private startEq(): void {
    if (this.eqTimer !== -1) {
      return;
    }
    this.eqTimer = setInterval(() => {
      this.eqTick += 1;
      const t: number = this.eqTick * 0.38;
      const l: number[] = [];
      const r: number[] = [];
      for (let i = 0; i < 6; i++) {
        l.push(0.28 + 0.72 * Math.abs(Math.sin(t + i * 0.66)));
        r.push(0.28 + 0.72 * Math.abs(Math.sin(t + 2.9 - i * 0.66)));
      }
      // 必须走 animateTo：直接赋值会一帧跳到位，看不出起伏
      this.getUIContext().animateTo({ duration: 130, curve: Curve.EaseInOut }, () => {
        this.eqL = l;
        this.eqR = r;
      });
    }, 130);
  }

  private stopEq(): void {
    if (this.eqTimer !== -1) {
      clearInterval(this.eqTimer);
      this.eqTimer = -1;
    }
    this.eqL = [0.3, 0.3, 0.3, 0.3, 0.3, 0.3];
    this.eqR = [0.3, 0.3, 0.3, 0.3, 0.3, 0.3];
  }

  /**
   * 播放控制盘：整块白玻璃。
   *
   * 盘面从深色改成白色圆盘，靠「比卡片更白 + 一层很淡的投影」从卡上立起来，
   * 盘内不再画任何分隔线——四个方向本来就没有分区，那几条 45° 线只是装饰。
   *
   * 上「+」下「−」是音量，左右是上一首/下一首，中心是播放暂停。
   * 左右各两枚模式键，四种模式一眼看全、一次点中。
   */
  @Builder
  transportDial() {
    Row() {
      Column({ space: 10 }) {
        this.modeChip('seq')
        this.modeChip('loop')
      }
      .justifyContent(FlexAlign.Center)

      // 左组音律：作为独立元素参与两端对齐，自然落在「球—盘」空隙正中
      this.eqBars(true)

      Stack({ alignContent: Alignment.Center }) {
        // 盘面：白玻璃
        Stack()
          .width(DIAL_D).height(DIAL_D)
          .borderRadius(DIAL_D / 2)
          .linearGradient({
            angle: 145,
            // 盘面不再是一块白玻璃：改成封面主色的深盘（亮度 0.08~0.20）。
            // 色相跟背景同源，看上去是背景里沉下去的一层，而不是贴上去的圆片
            colors: [
              [tone(this.accent, 0.21), 0.0],
              [tone(this.accent, 0.14), 0.52],
              [tone(this.accent, 0.09), 1.0]
            ] as Array<[ResourceColor, number]>
          })
          .border({ width: 1, color: tone(this.accent, 0.36, 0.50) })
          .shadow({ radius: 26, color: 'rgba(0,0,0,0.32)', offsetX: 0, offsetY: 8 })

        // 上：音量 +
        Stack() {
          Text('+')
            .fontSize(23).fontFamily(APP_FONT)
            .fontWeight(FontWeight.Lighter)
            .fontColor('#E9F0F9')
        }
        .width(50).height(50)
        .borderRadius(25)
        .alignContent(Alignment.Center)
        .offset({ x: 0, y: -DIAL_D * 0.365 })
        .onClick(() => { this.applyVolume(this.volume + 5); })

        // 下：音量 −
        Stack() {
          Text('−')
            .fontSize(25).fontFamily(APP_FONT)
            .fontWeight(FontWeight.Lighter)
            .fontColor('#E9F0F9')
        }
        .width(50).height(50)
        .borderRadius(25)
        .alignContent(Alignment.Center)
        .offset({ x: 0, y: DIAL_D * 0.365 })
        .onClick(() => { this.applyVolume(this.volume - 5); })

        // 左：上一首
        Stack() {
          Image($r('app.media.ic_prev'))
            .width(19).height(19)
            .fillColor('#DCE6F3')
        }
        .width(50).height(50)
        .borderRadius(25)
        .alignContent(Alignment.Center)
        .offset({ x: -DIAL_D * 0.365, y: 0 })
        .onClick(() => { this.prev(); })

        // 右：下一首
        Stack() {
          Image($r('app.media.ic_next'))
            .width(19).height(19)
            .fillColor('#DCE6F3')
        }
        .width(50).height(50)
        .borderRadius(25)
        .alignContent(Alignment.Center)
        .offset({ x: DIAL_D * 0.365, y: 0 })
        .onClick(() => { this.next(); })

        // 中心：播放 / 暂停。键帽比盘面略沉一点，像盘上的一处凹槽
        Stack() {
          // 键帽 + 图标整体按「状态」重建。
          //
          // 实机截图里出现过这样的叠影：暂停的两根竖条和播放的三角同时压在一起，
          // 变成一个诡异的「▶❚❚」。原因是这里用 if / else 换图标时，
          // 旧图标那个节点在某些情况下没有被真正移除（同一份绘制结果留在了层里）。
          // 把键帽和图标一起做成 ForEach 的子项、key 里带上状态名之后：
          // 状态一变就是「旧的整块销毁、新的整块重建」，而且新键帽是不透明底色，
          // 就算真有一块残留，也会被它整块盖掉。
          ForEach([this.playIconKey()], (k: string) => {
            Stack({ alignContent: Alignment.Center }) {
              Stack()
                .width(74).height(74)
                .borderRadius(37)
                // 键帽比盘面再沉一档：深盘上的凹槽，不是白瓷按钮
                .backgroundColor(tone(this.accent, 0.07))
                .border({ width: 1, color: tone(this.accent, 0.34, 0.55) })
                .shadow({ radius: 10, color: 'rgba(0,0,0,0.28)', offsetX: 0, offsetY: 3 })

              if (k === 'load') {
                LoadingProgress().width(26).height(26).color('#FFFFFF')
              } else if (k === 'pause') {
                Row({ space: 6 }) {
                  Row().width(4.5).height(22).borderRadius(1.5).backgroundColor('#FFFFFF')
                  Row().width(4.5).height(22).borderRadius(1.5).backgroundColor('#FFFFFF')
                }
              } else {
                Image($r('app.media.ic_play'))
                  .width(26).height(26)
                  .fillColor('#FFFFFF')
                  .margin({ left: 3 })
              }
            }
            .width(74).height(74)
          }, (k: string) => 'pbtn#' + k)
        }
        .width(74).height(74)
        .alignContent(Alignment.Center)
        // 按下即缩、抬起回弹：无论声音多久出来，「点到了」这件事先给回应。
        // 110ms 是键盘的触感时长，再慢就跟手脱节了。
        // 补间走显式 animateTo，不挂 .animation()：隐式动画会把子树的内容变化
        // 一起卷进动画上下文，这正是上面那种图标叠影的温床（迷你条同因）。
        .scale({ x: this.playPress ? 0.93 : 1, y: this.playPress ? 0.93 : 1 })
        .onTouch((e: TouchEvent) => {
          const down: boolean = e.type === TouchType.Down;
          const up: boolean = e.type === TouchType.Up || e.type === TouchType.Cancel;
          if (!down && !up) {
            return;
          }
          const target: boolean = down;
          if (target === this.playPress) {
            return;
          }
          this.getUIContext().animateTo({ duration: 110, curve: Curve.EaseOut }, () => {
            this.playPress = target;
          });
        })
        .onClick(() => { this.togglePlay(); })
      }
      .width(DIAL_D).height(DIAL_D)

      // 右组音律：同上，与左侧镜像
      this.eqBars(false)

      Column({ space: 10 }) {
        this.modeChip('one')
        this.modeChip('shuffle')
      }
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    // 两列模式键推到卡片两侧：盘居中不动，剩余空间平均分给左右两段
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
    .margin({ top: 12, bottom: 12 })
  }

  /**
   * 模式键：选中填强调色 + 图标反白，未选中是白球。
   *
   * 选中态原先只是「外置环深一档 + 图标换蓝」，在白卡上两者都太轻，
   * 四颗键看不出选了哪颗。改成整球填色后，模式是个一眼可读的状态，
   * 不再需要凑近比对环的深浅。
   *
   * 球体用 145° 三段蓝：左上偏亮、右下收深，与播放盘同一套光源方向；
   * 纯平涂的蓝球在浅色卡上会显得像一块贴纸。
   *
   * 图标不能靠 fillColor 染色：这四个 SVG 全是 stroke、没有 fill，
   * fillColor 替换的是 fill。所以白色版本是单独的 _sel 资源文件。
   */
  @Builder
  modeChip(m: PlayMode) {
    Stack() {
      // 外置环：选中时是同色柔光；未选中不再描一圈灰，融进背景
      Stack()
        .width(57).height(57)
        .borderRadius(28.5)
        .backgroundColor(this.playMode === m ? tone(this.accent, 0.55, 0.22) : 'rgba(255,255,255,0.07)')

      // 球体：选中填主色，未选中是同色深玻璃（半透明，透出背后的封面光）
      Stack() {
        Image(this.modeGlyph(m, this.playMode === m))
          .width(24).height(24)
      }
      .width(54).height(54)
      .borderRadius(27)
      .linearGradient({
        angle: 145,
        colors: this.playMode === m
          ? [
            [tone(this.accent, 0.62), 0.0],
            [tone(this.accent, 0.52), 0.55],
            [tone(this.accent, 0.44), 1.0]
          ] as Array<[ResourceColor, number]>
          : [
            // 未选中：白瓷球。深玻璃球在压暗后的背景上会直接消失，
            // 而这四颗键是"模式"的唯一入口，看不见就没法按
            ['rgba(255,255,255,0.74)', 0.0],
            ['rgba(255,255,255,0.58)', 0.55],
            ['rgba(255,255,255,0.44)', 1.0]
          ] as Array<[ResourceColor, number]>
      })
      .border({
        width: 1,
        color: this.playMode === m ? tone(this.accent, 0.80, 0.55) : 'rgba(255,255,255,0.36)'
      })
    }
    .width(57).height(57)
    .alignContent(Alignment.Center)
    .onClick(() => { this.choosePlayMode(m); })
  }

  /** 模式图标：选中态用反白版，其余用深色版；颜色写死在 SVG 里 */
  private modeGlyph(m: PlayMode, on: boolean): Resource {
    if (m === 'shuffle') {
      return on ? $r('app.media.ic_mode_shuffle_sel') : $r('app.media.ic_mode_shuffle');
    }
    if (m === 'one') {
      return on ? $r('app.media.ic_mode_one_sel') : $r('app.media.ic_mode_one');
    }
    if (m === 'seq') {
      return on ? $r('app.media.ic_mode_seq_sel') : $r('app.media.ic_mode_seq');
    }
    return on ? $r('app.media.ic_mode_loop_sel') : $r('app.media.ic_mode_loop');
  }

  @Builder
  deck() {
    Column() {
      // ---- 信息行 ----
      Row() {
        // 四根跳动音柱（echo-bars）
        Row({ space: 2 }) {
          ForEach([0, 1, 2, 3], (i: number) => {
            Column()
              .width(2)
              .height(18 * this.barsVal[i])
              .borderRadius(1)
              .backgroundColor('#C6D5E8')
              .alignSelf(ItemAlign.Center)
          }, (i: number) => i.toString())
        }
        .height(20)
        .alignItems(VerticalAlign.Center)

        Column() {
          Text(this.isLoading ? '加载中…' : this.title)
            .fontSize(13.5).fontFamily(APP_FONT)
            .letterSpacing(0.5)
            .fontColor('#F5F9FF')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.artist)
            .fontSize(9.5).fontFamily(APP_FONT)
            .letterSpacing(1.0)
            .fontColor('#CCD8E8')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })

        // 收藏（参考稿 tabs 的位置）
        Image(this.liked
          ? $r('app.media.ic_heart_f')
          : $r('app.media.ic_heart'))
          .width(20).height(20)
          .fillColor(this.liked ? '#E8606E' : '#CBD7E7')
          .margin({ left: 8 })
          .onClick(() => {
            // 没有曲目（队列被清空、刚好切歌中）时不要假装收藏成功
            const sid: string = this.likedSongId;
            if (sid.length === 0) {
              return;
            }
            const next: boolean = !this.liked;
            this.liked = next;
            toast(next ? '已收藏' : '已取消收藏');
            AppStorage.setOrCreate('starredDirty', true);
            const call: Promise<boolean> = next
              ? Store.get().starSong(sid)
              : Store.get().unstarSong(sid);
            call.then((ok: boolean) => {
              if (!ok) {
                this.liked = !next;
                toast('操作失败，请检查网络');
              }
            });
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // ---- 进度行 ----
      // 轨道 2→4、滑块 7→12：原来细得像一根装饰线，手指根本瞄不准。
      // 右侧改显示「剩余」而不是总时长——总时长在档案行已经有了。
      Row() {
        Text(Fmt.time(this.isSeeking ? this.seekValue : this.playPos))
          .fontSize(10.5).fontFamily(APP_FONT)
          .fontColor('#C9D5E5')
          .width(40)
          .textAlign(TextAlign.Start)

        Slider({
          value: this.seekValue,
          min: 0,
          max: this.duration > 0 ? this.duration : 1,
          // 1ms 连续取值：step=1000 会吸附整秒，拖动手感发滞
          step: 1,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .trackThickness(4)
          .trackBorderRadius(2)
          .blockSize({ width: 12, height: 12 })
          .blockColor('#FFFFFF')
          .blockBorderColor('rgba(255,255,255,0.60)')
          .blockBorderWidth(1.5)
          .trackColor('rgba(255,255,255,0.20)')
          .selectedColor('#F2F7FD')
          .onChange((v: number, mode: SliderChangeMode) => { this.onSeek(v, mode); })
          .onTouch((e: TouchEvent) => {
            // 按下就进入拖动态：只按住不动时 onChange 不触发，
            // 不抢先置位的话进度回调会把滑块往回拽
            if (e.type === TouchType.Down) {
              this.isSeeking = true;
            } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
              if (this.isSeeking) {
                this.commitSeek(this.seekValue);
              }
            }
          })

        Text(this.remainLabel())
          .fontSize(10.5).fontFamily(APP_FONT)
          .fontColor('#C9D5E5')
          .width(40)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .padding({ left: 1, right: 1 })
      .margin({ top: 10 })

      // ---- 控制盘（音量 / 切歌 / 播放 + 四种模式）----
      this.transportDial()

      // 分割线：把「控制区」和「铭牌区」分开，卡片下缘不再是一块空
      Column()
        .width('100%').height(1)
        .backgroundColor('rgba(255,255,255,0.16)')
        .margin({ top: 11 })

      // ---- footer ----
      // 左段放真规格（原来是恒定的 STEREO / 33⅓）、中间引语降一档，
      // 三栏都收在 7–9vp 的同一条铭牌线上：这里的信息是"标注"，不是"标题"
      Row() {
        Text(this.specBadge())
          .fontSize(7).fontFamily(APP_FONT)
          .letterSpacing(1.6)
          .fontColor('#B2C1D5')
          .maxLines(1)
        Text('some things never fade.')
          .fontSize(9).fontFamily(APP_FONT)
          .fontStyle(FontStyle.Italic)
          .fontColor('#BCC9DA')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .margin({ left: 9, right: 9 })
        Text(this.queueLen > 0
          ? this.pad2(this.trackNo) + ' — ' + this.pad2(this.queueLen)
          : '01 — 03')
          .fontSize(7).fontFamily(APP_FONT)
          .letterSpacing(1.6)
          .fontColor('#B2C1D5')
      }
      .width('100%')
      .margin({ top: 8 })
      .padding({ left: 2, right: 2 })
    }
    .width('100%')
    .padding({ left: 15, right: 15, top: 11, bottom: 9 })
    // 1.1.64：控制台不再是一块独立玻璃板。
    // 卡片一旦存在，底下压着的模糊封面就被切出一道硬边，控件像"贴在背景上"；
    // 三套皮肤统一去掉底、模糊、边线与投影，只留内容浮在背景里。
    // 没有卡片也就没有可读性兜底，所以配色改由 ck() 统一跟封面色走。
    .margin({ left: 12, right: 12 })
    // 记录控制卡位置：下拉手势 judge 据此让位给进度条
    .onAreaChange((_o: Area, n: Area) => {
      this.deckRectX = Number(n.globalPosition.x);
      this.deckRectY = Number(n.globalPosition.y);
      this.deckRectW = Number(n.width);
      this.deckRectH = Number(n.height);
    })
  }

  /**
   * 页面转场：整屏从底部推上来，返回时整屏滑下去（纵向模态）。
   */
  pageTransition() {
    PageTransitionEnter({ duration: Motion.MODAL_IN, curve: Curve.Friction })
      .translate({ y: '100%' })
    PageTransitionExit({ duration: Motion.MODAL_OUT, curve: Curve.Friction })
      .translate({ y: '100%' })
  }

  build() {
    // 外层垫底色：下拉时露出的是列表页当前页签的底色，不是黑屏
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundColor(this.baseBg())

      Stack() {
        // 背景 = 封面高斯模糊铺底。压暗用「乘法」（brightness），不用「盖色」。
        // 盖一层 70% 炭黑，本质是让每个像素朝同一个颜色插值：
        // 色团之间的明暗差只剩 30%，模糊就退化成一块纯色——这正是之前看着像纯色的原因。
        // brightness 是整体按比例变暗，明暗差按同一比例缩放，
        // 模糊的色团、光斑、色带全部原样保留，看着还是"封面糊了"。
        Stack() {
          // 三套皮肤共用同一层背景：封面高斯模糊铺底（1.1.70 起时计也走这里）
          // 底：主色深调。只在封面缺失时露出来
          Column()
            .width('100%').height('100%')
            .backgroundColor(tone(this.accent, 0.09))

          if (this.coverUrl.length > 0) {
            // 背景只能三选一，1:1 的封面铺 9:19.5 的屏，数学上没有第四种：
            //   Cover   —— 等比放大到铺满，左右各裁掉约 27%，不变形（本版）；
            //   Fill    —— 整张压进屏幕，上下拉长 2.17 倍（1.1.72，圆变竖椭圆）；
            //   Contain —— 完整显示，上下必然留出 210vp 的空白（1.1.74 试过双层
            //              补底，接缝处是一块封面中部、一块封面上缘，颜色对不上，
            //              模糊再重也能看见一条横线，比变形更难看）。
            //
            // 所以回到 Cover：形状绝对正确、画面连续、无接缝。放大感用模糊和
            // 压暗收掉——1.1.70 时 blur 45 糊成一团才显得"放大又模糊"，
            // 收到 30 之后还能认出封面结构，看的是"背景"，不是"被吹大的封面"。
            Image(this.coverUrl)
              .width('100%').height('100%')
              .objectFit(ImageFit.Cover)
              // 30：比 45 能看出封面，又比 26 更柔，压得住 Cover 的放大
              .blur(30)
              .saturate(1.35)
              // 乘法压暗：0.55 → 整体亮度 ×0.55，不是盖一层灰
              .brightness(0.55)
              .opacity(0.85)
          }
          // 调色层：只负责把色相收到设计稿的暖炭黑 #231A20。
          // 很薄（顶 10% / 中 4% / 底 28%，底部略收一点给控制台让位），
          // 不再参与"压暗"——压暗已经交给 brightness 了。
          Column()
            .width('100%').height('100%')
            .linearGradient({
              angle: 135,
              colors: [['#1A231A20', 0.0], ['#0A231A20', 0.45], ['#47231A20', 1.0]]
            })
        }
        .width('100%').height('100%')

        Column() {
          this.topBar()

          if (this.skin === 'vinyl') {
            // 唱片封套版：歌名、歌手、专辑都已印在封套上，
            // 不再单独占一行档案行，中间这段全给封套与曲目表
            this.vScene()
          } else if (this.skin === 'clock') {
            // 时计机芯版：钟盘 + 轴线 + 弧排歌词，档案行并入盘内，不再单列
            this.clockScene()
          } else {
            // 经典玻璃版：歌词卡（回形针）+ 唱片（盘心封面）+ 唱臂
            this.scene()

            // 曲目档案行：填住场景与控制卡之间那段空白
            this.archiveRow()
          }

          // 控制台
          Column() {
            this.deck()
          }
          .width('100%')

          // 底部留白：次级操作与规格胶囊已整体移除，这块空着
          this.bottomBreath()
        }
        .width('100%').height('100%')
        // 六段均分整屏：顶栏贴顶、规格行贴底，中间各段平分剩余空白。
        // 之前整组居中，上下各留一大块空——正是「播放页有点空」的来源。
        .justifyContent(FlexAlign.SpaceBetween)
        .padding({
          // 大屏多压 56（居中布局下整组重心下移约 28vp，控制台不再偏上）；
          // 窄屏空间紧，只压 20，避免整组被挤得上下都贴边
          top: topInset() + (this.k() > 1.1 ? 58 : 26),
          bottom: bottomInset() + 16
        })
        // 下拉返回挂在内容层。
        // 用默认手势（非 parallel）：子组件（进度条等）的手势优先，
        // 空白处起手才轮到整页下拉——进度条不再需要"防抢"判断。
        .gesture(
          PanGesture({ fingers: 1, direction: PanDirection.Down, distance: 4 })
            .tag('pullback')
            .onActionUpdate((e: GestureEvent) => {
              this.applyDrag(Number(e.offsetY));
            })
            .onActionEnd((e: GestureEvent) => {
              this.endDrag(Number(e.offsetY), Number(e.velocityY));
            })
            .onActionCancel(() => {
              this.endDrag(0, 0);
            })
        )
        // 横滑切歌：挂在同一层，控制台区域由下面的手势裁判统一让位
        .gesture(
          PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 20 })
            .tag('swipe-track')
            .onActionEnd((e: GestureEvent) => {
              this.swipeToTrack(Number(e.offsetX));
            })
        )
        // 控制台区域让位：从卡内起手的下拉手势直接拒绝，
        // 避免显式手势抢走 Slider 的触摸。
        .onGestureJudgeBegin((info: GestureInfo, event: BaseGestureEvent) => {
          if ((info.tag === 'pullback' || info.tag === 'swipe-track')
            && this.deckRectW > 0 && event.fingerList.length > 0) {
            const fx: number = Number(event.fingerList[0].globalX);
            const fy: number = Number(event.fingerList[0].globalY);
            if (fx > this.deckRectX - 8 && fx < this.deckRectX + this.deckRectW + 8
              && fy > this.deckRectY - 8 && fy < this.deckRectY + this.deckRectH + 8) {
              return GestureJudgeResult.REJECT;
            }
          }
          return GestureJudgeResult.CONTINUE;
        })
      }
      .width('100%').height('100%')
    }
    .width('100%').height('100%')
    // 下拉跟手的视觉：位移 + 轻缩 + 圆角随位移长出来
    .translate({ y: this.dragY })
    .scale({ x: this.dragScale, y: this.dragScale })
    .borderRadius(Math.min(this.dragY / 160, 1) * Motion.MODAL_RADIUS)
    .clip(true)
  }
}
