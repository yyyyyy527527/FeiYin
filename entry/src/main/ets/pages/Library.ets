import { Track, WebDavEntry } from '../model/Models';
import { APP_FONT, APP_FONT_BOLD } from '../utils/Fonts';
import { Store } from '../store/Store';
import { Router } from '../utils/Router';
import { Theme, Fmt, toast, topInset, bottomInset } from '../utils/Theme';
import { MiniPlayer } from '../components/MiniPlayer';
import { Motion } from '../utils/Motion';

@Entry
@Component
struct Library {
  @StorageProp('isDark') private isDark: boolean = true;
  @State private entries: WebDavEntry[] = [];
  @State private tracks: Track[] = [];
  @State private currentPath: string = '/';
  @State private breadcrumbs: string[] = [];
  @State private loading: boolean = true;
  @State private error: string = '';
  @State private searchKeyword: string = '';

  aboutToAppear(): void {
    const cfg = Store.get().serverConfig;
    if (cfg === null) {
      Router.replace('pages/Setup');
      return;
    }
    this.currentPath = cfg.rootPath || '/';
    this.breadcrumbs = ['根目录'];
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.error = '';
    try {
      const res = await Store.get().scanFolder(this.currentPath);
      this.entries = res.folders;
      this.tracks = res.tracks;
      if (this.tracks.length === 0 && this.entries.length === 0) {
        this.error = '此文件夹为空';
      }
    } catch (err) {
      this.error = err instanceof Error ? err.message : String(err);
    }
    this.loading = false;
  }

  private async openFolder(entry: WebDavEntry): Promise<void> {
    this.currentPath = entry.href;
    this.breadcrumbs.push(entry.displayName);
    await this.load();
  }

  private async goBreadcrumb(idx: number): Promise<void> {
    if (idx === this.breadcrumbs.length - 1) return;
    this.breadcrumbs = this.breadcrumbs.slice(0, idx + 1);
    if (idx === 0) {
      this.currentPath = Store.get().serverConfig?.rootPath || '/';
    } else {
      // 根据面包屑路径重建
      const cfg = Store.get().serverConfig;
      const root = cfg?.rootPath || '/';
      let path = root;
      for (let i = 1; i <= idx; i++) {
        // 查找匹配的条目
      }
      this.currentPath = path;
    }
    await this.load();
  }

  private playTrack(idx: number): void {
    if (this.tracks.length === 0) return;
    Store.get().player().playQueue(this.tracks, idx);
    toast('开始播放：' + this.tracks[idx].title);
  }

  private playAll(): void {
    if (this.tracks.length === 0) {
      toast('当前文件夹没有音乐文件');
      return;
    }
    this.playTrack(0);
  }

