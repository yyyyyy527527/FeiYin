import { curves } from '@kit.ArkUI';
import { Track, Album } from '../model/Models';
import { APP_FONT } from '../utils/Fonts';
import { Theme, Fmt } from '../utils/Theme';

/**
 * 列表行的三种展示形态（专辑格、歌曲行、首页网格歌曲格）。
 *
 * 单独拆出来的原因：SubsonicLibrary.ets 已经三千多行，
 * 这三个是纯叶子组件——只读 props 和主题，不碰页面状态，
 * 放在页面文件里只是占地方，拆出来也不影响任何调用方。
 */

@Component
export struct AlbumCell {
  @StorageProp('isDark') private isDark: boolean = true;
  @Prop album: Album;
  @Prop coverUrl: string;
  /** 紧凑模式：四列小封面用，字号与圆角同步收一档 */
  @Prop compact: boolean = false;

  build() {
    Column() {
      if (this.coverUrl.length > 0) {
        Image(this.coverUrl)
          .width('100%')
          .aspectRatio(1)
          .borderRadius(this.compact ? 7 : 10)
          .objectFit(ImageFit.Cover)
      } else {
        Column() {
          Image($r('app.media.app_icon')).width(32).height(32)
        }
        .width('100%')
        .aspectRatio(1)
        .borderRadius(this.compact ? 7 : 10)
        .backgroundColor(Theme.surfaceAlt(this.isDark))
        .justifyContent(FlexAlign.Center)
      }
      Text(this.album.name)
        .fontSize(this.compact ? 11 : 12).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
        .maxLines(this.compact ? 1 : 2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: this.compact ? 5 : 6 })
        .width('100%')
      Text(this.album.artist)
        .fontSize(this.compact ? 9.5 : 11).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 })
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct SongRow {
  @StorageProp('isDark') private isDark: boolean = true;
  @Prop track: Track;
  @Prop index: number;
  @Prop coverUrl: string;
  /** 是否在行尾显示收藏爱心（「喜爱的歌」列表用，随时可取消） */
  @Prop showLike: boolean = false;
  @Prop liked: boolean = false;
  onToggleLike: () => void = () => {};
  @StorageLink('playerTitle') private currentTitle: string = '';
  /** 按下态：手指压住时整行轻微压暗，松手回弹。没有这个，点击像「没反应」 */
  @State private pressed: boolean = false;

  build() {
    Row() {
      if (this.coverUrl.length > 0) {
        Image(this.coverUrl)
          .width(44).height(44).borderRadius(8).objectFit(ImageFit.Cover)
      } else {
        Column() {
          Text(String(this.index + 1))
            .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
        }
        .width(44).height(44).borderRadius(8)
        .backgroundColor(Theme.surfaceAlt(this.isDark))
        .justifyContent(FlexAlign.Center)
      }

      Column() {
        Text(this.track.title)
          .fontSize(14).fontFamily(APP_FONT)
          .fontColor(this.currentTitle === this.track.title ? Theme.accent(this.isDark) : Theme.text(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Text(this.track.artist)
            .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
          if (this.track.bitRate > 0) {
            Text(this.track.suffix.toUpperCase() + ' ' + this.track.bitRate)
              .fontSize(10).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
              .margin({ left: 6 })
          }
        }
        .width('100%')
        .margin({ top: 2 })
      }
      .layoutWeight(1)
      .margin({ left: 12 })
      .alignItems(HorizontalAlign.Start)

      if (this.track.duration > 0) {
        Text(Fmt.time(this.track.duration))
          .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
      }

      if (this.showLike) {
        Image(this.liked ?
          (this.isDark ? $r('app.media.ic_heart_f') : $r('app.media.ic_heart_f_d')) :
          (this.isDark ? $r('app.media.ic_heart') : $r('app.media.ic_heart_d')))
          .width(20).height(20)
          .margin({ left: 12 })
          // 图标只有 20，热区放大到 40，避免点在缝隙里没反应
          .responseRegion({ x: -10, y: -10, width: 40, height: 40 })
          .onClick(() => { this.onToggleLike(); })
      }
    }
    .width('100%')
    .height(60)
    .padding({ left: 20, right: 20 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.pressed
      ? (this.isDark ? '#14FFFFFF' : '#0D000000')
      : '#00000000')
    // 按下用 0 时长瞬时生效（要跟手指同步，慢了会觉得迟滞），
    // 松手用 spring 柔和退回，避免「啪」一下跳回去。
    .animation(this.pressed
      ? { duration: 0 }
      : { curve: curves.springMotion(0.28, 0.9) })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressed = true;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
  }
}

/**
 * 首页 2×2 网格里的歌曲单元格：小方封面 + 歌名 + 歌手 + 简写音质 + 右侧红心。
 * 单元格只有半屏宽，所以音质行用「格式 · 时长」简写，完整参数留给播放页。
 */
@Component
export struct HomeSongRow {
  @StorageProp('isDark') private isDark: boolean = true;
  @StorageLink('playerTitle') private currentTitle: string = '';
  @Prop track: Track;
  @Prop coverUrl: string;
  @Prop liked: boolean;
  onToggle: () => void = () => {};

  /** 音质行简写：FLAC · 02:49 */
  private qualityText(): string {
    const parts: string[] = [];
    const ext: string = this.track.suffix.toUpperCase();
    if (ext.length > 0) {
      parts.push(ext);
    }
    if (this.track.duration > 0) {
      const total: number = Math.floor(this.track.duration / 1000);
      const min: number = Math.floor(total / 60);
      const sec: number = total % 60;
      parts.push((min < 10 ? '0' + min.toString() : min.toString()) + ':' +
        (sec < 10 ? '0' + sec.toString() : sec.toString()));
    }
    return parts.join(' · ');
  }

  build() {
    Row() {
      if (this.coverUrl.length > 0) {
        Image(this.coverUrl)
          .width(42).height(42).borderRadius(8).objectFit(ImageFit.Cover)
      } else {
        Column() {
          Image($r('app.media.app_icon')).width(20).height(20)
        }
        .width(42).height(42).borderRadius(8)
        .backgroundColor(Theme.surfaceAlt(this.isDark))
        .justifyContent(FlexAlign.Center)
      }

      Column() {
        Text(this.track.title)
          .fontSize(13).fontFamily(APP_FONT)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.currentTitle === this.track.title ? Theme.accent(this.isDark) : Theme.text(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.track.artist)
          .fontSize(10.5).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 }).width('100%')
        Text(this.qualityText())
          .fontSize(9.5).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 }).width('100%')
      }
      .layoutWeight(1)
      .margin({ left: 10 })
      .alignItems(HorizontalAlign.Start)

      Image(this.liked ?
        (this.isDark ? $r('app.media.ic_heart_f') : $r('app.media.ic_heart_f_d')) :
        (this.isDark ? $r('app.media.ic_heart') : $r('app.media.ic_heart_d')))
        .width(16).height(16)
        .margin({ left: 8 })
        .padding(0)
        // 图标只有 16，热区放大到 36 才好点
        .responseRegion({ x: -10, y: -10, width: 36, height: 36 })
        .onClick(() => { this.onToggle(); })
    }
    .width('100%')
    .height(58)
    .alignItems(VerticalAlign.Center)
  }
}

/** 多人合唱取主歌手：「阿吉太组合、DJ沈念」→「阿吉太组合」 */
