import { ServerConfig } from '../model/Models';
import { APP_FONT, APP_FONT_BOLD, registerAppFonts } from '../utils/Fonts';
import { Store } from '../store/Store';
import { Subsonic } from '../net/Subsonic';
import { Router } from '../utils/Router';
import { Theme, toast, topInset } from '../utils/Theme';
import { Motion } from '../utils/Motion';

@Entry
@Component
struct Setup {
  @StorageProp('isDark') private isDark: boolean = true;
  // 不预填任何服务器地址 / 账号：输入框留空走 placeholder，
  // 已保存过的配置在 aboutToAppear 里回填
  @State private url: string = '';
  @State private username: string = '';
  @State private password: string = '';
  @State private showPass: boolean = false;
  @State private testing: boolean = false;
  @State private result: string = '';
  @State private resultOk: boolean = false;
  @State private focusIdx: number = -1;
  /** 上一次测试成功时用的连接参数。改了输入就得重测，不能拿旧结果直接进 */
  private testedKey: string = '';

  aboutToAppear(): void {
    registerAppFonts(this.getUIContext());
    const cfg: ServerConfig | null = Store.get().serverConfig;
    if (cfg !== null && cfg.url.length > 0) {
      this.url = cfg.url;
      this.username = cfg.username;
      this.password = cfg.password;
    }
  }

  private async test(): Promise<void> {
    if (this.url.trim().length === 0 || this.username.trim().length === 0) {
      this.result = '请填写地址和用户名';
      this.resultOk = false;
      return;
    }
    this.testing = true;
    this.resultOk = false;
    const cfg: ServerConfig = this.currentConfig();
    this.result = '正在连接 Navidrome…';
    const client = new Subsonic(cfg);
    const res = await client.ping();
    this.testing = false;
    this.result = res.msg;
    this.resultOk = res.ok;
    this.testedKey = res.ok ? this.configKey(cfg) : '';
    if (this.resultOk) {
      await Store.get().saveConfig(cfg);
      toast('连接成功');
    }
  }

  /** 连接参数的指纹：地址 / 用户名 / 密码任一变化都算「没测过」 */
  private configKey(cfg: ServerConfig): string {
    return cfg.url + '\n' + cfg.username + '\n' + cfg.password;
  }

  private currentConfig(): ServerConfig {
    return {
      type: 'subsonic',
      url: this.url.trim().replace(/\/+$/, ''),
      username: this.username.trim(),
      password: this.password,
      rootPath: '/'
    };
  }

  private async saveAndEnter(): Promise<void> {
    // 「测试通过」只对当时那组参数有效。测完又改了密码却直接进，
    // 会用错误的密码覆盖掉刚存好的配置，下次打开整个库都读不出来。
    if (this.resultOk && this.testedKey.length > 0 &&
      this.testedKey === this.configKey(this.currentConfig())) {
      Router.replace('pages/SubsonicLibrary');
      return;
    }
    await this.test();
    if (this.resultOk) {
      Router.replace('pages/SubsonicLibrary');
    }
  }

  @Builder
  field(icon: Resource, placeholder: string, value: string, idx: number, isPass: boolean,
    onChange: (v: string) => void) {
    Row() {
      Image(icon).width(20).height(20).opacity(this.focusIdx === idx ? 0.9 : 0.45)
      TextInput({ text: value, placeholder: placeholder })
        .layoutWeight(1)
        .height(50)
        .backgroundColor(Color.Transparent)
        .placeholderColor('#5A5A64')
        .fontSize(15).fontFamily(APP_FONT)
        .fontColor(Theme.text(this.isDark))
        .caretColor(Theme.accent(this.isDark))
        .type(isPass && !this.showPass ? InputType.Password : InputType.Normal)
        .showPasswordIcon(false)
        .onFocus(() => { this.focusIdx = idx; })
        .onBlur(() => { this.focusIdx = -1; })
        .onChange((v: string) => { onChange(v); })
      if (isPass) {
        Image(this.showPass ? (this.isDark ? $r('app.media.ic_eye') : $r('app.media.ic_eye_d')) : (this.isDark ? $r('app.media.ic_eye_off') : $r('app.media.ic_eye_off_d')))
          .width(18).height(18).opacity(0.5)
          .onClick(() => { this.showPass = !this.showPass; })
      }
    }
    .width('100%')
    .height(54)
    .padding({ left: 14, right: 14 })
    .backgroundColor(Theme.surface(this.isDark))
    .borderRadius(14)
    .border({ width: this.focusIdx === idx ? 1.5 : 1, color: this.focusIdx === idx ? Theme.accentBorder(this.isDark) : Theme.divider(this.isDark) })
  }

