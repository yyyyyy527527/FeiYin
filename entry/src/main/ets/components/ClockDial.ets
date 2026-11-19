/**
 * 时计（Clock）皮肤的环盘。
 *
 * 结构：一枚占满屏宽的发光环，环心是**清晰的封面**（不再模糊），
 * 当前句的单字沿环内侧排开，一段白色拖尾弧跟着句内进度在环上走。
 *
 * 颜色不写死：环、字、刻度、辉光全部由 accent 派生，而 accent 是封面主色
 * （见 utils/CoverColor）。粉色只是某张封面的结果，不是这个皮肤的设计色。
 */

import { tone, DEFAULT_ACCENT } from '../utils/CoverColor';

@Component
export struct ClockDial {
  /** 画布边长（vp）。环半径 = 边长/2 - 6，留一点给环外刻度与辉光 */
  @Prop dialSize: number = 352;
  @Prop coverUrl: string = '';
  /** 封面主色：环的主色相 */
  @Prop accent: string = DEFAULT_ACCENT;
  /** 当前句文本：逐字沿环排开 */
  @Prop text: string = '';
  /** 句内进度 0~1：白色拖尾弧的位置，也决定亮到第几个字 */
  @Prop progress: number = 0;
  @Prop playing: boolean = false;
  /** 前后台：40ms 一帧的 Canvas 重绘，后台必须停 */
  @StorageProp('appForeground') @Watch('onAppForeground') private appFg: boolean = true;

  private ctx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;
  private timer: number = -1;
  /** 摆动的呼吸相位：环的辉光轻微起伏，静止画面也有生命 */
  private phase: number = 0;
  private lastMs: number = 0;
  /** 平滑后的进度：直接跟 @Prop 会在换句瞬间跳变，这里做每帧追 11 倍的缓动 */
  private smooth: number = 0;

  aboutToAppear(): void {
    this.smooth = this.progress;
    this.lastMs = Date.now();
    this.timer = setInterval(() => {
      this.advance();
      this.draw();
    }, 40);
  }

