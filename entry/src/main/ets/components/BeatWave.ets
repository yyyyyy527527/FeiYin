import { Theme } from '../utils/Theme';

/**
 * 播放页的「音律起伏图」。
 *
 * 为什么是模拟而不是真实频谱：
 * AVPlayer 不对外暴露 PCM 或振幅数据；HarmonyOS 里唯一能读到「正在播放的音频」
 * 的路子是 AudioCapturer 的 SOURCE_TYPE_PLAYBACK_CAPTURE，那需要系统级受限权限，
 * 三方应用申请不到。所以这里用多频段正弦叠加 + 节拍脉冲生成形似真实频谱的起伏。
 *
 * 为了让它「看起来是跟着歌在动」而不是随机闪烁：
 *  - 每根柱子有独立相位，且用 1x / 1.7x / 2.9x 三层频率叠加，形成弛豫-收缩的群组感；
 *  - 叠一层约 111 BPM 的节拍脉冲（衰减曲线），每拍整排一起「顶」一下，低频段更强；
 *  - 中间高、两端收窄的梭形包络，和设备上常见的频谱样式一致；
 *  - 暂停时目标幅度归零，柱子按更慢的插值系数平滑落回基线，不会「啪」地消失。
 */

/** 柱子数量。44 根在 300vp 宽上约 5vp 一根，密度接近参考图 */
const BAR_COUNT: number = 40;
/** 刷新间隔：30fps。再高对这个尺寸没有可见收益，只会白烧电 */
const TICK_MS: number = 33;
/** 组件高度（vp）。改这里，播放页控制区高度会自动跟着变（NowPlaying 引用了它） */
export const WAVE_H: number = 60;
/** 每秒拍数，约 111 BPM——中速流行歌的常见值 */
const BEAT_RATE: number = 1.85;

@Component
export struct BeatWave {
  @StorageProp('isDark') private isDark: boolean = true;
  @StorageProp('playerPlaying') private playing: boolean = false;
  @StorageProp('playerLoading') private loading: boolean = false;

  private ctx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private timer: number = -1;
  private ready: boolean = false;
  private w: number = 320;
  private h: number = WAVE_H;
  /** 累计时间（秒），驱动所有正弦相位 */
  private t: number = 0;
  private last: number = 0;
  /** 当前高度（0~1，占可用半高的比例） */
  private cur: number[] = [];
  /** 每根柱子的随机相位，让整排不会整齐划一地摆 */
  private ph: number[] = [];
  /** 缓存渐变：尺寸/主题不变就不重建，30fps 下别每帧 new 一个 */
  private grad: CanvasGradient | null = null;
  private gradKey: string = '';

