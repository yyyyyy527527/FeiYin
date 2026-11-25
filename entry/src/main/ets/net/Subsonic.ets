import http from '@ohos.net.http';
import util from '@ohos.util';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ServerConfig, TestResult, Artist, Album, Genre, Track,
  ArtistDetail, AlbumDetail, SearchResult, StarredResult, LyricLine, LyricsResult, Playlist,
  SongProbe } from '../model/Models';
import { parseLrc } from '../utils/LrcParser';

type JsonObj = Record<string, Object>;

const API_VERSION: string = '1.16.1';
const CLIENT_NAME: string = 'FeiYin';

/**
 * Subsonic / OpenSubsonic API 客户端。
 * 用于连接 Navidrome、Airsonic 等兼容 Subsonic 协议的音乐服务器。
 *
 * 认证采用 token 方式：t = md5(password + salt)，比明文密码更安全。
 * stream / coverArt 直接拼成带认证的 URL，交给 AVPlayer / Image 组件加载。
 */
export class Subsonic {
  private cfg: ServerConfig;
  private base: string;
  private salt: string;
  private token: string;
  private authQuery: string;
  /**
   * stream / 封面这类二进制接口专用：去掉 f=json。
   * 这些接口的响应本来就是音频字节，f 只对 JSON 接口有意义；
   * 少数服务器（Gonic 等）见了 f=json 会回一包 JSON 错误，
   * AVPlayer 自然一个采样都解不出来。
   */
  private binQuery: string;

  constructor(cfg: ServerConfig) {
    this.cfg = cfg;
    this.base = cfg.url.replace(/\/+$/, '');
    this.salt = 'feiyin' + Math.floor(Math.random() * 1e9).toString(36) + Date.now().toString(36);
    this.token = md5Hex(cfg.password + this.salt);
    this.authQuery = 'u=' + enc(cfg.username) + '&t=' + this.token + '&s=' + this.salt +
      '&v=' + API_VERSION + '&c=' + CLIENT_NAME + '&f=json';
    this.binQuery = 'u=' + enc(cfg.username) + '&t=' + this.token + '&s=' + this.salt +
      '&v=' + API_VERSION + '&c=' + CLIENT_NAME;
  }

  get url(): string {
    return this.base;
  }

  /** 当前登录用户名（判断歌单归属用） */
  get username(): string {
    return this.cfg.username;
  }

  /**
   * 流式播放 URL，直接给 AVPlayer。
   *
   * transcode=true 时让服务器转成 mp3 再送：Hi-Res ALAC / DSD 这类容器
   * 系统解码器不认（AVPlayer 报 5400106），转码是唯一能让它出声的路。
   * 只在直连失败后才会走这条路，正常播放仍是原始文件、不损音质。
   */
  streamUrl(songId: string, transcode: boolean = false): string {
    let u: string = this.base + '/rest/stream?' + this.binQuery + '&id=' + enc(songId);
    if (transcode) {
      u += '&format=mp3&maxBitRate=320';
    }
    return u;
  }

  /** 封面图 URL，直接给 Image 组件 */
  coverUrl(coverArt: string, size: number): string {
    if (coverArt.length === 0) {
      return '';
    }
    // 与 stream 一样是二进制接口：带上 f=json 会被部分服务器
    // 当成「要 JSON」，回一包错误体，结果是封面全部空白
    return this.base + '/rest/getCoverArt?' + this.binQuery + '&id=' + enc(coverArt) + '&size=' + size;
  }

  /** 测试连接 */
  async ping(): Promise<TestResult> {
    try {
      const raw: string = await this.getJson('/rest/ping');
      const r: JsonObj = parseObj(raw);
      const status: string = asStr(r['status'], '');
      if (status === 'ok') {
        const serverVer: string = asStr(r['serverVersion'], '');
        const serverType: string = asStr(r['type'], '');
        const result: TestResult = {
          ok: true,
          msg: '连接成功 · ' + serverType + ' ' + serverVer,
          count: 0
        };
        return result;
      }
      const err: JsonObj = asObj(r['error']);
      const msg: string = asStr(err['message'], '认证失败或服务不可用');
      const fail: TestResult = { ok: false, msg: msg, count: 0 };
      return fail;
    } catch (err) {
      const m: string = err instanceof Error ? err.message : String(err);
      const fail: TestResult = { ok: false, msg: m, count: 0 };
      return fail;
    }
  }