  private onAppForeground(): void {
    if (!this.appFg) {
      if (this.timer !== -1) {
        clearInterval(this.timer);
        this.timer = -1;
      }
      return;
    }
    if (this.timer === -1) {
      // 后台待了很久，dt 会很大：重置基准时间，避免回前台第一帧进度突跳
      this.lastMs = Date.now();
      this.timer = setInterval(() => {
        this.advance();
        this.draw();
      }, 40);
    }
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private advance(): void {
    const now: number = Date.now();
    const dt: number = Math.min(0.12, (now - this.lastMs) / 1000);
    this.lastMs = now;
    // 换句时进度会从 1 跳回 0，缓动会把白弧"倒着拉回去"。
    // 差值过大时直接归位，只有正常推进才做平滑。
    if (this.progress - this.smooth > 0.5 || this.smooth - this.progress > 0.5) {
      this.smooth = this.progress;
    } else {
      this.smooth += (this.progress - this.smooth) * Math.min(1, dt * 11);
    }
    if (this.playing) {
      this.phase += dt * 1.6;
    }
  }

  /**
   * 把一句歌词切成"环上单元"：中文一个字一块，英文/数字一个词一块。
   *
   * 逐字符排是有硬伤的：一句英文四十个字母挤在 180° 弧上，每个字母只分到
   * 四度，字号压到下限仍然互相压着，最后糊成一圈看不清的碎点（1.1.66 的英文歌词）。
   * 按词分块之后，"waiting" 是一块而不是七块，环上只剩十来块，
   * 每块再按自身宽度分弧长，英文长句才排得开。
   */
  private units(): string[] {
    const out: string[] = [];
    let buf: string = '';
    for (let i: number = 0; i < this.text.length; i++) {
      const c: string = this.text.charAt(i);
      if (c === ' ' || c === '　') {
        if (buf.length > 0) {
          out.push(buf);
          buf = '';
        }
        continue;
      }
      if (c.charCodeAt(0) < 128) {
        // 半角连排：单词、数字、I've 这类缩写都是一个整体
        buf += c;
      } else {
        if (buf.length > 0) {
          out.push(buf);
          buf = '';
        }
        out.push(c);
      }
    }
    if (buf.length > 0) {
      out.push(buf);
    }
    return out;
  }

  /** 单元的相对宽度：中文算一个字，半角按 0.56 个字 */
  private unitW(s: string): number {
    let w: number = 0;
    for (let i: number = 0; i < s.length; i++) {
      w += s.charCodeAt(i) < 128 ? 0.56 : 1;
    }
    return w;
  }

  private draw(): void {
    if (!this.ready) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.ctx;
    const D: number = this.dialSize;
    const cx: number = D / 2;
    const cy: number = D / 2;
    const R: number = D / 2 - 6;

    // 这一帧要用到的几档颜色，全部来自封面主色的色相
    const ac: string = this.accent;
    const ring: string = tone(ac, 0.64);
    const ringHot: string = tone(ac, 0.82);
    const glow: string = tone(ac, 0.58, 0.92);
    const textOn: string = 'rgba(255,252,254,0.97)';
    const textOff: string = 'rgba(255,255,255,0.66)';
    const tick: string = tone(ac, 0.66, 0.26);
    const tickLong: string = tone(ac, 0.70, 0.38);

    ctx.clearRect(0, 0, D, D);

    // ---- 环外 12 格刻度：短、暗，只负责把"这是钟"说清楚 ----
    for (let i: number = 0; i < 12; i++) {
      const a: number = i * Math.PI * 2 / 12 - Math.PI / 2;
      const long: boolean = i % 3 === 0;
      const len: number = long ? 9 : 5;
      ctx.strokeStyle = long ? tickLong : tick;
      ctx.lineWidth = long ? 1.4 : 1;
      ctx.beginPath();
      ctx.moveTo(cx + (R + 4) * Math.cos(a), cy + (R + 4) * Math.sin(a));
      ctx.lineTo(cx + (R + 4 + len) * Math.cos(a), cy + (R + 4 + len) * Math.sin(a));
      ctx.stroke();
    }

    // ---- 内环：一圈细线，把"封面区"和"歌词带"分开 ----
    // 半径压在封面边缘外一点点，作用是给封面一圈台阶，不是装饰
    ctx.strokeStyle = tone(ac, 0.62, 0.20);
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(cx, cy, R * 0.72, 0, Math.PI * 2);
    ctx.stroke();

    // ---- 主环：三遍。宽晕 → 辉光 → 亮芯 ----
    const breath: number = 0.85 + Math.sin(this.phase) * 0.15;
    ctx.strokeStyle = tone(ac, 0.60, 0.085);
    ctx.lineWidth = 5;
    ctx.beginPath();
    ctx.arc(cx, cy, R, 0, Math.PI * 2);
    ctx.stroke();

    ctx.save();
    ctx.shadowColor = glow;
    ctx.shadowBlur = 13 * breath;
    ctx.strokeStyle = ring;
    ctx.lineWidth = 2.1;
    ctx.beginPath();
    ctx.arc(cx, cy, R, 0, Math.PI * 2);
    ctx.stroke();
    ctx.restore();

    ctx.strokeStyle = ringHot;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(cx, cy, R, 0, Math.PI * 2);
    ctx.stroke();

    // ---- 字：按"词块"沿环排开，句首到句尾 ----
    const us: string[] = this.units();
    const n: number = us.length;
    // 字带中心：夹在封面边缘（0.60 直径）与环内缘之间
    const textR: number = R * 0.882;
    // 字号跟着环径走：大屏更大，小屏不至于把字甩出环外
    const BASE_PX: number = Math.min(23.5, Math.max(17, D * 0.0685));
    // 180° 是上限：再往外绕，两端的字就要翻过去倒着看了
    const MAX_SPAN: number = 180;
    let fontPx: number = BASE_PX;
    let gapPx: number = 0;
    let spanDeg: number = 0;

    if (n > 0) {
      const ws: number[] = [];
      const gk: number[] = [];
      let totalW: number = 0;
      let totalChars: number = 0;
      let gapSum: number = 0;
      for (let i: number = 0; i < n; i++) {
        const w: number = this.unitW(us[i]);
        ws.push(w);
        totalW += w;
        totalChars += us[i].length;
        if (i < n - 1) {
          // 词间空隙：中文之间 0.30 字宽就够，英文词必须留 0.55——
          // 六七个字母的单词挨在一起，"this moment" 会被读成 "thismoment"
          const half: boolean = us[i].charCodeAt(0) < 128 || us[i + 1].charCodeAt(0) < 128;
          const k: number = half ? 0.55 : 0.30;
          gk.push(k);
          gapSum += k;
        } else {
          gk.push(0);
        }
      }
      const avail: number = MAX_SPAN * Math.PI / 180 * textR;
      const need: number = (totalW + gapSum) * fontPx;
      let mul: number = 1;
      if (need > avail) {
        // 间距压到最小仍放不下：先等比降字号，最低 15vp——
        // 再小就不是"放大"而是退回 1.1.62 了
        const k: number = avail / need;
        fontPx = Math.max(15, fontPx * k);
        mul = 1;
      } else {
        // 放得下：把多余的弧长按比例分给各处间隙，最多放到基准的 2.4 倍
        // （中文 0.30 → 0.72 字宽、英文 0.55 → 1.32 字宽，再散就断句了）
        const free: number = avail - totalW * fontPx;
        const base: number = gapSum * fontPx;
        mul = base > 0 ? Math.min(2.4, free / base) : 1;
      }
      spanDeg = (totalW + gapSum * mul) * fontPx / textR * 180 / Math.PI;
      gapPx = 0; // 每块的实际间隙在落位时按 gk[i] * mul 算

      const startDeg: number = -90 - spanDeg / 2;
      const lit: number = Math.floor(this.smooth * totalChars);
      let accPx: number = 0;
      let charAcc: number = 0;

      ctx.font = `600 ${fontPx.toFixed(1)}px HarmonyOS Sans`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      for (let i: number = 0; i < n; i++) {
        const wPx: number = ws[i] * fontPx;
        const gap: number = gk[i] * mul * fontPx;
        const midPx: number = accPx + wPx / 2;
        const a: number = (startDeg + (midPx / textR) * 180 / Math.PI) * Math.PI / 180;
        const x: number = cx + textR * Math.cos(a);
        const y: number = cy + textR * Math.sin(a);
        // 已唱判定按字符数走：一个词的起始字符落在已唱区间内就算唱到了
        const on: boolean = charAcc < lit;
        charAcc += us[i].length;
        accPx += wPx + gap;

        // 每个块跟着所在位置的切线转向：环顶是正的，往两边依次侧过去，
        // 这样一串字才是一条围着环走的带子，不是一堆横字散在圆周上
        ctx.save();
        ctx.translate(x, y);
        ctx.rotate(a + Math.PI / 2);
        if (on) {
          ctx.shadowColor = tone(ac, 0.68, 0.90);
          ctx.shadowBlur = 12;
          ctx.fillStyle = textOn;
        } else {
          // 未唱字：白 0.66 再压一圈深色柔边。
          // 只提白没用——封面一亮，环内侧那块底也跟着亮，纯白字会化进去
          ctx.shadowColor = 'rgba(0,0,0,0.38)';
          ctx.shadowBlur = 5;
          ctx.fillStyle = textOff;
        }
        ctx.fillText(us[i], 0, 0);
        ctx.restore();
      }
    }

    // ---- 白色拖尾弧：句内进度 ----
    // 只有一小截亮弧在环上跑，像秒针的余晖；一句唱完正好回到 12 点
    {
      const curDeg: number = -90 + this.smooth * 360;
      const from: number = (curDeg - 12) * Math.PI / 180;
      const to: number = curDeg * Math.PI / 180;
      ctx.save();
      ctx.shadowColor = 'rgba(255,255,255,0.95)';
      ctx.shadowBlur = 12;
      ctx.strokeStyle = '#FFFFFF';
      ctx.lineWidth = 3;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.arc(cx, cy, R, from, to);
      ctx.stroke();
      ctx.restore();

      // 弧头那颗亮点：让"针尖"的位置一眼可辨
      ctx.save();
      ctx.shadowColor = 'rgba(255,255,255,1)';
      ctx.shadowBlur = 14;
      ctx.fillStyle = '#FFFFFF';
      ctx.beginPath();
      ctx.arc(cx + R * Math.cos(to), cy + R * Math.sin(to), 2.2, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }
  }

  build() {
    Stack() {
      // 环心：封面本身，清晰、不做模糊。
      // 外面一圈同色描边把它从背景里托起来，再垫一层很淡的投影
      if (this.coverUrl.length > 0) {
        Image(this.coverUrl)
          .width(this.dialSize * 0.60)
          .height(this.dialSize * 0.60)
          .borderRadius(this.dialSize * 0.30)
          .objectFit(ImageFit.Cover)
          .saturate(1.04)
          .brightness(0.96)
          .border({ width: 1, color: tone(this.accent, 0.62, 0.34) })
          .shadow({ radius: 22, color: 'rgba(0,0,0,0.55)', offsetX: 0, offsetY: 6 })
      }
      Canvas(this.ctx)
        .width(this.dialSize)
        .height(this.dialSize)
        .onReady(() => {
          this.ready = true;
          this.draw();
        })
    }
    .width(this.dialSize)
    .height(this.dialSize)
    .alignContent(Alignment.Center)
  }
}
