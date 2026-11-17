import { Track, Artist, Album, Playlist, SearchResult, SongsSort, RecentEntry } from '../model/Models';
import { APP_FONT, APP_FONT_BOLD, registerAppFonts } from '../utils/Fonts';
import { Store } from '../store/Store';
import { Router } from '../utils/Router';
import { Motion } from '../utils/Motion';
import { Theme, Fmt, toast, topInset, bottomInset, sheetListMax } from '../utils/Theme';
import { MiniPlayer } from '../components/MiniPlayer';
import { BottomNav, NavTab } from '../components/BottomNav';
import { SettingsPanel } from '../components/SettingsPanel';
import { PlaylistCover, PlaylistRow, SheetScrim, PlaylistNameSheet, CheckRow } from '../components/PlaylistParts';
import { TrackSource } from '../utils/TrackSource';
import { qualityText, pairTracks, pairKey, errText, primaryArtist } from '../utils/TrackUtils';
import { AlbumCell, SongRow, HomeSongRow } from '../components/TrackRows';
import { SearchPage } from '../components/SearchPage';
import { PlayerCore } from '../player/PlayerCore';
import common from '@ohos.app.ability.common';

/** 底部导航的五个主界面，与 BottomNav 的 NavTab 保持一致 */
type NavName = NavTab;
type SubView = 'main' | 'artist' | 'album' | 'search' | 'albums' | 'playlist';

/** 「全部歌曲」排序弹层的选项，展示顺序即列表顺序 */
const SORT_OPTIONS: SongsSort[] =
  ['default', 'title', 'artist', 'album', 'added', 'plays', 'random'];

/** 「全部歌曲」每页条数 */
const PAGE_SIZE: number = 300;
/** 专辑单页条数（首页先取一页立即渲染，剩余后台补齐） */
const ALBUM_PAGE: number = 500;
/**
 * 列表/滚动区底部留白：迷你条 60 + 间隙 10 + 导航条 58 + 底部安全区 + 余量，
 * 保证滚到底时最后一排完整露在悬浮区之上
 */
const BOTTOM_PAD: number = 192;
/** 多选操作条高度；列表末尾要为它额外让位 */
const PICK_BAR_H: number = 58;
/** 屏幕左右边缘留给系统侧滑返回的宽度（vp）：这条带内应用内横滑不接管 */
const EDGE_BACK_W: number = 32;

@Entry
@Component
struct SubsonicLibrary {
  @StorageProp('isDark') private isDark: boolean = true;
  @State private navTab: string = 'home';
  @State private view: SubView = 'main';
  /**
   * 内容层透明度。切换 tab / 进出详情页时先淡出再淡入，
   * 避免「咔」一下换成一屏完全不同的内容，让人分不清是刷新了还是切走了。
   */
  @State private contentOpacity: number = 1;
  /** 内容层纵向位移（vp）：与透明度一起构成「轻轻上浮」的进场感 */
  @State private contentShift: number = 0;
  /**
   * 内容层横向位移（vp）。进详情页从右侧滑入（+ → 0），返回从左侧滑入（- → 0），
   * 层级关系用水平方向表达，比单纯淡入淡出更容易看懂「进了一层 / 退了一层」。
   */
  @State private contentSlide: number = 0;
  /** 内容层缩放：换层时轻微后退，给「进了一层」一点纵深 */
  @State private contentScale: number = 1;
  /** 过渡淡出阶段的定时器句柄（-1 表示没有在跑） */
  private transitionTimer: number = -1;
  @State private albums: Album[] = [];
  /** 首页「全部专辑」板块预览：只放前 6 张（3 列 × 2 行） */
  @State private homeAlbums: Album[] = [];
  /** 首页「随机歌曲」板块：4 首，可换一批 */
  @State private homeRandom: Track[] = [];
  /** 首页「每日推荐」板块：4 首，当天固定 */
  @State private homeDaily: Track[] = [];
  /** 首页「最近播放」：按最后一次播放时间倒序，最多 40 条 */
  @State private recent: RecentEntry[] = [];
  /** 已收藏歌曲 id 集合：首页列表直接标出红心状态，避免逐首请求 */
  @State private starredIds: string[] = [];
  @State private homeLoading: boolean = false;
  @State private songsCount: number = 0;
  @State private songsTotal: number = 0;
  @State private songsLoading: boolean = false;
  @State private songsDone: boolean = false;
  @State private starredSongs: Track[] = [];
  @State private starredLoaded: boolean = false;
  @State private curArtist: Artist | null = null;
  @State private curArtistAlbums: Album[] = [];
  @State private curAlbum: Album | null = null;
  @State private curAlbumSongs: Track[] = [];
  /** 搜索页是否处于多选：操作条由 SearchPage 自己画，主页面只需要知道以便退出时清状态 */
  @State private pickMode: boolean = false;
  @State private loading: boolean = true;
  @State private error: string = '';
  // ============ 歌单 ============
  @State private playlists: Playlist[] = [];
  @State private playlistsLoaded: boolean = false;
  @State private playlistsLoading: boolean = false;
  /** 歌单列表页的封面 URL 拼图，key 为歌单 id */
  @State private playlistCovers: Record<string, string[]> = {};
  /** 当前打开的歌单详情 */
  @State private curPlaylist: Playlist | null = null;
  /** 歌单详情的曲目（与 curPlaylist 分开，方便增删后局部更新） */
  @State private curPlaylistSongs: Track[] = [];
  @State private playlistLoading: boolean = false;
  /**
   * 搜索词。放在页面而不是搜索页组件里：
   * 搜索页是 if/else 分支，跳到专辑/歌手详情就会被销毁；
   * 从详情返回时用这个词把结果恢复出来，用户不会「刚搜完一返回就空了」。
   */
  @State private searchQ: string = '';
  // 弹层：'none' 不显示；'create' 新建；'rename' 改名；'add' 选歌加入；'pick' 选歌单；
  // 'more' 歌单更多操作；'trackmenu' 歌曲长按菜单；'queue' 播放队列
  @State private sheet: string = 'none';
  /** 播放队列弹层的快照。PlayerCore 的 queue 不是可观察对象，改完要手动回填 */
  @State private queueSongs: Track[] = [];
  /** 队列弹层里的当前曲目下标，-1 表示播放器空闲 */
  @State private queueCur: number = -1;
  /** 队列为空时的标题文案，区分「还没播过」和「刚被清空」 */
  @State private queueEmptyHint: string = '还没有播放队列';
  /** 待加入歌单的歌曲（从播放页/列表长按进入） */
  @State private pendingTrack: Track | null = null;
  /** 选歌弹层里已勾选的歌曲 id */
  @State private pickedIds: string[] = [];
  /** 虚拟化数据源：@State 数组是真源，这些只负责喂 LazyForEach。
   *  改数组必须走下面的 set*Songs helper，否则列表不刷新 */
  private playlistSrc: TrackSource = new TrackSource();
  private queueSrc: TrackSource = new TrackSource();
  private starredSrc: TrackSource = new TrackSource();
  private albumSrc: TrackSource = new TrackSource();
  private addPoolSrc: TrackSource = new TrackSource();
  /** 选歌单弹层里已勾选的歌单 id */
  @State private pickedPlaylists: string[] = [];
  /** 长按的曲目在歌单里的序号，-1 表示没有 */
  @State private removingIndex: number = -1;
  /** 多选模式下待加入歌单的歌曲 id */
  @State private bulkSongIds: string[] = [];
  /** 歌曲长按菜单当前指向的曲目（各列表共用，避免每处单独存状态） */
  @State private menuTrack: Track | null = null;
  /** 长按菜单里展示的「下一首播放」，让用户确认排到自己选的那首前面 */
  @State private playNextLabel: string = '';
  /** 当前曲目是否已收藏（长按菜单里的红心用） */
  @State private menuLiked: boolean = false;
  /** 长按菜单操作进行中，避免连点重复提交 */
  @State private menuBusy: boolean = false;

  private songs: TrackSource = new TrackSource();
  /** 「全部歌曲」排序方式：上次的 choice 从设置恢复 */
  @State private songsSort: SongsSort = 'default';
  /** 随机排序待洗牌标记：重新加载读全后洗一次牌（用户手动点选时清掉） */
  private randomDirty: boolean = false;
  /** 专辑剩余分页后台补齐进行中标记 */
  private albumsPreloading: boolean = false;
  /** 后台预载剩余歌曲分页的进行中标记 */
  private preloading: boolean = false;
  /** 「全部歌曲」的加载代次：重置时自增，用来丢弃过期的分页结果 */
  private songsGen: number = 0;
  /** 服务器原始顺序的全部歌曲快照（缓存落盘用；界面上怎么排序都不动它） */
  private songsRaw: Track[] = new Array<Track>();
  /** 红心代次：本地每次改动自增，用来丢弃「改动之前发出」的旧回包，避免红心闪回 */
  private starredGen: number = 0;
  /** 页面销毁后停止后台预载 */
  private alive: boolean = true;
  /** 打开专辑详情前所处的视图：返回时按原路退回，而不是一律回首页 */
  private albumOrigin: string = 'main';

  aboutToAppear(): void {
    registerAppFonts(this.getUIContext());
    // 播放页下拉时垫的底色要和这里一致，先把这个页签带给它
    AppStorage.setOrCreate('navTab', this.navTab);
    const cfg = Store.get().serverConfig;
    if (cfg === null || Store.get().sourceType !== 'subsonic') {
      Router.replace('pages/Setup');
      return;
    }
    // 恢复上次的「全部歌曲」排序（loadSettings 已做过合法性校验）
    this.songsSort = Store.get().settings.songsSort ?? 'default';
    this.loadHome();
    // 桌面长按图标快捷方式（随机播放 / 播放喜爱 / 每日推荐）：
    // EntryAbility 冷启动 / 热启动都会把动作广播到这里
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ctx.eventHub.on('shortcut_action', (name: string) => {
      this.runShortcut(name);
    });
  }

  /** 快捷方式动作：能直接播的直接播，不打断用户停在哪个页面 */
  private runShortcut(name: string): void {
    const p: PlayerCore = Store.get().player();
    if (name === 'random') {
      Store.get().randomSongs(30).then((songs: Track[]) => {
        if (songs.length === 0) {
          toast('曲库里还没有歌');
          return;
        }
        p.playQueue(songs, 0);
        toast('随机播放 ' + songs.length.toString() + ' 首');
      }).catch(() => { toast('随机播放失败，请检查网络'); });
    } else if (name === 'favorites') {
      p.playFavorites().then((n: number) => {
        toast(n > 0 ? '播放喜爱 ' + n.toString() + ' 首' : '还没有收藏的歌曲');
      });
    } else if (name === 'daily') {
      Store.get().getDailyPicks(30, 30).then((songs: Track[]) => {
        if (songs.length === 0) {
          toast('今日推荐还没生成');
          return;
        }
        p.playQueue(songs, 0);
        toast('播放今日推荐 ' + songs.length.toString() + ' 首');
      }).catch(() => { toast('每日推荐拉取失败，请检查网络'); });
    }
  }

  /**
   * 从播放页返回时补一次刷新。
   * 停在「喜爱的歌」页时去播放页收藏/取消收藏，返回后原本不会重新拉取，
   * 表现为「刚收藏的歌进不了喜爱列表」（列表还是离开前的旧数据）。
   */
  onPageShow(): void {
    // 最近播放只在播放页里变（切歌、进度推进），回到列表页重读一次即可。
    // 不做成 AppStorage 订阅：那份记录本机只读一份，没必要为它加全局状态。
    this.recent = Store.get().recentEntries();
    const dirty: boolean = AppStorage.get<boolean>('starredDirty') ?? false;
    if (!dirty) {
      return;
    }
    if (this.navTab === 'starred') {
      this.loadStarred();
      return;
    }
    if (this.navTab === 'home') {
      // 首页两排歌曲的红心用 starredIds 判断：在播放页/锁屏收藏后返回，
      // 不重拉这份 id 就会出现「已经收藏了，首页还是空心」。
      this.loadStarredIds();
      // 拉完就把脏标记清掉，否则每次从播放页回来都会重拉一遍整个收藏列表。
      // 同时把「喜爱页已加载」置否：那份列表确实是旧的，下次切过去要重新取。
      this.starredLoaded = false;
      AppStorage.setOrCreate('starredDirty', false);
    }
  }

  aboutToDisappear(): void {
    this.alive = false;
    // 过渡定时器不清会一直持有本组件实例，退出页面后回调里还在改已销毁的状态
    if (this.transitionTimer !== -1) {
      clearTimeout(this.transitionTimer);
      this.transitionTimer = -1;
    }
  }

  private cover(coverArt: string, size: number): string {
    const s = Store.get().subsonicClient();
    if (s === null || coverArt.length === 0) {
      return '';
    }
    return s.coverUrl(coverArt, size);
  }

  // ============ 数据 ============

  /** 首页：每日推荐 + 随机歌曲 + 专辑预览。
   *  四路请求相互独立，串行 await 的总耗时是「相加」，
   *  并行后只等最慢的一路——NAS 上首页能快两三倍 */
  private async loadHome(): Promise<void> {
    this.homeLoading = true;
    this.error = '';
    await Promise.all([
      this.loadHomeAlbums(),
      this.loadHomeDaily(),
      this.loadHomeRandom(),
      this.loadStarredIds()
    ]);
    this.homeLoading = false;
  }

  /** 拉一次收藏 id 集合：首页两排歌曲用它判断红心是否点亮 */
  private async loadStarredIds(): Promise<void> {
    const gen: number = this.starredGen;
    // 缓存先铺：首页红心不用等网络
    if (this.starredIds.length === 0) {
      const cached: Track[] = Store.get().loadStarredCache();
      if (cached.length > 0) {
        const warm: string[] = [];
        for (const t of cached) {
          warm.push(t.id);
        }
        this.starredIds = warm;
      }
    }
    try {
      const r = await Store.get().listStarred();
      // 回包发出后本地又改过红心：这份数据是旧的，丢掉落，免得刚点的红心被顶回去
      if (gen !== this.starredGen) {
        return;
      }
      const ids: string[] = [];
      for (const t of r.songs) {
        ids.push(t.id);
      }
      this.starredIds = ids;
    } catch (e) {
      // 拉不到就维持现状（缓存铺过或上一次的值），别把红心全清成空心
    }
  }

  private isLiked(t: Track): boolean {
    return this.starredIds.indexOf(t.id) >= 0;
  }

  /** 首页行内点红心：先行变更本地状态（即时反馈），失败再回滚 */
  private async toggleLike(t: Track): Promise<void> {
    const liked: boolean = this.isLiked(t);
    // 代次自增：此前发出的 listStarred 回包作废，不会覆盖这次乐观更新
    this.starredGen++;
    const ids: string[] = [];
    for (const id of this.starredIds) {
      if (id !== t.id) {
        ids.push(id);
      }
    }
    if (!liked) {
      ids.push(t.id);
    }
    this.starredIds = ids;
    const ok: boolean = liked ? await Store.get().unstarSong(t.id) : await Store.get().starSong(t.id);
    if (!ok) {
      // 回滚
      const back: string[] = [];
      for (const id of this.starredIds) {
        if (id !== t.id) {
          back.push(id);
        }
      }
      if (liked) {
        back.push(t.id);
      }
      this.starredIds = back;
      toast(liked ? '取消收藏失败' : '收藏失败');
      return;
    }
    AppStorage.setOrCreate('starredDirty', true);
  }

  /**
   * 「喜爱的歌」列表里点爱心：先把它从列表拿掉（即时反馈），再调服务端取消收藏。
   * 失败则把整行放回去；成功后同步播放页红心与系统卡片的 isFavorite。
   */
  private async unstarHere(t: Track): Promise<void> {
    const pos: number = this.starredSongs.findIndex((s: Track) => s.id === t.id);
    const songs: Track[] = [];
    for (const s of this.starredSongs) {
      if (s.id !== t.id) {
        songs.push(s);
      }
    }
    const ids: string[] = [];
    for (const id of this.starredIds) {
      if (id !== t.id) {
        ids.push(id);
      }
    }
    this.setStarredSongs(songs);
    this.starredIds = ids;
    const ok: boolean = await Store.get().unstarSong(t.id);
    if (!ok) {
      // 只把这一行插回原位，别用整份快照覆盖（期间可能已删掉别的行）
      const restored: Track[] = this.starredSongs.slice();
      const at: number = pos < 0 || pos > restored.length ? restored.length : pos;
      restored.splice(at, 0, t);
      this.setStarredSongs(restored);
      const idsRestored: string[] = this.starredIds.slice();
      idsRestored.push(t.id);
      this.starredIds = idsRestored;
      toast('取消收藏失败');
      return;
    }
    this.starredLoaded = true;
    if (this.starredSongs.length === 0) {
      this.error = '还没有收藏的歌曲';
    }
    // 正在播放的就是这首时，播放页红心与锁屏/控制中心的状态一起跟着变
    Store.get().player().syncFavoriteFromExternal(t.id, false);
    toast('已取消收藏');
  }