  /** 获取全部歌手 */
  async getArtists(): Promise<Artist[]> {
    const raw: string = await this.getJson('/rest/getArtists');
    const r: JsonObj = parseObj(raw);
    const artists: JsonObj = asObj(r['artists']);
    const index: Object[] = asArr(artists['index']);
    return parseArtists(index);
  }

  /**
   * 获取专辑列表。
   * type: newest | frequent | recent | random | alphabeticalByName | alphabeticalByArtist | starred
   * offset: 分页偏移（size + offset 翻页，size 上限一般 500）
   */
  async getAlbumList(type: string, size: number, offset: number = 0): Promise<Album[]> {
    const raw: string = await this.getJson('/rest/getAlbumList?type=' + type + '&size=' + size +
      '&offset=' + offset);
    const r: JsonObj = parseObj(raw);
    const list: JsonObj = asObj(r['albumList2']);
    let arr: Object[] = asArr(list['album']);
    if (arr.length === 0) {
      const list1: JsonObj = asObj(r['albumList']);
      arr = asArr(list1['album']);
    }
    return parseAlbums(arr);
  }

  /** 曲库歌曲总数：Navidrome 的 getScanStatus.count 即扫描到的音乐文件总数 */
  async getScanCount(): Promise<number> {
    const raw: string = await this.getJson('/rest/getScanStatus');
    const r: JsonObj = parseObj(raw);
    const st: JsonObj = asObj(r['scanStatus']);
    const c: Object | undefined = st['count'];
    return typeof c === 'number' ? (c as number) : 0;
  }

  /** 获取歌手的专辑 */
  async getArtist(id: string): Promise<ArtistDetail> {
    const raw: string = await this.getJson('/rest/getArtist?id=' + enc(id));
    const r: JsonObj = parseObj(raw);
    const a: JsonObj = asObj(r['artist']);
    const artist: Artist = {
      id: asStr(a['id'], ''),
      name: asStr(a['name'], ''),
      albumCount: asNum(a['albumCount'], 0),
      coverArt: asStr(a['coverArt'], '')
    };
    const albums: Album[] = parseAlbums(asArr(a['album']));
    const result: ArtistDetail = {
      artist: artist.id.length > 0 ? artist : null,
      albums: albums
    };
    return result;
  }

  /** 获取专辑详情含歌曲 */
  async getAlbum(id: string): Promise<AlbumDetail> {
    const raw: string = await this.getJson('/rest/getAlbum?id=' + enc(id));
    const r: JsonObj = parseObj(raw);
    const a: JsonObj = asObj(r['album']);
    if (a['id'] === undefined) {
      const empty: AlbumDetail = { album: null, songs: [] };
      return empty;
    }
    const album: Album = {
      id: asStr(a['id'], ''),
      name: asStr(a['name'], ''),
      artist: asStr(a['artist'], ''),
      artistId: asStr(a['artistId'], ''),
      coverArt: asStr(a['coverArt'], ''),
      songCount: asNum(a['songCount'], 0),
      year: asNum(a['year'], 0),
      genre: asStr(a['genre'], '')
    };
    const songs: Track[] = parseSongs(asArr(a['song']));
    const result: AlbumDetail = { album: album, songs: songs };
    return result;
  }

  /** 搜索 */
  async search2(query: string): Promise<SearchResult> {
    if (query.trim().length === 0) {
      const empty: SearchResult = { artists: [], albums: [], songs: [] };
      return empty;
    }
    const raw: string = await this.getJson('/rest/search2?query=' + enc(query) +
      '&artistCount=20&albumCount=20&songCount=40');
    const r: JsonObj = parseObj(raw);
    const sr: JsonObj = asObj(r['searchResult2']);
    const result: SearchResult = {
      artists: parseArtists(asArr(sr['artist'])),
      albums: parseAlbums(asArr(sr['album'])),
      songs: parseSongs(asArr(sr['song']))
    };
    return result;
  }

  /** 搜索（search3，Navidrome/OpenSubsonic 推荐，search2 在新服务端上已废弃） */
  async search3(query: string): Promise<SearchResult> {
    if (query.trim().length === 0) {
      const empty: SearchResult = { artists: [], albums: [], songs: [] };
      return empty;
    }
    const raw: string = await this.getJson('/rest/search3?query=' + enc(query) +
      '&songCount=60&albumCount=24&artistCount=10');
    const r: JsonObj = parseObj(raw);
    const sr: JsonObj = asObj(r['searchResult3']);
    const result: SearchResult = {
      artists: parseArtists(asArr(sr['artist'])),
      albums: parseAlbums(asArr(sr['album'])),
      songs: parseSongs(asArr(sr['song']))
    };
    return result;
  }

