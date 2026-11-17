import { Track, Album } from '../model/Models';
import { APP_FONT, APP_FONT_BOLD } from '../utils/Fonts';
import { Store } from '../store/Store';
import { Theme, toast, topInset, bottomInset } from '../utils/Theme';
import { AlbumCell, SongRow } from './TrackRows';
import { Motion } from '../utils/Motion';

/** 「全部歌曲」列表底部留白，与主页面保持一致，保证滚到底不被悬浮条压住 */
const BOTTOM_PAD: number = 192;
/** 多选操作条高度；列表末尾要为它额外让位 */
const PICK_BAR_H: number = 58;

/**
 * 搜索页。
 *
 * 从 SubsonicLibrary.ets 拆出来的：搜索自带一整组状态
 * （查询词、服务器原始结果、本地过滤结果、搜索历史、多选），
 * 与主页面的耦合只有三个出口——播放一首歌、打开专辑、把选中的歌拿去加歌单。
 * 拆开之后搜索的防抖、前缀判断、竞态保护都封在自己的组件里，
 * 改搜索不用再翻三千行的文件。
 *
 * 对外接口：
 *   onPlay(list, idx)  点某一首播放（传整份结果，播完能顺下去）
 *   onOpenAlbum(album) 点专辑进详情
 *   onBulkPick(ids)    多选完成，把选中的歌曲 id 交给主页面弹「加入歌单」
 *   onTrackMenu(track) 长按歌曲：走和「全部歌曲」同一张操作菜单
 *   onExit()           清空词条后按返回，回到主界面
 */
@Component
export struct SearchPage {
  @StorageProp('isDark') private isDark: boolean = true;

  /** 出口，由主页面注入 */
  onPlay: (list: Track[], idx: number) => void = () => {};
  onOpenAlbum: (a: Album) => void = () => {};
  onBulkPick: (ids: string[]) => void = () => {};
  /** 长按歌曲：交给主页面统一的长按菜单（下一首播放 / 加入队列 / 加入歌单 / 收藏 / 查看专辑歌手） */
  onTrackMenu: (t: Track) => void = () => {};

  /**
   * 搜索词。由主页面保管（@Link），不用 @State。
   *
   * 原因：搜索页是 if/else 的一个分支，一跳到专辑或歌手详情就会被销毁。
   * 词条留在组件里的话，从详情返回时搜索页重建、词条为空，用户看到的是
   * 一片空白的搜索页——刚搜出来的东西全没了。词条放到主页面，重建后能照原样恢复。
   */
  @Link q: string;

  // ---- 服务器原始结果（过滤前，保留全量） ----
  private remoteSongs: Track[] = [];
  private remoteAlbums: Album[] = [];
  /** 上一次真正问过服务器的词，用于判断「往回删字」时不必再请求 */
  private lastAsked: string = '';

  // ---- 展示用结果（过滤后） ----
  @State private results: Track[] = [];
  @State private albums: Album[] = [];
  @State private searching: boolean = false;

  @State private history: string[] = [];
  /** 本地过滤：默认开，敲字就有反应，不用等网络 */
  @State private localFilter: boolean = true;

  // ---- 多选 ----
  /** 与主页面共享：离开搜索页时主页面置 false，这里跟着清空勾选 */
  @Link @Watch('onPickModeChange') pickMode: boolean;
  @State private picked: string[] = [];

  private searchTimer: number = -1;

  aboutToAppear(): void {
    this.history = Store.get().searchHistory();
    // 从「查看专辑 / 查看歌手」返回时这个组件会被重建：词条由主页面保管，
    // 按它把结果重新拉一遍，返回后还停在原来那次搜索上。
    const w: string = this.q.trim();
    if (w.length > 0) {
      this.runSearch(w, true);
    }
  }

  aboutToDisappear(): void {
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
  }

  /** pickMode 由外部置 false（离开搜索页）时，顺手清掉残留勾选 */
  private onPickModeChange(): void {
    if (!this.pickMode && this.picked.length > 0) {
      this.picked = [];
    }
  }

  private topPad(): number {
    return topInset() + 10;
  }

  private cover(coverArt: string, size: number): string {
    const c = Store.get().subsonicClient();
    if (c === null || coverArt.length === 0) {
      return '';
    }
    return c.coverUrl(coverArt, size);
  }