  private async loadHomeAlbums(): Promise<void> {
    try {
      // 分阶段加载：首页只需要 6 张 + 总数，先取一页（500 张）立即渲染，
      // 不用等全量分页拉完（大曲库 20 个串行请求能把首屏拖好几秒）
      const first: Album[] = await Store.get().listAlbumsPage('newest', ALBUM_PAGE, 0);
      this.albums = first;
      this.homeAlbums = first.slice(0, 6);
      if (first.length === 0) {
        this.error = '音乐库暂无专辑';
        return;
      }
      if (first.length < ALBUM_PAGE) {
        return; // 曲库不足一页，已经是全量
      }
      this.preloadAlbumsRest();
    } catch (err) {
      this.error = errText(err as Object);
    }
  }

  /** 后台逐页补齐剩余专辑（「全部专辑」页靠这份全量数据；带代次防重入/防过期） */
  private preloadAlbumsRest(): void {
    if (this.albumsPreloading || !this.alive) {
      return;
    }
    this.albumsPreloading = true;
    const step = (): void => {
      if (!this.alive) {
        this.albumsPreloading = false;
        return;
      }
      const offset: number = this.albums.length;
      Store.get().listAlbumsPage('newest', ALBUM_PAGE, offset).then((page: Album[]) => {
        if (!this.alive) {
          this.albumsPreloading = false;
          return;
        }
        if (page.length > 0) {
          // 追加而不是覆盖：期间用户在「全部专辑」页看到的列表逐步变长
          this.albums = this.albums.concat(page);
        }
        if (page.length < ALBUM_PAGE) {
          this.albumsPreloading = false;
        } else {
          setTimeout(() => { step(); }, 50);
        }
      }).catch(() => {
        // 补齐失败不重试也不报错：首页已经能看，「全部专辑」少几页无伤大雅
        this.albumsPreloading = false;
      });
    };
    step();
  }

  private async loadHomeDaily(): Promise<void> {
    try {
      this.homeDaily = await Store.get().getDailyPicks(4, 24);
    } catch (e) {
      this.homeDaily = [];
    }
  }

  /**
   * 播放时撞上「服务器上找不到这首歌」，Store 会把这首从当日推荐池里剔掉并置脏。
   * 回到首页时重取一次，把那首死链换掉，而不是继续摆在那儿。
   */
  private refreshDailyIfDirty(): void {
    const dd: boolean = AppStorage.get<boolean>('dailyDirty') ?? false;
    if (!dd) {
      return;
    }
    AppStorage.setOrCreate('dailyDirty', false);
    this.loadHomeDaily();
  }

  private async loadHomeRandom(): Promise<void> {
    try {
      this.homeRandom = await Store.get().randomSongs(4);
    } catch (e) {
      this.homeRandom = [];
    }
  }

  /** 「换一批」：重新抽 4 首随机歌 */
  private async reloadRandom(): Promise<void> {
    try {
      this.homeRandom = await Store.get().randomSongs(4);
    } catch (e) {
      this.homeRandom = [];
    }
  }

  /** 右上角刷新：整列表重新从服务器拉一遍；失败时用 toast 告知（列表有内容时错误不占页面） */
  private async refreshSongs(): Promise<void> {
    if (this.songsLoading) {
      return;
    }
    await this.loadSongs(true);
    if (this.error.length > 0) {
      toast(this.error);
    }
  }

  /** 全部歌曲：分页取；首屏一页 + 后台把剩余分页拉完，页头始终显示真实总数 */
  private async loadSongs(reset: boolean): Promise<void> {
    if (reset) {
      // 重新加载：作废进行中的后台预载，否则它会把旧 offset 的页追加到新列表上
      this.songsGen++;
      this.preloading = false;
      this.songsDone = false;
    } else if (this.songsLoading || this.songsDone) {
      return;
    }
    const gen: number = this.songsGen;
    // 本次是否已经拿过曲库总数：缓存分支会顺手拉一次，重建时就不重复请求
    let totalFetched: boolean = false;

    // 冷启动先用落盘缓存把列表铺出来，再用一次轻量的「曲库总数」对账：
    // 数量没变就完全不重新拉曲库（只发一个 scanStatus 请求），列表立刻可用；
    // 数量对不上（服务器加了/删了歌）或拉不到总数，才走正常网络重建。
    // 右上角手动刷新不受此影响：列表非空时缓存分支不会命中。
    if (reset && this.songs.count() === 0 && this.songsRaw.length === 0) {
      const cache: Track[] = Store.get().loadSongsCache();
      if (cache.length > 0) {
        // 先占住加载态：这段 await 期间用户点刷新不能重入，否则两次对账互踩
        this.songsLoading = true;
        let total: number = 0;
        try {
          total = await Store.get().getScanCount();
          totalFetched = true;
        } catch (e) {
          total = 0;
        }
        if (!this.alive || gen !== this.songsGen) {
          return;
        }
        // total 为 0 多半是离线/超时：这时候缓存是唯一能看的数据，照常铺
        if (total === cache.length || total <= 0) {
          this.songsRaw = cache.slice();
          this.songs.setAll(cache);
          this.songsCount = cache.length;
          this.songsTotal = total > 0 ? total : cache.length;
          this.songsDone = true;
          this.error = '';
          if (this.songsSort !== 'default') {
            this.applySort();
          }
          this.songsLoading = false;
          this.loading = false;
          return;
        }
        // 数量对不上：缓存过时，清掉走正常重建（songsRaw 也要清，否则保存逻辑会拿旧快照）
        this.songs.setAll([]);
        this.songsRaw = new Array<Track>();
        this.songsCount = 0;
        // 总数已知，直接用作页头，重建时不再重复请求
        this.songsTotal = total;
      }
    }

    this.songsLoading = true;
    if (reset) {
      this.error = '';
      // 页头总数来自 getScanStatus.count，与已加载页数无关。
      // 每次重载都校准一次（缓存铺过之后 songsTotal 非 0，只在 0 时拉会一直显示旧值）
      if (!totalFetched) {
        try {
          this.songsTotal = await Store.get().getScanCount();
        } catch (e) {
        }
        if (!this.alive || gen !== this.songsGen) {
          return;
        }
      }
    }
    try {
      const offset: number = reset ? 0 : this.songs.count();
      const page: Track[] = await Store.get().listSongs(PAGE_SIZE, offset);
      if (!this.alive || gen !== this.songsGen) {
        return;
      }
      if (reset) {
        this.songs.setAll(page);
        this.songsRaw = page.slice();
        // 重新加载后若处于「随机」排序，等读全再统一洗一次牌（见下方 songsDone 分支）
        this.randomDirty = this.songsSort === 'random';
        // 首页也要立刻排：曲库不满一页时不会再有追加分支来补排序
        if (this.songsSort !== 'default' && this.songsSort !== 'random') {
          this.applySort();
        }
      } else {
        this.songs.append(page);
        for (const t of page) {
          this.songsRaw.push(t);
        }
        // 非默认排序时把新页并入排序（random 不逐页洗，避免后台每页都重洗）
        if (this.songsSort !== 'default' && this.songsSort !== 'random') {
          this.applySort();
        }
      }
      this.songsCount = this.songs.count();
      this.songsDone = page.length < PAGE_SIZE;
      // 读全了：把服务器原始顺序的快照落盘，下次冷启动直接铺列表
      if (this.songsDone && this.songsRaw.length > 0) {
        Store.get().saveSongsCache(this.songsRaw);
      }
      // 「随机」排序：全量读完后洗一次牌，之后不再动，保证滚动位置稳定
      if (this.songsDone && this.randomDirty) {
        this.randomDirty = false;
        this.applySort();
      }
      if (this.songsCount === 0) {
        this.error = '音乐库暂无歌曲';
      }
    } catch (err) {
      if (gen === this.songsGen) {
        if (reset) {
          // 用户主动刷新/首次加载失败：写错误文案并判死，
          // 空列表态会把 this.error 显示出来，用户知道原因
          this.error = errText(err as Object);
          this.songsDone = true;
        } else {
          // 后台翻页失败：只是这一页没拿到，列表不作废。
          // 之前把 songsDone 置 true 的后果是——后台某一页失败一次，
          // 整个曲库就永远停在 300 首，滚到底也不会再拉（onReachEnd 被 done 挡住）。
          // 现在保持 false，交给 preloadRest 退避重试 / onReachEnd 再唤起。
          this.songsDone = false;
        }
      }
    }
    if (gen !== this.songsGen) {
      return;
    }
    this.songsLoading = false;
    this.loading = false;
    // 后台顺序拉完剩余分页，保证列表与「随机播放」拿到完整曲库
    if (!this.songsDone && this.alive) {
      this.preloadRest();
    }
  }

  /**
   * 后台逐页预载剩余歌曲，直至读全（每页之间稍作间隔，不抢前台渲染）。
   * 单页失败按指数退避重试（600ms 起、最多 5 次），仍失败就先停下：
   * 滚到底（onReachEnd）或下次刷新会重新唤起，列表不会永远卡在半截。
   */
  private preloadRest(): void {
    if (this.preloading || this.songsDone || !this.alive) {
      return;
    }
    this.preloading = true;
    const step = (attempt: number): void => {
      if (!this.alive || this.songsDone) {
        this.preloading = false;
        return;
      }
      const before: number = this.songs.count();
      this.loadSongs(false).then(() => {
        if (!this.alive || this.songsDone) {
          this.preloading = false;
          return;
        }
        if (this.songs.count() > before) {
          // 这一页拿到了：稍歇 50ms 继续下一页
          setTimeout(() => { step(0); }, 50);
          return;
        }
        const next: number = attempt + 1;
        if (next > 5) {
          this.preloading = false;
          return;
        }
        const delay: number = Math.min(600 * Math.pow(2, next - 1), 9000);
        setTimeout(() => { step(next); }, delay);
      }).catch(() => {
        this.preloading = false;
      });
    };
    step(0);
  }

  // ============ 全部歌曲排序 ============

  private sortLabel(m: SongsSort): string {
    if (m === 'title') return '标题 A–Z';
    if (m === 'artist') return '按歌手';
    if (m === 'album') return '按专辑';
    if (m === 'added') return '最近添加';
    if (m === 'plays') return '最常播放';
    if (m === 'random') return '随机排序';
    return '默认顺序';
  }

  private sortDesc(m: SongsSort): string {
    if (m === 'added') return '新入库的排在前面';
    if (m === 'plays') return '听得最多的排在前面';
    if (m === 'random') return '打乱当前列表顺序';
    return '';
  }

  /** 中文排序器实例（懒创建）。localeCompare 每次调用都重建排序器，
   *  一次大列表排序要几万次比较，复用 Collator 实例快数倍 */
  private collator: Intl.Collator | null = null;

  /** 中文按拼音排；系统不支持 zh collation 时回落到码点序，不会抛错 */
  private cmpText(a: string, b: string): number {
    if (a === b) {
      return 0;
    }
    if (a.length === 0) {
      return 1; // 空值排最后
    }
    if (b.length === 0) {
      return -1;
    }
    if (this.collator === null) {
      try {
        this.collator = new Intl.Collator('zh-Hans-CN');
      } catch (e) {
        this.collator = new Intl.Collator();
      }
    }
    return this.collator.compare(a, b);
  }

  /** 服务端播放次数优先，没给就用本机听歌统计 */
  private playsOf(t: Track): number {
    const server: number = t.playCount ?? 0;
    if (server > 0) {
      return server;
    }
    const st = Store.get().statOf(t.id);
    return st !== null ? st.plays : 0;
  }

  private sortCompare(a: Track, b: Track): number {
    const m: SongsSort = this.songsSort;
    if (m === 'title') {
      return this.cmpText(a.title, b.title) || this.cmpText(a.artist, b.artist);
    }
    if (m === 'artist') {
      return this.cmpText(a.artist, b.artist) || this.cmpText(a.album, b.album) ||
        this.cmpText(a.title, b.title);
    }
    if (m === 'album') {
      return this.cmpText(a.album, b.album) || this.cmpText(a.title, b.title);
    }
    if (m === 'added') {
      return (b.created ?? 0) - (a.created ?? 0);
    }
    if (m === 'plays') {
      return this.playsOf(b) - this.playsOf(a);
    }
    return 0;
  }

  /** 对已加载的列表就地重排并通知列表刷新 */
  private applySort(): void {
    const list: Track[] = this.songs.all();
    if (list.length < 2) {
      return;
    }
    if (this.songsSort === 'random') {
      // Fisher–Yates 洗牌
      for (let i = list.length - 1; i > 0; i--) {
        const j: number = Math.floor(Math.random() * (i + 1));
        const tmp: Track = list[i];
        list[i] = list[j];
        list[j] = tmp;
      }
    } else {
      list.sort((a: Track, b: Track) => this.sortCompare(a, b));
    }
    this.songs.setAll(list);
  }

  /** 用户在弹层里选了一种排序 */
  private applySortChoice(m: SongsSort): void {
    this.sheet = 'none';
    if (m === this.songsSort && m !== 'random') {
      return;
    }
    this.songsSort = m;
    this.randomDirty = false;
    // 记住选择，下次启动直接用（写失败不影响本次切换）
    Store.get().settings.songsSort = m;
    Store.get().saveSettings(Store.get().settings).catch(() => {
    });
    if (m === 'default') {
      // 服务器顺序本地排不出来：清掉重来，走正常分页加载
      this.loadSongs(true);
      return;
    }
    this.applySort();
    if (m === 'random') {
      toast('已打乱当前列表');
    }
  }

  private async loadStarred(): Promise<void> {
    const gen: number = this.starredGen;
    this.loading = true;
    this.error = '';
    // 先铺落盘缓存：冷启动进「喜爱」页立刻有内容，网络回来再覆盖
    if (this.starredSongs.length === 0) {
      const cache: Track[] = Store.get().loadStarredCache();
      if (cache.length > 0) {
        this.setStarredSongs(cache);
      }
    }
    try {
      const r = await Store.get().listStarred();
      // 请求期间用户在列表里点过红心：这份回包已经过期，套上去会把刚取消的歌又塞回来
      if (gen !== this.starredGen) {
        this.loading = false;
        return;
      }
      this.setStarredSongs(r.songs);
      this.starredLoaded = true;
      if (r.songs.length > 0) {
        Store.get().saveStarredCache(r.songs);
      }
      // 消费掉播放页收藏操作留下的刷新标记
      AppStorage.setOrCreate('starredDirty', false);
      if (this.starredSongs.length === 0) {
        this.error = '还没有收藏的歌曲';
      }
    } catch (err) {
      // 缓存铺过、网络失败：列表保持缓存内容可看可播，不把 error 写成整页报错
      if (this.starredSongs.length === 0) {
        this.error = errText(err as Object);
      }
    }
    this.loading = false;
  }

  // ============ 歌单 ============

  /** 拉取全部歌单，并异步补齐封面拼图（封面缺失时用前 4 首歌的封面） */
  private async loadPlaylists(): Promise<void> {
    this.playlistsLoading = true;
    this.error = '';
    try {
      const list: Playlist[] = await Store.get().listPlaylists();
      this.playlists = list;
      this.playlistsLoaded = true;
      this.buildCovers(list);
    } catch (err) {
      this.error = errText(err as Object);
    }
    this.playlistsLoading = false;
  }

