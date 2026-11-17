import { Router } from '../utils/Router';
import { APP_FONT, APP_FONT_BOLD } from '../utils/Fonts';
import { Theme, topInset, bottomInset } from '../utils/Theme';
import { SettingsPanel } from '../components/SettingsPanel';

/**
 * 独立设置页：只在外部（旧入口）跳转时用到。
 * 主页的「设置」标签直接嵌 components/SettingsPanel，不走这个页面。
 */
@Entry
@Component
struct Settings {
  @StorageProp('isDark') private isDark: boolean = true;

  /**
   * 页面转场：与播放页同一套参数（进 340 / 出 280，FastOutSlowIn）。
   * 位移只给 18%，两页有一小段时间同时可见，空间关系比整页平移更轻。
   */
  // 不再自定义 pageTransition：与统计页保持一致，交给系统默认转场，
  // 避免重页面上每帧整页位移+透明度合成造成的转场掉帧。

  build() {
    Column() {
      Row() {
        Image((this.isDark ? $r('app.media.ic_back') : $r('app.media.ic_back_d')))
          .width(24).height(24)
          .onClick(() => { Router.back(); })
        Text('设置')
          .fontSize(18).fontFamily(APP_FONT).fontWeight(FontWeight.Medium).fontColor(Theme.text(this.isDark))
          .margin({ left: 12 })
        Row().layoutWeight(1)
      }
      .width('100%')
      .height(52 + topInset())
      .padding({ left: 16, right: 16, top: topInset() })
      .alignItems(VerticalAlign.Center)

      SettingsPanel({ bottomPad: bottomInset() + 30 })
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.bg(this.isDark))
  }
}
