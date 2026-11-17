import { curves } from '@kit.ArkUI';
import { Theme, winWidth } from '../utils/Theme';

/** 底部导航的五个入口 */
export type NavTab = 'home' | 'songs' | 'playlists' | 'starred' | 'settings';

/** 导航条高度（外部算底部留白时会用到） */
export const NAV_H: number = 58;

const ICON: number = 22;
const PILL: number = 40;
/** 收起态圆钮直径 */
const DISC: number = 46;
/** 开始播放后多久自动收起 */
const COLLAPSE_AFTER_PLAY: number = 4000;
/** 用户操作过导航后无操作，多久自动收起 */
const COLLAPSE_AFTER_IDLE: number = 7000;

interface NavItem {
  key: string;
  icon: Resource;
  iconD: Resource;
  iconW: Resource;
}

/**
 * 悬浮底部导航，双形态（与迷你播放栏同一套交互）：
 *  - 展开态：毛玻璃胶囊，五个图标等分，选中项套品牌色实心圆；
 *  - 收起态：右下角一枚品牌色小圆钮，只显示当前选中图标，点击展开。
 * 开始播放后自动收起，操作过后 7 秒无动作再收起；暂停时恢复展开。
 */
@Component
export struct BottomNav {
  @StorageProp('isDark') private isDark: boolean = true;
  /** 智感握姿：'left' 时收起态圆钮靠左，'right' 靠右 */
  @StorageProp('gripHand') private gripHand: string = 'right';
  @StorageLink('playerPlaying') @Watch('onPlayingChanged') private playing: boolean = false;
  @StorageProp('winWidth') private winW: number = 0;
  @Prop cur: string;
  // 必须 public：private 成员无法从组件构造函数初始化
  onSelect: (t: string) => void = () => {};

  @State private collapsed: boolean = false;
  private timerId: number = -1;

  aboutToDisappear(): void {
    this.clearTimer();
  }

