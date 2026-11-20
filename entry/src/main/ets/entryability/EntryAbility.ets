import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import window from '@ohos.window';
import { Store } from '../store/Store';
import { applySystemBar, setAppForeground, setMainWindow } from '../utils/WindowBar';
import { startGripWatch } from '../utils/Grip';
import { FormSync } from '../utils/FormSync';
import { Router } from '../utils/Router';

export default class EntryAbility extends UIAbility {
  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    await Store.get().init(this.context);
    // 卡片数据接力：主进程这边登记上下文，之后播放状态变化时由 FormSync 推给桌面卡片
    FormSync.init(this.context);
    // 恢复上次的队列与播放位置（只恢复，不自动出声）。
    // 放在 onCreate 而不是页面里：多个页面都会用到播放器状态，
    // 挂在页面上会出现「谁先加载谁决定队列」的竞态。
    try {
      await Store.get().player().restoreQueue();
    } catch (e) {
      console.warn('[ability] 恢复播放队列失败：' + (e instanceof Error ? e.message : String(e)));
    }
    // 冷启动时被卡片拉起（call/router）：先把命令记下来，
    // 等页面加载完再执行——页面没就绪时 router 会静默失败
    this.pendingCardAction = readCardAction(want);
    // 桌面长按图标快捷方式（随机播放/播放喜爱/每日推荐）：
    // 冷启动页面还没起来，先把动作存进 AppStorage，页面 aboutToAppear 时取走执行
    this.pendingShortcut = readShortcutName(want);
    // 智感握姿：监听握持手，收起态的迷你播放栏/导航栏据此换边（设备不支持时静默降级）
    startGripWatch();
  }

  /**
   * 桌面卡片控制键（call 动作）在应用已在后台/前台运行时走到这里。
   * 播放命令直接驱动 PlayerCore，不拉起界面；openNowPlaying 再进 router。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const action: string = readCardAction(want);
    if (action.length > 0) {
      this.handleCardAction(action);
      return;
    }
    // 快捷方式热启动：页面在监听，直接广播
    const sc: string = readShortcutName(want);
    if (sc.length > 0) {
      this.context.eventHub.emit('shortcut_action', sc);
    }
  }

  /** 页面加载完成后执行卡片带来的动作（冷启动路径） */
  private pendingCardAction: string = '';
  /** 冷启动时桌面快捷方式带来的动作（页面就绪后广播给页面执行） */
  private pendingShortcut: string = '';

  private runPendingCardAction(): void {
    if (this.pendingCardAction.length > 0) {
      const action: string = this.pendingCardAction;
      this.pendingCardAction = '';
      this.handleCardAction(action);
    }
  }

  /**
   * 卡片命令分发：
   *  togglePlay / next / prev 是后台控制，不弹界面；
   *  openNowPlaying 打开播放页。
   */
  private handleCardAction(action: string): void {
    const player = Store.get().player();
    try {
      if (action === 'togglePlay') {
        player.togglePlayPause();
      } else if (action === 'next') {
        player.next();
      } else if (action === 'prev') {
        player.prev();
      } else if (action === 'openNowPlaying') {
        this.context.eventHub.emit('card_open_nowplaying');
      }
    } catch (e) {
      console.error('[ability] 卡片命令执行失败：' + (e instanceof Error ? e.message : String(e)));
    }
  }

  /** 窗口就绪：装系统栏、避让区、窗口尺寸监听，然后决定首页 */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    const win = windowStage.getMainWindowSync();
    setMainWindow(win);


    // 沉浸式全屏：内容延伸到状态栏与导航栏下方
    win.setWindowLayoutFullScreen(true).catch(() => {});

    // 读取避让区（全屏后页面用 topInset/bottomInset 做安全区留白）
    const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    AppStorage.setOrCreate('topInset', px2vp(area.topRect.height));
    AppStorage.setOrCreate('bottomInset', px2vp(area.bottomRect.height));
    // 窗口尺寸（vp）：底部弹层的最大高度、播放页翻页的位移上限都按它算，不写死像素
    const rect = win.getWindowProperties().windowRect;
    AppStorage.setOrCreate('winHeight', px2vp(rect.height));
    AppStorage.setOrCreate('winWidth', px2vp(rect.width));

    win.on('windowSizeChange', (size) => {
      const a = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      AppStorage.setOrCreate('topInset', px2vp(a.topRect.height));
      AppStorage.setOrCreate('bottomInset', px2vp(a.bottomRect.height));
      AppStorage.setOrCreate('winHeight', px2vp(size.height));
      AppStorage.setOrCreate('winWidth', px2vp(size.width));
    });

    // 等配置/主题读取完成再决定首页与系统栏配色，避免读到默认值
    Store.get().ready().then(() => {
      applySystemBar(win, AppStorage.get<boolean>('isDark') ?? true);
      const store: Store = Store.get();
      const initialPage: string = store.isConfigured ? 'pages/SubsonicLibrary' : 'pages/Setup';
      windowStage.loadContent(initialPage, (err) => {
        if (err) {
          console.error('[ability] 加载页面失败：' + JSON.stringify(err));
        }
        // 已登录的账号：启动即静默拉一次云端，换机后开机就能看到自己的统计
        store.autoSync();
        // 卡片「点整卡打开播放页」：页面就绪后才能 router
        this.context.eventHub.on('card_open_nowplaying', () => {
          Router.push('pages/NowPlaying');
        });
        // 冷启动时桌面快捷方式带来的动作：页面已就绪（监听已注册），广播出去
        const sc0: string = this.pendingShortcut;
        if (sc0.length > 0) {
          this.pendingShortcut = '';
          this.context.eventHub.emit('shortcut_action', sc0);
        }
        // 冷启动时卡片带来的动作（播放控制）现在页面已就绪，可以执行了
        this.runPendingCardAction();
      });
    });
  }

  onForeground(): void {
    // 回到前台：恢复常亮判定（播放页可能还开着），让后台暂停的动画可以继续
    setAppForeground(true);
    // 切回前台：把后台攒下的听歌统计补推一次，同时拉取其他设备的更新
    Store.get().autoSync();
  }

  onBackground(): void {
    // 后台保活：由 backgroundModes: audioPlayback + 播放时申请的长时任务保证，
    // 系统媒体卡片（AVSession）在后台/锁屏下仍可控制播放。
    // 这里同时交还「屏幕常亮」并通知页面停掉自绘动画的定时器（见 WindowBar）。
    setAppForeground(false);
  }

  onDestroy(): void {
    // 退出应用：释放播放器、媒体会话并结束长时任务，避免通知栏残留
    Store.get().player().release();
  }
}

/** 从卡片 postCardAction 的 want 里取 method 参数；没有就返回空串 */
function readCardAction(want: Want): string {
  if (want === null || want.parameters === undefined || want.parameters === null) {
    return '';
  }
  const m: Object | undefined = want.parameters['method'];
  return typeof m === 'string' ? m as string : '';
}

/** 从桌面快捷方式的 want 里取 shortcut 参数；没有就返回空串 */
function readShortcutName(want: Want): string {
  if (want === null || want.parameters === undefined || want.parameters === null) {
    return '';
  }
  const m: Object | undefined = want.parameters['shortcut'];
  return typeof m === 'string' ? m as string : '';
}
