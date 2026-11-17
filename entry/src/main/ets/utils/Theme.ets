/**
 * 双主题：深色 / 浅色。
 * 颜色方法都接收 dark 参数——页面传 this.isDark，这样 ArkUI 能追踪到状态依赖，
 * 主题切换时才会重建。若在方法内部读 AppStorage，ArkUI 不会把它算作组件依赖。
 *
 * 注意：ArkUI 8 位十六进制为 #AARRGGBB（ARGB），不是 RGBA。
 */
import { promptAction } from '@kit.ArkUI';

const KEY_DARK: string = 'isDark';

function dark(): boolean {
  const v: boolean | undefined = AppStorage.get<boolean>(KEY_DARK);
  return v === undefined ? true : v;
}

export class Theme {
  // ---------------- 背景层次 ----------------
  /**
   * 页面底色：浅色模式用偏暖的米白（纸感），不用冷灰，
   * 和白色卡片之间留出一点点层次，观感更朴素。
   */
  static bg(dark: boolean): string {
    return dark ? '#0D0D0F' : '#F0EADC';  }

  /**
   * 五个主界面各自的底色（底部导航的 home / songs / playlists / starred / settings）。
   *
   * 两套都往浅里挪了一档：深色不再是近黑 #0D0D0F，浅色也比原来的米黄更亮。
   * 五个值之间只差色温、不差明度——差太多会变成五张不同 App 的截图，
   * 而不是同一个 App 的五个角落。色相偏移都控制在 ±10 以内，一眼扫过去
   * 是「这几个页面不太一样」，而不是「怎么花里胡哨的」。
   *
   * 注意：深色下背景整体提亮后，卡片色（surface / surfaceAlt）也必须跟着提，
   * 否则 #171015 这种偏亮的底色和 #1A1A1E 的卡片几乎同亮度，卡片边界会消失。
   */
  static pageBg(dark: boolean, tab: string): string {
    if (dark) {
      if (tab === 'home') {
        return '#0F1318';      // 冷蓝，最接近原来的观感
      }
      if (tab === 'songs') {
        return '#191026';      // 偏紫
      }
      if (tab === 'playlists') {
        return '#0D1B15';      // 偏青绿
      }
      if (tab === 'starred') {
        return '#1D1117';      // 偏玫，呼应品牌红
      }
      return '#1E1911';        // 设置：偏暖棕（再亮一档卡片就浮不起来了）
    }
    if (tab === 'home') {
      return '#F0F2F6';
    }
    if (tab === 'songs') {
      return '#F4EFF9';
    }
    if (tab === 'playlists') {
      return '#EDF5F0';
    }
    if (tab === 'starred') {
      return '#FAEFEF';
    }
    return '#F8F2E6';
  }

  // 深色卡片比旧版亮一档（#1A1A1E → #232330）：五个界面的底色都提亮之后，
  // 原来的卡片会和 starred 页那种偏亮的底色贴成一片，卡片边界就没了。
  static surface(dark: boolean): string {
    return dark ? '#232330' : '#FFFFFF';  }

  // 浅色下这里原来是米黄 #E6DECC。五个底色各自带一点色温之后，
  // 一块米黄的色块摆在淡绿/淡粉底上会发脏，收成中性灰米，和哪个底色都处得来。
  static surfaceAlt(dark: boolean): string {
    return dark ? '#2D2D3A' : '#E8E5DC';  }

  static elevated(dark: boolean): string {
    return dark ? '#2A2A33' : '#FFFFFF';  }

  // ---------------- 文字 ----------------
  static text(dark: boolean): string {
    return dark ? '#E8E8EC' : '#14141A';  }

  static textSecondary(dark: boolean): string {
    return dark ? '#8A8A94' : '#6B6B78';  }

  static textTertiary(dark: boolean): string {
    return dark ? '#5A5A64' : '#9A9AA6';  }

  // ---------------- 品牌色 ----------------
  static accent(dark: boolean): string {
    return dark ? '#FF6470' : '#F0455A';  }

  static accentSecondary(dark: boolean): string {
    return dark ? '#FFC864' : '#E09B2D';  }

  static accentGradient(dark: boolean): string {
    return dark ? '#FF6470' : '#F0455A';  }

  static success(dark: boolean): string {
    return dark ? '#4CAF7A' : '#2E9E68';  }

  // 半透明色：ARGB
  static divider(dark: boolean): string {
    return dark ? '#1FFFFFFF' : '#14000000';  }

  static overlay(dark: boolean): string {
    return dark ? '#99000000' : '#66000000';  }

  static accentSoft(dark: boolean): string {
    return dark ? '#20FF6470' : '#1AF0455A';  }

  static accentChip(dark: boolean): string {
    return dark ? '#33FF6470' : '#26F0455A';  }

  static accentBorder(dark: boolean): string {
    return dark ? '#66FF6470' : '#59F0455A';  }
}

/** 切换明暗模式，返回切换后的状态 */
export function toggleDark(): boolean {
  const next: boolean = !dark();
  AppStorage.setOrCreate(KEY_DARK, next);
  return next;
}

/** 初始化主题（从持久化设置恢复） */
export function initTheme(isDarkMode: boolean): void {
  AppStorage.setOrCreate(KEY_DARK, isDarkMode);
}