  private clearTimer(): void {
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  private armCollapse(ms: number): void {
    this.clearTimer();
    this.timerId = setTimeout(() => {
      this.timerId = -1;
      this.collapsed = true;
    }, ms);
  }

  /** 播放态变化：开播计时收起，暂停立即展开 */
  private onPlayingChanged(): void {
    if (this.playing) {
      this.armCollapse(COLLAPSE_AFTER_PLAY);
    } else {
      this.clearTimer();
      this.collapsed = false;
    }
  }

  /** 点了某个 tab：算一次用户操作，重置收起计时 */
  private onUserAction(): void {
    if (this.playing) {
      this.armCollapse(COLLAPSE_AFTER_IDLE);
    } else {
      this.clearTimer();
    }
  }

  private expand(): void {
    this.collapsed = false;
    if (this.playing) {
      this.armCollapse(COLLAPSE_AFTER_IDLE);
    }
  }

  private collapse(): void {
    this.clearTimer();
    this.collapsed = true;
  }

  private items(): NavItem[] {
    const list: NavItem[] = [
      {
        key: 'home',
        icon: $r('app.media.ic_home'), iconD: $r('app.media.ic_home_d'),
        iconW: $r('app.media.ic_home_w')
      },
      {
        key: 'songs',
        icon: $r('app.media.ic_note'), iconD: $r('app.media.ic_note_d'),
        iconW: $r('app.media.ic_note_w')
      },
      {
        key: 'playlists',
        icon: $r('app.media.ic_list'), iconD: $r('app.media.ic_list_d'),
        iconW: $r('app.media.ic_list_w')
      },
      {
        key: 'starred',
        icon: $r('app.media.ic_heart'), iconD: $r('app.media.ic_heart_d'),
        iconW: $r('app.media.ic_heart_w')
      },
      {
        key: 'settings',
        icon: $r('app.media.ic_settings'), iconD: $r('app.media.ic_settings_d'),
        iconW: $r('app.media.ic_settings_w')
      }
    ];
    return list;
  }

  private iconOf(it: NavItem, active: boolean): Resource {
    if (active) {
      return it.iconW;
    }
    return this.isDark ? it.icon : it.iconD;
  }

  /** 当前选中项（收起态圆钮里显示它的白色图标） */
  private selectedIcon(): Resource {
    const cur: NavItem | undefined = this.items().find((it: NavItem) => it.key === this.cur);
    if (cur === undefined) {
      return this.items()[0].iconW;
    }
    return cur.iconW;
  }

  /** 展开态导航条的宽度（vp）：按窗口算死，理由同 MiniPlayer.pillW() */
  private barW(): number {
    const w: number = this.winW > 0 ? this.winW : winWidth();
    return w - 32;
  }

  build() {
    // 外层只负责左右留边：width 100% 再叠 margin 会向右溢出屏幕
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        if (this.collapsed) {
          // 收起态：品牌色圆钮 + 当前选中图标
          Column()
            .width(DISC).height(DISC)
            .borderRadius(DISC / 2)
            .backgroundColor(Theme.accent(this.isDark))

          Image(this.selectedIcon())
            .width(20).height(20)
        } else {
          Row() {
            ForEach(this.items(), (it: NavItem) => {
              Stack({ alignContent: Alignment.Center }) {
                // 选中态底圆
                // 用 spring 而不是固定时长：底圆从 0 长到 PILL 是个「弹出」动作，
                // 弹簧末尾那点过冲正好是想要的果冻感；固定缓动到位太规矩、偏硬。
                Column()
                  .width(this.cur === it.key ? PILL : 0)
                  .height(this.cur === it.key ? PILL : 0)
                  .borderRadius(PILL / 2)
                  .backgroundColor(Theme.accent(this.isDark))
                  .opacity(this.cur === it.key ? 1 : 0)
                  .animation({ curve: curves.springMotion(0.3, 0.7) })

                Image(this.iconOf(it, this.cur === it.key))
                  .width(ICON).height(ICON)
                  .opacity(this.cur === it.key ? 1 : 0.55)
                  .animation({ duration: 180, curve: Curve.FastOutSlowIn })
              }
              .layoutWeight(1)
              .height(NAV_H)
              .onClick(() => {
                if (this.cur !== it.key) {
                  this.onSelect(it.key);
                }
                this.onUserAction();
              })
            })
          }
          .width(this.barW())
          .height(NAV_H)
          .padding({ left: 4, right: 4 })
        }
      }
      .width(this.collapsed ? DISC : this.barW())
      .height(this.collapsed ? DISC : NAV_H)
      .borderRadius(this.collapsed ? DISC / 2 : NAV_H / 2)
      .clip(true)
      .backgroundColor(this.collapsed
        ? Theme.accent(this.isDark)
        : (this.isDark ? '#8C232330' : '#8FFFFFFF'))
      .backdropBlur(this.collapsed ? 0 : (this.isDark ? 30 : 26))
      .border({
        width: this.collapsed ? 0 : 0.8,
        color: this.collapsed ? '#00000000' : Theme.divider(this.isDark)
      })
      .shadow({
        radius: 16,
        color: this.isDark ? '#66000000' : '#1A000000',
        offsetY: 4
      })
      // 展开/收起的形变也交给 spring：
      // 这个动画同时改 width、height、borderRadius 三个几何量，
      // 固定缓动下三者是同一节奏线性插值，形状看着像被「压扁」；
      // 弹簧的减速曲线让半径和尺寸同步收，视觉上更像真的缩成一个圆。
      .animation({ curve: curves.springMotion(0.38, 0.86) })
      .onClick(() => {
        if (this.collapsed) {
          this.expand();
        }
      })
      .gesture(
        LongPressGesture({ repeat: false, duration: 420 })
          .onAction(() => {
            this.collapse();
          })
      )
    }
    .width(this.barW() + 32)
    .padding({ left: 16, right: 16 })
    // 智感握姿：左手握持时收起的圆钮移到左下角，右手时右下角
    .justifyContent(this.gripHand === 'left' ? FlexAlign.Start : FlexAlign.End)
  }
}
