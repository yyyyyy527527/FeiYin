import { AppSettings, TrackStat, CacheUsage, PlayerSkin } from '../model/Models';
import { APP_FONT, APP_FONT_BOLD } from '../utils/Fonts';
import { Store } from '../store/Store';
import { Router } from '../utils/Router';
import { Theme, Fmt, toast } from '../utils/Theme';
import { refreshSystemBar } from '../utils/WindowBar';

/** 单曲排行只展示前十名，避免设置页被长列表撑开 */
const TRACK_TOP_N: number = 10;

/** 柱状图的一根柱子 */
interface ListenDay {
  key: string;
  label: string;
  minutes: number;
  barHeight: number;
}

/** 同步服务地址默认值：沿用 Navidrome 的主机，端口换成本服务的 8787 */
function deriveSyncUrl(serverUrl: string): string {
  const m: RegExpMatchArray | null = serverUrl.match(/^(https?:\/\/)?([^/:]+)(:\d+)?/);
  if (m === null) {
    return '';
  }
  const scheme: string = m[1] === undefined ? 'http://' : m[1];
  const host: string = m[2];
  return scheme + host + ':8787';
}

/**
 * 单行设置项：左侧图标 + 标题 + 副标题，右侧开关。
 *
 * 做成独立组件而不是 @Builder：@Builder 的参数是值传递，
 * 同步/恢复把开关值改了以后界面不会跟着变（设置页之前就踩过这个坑）。
 * @Prop 才会建立依赖，值变了 Toggle 立刻重绘。
 */
@Component
struct SettingSwitchRow {
  @Prop icon: Resource;
  @Prop title: string;
  @Prop desc: string;
  @Prop on: boolean;
  @Prop isDark: boolean;
  rowKey: string = '';
  onToggle: (key: string, v: boolean) => void = () => {};

  build() {
    Row() {
      Column() {
        Row() {
          Image(this.icon).width(20).height(20).opacity(0.85)
          Text(this.title)
            .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
            .margin({ left: 10 })
        }
        Text(this.desc)
          .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
          .margin({ top: 4, left: 30 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.on })
        .selectedColor(Theme.accent(this.isDark))
        .onChange((v: boolean) => { this.onToggle(this.rowKey, v); })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Theme.surface(this.isDark))
    .borderRadius(14)
  }
}

/**
 * 点击型设置行：右侧不是开关，而是一段说明文字 + 一个动作按钮。
 * 用于「清空缓存」这类执行型操作，与 SettingSwitchRow 的开关语义区分开。
 */
@Component
struct SettingActionRow {
  @Prop icon: Resource;
  @Prop title: string;
  @Prop desc: string;
  /** 右侧灰色状态文字，通常是占用空间 / 已缓存数量 */
  @Prop value: string;
  /** 动作按钮文字 */
  @Prop action: string;
  @Prop isDark: boolean;
  /** 动作进行中：按钮置灰并显示进行中文案，避免连点 */
  @Prop busy: boolean = false;
  /** 无内容可清时置灰按钮 */
  @Prop disabled: boolean = false;
  onAction: () => void = () => {};