  /** 收藏列表 */
  async getStarred2(): Promise<StarredResult> {
    const raw: string = await this.getJson('/rest/getStarred2');
    const r: JsonObj = parseObj(raw);
    const sr: JsonObj = asObj(r['starred2']);
    const result: StarredResult = {
      artists: parseArtists(asArr(sr['artist'])),
      albums: parseAlbums(asArr(sr['album'])),
      songs: parseSongs(asArr(sr['song']))
    };
    return result;
  }

  /** 风格列表 */
  async getGenres(): Promise<Genre[]> {
    const raw: string = await this.getJson('/rest/getGenres');
    const r: JsonObj = parseObj(raw);
    const g: JsonObj = asObj(r['genres']);
    const arr: Object[] = asArr(g['genre']);
    const out: Genre[] = [];
    for (const item of arr) {
      const o: JsonObj = asObj(item);
      const genre: Genre = {
        value: asStr(o['value'], ''),
        songCount: asNum(o['songCount'], 0),
        albumCount: asNum(o['albumCount'], 0)
      };
      out.push(genre);
    }
    return out;
  }

  /** 随机歌曲 */
  async getRandomSongs(size: number): Promise<Track[]> {
    const raw: string = await this.getJson('/rest/getRandomSongs?size=' + size);
    const r: JsonObj = parseObj(raw);
    const s: JsonObj = asObj(r['randomSongs']);
    return parseSongs(asArr(s['song']));
  }

  /** 全部歌曲（分页）。Navidrome 对 search3 的空查询会返回整个曲库，songOffset 控制翻页 */
  async getSongsPage(limit: number, offset: number): Promise<Track[]> {
    const raw: string = await this.getJson('/rest/search3?query=&songCount=' + limit +
      '&songOffset=' + offset);
    const r: JsonObj = parseObj(raw);
    const sr: JsonObj = asObj(r['searchResult3']);
    return parseSongs(asArr(sr['song']));
  }

  /**
   * 相似歌曲（电台续播用）。
   *
   * 两代接口都要试：getSimilarSongs2（OpenSubsonic / Navidrome）返回的是
   * `similarSongs2` 包装，老服务端只认 getSimilarSongs 且包装名少个 2。
   * 只试一个的话，在另一半服务器上就是「电台永远拉不到歌」。
   *
   * 服务器没开相似度数据（Navidrome 未配 Last.fm）时返回空数组——
   * 这是正常结果，不是错误，调用方据此停止续播，不要反复重试。
   */
  async getSimilarSongs(songId: string, count: number = 20): Promise<Track[]> {
    const n: number = count < 1 ? 1 : (count > 50 ? 50 : count);
    const paths: string[] = ['/rest/getSimilarSongs2', '/rest/getSimilarSongs'];
    let lastErr: Error | null = null;
    /** 至少有一个接口正常应答过。用来区分「服务器说没有相似歌」与「根本没连上」 */
    let answered: boolean = false;
    for (const path of paths) {
      try {
        const raw: string = await this.getJson(path + '?id=' + enc(songId) + '&count=' + n);
        const r: JsonObj = parseObj(raw);
        answered = true;
        const box: JsonObj = r['similarSongs2'] !== undefined
          ? asObj(r['similarSongs2'])
          : asObj(r['similarSongs']);
        const songs: Track[] = parseSongs(asArr(box['song']));
        if (songs.length > 0) {
          return songs;
        }
      } catch (e) {
        // 接口不存在 / 参数被拒：换下一个
        lastErr = e as Error;
      }
    }
    // 两个接口都没答上来，是网络或服务问题，不能当成「没有相似歌」——
    // 后者会让调用方把整轮电台关掉，而网络抖动几秒后本可以恢复
    if (!answered && lastErr !== null) {
      throw lastErr;
    }
    return [];
  }

  /**
   * 播放上报（scrobble）。
   * submission=false：刚开播，告诉服务器「我在听这首」（Now Playing）；
   * submission=true ：听够了，计入播放次数 / 推荐权重。
   * time 是毫秒时间戳，服务器用它统计「什么时候听的」，传 0 表示现在。
   *
   * 返回值只用于日志：这属于旁路行为，失败绝不能影响播放。
   */
  async scrobble(songId: string, submission: boolean, timeMs: number = 0): Promise<boolean> {
    let path: string = '/rest/scrobble?id=' + enc(songId) +
      '&submission=' + (submission ? 'true' : 'false');
    if (timeMs > 0) {
      path += '&time=' + Math.floor(timeMs).toString();
    }
    return this.boolCall(path);
  }