  private filteredTracks(): Track[] {
    if (this.searchKeyword.length === 0) {
      return this.tracks;
    }
    const kw: string = this.searchKeyword.toLowerCase();
    return this.tracks.filter((t: Track) =>
      t.title.toLowerCase().indexOf(kw) >= 0 || t.artist.toLowerCase().indexOf(kw) >= 0);
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
    Column() {
      // 顶部栏
      Row() {
        Text('星籁')
          .fontSize(22).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Bold).fontColor(Theme.text(this.isDark))
          .letterSpacing(2)
        Row().layoutWeight(1)
        Image((this.isDark ? $r('app.media.ic_settings') : $r('app.media.ic_settings_d')))
          .width(24).height(24)
          .onClick(() => { Router.push('pages/Settings'); })
      }
      .width('100%')
      .height(52)
      .padding({ left: 20, right: 20, top: topInset() })
      .backgroundColor(Theme.bg(this.isDark))

      // 面包屑 + 搜索
      Column() {
        // 面包屑
        Scroll() {
          Row() {
            ForEach(this.breadcrumbs, (crumb: string, idx: number) => {
              Text(crumb)
                .fontSize(13).fontFamily(APP_FONT).fontColor(idx === this.breadcrumbs.length - 1 ? Theme.text(this.isDark) : Theme.textSecondary(this.isDark))
                .maxLines(1)
                .onClick(() => { this.goBreadcrumb(idx); })
              if (idx < this.breadcrumbs.length - 1) {
                Text('/')
                  .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                  .margin({ left: 6, right: 6 })
              }
            })
          }
          .padding({ left: 20, right: 20 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(28)

        // 搜索框
        Row() {
          Image((this.isDark ? $r('app.media.ic_search') : $r('app.media.ic_search_d'))).width(16).height(16).opacity(0.4)
          TextInput({ text: this.searchKeyword, placeholder: '搜索当前文件夹' })
            .layoutWeight(1)
            .height(36)
            .backgroundColor(Color.Transparent)
            .placeholderColor('#5A5A64')
            .fontSize(13).fontFamily(APP_FONT)
            .fontColor(Theme.text(this.isDark))
            .onChange((v: string) => { this.searchKeyword = v; })
          if (this.tracks.length > 0) {
            Text('全部播放')
              .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
              .onClick(() => { this.playAll(); })
          }
        }
        .width('100%')
        .height(40)
        .padding({ left: 12, right: 12 })
        .backgroundColor(Theme.surface(this.isDark))
        .borderRadius(12)
        .margin({ left: 20, right: 20, top: 4 })
      }
      .width('100%')
      .margin({ bottom: 8 })

      // 内容区
      if (this.loading) {
        Column() {
          LoadingProgress().width(32).height(32).color(Theme.accent(this.isDark))
          Text('正在读取 NAS 目录…')
            .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
            .margin({ top: 10 })
        }
        .width('100%').layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0 && this.entries.length === 0 && this.tracks.length === 0) {
        Column() {
          Image((this.isDark ? $r('app.media.ic_nas') : $r('app.media.ic_nas_d'))).width(40).height(40).opacity(0.3)
          Text(this.error)
            .fontSize(14).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
            .margin({ top: 12 })
          Button('重新连接')
            .fontFamily(APP_FONT)
            .margin({ top: 16 })
            .onClick(() => { this.load(); })
        }
        .width('100%').layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          // 文件夹
          if (this.searchKeyword.length === 0) {
            ForEach(this.entries, (entry: WebDavEntry) => {
              ListItem() {
                Row() {
                  Image((this.isDark ? $r('app.media.ic_folder') : $r('app.media.ic_folder_d'))).width(22).height(22).opacity(0.6)
                  Text(entry.displayName)
                    .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
                    .layoutWeight(1)
                    .margin({ left: 14 })
                  Image((this.isDark ? $r('app.media.ic_back') : $r('app.media.ic_back_d'))).width(16).height(16).opacity(0.3)
                    .rotate({ angle: 180 })
                }
                .width('100%')
                .height(54)
                .padding({ left: 20, right: 20 })
                .alignItems(VerticalAlign.Center)
                .onClick(() => { this.openFolder(entry); })
              }
            })
          }

          // 音乐文件
          ForEach(this.filteredTracks(), (track: Track, idx: number) => {
            ListItem() {
              TrackRowItem({ track: track, index: idx })
            }
            .onClick(() => {
              const filtered = this.filteredTracks();
              const realIdx = this.tracks.indexOf(filtered[idx]);
              if (realIdx >= 0) {
                this.playTrack(realIdx);
              }
            })
          })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .divider({ color: Theme.divider(this.isDark), strokeWidth: 0.5, startMargin: 56, endMargin: 20 })
      }

      // MiniPlayer（悬浮胶囊：底部留出手势区 + 额外呼吸间距）
      MiniPlayer({ onTap: () => { Router.push('pages/NowPlaying'); } })
        .margin({ bottom: bottomInset() + 30 })
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.bg(this.isDark))
  }
}

@Component
struct TrackRowItem {
  @StorageProp('isDark') private isDark: boolean = true;
  @Prop track: Track;
  @Prop index: number;
  @StorageLink('playerTitle') private currentTitle: string = '';

  build() {
    Row() {
      // 序号或播放指示
      if (this.currentTitle === this.track.title) {
        Image($r('app.media.ic_play'))
          .width(16).height(16)
          .fillColor(Theme.accent(this.isDark))
      } else {
        Text(String(this.index + 1))
          .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
          .width(20)
          .textAlign(TextAlign.Center)
      }

      Column() {
        Text(this.track.title)
          .fontSize(14).fontFamily(APP_FONT).fontColor(this.currentTitle === this.track.title ? Theme.accent(this.isDark) : Theme.text(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Text(this.track.artist)
            .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
          Text('·').fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark)).margin({ left: 4, right: 4 })
          Text(Fmt.size(this.track.size))
            .fontSize(11).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
          if (this.track.cached) {
            Image((this.isDark ? $r('app.media.ic_downloaded') : $r('app.media.ic_downloaded_d'))).width(12).height(12).margin({ left: 6 })
          }
        }
        .margin({ top: 2 })
      }
      .layoutWeight(1)
      .margin({ left: 12 })
      .alignItems(HorizontalAlign.Start)

      if (this.track.duration > 0) {
        Text(Fmt.time(this.track.duration))
          .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 20, right: 20 })
    .alignItems(VerticalAlign.Center)
  }
}