  /**
   * 生成歌单封面：
   * 服务端给了 coverArt 就直接用；没给就要拉一次详情拿前 4 首歌的封面。
   * 这一步单独跑，不让歌单列表等它，列表先出来体感快得多。
   */
  private buildCovers(list: Playlist[]): void {
    const map: Record<string, string[]> = {};
    const pending: Playlist[] = [];
    for (const p of list) {
      if (p.coverArt.length > 0) {
        map[p.id] = [this.cover(p.coverArt, 240)];
      } else if (p.songCount === 0) {
        map[p.id] = [];
      } else {
        map[p.id] = [];
        pending.push(p);
      }
    }
    this.playlistCovers = map;
    const self = this;
    const step = (i: number): void => {
      if (i >= pending.length || !self.alive) {
        return;
      }
      const p: Playlist = pending[i];
      self.fetchCovers(p).then((covers: string[]) => {
        if (!self.alive) {
          return;
        }
        // ArkTS 不支持 Object.assign 做浅拷贝，手动复制一份再改。
        // @State 对对象是引用比较，必须换新对象才会触发刷新。
        const next: Record<string, string[]> = {};
        const prevRecord: Record<string, string[]> = self.playlistCovers;
        const keys: string[] = Object.keys(prevRecord);
        for (const k of keys) {
          next[k] = prevRecord[k];
        }
        next[p.id] = covers;
        self.playlistCovers = next;
        step(i + 1);
      }).catch(() => { step(i + 1); });
    };
    step(0);
  }

  /** 拉一个歌单的前四张封面 */
  private async fetchCovers(p: Playlist): Promise<string[]> {
    const detail: Playlist | null = await Store.get().getPlaylist(p.id);
    const out: string[] = [];
    if (detail === null) {
      return out;
    }
    for (const t of detail.songs) {
      if (out.length >= 4) {
        break;
      }
      if (t.coverArt.length > 0) {
        out.push(this.cover(t.coverArt, 200));
      }
    }
    return out;
  }

  /** 打开歌单详情 */
  private async openPlaylist(p: Playlist): Promise<void> {
    this.curPlaylist = p;
    this.setPlaylistSongs([]);
    this.playlistLoading = true;
    this.crossfade(() => { this.view = 'playlist'; }, 1);
    try {
      const detail: Playlist | null = await Store.get().getPlaylist(p.id);
      // 期间已经返回或换了一个歌单：这份结果属于上一个请求，直接丢弃
      if (this.curPlaylist === null || this.curPlaylist.id !== p.id) {
        return;
      }
      if (detail === null) {
        this.error = '歌单不存在或已被删除';
        this.playlistLoading = false;
        return;
      }
      this.curPlaylist = detail;
      this.setPlaylistSongs(detail.songs);
      // 详情里的曲目数是准的，回写列表项，返回时列表不会显示旧数量
      this.syncPlaylistMeta(detail);
    } catch (err) {
      if (this.curPlaylist !== null && this.curPlaylist.id === p.id) {
        toast('加载歌单失败');
      }
    }
    this.playlistLoading = false;
  }

  /** 用详情数据回写列表里的同名歌单 */
  private syncPlaylistMeta(detail: Playlist): void {
    const next: Playlist[] = [];
    for (const it of this.playlists) {
      if (it.id === detail.id) {
        const merged: Playlist = {
          id: detail.id,
          name: detail.name,
          songCount: detail.songs.length,
          duration: detail.duration,
          coverArt: detail.coverArt,
          owner: detail.owner,
          created: detail.created,
          changed: detail.changed,
          editable: detail.editable,
          songs: []
        };
        next.push(merged);
      } else {
        next.push(it);
      }
    }
    this.playlists = next;
  }

  /** 新建歌单（可带初始曲目），成功后打开它 */
  private async doCreatePlaylist(name: string): Promise<void> {
    this.sheet = 'none';
    const id: string = await Store.get().createPlaylist(name, []);
    if (id.length === 0) {
      toast('创建失败，请检查服务器');
      return;
    }
    toast('已创建歌单：' + name);
    await this.loadPlaylists();
    const created: Playlist | null = this.playlists.find((p: Playlist) => p.id === id) ?? null;
    if (created !== null) {
      this.openPlaylist(created);
    }
  }

  /**
   * 给歌单加歌。
   * Subsonic 一次只能提交一批 songId，曲目多时分批调用，避免超长 URL。
   */
  private async addSongsToPlaylist(pid: string, ids: string[]): Promise<boolean> {
    const BATCH: number = 40;
    let i: number = 0;
    while (i < ids.length) {
      const batch: string[] = ids.slice(i, i + BATCH);
      const ok: boolean = await Store.get().updatePlaylist(pid, '', batch, []);
      if (!ok) {
        return false;
      }
      i += BATCH;
    }
    return true;
  }

  /** 改名 */
  private async doRenamePlaylist(name: string): Promise<void> {
    const p: Playlist | null = this.curPlaylist;
    this.sheet = 'none';
    if (p === null) {
      return;
    }
    const ok: boolean = await Store.get().updatePlaylist(p.id, name, [], []);
    if (!ok) {
      toast('改名失败');
      return;
    }
    if (this.curPlaylist !== null) {
      const updated: Playlist = {
        id: this.curPlaylist.id, name: name, songCount: this.curPlaylist.songCount,
        duration: this.curPlaylist.duration, coverArt: this.curPlaylist.coverArt,
        owner: this.curPlaylist.owner, created: this.curPlaylist.created,
        changed: Date.now(), editable: this.curPlaylist.editable, songs: this.curPlaylistSongs
      };
      this.curPlaylist = updated;
      // 之前这里传的是 `this.curPlaylist as Playlist`：请求期间用户若已退出歌单，
      // curPlaylist 是 null，这个 as 只是骗过编译器，运行时照样取 .id 崩溃
      this.syncPlaylistMeta(updated);
    }
    toast('已改名为：' + name);
  }

  /** 从歌单里移除一首（按序号删，不是按 id） */
  private async removeFromPlaylist(index: number): Promise<void> {
    const p: Playlist | null = this.curPlaylist;
    if (p === null) {
      return;
    }
    const ok: boolean = await Store.get().updatePlaylist(p.id, '', [], [index]);
    if (!ok) {
      toast('移除失败');
      return;
    }
    const left: Track[] = this.curPlaylistSongs.slice(0);
    left.splice(index, 1);
    this.setPlaylistSongs(left);
    if (this.curPlaylist !== null) {
      // 整体换新对象：@State 对对象是引用比较，改字段不会触发刷新
      const updated: Playlist = {
        id: this.curPlaylist.id, name: this.curPlaylist.name, songCount: left.length,
        duration: this.curPlaylist.duration, coverArt: this.curPlaylist.coverArt,
        owner: this.curPlaylist.owner, created: this.curPlaylist.created,
        changed: Date.now(), editable: this.curPlaylist.editable, songs: left
      };
      this.curPlaylist = updated;
      this.syncPlaylistMeta(updated);
    }
    toast('已从歌单移除');
  }

  /** 删除整个歌单 */
  private async doDeletePlaylist(p: Playlist): Promise<void> {
    const ok: boolean = await Store.get().deletePlaylist(p.id);
    if (!ok) {
      toast('删除失败');
      return;
    }
    toast('已删除歌单：' + p.name);
    if (this.curPlaylist !== null && this.curPlaylist.id === p.id) {
      this.backToMain();
    }
    this.loadPlaylists();
  }

  /** 打开「选歌单」弹层，把一首歌加进某个歌单 */
  private openPickSheet(t: Track): void {
    this.pendingTrack = t;
    this.pickedPlaylists = [];
    this.sheet = 'pick';
    if (!this.playlistsLoaded) {
      this.loadPlaylists();
    }
  }

  // ============ 歌曲长按菜单 ============

  /** 菜单头部第二行用的音质简写： · FLAC 1080k */
  /** 所有列表的长按统一走这里：记下曲目，打开菜单 */
  private openTrackMenu(t: Track): void {
    this.menuTrack = t;
    this.menuBusy = false;
    this.menuLiked = this.isLiked(t);
    this.refreshPlayNextLabel();
    this.sheet = 'trackmenu';
  }

  // ============ 播放队列 ============

  /**
   * 打开队列弹层。
   * 队列和当前曲目都存在 PlayerCore 的普通字段里，没有可观察性，
   * 所以每次打开都从播放器重新拍一份快照给 @State，界面才有数据。
   */
  private openQueue(): void {
    this.syncQueueState();
    if (this.queueSongs.length === 0) {
      this.queueEmptyHint = '还没有播放队列';
    }
    this.sheet = 'queue';
  }

  /** 把播放器的队列/当前下标同步到界面状态 */
  private syncQueueState(): void {
    const p: PlayerCore = Store.get().player();
    this.setQueueSongs(p.getQueue());
    this.queueCur = p.queueSize === 0 ? -1 : p.currentIndex;
  }

  /** 队列里点了某一首：从它开始播，原有的队列顺序与随机表都保留 */
  private async jumpQueueTo(idx: number): Promise<void> {
    if (idx < 0 || idx >= this.queueSongs.length) {
      return;
    }
    const p: PlayerCore = Store.get().player();
    const cur: number = p.currentIndex;
    if (idx === cur) {
      this.sheet = 'none';
      Router.push('pages/NowPlaying');
      return;
    }
    // playQueue 会按新顺序重建随机表，正好用来让「刚点的那首」成为随机起点
    await p.playQueue(this.queueSongs, idx);
    this.syncQueueState();
    toast('正在播放：' + this.queueSongs[idx].title);
  }

  /**
   * 从队列移除一首。
   * 注意不能直接 playQueue(剩下的歌)：那会重新开始播放并把当前曲目顶掉。
   * 这里要的是「队列瘦身，正在响的这首不受影响」，所以给 PlayerCore 加了 removeAt。
   */
  private removeFromQueue(idx: number): void {
    if (idx < 0 || idx >= this.queueSongs.length) {
      return;
    }
    const p: PlayerCore = Store.get().player();
    const removed: Track = this.queueSongs[idx];
    const wasCur: boolean = idx === this.queueCur;
    p.removeAt(idx);
    this.syncQueueState();
    if (this.queueSongs.length === 0) {
      this.queueEmptyHint = '队列已清空';
      this.sheet = 'none';
      toast('队列已清空');
      return;
    }
    if (wasCur) {
      toast('已切到下一首');
    } else {
      toast('已从队列移除：' + removed.title);
    }
  }

  /** 清空队列：连同当前曲目一起停掉 */
  private async clearQueue(): Promise<void> {
    const p: PlayerCore = Store.get().player();
    await p.clearQueue();
    this.syncQueueState();
    this.queueEmptyHint = '队列已清空';
    this.sheet = 'none';
    toast('已清空播放队列');
  }

  /** 「下一首播放」的目标是当前曲目之后的那首，显示出来避免用户猜 */
  private refreshPlayNextLabel(): void {
    const p: PlayerCore = Store.get().player();
    const q: Track[] = p.getQueue();
    if (q.length === 0) {
      this.playNextLabel = '当前没有播放，将直接开始播放';
      return;
    }
    const cur: Track | null = p.currentTrack;
    if (cur === null) {
      this.playNextLabel = '当前没有播放，将直接开始播放';
      return;
    }
    this.playNextLabel = '当前：' + cur.title;
  }

  /**
   * 下一首播放：插到当前曲目后面，而不是队尾。
   * 随机播放模式下也要跟着调整索引表，否则「下一首」不会命中这一首。
   */
  private async playNext(t: Track): Promise<void> {
    const p: PlayerCore = Store.get().player();
    if (p.queueSize === 0) {
      await p.playQueue([t], 0);
      toast('开始播放：' + t.title);
      return;
    }
    p.insertNext(t);
    toast('下一首播放：' + t.title);
  }

  /** 左滑行操作：收藏 / 取消收藏。逻辑同长按菜单，多一步通知这一行重建红心 */
  private async swipeLike(t: Track, idx: number): Promise<void> {
    const wasLiked: boolean = this.isLiked(t);
    const ok: boolean = wasLiked
      ? await Store.get().unstarSong(t.id)
      : await Store.get().starSong(t.id);
    if (!ok) {
      toast('操作失败，请检查服务器');
      return;
    }
    this.syncLikeEverywhere(t.id, !wasLiked);
    // LazyForEach 按 key 复用节点，红心藏在左滑按钮里不在 key 里；
    // 单独通知这一行，滑动关闭时图标就是新状态
    this.songs.notifyItemAt(idx);
    toast(!wasLiked ? '已收藏' : '已取消收藏');
  }

  /** 左滑露出的操作按钮：收藏 + 下一首播放 */
  @Builder
  private songSwipeEnd(t: Track, idx: number) {
    Row({ space: 10 }) {
      Column() {
        Image(this.isLiked(t)
          ? (this.isDark ? $r('app.media.ic_heart_f') : $r('app.media.ic_heart_f_d'))
          : (this.isDark ? $r('app.media.ic_heart') : $r('app.media.ic_heart_d')))
          .width(20).height(20)
        Text('收藏')
          .fontSize(10).fontFamily(APP_FONT)
          .fontColor(Theme.textSecondary(this.isDark))
          .margin({ top: 3 })
      }
      .width(58).height(52)
      .justifyContent(FlexAlign.Center)
      .borderRadius(14)
      .backgroundColor(Theme.surfaceAlt(this.isDark))
      .onClick(() => { this.swipeLike(t, idx); })

      Column() {
        Image(this.isDark ? $r('app.media.ic_next') : $r('app.media.ic_next_d'))
          .width(20).height(20)
          .fillColor(Theme.accent(this.isDark))
        Text('下一首')
          .fontSize(10).fontFamily(APP_FONT)
          .fontColor(Theme.accent(this.isDark))
          .margin({ top: 3 })
      }
      .width(58).height(52)
      .justifyContent(FlexAlign.Center)
      .borderRadius(14)
      .backgroundColor(Theme.surfaceAlt(this.isDark))
      .onClick(() => { this.playNext(t); })
    }
    .padding({ left: 8, right: 4 })
  }

  /** 加入播放队列末尾 */
  private addToQueueEnd(t: Track): void {
    const p: PlayerCore = Store.get().player();
    if (p.queueSize === 0) {
      this.playNext(t);
      return;
    }
    p.addToQueue(t);    toast('已加入队列，共 ' + p.queueSize.toString() + ' 首');
  }
  /** 菜单里的红心：收藏 / 取消收藏 */
  private async toggleMenuLike(): Promise<void> {
    if (this.menuTrack === null || this.menuBusy) {
      return;
    }
    this.menuBusy = true;
    const t: Track = this.menuTrack;
    const wasLiked: boolean = this.menuLiked;
    // 先翻转再发请求：失败时回滚，避免界面卡在中间态
    this.menuLiked = !wasLiked;
    const ok: boolean = wasLiked
      ? await Store.get().unstarSong(t.id)
      : await Store.get().starSong(t.id);
    if (!ok) {
      this.menuLiked = wasLiked;
      toast('操作失败，请检查服务器');
      this.menuBusy = false;
      return;
    }
    this.syncLikeEverywhere(t.id, !wasLiked);
    toast(!wasLiked ? '已收藏' : '已取消收藏');
    this.menuBusy = false;
  }

  /**
   * 收藏状态同步到各处：
   * 首页两排歌曲用 starredIds 判断红心，喜爱页是独立的列表，
   * 播放页/迷你播放器读的是全局 favId。三处都要跟上，否则会出现
   * 「长按里点了心，回到列表红心还是空的」。
   */
  private syncLikeEverywhere(songId: string, liked: boolean): void {
    AppStorage.setOrCreate('favId', liked ? songId : '');
    Store.get().player().syncFavoriteFromExternal(songId, liked);

    const ids: string[] = [];
    for (const id of this.starredIds) {
      if (id !== songId) {
        ids.push(id);
      }
    }
    if (liked) {
      ids.push(songId);
    }
    this.starredIds = ids;

    const songs: Track[] = [];
    for (const s of this.starredSongs) {
      if (s.id !== songId) {
        songs.push(s);
      }
    }
    if (liked && this.menuTrack !== null && this.menuTrack.id === songId) {
      songs.unshift(this.menuTrack);
    }
    this.setStarredSongs(songs);
    AppStorage.setOrCreate('starredDirty', true);
  }

  /** 跳到歌曲所属专辑 */
  private async goTrackAlbum(t: Track): Promise<void> {
    if (t.albumId.length === 0) {
      toast('这首歌没有关联专辑信息');
      return;
    }
    const al: Album = {
      id: t.albumId,
      name: t.album,
      artist: t.artist,
      artistId: '',
      coverArt: t.coverArt,
      songCount: 0,
      year: 0,
      genre: ''
    };
    this.sheet = 'none';
    await this.openAlbum(al);
  }