  /** 收藏 / 取消收藏歌曲 */
  async star(songId: string): Promise<boolean> {
    return this.boolCall('/rest/star?id=' + enc(songId));
  }

  /** 查询歌曲是否已收藏（getSong 的 starred 字段：已收藏时为时间戳字符串） */
  async getSongStarred(songId: string): Promise<boolean> {
    try {
      const raw: string = await this.getJson('/rest/getSong?id=' + enc(songId));
      const r: JsonObj = parseObj(raw);
      const song: JsonObj = asObj(r['song']);
      return asStr(song['starred'], '').length > 0;
    } catch (e) {
      return false;
    }
  }

  /**
   * 查一首歌的最新详情。既用来确认歌还在不在，也用来**刷新本地缓存里的旧快照**——
   * 每日推荐的存档可能来自很早的版本，里面的 streamUrl / coverArt 是当时生成的，
   * 直接用会「点不动 + 没封面」。每次回查顺手换成服务器当前的数据就顺手治好了。
   *
   * state 三态，关键是别把「网络不通」当成「歌被删了」：
   *   'ok'      歌还在，track 是最新数据
   *   'gone'    服务器明确回答没有这首（code 70 / HTTP 404）
   *   'unknown' 连不上、鉴权失败、5xx ——调用方必须当作「未知」保留原样
   */
  async probeSong(songId: string): Promise<SongProbe> {
    try {
      const raw: string = await this.getJson('/rest/getSong?id=' + enc(songId));
      const r: JsonObj = parseObj(raw);
      if (asStr(r['status'], '') === 'failed') {
        const err: JsonObj = asObj(r['error']);
        // 70 = 请求的数据不存在。Navidrome 上删掉一首歌之后，getSong 返回的就是它；
        // 其他错误码（权限、服务器内部）不能说明歌没了
        if (asNum(err['code'], 0) === 70) {
          return { state: 'gone', track: null };
        }
        return { state: 'unknown', track: null };
      }
      const one: Track[] = parseSongs([asObj(r['song'])]);
      if (one.length === 0) {
        return { state: 'unknown', track: null };
      }
      const t: Track = one[0];
      // 有些库不给 coverArt，但 getCoverArt 接受 song id，用 id 兜底能拿到所属专辑的封面
      if (t.coverArt.length === 0) {
        t.coverArt = t.id;
      }
      return { state: 'ok', track: t };
    } catch (e) {
      // 部分服务端对不存在的 id 直接回 HTTP 404，而不是 200 + code 70
      if (String(e).indexOf('HTTP 404') >= 0) {
        return { state: 'gone', track: null };
      }
      return { state: 'unknown', track: null };
    }
  }

