import { Track } from '../model/Models';

/**
 * 越界时返回的占位曲目。
 * LazyForEach 在数据收缩的那一帧仍可能按旧下标来取数据，
 * 返回 undefined 会让下游的 t.id / t.title 直接抛错（表现为列表整块消失）。
 */
const EMPTY_TRACK: Track = {
  id: '', href: '', title: '', artist: '', album: '', folder: '',
  size: 0, duration: 0, cached: false, cachedPath: '',
  coverArt: '', albumId: '', suffix: '', bitRate: 0,
  samplingRate: 0, bitDepth: 0, streamUrl: ''
};

/**
 * 给 LazyForEach 用的歌曲数据源。
 * 「全部歌曲」是分页追加的，最终可能有几千条；用 ForEach 会一次性建出全部节点，
 * LazyForEach + IDataSource 只创建可见区域，滚动才补。
 */
export class TrackSource implements IDataSource {
  private items: Track[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): Track {
    if (index < 0 || index >= this.items.length) {
      return EMPTY_TRACK;
    }
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  /** 覆盖全量（切标签、刷新） */
  setAll(list: Track[]): void {
    this.items = list;
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }

  /** 追加一页 */
  append(list: Track[]): void {
    this.items = this.items.concat(list);
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }

  /** 单项变化（如勾选态）：只刷新这一行，不整表重建 */
  notifyItemAt(index: number): void {
    if (index < 0 || index >= this.items.length) {
      return;
    }
    for (const l of this.listeners) {
      l.onDataChange(index);
    }
  }

  /** 已经加载的条数 */
  count(): number {
    return this.items.length;
  }

  /** 取全部（播放队列要用完整列表） */
  all(): Track[] {
    return this.items;
  }
}
