/**
 * 封面色提取。
 *
 * 时计皮肤的环不能写死颜色——同一页里封面是会换的，环必须跟着换。
 * 做法：抓一张很小的封面（48px，几 KB），缩到 20×20 读像素，
 * 按色相分 12 桶统计（用饱和度加权，灰和黑白天然低权重被压掉），
 * 取最重的那桶求平均，再把它拉到"能发光"的区间。
 *
 * 不取平均色：一张人像封面平均下来永远是灰褐色，
 * 环就成了泥浆色。要的是"最有个性的那一片颜色"。
 */

import http from '@ohos.net.http';
import image from '@ohos.multimedia.image';

/** 取不到封面时的兜底色：Folia 时计的那个品红 */
export const DEFAULT_ACCENT: string = '#F26BB2';

/**
 * 封面给页面的一组"底子"：主色 + 平均亮度。
 *
 * 主色决定色相；亮度决定这一页到底该按深底还是浅底排字。
 * 只有主色是不够的——白底人像封面照样能抽出深蓝色当主色，
 * 结果就是深蓝字铺在浅灰背景上，整页糊成一片。
 */
export interface CoverTone {
  accent: string;
  /** 封面平均亮度 0~1（感知亮度，只统计非纯黑非纯白的像素） */
  luma: number;
}

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : (v > hi ? hi : v);
}

function hex2rgb(hex: string): number[] {
  let h: string = hex;
  if (h.length === 7) {
    h = h.substring(1);
  }
  const r: number = parseInt(h.substring(0, 2), 16);
  const g: number = parseInt(h.substring(2, 4), 16);
  const b: number = parseInt(h.substring(4, 6), 16);
  return [r, g, b];
}

function rgb2hsl(r: number, g: number, b: number): number[] {
  const rr: number = r / 255;
  const gg: number = g / 255;
  const bb: number = b / 255;
  const max: number = Math.max(rr, Math.max(gg, bb));
  const min: number = Math.min(rr, Math.min(gg, bb));
  const l: number = (max + min) / 2;
  const d: number = max - min;
  let h: number = 0;
  let s: number = 0;
  if (d > 0.0001) {
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    if (max === rr) {
      h = (gg - bb) / d + (gg < bb ? 6 : 0);
    } else if (max === gg) {
      h = (bb - rr) / d + 2;
    } else {
      h = (rr - gg) / d + 4;
    }
    h *= 60;
  }
  return [h, s, l];
}

function hsl2rgb(h: number, s: number, l: number): number[] {
  if (s <= 0.0001) {
    const v: number = Math.round(l * 255);
    return [v, v, v];
  }
  const q: number = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p: number = 2 * l - q;
  const hk: number = h / 360;
  const conv = (t: number): number => {
    let tt: number = t;
    if (tt < 0) {
      tt += 1;
    }
    if (tt > 1) {
      tt -= 1;
    }
    if (tt < 1 / 6) {
      return p + (q - p) * 6 * tt;
    }
    if (tt < 1 / 2) {
      return q;
    }
    if (tt < 2 / 3) {
      return p + (q - p) * (2 / 3 - tt) * 6;
    }
    return p;
  };
  return [
    Math.round(conv(hk + 1 / 3) * 255),
    Math.round(conv(hk) * 255),
    Math.round(conv(hk - 1 / 3) * 255)
  ];
}

/**
 * 同一色相换一个亮度/透明度，输出 CSS 颜色串。
 * 环、字、刻度、辉光全部由这一支函数派生，色相永远和封面一致。
 */
export function tone(hex: string, l: number, a: number = 1): string {
  const c: number[] = hex2rgb(hex);
  const hsl: number[] = rgb2hsl(c[0], c[1], c[2]);
  const rgb: number[] = hsl2rgb(hsl[0], hsl[1], clamp(l, 0, 1));
  if (a >= 0.999) {
    return `#${rgb[0].toString(16).padStart(2, '0')}${rgb[1].toString(16).padStart(2, '0')}${rgb[2].toString(16).padStart(2, '0')}`;
  }
  return `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${a.toFixed(3)})`;
}

