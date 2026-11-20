import router from '@ohos.router';

const MAIN_PAGE: string = 'pages/SubsonicLibrary';

export class Router {
  /**
   * 防重复压栈：迷你条/卡片/横滑这类入口都很快，连点两下会把同一个页面
   * 压两次，返回手势就得划两下才出得去。目标页已在栈顶时直接忽略。
   */
  static push(url: string): void {
    try {
      const st = router.getState();
      if (st !== undefined && st !== null && typeof st.path === 'string'
        && st.path.length > 0 && st.path.endsWith(url)) {
        return;
      }
    } catch (_) {
      // 状态读不到就按原逻辑压栈，不能因为防护把导航卡死
    }
    router.pushUrl({ url: url }).catch(() => {});
  }

  static replace(url: string): void {
    router.replaceUrl({ url: url }).catch(() => {});
  }

  /**
   * 返回上一页。
   * 路由栈里只有当前页时（例如从卡片直接唤起），退回指定主页面而不是退出应用。
   */
  static back(fallbackUrl?: string): void {
    const len: number = Number(router.getLength());
    if (len > 1) {
      router.back();
      return;
    }
    const target: string = fallbackUrl === undefined ? MAIN_PAGE : fallbackUrl;
    router.replaceUrl({ url: target }).catch(() => {});
  }

  static pushWithParam(url: string, param: Record<string, Object>): void {
    router.pushUrl({ url: url, params: param }).catch(() => {});
  }
}