  aboutToAppear(): void {
    for (let i = 0; i < BAR_COUNT; i++) {
      this.cur.push(0.04);
      this.ph.push(Math.random() * Math.PI * 2);
    }
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private start(): void {
    if (this.timer >= 0) {
      return;
    }
    this.last = Date.now();
    this.timer = setInterval(() => { this.step(); }, TICK_MS);
  }

  private step(): void {
    const now: number = Date.now();
    let dt: number = (now - this.last) / 1000;
    this.last = now;
    // 切后台回来时 dt 可能是几十秒，钳一下，否则柱子会瞬移到目标值
    if (dt > 0.12) {
      dt = 0.12;
    }
    this.t += dt;

    // 节拍脉冲：每拍开头为 1，之后按五次方衰减，形成「咚」一下的顶起
    const bp: number = (this.t * BEAT_RATE) % 1;
    const kick: number = Math.pow(1 - bp, 4);
    // 缓冲/切歌时波形也落下，等真正出声再涨回来——否则新歌还没开始播，
    // 波形就按上一首的节奏在跳，看着和耳朵对不上
    const active: boolean = this.playing && !this.loading;

    for (let i = 0; i < BAR_COUNT; i++) {
      const u: number = BAR_COUNT > 1 ? i / (BAR_COUNT - 1) : 0.5;
      // 梭形包络：两端收窄、中间最高。
      // 1.25 次方把两侧压得太瘦，加高之后中段那一小簇柱子孤零零地立着，
      // 两侧空着大半截高度；放到 1.05 让肩膀也有肉，整条才是「一片」波形。
      const env: number = 0.16 + 0.84 * Math.pow(Math.sin(Math.PI * u), 1.05);

      let target: number = 0.10;
      if (active) {
        // 均值压到 0.46、同时把三层正弦的振幅拉大：波形才有高低层次，
        // 否则大家挤在 0.5 附近，乘完系数一起顶到上限，中段糊成一片
        let v: number = 0.46
          + 0.36 * Math.sin(this.t * 3.2 + this.ph[i])
          + 0.24 * Math.sin(this.t * 5.4 + this.ph[i] * 1.7)
          + 0.13 * Math.sin(this.t * 8.6 + this.ph[i] * 0.6);
        // 低频段（左半）吃节拍更重，右侧高频只轻轻跟着动
        v += kick * 0.36 * (1 - u * 0.55);
        // 三层正弦叠加后的分布集中在 0.5 附近，直接乘包络会显得很矮；
        // 这里把整体抬到接近满幅，才有「撑起来」的观感。
        // 系数不宜再大：过了 1.3 中段会成片顶到上限，变成一堵实心墙，反而没层次。
        v *= 1.15;
        // 真实频谱里低频能量总比高频强，左半段略抬一点，形状才像「音乐」而不是对称花纹
        v *= 1.04 - u * 0.30;
        if (v < 0.10) {
          v = 0.10;
        } else if (v > 1) {
          v = 1;
        }
        target = v * env;
      }
      // 起振快、回落慢：播放时追得紧，暂停时慢慢趴下
      const k: number = active ? 0.45 : 0.10;
      this.cur[i] += (target - this.cur[i]) * k;
    }

    this.paint();
  }

  /** '#RRGGBB' → 'rgba(r,g,b,a)'。Canvas 不认 ArkUI 的 #AARRGGBB */
  private rgba(hex: string, a: number): string {
    const r: number = parseInt(hex.substring(1, 3), 16);
    const g: number = parseInt(hex.substring(3, 5), 16);
    const b: number = parseInt(hex.substring(5, 7), 16);
    return 'rgba(' + r.toString() + ',' + g.toString() + ',' + b.toString() + ',' + a.toString() + ')';
  }

  private paint(): void {
    if (!this.ready) {
      return;
    }
    const c = this.ctx;
    const W: number = this.w;
    const H: number = this.h;
    if (W <= 0 || H <= 0) {
      return;
    }
    c.clearRect(0, 0, W, H);

    const gap: number = 2.0;
    const bw: number = Math.max(1.5, (W - gap * (BAR_COUNT - 1)) / BAR_COUNT);
    const cy: number = H / 2;
    const half: number = H / 2 - 1;

    // 上下对称的纵向渐变：中线最实、往外淡出，柱子看起来像从中间「长」出来。
    // 渐变的色标依赖高度和主题，这两样都不常变，缓存下来即可，不必每帧重建。
    const key: string = W.toString() + 'x' + H.toString() + (this.isDark ? 'd' : 'l');
    if (this.grad === null || this.gradKey !== key) {
      const g = c.createLinearGradient(0, 0, 0, H);
      const base: string = Theme.accent(this.isDark);
      // 顶端别太淡：0.42 的柱顶压在深色背景上几乎看不见，
      // 实际高度会被吃掉一大截，看着还是「矮」
      g.addColorStop(0, this.rgba(base, this.isDark ? 0.62 : 0.60));
      g.addColorStop(0.5, this.rgba(base, this.isDark ? 1 : 0.92));
      g.addColorStop(1, this.rgba(base, this.isDark ? 0.62 : 0.60));
      this.grad = g;
      this.gradKey = key;
    }
    c.fillStyle = this.grad;

    for (let i = 0; i < BAR_COUNT; i++) {
      const bh: number = Math.max(0.9, this.cur[i] * half);
      const x: number = i * (bw + gap);
      // 上下各画一段，构成镜像的梭形
      c.fillRect(x, cy - bh, bw, bh);
      c.fillRect(x, cy, bw, bh);
    }
  }

  build() {
    Column() {
      Canvas(this.ctx)
        .width('100%')
        .height('100%')
        .onReady(() => {
          this.w = this.ctx.width;
          this.h = this.ctx.height;
          this.ready = true;
          this.paint();
          this.start();
        })
        .onAreaChange((_o: Area, n: Area) => {
          const nw: number = Number(n.width);
          const nh: number = Number(n.height);
          if (nw > 0 && nh > 0 && (Math.abs(nw - this.w) > 0.5 || Math.abs(nh - this.h) > 0.5)) {
            this.w = nw;
            this.h = nh;
            this.paint();
          }
        })
    }
    .width('100%')
    .height(WAVE_H)
  }
}