  /**
   * 跳到歌手页。Subsonic 的歌曲对象不带 artistId，
   * 先按名字去歌手列表里找，找不到就提示——总比跳到一个空页面好。
   */
  /**
   * 跳到歌手页。
   *
   * 不用「拉全库歌手列表再按名字精确比对」：
   * getArtists 返回的是整个索引树，歌多时又慢又容易超时；
   * 而且歌手名常有细微差异，精确比对经常落空，表现就是点了没反应。
   * 改走 search3，让服务器自己做模糊匹配，优先取同名的，没有再退回第一个候选。
   */
  private async goTrackArtist(t: Track): Promise<void> {
    this.sheet = 'none';
    const name: string = t.artist.trim();
    if (name.length === 0) {
      toast('这首歌没有歌手信息');
      return;
    }
    // 多人合唱常见「阿吉太组合、DJ沈念」，先按主歌手查，查不到再用全名
    const keys: string[] = [primaryArtist(name), name];
    // 这里不碰 this.loading：那个标志是歌手页/专辑页的骨架屏开关，
    // openArtist 进了歌手页会自己置位，在外面提前改反而可能卡住当前列表。
    for (const key of keys) {
      if (key.length === 0) {
        continue;
      }
      let list: Artist[] = [];
      try {
        const r: SearchResult = await Store.get().search(key);
        list = r.artists;
      } catch (err) {
        continue;
      }
      if (list.length === 0) {
        continue;
      }
      let hit: Artist = list[0];
      for (const a of list) {
        if (a.name.trim() === key) {
          hit = a;
          break;
        }
      }
      await this.openArtist(hit);
      return;
    }
    toast('歌手库里没有「' + name + '」');
  }


  /** 把 pendingTrack 提交到勾选的歌单 */
  private async submitPick(): Promise<void> {
    const targets: string[] = this.pickedPlaylists.slice(0);
    // 批量模式用 bulkSongIds，单曲模式用 pendingTrack
    let ids: string[] = [];
    if (this.bulkSongIds.length > 0) {
      ids = this.bulkSongIds.slice(0);
    } else if (this.pendingTrack !== null) {
      ids = [this.pendingTrack.id];
    }
    if (ids.length === 0 || targets.length === 0) {
      this.sheet = 'none';
      return;
    }
    this.sheet = 'none';
    let okCount: number = 0;
    for (const pid of targets) {
      const ok: boolean = await this.addSongsToPlaylist(pid, ids);
      if (ok) {
        okCount += 1;
      }
    }
    const howMany: string = ids.length > 1 ? ids.length.toString() + ' 首' : '1 首';
    if (okCount === 0) {
      toast('加入失败，请检查服务器');
      return;
    }
    toast('已把 ' + howMany + '加入 ' + okCount.toString() + ' 个歌单');
    this.bulkSongIds = [];
    this.pendingTrack = null;
    this.pickMode = false;
    this.loadPlaylists();
  }

  private togglePickedPlaylist(id: string): void {
    const arr: string[] = this.pickedPlaylists.slice(0);
    const i: number = arr.indexOf(id);
    if (i >= 0) {
      arr.splice(i, 1);
    } else {
      arr.push(id);
    }
    this.pickedPlaylists = arr;
  }

  private togglePickedSong(id: string): void {
    const arr: string[] = this.pickedIds.slice(0);
    const i: number = arr.indexOf(id);
    if (i >= 0) {
      arr.splice(i, 1);
    } else {
      arr.push(id);
    }
    this.pickedIds = arr;
    // 勾选态在 key 里已去掉，靠单项通知刷新这一行的 @Prop
    const pool: Track[] = this.addPool();
    for (let k = 0; k < pool.length; k++) {
      if (pool[k].id === id) {
        this.addPoolSrc.notifyItemAt(k);
        return;
      }
    }
  }

  // ============ 加入歌单弹层：歌单全选 ============

  /** 可写歌单（只读的 smart playlist 不参与全选，否则提交会被服务器拒） */
  private editablePlaylists(): Playlist[] {
    const list: Playlist[] = [];
    for (const p of this.playlists) {
      if (p.editable) {
        list.push(p);
      }
    }
    return list;
  }

  private allPlaylistsPicked(): boolean {
    const list: Playlist[] = this.editablePlaylists();
    if (list.length === 0) {
      return false;
    }
    for (const p of list) {
      if (this.pickedPlaylists.indexOf(p.id) < 0) {
        return false;
      }
    }
    return true;
  }

  /** 全选 / 取消全选：只动可写歌单，不动用户已勾的其它状态之外的项 */
  private toggleAllPlaylists(): void {
    if (this.allPlaylistsPicked()) {
      this.pickedPlaylists = [];
      return;
    }
    const all: string[] = [];
    for (const p of this.editablePlaylists()) {
      all.push(p.id);
    }
    this.pickedPlaylists = all;
  }

  /** 搜索页多选完成：ids 由 SearchPage 传进来，改走批量加歌单流程 */
  private openBulkPick(ids: string[]): void {
    if (ids.length === 0) {
      return;
    }
    this.bulkSongIds = ids.slice(0);
    this.pendingTrack = null;
    this.pickedPlaylists = [];
    this.sheet = 'pick';
    if (!this.playlistsLoaded) {
      this.loadPlaylists();
    }
  }

  /** 歌单详情里「加入歌曲」：把当前浏览的歌曲列表做成可勾选项 */
  private openAddPoolSheet(): void {
    this.pickedIds = [];
    this.refreshAddPool();
    this.sheet = 'add';
  }

  /** 确认把勾选的歌曲加入当前歌单 */
  private async submitAdd(): Promise<void> {
    const p: Playlist | null = this.curPlaylist;
    if (p === null || this.pickedIds.length === 0) {
      this.sheet = 'none';
      return;
    }
    this.sheet = 'none';
    // 先把数量记下来：请求期间弹层可能被关掉，pickedIds 会被清空，
    // 那时再读长度就会提示「已加入 0 首」
    const howMany: number = this.pickedIds.length;
    const ok: boolean = await this.addSongsToPlaylist(p.id, this.pickedIds);
    if (!ok) {
      toast('加入失败');
      return;
    }
    toast('已加入 ' + howMany.toString() + ' 首');
    this.openPlaylist(p);
  }

  /** 可选歌曲池：优先用「全部歌曲」已加载的内容，没有就取收藏 */
  // ---- 数组与虚拟化数据源的同步入口。绕过它们直接赋 @State 数组，
  // ---- LazyForEach 拿不到通知，列表会停留在旧数据上
  private setPlaylistSongs(list: Track[]): void {
    this.curPlaylistSongs = list;
    this.playlistSrc.setAll(list);
  }

  private setAlbumSongs(list: Track[]): void {
    this.curAlbumSongs = list;
    this.albumSrc.setAll(list);
  }

  private setStarredSongs(list: Track[]): void {
    this.starredSongs = list;
    this.starredSrc.setAll(list);
  }

  private setQueueSongs(list: Track[]): void {
    this.queueSongs = list;
    this.queueSrc.setAll(list);
  }

  private refreshAddPool(): void {
    this.addPoolSrc.setAll(this.addPool());
  }

  private addPool(): Track[] {
    const all: Track[] = this.songs.all();
    if (all.length > 0) {
      return all;
    }
    return this.starredSongs;
  }

  private async openArtist(a: Artist): Promise<void> {
    this.curArtist = a;
    this.curArtistAlbums = [];
    this.loading = true;
    this.crossfade(() => { this.view = 'artist'; }, 1);
    try {
      const r = await Store.get().getArtist(a.id);
      // 请求期间用户已经返回或点进了别的歌手：这份结果不能再往界面上写，
      // 否则会看到「A 的歌手的专辑列表，B 的名字」这种错位
      if (this.curArtist === null || this.curArtist.id !== a.id) {
        return;
      }
      this.curArtistAlbums = r.albums;
      if (r.artist !== null) {
        this.curArtist = r.artist;
      }
    } catch (err) {
      // 失败也把 curArtist 留着，页面至少显示歌手名而不是一片空白
      if (this.curArtist !== null && this.curArtist.id === a.id) {
        toast('加载歌手失败');
      }
    }
    this.loading = false;
  }

  private async openAlbum(al: Album): Promise<void> {
    // 记录来处：详情页返回时原路退回（专辑列表 / 歌手页 / 搜索结果 / 首页）
    this.albumOrigin = this.view;
    this.curAlbum = al;
    this.setAlbumSongs([]);
    this.loading = true;
    this.crossfade(() => { this.view = 'album'; }, 1);
    try {
      const r = await Store.get().getAlbumSongs(al.id);
      // 同上：切走之后回来的结果一律丢弃
      if (this.curAlbum === null || this.curAlbum.id !== al.id) {
        return;
      }
      this.setAlbumSongs(r.songs);
      // 详情接口的专辑信息更全（年份、封面、曲目数），有就用它覆盖列表页传来的那一份
      if (r.album !== null) {
        this.curAlbum = r.album;
      }
    } catch (err) {
      if (this.curAlbum !== null && this.curAlbum.id === al.id) {
        toast('加载专辑失败');
      }
    }
    this.loading = false;
  }

  private backToMain(): void {
    this.crossfade(() => {
      this.view = 'main';
      this.curArtist = null;
      this.curAlbum = null;
      this.setAlbumSongs([]);
      this.curArtistAlbums = [];
      this.curPlaylist = null;
      this.setPlaylistSongs([]);
    }, -1);
  }

  /** 逐层返回：详情页先退回打开它的那一页，其它子视图退回首页 */
  private goBack(): void {
    if (this.view === 'playlist') {
      this.crossfade(() => {
        this.curPlaylist = null;
        this.setPlaylistSongs([]);
        this.view = 'main';
      }, -1);
      return;
    }
    if (this.view === 'album') {
      const from: string = this.albumOrigin;
      this.curAlbum = null;
      this.setAlbumSongs([]);
      if (from === 'albums') {
        this.crossfade(() => { this.view = 'albums'; }, -1);
        return;
      }
      if (from === 'artist' && this.curArtist !== null) {
        this.crossfade(() => { this.view = 'artist'; }, -1);
        return;
      }
      if (from === 'search') {
        this.crossfade(() => { this.view = 'search'; }, -1);
        return;
      }
      this.backToMain();
      return;
    }
    if (this.view === 'search') {
      this.exitSearch();
      return;
    }
    this.backToMain();
  }

  /**
   * 关闭当前弹层，并把只属于这一次弹层的临时状态一起清掉。
   *
   * bulkSongIds / pendingTrack 是「这次要加哪几首」的载荷，只在弹层存续期间有意义。
   * 以前点遮罩关闭时只写 sheet = 'none'，批量选了 5 首又取消，id 还留着，
   * 下一回单曲「加入歌单」会把它当批量任务提交，加进去的是上一次那几首。
   */
  private closeSheet(): void {
    this.sheet = 'none';
    this.menuBusy = false;
    this.pendingTrack = null;
    this.bulkSongIds = [];
    this.pickedPlaylists = [];
    this.pickedIds = [];
  }

  /**
   * 系统返回（侧滑手势 / 返回键）：按「弹层 → 多选 → 子视图 → 系统」的顺序逐层退出。
   * 返回 true 表示事件已消费，不会退出应用。
   *
   * 弹层必须排在最前：以前这里不判 sheet，弹层打开时直接返回 false，
   * 系统就把整个页面退掉（主界面则是退出应用），弹层跟着页面一起消失，
   * 看起来就是「弹窗出来了，返回手势也关不掉它」。多选同理——返回应该先退出多选。
   */
  onBackPress(): boolean {
    if (this.sheet !== 'none') {
      this.closeSheet();
      return true;
    }
    if (this.pickMode) {
      this.pickMode = false;
      return true;
    }
    if (this.view !== 'main') {
      this.goBack();
      return true;
    }
    return false;
  }

  // ============ 搜索 ============

  private openSearch(): void {
    // 全新一次搜索：不带上次的词与结果
    this.searchQ = '';
    this.crossfade(() => { this.view = 'search'; }, 1);
  }

  private exitSearch(): void {
    // 离开搜索页时退出多选，避免下次进来残留勾选
    this.pickMode = false;
    this.searchQ = '';
    this.crossfade(() => { this.view = 'main'; }, -1);
  }

  private playSongList(songs: Track[], idx: number): void {
    if (songs.length === 0) {
      return;
    }
    Store.get().player().playQueue(songs, idx);
    toast('开始播放：' + songs[idx].title);
  }

  /**
   * 内容层切换过渡：先快速淡出（120ms），换完内容再淡入（200ms）。
   * 只动 opacity + 轻微位移，不重建列表，所以切 tab 不会掉帧、也不会丢滚动位置之外的状态。
   */
  /** 横滑换 tab：切完内容后补一次带方向的过渡，滑动方向与内容进出方向相反 */
  private switchTabWithDirection(t: string, slideFrom: number): void {
    this.crossfade(() => {
      this.navTab = t;
      this.view = 'main';
      this.error = '';
    }, slideFrom);
    if (t === 'home' && this.homeAlbums.length === 0) {
      this.loadHome();
    } else if (t === 'home') {
      this.refreshDailyIfDirty();
    } else if (t === 'songs' && this.songs.count() === 0) {
      this.loadSongs(true);
    } else if (t === 'playlists' && !this.playlistsLoaded) {
      this.loadPlaylists();
    } else if (t === 'starred') {
      // 与点按 tab 走同一套判断：滑过来时也要认「收藏状态已变」这个标记，
      // 否则在播放页收藏后滑回喜爱页，看到的还是旧列表
      const dirty: boolean = AppStorage.get<boolean>('starredDirty') ?? false;
      if (!this.starredLoaded || dirty) {
        this.loadStarred();
      }
    }
  }

  /**
   * 内容层切换过渡。
   *
   * 分三段，但交接处不留空白帧：
   *
   *   0-110ms    旧内容淡到 0.22，同时沿行进反方向退 14vp、缩到 0.994
   *   110ms      换内容，新内容立刻摆到进场位（行进方向 28vp；tab 时从下方 10vp）
   *   126ms 起   新内容用 spring(0.26, 0.92) 淡入并归位
   *
   * 之前的参数是 64ms + 0.35 + 6/8vp：退场太快、位移太小，
   * 观感更接近"闪一下"，而不是"翻了一层"——这正是切换发硬的来源。
   * 现在退场给足 110ms，位移按层级拉到 14/28vp，再用一点缩放补纵深，
   * 整体 320ms 左右完成，与鸿蒙 NavDestination 的推入节奏同量级。
   *
   * 为什么仍然不用 transition / TransitionEffect：
   * 同一个容器挂着 if/else，切分支时旧节点先卸载、新节点再挂载，
   * 两套 transition 不会重叠播放，反而会在中间多出空帧。
   * 单通道 + 显式两段，是这里唯一能保证不断帧的写法。
   *
   * slideFrom：+1 从右侧进入（进了一层），-1 从左侧进入（退了一层），0 原地（tab 切换）。
   */
  private crossfade(mutate: () => void, slideFrom: number = 0): void {
    const ctx = this.getUIContext();
    const dir: number = slideFrom === 0 ? 0 : (slideFrom > 0 ? 1 : -1);

    // 上一次还在跑：先掐掉它的定时器。
    // 不掐的话，旧定时器会在新内容已经出来之后再补一次淡入，表现为闪一下。
    if (this.transitionTimer !== -1) {
      clearTimeout(this.transitionTimer);
      this.transitionTimer = -1;
    }

    // 第一段：旧内容退场。刻意不退到全透明——
    // 留 0.22 托住交接帧，容器底色不会在中间"漏"出来。
    ctx.animateTo(Motion.exit(Motion.CONTENT_OUT), () => {
      this.contentOpacity = 0.22;
      this.contentSlide = -dir * Motion.PUSH_BACK;
      this.contentShift = -6;
      this.contentScale = Motion.PUSH_SCALE + (1 - Motion.PUSH_SCALE) * 0.6;
    });

    this.transitionTimer = setTimeout(() => {
      this.transitionTimer = -1;
      // 换内容那一帧：新内容先摆到进场位，第一次绘制就已经"偏位 + 半透"，
      // 不会出现硬切帧。
      this.contentOpacity = 0.22;
      this.contentSlide = dir * Motion.PUSH_IN;
      this.contentShift = dir === 0 ? Motion.TAB_RISE : 0;
      this.contentScale = Motion.PUSH_SCALE;
      ctx.animateTo({ duration: 0 }, () => {
        mutate();
      });
      // 隔一帧再起动画：换内容和起动画挤在同一帧，列表这种重内容会掉帧。
      this.transitionTimer = setTimeout(() => {
        this.transitionTimer = -1;
        // 入场：位移、透明度、缩放共用一个弹簧，节奏一致。
        // damping 0.92 几乎不过冲——整页内容的过冲会让人晕。
        ctx.animateTo(Motion.enter(0.26, 0.92), () => {
          this.contentOpacity = 1;
          this.contentSlide = 0;
          this.contentShift = 0;
          this.contentScale = 1;
        });
      }, 16);
    }, Motion.CONTENT_OUT);
  }