  /**
   * 获取歌词。
   * 优先用 OpenSubsonic 的 getLyricsBySongId（带毫秒时间轴，可滚动高亮），
   * 服务端不支持时降级到经典 getLyrics（纯文本 / LRC 文本）。
   */
  async getLyrics(songId: string, artist: string, title: string): Promise<LyricsResult> {
    // 记下两条通道各自的结果，失败时能直接看出是「接口不支持」还是「服务器没收录」。
    // OpenSubsonic 的失败是「预期内的」（老服务器没这个端点），不刷日志；
    // 只在最终确实没拿到歌词时合并输出一行。
    let openErr: string = '';
    let openGroups: number = -1;
    let legacyLen: number = -1;
    /** 结构化歌词里的纯文本组（无时间轴），先留着：同步歌词优先，它是最后兜底 */
    let plainFallback: LyricLine[] | null = null;
    try {
      const raw: string = await this.getJson('/rest/getLyricsBySongId?id=' + enc(songId));
      const r: JsonObj = parseObj(raw);
      const list: JsonObj = asObj(r['lyricsList']);
      const groups: Object[] = asArr(list['structuredLyrics']);
      openGroups = groups.length;
      /**
       * 多组歌词里可能同时有「同步组」与「未同步组」（纯文本、所有 start=0），
       * 顺序不固定。这里必须先按 synced 挑，不能取第一个有字的组——
       * 取错了的表现正是「极少数歌的歌词整篇不滚动」：
       * 未同步组的 start 全是 0，被当成同步歌词后二分查找每次都命中最后一行，
       * 高亮直接钉在末句，看着像卡住。
       */
      for (const g of groups) {
        const o: JsonObj = asObj(g);
        const rows: Object[] = asArr(o['line']);
        // synced 缺省按 true：老服务端不写这个字段，但给了 start
        const groupSynced: boolean = o['synced'] === undefined ? true : (o['synced'] as boolean);
        // offset：OpenSubsonic 规范里每行可带一个额外偏移（毫秒），
        // 用于「这句歌词整体往后挪一点」这类校准。旧实现只读 start、
        // 忽略 offset，遇到用了这个字段的服务器就会整首歌系统性偏移。
        // 另外该规范也允许 value 为空、只有 start（表示「此处起无歌词」的间隔），
        // 这类行要保留为占位，否则两行之间的时间会被错算到前一行上。
        const lines: LyricLine[] = [];
        let lastStart: number = 0;
        for (const it of rows) {
          const row: JsonObj = asObj(it);
          const text: string = asStr(row['value'], '');
          const start: number = asNum(row['start'], 0) + asNum(row['offset'], 0);
          if (start > lastStart) {
            lastStart = start;
          }
          const line: LyricLine = { start: start, text: text };
          lines.push(line);
        }
        if (lines.length === 0) {
          continue;
        }
        // 规范不保证行的顺序，统一排一次，后面查找依赖升序
        lines.sort((a: LyricLine, b: LyricLine) => a.start - b.start);
        // 全是空文本说明只有时间骨架、没有词，交给下一组 / 降级通道
        let hasText: boolean = false;
        for (const l of lines) {
          if (l.text.length > 0) {
            hasText = true;
            break;
          }
        }
        if (!hasText) {
          continue;
        }
        // 标记了未同步，或所有 start 都是 0：只能静态展示，不能参与滚动查找。
        // 先记下来，但仍继续试后面的组与降级通道——真正的同步歌词可能排在后面
        if (!groupSynced || lastStart <= 0) {
          if (plainFallback === null) {
            plainFallback = lines;
          }
          continue;
        }
        const result: LyricsResult = { lines: lines, synced: true };
        return result;
      }
    } catch (e) {
      openErr = e instanceof Error ? e.message : String(e);
    }

    // 降级：经典接口返回整段文本，可能内嵌 [mm:ss.xx] 时间轴
    if (artist.length > 0 && title.length > 0) {
      try {
        const raw: string = await this.getJson('/rest/getLyrics?artist=' + enc(artist) +
          '&title=' + enc(title));
        const r: JsonObj = parseObj(raw);
        const ly: JsonObj = asObj(r['lyrics']);
        const value: string = asStr(ly['value'], '');
        if (value.length > 0) {
          const parsed: LyricsResult = parseLrc(value);
          // 纯文本歌词（无时间轴）的行数同样要记下来：>0 说明「有词但不同步」，
          // 这种情况页面能正常显示，只是不做高亮滚动。
          legacyLen = parsed.lines.length;
          if (parsed.lines.length > 0) {
            // 带时间轴优先：它比结构化里的纯文本组更有价值。
            // 不带时间轴的先当兜底，不急着返回
            if (parsed.synced) {
              return parsed;
            }
            if (plainFallback === null) {
              plainFallback = parsed.lines;
            }
          }
        } else {
          legacyLen = 0;
        }
      } catch (e) {
        legacyLen = -2;
      }
    }

    if (plainFallback !== null) {
      // 只找到无时间轴的歌词：整篇静态显示，不做高亮滚动。
      // 这比「当成同步歌词去滚动」诚实——后者会把高亮钉在最后一句
      const plain: LyricsResult = { lines: plainFallback, synced: false };
      return plain;
    }

    // 到这里说明两条通道都没拿到歌词。区分三种情况，方便对号入座：
    //   openGroups === -1  → getLyricsBySongId 这个端点不存在（老服务器），正常
    //   openGroups === 0   → 端点存在，但这首歌服务器没收录歌词
    //   openGroups > 0     → 有 lyricsList，但每组的 line 都是空的（结构不标准）
    console.info('[lyrics] miss song=' + songId
      + ' bySongId.groups=' + openGroups.toString()
      + ' err=' + (openErr.length > 0 ? openErr : '-')
      + ' legacy.lines=' + legacyLen.toString());

    const empty: LyricsResult = { lines: [], synced: false };
    return empty;
  }

  async unstar(songId: string): Promise<boolean> {
    return this.boolCall('/rest/unstar?id=' + enc(songId));
  }

  // ================ 歌单 ================

