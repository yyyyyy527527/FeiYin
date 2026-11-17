import { curves } from '@kit.ArkUI';
import { Theme, winWidth } from '../utils/Theme';
import { APP_FONT, APP_FONT_BOLD } from '../utils/Fonts';
import { Store } from '../store/Store';

/** 两种形态高度一致，展开/收起时列表不会跳动 */
const DISC: number = 60;
/** 展开态右侧圆钮直径 */
const BTN: number = 34;
/** 开始播放后多久自动收起 */
const COLLAPSE_AFTER_PLAY: number = 2400;
/** 手动展开后无操作，多久自动收起 */
const COLLAPSE_AFTER_IDLE: number = 7000;
/** 唱片自转：每 100ms 转 3°，约 12 秒一圈 */
const SPIN_STEP: number = 3;
const SPIN_TICK: number = 100;

/**
 * 迷你播放器：
 *  - 展开态：占满宽度的毛玻璃胶囊，显示歌名 + 当前歌词 + 播放/下一首，点击进播放页，长按收起；
 *  - 收起态：右下角一枚圆形唱片（封面 + 环形进度 + 中心轴孔），播放时缓慢自转，点击展开。
 * 开始播放后自动收起，避免一直压着列表。
 * 展开态整条胶囊就是进度条——填充层随播放进度从左向右增长。
 */
@Component
export struct MiniPlayer {
  @StorageProp('isDark') private isDark: boolean = true;
  /** 智感握姿：'left' 时收起态唱片靠左，'right' 靠右 */
  @StorageProp('gripHand') private gripHand: string = 'right';
  @StorageLink('playerPlaying') @Watch('onPlayingChanged') private playing: boolean = false;
  @StorageLink('playerTitle') @Watch('onPlayingChanged') private title: string = '';
  @StorageLink('playerArtist') private artist: string = '';
  @StorageLink('playerCoverUrl') private coverUrl: string = '';
  @StorageLink('playerPosition') private playPos: number = 0;
  @StorageLink('playerDuration') private duration: number = 0;
  @StorageLink('playerLoading') private loading: boolean = false;
  @StorageLink('miniLyric') private lyricLine: string = '';
  /** 窗口宽度（vp）。胶囊宽度按它算死，不再用 '100%'，见 pillW() */
  @StorageProp('winWidth') private winW: number = 0;
  /** 被动暂停原因（来电、别的应用抢焦点…）。空串 = 正常状态，不显示提示 */
  @StorageProp('playerPauseReason') private pauseReason: string = '';
  // 必须是 public：private 成员无法从组件构造函数初始化，外部传入的回调会失效
  onTap: () => void = () => {};
  /** 点队列按钮：由页面负责弹队列（弹层状态都在页面里） */
  onOpenQueue: () => void = () => {};

  @State private expanded: boolean = true;
  @State private spinAngle: number = 0;
  private timerId: number = -1;
  private spinTimer: number = -1;

  // 注意：这里不再覆盖 player.onStateChange / onProgress。
  // 播放页（NowPlaying）会占用这两个回调，若此处重复赋值会把它顶掉，
  // 导致播放页的封面与播放态停止更新。迷你条全部走 @StorageLink 同步。

  aboutToAppear(): void {
    // 进入页面时若已经在播放，稍等一下就收起（给一眼看清现在放的是什么）
    if (this.playing) {
      this.armCollapse(COLLAPSE_AFTER_PLAY);
    }
  }

