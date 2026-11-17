import { Playlist } from '../model/Models';
import { APP_FONT, APP_FONT_BOLD } from '../utils/Fonts';
import { Theme, Fmt } from '../utils/Theme';
import { Motion } from '../utils/Motion';

/**
 * 歌单相关的一组组件与弹层。
 * 单独拆文件是因为 SubsonicLibrary.ets 已经 1500 多行，
 * 歌单的封面拼图、格子、选歌弹层都自成一套。
 */

/**
 * 歌单封面：Subsonic 的 playlist 有自己的 coverArt；
 * 没有时用前 4 首歌的封面拼成 2×2，这也是音乐类 App 的通行做法。
 */
@Component
export struct PlaylistCover {
  @StorageProp('isDark') private isDark: boolean = true;
  /**
   * 封面 URL，最多四个，按顺序填左上、右上、左下、右下。
   * 用普通成员而不是 @Prop：@Prop 对数组做的是深拷贝，封面是异步分批补进来的，
   * 每次都要整组重新拷一遍，列表长了很浪费。
   */
  covers: string[] = [];
  @Prop boxSize: number = 56;
  @Prop radius: number = 10;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.covers.length === 0) {
        // 一首歌都没有的空歌单：音符占位
        Column() {
          Image(this.isDark ? $r('app.media.ic_list') : $r('app.media.ic_list_d'))
            .width(this.boxSize * 0.42).height(this.boxSize * 0.42).opacity(0.55)
        }
        .width('100%').height('100%')
        .backgroundColor(Theme.surfaceAlt(this.isDark))
        .justifyContent(FlexAlign.Center)
      } else if (this.covers.length === 1) {
        Image(this.covers[0])
          .width('100%').height('100%').objectFit(ImageFit.Cover)
      } else {
        Column() {
          Row() {
            this.quad(0)
            this.quad(1)
          }
          .layoutWeight(1)
          Row() {
            this.quad(2)
            this.quad(3)
          }
          .layoutWeight(1)
        }
        .width('100%').height('100%')
      }
    }
    .width(this.boxSize).height(this.boxSize)
    .borderRadius(this.radius)
    .clip(true)
    .backgroundColor(Theme.surfaceAlt(this.isDark))
  }

  /** 拼图的一格：不足四张时用底色补齐，避免右下角塌陷 */
  @Builder
  private quad(i: number) {
    if (i < this.covers.length) {
      Image(this.covers[i])
        .layoutWeight(1).height('100%').objectFit(ImageFit.Cover)
        .border({
          width: 0.5,
          color: this.isDark ? '#33000000' : '#1A000000'
        })
    } else {
      Column()
        .layoutWeight(1).height('100%')
        .backgroundColor(Theme.surfaceAlt(this.isDark))
    }
  }
}

/** 歌单列表里的一格（一行一个，横向排布） */
@Component
export struct PlaylistRow {
  @StorageProp('isDark') private isDark: boolean = true;
  @Prop playlist: Playlist;
  /** 同 PlaylistCover.covers，用普通成员避免数组深拷贝 */
  covers: string[] = [];
  onTap: () => void = () => {};
  onMore: () => void = () => {};

  build() {
    Row() {
      PlaylistCover({ covers: this.covers, boxSize: 56, radius: 10 })

      Column() {
        Row() {
          Text(this.playlist.name)
            .fontSize(14.5).fontFamily(APP_FONT)
            .fontColor(Theme.text(this.isDark))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
          // 只读标记：别人的歌单 / 智能歌单不能改
          if (!this.playlist.editable) {
            Text('只读')
              .fontSize(9).fontFamily(APP_FONT)
              .fontColor(Theme.textTertiary(this.isDark))
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(4)
              .border({ width: 0.7, color: Theme.divider(this.isDark) })
              .margin({ left: 6 })
          }
        }
        .width('100%')
        Text(this.metaText())
          .fontSize(11.5).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 }).width('100%')
      }
      .layoutWeight(1)
      .margin({ left: 12 })
      .alignItems(HorizontalAlign.Start)