  build() {
    Row() {
      Column() {
        Row() {
          Image(this.icon).width(20).height(20).opacity(0.85)
          Text(this.title)
            .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
            .margin({ left: 10 })
        }
        // 描述一行截断：这一行的重点是「有缓存占多少」，描述写太长会把右侧按钮挤走
        Text(this.desc)
          .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
          .margin({ top: 4, left: 30 })
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        // 占用信息放在描述下面，用强调色，比塞在按钮左边更清楚
        if (this.value.length > 0) {
          Text(this.value)
            .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
            .margin({ top: 4, left: 30 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 按钮固定宽度不参与拉伸，避免被左侧长文字挤压
      Text(this.busy ? '清理中…' : this.action)
        .fontSize(12.5).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
        .fontColor(this.disabled || this.busy ? Theme.textTertiary(this.isDark) : Theme.accent(this.isDark))
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .borderRadius(12)
        .border({
          width: 1,
          color: this.disabled || this.busy ? Theme.divider(this.isDark) : Theme.accentBorder(this.isDark)
        })
        .flexShrink(0)
        .margin({ left: 12 })
        .onClick(() => {
          if (this.disabled || this.busy) {
            return;
          }
          this.onAction();
        })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Theme.surface(this.isDark))
    .borderRadius(14)
  }
}

/**
 * 设置内容面板。不带页面标题栏，可嵌在底部导航的「设置」标签里，
 * 也可以被 pages/Settings 单独包一层顶栏使用。
 */
@Component
export struct SettingsPanel {
  @StorageProp('isDark') private isDark: boolean = true;
  /**
   * 统计版本：Store 每记一次播放 / 落盘 / 云合并都会递增。
   * 面板可能一直挂在页面里（边听边待在设置页，或 push 进统计页再返回），
   * 只靠 aboutToAppear 读一次会让「播放排行」「近 7 天时长」停在旧数据上。
   */
  @StorageProp('statsVer') @Watch('onStatsChanged') private statsVer: number = 0;
  /** 滚动区底部留白（嵌在标签页里要给导航条与迷你播放器让位） */
  @Prop bottomPad: number = 30;
  /** 滚动区顶部留白（嵌在标签页里给悬浮标题条让位，内容从条下穿过） */
  @Prop topPad: number = 0;
  /**
   * 可选的页面标题：由调用方传入后会成为滚动内容的第一项，
   * 跟内容一起滚出屏幕——不再固定压在内容上方形成一条遮挡带。
   * 注意：@BuilderParam 不能声明为 private——private 成员无法从组件构造函数
   * 初始化，调用方传进来的尾随闭包会被静默丢弃（编译期只有一条 WARN），
   * 表现就是设置页的滚动首项标题永远不渲染。
   */
  @BuilderParam header: () => void = this.emptyHeader;
  @State private autoCache: boolean = true;
  @State private radio: boolean = true;
  @State private scrobble: boolean = true;
  @State private onlineLyric: boolean = true;
  @State private volume: number = 80;
  /** 播放页外观：classic 经典玻璃版 / vinyl 唱片封套版 */
  @State private skin: PlayerSkin = 'classic';
  @State private serverUrl: string = '';
  /** 近 7 天听歌时长（柱状图数据） */
  @State private listenDays: ListenDay[] = [];
  @State private listenTotal: string = '0 分钟';
  @State private listenWeek: string = '0 分钟';
  /** 单曲排行（按播放次数降序） */
  @State private trackStats: TrackStat[] = [];
  @State private trackTotal: number = 0;
  @State private trackMaxPlays: number = 1;
  /** 账号与同步 */
  @State private loggedIn: boolean = false;
  @State private accountLabel: string = '';
  @State private lastSyncText: string = '尚未同步';
  @State private syncUrlInput: string = '';
  @State private syncing: boolean = false;
  @State private syncMsg: string = '';
  /** 已登录时展示的恢复码（换机用，按 4 位分组显示） */
  @State private recoveryCode: string = '';
  /** 登录方式：huawei / code，仅用于文案 */
  @State private loginVia: string = 'huawei';
  /** 未登录时是否展开「用恢复码登录」输入区 */
  @State private showRecovery: boolean = false;
  @State private recoveryInput: string = '';
  /** 是否真正连上了同步服务（没连上时「立即同步」不出现） */
  @State private syncReady: boolean = false;
  /** 缓存占用文字（如「128.4 MB · 62 个文件」），空串表示无缓存 */
  @State private cacheSizeText: string = '';
  @State private cacheBusy: boolean = false;

  aboutToAppear(): void {
    const s = Store.get().settings;
    this.autoCache = s.autoCache;
    this.radio = s.radio !== false;
    this.scrobble = s.scrobble !== false;
    this.onlineLyric = s.onlineLyric !== false;
    this.volume = s.volume;
    this.skin = Store.get().playerSkin;
    const cfg = Store.get().serverConfig;
    this.serverUrl = cfg !== null ? cfg.url : '未配置';
    this.refreshListenStats();
    this.refreshTrackStats();
    this.refreshCacheUsage();
    this.initAccount();
  }

  /**
   * 统计版本变化：就地刷新排行与听歌时长。
   * 播放页在下面播、面板还在前台时，排行会跟着跳；从统计页返回也一样。
   */
  private onStatsChanged(): void {
    this.refreshListenStats();
    this.refreshTrackStats();
  }

  // ---------------- 账号与云同步 ----------------

  private initAccount(): void {
    const store: Store = Store.get();
    this.loggedIn = store.isLoggedIn;
    this.syncUrlInput = store.syncUrl;
    if (this.syncUrlInput.length === 0) {
      // 同步服务通常和 Navidrome 部署在同一台机器上，按服务器主机名派生一个默认地址
      const cfg = store.serverConfig;
      if (cfg !== null) {
        this.syncUrlInput = deriveSyncUrl(cfg.url);
      }
    }
    const acc = store.account;
    this.accountLabel = acc !== null && acc.userId.length > 0 ? acc.userId : '';
    this.recoveryCode = acc !== null ? acc.recoveryCode : '';
    this.loginVia = acc !== null && acc.via === 'code' ? 'code' : 'huawei';
    this.lastSyncText = this.fmtSyncTime(acc !== null ? acc.lastSyncAt : 0);
    this.syncReady = store.canSync;
    if (acc !== null && !this.syncReady) {
      // 纯本机账号不该显示「尚未同步」，它压根没连过云端
      this.lastSyncText = '仅本机账号';
    }
    // 已登录「且」连过同步服务，才静默同步一次；纯本机账号不去打扰服务器
    if (this.loggedIn && this.syncReady) {
      this.doSync(true);
    }
  }

  private fmtSyncTime(ts: number): string {
    if (ts <= 0) {
      return '尚未同步';
    }
    const diff: number = Date.now() - ts;
    if (diff < 60000) {
      return '刚刚同步';
    }
    if (diff < 3600000) {
      return Math.floor(diff / 60000) + ' 分钟前同步';
    }
    if (diff < 86400000) {
      return Math.floor(diff / 3600000) + ' 小时前同步';
    }
    return Math.floor(diff / 86400000) + ' 天前同步';
  }

  /** 华为账号一键登录：只做认证，不依赖同步服务 */
  private async doLogin(): Promise<void> {
    if (this.syncing) {
      return;
    }
    const ctx = Store.get().abilityContext;
    if (ctx === null) {
      toast('应用还没准备好，稍后再试');
      return;
    }
    this.syncing = true;
    this.syncMsg = '';
    try {
      // 延迟加载：Account Kit 只在华为设备上存在，静态引入会让启动链一起崩
      const authMod = await import('../auth/HuaweiAuth');
      const auth = await authMod.HuaweiAuth.signIn(ctx);
      if (!auth.ok) {
        this.syncMsg = auth.msg;
        // 华为账号走不通时，恢复码是唯一的出路，直接把入口摊开
        this.showRecovery = true;
        return;
      }
      // 只记身份，不连服务器：登录秒完成，后面要不要同步由「立即同步」决定
      const r = await Store.get().loginHuaweiLocal(auth.idToken, auth.openid, '');
      if (!r.ok || r.account === null) {
        this.syncMsg = r.msg.length > 0 ? r.msg : '登录失败，请重试';
        return;
      }
      this.loggedIn = true;
      this.loginVia = 'huawei';
      this.accountLabel = r.account.userId;
      this.recoveryCode = '';
      this.lastSyncText = '仅本机账号';
      this.syncReady = false;
      toast('华为账号登录成功');
      this.refreshSettingsState();
    } catch (e) {
      // 模块加载失败也落到这里，不再向上抛成未捕获异常
      this.syncMsg = '当前设备不支持华为账号登录，请使用恢复码登录';
      this.showRecovery = true;
    } finally {
      this.syncing = false;
    }
  }

  /** 恢复码登录：换机、模拟器、未登录华为账号时的唯一退路 */
  private async doResume(): Promise<void> {
    if (this.syncing) {
      return;
    }
    const code: string = this.recoveryInput.replace(/[^0-9a-zA-Z]/g, '');
    if (code.length < 12) {
      toast('请输入 16 位恢复码');
      return;
    }
    if (this.syncUrlInput.trim().length === 0) {
      toast('请先填写同步服务地址');
      return;
    }
    this.syncing = true;
    this.syncMsg = '';
    try {
      await Store.get().saveSyncUrl(this.syncUrlInput);
      const r = await Store.get().loginCloudByCode(code);
      if (!r.ok) {
        this.syncMsg = r.msg;
        return;
      }
      this.loggedIn = true;
      this.loginVia = 'code';
      this.accountLabel = r.account !== null ? r.account.userId : '';
      this.recoveryCode = r.account !== null ? r.account.recoveryCode : '';
      this.showRecovery = false;
      this.recoveryInput = '';
      const merged = await Store.get().syncNow();
      if (merged.ok) {
        this.lastSyncText = '刚刚同步';
        this.syncReady = true;
        this.refreshSettingsState();
        toast('已用恢复码登录，数据已恢复');
      } else {
        this.syncMsg = merged.msg;
      }
    } finally {
      this.syncing = false;
    }
  }

  /** 恢复码按 4 位分组，方便抄写 */
  private groupCode(code: string): string {
    if (code.length === 0) {
      return '登录后生成';
    }
    let out: string = '';
    for (let i = 0; i < code.length; i += 4) {
      if (i > 0) {
        out += ' ';
      }
      out += code.substring(i, Math.min(i + 4, code.length));
    }
    return out;
  }

  /**
   * 已登录华为账号、想补连云端：静默再拿一次令牌，
   * 到服务端换成云账号，成功后立刻同步一次。
   */
  private async doConnectCloud(): Promise<void> {
    if (this.syncing) {
      return;
    }
    if (this.syncUrlInput.trim().length === 0) {
      toast('请先填写同步服务地址');
      return;
    }
    const ctx = Store.get().abilityContext;
    if (ctx === null) {
      toast('应用还没准备好，稍后再试');
      return;
    }
    this.syncing = true;
    this.syncMsg = '';
    try {
      await Store.get().saveSyncUrl(this.syncUrlInput);
      // 延迟加载：Account Kit 只在华为设备上存在，静态引入会让启动链一起崩
      const authMod = await import('../auth/HuaweiAuth');
      const auth = await authMod.HuaweiAuth.signIn(ctx);
      if (!auth.ok) {
        this.syncMsg = auth.msg;
        return;
      }
      const r = await Store.get().loginCloud(auth.idToken, auth.openid, '');
      if (!r.ok || r.account === null) {
        this.syncMsg = r.msg;
        return;
      }
      this.accountLabel = r.account.userId;
      this.recoveryCode = r.account.recoveryCode;
      const merged = await Store.get().syncNow();
      if (merged.ok) {
        this.syncReady = true;
        this.lastSyncText = '刚刚同步';
        this.refreshSettingsState();
        toast(r.hasCloudData ? '已连接，云端数据已合并' : '已连接，已建立云端存档');
      } else {
        this.syncMsg = merged.msg;
      }
    } catch (e) {
      this.syncMsg = '当前设备不支持华为账号登录，请使用恢复码登录';
    } finally {
      this.syncing = false;
    }
  }

  private async doSync(silent: boolean): Promise<void> {
    if (this.syncing) {
      return;
    }
    this.syncing = true;
    const r = await Store.get().syncNow();
    this.syncing = false;
    if (r.ok) {
      this.lastSyncText = '刚刚同步';
      this.syncMsg = '';
      this.syncReady = true;
      this.refreshSettingsState();
      if (!silent) {
        toast('同步完成');
      }
    } else {
      this.syncMsg = r.msg;
      if (r.msg.indexOf('还没登录') >= 0 || r.msg.indexOf('未登录') >= 0) {
        this.loggedIn = false;
      }
    }
  }

  private async doSyncPing(): Promise<void> {
    if (this.syncUrlInput.trim().length === 0) {
      toast('请先填写同步服务地址');
      return;
    }
    this.syncing = true;
    await Store.get().saveSyncUrl(this.syncUrlInput);
    const ok: boolean = await Store.get().pingSyncServer();
    this.syncing = false;
    this.syncMsg = ok ? '' : '连不上这个地址，检查服务是否启动、端口是否放通';
    toast(ok ? '连接正常' : '连不上同步服务');
  }

  private async doLogout(): Promise<void> {
    if (this.syncing) {
      return;
    }
    await Store.get().logoutCloud();
    this.loggedIn = false;
    this.syncReady = false;
    this.accountLabel = '';
    this.lastSyncText = '尚未同步';
    this.recoveryCode = '';
    this.syncMsg = '';
    // 地址已被清空，重新按 Navidrome 主机名派生一个默认值
    this.syncUrlInput = '';
    this.initAccount();
    toast('已退出登录，云端数据保留');
  }

  /** 同步/恢复后把面板上的开关与文字重新对齐 Store（云端值可能已经覆盖本地） */
  private refreshSettingsState(): void {
    const s = Store.get().settings;
    this.autoCache = s.autoCache;
    this.radio = s.radio !== false;
    this.scrobble = s.scrobble !== false;
    this.onlineLyric = s.onlineLyric !== false;
    this.volume = s.volume;
    this.refreshListenStats();
    this.refreshTrackStats();
    this.refreshCacheUsage();
  }

  /** 读取缓存占用，刷新右上角文字（异步遍历，不冻设置页） */
  private refreshCacheUsage(): void {
    Store.get().cacheUsage().then((u: CacheUsage) => {
      if (u.files === 0) {
        this.cacheSizeText = '';
      } else {
        this.cacheSizeText = Fmt.size(u.bytes) + ' · ' + u.files.toString() + ' 个文件';
      }
    }).catch(() => {
    });
  }

  /** 清空缓存：删文件 + 清索引 + 刷新显示 */
  private async clearCacheNow(): Promise<void> {
    if (this.cacheBusy) {
      return;
    }
    this.cacheBusy = true;
    // 先记一下清理前的量，用来在 Toast 里告诉用户释放了多少
    const before: CacheUsage = await Store.get().cacheUsage();
    try {
      await Store.get().clearCache();
    } catch (e) {
    }
    this.cacheBusy = false;
    this.refreshCacheUsage();
    if (before.files === 0) {
      toast('缓存本来就是空的');
    } else {
      toast('已清空缓存，释放 ' + Fmt.size(before.bytes));
    }
  }

  /** 拉取单曲排行：只取前 10 名，用播放次数决定条形长度 */
  private refreshTrackStats(): void {
    const store: Store = Store.get();
    this.trackTotal = store.trackStatCount();
    const top: TrackStat[] = store.topTracks(TRACK_TOP_N);
    let maxPlays: number = 1;
    for (let i = 0; i < top.length; i++) {
      if (top[i].plays > maxPlays) {
        maxPlays = top[i].plays;
      }
    }
    this.trackStats = top;
    this.trackMaxPlays = maxPlays;
  }

  /** 单曲累计时长的短写法（列表里空间有限） */
  private fmtTrackTime(seconds: number): string {
    const total: number = Math.floor(seconds);
    if (total < 60) {
      return total + ' 秒';
    }
    const mins: number = Math.floor(total / 60);
    if (mins < 60) {
      return mins + ' 分';
    }
    return Math.floor(mins / 60) + ' 时 ' + (mins % 60) + ' 分';
  }

  /** 排行条宽度：相对最高播放次数，最小留 6% 让形状可见 */
  private barPct(plays: number, maxPlays: number): string {
    if (maxPlays <= 0 || plays <= 0) {
      return '6%';
    }
    return Math.max(6, Math.round(plays / maxPlays * 100)) + '%';
  }

  /** 秒 → 人话时长（分钟四舍五入，跟柱顶数字保持一致） */
  private fmtDuration(seconds: number): string {
    const total: number = Math.floor(seconds);
    if (total < 60) {
      return total + ' 秒';
    }
    const totalMin: number = Math.round(total / 60);
    const h: number = Math.floor(totalMin / 60);
    const m: number = totalMin % 60;
    if (h === 0) {
      return m + ' 分钟';
    }
    return h + ' 小时 ' + m + ' 分';
  }

  /** 拉取累计/本周时长，并算出近 7 天柱高 */
  private refreshListenStats(): void {
    const store: Store = Store.get();
    this.listenTotal = this.fmtDuration(store.listenTotalSeconds());

    const now: Date = new Date();
    const dayMs: number = 24 * 60 * 60 * 1000;
    const secs: number[] = [];
    let maxSec: number = 0;
    let weekSec: number = 0;
    for (let i = 6; i >= 0; i--) {
      const d: Date = new Date(now.getTime() - i * dayMs);
      const s: number = store.listenSecondsOn(Store.dayKey(d));
      secs.push(s);
      weekSec += s;
      if (s > maxSec) {
        maxSec = s;
      }
    }
    this.listenWeek = this.fmtDuration(weekSec);

    const days: ListenDay[] = [];
    for (let i = 0; i < 7; i++) {
      const d: Date = new Date(now.getTime() - (6 - i) * dayMs);
      const s: number = secs[i];
      // 柱高 4~96vp：有数据按比例，没有也留一小截表示「这天没听」
      const h: number = maxSec > 0 ? Math.max(4, Math.round(s / maxSec * 96)) : 4;
      days.push({
        key: Store.dayKey(d),
        label: i === 6 ? '今天' : (d.getMonth() + 1) + '/' + d.getDate(),
        minutes: Math.round(s / 60),
        barHeight: h
      });
    }
    this.listenDays = days;
  }

  /** 是否今天（柱状图里今天高亮） */
  private isToday(key: string): boolean {
    return key === Store.dayKey(new Date());
  }

  private async saveSettings(): Promise<void> {
    const settings: AppSettings = {
      autoCache: this.autoCache,
      volume: this.volume,
      radio: this.radio,
      scrobble: this.scrobble,
      onlineLyric: this.onlineLyric,
      playerSkin: this.skin
    };
    await Store.get().saveSettings(settings);
  }

  private disconnect(): void {
    Router.replace('pages/Setup');
  }

  private async setDark(v: boolean): Promise<void> {
    AppStorage.setOrCreate('isDark', v);
    await Store.get().saveDark(v);
    refreshSystemBar(v);
  }

  private applySwitch(key: string, v: boolean): void {
    if (key === 'dark') {
      this.setDark(v);
      return;
    }
    if (key === 'cache') {
      this.autoCache = v;
    } else if (key === 'radio') {
      this.radio = v;
    } else if (key === 'scrobble') {
      this.scrobble = v;
    } else if (key === 'onlineLyric') {
      this.onlineLyric = v;
    }
    this.saveSettings();
  }

  /** 选播放页外观：写设置并立刻生效（播放页每次进入都会重读） */
  private async pickSkin(key: PlayerSkin): Promise<void> {
    if (this.skin === key) {
      return;
    }
    this.skin = key;
    AppStorage.setOrCreate('playerSkin', key);
    await this.saveSettings();
    let tip: string = '播放页切换到「经典玻璃」';
    if (key === 'vinyl') {
      tip = '播放页切换到「唱片封套」';
    } else if (key === 'clock') {
      tip = '播放页切换到「时计机芯」';
    }
    toast(tip);
  }

  /**
   * 播放页样式的小缩略卡：左边示意图，右边只有名字。
   * 示意图不用图片资源，两个方块拼出来——足够让人分清「圆盘 + 卡片」和「方形封套」。
   */
  @Builder
  private skinCard(key: PlayerSkin, label: string, hint: string) {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        if (key === 'vinyl') {
          // 封套：砖红方块，右侧抽出黑胶
          Column()
            .width(26).height(26).borderRadius(2)
            .backgroundColor('#B8452F')
          Column()
            .width(21).height(21).borderRadius(10.5)
            .backgroundColor('#141418')
            .border({ width: 1, color: '#33FFFFFF' })
            .position({ x: 15, y: 3 })
          Column()
            .width(6).height(6).borderRadius(3)
            .backgroundColor('#E8DFCD')
            .position({ x: 22.5, y: 10.5 })
        } else if (key === 'clock') {
          // 时计：深底机芯盘（双环）+ 盘心封套 + 向下的轴线
          Column()
            .width(30).height(30).borderRadius(15)
            .backgroundColor('#0B1119')
            .border({ width: 1, color: '#668FB4DE' })
            .position({ x: 7, y: 3 })
          Column()
            .width(22).height(22).borderRadius(11)
            .backgroundColor('#00000000')
            .border({ width: 1, color: '#3DC9D6E8' })
            .position({ x: 11, y: 7 })
          Column()
            .width(9).height(9).borderRadius(4.5)
            .backgroundColor('#8FB4DE')
            .opacity(0.55)
            .position({ x: 17.5, y: 13.5 })
          Column()
            .width(1).height(5)
            .backgroundColor('#B38FB4DE')
            .position({ x: 21.5, y: 32 })
        } else {
          // 经典：银灰盘 + 左上歌词卡
          Column()
            .width(28).height(28).borderRadius(14)
            .backgroundColor('#2A2E36')
            .border({ width: 1, color: '#4DFFFFFF' })
            .position({ x: 12, y: 6 })
          Column()
            .width(13).height(11).borderRadius(2)
            .backgroundColor('#C9D3E2')
            .position({ x: 2, y: 4 })
        }
      }
      .width(44).height(40)

      Text(label)
        .fontSize(12).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
        .fontColor(this.skin === key ? Theme.accent(this.isDark) : Theme.text(this.isDark))
        .margin({ top: 4 })
      Text(hint)
        .fontSize(9.5).fontFamily(APP_FONT)
        .fontColor(Theme.textTertiary(this.isDark))
        .margin({ top: 2 })
        .maxLines(1)
    }
    .layoutWeight(1)
    .padding({ top: 12, bottom: 10 })
    .backgroundColor(this.skin === key ? Theme.surfaceAlt(this.isDark) : Theme.surface(this.isDark))
    .borderRadius(12)
    .border({
      width: this.skin === key ? 1.5 : 1,
      color: this.skin === key ? Theme.accent(this.isDark) : '#00000000'
    })
    .onClick(() => { this.pickSkin(key); })
  }

  /** 未传入标题时的默认头部：什么都不画 */
  @Builder
  private emptyHeader() {}

  build() {
    Scroll() {
      Column() {
        // 标题（如果有）或顶部空白，作为滚动内容的第一项
        if (this.topPad > 0) {
          Column().height(this.topPad)
        }
        this.header()

        // 账号与同步：华为账号一键登录，数据存自己的 NAS
        Column() {
          Text('账号与同步')
            .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark)).width('100%')
            .margin({ bottom: 8 })
          Column() {
            Row() {
              // 头像位：不用外部图标，画一个圆底字块
              Column() {
                Text('华')
                  .fontSize(17).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
              }
              .width(40).height(40).borderRadius(20)
              .backgroundColor(Theme.accent(this.isDark))
              .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)

              Column() {
                Text(this.loggedIn
                  ? (this.loginVia === 'code' ? '已连接云端（恢复码登录）' : '已登录华为账号')
                  : '华为账号一键登录')
                  .fontSize(15).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
                  .fontColor(Theme.text(this.isDark))
                Text(this.loggedIn
                  ? (this.lastSyncText + (this.accountLabel.length > 0 ? ' · ' + this.accountLabel : ''))
                  : '登录后自动备份设置、收藏与听歌统计')
                  .fontSize(11).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                  .margin({ top: 3 })
                  .maxLines(2)
              }
              .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 12 })
            }
            .width('100%')

            // 已登录且连过云端：把恢复码摆出来，换机靠它（纯本机账号没有恢复码）
            if (this.loggedIn && this.recoveryCode.length > 0) {
              Column() {
                Row() {
                  Text('恢复码')
                    .fontSize(11).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                  Row().layoutWeight(1)
                  Text('长按复制')
                    .fontSize(10).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                }
                .width('100%')
                Text(this.groupCode(this.recoveryCode))
                  .fontSize(15).fontFamily(APP_FONT)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.text(this.isDark))
                  .letterSpacing(1.2)
                  .width('100%')
                  .margin({ top: 6 })
                  .copyOption(CopyOptions.LocalDevice)
                Text('换手机、刷机或华为账号登不上时，在新设备输入这串码即可取回全部数据')
                  .fontSize(10).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                  .width('100%').margin({ top: 6 })
                  .maxLines(3)
              }
              .width('100%')
              .padding(12)
              .margin({ top: 12 })
              .backgroundColor(Theme.surfaceAlt(this.isDark))
              .borderRadius(10)
            }

            // 同步服务地址：已连上云端只读展示，其余情况都可编辑
            Row() {
              Image((this.isDark ? $r('app.media.ic_link') : $r('app.media.ic_link_d')))
                .width(16).height(16).opacity(0.5)
              if (this.loggedIn && this.syncReady) {
                Text(this.syncUrlInput.length > 0 ? this.syncUrlInput : '未配置')
                  .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                  .layoutWeight(1).margin({ left: 8 })
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              } else {
                TextInput({ text: $$this.syncUrlInput, placeholder: '如 192.168.1.10:8787' })
                  .fontSize(12).fontFamily(APP_FONT)
                  .fontColor(Theme.text(this.isDark))
                  .placeholderColor(Theme.textTertiary(this.isDark))
                  .backgroundColor(Color.Transparent)
                  .padding(0)
                  .layoutWeight(1)
                  .margin({ left: 8 })
                  .height(30)
                  .onChange((v: string) => { this.syncUrlInput = v; })
                Text('测试')
                  .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
                  .padding({ left: 10, right: 2, top: 8, bottom: 8 })
                  .onClick(() => { this.doSyncPing(); })
              }
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .margin({ top: 12 })

            if (this.syncMsg.length > 0) {
              Text(this.syncMsg)
                .fontSize(11).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
                .width('100%').margin({ bottom: 10 })
                .maxLines(3)
            }

            // 未登录时展开的恢复码输入区
            if (!this.loggedIn && this.showRecovery) {
              Row() {
                TextInput({ text: $$this.recoveryInput, placeholder: '输入 16 位恢复码' })
                  .fontSize(13).fontFamily(APP_FONT)
                  .fontColor(Theme.text(this.isDark))
                  .placeholderColor(Theme.textTertiary(this.isDark))
                  .backgroundColor(Theme.surfaceAlt(this.isDark))
                  .borderRadius(9)
                  .padding({ left: 10, right: 10 })
                  .height(38)
                  .layoutWeight(1)
                Text(this.syncing ? '恢复中…' : '恢复')
                  .fontSize(13).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
                  .textAlign(TextAlign.Center)
                  .width(72).height(38)
                  .borderRadius(9)
                  .backgroundColor(Theme.accent(this.isDark))
                  .opacity(this.syncing ? 0.6 : 1)
                  .margin({ left: 8 })
                  .onClick(() => { this.doResume(); })
              }
              .width('100%')
              .margin({ bottom: 10 })
            }

            Row() {
              if (!this.loggedIn) {
                Text(this.syncing ? '登录中…' : '华为账号登录')
                  .fontSize(13).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
                  .textAlign(TextAlign.Center)
                  .layoutWeight(1)
                  .height(38)
                  .borderRadius(19)
                  .backgroundColor(Theme.accent(this.isDark))
                  .opacity(this.syncing ? 0.6 : 1)
                  .onClick(() => { this.doLogin(); })
                Text(this.showRecovery ? '收起' : '用恢复码')
                  .fontSize(13).fontFamily(APP_FONT)
                  .fontColor(Theme.textSecondary(this.isDark))
                  .textAlign(TextAlign.Center)
                  .width(84)
                  .height(38)
                  .borderRadius(19)
                  .backgroundColor(Theme.surfaceAlt(this.isDark))
                  .margin({ left: 10 })
                  .onClick(() => {
                    this.showRecovery = !this.showRecovery;
                    this.syncMsg = '';
                  })
              } else {
                if (this.syncReady) {
                  Text(this.syncing ? '同步中…' : '立即同步')
                    .fontSize(13).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
                    .fontColor(Theme.accent(this.isDark))
                    .textAlign(TextAlign.Center)
                    .layoutWeight(1)
                    .height(38)
                    .borderRadius(19)
                    .backgroundColor(Theme.surfaceAlt(this.isDark))
                    .opacity(this.syncing ? 0.6 : 1)
                    .onClick(() => { this.doSync(false); })
                  Text('退出')
                    .fontSize(13).fontFamily(APP_FONT)
                    .fontColor(Theme.textSecondary(this.isDark))
                    .textAlign(TextAlign.Center)
                    .width(88)
                    .height(38)
                    .borderRadius(19)
                    .backgroundColor(Theme.surfaceAlt(this.isDark))
                    .margin({ left: 10 })
                    .onClick(() => { this.doLogout(); })
                } else {
                  Text(this.syncing ? '连接中…' : '连接同步')
                    .fontSize(13).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
                    .fontColor(Color.White)
                    .textAlign(TextAlign.Center)
                    .layoutWeight(1)
                    .height(38)
                    .borderRadius(19)
                    .backgroundColor(Theme.accent(this.isDark))
                    .opacity(this.syncing ? 0.6 : 1)
                    .onClick(() => { this.doConnectCloud(); })
                  Text('退出登录')
                    .fontSize(13).fontFamily(APP_FONT)
                    .fontColor(Theme.textSecondary(this.isDark))
                    .textAlign(TextAlign.Center)
                    .width(88)
                    .height(38)
                    .borderRadius(19)
                    .backgroundColor(Theme.surfaceAlt(this.isDark))
                    .margin({ left: 10 })
                    .onClick(() => { this.doLogout(); })
                }
              }
            }
            .width('100%')
          }
          .width('100%').padding(16)
          .backgroundColor(Theme.surface(this.isDark))
          .borderRadius(14)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 4 })

