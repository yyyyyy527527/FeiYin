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