  /**
   * 全部歌单。Subsonic 没有分页，一次拉完；
   * 返回的条目只有元信息，曲目要再调 getPlaylist 取。
   */
  async getPlaylists(): Promise<Playlist[]> {
    const raw: string = await this.getJson('/rest/getPlaylists');
    const r: JsonObj = parseObj(raw);
    const box: JsonObj = asObj(r['playlists']);
    return parsePlaylists(asArr(box['playlist']));
  }

  /** 单个歌单详情（含曲目） */
  async getPlaylist(id: string): Promise<Playlist | null> {
    const raw: string = await this.getJson('/rest/getPlaylist?id=' + enc(id));
    const r: JsonObj = parseObj(raw);
    const box: JsonObj = asObj(r['playlist']);
    if (box['id'] === undefined) {
      return null;
    }
    return parsePlaylistDetail(box);
  }

  /**
   * 新建歌单。songIds 可以为空（先建空歌单再往里加）。
   * 返回新歌单 id，失败返回空串。
   */
  async createPlaylist(name: string, songIds: string[]): Promise<string> {
    let path: string = '/rest/createPlaylist?name=' + enc(name);
    for (const id of songIds) {
      path += '&songId=' + enc(id);
    }
    try {
      const raw: string = await this.getJson(path);
      const r: JsonObj = parseObj(raw);
      if (asStr(r['status'], '') !== 'ok') {
        return '';
      }
      const box: JsonObj = asObj(r['playlist']);
      return asStr(box['id'], '');
    } catch (err) {
      return '';
    }
  }

  /**
   * 修改歌单：改名、加歌、删歌。
   * 服务端一次调用就能同时完成三种修改，参数为空表示该项不改。
   * playlistId 为旧版兼容字段，Navidrome 两个都认，这里一起带上。
   */
  async updatePlaylist(playlistId: string, name: string,
    addIds: string[], removeIndexes: number[]): Promise<boolean> {
    let path: string = '/rest/updatePlaylist?playlistId=' + enc(playlistId);
    if (name.length > 0) {
      path += '&name=' + enc(name);
    }
    for (const id of addIds) {
      path += '&songIdToAdd=' + enc(id);
    }
    for (const idx of removeIndexes) {
      path += '&songIndexToRemove=' + idx.toString();
    }
    return this.boolCall(path);
  }

  /** 删除整个歌单 */
  async deletePlaylist(playlistId: string): Promise<boolean> {
    return this.boolCall('/rest/deletePlaylist?id=' + enc(playlistId));
  }

  private async boolCall(path: string): Promise<boolean> {
    try {
      const raw: string = await this.getJson(path);
      const r: JsonObj = parseObj(raw);
      return asStr(r['status'], '') === 'ok';
    } catch (err) {
      return false;
    }
  }

  private async getJson(path: string): Promise<string> {
    const url: string = this.base + path + (path.indexOf('?') >= 0 ? '&' : '?') + this.authQuery;
    try {
      return await this.getJsonOnce(url);
    } catch (e) {
      // 幂等 GET：NAS 偶发抖动（读超时 / 5xx / 429）重试一次就能救回来；
      // 其他 4xx（鉴权失败、参数错）重试也不会好，直接抛。
      const msg: string = (e as Error).message ?? '';
      // 鉴权/参数类错误重试也不会变好，只会让列表多等一轮
      const fatal: boolean = msg.indexOf('用户名或密码') >= 0 ||
        msg.indexOf('服务器错误') >= 0 || msg.indexOf('XML') >= 0;
      const clientErr: boolean = msg.indexOf('HTTP 4') >= 0 && msg.indexOf('HTTP 429') < 0;
      if (clientErr || fatal) {
        throw e as Error;
      }
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => { resolve(); }, 400);
      });
      return await this.getJsonOnce(url);
    }
  }

  private async getJsonOnce(url: string): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 15000
      } as http.HttpRequestOptions);
      if (resp.responseCode >= 400) {
        throw new Error('请求失败：HTTP ' + resp.responseCode);
      }
      const text: string = typeof resp.result === 'string' ? resp.result : '';
      assertOk(text);
      return text;
    } finally {
      req.destroy();
    }
  }
}

/**
 * Subsonic 的失败是「HTTP 200 + status=failed」。
 *
 * 不拦的话，错误体照样会走 JSON.parse，各 getter 读不到字段就返回空数组，
 * 界面显示成「音乐库暂无歌曲」「暂无专辑」——看起来像服务器没歌，
 * 实际是密码错了或请求参数被拒，排查方向会被完全带偏。
 */
