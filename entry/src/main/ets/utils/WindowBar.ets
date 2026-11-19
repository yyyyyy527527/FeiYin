import window from '@ohos.window';

/** 主窗口引用（模块级，Window 对象无法放入 AppStorage） */
let mainWindow: window.Window | null = null;

export function setMainWindow(win: window.Window): void {
  mainWindow = win;
}

/** 沉浸式全屏 + 系统栏透明，图标颜色跟随明暗主题 */
export function applySystemBar(win: window.Window, isDark: boolean): void {
  const content: string = isDark ? '#FFFFFF' : '#000000';
  win.setWindowSystemBarProperties({
    statusBarColor: '#00000000',
    statusBarContentColor: content,
    navigationBarColor: '#00000000',
    navigationBarContentColor: content
  }).catch(() => {});
}

/** 切换主题后刷新系统栏颜色（状态栏图标黑/白随之切换） */
export function refreshSystemBar(isDark: boolean): void {
  if (mainWindow !== null) {
    applySystemBar(mainWindow, isDark);
  }
}

// ---------------------------------------------------------------------------
// 屏幕常亮（2.0.0）
//
// 只在「播放页可见 且 正在出声」时保持常亮，任一条件不成立立刻交还系统：
//   · 暂停了 → 用户可能把手机放桌上走人，还亮着屏就是纯耗电；
//   · 退到后台 → 后台播放本身就靠长时任务保活，不需要屏幕；
//   · 离开播放页 → 列表页停留不会被系统息屏打断。
// 两个条件分别由页面（holdScreenOn）和 Ability 生命周期（setAppForeground）写入，
// 合成后统一调用一次 setWindowKeepScreenOn，避免两边各自调用产生竞态。
// ---------------------------------------------------------------------------

/** 应用是否在前台。Ability 生命周期维护，同时广播到 AppStorage 供组件停动画 */
let appForeground: boolean = true;
/** 播放页是否要求常亮（页面可见 && 正在播放） */
let pageHoldsScreen: boolean = false;

function applyKeepScreenOn(): void {
  if (mainWindow === null) {
    return;
  }
  mainWindow.setWindowKeepScreenOn(appForeground && pageHoldsScreen).catch(() => {});
}

/** 播放页态变化时调用：正在播放为 true，暂停/离开页面为 false */
export function holdScreenOn(on: boolean): void {
  pageHoldsScreen = on;
  applyKeepScreenOn();
}

/**
 * Ability 前后台切换。同时写 AppStorage，页面/组件订阅 'appForeground'
 * 后可以把自绘动画的定时器停掉——后台没人看，30~60fps 的空转只是白烧电。
 */
export function setAppForeground(fg: boolean): void {
  appForeground = fg;
  AppStorage.setOrCreate<boolean>('appForeground', fg);
  applyKeepScreenOn();
}

export function isAppForeground(): boolean {
  return appForeground;
}