  aboutToDisappear(): void {
    this.clearTimer();
    this.stopSpin();
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
      this.setExpanded(false);
      this.startSpin();
    }, ms);
  }

  /**
   * 展开 / 收起统一走这里：用 animateTo 而不是给容器挂 .animation()。
   *
   * 容器上的 .animation() 是隐式动画，会把「子树的内容变化」也卷进动画上下文里：
   * 切歌时文字换了内容，旧的绘制结果没有被清掉，就和新文字叠成重影
   * （迷你条 1.1.77、播放键 1.1.78 实机都撞到过）。改成显式 animateTo 后，
   * 只有 width / borderRadius 这两个属性参与补间，子内容变化是普通的一次重绘。
   */
  private setExpanded(v: boolean): void {
    if (this.expanded === v) {
      return;
    }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.36, 0.86) }, () => {
      this.expanded = v;
    });
  }

  /** 唱片自转（只在收起且正在播放时跑，10fps 小状态更新） */
  private startSpin(): void {
    if (!this.playing || this.expanded || this.spinTimer !== -1) {
      return;
    }
    this.spinTimer = setInterval(() => {
      this.spinAngle = (this.spinAngle + SPIN_STEP) % 360;
    }, SPIN_TICK);
  }

  private stopSpin(): void {
    if (this.spinTimer !== -1) {
      clearInterval(this.spinTimer);
      this.spinTimer = -1;
    }
  }

  /** 播放态或歌曲变化（新歌开始播放）→ 自动收起 */
  private onPlayingChanged(): void {
    if (this.playing) {
      this.armCollapse(COLLAPSE_AFTER_PLAY);
    } else {
      this.clearTimer();
      this.stopSpin();
    }
  }

  private expand(): void {
    this.stopSpin();
    this.setExpanded(true);
    if (this.playing) {
      this.armCollapse(COLLAPSE_AFTER_IDLE);
    }
  }

  private collapse(): void {
    this.clearTimer();
    this.setExpanded(false);
    this.startSpin();
  }

  /** 点条本体：展开态进播放页，收起态先展开 */
  private onBodyTap(): void {
    if (this.expanded) {
      this.clearTimer();
      this.onTap();
    } else {
      this.expand();
    }
  }

  /**
   * 展开态胶囊的宽度（vp）。
   *
   * 之前这里是 `.width(this.expanded ? '100%' : DISC)`：百分比要沿着
   * Row → Column → 页面 Stack 一路回溯才能解析，而胶囊上还挂着 spring 动画，
   * 动画期间百分比是按旧尺寸算的，解析失败时就会停在某个中间值——
   * 表现出来就是"胶囊只有半截、内容被裁掉"（1.1.72 的实机截图）。
   * 直接按窗口宽度算成具体数值：左右各 16 的留边写死，宽度永远是
   * winW - 32，动画只是数字之间插值，不存在解析失败。
   */
  private pillW(): number {
    const w: number = this.winW > 0 ? this.winW : winWidth();
    return w - 32;
  }

  private progressWidth(): string {
    if (this.duration <= 0) {
      return '0%';
    }
    // 必须夹在 0~1：切歌瞬间偶尔会先拿到新的 duration、后拿到重置后的 position，
    // 用上一首的进度去比新歌的时长，比例可能好几倍——填充层会画到胶囊外面，
    // 就是截图里那块盖住封面的粉色方块
    let p: number = this.playPos / this.duration;
    if (p < 0) {
      p = 0;
    } else if (p > 1) {
      p = 1;
    }
    return (p * 100) + '%';
  }

  private lyricText(): string {
    return this.lyricLine.length > 0 ? this.lyricLine : this.artist;
  }

  @Builder
  private cover(size: number, radius: number) {
    if (this.coverUrl.length > 0) {
      Image(this.coverUrl)
        .width(size).height(size).borderRadius(radius).objectFit(ImageFit.Cover)
    } else {
      Column() {
        Text('♪')
          .fontSize(size * 0.5).fontFamily(APP_FONT)
          .fontColor(Theme.accent(this.isDark))
      }
      .width(size).height(size)
      .backgroundColor(Theme.surfaceAlt(this.isDark))
      .borderRadius(radius)
      .justifyContent(FlexAlign.Center)
    }
  }

  /** 收起态：一枚旋转的唱片，外缘一圈就是播放进度 */
  @Builder
  private disc() {
    Stack({ alignContent: Alignment.Center }) {
      // 黑胶盘面：封面之外留出一圈深色，是这个形态成不成立的关键
      Column()
        .width(DISC).height(DISC).borderRadius(DISC / 2)
        .backgroundColor(this.isDark ? '#2A2A33' : '#17171C')

      // 封面标签
      if (this.coverUrl.length > 0) {
        Image(this.coverUrl)
          .width(42).height(42).borderRadius(21)
          .objectFit(ImageFit.Cover)
          .border({ width: 0.6, color: '#26FFFFFF' })
          .rotate({ angle: this.spinAngle })
          .animation({ duration: SPIN_TICK + 20, curve: Curve.Linear })
      } else {
        Column() {
          Text('♪')
            .fontSize(17).fontFamily(APP_FONT)
            .fontColor(Theme.accent(this.isDark))
        }
        .width(42).height(42).borderRadius(21)
        .backgroundColor(Theme.surfaceAlt(this.isDark))
        .justifyContent(FlexAlign.Center)
      }

      // 中心轴孔
      Circle({ width: 6, height: 6 })
        .fill('#99000000')
        .stroke('#4DFFFFFF')
        .strokeWidth(1)
    }
    .width(DISC).height(DISC)
  }

  /** 被动暂停的原因气泡：音乐突然停了，得让人知道是谁停的 */
  @Builder
  pauseBubble() {
    Row() {
      Image($r('app.media.ic_pause'))
        .width(10).height(10)
        .fillColor('#EDEDF5')
        .opacity(0.65)
      Text(this.pauseReason)
        .fontSize(11).fontFamily(APP_FONT)
        .fontColor('#EDEDF5')
        .maxLines(1)
        .margin({ left: 5 })
    }
    .padding({ left: 11, right: 11, top: 5, bottom: 5 })
    .borderRadius(12)
    .backgroundColor(this.isDark ? '#E62A2A32' : '#D94A4A54')
  }

  build() {
    if (this.title.length === 0) {
      Row().height(0)
    } else {
      // 位置这块这次重排过，原因是原来最外层是 height = DISC + 40 的 Stack：
      // 那 40vp 是给打断提示预留的，但提示实际画在胶囊"上面"，
      // 这 40vp 就白留在了胶囊"下面" —— 迷你条与导航条之间空出 50vp，
      // 滚动的内容正好从这条缝里露出来，两条看着像各自漂着、不成一体。
      // 现在改成 Column：提示有内容时自己占一行浮在胶囊上方，没有就完全不存在，
      // 胶囊下方不再有空白；左右留边统一 16，与底部导航条严格对齐（原来 12 vs 16）。
      Column() {
        // 打断提示：独立占一行 → 出现时整块向上长，胶囊本身的位置不动。
        // 不参与命中，不挡下面胶囊的点击
        if (this.pauseReason.length > 0) {
          Column() {
            this.pauseBubble()
          }
          .margin({ left: 16, right: 16, bottom: 6 })
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.translate({ y: 8 })
              .animation({ curve: curves.springMotion(0.3, 0.85) })
              .combine(TransitionEffect.opacity(0).animation({ duration: 140 })),
            TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseIn })))
          .hitTestBehavior(HitTestMode.None)
        }

          Row() {
            Stack({ alignContent: Alignment.Start }) {
            // 胶囊底色：不做毛玻璃，直接给近乎不透明的实色 + 阴影立起来。
            //
            // 之前那层「半透明 + backdropBlur」有两个问题：
            // ① 背景模糊根本没有生效（胶囊外层有 clip + 圆角，子层的 backdrop
            //    采样不到页面内容），于是列表里压在胶囊下方的歌名/歌手就透上来，
            //    和胶囊自己的歌名/歌词错开十几像素叠在一起——看上去就是
            //    「上一首还在，重影」；
            // ② 毛玻璃那层离屏合成在切歌时也不可靠，本身就可能留残影。
            // 95% 不透明度下，背后的黑字只剩 5% 的对比，肉眼看不见；
            // 磨砂那点质感在这个不透明度下本来也已经看不出来了。
            if (this.expanded) {
              // 进度填充层：占满胶囊高度，宽度 = 播放进度。
              // 高度用 100% 而不是常量，跟着容器一起变，展开动画中途不会多出一截
              Row()
                .width(this.progressWidth())
                .height('100%')
                .backgroundColor(this.isDark ? '#52FF6470' : '#40F0455A')

              Row() {
                this.cover(40, 10)

                Column() {
                  // 标题与歌词都用 ForEach 包一层，key 里带上文本内容本身。
                  // 字符串一变，旧节点被销毁、新节点重建——即使离屏层里还留着
                  // 上一帧的像素，也是一次「删节点 + 建节点」的完整重绘，
                  // 不会像原地改 Text 内容那样，旧字形赖在同一块区域里不出来。
                  // 代价只有两个小 Text 的增删，忽略不计。
                  ForEach([this.loading ? '加载中…' : this.title], (t: string) => {
                    Text(t)
                      .fontSize(14).fontFamily(APP_FONT).fontWeight(FontWeight.Medium)
                      .fontColor(Theme.text(this.isDark))
                      // 宽度必须撑满：Text 默认按内容宽度排版，切歌时新标题更短，
                      // 旧的较长文字就有一截落在这块「没有重绘」的区域里
                      .width('100%')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }, (t: string) => 'mt#' + t)

                  // 有同步歌词时第二行显示当前歌词行，否则显示歌手
                  ForEach([this.lyricText()], (s: string) => {
                    Text(s)
                      .fontSize(12).fontFamily(APP_FONT)
                      .fontColor(this.lyricLine.length > 0
                        ? Theme.accent(this.isDark)
                        : Theme.textSecondary(this.isDark))
                      .width('100%')
                      .maxLines(1)
                      // 这里原来用 MARQUEE。跑马灯内部会摆两份文本做无缝滚动，
                      // 宽度没撑满时两份会叠在同一点上；迷你条空间本来就窄，
                      // 改成截断更稳，完整歌词在播放页里看
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 2 })
                  }, (s: string) => 'ml#' + s)
                }
                .layoutWeight(1)
                .margin({ left: 10, right: 10 })
                .alignItems(HorizontalAlign.Start)

                // 上一首
                Stack() {
                  Image((this.isDark ? $r('app.media.ic_prev') : $r('app.media.ic_prev_d')))
                    .width(20).height(20)
                }
                .animation({ duration: 140, curve: Curve.EaseOut })
                .width(BTN).height(BTN).borderRadius(BTN / 2)
                .backgroundColor(this.isDark ? '#1FFFFFFF' : '#12000000')
                .margin({ left: 8 })
                .onClick(() => {
                  Store.get().player().prev();
                })

                // 播放 / 暂停
                Stack() {
                  Image(this.playing
                    ? (this.isDark ? $r('app.media.ic_pause') : $r('app.media.ic_pause_d'))
                    : (this.isDark ? $r('app.media.ic_play') : $r('app.media.ic_play_d')))
                    .width(20).height(20)
                    // 图标本身也做一次极短过渡：播放/暂停互切时不闪
                    .animation({ duration: 140, curve: Curve.EaseOut })
                }
                .animation({ duration: 140, curve: Curve.EaseOut })
                .width(BTN).height(BTN).borderRadius(BTN / 2)
                .backgroundColor(this.isDark ? '#1FFFFFFF' : '#12000000')
                // 三个圆钮靠同一个 8vp 左间距等距排开（只给两侧加会导致上一首与播放键贴死）
                .margin({ left: 8 })
                .onClick(() => {
                  Store.get().player().togglePlayPause();
                })

                // 下一首
                Stack() {
                  Image((this.isDark ? $r('app.media.ic_next') : $r('app.media.ic_next_d')))
                    .width(20).height(20)
                }
                .animation({ duration: 140, curve: Curve.EaseOut })
                .width(BTN).height(BTN).borderRadius(BTN / 2)
                .backgroundColor(this.isDark ? '#1FFFFFFF' : '#12000000')
                .margin({ left: 8 })
                .onClick(() => {
                  Store.get().player().next();
                })

                // 播放队列：交给页面打开队列弹层（迷你条自己不持有弹层）
                Stack() {
                  Image((this.isDark ? $r('app.media.ic_queue') : $r('app.media.ic_queue_d')))
                    .width(19).height(19)
                }
                .animation({ duration: 140, curve: Curve.EaseOut })
                .width(BTN).height(BTN).borderRadius(BTN / 2)
                .backgroundColor(this.isDark ? '#1FFFFFFF' : '#12000000')
                .margin({ left: 8 })
                .onClick(() => {
                  this.onOpenQueue();
                })
              }
              .width(this.expanded ? this.pillW() : DISC)
              .height(DISC)
              .padding({ left: 10, right: 12 })
              .alignItems(VerticalAlign.Center)
            } else {
              // 收起态：唱片
              this.disc()
            }
          }
          .width(this.expanded ? this.pillW() : DISC)
          .height(DISC)
          .borderRadius(this.expanded ? 20 : DISC / 2)
          .clip(true)
          // 95% 不透明：背后的列表文字透不上来（见上方注释），
          // 又比纯白/纯黑多一点点空气感，不至于像一块贴纸
          .backgroundColor(this.isDark ? '#F2232330' : '#F2FFFFFF')
          .border({ width: this.expanded ? 0.8 : 1, color: this.expanded ? Theme.divider(this.isDark) : '#33FFFFFF' })
          .shadow({ radius: 18, color: this.isDark ? '#99000000' : '#1F000000', offsetY: 4 })
          // 圆碟 ↔ 长条之间的变形不再挂 .animation()：
          // 补间改由 setExpanded() 里的 animateTo 负责（理由见那个方法）。
          // 这里挂隐式动画会把子树的内容变化一起卷进去，导致切歌重影。
          // 从播放页返回时组件不会重建（aboutToAppear 不再触发），
          // 靠可见性变化补一次「回到首页后自动收起」
          .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean) => {
            if (isVisible && this.expanded && this.playing) {
              this.armCollapse(COLLAPSE_AFTER_PLAY);
            }
          })
          .onClick(() => {
            this.onBodyTap();
          })
          .gesture(
            LongPressGesture({ repeat: false, duration: 420 })
              .onAction(() => {
                this.collapse();
              })
          )
        }
        .width(this.pillW() + 32)
        .padding({ left: 16, right: 16 })
        // 智感握姿：左手握持时收起的唱片移到左下角，右手时右下角
        .justifyContent(this.gripHand === 'left' ? FlexAlign.Start : FlexAlign.End)
      }
      .width(this.pillW() + 32)
      // 提示与胶囊的横向对齐跟着形态走：展开态靠左（与胶囊左边缘齐），
      // 收起态靠右（与唱片右边缘齐）。左右 16 的留边由子元素自身的 margin / padding 给出
      .alignItems(this.expanded ? HorizontalAlign.Start : HorizontalAlign.End)
    }
  }
}