        // 服务器信息
        Column() {
          Text('Navidrome 连接')
            .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark)).width('100%')
            .margin({ bottom: 8 })
          Row() {
            Image((this.isDark ? $r('app.media.ic_nas') : $r('app.media.ic_nas_d')))
              .width(20).height(20).opacity(0.6)
            Column() {
              Text('服务器地址')
                .fontSize(11).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
              Text(this.serverUrl)
                .fontSize(14).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1).margin({ left: 12 })
            .alignItems(HorizontalAlign.Start)
            Text('更改')
              .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
              .onClick(() => { this.disconnect(); })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Theme.surface(this.isDark))
          .borderRadius(14)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 4 })

        // 外观
        Column() {
          Text('外观')
            .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark)).width('100%')
            .margin({ bottom: 8 })
          // 深浅色开关不用 switchRow：isOn 必须直接绑 this.isDark 才能即时反映状态
          Row() {
            Column() {
              Row() {
                Image((this.isDark ? $r('app.media.ic_moon') : $r('app.media.ic_sun_d')))
                  .width(20).height(20).opacity(0.85)
                Text(this.isDark ? '深色模式' : '浅色模式')
                  .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
                  .margin({ left: 10 })
              }
              Text('一键切换明暗界面，偏好自动保存')
                .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                .margin({ top: 4, left: 30 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .onClick(() => { this.setDark(!this.isDark); })
            Toggle({ type: ToggleType.Switch, isOn: this.isDark })
              .selectedColor(Theme.accent(this.isDark))
              .onChange((v: boolean) => { this.setDark(v); })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Theme.surface(this.isDark))
          .borderRadius(14)

          // 播放页样式：三套布局，换的是整页版式而不只是配色
          Row() {
            Text('播放页样式')
              .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
            Row().layoutWeight(1)
            Text('下次进入播放页生效')
              .fontSize(10).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
          }
          .width('100%')
          .margin({ top: 18, bottom: 8 })

          Row({ space: 10 }) {
            this.skinCard('classic', '经典玻璃', '歌词卡 + 银盘')
            this.skinCard('vinyl', '唱片封套', '封套 + 抽出黑胶')
            this.skinCard('clock', '时计机芯', '齿轮盘 + 轴线')
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 20 })

        // 播放与体验
        Column() {
          Text('播放与体验')
            .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark)).width('100%')
            .margin({ bottom: 8 })
          SettingSwitchRow({
            icon: this.isDark ? $r('app.media.ic_download') : $r('app.media.ic_download_d'),
            title: '自动缓存',
            desc: '下载到本地支持离线；上限 1GB，超了自动清最旧的',
            on: this.autoCache,
            isDark: this.isDark,
            rowKey: 'cache',
            onToggle: (k: string, v: boolean) => { this.applySwitch(k, v); }
          })
          Column().height(8)
          SettingSwitchRow({
            icon: this.isDark ? $r('app.media.ic_cycle_shuffle') : $r('app.media.ic_cycle_shuffle_d'),
            title: '电台续播',
            desc: '队列快放完时自动接上相似歌曲，一直放下去',
            on: this.radio,
            isDark: this.isDark,
            rowKey: 'radio',
            onToggle: (k: string, v: boolean) => { this.applySwitch(k, v); }
          })
          Column().height(8)
          SettingSwitchRow({
            icon: this.isDark ? $r('app.media.ic_server') : $r('app.media.ic_server_d'),
            title: '播放上报',
            desc: '把播放记录同步给服务器，推荐更准；关掉后服务器不留痕迹',
            on: this.scrobble,
            isDark: this.isDark,
            rowKey: 'scrobble',
            onToggle: (k: string, v: boolean) => { this.applySwitch(k, v); }
          })
          Column().height(8)
          SettingSwitchRow({
            icon: this.isDark ? $r('app.media.ic_lyrics') : $r('app.media.ic_lyrics_d'),
            title: '在线歌词兜底',
            desc: '服务器没歌词时自动匹配网络歌词；匹配上的歌在播放页歌词卡标注「在线匹配」，点它可看是哪个版本',
            on: this.onlineLyric,
            isDark: this.isDark,
            rowKey: 'onlineLyric',
            onToggle: (k: string, v: boolean) => { this.applySwitch(k, v); }
          })
          Column().height(8)
          SettingActionRow({
            icon: this.isDark ? $r('app.media.ic_download') : $r('app.media.ic_download_d'),
            title: '清空缓存',
            desc: '删除本地歌曲文件，不影响歌单',
            value: this.cacheSizeText,
            action: '清空',
            isDark: this.isDark,
            busy: this.cacheBusy,
            disabled: this.cacheSizeText.length === 0,
            onAction: () => { this.clearCacheNow(); }
          })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 20 })

        // 听歌统计：累计时长 + 近 7 天柱状图；右上角进二级统计页
        Column() {
          Row() {
            Text('听歌统计')
              .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
            Row().layoutWeight(1)
            Text('查看全部')
              .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
            Text('›')
              .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
              .margin({ left: 2 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 8 })
          .onClick(() => { Router.push('pages/Stats'); })
          Column() {
            Row() {
              Column() {
                Text('累计时长')
                  .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                Text(this.listenTotal)
                  .fontSize(24).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Bold)
                  .fontColor(Theme.text(this.isDark))
                  .margin({ top: 3 })
              }
              .layoutWeight(1).alignItems(HorizontalAlign.Start)

              Column() {
                Text('近 7 天')
                  .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                Text(this.listenWeek)
                  .fontSize(15).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
                  .fontColor(Theme.accent(this.isDark))
                  .margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.End)
            }
            .width('100%')

            // 柱状图：7 根柱子底部对齐，柱顶标分钟数
            Row() {
              ForEach(this.listenDays, (d: ListenDay) => {
                Column() {
                  Text(d.minutes > 0 ? d.minutes.toString() : '')
                    .fontSize(9).fontFamily(APP_FONT)
                    .fontColor(Theme.textTertiary(this.isDark))
                    .height(12)
                  Column()
                    .width(18)
                    .height(d.barHeight)
                    .borderRadius(9)
                    .backgroundColor(Theme.accent(this.isDark))
                    .opacity(this.isToday(d.key) ? 1 : 0.38)
                  Text(d.label)
                    .fontSize(9).fontFamily(APP_FONT)
                    .fontColor(this.isToday(d.key) ? Theme.accent(this.isDark) : Theme.textTertiary(this.isDark))
                    .margin({ top: 6 })
                }
                .layoutWeight(1)
                .height(132)
                .justifyContent(FlexAlign.End)
                .alignItems(HorizontalAlign.Center)
              }, (d: ListenDay) => d.key)
            }
            .width('100%')
            .margin({ top: 16 })
            .alignItems(VerticalAlign.Bottom)
          }
          .width('100%').padding(16)
          .backgroundColor(Theme.surface(this.isDark))
          .borderRadius(14)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 20 })

        // 单曲收听：每首歌被播放了几次、一共听了多久
        Column() {
          Text('单曲统计')
            .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark)).width('100%')
            .margin({ bottom: 8 })
          Column() {
            Row() {
              Text('播放排行')
                .fontSize(15).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
                .fontColor(Theme.text(this.isDark))
              Text('TOP ' + TRACK_TOP_N)
                .fontSize(10).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
                .fontColor(Theme.accent(this.isDark))
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .borderRadius(4)
                .backgroundColor(Theme.surfaceAlt(this.isDark))
                .margin({ left: 8 })
              Row().layoutWeight(1)
              Text('共 ' + this.trackTotal + ' 首')
                .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            if (this.trackStats.length === 0) {
              Text('还没有播放记录，听几首歌就会出现在这里')
                .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                .width('100%').margin({ top: 14, bottom: 4 })
            } else {
              ForEach(this.trackStats, (st: TrackStat, idx: number) => {
                Column() {
                  Row() {
                    Text((idx + 1).toString())
                      .fontSize(11).fontFamily(APP_FONT)
                      .fontWeight(idx < 3 ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor(idx < 3 ? Theme.accent(this.isDark) : Theme.textTertiary(this.isDark))
                      .width(16).textAlign(TextAlign.Center)
                    Column() {
                      Text(st.title)
                        .fontSize(14).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(st.artist.length > 0 ? st.artist : '未知歌手')
                        .fontSize(11).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 2 })
                    }
                    .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 8 })
                    Column() {
                      Text(st.plays + ' 次')
                        .fontSize(13).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
                        .fontColor(Theme.accent(this.isDark))
                      Text(this.fmtTrackTime(st.seconds))
                        .fontSize(11).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                        .margin({ top: 2 })
                    }
                    .alignItems(HorizontalAlign.End).margin({ left: 8 })
                  }
                  .width('100%')

                  // 相对播放次数的细条，一眼看出哪几首听得最多
                  Stack({ alignContent: Alignment.Start }) {
                    Column().width('100%').height(3)
                      .borderRadius(2).backgroundColor(Theme.surfaceAlt(this.isDark))
                    Column().width(this.barPct(st.plays, this.trackMaxPlays)).height(3)
                      .borderRadius(2).backgroundColor(Theme.accent(this.isDark))
                      .opacity(idx < 3 ? 1 : 0.45)
                  }
                  .width('100%').height(3).margin({ top: 8 })
                }
                .width('100%')
                .margin({ top: 14 })
              }, (st: TrackStat) => st.id + '-' + st.plays)
            }
          }
          .width('100%').padding(16)
          .backgroundColor(Theme.surface(this.isDark))
          .borderRadius(14)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 20, bottom: this.bottomPad })
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    // 关掉滚动边缘渐隐：否则内容滚到顶部/底部会被一层半透明渐变盖住，看起来像遮罩
    .fadingEdge(false)
  }
}