  private selectTab(t: string): void {
    // 收藏状态有变化（播放页/锁屏点了红心）就置脏，切回喜爱页必须重拉
    const dirty: boolean = AppStorage.get<boolean>('starredDirty') ?? false;
    if (this.navTab === t && this.view === 'main') {
      // 重复点同一个 tab 一般不做动作，但「喜爱」的数据过期时仍要刷新；
      // 歌单可能在别的设备上改过，重按一次就重新拉一遍
      if (t === 'starred' && dirty) {
        this.loadStarred();
      } else if (t === 'playlists' && !this.playlistsLoading) {
        this.loadPlaylists();
      }
      return;
    }
    // 换内容包在过渡里：先淡出，再切 tab 并淡入
    this.crossfade(() => {
      this.navTab = t;
      this.view = 'main';
      this.error = '';
      // 播放页下拉时要垫一层"下面的页面底色"，它得知道当前停在哪一页
      AppStorage.setOrCreate('navTab', t);
    });
    if (t === 'home' && this.homeAlbums.length === 0) {
      this.loadHome();
    } else if (t === 'home') {
      this.refreshDailyIfDirty();
    } else if (t === 'songs' && this.songs.count() === 0) {
      this.loadSongs(true);
    } else if (t === 'playlists' && !this.playlistsLoaded) {
      this.loadPlaylists();
    } else if (t === 'starred' && (!this.starredLoaded || dirty)) {
      // 首次进入，或播放页收藏状态有变化时重新拉取
      this.loadStarred();
    } else {
      this.loading = false;
    }
  }

  // ============ 组件 ============