/** 把主色拉到能当"发光体"的区间：太暗提亮，太灰增饱和 */
function tune(hex: string): string {
  const c: number[] = hex2rgb(hex);
  const hsl: number[] = rgb2hsl(c[0], c[1], c[2]);
  const h: number = hsl[0];
  // 黑白封面：不硬加饱和，否则 s=0 时色相会退化成红色，银白封面出来一圈砖红
  // 黄绿青这一段人眼最敏感，同样亮度下比红紫"亮"一档，
  // 饱和度和亮度都要再收一点，否则出来就是荧光管
  const green: boolean = hsl[0] >= 60 && hsl[0] <= 180;
  const sHi: number = green ? 0.70 : 0.84;
  const lHi: number = green ? 0.60 : 0.64;
  const s: number = hsl[1] < 0.06 ? 0.09 : clamp(hsl[1] * 1.10 + 0.14, 0.40, sHi);
  const l: number = clamp(hsl[2], 0.50, lHi);
  const rgb: number[] = hsl2rgb(h, s, l);
  return `#${rgb[0].toString(16).padStart(2, '0')}${rgb[1].toString(16).padStart(2, '0')}${rgb[2].toString(16).padStart(2, '0')}`;
}

/**
 * 从封面抓主色。
 * 失败、无封面、纯灰封面都退回 DEFAULT_ACCENT——宁可回到设计稿的品红，
 * 也不要让环变成一条无彩色的灰线。
 */
export async function pickCoverTone(url: string): Promise<CoverTone> {
  const fallback: CoverTone = { accent: DEFAULT_ACCENT, luma: 0.18 };
  if (url.length === 0) {
    return fallback;
  }
  try {
    const req: http.HttpRequest = http.createHttp();
    const resp: http.HttpResponse = await req.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 6000,
      readTimeout: 6000
    });
    req.destroy();
    if (resp.responseCode !== 200 || resp.result === undefined) {
      return fallback;
    }
    const raw: ArrayBuffer = resp.result as ArrayBuffer;
    const src: image.ImageSource = image.createImageSource(raw);
    if (src === undefined) {
      return fallback;
    }
    const opts: image.DecodingOptions = {
      desiredSize: { width: 20, height: 20 },
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888
    };
    const pm: image.PixelMap = await src.createPixelMap(opts);
    // 解码完立刻放掉 ImageSource：它内部还攥着刚下载的原始封面缓冲
    src.release();
    const info: image.ImageInfo = await pm.getImageInfo();
    const w: number = info.size.width;
    const h: number = info.size.height;
    const buf: ArrayBuffer = new ArrayBuffer(w * h * 4);
    await pm.readPixelsToBuffer(buf);
    // 读出像素就放掉 PixelMap，别等 GC
    pm.release();
    const px: Uint8Array = new Uint8Array(buf);
    const bgra: boolean = info.pixelFormat === image.PixelMapFormat.BGRA_8888;

    // 12 个色相桶：权重 = 饱和度 × 中间亮度加成。黑白灰的 s 接近 0，自然被压掉
    let ar: number = 0;
    let ag: number = 0;
    let ab: number = 0;
    let an: number = 0;
    const bins: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    const sr: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    const sg: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    const sb: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

    for (let i: number = 0; i < w * h; i++) {
      const o: number = i * 4;
      const r: number = bgra ? px[o + 2] : px[o];
      const g: number = px[o + 1];
      const b: number = bgra ? px[o] : px[o + 2];
      const a: number = px[o + 3];
      if (a < 40) {
        continue;
      }
      const hsl: number[] = rgb2hsl(r, g, b);
      const s: number = hsl[1];
      const l: number = hsl[2];
      if (l > 0.08 && l < 0.94) {
        ar += r;
        ag += g;
        ab += b;
        an += 1;
      }
      // 纯黑、纯白、灰：不参与投票
      if (s < 0.14 || l < 0.08 || l > 0.94) {
        continue;
      }
      const mid: number = 1 - Math.abs(l - 0.5) * 1.1;
      const wgt: number = s * (mid < 0.15 ? 0.15 : mid);
      const bin: number = Math.floor(hsl[0] / 30) % 12;
      bins[bin] += wgt;
      sr[bin] += r * wgt;
      sg[bin] += g * wgt;
      sb[bin] += b * wgt;
    }

    let best: number = -1;
    let bestW: number = 0;
    for (let i: number = 0; i < 12; i++) {
      if (bins[i] > bestW) {
        bestW = bins[i];
        best = i;
      }
    }
    if (best < 0 || bestW <= 0.0001) {
      // 整张封面没有像样的彩色（黑白照、纯字标）：
      // 用它的平均亮度做一条银白环，也比硬塞一条品红强
      if (an > 0) {
        const nr: number = Math.round(ar / an);
        const ng: number = Math.round(ag / an);
        const nb: number = Math.round(ab / an);
        const gray: string = `#${nr.toString(16).padStart(2, '0')}${ng.toString(16).padStart(2, '0')}${nb.toString(16).padStart(2, '0')}`;
        return { accent: tune(gray), luma: 0.5 };
      }
      return fallback;
    }
    const mr: number = Math.round(sr[best] / bestW);
    const mg: number = Math.round(sg[best] / bestW);
    const mb: number = Math.round(sb[best] / bestW);
    const hex: string = `#${mr.toString(16).padStart(2, '0')}${mg.toString(16).padStart(2, '0')}${mb.toString(16).padStart(2, '0')}`;
    // 平均亮度同样只统计中间调像素：整块黑边或纯白留白不该左右判断
    const luma: number = an > 0
      ? clamp((0.2126 * ar + 0.7152 * ag + 0.0722 * ab) / an / 255, 0, 1)
      : 0.18;
    return { accent: tune(hex), luma: luma };
  } catch (e) {
    return fallback;
  }
}