  @Builder
  private emptyState(icon: Resource, text: string) {
    Column() {
      Image(icon).width(38).height(38).opacity(0.3)
      Text(text)
        .fontSize(13).fontFamily(APP_FONT)
        .fontColor(Theme.textSecondary(this.isDark))
        .margin({ top: 12 })
    }
    .width('100%').layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 输入变化：两段式。
   * 1) 立刻用本地缓存的结果过滤，敲字就有反应，不等网络；
   * 2) 400ms 防抖后，只在「服务器还没搜过这个词」时才真正发请求，
   *    只是往回删字（新词是旧词前缀）就不再打服务器。
   */
  private onQueryChanged(v: string): void {
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    const word: string = v.trim();
    if (word.length === 0) {
      this.remoteSongs = [];
      this.remoteAlbums = [];
      this.lastAsked = '';
      this.albums = [];
      this.results = [];
      this.searching = false;
      return;
    }
    if (this.localFilter && this.remoteSongs.length + this.remoteAlbums.length > 0) {
      this.applyLocalFilter(word);
    }
    if (this.localFilter && this.lastAsked.length > 0 && this.lastAsked.indexOf(word) === 0) {
      this.searching = false;
      return;
    }
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      this.runSearch(word);
    }, 400);
  }

  /** 在服务器结果上做关键词过滤：歌名 / 歌手 / 专辑任一命中即可 */
  private applyLocalFilter(word: string): void {
    const kw: string = word.toLowerCase();
    const songs: Track[] = [];
    for (const t of this.remoteSongs) {
      if (t.title.toLowerCase().indexOf(kw) >= 0
        || t.artist.toLowerCase().indexOf(kw) >= 0
        || t.album.toLowerCase().indexOf(kw) >= 0) {
        songs.push(t);
      }
    }
    const als: Album[] = [];
    for (const a of this.remoteAlbums) {
      if (a.name.toLowerCase().indexOf(kw) >= 0
        || a.artist.toLowerCase().indexOf(kw) >= 0) {
        als.push(a);
      }
    }
    this.results = songs;
    this.albums = als;
    // 结果集变了，之前的勾选可能已不在列表里
    if (this.picked.length > 0) {
      this.picked = [];
    }
  }

  private async runSearch(word0: string, force: boolean = false): Promise<void> {
    const word: string = word0.trim();
    if (word.length === 0) {
      return;
    }
    if (!force && word === this.lastAsked
      && this.remoteSongs.length + this.remoteAlbums.length > 0) {
      this.applyLocalFilter(word);
      return;
    }
    this.searching = true;
    this.lastAsked = word;
    try {
      const r = await Store.get().search(word);
      this.remoteSongs = r.songs;
      this.remoteAlbums = r.albums;
      // 竞态保护：返回时输入已经变了就不覆盖界面（原始结果仍留着给过滤用）
      if (word !== this.q.trim()) {
        this.searching = false;
        return;
      }
      this.albums = r.albums;
      this.results = r.songs;
      if (this.picked.length > 0) {
        this.picked = [];
      }
      // 真正提交且有结果的关键词才记进历史；打字中途的每个前缀不记
      if (r.songs.length + r.albums.length > 0) {
        await Store.get().addSearchHistory(word);
        this.history = Store.get().searchHistory();
      }
    } catch (err) {
      toast('搜索失败');
    }
    this.searching = false;
  }

  /** 点历史词条：填进输入框并直接搜 */
  private useHistoryWord(w: string): void {
    this.q = w;
    this.runSearch(w, true);
  }

  private async removeHistoryWord(w: string): Promise<void> {
    await Store.get().removeSearchHistory(w);
    this.history = Store.get().searchHistory();
  }

  private async clearAllHistory(): Promise<void> {
    await Store.get().clearSearchHistory();
    this.history = [];
    toast('已清空搜索历史');
  }

  // ---------- 多选 ----------

  private exitPickMode(): void {
    this.pickMode = false;
    this.picked = [];
  }

  private togglePick(id: string): void {
    const arr: string[] = this.picked.slice(0);
    const i: number = arr.indexOf(id);
    if (i >= 0) {
      arr.splice(i, 1);
    } else {
      arr.push(id);
    }
    this.picked = arr;
  }

  private togglePickAll(): void {
    if (this.picked.length === this.results.length) {
      this.picked = [];
    } else {
      const all: string[] = [];
      for (const t of this.results) {
        all.push(t.id);
      }
      this.picked = all;
    }
  }

  private allChecked(): boolean {
    return this.results.length > 0 && this.picked.length === this.results.length;
  }

  /** 搜索页顶部：搜索输入框，跟随内容滚动，不覆盖列表。返回走系统侧滑手势 */
  @Builder
  private searchInlineHeader() {
    Row() {
      TextInput({
        text: $$this.q,
        placeholder: '搜索歌曲、专辑'
      })
        .layoutWeight(1)
        .height(40)
        .borderRadius(20)
        .backgroundColor(Theme.surfaceAlt(this.isDark))
        .fontColor(Theme.text(this.isDark))
        .placeholderColor(Theme.textTertiary(this.isDark))
        .placeholderFont({ size: 14 })
        .caretColor(Theme.accent(this.isDark))
        .fontSize(14).fontFamily(APP_FONT)
        .enterKeyType(EnterKeyType.Search)
        // 刚从别的页面返回、带着词条重建时不抢焦点：
        // 一聚焦就会弹键盘，挡住刚刚恢复的搜索结果。
        .defaultFocus(this.q.length === 0)
        .onChange((v: string) => { this.onQueryChanged(v); })
        .onSubmit(() => {
          const q: string = this.q.trim();
          if (q.length > 0) {
            this.runSearch(q);
          }
        })

      // 有搜索结果时才给多选入口
      if (this.results.length > 0) {
        Text(this.pickMode ? '完成' : '选择')
          .fontSize(14).fontFamily(APP_FONT)
          .fontColor(this.pickMode ? Theme.accent(this.isDark) : Theme.textSecondary(this.isDark))
          .padding({ left: 12 })
          .onClick(() => {
            if (this.pickMode) {
              this.exitPickMode();
            } else {
              this.pickMode = true;
              this.picked = [];
            }
          })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: this.topPad(), bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  /** 搜索结果：搜索条固定在顶部（不在分支里），结果区单独切换，输入焦点不会丢 */
  @Builder
  private searchBody() {
    Column() {
      this.searchInlineHeader()

      Column() {
        if (this.q.trim().length === 0) {
          if (this.history.length > 0) {
            this.searchHistoryBody()
          } else {
            this.emptyState((this.isDark ? $r('app.media.ic_search') : $r('app.media.ic_search_d')),
              '输入关键词搜索歌曲与专辑')
          }
        } else if (this.searching && this.results.length === 0 && this.albums.length === 0) {
          Column() {
            LoadingProgress().width(30).height(30).color(Theme.accent(this.isDark))
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.results.length === 0 && this.albums.length === 0) {
          this.emptyState((this.isDark ? $r('app.media.ic_note') : $r('app.media.ic_note_d')),
            '未找到相关内容')
        } else {
          List() {
            // 过滤状态条：告诉用户这是服务器全量结果还是在本地筛过的
            ListItem() {
              Row() {
                Text(this.localFilter
                  ? '已过滤 · ' + this.results.length.toString() + ' 首'
                  : '服务器全部结果 · ' + this.results.length.toString() + ' 首')
                  .fontSize(11.5).fontFamily(APP_FONT)
                  .fontColor(Theme.textTertiary(this.isDark))
                  .layoutWeight(1)

                // 本地筛空了就提示可以关掉过滤去问服务器
                if (this.localFilter && this.results.length === 0) {
                  Text('在服务器重新搜')
                    .fontSize(11.5).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
                    .onClick(() => { this.runSearch(this.q.trim(), true); })
                } else {
                  Text(this.localFilter ? '关闭过滤' : '开启过滤')
                    .fontSize(11.5).fontFamily(APP_FONT)
                    .fontColor(Theme.textSecondary(this.isDark))
                    .onClick(() => {
                      this.localFilter = !this.localFilter;
                      if (this.localFilter) {
                        this.applyLocalFilter(this.q.trim());
                      } else {
                        // 关掉过滤：还原成服务器原始结果
                        this.results = this.remoteSongs.slice(0);
                        this.albums = this.remoteAlbums.slice(0);
                      }
                    })
                }
              }
              .width('100%')
              .height(32)
              .padding({ left: 20, right: 20 })
              .alignItems(VerticalAlign.Center)
            }

            if (this.albums.length > 0) {
              ListItem() {
                Scroll() {
                  Row({ space: 12 }) {
                    ForEach(this.albums, (al: Album) => {
                      Column() {
                        AlbumCell({ album: al, coverUrl: this.cover(al.coverArt, 300) })
                      }
                      .width(110)
                      .onClick(() => { this.onOpenAlbum(al); })
                    }, (al: Album) => 'sal_' + al.id)
                  }
                  .padding({ left: 20, right: 20 })
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width('100%')
              }
            }

            ForEach(this.results, (t: Track, idx: number) => {
              ListItem() {
                Row() {
                  // 多选模式：行首加勾选圈，点整行切换勾选而不是播放
                  if (this.pickMode) {
                    Column() {
                      Stack({ alignContent: Alignment.Center }) {
                        Column()
                          .width(21).height(21).borderRadius(11)
                          .backgroundColor(this.picked.indexOf(t.id) >= 0
                            ? Theme.accent(this.isDark) : '#00000000')
                          .border({
                            width: 1.5,
                            color: this.picked.indexOf(t.id) >= 0
                              ? Theme.accent(this.isDark) : Theme.textTertiary(this.isDark)
                          })
                          .animation(Motion.micro())
                        if (this.picked.indexOf(t.id) >= 0) {
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
                          // 与「加入歌单」弹层里的勾选保持同一手感
                          .transition(TransitionEffect.asymmetric(
                            TransitionEffect.scale({ x: 0.6, y: 0.6 })
                              .animation(Motion.enter(0.22, 0.8))
                              .combine(TransitionEffect.opacity(0).animation({ duration: 120, curve: Curve.FastOutSlowIn })),
                            TransitionEffect.OPACITY.animation(Motion.exit(90))))
                        }
                      }
                      .width(21).height(21)
                    }
                    .width(32)
                    .padding({ left: 20 })
                    .alignItems(HorizontalAlign.Start)
                  }

                  SongRow({ track: t, index: idx, coverUrl: this.cover(t.coverArt, 120) })
                    .layoutWeight(1)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .gesture(
                  LongPressGesture({ repeat: false, duration: 450 })
                    .onAction(() => {
                      // 平时长按 = 打开操作菜单，和「全部歌曲」「喜爱的歌」等列表完全一致：
                      // 下一首播放 / 加入播放队列 / 加入歌单 / 收藏 / 查看专辑歌手。
                      // 多选模式下行首已有勾选圈、点整行即勾选，长按不再另开菜单。
                      if (!this.pickMode) {
                        this.onTrackMenu(t);
                      }
                    })
                )
              }
              .onClick(() => {
                if (this.pickMode) {
                  this.togglePick(t.id);
                } else {
                  this.onPlay(this.results, idx);
                }
              })
            }, (t: Track, idx: number) =>
              t.id + '#s' + idx.toString() + (this.picked.indexOf(t.id) >= 0 ? '_1' : '_0'))

            // 底部空白：给悬浮导航条与迷你播放器让位。
            // 多选时导航条上方还要浮一条操作条，再补一份高度，免得最后一首被压住
            ListItem() {
              Column().width('100%').height(BOTTOM_PAD + (this.pickMode ? PICK_BAR_H : 0))
            }
          }
          .width('100%').layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .divider({ color: Theme.divider(this.isDark), strokeWidth: 0.5, startMargin: 68, endMargin: 20 })
        }
      }
      .width('100%').layoutWeight(1)
    }
    .width('100%').height('100%')
  }

  /**
   * 搜索页多选操作条：全悬浮胶囊，浮在底部导航条上方，四边都脱开屏幕，
   * 不做通栏色块，避免和列表、导航条之间出现一条生硬的分界线。
   */
  @Builder
  private searchPickBar() {
    Row() {
      // 全选：点一下全勾，再点取消，不用再回右上角
      Row() {
        Column() {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width(19).height(19).borderRadius(10)
              .backgroundColor(this.allChecked()
                ? Theme.accent(this.isDark) : '#00000000')
              .border({
                width: 1.5,
                color: this.allChecked()
                  ? Theme.accent(this.isDark) : Theme.textTertiary(this.isDark)
              })
            if (this.allChecked()) {
              Stack({ alignContent: Alignment.Center }) {
                Row() {
                  Column()
                    .width(3).height(5).borderRadius(1.5)
                    .backgroundColor(Color.White)
                    .rotate({ angle: -45 })
                    .margin({ top: 3, left: 1 })
                  Column()
                    .width(3).height(9).borderRadius(1.5)
                    .backgroundColor(Color.White)
                    .rotate({ angle: 45 })
                    .margin({ left: -1 })
                }
                .alignItems(VerticalAlign.Center)
              }
              .width(19).height(19)
            }
          }
          .width(19).height(19)
        }
        .width(19).height(19)

        Text('全选')
          .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
          .margin({ left: 7 })
      }
      .padding({ left: 12, right: 14 })
      .height(38).borderRadius(19)
      .backgroundColor(Theme.surfaceAlt(this.isDark))
      .onClick(() => { this.togglePickAll(); })

      Text('已选 ' + this.picked.length.toString() + ' 首')
        .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
        .layoutWeight(1)
        .textAlign(TextAlign.Center)

      Text('加入歌单')
        .fontSize(14).fontFamily(APP_FONT).fontColor(Color.White)
        .padding({ left: 18, right: 18 })
        .height(38).borderRadius(19)
        .backgroundColor(Theme.accent(this.isDark))
        .opacity(this.picked.length > 0 ? 1 : 0.4)
        .textAlign(TextAlign.Center)
        .onClick(() => { this.onBulkPick(this.picked.slice(0)); })
    }
    .width('100%')
    .height(PICK_BAR_H)
    .padding({ left: 8, right: 8 })
    .backgroundColor(Theme.surface(this.isDark))
    .borderRadius(30)
    .shadow({ radius: 18, color: this.isDark ? '#80000000' : '#26000000', offsetX: 0, offsetY: 6 })
    .margin({ left: 16, right: 16, bottom: bottomInset() + 10 })
    // 进多选时从底下托上来，退出时轻轻落回去。
    // 之前是 if 直接挂载/卸载，操作条"凭空出现"，像页面抖了一下。
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.translate({ y: 26 })
        .animation(Motion.enter(0.34, 0.9))
        .combine(TransitionEffect.opacity(0).animation({ duration: 170, curve: Curve.FastOutSlowIn })),
      TransitionEffect.translate({ y: 18 })
        .animation(Motion.exit(160))
        .combine(TransitionEffect.opacity(0).animation({ duration: 140, curve: Curve.FastOutSlowIn }))))
  }

  /**
   * 搜索历史：没有输入关键词时显示。
   * 点词条直接搜，点右边的叉删单条，右上角清空全部。
   */
  @Builder
  private searchHistoryBody() {
    Column() {
      Row() {
        Text('搜索历史')
          .fontSize(13).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Medium)
          .fontColor(Theme.textSecondary(this.isDark))
          .layoutWeight(1)
        Text('清空')
          .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
          .onClick(() => { this.clearAllHistory(); })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 4, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      List() {
        ForEach(this.history, (w: string) => {
          ListItem() {
            Row() {
              Image(this.isDark ? $r('app.media.ic_search') : $r('app.media.ic_search_d'))
                .width(16).height(16).opacity(0.4)
              Text(w)
                .fontSize(14).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
                .layoutWeight(1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ left: 12 })
              // 删除单条：叉号做得小一点、淡一点，别抢词条的点击区域
              Stack({ alignContent: Alignment.Center }) {
                Image(this.isDark ? $r('app.media.ic_close') : $r('app.media.ic_close_d'))
                  .width(13).height(13).opacity(0.35)
              }
              .width(34).height(34)
              .onClick(() => { this.removeHistoryWord(w); })
            }
            .width('100%')
            .height(46)
            .padding({ left: 20, right: 12 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => { this.useHistoryWord(w); })
          }
        }, (w: string) => 'sh_' + w)
        // 底部空白：让最后一条不被导航条压住
        ListItem() {
          Column().width('100%').height(BOTTOM_PAD)
        }
      }
      .width('100%').layoutWeight(1)
      .scrollBar(BarState.Off)
      .divider({ color: Theme.divider(this.isDark), strokeWidth: 0.5, startMargin: 48, endMargin: 20 })
    }
    .width('100%').layoutWeight(1)
  }

  /**
   * 搜索页整体：搜索条 + 结果区，多选操作条浮在最上层。
   * 结构照搬拆分前的主页面——搜索条不在 if 分支里，
   * 输入焦点在结果切换时不会丢。
   */
  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.searchBody()

      if (this.pickMode) {
        // 只让操作条本身响应点击，空白区域不拦截列表的滚动与点击
        this.searchPickBar()
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