function assertOk(raw: string): void {
  const text: string = raw.trimStart();
  if (text.length === 0) {
    return;
  }
  // 回的是 XML：说明 f=json 没生效（个别反代会丢查询参数）
  if (text.charAt(0) === '<') {
    throw new Error('服务器返回了 XML，请检查服务器地址是否被代理改写');
  }
  const r: JsonObj = parseObj(text);
  if (asStr(r['status'], 'ok') !== 'failed') {
    return;
  }
  const e: JsonObj = asObj(r['error']);
  const code: number = asNum(e['code'], 0);
  const msg: string = asStr(e['message'], '服务器拒绝了这次请求');
  if (code === 40) {
    throw new Error('用户名或密码不对，请在设置里重新登录');
  }
  if (code === 10) {
    throw new Error('请求缺少参数（' + msg + '）');
  }
  throw new Error('服务器错误 ' + code + '：' + msg);
}

// ---------------- JSON 解析辅助 ----------------

function parseObj(raw: string): JsonObj {
  try {
    const parsed: Object = JSON.parse(raw);
    const root = parsed as JsonObj;
    const resp = root['subsonic-response'];
    if (resp !== undefined && resp !== null) {
      return resp as JsonObj;
    }
    return root;
  } catch (e) {
    return {} as JsonObj;
  }
}

function asObj(v: Object | undefined): JsonObj {
  if (v === undefined || v === null) {
    return {} as JsonObj;
  }
  return v as JsonObj;
}

function asArr(v: Object | undefined): Object[] {
  if (v === undefined || v === null) {
    return [];
  }
  if (v instanceof Array) {
    return v as Object[];
  }
  return [v];
}

function asStr(v: Object | undefined, def: string): string {
  if (v === undefined || v === null) {
    return def;
  }
  const s: string = String(v);
  return s.length > 0 ? s : def;
}

function asNum(v: Object | undefined, def: number): number {
  if (v === undefined || v === null) {
    return def;
  }
  const n: number = Number(v);
  return isNaN(n) ? def : n;
}

function parseArtists(arr: Object[]): Artist[] {
  const out: Artist[] = [];
  for (const item of arr) {
    const o: JsonObj = asObj(item);
    const artist: Artist = {
      id: asStr(o['id'], ''),
      name: asStr(o['name'], '未知歌手'),
      albumCount: asNum(o['albumCount'], 0),
      coverArt: asStr(o['coverArt'], '')
    };
    if (artist.id.length > 0) {
      out.push(artist);
    }
  }
  return out;
}

function parseAlbums(arr: Object[]): Album[] {
  const out: Album[] = [];
  for (const item of arr) {
    const o: JsonObj = asObj(item);
    const album: Album = {
      id: asStr(o['id'], ''),
      name: asStr(o['name'], '未知专辑'),
      artist: asStr(o['artist'], ''),
      artistId: asStr(o['artistId'], ''),
      coverArt: asStr(o['coverArt'], ''),
      songCount: asNum(o['songCount'], 0),
      year: asNum(o['year'], 0),
      genre: asStr(o['genre'], '')
    };
    if (album.id.length > 0) {
      out.push(album);
    }
  }
  return out;
}

function parseSongs(arr: Object[]): Track[] {
  const out: Track[] = [];
  const sub: Subsonic | null = SubsonicHolder.instance;
  for (const item of arr) {
    const o: JsonObj = asObj(item);
    const id: string = asStr(o['id'], '');
    if (id.length === 0) {
      continue;
    }
    const streamUrl: string = sub === null ? '' : sub.streamUrl(id);
    const track: Track = {
      id: id,
      href: id,
      title: asStr(o['title'], '未知曲目'),
      artist: asStr(o['artist'], ''),
      album: asStr(o['album'], ''),
      folder: asStr(o['album'], ''),
      size: asNum(o['size'], 0),
      duration: asNum(o['duration'], 0) * 1000,
      cached: false,
      cachedPath: '',
      coverArt: asStr(o['coverArt'], ''),
      albumId: asStr(o['albumId'], ''),
      suffix: asStr(o['suffix'], ''),
      bitRate: asNum(o['bitRate'], 0),
      samplingRate: asNum(o['samplingRate'], 0),
      bitDepth: asNum(o['bitDepth'], 0),
      streamUrl: streamUrl,
      created: parseIsoTime(asStr(o['created'], '')),
      playCount: asNum(o['playCount'], 0)
    };
    out.push(track);
  }
  return out;
}

/** 持有 Subsonic 单例，供 parseSongs 构造 streamUrl */
class SubsonicHolder {
  static instance: Subsonic | null = null;
  /** 当前登录用户名：判断歌单是否为自己的（可编辑） */
  static user: string = '';
}

