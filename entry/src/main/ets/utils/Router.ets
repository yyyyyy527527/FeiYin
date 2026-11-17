import router from '@ohos.router';

const MAIN_PAGE: string = 'pages/SubsonicLibrary';

export class Router {
  static push(url: string): void {
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