  /**
   * 页面转场：与播放页同一套参数（进 340 / 出 280，FastOutSlowIn）。
   * 位移只给 18%，两页有一小段时间同时可见，空间关系比整页平移更轻。
   */
  pageTransition() {
    PageTransitionEnter({ duration: Motion.PAGE_IN, curve: Curve.FastOutSlowIn })
      .translate({ x: '18%' })
      .opacity(0.35)
    PageTransitionExit({ duration: Motion.PAGE_OUT, curve: Curve.FastOutSlowIn })
      .translate({ x: '8%' })
      .opacity(0.55)
  }

  build() {
    Scroll() {
      Column() {
        // 顶部
        Column() {
          Image($r('app.media.app_icon')).width(60).height(60).borderRadius(16)
          Text('星籁')
            .fontSize(28).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Bold).fontColor(Theme.text(this.isDark))
            .letterSpacing(3).margin({ top: 14 })
          Text('连接你的 Navidrome，播放私有音乐库')
            .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
            .margin({ top: 6 })
        }
        .width('100%')
        .padding({ top: topInset() + 40, bottom: 28 })
        .alignItems(HorizontalAlign.Center)

        // 表单
        Column() {
          Text('Navidrome / Subsonic 连接')
            .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
            .width('100%').margin({ bottom: 10 })

          // 快捷预设
          this.field((this.isDark ? $r('app.media.ic_server') : $r('app.media.ic_server_d')),
            'Navidrome 地址（如 http://ip:port）',
            this.url, 0, false, (v: string) => { this.url = v; })

          Column() {
            this.field((this.isDark ? $r('app.media.ic_person') : $r('app.media.ic_person_d')), '用户名',
              this.username, 1, false, (v: string) => { this.username = v; })
          }
          .margin({ top: 10 })

          Column() {
            this.field((this.isDark ? $r('app.media.ic_lock') : $r('app.media.ic_lock_d')),
              '密码（输入一次后自动记住）',
              this.password, 2, true, (v: string) => { this.password = v; })
          }
          .margin({ top: 10 })

          if (this.result.length > 0) {
            Row() {
              Text(this.result)
                .fontSize(13).fontFamily(APP_FONT)
                .fontColor(this.resultOk ? Theme.success(this.isDark) : Theme.accent(this.isDark))
                .layoutWeight(1)
            }
            .width('100%').margin({ top: 14 })
          }

          Button(this.testing ? '测试中…' : '测试连接')
            .width('100%').height(48).borderRadius(14)
            .fontSize(15).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
            .fontColor(Theme.text(this.isDark))
            .backgroundColor(Theme.surfaceAlt(this.isDark))
            .border({ width: 1, color: Theme.divider(this.isDark) })
            .margin({ top: 18 })
            .enabled(!this.testing)
            .onClick(() => { this.test(); })

          Button(this.resultOk ? '进入音乐库' : '保存并进入')
            .width('100%').height(52).borderRadius(14)
            .fontSize(16).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .backgroundColor(Theme.accent(this.isDark))
            .margin({ top: 10 })
            .onClick(() => { this.saveAndEnter(); })
        }
        .width('100%')
        .padding({ left: 22, right: 22, top: 24, bottom: 36 })

        // 使用步骤
        Column() {
          Text('使用步骤')
            .fontSize(13).fontFamily(APP_FONT).fontWeight(FontWeight.Medium).fontColor(Theme.textSecondary(this.isDark))
            .margin({ bottom: 10 })
          Text('1. Navidrome 已部署运行（你的服务已就绪）\n2. 地址与账号已自动预填，只需输入密码\n3. 点击「测试连接」→「进入音乐库」\n4. 按 歌手/专辑/收藏 浏览，点击即播')
            .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
            .lineHeight(20)
        }
        .width('100%')
        .padding({ left: 22, right: 22, bottom: 40 })
      }
      .width('100%')
    }
    .width('100%').height('100%')
    .scrollBar(BarState.Off)
    .backgroundColor(Theme.bg(this.isDark))
    .edgeEffect(EdgeEffect.Spring)
  }
}