export class Fmt {
  static time(ms: number): string {
    if (ms <= 0 || isNaN(ms)) {
      return '0:00';
    }
    const totalSec: number = Math.floor(ms / 1000);
    const min: number = Math.floor(totalSec / 60);
    const sec: number = totalSec % 60;
    return min + ':' + (sec < 10 ? '0' + sec : '' + sec);
  }

  /** 时长中文文案：45 秒 / 38 分钟 / 2 小时 5 分，用于歌单总时长等摘要场景 */
  static durationCn(ms: number): string {
    if (ms <= 0 || isNaN(ms)) {
      return '0 分钟';
    }
    const totalSec: number = Math.floor(ms / 1000);
    if (totalSec < 60) {
      return totalSec.toString() + ' 秒';
    }
    const totalMin: number = Math.floor(totalSec / 60);
    if (totalMin < 60) {
      return totalMin.toString() + ' 分钟';
    }
    const h: number = Math.floor(totalMin / 60);
    const m: number = totalMin % 60;
    return m === 0 ? h.toString() + ' 小时'
      : h.toString() + ' 小时 ' + m.toString() + ' 分';
  }

  /**
   * 字节数转可读大小。
   * 单位按「四舍五入后是否满 1024」进位，而不是按原始值判断——
   * 否则 1048575 字节会显示成「1024.0 KB」这种不合理的写法。
   */
  static size(bytes: number): string {
    if (bytes < 1024) {
      return bytes + ' B';
    }
    const units: string[] = ['KB', 'MB', 'GB', 'TB'];
    let v: number = bytes / 1024;
    let i: number = 0;
    while (v >= 1024 && i < units.length - 1) {
      v = v / 1024;
      i++;
    }
    // 进位后可能仍然 >= 1024（如 1023.99 → 1024.0），再进一级
    if (Number(v.toFixed(1)) >= 1024 && i < units.length - 1) {
      v = v / 1024;
      i++;
    }
    return v.toFixed(1) + ' ' + units[i];
  }

  static truncate(s: string, max: number): string {
    if (s.length <= max) {
      return s;
    }
    return s.substring(0, max - 1) + '…';
  }

  static ext(path: string): string {
    const idx: number = path.lastIndexOf('.');
    if (idx < 0) {
      return '';
    }
    return path.substring(idx + 1).toLowerCase();
  }

  static basename(path: string): string {
    const clean: string = path.replace(/\/+$/, '');
    const idx: number = clean.lastIndexOf('/');
    return idx < 0 ? clean : clean.substring(idx + 1);
  }

  static stripExt(name: string): string {
    const idx: number = name.lastIndexOf('.');
    return idx > 0 ? name.substring(0, idx) : name;
  }

  static isAudio(path: string): boolean {
    const ext: string = Fmt.ext(path);
    const audioExts: string[] = ['mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'wma', 'opus'];
    return audioExts.indexOf(ext) >= 0;
  }

  static isImage(path: string): boolean {
    const ext: string = Fmt.ext(path);
    const imgExts: string[] = ['jpg', 'jpeg', 'png', 'webp', 'bmp'];
    return imgExts.indexOf(ext) >= 0;
  }
}

export function topInset(): number {
  const v: number = AppStorage.get<number>('topInset') ?? 44;
  return v;
}

export function bottomInset(): number {
  const v: number = AppStorage.get<number>('bottomInset') ?? 0;
  return v;
}

/** 窗口高度（vp）。取不到时按常见 6.5 寸屏兜底 */
export function winHeight(): number {
  return AppStorage.get<number>('winHeight') ?? 780;
}

/** 窗口宽度（vp）。取不到时按常见 6.5 寸屏兜底 */
export function winWidth(): number {
  return AppStorage.get<number>('winWidth') ?? 360;
}

/**
 * 底部弹层里可滚动列表的最大高度：
 * 按窗口高度的比例算，给弹层自己的标题/按钮和安全区留出余量，
 * 这样不同尺寸的机器都不会把最后一项切一半。
 */
export function sheetListMax(ratio: number): number {
  const h: number = winHeight();
  const cap: number = h * ratio - topInset() * 0.2 - bottomInset() - 200;
  return cap > 200 ? Math.round(cap) : 200;
}

/**
 * 轻提示。
 *
 * 之前的实现只是往 AppStorage 里写 toastText / toastTime，
 * 而全项目没有任何组件去读这两个值 —— 也就是说 60 多处 toast() 调用
 * 一直是「写了没人看」，界面上什么都不显示。
 * 这也是「点了没反应」反复出现的根源之一：操作其实成功了，只是没提示。
 *
 * 现在直接调系统的 promptAction.showToast。它自己管生命周期、
 * 会自动避让软键盘，不用在本项目里再维护一个浮层。
 *
 * 用 try/catch 包住：Toast 依赖窗口上下文，在 Ability 还没完全
 * attach 时调用可能抛错，但提示失败不能影响业务流程。
 */
export function toast(msg: string): void {
  // 保留 AppStorage 写入：万一以后要做应用内自定义样式浮层，这里还有入口
  AppStorage.setOrCreate('toastText', msg);
  AppStorage.setOrCreate('toastTime', Date.now());
  try {
    promptAction.showToast({
      message: msg,
      // 1500ms 是系统允许的下限，默认值也是它；稍长一点让中文看得完
      duration: 2000,
      // 抬高一点，避开底部导航条和迷你播放器
      bottom: 96
    });
  } catch (e) {
    console.warn('[toast] showToast failed: ' + (e instanceof Error ? e.message : String(e)));
  }
}