      Stack({ alignContent: Alignment.Center }) {
        Image(this.isDark ? $r('app.media.ic_more') : $r('app.media.ic_more_d'))
          .width(18).height(18).opacity(0.6)
      }
      .width(34).height(34)
      .onClick(() => { this.onMore(); })
    }
    .width('100%')
    .padding({ left: 20, right: 12, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => { this.onTap(); })
  }

  /** 副标题：曲目数 · 总时长 */
  private metaText(): string {
    const n: string = this.playlist.songCount > 0
      ? this.playlist.songCount.toString() + ' 首' : '空歌单';
    if (this.playlist.duration > 0) {
      return n + ' · ' + Fmt.durationCn(this.playlist.duration);
    }
    return n;
  }
}

/** 弹层通用背景：半透明遮罩 + 底部面板 */
@Component
export struct SheetScrim {
  onClose: () => void = () => {};

  build() {
    Column()
      .width('100%').height('100%')
      .backgroundColor('#66000000')
      .onClick(() => { this.onClose(); })
  }
}

/** 新建 / 改名歌单的输入面板 */
@Component
export struct PlaylistNameSheet {
  @StorageProp('isDark') private isDark: boolean = true;
  /** 面板标题：新建歌单 / 重命名 */
  @Prop title: string = '新建歌单';
  @State private value: string = '';
  onSubmit: (name: string) => void = () => {};
  onClose: () => void = () => {};

  build() {
    Column() {
      Row() {
        Text('取消')
          .fontSize(14).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
          .onClick(() => { this.onClose(); })
        Row().layoutWeight(1)
        Text(this.title)
          .fontSize(15).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Medium)
          .fontColor(Theme.text(this.isDark))
        Row().layoutWeight(1)
        Text('确定')
          .fontSize(14).fontFamily(APP_FONT)
          .fontColor(this.value.trim().length > 0
            ? Theme.accent(this.isDark) : Theme.textTertiary(this.isDark))
          .onClick(() => {
            const v: string = this.value.trim();
            if (v.length > 0) {
              this.onSubmit(v);
            }
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 14 })
      .alignItems(VerticalAlign.Center)

      TextInput({ text: $$this.value, placeholder: '给歌单起个名字' })
        .height(44)
        .fontSize(15).fontFamily(APP_FONT)
        .fontColor(Theme.text(this.isDark))
        .placeholderColor(Theme.textTertiary(this.isDark))
        .backgroundColor(Theme.surfaceAlt(this.isDark))
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .margin({ left: 20, right: 20 })
        .maxLength(40)
        .onChange((v: string) => { this.value = v; })

      Column().height(20)
    }
    .width('100%')
    .backgroundColor(Theme.surface(this.isDark))
    .borderRadius({ topLeft: 20, topRight: 20 })
  }
}

/** 一个可勾选的选项行（选歌、选歌单共用） */
@Component
export struct CheckRow {
  @StorageProp('isDark') private isDark: boolean = true;
  @Prop title: string;
  @Prop subtitle: string = '';
  @Prop checked: boolean = false;
  onToggle: () => void = () => {};

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(14).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(11).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 }).width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(21).height(21).borderRadius(11)
          .backgroundColor(this.checked ? Theme.accent(this.isDark) : '#00000000')
          .border({ width: 1.5, color: this.checked ? Theme.accent(this.isDark) : Theme.textTertiary(this.isDark) })
          // 勾选是最高频的微动效：160ms 足够，再慢就显得"粘手"
          .animation(Motion.micro())
        if (this.checked) {
          // 对勾用两段圆角短棒拼成；不用图标资源，也不依赖 position/负角度
          Stack({ alignContent: Alignment.Center }) {
            Row() {
              Column()
                .width(3).height(6).borderRadius(1.5)
                .backgroundColor(Color.White)
                .rotate({ angle: -45 })
                .margin({ top: 3, left: 1 })
              Column()
                .width(3).height(10).borderRadius(1.5)
                .backgroundColor(Color.White)
                .rotate({ angle: 45 })
                .margin({ left: -1 })
            }
            .alignItems(VerticalAlign.Center)
          }
          .width(21).height(21)
          // 对勾不要"啪"地长出来：从 0.6 弹到 1，配一点回弹（damping 0.8）
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.scale({ x: 0.6, y: 0.6 })
              .animation(Motion.enter(0.22, 0.8))
              .combine(TransitionEffect.opacity(0).animation({ duration: 120, curve: Curve.FastOutSlowIn })),
            TransitionEffect.OPACITY.animation(Motion.exit(90))))
        }
      }
      .width(30).height(30)
    }
    .width('100%')
    .padding({ left: 20, right: 16, top: 11, bottom: 11 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => { this.onToggle(); })
  }
}