  /**
   * 页面转场（本页作为"下层"时）。
   *
   * 只做压暗，不做位移。上层页面有两种进入方向：播放页是整屏从底部推上来，
   * 设置页是横向推入；下层若也跟着左移，播放页纵向推入时就会横着错位。
   * 变暗没有方向，两种都成立，而且"上面推、下面沉"本身就给出了纵深。
   */
  pageTransition() {
    // 恢复（上层页面退出、本页回来）比压暗快：返回时用户已经等过一次转场，
    // 背景再花 340ms 慢慢亮起来会显得拖；压暗可以慢，恢复必须短。
    PageTransitionEnter({ duration: 240, curve: Curve.FastOutSlowIn })
      .opacity(Motion.DIM)
    PageTransitionExit({ duration: Motion.PAGE_IN, curve: Curve.FastOutSlowIn })
      .opacity(Motion.DIM)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 内容层：铺满整屏，从顶部标题条和底部导航条下面穿过
      Column() {
        if (this.view === 'playlist') {
          this.playlistDetailBody()
        } else if (this.view === 'album') {
          this.albumDetailBody()
        } else if (this.view === 'artist') {
          this.artistBody()
        } else if (this.view === 'search') {
          // 搜索页自成一个组件：查询词、服务器原始结果、本地过滤、历史、多选都封在里面，
          // 主页面只接收三个出口——播放、进专辑、把选中的歌拿去加歌单。
          SearchPage({
            onPlay: (list: Track[], idx: number) => { this.playSongList(list, idx); },
            onOpenAlbum: (a: Album) => { this.openAlbum(a); },
            onBulkPick: (ids: string[]) => { this.openBulkPick(ids); },
            // 长按歌曲：复用「全部歌曲」等列表的同一张菜单，不再进多选
            onTrackMenu: (t: Track) => { this.openTrackMenu(t); },
            q: $searchQ,
            pickMode: $pickMode
          })
        } else if (this.view === 'albums') {
          this.albumsBody()
        } else if (this.navTab === 'home') {
          this.homeBody()
        } else if (this.navTab === 'songs') {
          this.songsBody()
        } else if (this.navTab === 'playlists') {
          this.playlistsBody()
        } else if (this.navTab === 'starred') {
          this.starredBody()
        } else {
          // 设置页：标题交给面板内部，作为滚动首项，跟内容一起滚走
          Column() {
            SettingsPanel({ bottomPad: BOTTOM_PAD }) {
              this.pageHeader()
            }
          }
          .width('100%').height('100%')
        }
      }
      .width('100%').height('100%')
      // 淡入淡出 + 轻微纵向位移，由 crossfade 驱动（见下方方法）
      .opacity(this.contentOpacity)
      .translate({ x: this.contentSlide, y: this.contentShift })
      .scale({ x: this.contentScale, y: this.contentScale })
      // 左右滑动：五个主界面之间切换；子页面右滑退回上一层。
      //
      // 手势必须挂在「内容层」而不是页面根节点上。挂根节点时它是弹层的祖先，
      // 弹层打开后遮罩照样落在它的命中范围里，横滑手势仍然参与识别，
      // 会把系统的侧滑返回手势挤掉——这就是「弹窗出来了，手势返回不了」。
      // 挂内容层后，弹层（兄弟节点）盖在上面时命中不到这里，手势自然不参与。
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 20 })
          .onActionEnd((event: GestureEvent) => {
            this.handleSwipe(event.offsetX, event.offsetY);
          })
      )
      // 屏幕左右边缘留给系统全面屏返回手势：从边缘起手时不接管，
      // 否则应用内横滑会先一步识别，系统返回手势被取消，页面就退不回去了。
      .onGestureJudgeBegin((info: GestureInfo, event: BaseGestureEvent) => {
        const list: FingerInfo[] = event.fingerList;
        if (list.length === 0) {
          return GestureJudgeResult.CONTINUE;
        }
        const x: number = Number(list[0].localX);
        const w: number = Number(AppStorage.get<number>('winWidth') ?? 0);
        if (x < EDGE_BACK_W || (w > 0 && x > w - EDGE_BACK_W)) {
          return GestureJudgeResult.REJECT;
        }
        return GestureJudgeResult.CONTINUE;
      })

      // 顶部不再有悬浮遮罩层：标题跟随内容一起滚动

      // 底部悬浮：迷你播放器浮在导航条之上；全高容器只负责贴底，不拦截列表点击。
      //
      // 多选时必须整块让开。原因：搜索页的多选操作条（全选 / 已选 N 首 / 加入歌单）
      // 是画在内容层里的，而这一层叠在内容层上面——两条一重叠，
      // 操作条右边那颗「加入歌单」正好落在迷你条与导航条底下，
      // 点上去命中的是胶囊（进播放页/切 tab），看起来就是「加入歌单不生效」。
      // 多选时底部导航本来也没用（还会误触切 tab），直接收起，操作条顺势占了它的位置。
      if (!this.pickMode) {
        Column() {
          MiniPlayer({
            onTap: () => { Router.push('pages/NowPlaying'); },
            onOpenQueue: () => { this.openQueue(); }
          })
          BottomNav({
            cur: this.navTab,
            onSelect: (t: string) => { this.selectTab(t); }
          })
            .margin({ top: 10, bottom: bottomInset() + 10 })
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.End)
        .hitTestBehavior(HitTestMode.None)
        // 双栏只在多选时收起/展开：给一点上滑 + 淡入，和弹层的语言一致
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.translate({ y: 12 })
            .animation(Motion.enter(0.34, 0.9))
            .combine(TransitionEffect.opacity(0).animation({ duration: 180, curve: Curve.FastOutSlowIn })),
          TransitionEffect.OPACITY.animation(Motion.exit(180))))
      }

      // 歌单相关弹层：盖在最上层。遮罩铺满，面板贴底，点遮罩关闭
      if (this.sheet !== 'none') {
        Stack({ alignContent: Alignment.Bottom }) {
          SheetScrim({ onClose: () => { this.closeSheet(); } })
            // 遮罩与面板分开控节奏：
            //   进场 240ms（Friction）—— 面板弹簧要走 380ms，遮罩太快会"背景先黑、面板后到"；
            //   退场 190ms —— 收起要干脆，比面板先一步消失，不留半透明压着内容。
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.animation(Motion.scrim(Motion.SCRIM_IN)),
              TransitionEffect.OPACITY.animation(Motion.scrim(Motion.SCRIM_OUT))))

          Column() {
            if (this.sheet === 'create') {
              PlaylistNameSheet({
                title: '新建歌单',
                onSubmit: (name: string) => { this.doCreatePlaylist(name); },
                onClose: () => { this.sheet = 'none'; }
              })
            } else if (this.sheet === 'rename') {
              PlaylistNameSheet({
                title: '重命名歌单',
                onSubmit: (name: string) => { this.doRenamePlaylist(name); },
                onClose: () => { this.sheet = 'none'; }
              })
            } else if (this.sheet === 'more') {
              this.playlistMoreSheet()
            } else if (this.sheet === 'pick') {
              this.pickPlaylistSheet()
            } else if (this.sheet === 'trackmenu') {
              this.trackMenuSheet()
            } else if (this.sheet === 'add') {
              this.addSongsSheet()
            } else if (this.sheet === 'queue') {
              this.queueSheet()
            } else if (this.sheet === 'sort') {
              this.sortSheet()
            }
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
          // 面板进场：从下方 100% 平移回原位，退场反过来。
          // 用 translate 而不是 scale/opacity，弹层的「贴底抽出」手感更准。
          //
          // 入场用 spring 而不是 FastOutSlowIn：
          // 线性缓动到位的瞬间速度归零，观感像「撞停」；弹簧会自己收尾，
          // 末尾保留一点点过冲再回落，这是原生弹层的手感来源。
          // 注意 spring 曲线会忽略 duration，response/dampingFraction 才是真正的旋钮。
          // 退场仍旧用固定时长缓动——退场要的是「干脆消失」，回弹反而拖沓。
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.translate({ y: '100%' })
              .animation(Motion.sheet())
              .combine(TransitionEffect.opacity(0)
                .animation({ duration: 160, curve: Curve.FastOutSlowIn })),
            TransitionEffect.translate({ y: '100%' })
              .animation({ duration: 240, curve: Curve.Sharp })
              .combine(TransitionEffect.opacity(0)
                .animation({ duration: 160, curve: Curve.FastOutSlowIn }))))
        }
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
    // 五个主界面各有一套底色，切 tab 时跟着换。
    // 不能硬切：页面本身是 crossfade 的，底色一闪一闪会很跳，
    // 所以挂一个和 crossfade 同时长的渐变。
    .backgroundColor(Theme.pageBg(this.isDark, this.navTab))
    .animation({ duration: Motion.THEME, curve: Curve.FastOutSlowIn })
  }

  /**
   * 横滑手势：主界面按底部导航顺序切换；子页面右滑退回上一层。
   * 搜索页只接管「右滑返回」（搜索页左上角不再放返回钮）；
   * 左滑不处理，留给专辑卡片横向滚动。
   */
  private handleSwipe(dx: number, dy: number): void {
    // 弹层打开时一律不翻页/不切 tab：这一刻的横滑只可能是想关弹层。
    // 手势已经挂到内容层、正常命中不到，这里是兜底——万一遮罩做成穿透，
    // 也绝不能出现「滑一下没关掉弹窗，页面反而切到下一个 tab」。
    if (this.sheet !== 'none') {
      return;
    }
    if (Math.abs(dx) < 60 || Math.abs(dx) < Math.abs(dy) * 1.5) {
      return;
    }
    if (this.view === 'search') {
      if (dx > 0) {
        this.exitSearch();
      }
      return;
    }
    if (this.view !== 'main') {
      if (dx > 0) {
        this.goBack();
      }
      return;
    }
    const tabs: string[] = ['home', 'songs', 'playlists', 'starred', 'settings'];
    const i: number = tabs.indexOf(this.navTab);
    if (i < 0) {
      return;
    }
    const next: number = dx < 0 ? i + 1 : i - 1;
    if (next >= 0 && next < tabs.length) {
      // 横滑换 tab：内容跟着手指方向进出（左滑下一屏从右侧推入，右滑上一屏从左侧推入），
      // 与点击 tab 的原地淡入区分开，横滑更像真的翻了一屏。
      this.switchTabWithDirection(tabs[next], dx < 0 ? 1 : -1);
    }
  }

  private detailTitle(): string {
    if (this.view === 'artist') {
      return this.curArtist !== null ? this.curArtist.name : '歌手';
    }
    return this.curAlbum !== null ? this.curAlbum.name : '专辑';
  }

  private headerTitle(): string {
    if (this.navTab === 'home') {
      return '发现';
    }
    if (this.navTab === 'songs') {
      return '全部歌曲';
    }
    if (this.navTab === 'playlists') {
      return '歌单';
    }
    if (this.navTab === 'starred') {
      return '喜爱的歌';
    }
    return '设置';
  }

  private headerMeta(): string {
    if (this.navTab === 'home') {
      return this.albums.length > 0 ? '音乐库共 ' + this.albums.length.toString() + ' 张专辑' : '';
    }
    if (this.navTab === 'songs') {
      if (this.songsCount === 0) {
        return '';
      }
      // 未读全时显示「已加载 / 总数」，读全后只显示总数
      if (!this.songsDone && this.songsTotal > this.songsCount) {
        return '已加载 ' + this.songsCount.toString() + ' / 共 ' + this.songsTotal.toString() + ' 首';
      }
      return this.songsCount.toString() + ' 首';
    }
    if (this.navTab === 'playlists') {
      if (!this.playlistsLoaded) {
        return '';
      }
      return this.playlists.length > 0 ? this.playlists.length.toString() + ' 个歌单' : '';
    }
    if (this.navTab === 'starred') {
      return this.starredSongs.length > 0 ? this.starredSongs.length.toString() + ' 首' : '';
    }
    return '';
  }

  /** 顶部留白：状态栏 + 一点呼吸空间（标题随内容滚动，不再覆盖遮罩） */
  private topPad(): number {
    return topInset() + 10;
  }

  /** 页面标题：作为列表首项参与滚动，不再是浮在最上层的毛玻璃条 */
  @Builder
  private pageHeader() {
    Row() {
      Column() {
        Text(this.headerTitle())
          .fontSize(28).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Bold)
          .fontColor(Theme.text(this.isDark))
        if (this.headerMeta().length > 0) {
          Text(this.headerMeta())
            .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
            .margin({ top: 3 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      // 排序 + 搜索 + 刷新入口：只在「全部歌曲」页显示
      if (this.navTab === 'songs') {
        Stack({ alignContent: Alignment.Center }) {
          Image((this.isDark ? $r('app.media.ic_refresh') : $r('app.media.ic_refresh_d')))
            .width(20).height(20)
        }
        .width(38).height(38)
        .borderRadius(19)
        .backgroundColor(Theme.surfaceAlt(this.isDark))
        .margin({ right: 10 })
        .onClick(() => { this.refreshSongs(); })

        Stack({ alignContent: Alignment.Center }) {
          Image((this.isDark ? $r('app.media.ic_sort') : $r('app.media.ic_sort_d')))
            .width(20).height(20)
        }
        .width(38).height(38)
        .borderRadius(19)
        .backgroundColor(Theme.surfaceAlt(this.isDark))
        .margin({ right: 10 })
        .onClick(() => { this.sheet = 'sort'; })

        Stack({ alignContent: Alignment.Center }) {
          Image((this.isDark ? $r('app.media.ic_search') : $r('app.media.ic_search_d')))
            .width(20).height(20)
        }
        .width(38).height(38)
        .borderRadius(19)
        .backgroundColor(Theme.surfaceAlt(this.isDark))
        .onClick(() => { this.openSearch(); })
      }
      // 新建歌单入口：只在「歌单」页显示
      if (this.navTab === 'playlists') {
        Stack({ alignContent: Alignment.Center }) {
          Text('+')
            .fontSize(24).fontFamily(APP_FONT)
            .fontColor(Theme.accent(this.isDark))
            .margin({ bottom: 2 })
        }
        .width(38).height(38)
        .borderRadius(19)
        .backgroundColor(Theme.surfaceAlt(this.isDark))
        .onClick(() => { this.sheet = 'create'; })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: this.topPad(), bottom: 14 })
    .alignItems(VerticalAlign.Center)
  }

  /** 「全部专辑」整页标题：没有返回钮，右滑或点底部 tab 离开（无参 builder，专辑数异步加载后能重建） */
  @Builder
  private albumsHeader() {
    Row() {
      Column() {
        Text('全部专辑')
          .fontSize(28).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Bold)
          .fontColor(Theme.text(this.isDark))
        if (this.albums.length > 0) {
          Text(this.albums.length.toString() + ' 张')
            .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
            .margin({ top: 3 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: this.topPad(), bottom: 14 })
    .alignItems(VerticalAlign.Center)
  }

  /** 详情页顶部：返回钮 + 标题，同样跟随内容滚动 */
  @Builder
  private pageBackHeader(title: string) {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        Image((this.isDark ? $r('app.media.ic_back') : $r('app.media.ic_back_d')))
          .width(20).height(20)
      }
      .width(38).height(38)
      .borderRadius(19)
      .backgroundColor(Theme.surfaceAlt(this.isDark))
      .onClick(() => { this.goBack(); })

      if (title.length > 0) {
        Text(title)
          .fontSize(20).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Bold).fontColor(Theme.text(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1).margin({ left: 12 })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: this.topPad(), bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private emptyState(icon: Resource, text: string) {
    Column() {
      Image(icon).width(38).height(38).opacity(0.3)
      Text(text).fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark)).margin({ top: 12 })
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
  }

  // ============ 专辑列表（四列行，顶部留出悬浮标题条的高度） ============
  /** 把专辑四张成行，交给 List 渲染：比 Grid 里的占位更可控 */
  private quadRows(list: Album[]): Album[][] {
    const rows: Album[][] = [];
    let i: number = 0;
    while (i < list.length) {
      const row: Album[] = [];
      let k: number = 0;
      while (k < 4 && i + k < list.length) {
        row.push(list[i + k]);
        k += 1;
      }
      rows.push(row);
      i += 4;
    }
    return rows;
  }

  /** 每行三张：首页「全部专辑」板块用 3 列 × 2 行 */
  private tripleRows(list: Album[]): Album[][] {
    const rows: Album[][] = [];
    let i: number = 0;
    while (i < list.length) {
      const row: Album[] = [list[i]];
      if (i + 1 < list.length) {
        row.push(list[i + 1]);
      }
      if (i + 2 < list.length) {
        row.push(list[i + 2]);
      }
      rows.push(row);
      i += 3;
    }
    return rows;
  }

  private currentAlbums(): Album[] {
    return this.view === 'artist' ? this.curArtistAlbums : this.albums;
  }

  /** 四列网格中的一张：不足 4 张时用空列占位，保证每张宽度一致 */
  @Builder
  private albumCellAt(row: Album[], i: number) {
    Column() {
      if (i < row.length) {
        AlbumCell({
          album: row[i],
          coverUrl: this.cover(row[i].coverArt, 300),
          compact: true
        })
      }
    }
    .layoutWeight(1)
    .onClick(() => {
      if (i < row.length) {
        this.openAlbum(row[i]);
      }
    })
  }

  @Builder
  private albumsList() {
    List() {
      // 标题栏作为列表首项，跟着内容一起滚动（无悬浮遮罩）
      ListItem() {
        if (this.view === 'artist') {
          this.pageBackHeader(this.detailTitle())
        } else if (this.view === 'albums') {
          this.albumsHeader()
        } else {
          this.pageHeader()
        }
      }
      ForEach(this.quadRows(this.currentAlbums()), (row: Album[], rowIdx: number) => {
        ListItem() {
          Row() {
            this.albumCellAt(row, 0)
            Column().width(10)
            this.albumCellAt(row, 1)
            Column().width(10)
            this.albumCellAt(row, 2)
            Column().width(10)
            this.albumCellAt(row, 3)
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 14 })
          .alignItems(VerticalAlign.Top)
        }
      }, (row: Album[], rowIdx: number) => 'row_' + rowIdx.toString() + '_' + row[0].id)
      // 底部空白：给悬浮导航条与迷你播放器让位，滚动时内容从下方穿过
      ListItem() {
        Column().width('100%').height(BOTTOM_PAD)
      }
    }
    .width('100%').layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  // ============ 首页（发现） ============

  /** 板块标题：右侧可带一个动作（换一批 / 全部） */
  @Builder
  private sectionHeader(title: string, action: string) {
    Row() {
      Text(title)
        .fontSize(18).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Bold)
        .fontColor(Theme.text(this.isDark))
      Row().layoutWeight(1)
      if (action.length > 0) {
        Text(action)
          .fontSize(12).fontFamily(APP_FONT)
          .fontColor(title === '每日推荐' ? Theme.textTertiary(this.isDark) : Theme.accent(this.isDark))
          .padding({ left: 12, top: 6, bottom: 6 })
          .onClick(() => { this.onSectionAction(title); })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  private onSectionAction(title: string): void {
    if (title === '随机歌曲') {
      this.reloadRandom();
    } else if (title === '全部专辑') {
      this.crossfade(() => { this.view = 'albums'; }, 1);
    }
  }

  // ============ 最近播放 ============

  /**
   * 首页「最近播放」：横向卡片。
   * 封面底部那条细线是「听到哪」——比写一行 1:23 更直观，
   * 一眼就能分出「听完了」和「刚开头」。
   */
  @Builder
  private recentRow() {
    Scroll() {
      Row({ space: 12 }) {
        ForEach(this.recent, (e: RecentEntry, i: number) => {
          Column() {
            Stack({ alignContent: Alignment.BottomStart }) {
              if (this.cover(e.track.coverArt, 200).length > 0) {
                Image(this.cover(e.track.coverArt, 200))
                  .width(92).height(92)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(10)
              } else {
                Column()
                  .width(92).height(92)
                  .borderRadius(10)
                  .backgroundColor('#22808CA0')
              }
              if (e.track.duration > 0 && e.pos > 0) {
                Row() {
                  Row()
                    .width(Math.min(100, Math.max(2, e.pos / e.track.duration * 100)).toString() + '%')
                    .height(2.5)
                    .backgroundColor('#F2F5F8FF')
                }
                .width(92).height(2.5)
                .backgroundColor('#4D000000')
                .borderRadius({ bottomLeft: 10, bottomRight: 10 })
              }
            }
            .width(92).height(92)

            Text(e.track.title)
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontSize(12).fontFamily(APP_FONT)
              .fontColor(Theme.text(this.isDark))
              .margin({ top: 6 })

            // pos 是毫秒（AVPlayer 的 currentTime），必须用 Fmt.time 而不是按秒算，
            // 否则 1:23 会被显示成 1383:20 —— 这正是「最近播放时间不对」的来源
            Text(e.pos >= 5000 ? ('听到 ' + Fmt.time(e.pos)) : e.track.artist)
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontSize(10).fontFamily(APP_FONT)
              .fontColor(Theme.textTertiary(this.isDark))
              .margin({ top: 2 })
          }
          .width(92)
          .alignItems(HorizontalAlign.Start)
          .onClick(() => { this.playRecent(i); })
        }, (e: RecentEntry) => e.track.id + '_' + e.at.toString())
      }
      .padding({ left: 20, right: 20, bottom: 4 })
      .alignItems(VerticalAlign.Top)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
  }

  /**
   * 点最近播放：把这份记录整体作为队列（前后翻就是最近听过的顺序），
   * 并回到上次听到的位置。快听完了（离结尾不足 8 秒）就不续了，从头再放。
   */
  private playRecent(idx: number): void {
    if (idx < 0 || idx >= this.recent.length) {
      return;
    }
    const e: RecentEntry = this.recent[idx];
    const list: Track[] = [];
    for (const it of this.recent) {
      list.push(it.track);
    }
    const d: number = e.track.duration;
    let pos: number = -1;
    // 阈值全部是毫秒：听够 5 秒才续；离结尾不足 8 秒就不续（那几秒残余没有意义，
    // 续过去会马上触发 completed，反而像「点了没反应」）
    if (e.pos >= 5000 && (d <= 0 || e.pos < d - 8000)) {
      pos = e.pos;
    }
    Store.get().player().playQueue(list, idx, pos);
    toast(pos > 0 ? ('接着听：' + e.track.title) : ('开始播放：' + e.track.title));
  }

  /** 两列一行的数据切分：4 首 → 2 行 × 2 列 */
  /**
   * 首页 2×2 网格：每个板块 4 首排成两行两列。
   * 不接数组参数：@Builder 的参数是按值传递的，异步加载完成后不会触发重建，
   * 必须让 builder 内部直接读 @State，才能跟着数据变化刷新。
   */
  /**
   * 2×2 网格的行 key：把本行每首歌的收藏状态查好后交给纯函数拼。
   * 只带 id 时，点第二列的红心不会触发重建，图标会停在旧状态。
   */
  private rowKey(prefix: string, r: number, row: Track[]): string {
    const liked: boolean[] = [];
    for (const t of row) {
      liked.push(this.isLiked(t));
    }
    return pairKey(prefix, r, row, liked);
  }

  @Builder
  private homeRandomList() {
    ForEach(pairTracks(this.homeRandom), (row: Track[], r: number) => {
      Row() {
        this.gridCell(row[0], r * 2, true)
        Column().width(16)
        if (row.length > 1) {
          this.gridCell(row[1], r * 2 + 1, true)
        } else {
          Column().layoutWeight(1)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })
      .alignItems(VerticalAlign.Top)
    }, (row: Track[], r: number) => this.rowKey('rnd_', r, row))
  }

  @Builder
  private homeDailyList() {
    ForEach(pairTracks(this.homeDaily), (row: Track[], r: number) => {
      Row() {
        this.gridCell(row[0], r * 2, false)
        Column().width(16)
        if (row.length > 1) {
          this.gridCell(row[1], r * 2 + 1, false)
        } else {
          Column().layoutWeight(1)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })
      .alignItems(VerticalAlign.Top)
    }, (row: Track[], r: number) => this.rowKey('day_', r, row))
  }

  /** 2×2 网格里的一个单元格：点击播放 + 行内红心 */
  @Builder
  private gridCell(t: Track, idx: number, random: boolean) {
    Column() {
      HomeSongRow({
        track: t,
        coverUrl: this.cover(t.coverArt, 120),
        liked: this.isLiked(t),
        onToggle: () => { this.toggleLike(t); }
      })
    }
    .layoutWeight(1)
    .onClick(() => {
      if (random) {
        this.playSongList(this.homeRandom, idx);
      } else {
        this.playSongList(this.homeDaily, idx);
      }
    })
  }

  /** 首页专辑一行三张（3 列 × 2 行 = 6 张） */
  @Builder
  private albumRowOf(row: Album[]) {
    Row() {
      this.homeAlbumCell(row, 0)
      Column().width(12)
      this.homeAlbumCell(row, 1)
      Column().width(12)
      this.homeAlbumCell(row, 2)
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 18 })
    .alignItems(VerticalAlign.Top)
  }

  /** 3 列网格中的一张：不足 3 张时用空列占位保持宽度一致 */
  @Builder
  private homeAlbumCell(row: Album[], i: number) {
    Column() {
      if (i < row.length) {
        AlbumCell({ album: row[i], coverUrl: this.cover(row[i].coverArt, 300) })
      }
    }
    .layoutWeight(1)
    .onClick(() => {
      if (i < row.length) {
        this.openAlbum(row[i]);
      }
    })
  }

  @Builder
  private homeBody() {
    List() {
      ListItem() {
        this.pageHeader()
      }

      // 最近播放（横向卡片，点一下续上上次听到的位置）
      if (this.recent.length > 0) {
        ListItem() {
          Column() {
            this.sectionHeader('最近播放', '')
            this.recentRow()
          }
          .width('100%')
        }
      }

      // 随机歌曲（2 行 × 2 列，共四首）
      ListItem() {
        Column() {
          this.sectionHeader('随机歌曲', '换一批')
          this.homeRandomList()
        }
        .width('100%')
      }

      // 每日推荐（当天固定，2 行 × 2 列）
      ListItem() {
        Column() {
          this.sectionHeader('每日推荐', '每天更新')
          this.homeDailyList()
        }
        .width('100%')
      }

      // 全部专辑（只展示两行，其余进单独页面）
      ListItem() {
        this.sectionHeader('全部专辑', '全部')
      }
      ForEach(this.tripleRows(this.homeAlbums), (row: Album[], r: number) => {
        ListItem() {
          this.albumRowOf(row)
        }
      }, (row: Album[], r: number) => 'halb_' + r.toString() + '_' + row[0].id)

      // 底部空白：给悬浮导航条与迷你播放器让位
      ListItem() {
        Column().width('100%').height(BOTTOM_PAD)
      }
    }
    .width('100%').layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  albumsBody() {
    if (this.error.length > 0 && this.albums.length === 0) {
      this.emptyState((this.isDark ? $r('app.media.ic_nas') : $r('app.media.ic_nas_d')), this.error)
    } else {
      this.albumsList()
    }
  }

  // ============ 全部歌曲 ============
  /** 排序方式弹层：单选列表，当前项打勾 */
  @Builder
  private sortSheet() {
    Column() {
      Row() {
        Text('排序方式')
          .fontSize(15).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Medium)
          .fontColor(Theme.text(this.isDark))
          .layoutWeight(1)
        Text('取消')
          .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
          .onClick(() => { this.sheet = 'none'; })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 8 })

      ForEach(SORT_OPTIONS, (m: SongsSort) => {
        Row() {
          Column() {
            Text(this.sortLabel(m))
              .fontSize(15).fontFamily(APP_FONT)
              .fontColor(m === this.songsSort
                ? Theme.accent(this.isDark) : Theme.text(this.isDark))
            if (this.sortDesc(m).length > 0) {
              Text(this.sortDesc(m))
                .fontSize(11.5).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                .margin({ top: 3 })
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          // 当前项打勾
          if (m === this.songsSort) {
            Text('✓')
              .fontSize(16).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
              .padding({ left: 12 })
          }
        }
        .width('100%')
        .height(50)
        .padding({ left: 20, right: 20 })
        .onClick(() => { this.applySortChoice(m); })

        if (m !== SORT_OPTIONS[SORT_OPTIONS.length - 1]) {
          Divider().color(Theme.divider(this.isDark)).margin({ left: 20, right: 20 })
        }
      }, (m: SongsSort) => m)

      Column().height(12)
    }
    .width('100%')
    .backgroundColor(Theme.surface(this.isDark))
    .borderRadius({ topLeft: 20, topRight: 20 })
    // 底部安全区：弹层贴底，需自己避让系统手势条
    .padding({ bottom: bottomInset() + 8 })
  }

  @Builder
  songsBody() {
    if (this.songsCount === 0) {
      if (this.songsLoading) {
        Column() {
          LoadingProgress().width(30).height(30).color(Theme.accent(this.isDark))
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        this.emptyState((this.isDark ? $r('app.media.ic_note') : $r('app.media.ic_note_d')),
          this.error.length > 0 ? this.error : '暂无歌曲')
      }
    } else {
      List() {
        // 标题栏作为列表首项，跟着内容一起滚动
        ListItem() {
          this.pageHeader()
        }
        LazyForEach(this.songs, (t: Track, idx: number) => {
          ListItem() {
            SongRow({ track: t, index: idx, coverUrl: this.cover(t.coverArt, 120) })
              .gesture(
                LongPressGesture({ repeat: false, duration: 450 })
                  .onAction(() => { this.openTrackMenu(t); })
              )
          }
          // 左滑露出「收藏 / 下一首」：长按菜单更全，但两步操作太重，
          // 高频动作（收藏、插播）值得一步到位（网易云 / Spotify 的做法）
          .swipeAction({ end: this.songSwipeEnd(t, idx) })
          .onClick(() => { this.playSongList(this.songs.all(), idx); })
        }, (t: Track, idx: number) => t.id + '#' + idx)
        // 底部空白：给悬浮导航条与迷你播放器让位
        ListItem() {
          Column().width('100%').height(BOTTOM_PAD)
        }
      }
      .width('100%').layoutWeight(1)
      .scrollBar(BarState.Off)
      .divider({ color: Theme.divider(this.isDark), strokeWidth: 0.5, startMargin: 68, endMargin: 20 })
      .onReachEnd(() => { this.loadSongs(false); })
    }
  }

  // ============ 歌单列表 ============
  @Builder
  playlistsBody() {
    // 标题栏始终渲染：空歌单时右上角的「+」是唯一的新建入口，
    // 之前把它放进 else 分支，导致没有歌单时整页没有任何新建入口。
    Column() {
      this.pageHeader()

      if (this.playlists.length === 0) {
        if (this.playlistsLoading || !this.playlistsLoaded) {
          Column() {
            LoadingProgress().width(30).height(30).color(Theme.accent(this.isDark))
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          Column() {
            Image(this.isDark ? $r('app.media.ic_list') : $r('app.media.ic_list_d'))
              .width(46).height(46).opacity(0.4)
            Text(this.error.length > 0 ? this.error : '还没有歌单')
              .fontSize(13).fontFamily(APP_FONT)
              .fontColor(this.error.length > 0 ? Theme.accent(this.isDark) : Theme.textSecondary(this.isDark))
              .margin({ top: 14 })
            // 空状态下直接给按钮，不依赖用户去找右上角
            Row() {
              Text('+')
                .fontSize(18).fontFamily(APP_FONT).fontColor(Color.White)
                .margin({ bottom: 2 })
              Text('新建歌单')
                .fontSize(14).fontFamily(APP_FONT).fontColor(Color.White)
                .margin({ left: 5 })
            }
            .padding({ left: 22, right: 22 })
            .height(42)
            .borderRadius(21)
            .backgroundColor(Theme.accent(this.isDark))
            .margin({ top: 20 })
            .onClick(() => { this.sheet = 'create'; })
          }
          .width('100%').layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          // 上移一点，避开底部悬浮导航
          .padding({ bottom: 80 })
        }
      } else {
        List() {
          ForEach(this.playlists, (p: Playlist) => {
            ListItem() {
              PlaylistRow({
                playlist: p,
                covers: this.coversOf(p),
                onTap: () => { this.openPlaylist(p); },
                onMore: () => { this.openPlaylist(p); }
              })
            }
          }, (p: Playlist) => this.playlistKey(p))
          ListItem() {
            Column().width('100%').height(BOTTOM_PAD)
          }
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%').height('100%')
  }

  /** 取某个歌单的封面数组；没算出来时返回空数组，组件会显示占位 */
  private coversOf(p: Playlist): string[] {
    const c: string[] | undefined = this.playlistCovers[p.id];
    return c === undefined ? [] : c;
  }

  /**
   * 列表项 key。不是 @Prop 的成员不参与状态追踪，封面又是异步补进来的，
   * 所以把封面的数量与首图拼进 key：封面到位时 key 变化 → 列表项重建 → 拼图出现。
   */
  private playlistKey(p: Playlist): string {
    const c: string[] = this.coversOf(p);
    const sig: string = c.length === 0 ? '0' : c.length.toString() + '_' + c[0];
    return 'pl_' + p.id + '_' + p.songCount.toString() + '_' + p.name + '_' + sig;
  }

  // ============ 歌单详情 ============
  @Builder
  playlistDetailBody() {
    List() {
      ListItem() {
        this.pageBackHeader('')
      }
      // 头部：封面 + 名称 + 统计 + 操作
      ListItem() {
        this.playlistHeader()
      }
      if (this.curPlaylistSongs.length === 0) {
        ListItem() {
          Column() {
            if (this.playlistLoading) {
              LoadingProgress().width(28).height(28).color(Theme.accent(this.isDark))
            } else {
              Text(this.curPlaylist !== null && this.curPlaylist.editable
                ? '歌单还是空的，点「加入歌曲」挑几首'
                : '这个歌单还没有歌曲')
                .fontSize(13).fontFamily(APP_FONT)
                .fontColor(Theme.textSecondary(this.isDark))
            }
          }
          .width('100%').height(160).justifyContent(FlexAlign.Center)
        }
      } else {
        LazyForEach(this.playlistSrc, (t: Track, idx: number) => {
          ListItem() {
            SongRow({
              track: t,
              index: idx,
              coverUrl: this.cover(t.coverArt, 120)
            })
            .gesture(
              LongPressGesture({ repeat: false, duration: 450 })
                .onAction(() => {
                  // 歌单详情里多一项「从本歌单移除」，记下序号供它使用
                  this.removingIndex = idx;
                  this.openTrackMenu(t);
                })
            )
          }
          .onClick(() => { this.playSongList(this.curPlaylistSongs, idx); })
        }, (t: Track, idx: number) => 'pls_' + t.id + '#' + idx.toString())
      }
      ListItem() {
        Column().width('100%').height(BOTTOM_PAD)
      }
    }
    .width('100%').layoutWeight(1)
    .scrollBar(BarState.Off)
    .divider({ color: Theme.divider(this.isDark), strokeWidth: 0.5, startMargin: 68, endMargin: 20 })
  }

  @Builder
  private playlistHeader() {
    Column() {
      Row() {
        // 封面用详情里前四首拼，比列表页更准
        PlaylistCover({ covers: this.detailCovers(), boxSize: 104, radius: 14 })
        Column() {
          Text(this.curPlaylist !== null ? this.curPlaylist.name : '')
            .fontSize(18).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Medium)
            .fontColor(Theme.text(this.isDark))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.playlistMetaText())
            .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
            .margin({ top: 6 })
          if (this.curPlaylist !== null && this.curPlaylist.owner.length > 0) {
            Text('创建者：' + this.curPlaylist.owner)
              .fontSize(11).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
              .margin({ top: 4 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .margin({ left: 14 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 播放全部 / 加入歌曲 / 更多
      Row() {
        Row() {
          Image(this.isDark ? $r('app.media.ic_play') : $r('app.media.ic_play_d'))
            .width(14).height(14)
            .fillColor(Color.White)
          Text('播放全部')
            .fontSize(14).fontFamily(APP_FONT).fontColor(Color.White)
            .margin({ left: 6 })
        }
        .layoutWeight(1)
        .height(42)
        .justifyContent(FlexAlign.Center)
        .borderRadius(21)
        .backgroundColor(Theme.accent(this.isDark))
        .opacity(this.curPlaylistSongs.length > 0 ? 1 : 0.4)
        .onClick(() => {
          if (this.curPlaylistSongs.length > 0) {
            this.playSongList(this.curPlaylistSongs, 0);
          }
        })

        if (this.curPlaylist !== null && this.curPlaylist.editable) {
          Text('加入歌曲')
            .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
            .height(42).padding({ left: 14, right: 14 })
            .borderRadius(21).margin({ left: 10 })
            .backgroundColor(Theme.surfaceAlt(this.isDark))
            .textAlign(TextAlign.Center)
            .onClick(() => { this.openAddPoolSheet(); })

          Text('更多')
            .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
            .height(42).padding({ left: 14, right: 14 })
            .borderRadius(21).margin({ left: 8 })
            .backgroundColor(Theme.surfaceAlt(this.isDark))
            .textAlign(TextAlign.Center)
            .onClick(() => { this.sheet = 'more'; })
        }
      }
      .width('100%')
      .margin({ top: 18 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, bottom: 16 })
  }

  /** 详情页封面：优先服务端 coverArt，其次前四首 */
  private detailCovers(): string[] {
    if (this.curPlaylist !== null && this.curPlaylist.coverArt.length > 0) {
      return [this.cover(this.curPlaylist.coverArt, 300)];
    }
    const out: string[] = [];
    for (const t of this.curPlaylistSongs) {
      if (out.length >= 4) {
        break;
      }
      if (t.coverArt.length > 0) {
        out.push(this.cover(t.coverArt, 200));
      }
    }
    return out;
  }

  private playlistMetaText(): string {
    const n: string = this.curPlaylistSongs.length.toString() + ' 首';
    let ms: number = 0;
    for (const t of this.curPlaylistSongs) {
      ms += t.duration;
    }
    if (ms > 0) {
      return n + ' · ' + Fmt.durationCn(ms);
    }
    if (this.curPlaylist !== null && this.curPlaylist.duration > 0) {
      return n + ' · ' + Fmt.durationCn(this.curPlaylist.duration);
    }
    return n;
  }

  // ============ 歌单弹层 ============

  /** 详情页「更多」：改名 / 删除 */
  @Builder
  private playlistMoreSheet() {
    Column() {
      Row() {
        Text(this.curPlaylist !== null ? this.curPlaylist.name : '')
          .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('取消')
          .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
          .onClick(() => { this.sheet = 'none'; })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 8 })

      Text('重命名')
        .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
        .width('100%').height(50).padding({ left: 20 }).textAlign(TextAlign.Start)
        .onClick(() => { this.sheet = 'rename'; })

      Divider().color(Theme.divider(this.isDark)).margin({ left: 20 })

      Text('删除歌单')
        .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
        .width('100%').height(50).padding({ left: 20 }).textAlign(TextAlign.Start)
        .onClick(() => {
          const p: Playlist | null = this.curPlaylist;
          this.sheet = 'none';
          if (p !== null) {
            this.doDeletePlaylist(p);
          }
        })

      Column().height(12)
    }
    .width('100%')
    .backgroundColor(Theme.surface(this.isDark))
    .borderRadius({ topLeft: 20, topRight: 20 })
    // 底部安全区：弹层贴底，需自己避让系统手势条
    .padding({ bottom: bottomInset() + 8 })
  }

  /** 选歌单：把当前歌曲加入一个或多个歌单 */
  @Builder
  private pickPlaylistSheet() {
    Column() {
      Row() {
        Column() {
          Text('加入歌单')
            .fontSize(15).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Medium)
            .fontColor(Theme.text(this.isDark))
          if (this.bulkSongIds.length > 0) {
            Text('已选 ' + this.bulkSongIds.length.toString() + ' 首')
              .fontSize(11.5).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
              .margin({ top: 3 })
          } else if (this.pendingTrack !== null) {
            Text(this.pendingTrack.title)
              .fontSize(11.5).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
              .margin({ top: 3 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.pickedPlaylists.length > 0 ? '完成' : '取消')
          .fontSize(14).fontFamily(APP_FONT)
          .fontColor(this.pickedPlaylists.length > 0
            ? Theme.accent(this.isDark) : Theme.textSecondary(this.isDark))
          .padding({ left: 10, right: 4 })
          .onClick(() => {
            if (this.pickedPlaylists.length > 0) {
              this.submitPick();
            } else {
              this.closeSheet();
            }
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      // 新建歌单：直接把当前歌曲带进去
      Row() {
        Text('+')
          .fontSize(20).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
          .width(34).textAlign(TextAlign.Center)
        Text('新建歌单并加入')
          .fontSize(14).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
      }
      .width('100%')
      .height(48)
      .padding({ left: 20, right: 20 })
      .onClick(() => { this.createWithPendingSong(); })

      Divider().color(Theme.divider(this.isDark)).margin({ left: 54, right: 20 })

      // 歌单全选：一次勾上所有可写歌单，再点「完成」批量写入
      if (this.editablePlaylists().length > 1) {
        Row() {
          Column() {
            Stack({ alignContent: Alignment.Center }) {
              Column()
                .width(19).height(19).borderRadius(10)
                .backgroundColor(this.allPlaylistsPicked() ? Theme.accent(this.isDark) : '#00000000')
                .border({
                  width: 1.5,
                  color: this.allPlaylistsPicked()
                    ? Theme.accent(this.isDark) : Theme.textTertiary(this.isDark)
                })
              if (this.allPlaylistsPicked()) {
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
          .hitTestBehavior(HitTestMode.None)

          Text(this.allPlaylistsPicked() ? '取消全选' : '全选歌单')
            .fontSize(13).fontFamily(APP_FONT)
            .fontColor(this.allPlaylistsPicked()
              ? Theme.accent(this.isDark) : Theme.textSecondary(this.isDark))
            .margin({ left: 10 })
            // 文字本身不接事件，点击冒泡到整行，避免只有点到字缝里才有反应
            .hitTestBehavior(HitTestMode.None)

          // 不用 Blank() 撑开：它是独立命中节点，会把这一整行的点击吃掉。
          // 用 layoutWeight 的占位层顶开，同样不参与命中。
          Row()
            .layoutWeight(1)
            .height('100%')
            .hitTestBehavior(HitTestMode.None)

          Text(this.pickedPlaylists.length.toString() + ' / ' +
            this.editablePlaylists().length.toString())
            .fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
            .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height(44)
        .padding({ left: 20, right: 20 })
        .onClick(() => {
          console.info('[pick] 全选被点击 picked=' + this.pickedPlaylists.length.toString()
            + ' editable=' + this.editablePlaylists().length.toString()
            + ' playlists=' + this.playlists.length.toString());
          this.toggleAllPlaylists();
          console.info('[pick] 全选点击后 picked=' + this.pickedPlaylists.length.toString()
            + ' all=' + this.allPlaylistsPicked().toString());
        })
      }

      if (this.playlists.length === 0) {
        Text(this.playlistsLoading ? '正在读取歌单…' : '还没有歌单，先新建一个')
          .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
          .width('100%').height(120).textAlign(TextAlign.Center)
      } else {
        List() {
          ForEach(this.playlists, (p: Playlist) => {
            ListItem() {
              CheckRow({
                title: p.name,
                subtitle: p.songCount.toString() + ' 首' + (p.editable ? '' : ' · 只读'),
                checked: this.pickedPlaylists.indexOf(p.id) >= 0,
                onToggle: () => { this.togglePickedPlaylist(p.id); }
              })
            }
            .enabled(p.editable)
            .opacity(p.editable ? 1 : 0.45)
          }, (p: Playlist) => 'pk_' + p.id + '_' + this.pickedPlaylists.indexOf(p.id).toString())
        }
        .width('100%')
        // 高度按内容自适应，最多占窗口 55%；不再写死 340，少时不留空、多时不被切
        .constraintSize({ maxHeight: sheetListMax(0.55) })
        .scrollBar(BarState.Off)
      }
      Column().height(12)
    }
    .width('100%')
    .backgroundColor(Theme.surface(this.isDark))
    .borderRadius({ topLeft: 20, topRight: 20 })
    // 底部安全区：弹层贴底，需自己避让系统手势条
    .padding({ bottom: bottomInset() + 8 })
  }

  /** 新建歌单时把待加入的歌曲一起提交 */
  private async createWithPendingSong(): Promise<void> {
    const t: Track | null = this.pendingTrack;
    const name: string = '我的歌单 ' + (this.playlists.length + 1).toString();
    this.sheet = 'none';
    const ids: string[] = t === null ? [] : [t.id];
    const id: string = await Store.get().createPlaylist(name, ids);
    if (id.length === 0) {
      toast('创建失败，请检查服务器');
      return;
    }
    toast('已创建：' + name);
    await this.loadPlaylists();
  }

  // ============ 歌曲长按菜单（各列表共用） ============

  /**
   * 长按菜单。
   *
   * 注意两点，都是踩过坑总结的：
   * 1) 不能写成「@Builder 带闭包参数」——参数是值传递，回调会丢上下文；
   * 2) 也不要在弹层内部再嵌一个带参数的 @Builder——那个内层 Builder
   *    在本版本 SDK 下不会渲染，表现就是「遮罩变黑、面板空白」。
   *    所以整张菜单在同一个 Builder 里平铺展开，点击直接改状态。
   */
  @Builder
  private trackMenuSheet() {
    Column() {
      // 头部：歌名 + 歌手 + 音质，比纯标题信息量大
      Row() {
        Column() {
          Text(this.menuTrack !== null ? this.menuTrack.title : '')
            .fontSize(15).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Medium)
            .fontColor(Theme.text(this.isDark))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.menuTrack !== null
            ? this.menuTrack.artist + qualityText(this.menuTrack)
            : '')
            .fontSize(11.5).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
            .margin({ top: 3 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text('取消')
          .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
          .padding({ left: 10 })
          .onClick(() => { this.sheet = 'none'; })
      }
      .width('100%')
      .padding({ left: 22, right: 22, top: 18, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Divider().color(Theme.divider(this.isDark)).margin({ left: 22, right: 22 })

      if (this.menuTrack !== null) {
        // ---- 播放相关 ----
        Row() {
          Image(this.isDark ? $r('app.media.ic_next') : $r('app.media.ic_next_d'))
            .width(19).height(19)
            .fillColor(Theme.textSecondary(this.isDark))
            .margin({ right: 14 })
          Text('下一首播放')
            .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
            .layoutWeight(1)
        }
        .width('100%').height(50).padding({ left: 22, right: 22 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.clickMenu(0); })

        Row() {
          Image(this.isDark ? $r('app.media.ic_queue') : $r('app.media.ic_queue_d'))
            .width(19).height(19)
            .fillColor(Theme.textSecondary(this.isDark))
            .margin({ right: 14 })
          Text('加入播放队列')
            .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
            .layoutWeight(1)
        }
        .width('100%').height(50).padding({ left: 22, right: 22 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.clickMenu(1); })

        Divider().color(Theme.divider(this.isDark)).margin({ left: 55, right: 22 })

        // ---- 歌单 / 收藏 ----
        Row() {
          Image(this.isDark ? $r('app.media.ic_list') : $r('app.media.ic_list_d'))
            .width(19).height(19)
            .fillColor(Theme.textSecondary(this.isDark))
            .margin({ right: 14 })
          Text('加入歌单')
            .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
            .layoutWeight(1)
        }
        .width('100%').height(50).padding({ left: 22, right: 22 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.clickMenu(2); })

        Row() {
          Image(this.menuLiked
            ? (this.isDark ? $r('app.media.ic_heart_f') : $r('app.media.ic_heart_f_d'))
            : (this.isDark ? $r('app.media.ic_heart') : $r('app.media.ic_heart_d')))
            .width(19).height(19)
            .fillColor(Theme.textSecondary(this.isDark))
            .margin({ right: 14 })
          Text(this.menuLiked ? '取消收藏' : '收藏')
            .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
            .layoutWeight(1)
        }
        .width('100%').height(50).padding({ left: 22, right: 22 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.clickMenu(3); })

        Divider().color(Theme.divider(this.isDark)).margin({ left: 55, right: 22 })

        // ---- 跳转 ----
        Row() {
          Image(this.isDark ? $r('app.media.ic_cover') : $r('app.media.ic_cover_d'))
            .width(19).height(19)
            .fillColor(Theme.textSecondary(this.isDark))
            .margin({ right: 14 })
          Text('查看专辑')
            .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
            .layoutWeight(1)
        }
        .width('100%').height(50).padding({ left: 22, right: 22 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.clickMenu(4); })

        Row() {
          Image(this.isDark ? $r('app.media.ic_artist') : $r('app.media.ic_artist_d'))
            .width(19).height(19)
            .fillColor(Theme.textSecondary(this.isDark))
            .margin({ right: 14 })
          Text('查看歌手')
            .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.text(this.isDark))
            .layoutWeight(1)
        }
        .width('100%').height(50).padding({ left: 22, right: 22 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.clickMenu(5); })

        // 从歌单详情长按进来的：多一项移除
        if (this.fromPlaylistDetail()) {
          Divider().color(Theme.divider(this.isDark)).margin({ left: 55, right: 22 })
          Row() {
            Image(this.isDark ? $r('app.media.ic_close') : $r('app.media.ic_close_d'))
              .width(19).height(19)
              .fillColor(Theme.accent(this.isDark))
              .margin({ right: 14 })
            Text('从本歌单移除')
              .fontSize(15).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
              .layoutWeight(1)
          }
          .width('100%').height(50).padding({ left: 22, right: 22 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.clickMenu(6); })
        }
      }

      Column().height(12)
    }
    .width('100%')
    .backgroundColor(Theme.surface(this.isDark))
    .borderRadius({ topLeft: 20, topRight: 20 })
    .padding({ bottom: bottomInset() + 8 })
  }

  // ============ 播放队列弹层 ============

  /**
   * 播放队列。
   * 队列页只有「看 + 跳 + 删」三件事，不做拖动排序：
   * 随机播放下的顺序由 shuffledOrder 决定，拖动队列位置并不等于改变实际播放顺序，
   * 做了反而会给出错误预期。
   */
  /**
   * 队列弹层的副标题。
   *
   * 把「电台续播」写在这里而不是另起一行：用户打开队列最常见的问题是
   * 「为什么放完最后一首还在放」——先让他在队列里看见自己是开着电台的。
   * 关掉后不再显示，队列本身也不会有任何多余装饰。
   */
  private queueSubtitle(): string {
    if (this.queueSongs.length === 0) {
      return this.queueEmptyHint;
    }
    const base: string = this.queueSongs.length.toString() + ' 首';
    const on: boolean = Store.get().settings.radio !== false && Store.get().isSubsonic;
    return on ? base + ' · 电台续播中' : base;
  }

  @Builder
  private queueSheet() {
    Column() {
      // ---- 头部：标题 + 总数 + 清空 ----
      Row() {
        Column() {
          Text('播放队列')
            .fontSize(17).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Medium)
            .fontColor(Theme.text(this.isDark))
          Text(this.queueSubtitle())
            .fontSize(11.5).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.queueSongs.length > 0) {
          Row() {
            Image(this.isDark ? $r('app.media.ic_close') : $r('app.media.ic_close_d'))
              .width(14).height(14)
              .fillColor(Theme.accent(this.isDark))
            Text('清空')
              .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
              .margin({ left: 4 })
          }
          .padding({ left: 10, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor(Theme.accentSoft(this.isDark))
          .onClick(() => { this.clearQueue(); })
        }

        Text('关闭')
          .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
          .padding({ left: 12 })
          .onClick(() => { this.sheet = 'none'; })
      }
      .width('100%')
      .padding({ left: 22, right: 22, top: 18, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Divider().color(Theme.divider(this.isDark)).margin({ left: 22, right: 22 })

      // ---- 列表 ----
      if (this.queueSongs.length === 0) {
        Column() {
          Image(this.isDark ? $r('app.media.ic_queue') : $r('app.media.ic_queue_d'))
            .width(34).height(34)
            .fillColor(Theme.textTertiary(this.isDark))
          Text(this.queueEmptyHint)
            .fontSize(13.5).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
            .margin({ top: 12 })
          Text('在歌曲上长按，选「加入播放队列」')
            .fontSize(11.5).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
            .margin({ top: 5 })
        }
        .width('100%')
        .padding({ top: 40, bottom: 44 })
        .alignItems(HorizontalAlign.Center)
      } else {
        List({ space: 0 }) {
          LazyForEach(this.queueSrc, (t: Track, i: number) => {
            ListItem() {
              this.queueRow(t, i)
            }
          }, (t: Track, i: number) => t.id + '_' + i.toString() + '_' + this.queueCur.toString())
        }
        .width('100%')
        .height(sheetListMax(0.62))
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }

      Column().height(6)
    }
    .width('100%')
    .backgroundColor(Theme.surface(this.isDark))
    .borderRadius({ topLeft: 20, topRight: 20 })
    .padding({ bottom: bottomInset() + 8 })
  }

  /**
   * 队列里的一行。
   * 当前播放项：标题走强调色 + 左侧竖条 + 封面右下角一个小喇叭角标。
   * 删除按钮常驻可见而不是左右滑出——这个弹层本身就是「管理」语义，
   * 藏起来会让用户以为不能删。
   */
  @Builder
  private queueRow(t: Track, idx: number) {
    Row() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.cover(t.coverArt, 120).length > 0) {
          Image(this.cover(t.coverArt, 120))
            .width(42).height(42).borderRadius(8)
            .objectFit(ImageFit.Cover)
            .alt($r('app.media.ic_cover'))
        } else {
          Column()
            .width(42).height(42).borderRadius(8)
            .backgroundColor(Theme.surfaceAlt(this.isDark))
        }
        if (idx === this.queueCur) {
          Row() {
            Image(this.isDark ? $r('app.media.ic_play') : $r('app.media.ic_play_d'))
              .width(9).height(9)
              .fillColor(Color.White)
          }
          .width(16).height(16).borderRadius(6)
          .backgroundColor(Theme.accent(this.isDark))
          .justifyContent(FlexAlign.Center)
          .margin({ right: 2, bottom: 2 })
        }
      }
      .width(42).height(42)
      .margin({ right: 12 })

      Column() {
        Text(t.title)
          .fontSize(14).fontFamily(APP_FONT)
          .fontColor(idx === this.queueCur ? Theme.accent(this.isDark) : Theme.text(this.isDark))
          .fontWeight(idx === this.queueCur ? FontWeight.Medium : FontWeight.Normal)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(t.artist)
          .fontSize(11).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 }).width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (idx === this.queueCur) {
        Text('播放中')
          .fontSize(10.5).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark))
          .margin({ right: 8 })
      }

      // 删除：命中区域给到 34×34，图标本身小一点，避免误触相邻行
      Stack({ alignContent: Alignment.Center }) {
        Image(this.isDark ? $r('app.media.ic_close') : $r('app.media.ic_close_d'))
          .width(14).height(14)
          .fillColor(Theme.textTertiary(this.isDark))
      }
      .width(34).height(34)
      .borderRadius(17)
      .onClick(() => { this.removeFromQueue(idx); })
    }
    .width('100%')
    .height(62)
    .padding({ left: 16, right: 12 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(idx === this.queueCur ? Theme.accentSoft(this.isDark) : '#00000000')
    .onClick(() => { this.jumpQueueTo(idx); })
  }

  /** 是否从歌单详情长按进来的：决定要不要显示「从本歌单移除」 */
  private fromPlaylistDetail(): boolean {
    return this.view === 'playlist' && this.curPlaylist !== null && this.curPlaylist.editable
      && this.removingIndex >= 0 && this.removingIndex < this.curPlaylistSongs.length;
  }

  /** 菜单动作分发。用序号而不是闭包参数，绕开 @Builder 值传递的坑 */
  private clickMenu(idx: number): void {
    const t: Track | null = this.menuTrack;
    if (idx === 6) {
      const i: number = this.removingIndex;
      this.sheet = 'none';
      if (i >= 0) {
        this.removeFromPlaylist(i);
      }
      return;
    }
    if (t === null) {
      this.sheet = 'none';
      return;
    }
    if (idx === 0) {
      this.sheet = 'none';
      this.playNext(t);
      return;
    }
    if (idx === 1) {
      this.sheet = 'none';
      this.addToQueueEnd(t);
      return;
    }
    if (idx === 2) {
      this.openPickSheet(t);
      return;
    }
    if (idx === 3) {
      this.toggleMenuLike();
      return;
    }
    if (idx === 4) {
      this.goTrackAlbum(t);
      return;
    }
    if (idx === 5) {
      this.goTrackArtist(t);
    }
  }

  /** 选歌加入当前歌单 */
  @Builder
  private addSongsSheet() {
    Column() {
      Row() {
        Column() {
          Text('加入歌曲')
            .fontSize(15).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Medium)
            .fontColor(Theme.text(this.isDark))
          Text(this.pickedIds.length.toString() + ' 首已选')
            .fontSize(11.5).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.pickedIds.length > 0 ? '加入' : '取消')
          .fontSize(14).fontFamily(APP_FONT)
          .fontColor(this.pickedIds.length > 0
            ? Theme.accent(this.isDark) : Theme.textSecondary(this.isDark))
          .padding({ left: 10, right: 4 })
          .onClick(() => {
            if (this.pickedIds.length > 0) {
              this.submitAdd();
            } else {
              this.sheet = 'none';
            }
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.addPool().length === 0) {
        Text('歌曲还没加载完，先去「全部歌曲」页浏览一下')
          .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
          .width('100%').height(140).textAlign(TextAlign.Center)
      } else {
        List() {
          LazyForEach(this.addPoolSrc, (t: Track) => {
            ListItem() {
              CheckRow({
                title: t.title,
                subtitle: t.artist,
                checked: this.pickedIds.indexOf(t.id) >= 0,
                onToggle: () => { this.togglePickedSong(t.id); }
              })
            }
          }, (t: Track) => 'ad_' + t.id)
        }
        .width('100%')
        // 同「加入歌单」弹层：内容自适应，最多 60% 窗口高
        .constraintSize({ maxHeight: sheetListMax(0.60) })
        .scrollBar(BarState.Off)
      }
      Column().height(12)
    }
    .width('100%')
    .backgroundColor(Theme.surface(this.isDark))
    .borderRadius({ topLeft: 20, topRight: 20 })
    // 底部安全区：弹层贴底，需自己避让系统手势条
    .padding({ bottom: bottomInset() + 8 })
  }

  // ============ 喜爱的歌 ============
  @Builder
  starredBody() {
    if (this.error.length > 0 && this.starredSongs.length === 0) {
      this.emptyState((this.isDark ? $r('app.media.ic_heart') : $r('app.media.ic_heart_d')), this.error)
    } else {
      List() {
        // 标题栏作为列表首项，跟着内容一起滚动
        ListItem() {
          this.pageHeader()
        }
        LazyForEach(this.starredSrc, (t: Track, idx: number) => {
          ListItem() {
            SongRow({
              track: t,
              index: idx,
              coverUrl: this.cover(t.coverArt, 120),
              showLike: true,
              liked: true,
              onToggleLike: () => { this.unstarHere(t); }
            })
          }
          .onClick(() => { this.playSongList(this.starredSongs, idx); })
          .gesture(
            LongPressGesture({ repeat: false, duration: 450 })
              .onAction(() => { this.openTrackMenu(t); })
          )
        }, (t: Track, idx: number) => 'st_' + t.id)
        // 底部空白：给悬浮导航条与迷你播放器让位
        ListItem() {
          Column().width('100%').height(BOTTOM_PAD)
        }
      }
      .width('100%').layoutWeight(1)
      .scrollBar(BarState.Off)
      .divider({ color: Theme.divider(this.isDark), strokeWidth: 0.5, startMargin: 68, endMargin: 20 })
    }
  }

  // ============ 歌手详情 ============
  @Builder
  artistBody() {
    if (this.curArtistAlbums.length === 0 && !this.loading) {
      Column() {
        Text('该歌手暂无专辑').fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
      }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
    } else {
      this.albumsList()
    }
  }

  // ============ 专辑详情：整页一个列表，头部信息跟内容一起从返回条下穿过 ============
  @Builder
  albumDetailBody() {
    List() {
      // 返回条作为列表首项，随内容一起滚动
      ListItem() {
        this.pageBackHeader('')
      }

      // 专辑头部：封面 + 信息
      ListItem() {
        Row() {
          if (this.curAlbum !== null && this.cover(this.curAlbum.coverArt, 300).length > 0) {
            Image(this.cover(this.curAlbum.coverArt, 300))
              .width(92).height(92).borderRadius(12)
          } else {
            Column() {
              Image($r('app.media.app_icon')).width(38).height(38)
            }
            .width(92).height(92).borderRadius(12).backgroundColor(Theme.surfaceAlt(this.isDark))
            .justifyContent(FlexAlign.Center)
          }
          Column() {
            if (this.curAlbum !== null) {
              Text(this.curAlbum.name)
                .fontSize(17).fontFamily(APP_FONT).fontWeight(FontWeight.Medium).fontColor(Theme.text(this.isDark))
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.curAlbum.artist)
                .fontSize(13).fontFamily(APP_FONT).fontColor(Theme.accent(this.isDark)).margin({ top: 6 })
                .onClick(() => {
                  if (this.curAlbum !== null && this.curAlbum.artistId.length > 0) {
                    const a: Artist = {
                      id: this.curAlbum.artistId,
                      name: this.curAlbum.artist,
                      albumCount: 0,
                      coverArt: ''
                    };
                    this.openArtist(a);
                  }
                })
              Row() {
                if (this.curAlbum.year > 0) {
                  Text(String(this.curAlbum.year)).fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                }
                if (this.curAlbum.songCount > 0) {
                  Text(' · ' + this.curAlbum.songCount + ' 首').fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                }
                if (this.curAlbum.genre.length > 0) {
                  Text(' · ' + this.curAlbum.genre).fontSize(12).fontFamily(APP_FONT).fontColor(Theme.textTertiary(this.isDark))
                }
              }
              .margin({ top: 4 })
            }
          }
          .layoutWeight(1).margin({ left: 14 }).alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 14 })
        .alignItems(VerticalAlign.Top)
      }

      if (this.curAlbumSongs.length === 0 && !this.loading) {
        ListItem() {
          Column() {
            Text('专辑暂无歌曲').fontSize(13).fontFamily(APP_FONT).fontColor(Theme.textSecondary(this.isDark))
          }
          .width('100%').height(300).justifyContent(FlexAlign.Center)
        }
      }
      LazyForEach(this.albumSrc, (t: Track, idx: number) => {
        ListItem() {
          SongRow({ track: t, index: idx, coverUrl: this.cover(t.coverArt, 120) })
            .gesture(
              LongPressGesture({ repeat: false, duration: 450 })
                .onAction(() => { this.openTrackMenu(t); })
            )
        }
        .onClick(() => { this.playSongList(this.curAlbumSongs, idx); })
      }, (t: Track, idx: number) => 'alb_' + t.id + '#' + idx.toString())
      // 底部空白：给悬浮导航条与迷你播放器让位
      ListItem() {
        Column().width('100%').height(BOTTOM_PAD)
      }
    }
    .width('100%').layoutWeight(1)
    .scrollBar(BarState.Off)
    .divider({ color: Theme.divider(this.isDark), strokeWidth: 0.5, startMargin: 68, endMargin: 20 })
  }
}