/** 只要主色的旧入口：内部走 pickCoverTone，行为不变 */
export async function pickCoverColor(url: string): Promise<string> {
  const t: CoverTone = await pickCoverTone(url);
  return t.accent;
}

/**
 * 把任意一个颜色"染"到主色的色相上，亮度与透明度原样保留。
 *
 * 时计皮肤下，播放页原本那套冷灰蓝（#93A7C2 / #6E7F96 / #8FA9C9…）在酒红底上会发脏。
 * 与其把十几处调色逐个改成手写常量，不如在 ck() 里统一过一道：
 * 深浅层次不变，色相换成封面主色，整块 UI 自动跟环同色。
 */
export function recolor(src: string, accent: string): string {
  let a: number = 1;
  let hex: string = src;
  // 8 位是 #AARRGGBB（ArkUI 的写法），6 位是 #RRGGBB
  if (src.length === 9) {
    a = parseInt(src.substring(1, 3), 16) / 255;
    hex = `#${src.substring(3)}`;
  } else if (src.length === 7) {
    hex = src;
  } else {
    return src;
  }
  const c: number[] = hex2rgb(hex);
  const sc: number[] = rgb2hsl(c[0], c[1], c[2]);
  const ac: number[] = hex2rgb(accent);
  const ah: number[] = rgb2hsl(ac[0], ac[1], ac[2]);
  // 亮度沿用源色（层次不乱），饱和度取源色的六成与主色四成半的较大者，
  // 让灰字带上色相，又不会被染成荧光
  const s2: number = Math.max(sc[1] * 0.62, ah[1] * 0.45);
  const rgb: number[] = hsl2rgb(ah[0], clamp(s2, 0, 0.9), sc[2]);
  if (a >= 0.999) {
    return `#${rgb[0].toString(16).padStart(2, '0')}${rgb[1].toString(16).padStart(2, '0')}${rgb[2].toString(16).padStart(2, '0')}`;
  }
  return `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${a.toFixed(3)})`;
}