/** 歌单列表项：不带曲目 */
function parsePlaylists(arr: Object[]): Playlist[] {
  const out: Playlist[] = [];
  for (const item of arr) {
    const p: Playlist = parsePlaylistBase(asObj(item));
    if (p.id.length > 0) {
      out.push(p);
    }
  }
  return out;
}

/** 歌单元信息解析（列表与详情共用） */
function parsePlaylistBase(o: JsonObj): Playlist {
  const owner: string = asStr(o['owner'], '');
  const songCount: number = asNum(o['songCount'], 0);
  const pl: Playlist = {
    id: asStr(o['id'], ''),
    name: asStr(o['name'], '未命名歌单'),
    songCount: songCount,
    // duration 是秒，转成毫秒与其他时长字段统一
    duration: asNum(o['duration'], 0) * 1000,
    coverArt: asStr(o['coverArt'], ''),
    owner: owner,
    created: asStr(o['created'], '').length > 0 ? parseIsoTime(asStr(o['created'], '')) : 0,
    changed: asStr(o['changed'], '').length > 0 ? parseIsoTime(asStr(o['changed'], '')) : 0,
    // owner 为空视为自己的：部分老版本服务端不返回该字段
    editable: owner.length === 0 || owner === SubsonicHolder.user,
    songs: []
  };
  return pl;
}

/** 歌单详情：元信息 + 曲目 */
function parsePlaylistDetail(o: JsonObj): Playlist {
  const pl: Playlist = parsePlaylistBase(o);
  pl.songs = parseSongs(asArr(o['entry']));
  // 服务端没给时长时按曲目累加，列表页显示总时长要用
  if (pl.duration === 0) {
    let sum: number = 0;
    for (const t of pl.songs) {
      sum += t.duration;
    }
    pl.duration = sum;
  }
  return pl;
}

/**
 * Subsonic 的时间是 ISO8601（2026-11-05T12:00:00.000Z）。
 * 手动拆字段而不是 new Date(str)：鸿蒙上部分格式解析不出来会得到 NaN。
 */
function parseIsoTime(s: string): number {
  const m: RegExpExecArray | null =
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/.exec(s);
  if (m === null) {
    return 0;
  }
  const d: Date = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]),
    Number(m[4]), Number(m[5]), Number(m[6]));
  const t: number = d.getTime();
  return isNaN(t) ? 0 : t;
}

/** Store 在创建 Subsonic 实例后调用，让 parseSongs 能拿到实例拼 streamUrl */
export function bindSubsonic(s: Subsonic): void {
  SubsonicHolder.instance = s;
  SubsonicHolder.user = s.username;
}

// ---------------- 工具 ----------------

/**
 * 解析纯文本歌词。若行首带 [mm:ss.xx] / [mm:ss:xx] 时间标记，则转成带时间轴的行，
 * 否则整段按普通文本处理（synced=false，界面上不高亮）。
 *
 * 两处容易踩、且都会表现为「节奏错乱」的细节，这里都处理了：
 *
 *   1) 一行可以有多个时间标签
 *      [00:10.00][01:20.00][02:30.00]副歌这一句
 *      这是标准写法（副歌复用同一句词）。旧实现只取第一个标签，
 *      80s / 150s 那两句就整个丢了，表现为「中间好长一段没歌词」。
 *
 *   2) 时间轴不一定是升序
 *      作者编辑歌词时复制粘贴、或从别处拼接，很容易出现乱序。
 *      旧实现按原顺序输出，而查找逻辑「遇到超前的行就 break」，
 *      于是乱序点之后的歌词永远命中不到，表现为「后面一直卡在某一 句」。
 */
function enc(s: string): string {
  return encodeURIComponent(s);
}

function md5Hex(input: string): string {
  const md = cryptoFramework.createMd('MD5');
  // 用 TextEncoder 把字符串转成 UTF-8 字节，避免 buffer.Buffer 的 buffer/byteOffset
  // 语义差异（ArkTS 下直接包 buf.buffer 会抛 newByteLength is out of range）。
  const encoder: util.TextEncoder = new util.TextEncoder();
  const data: Uint8Array = encoder.encodeInto(input);
  md.updateSync({ data: data });
  const blob = md.digestSync();
  const bytes: Uint8Array = blob.data;
  let hex: string = '';
  for (let i = 0; i < bytes.length; i++) {
    const h: string = bytes[i].toString(16);
    hex += h.length === 1 ? '0' + h : h;
  }
  return hex;
}
