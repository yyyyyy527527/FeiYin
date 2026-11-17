import fs from '@ohos.file.fs';
import formProvider from '@ohos.app.form.formProvider';
import formBindingData from '@ohos.app.form.formBindingData';
import { common } from '@kit.AbilityKit';

/**
 * 桌面卡片的数据同步。
 *
 * 卡片由 FormExtensionAbility（独立进程）承载，主应用进程里的播放状态
 * 它是读不到的——AppStorage 各进程各一份，跨进程不共享。
 * 这里用一个极小的 JSON 文件做跨进程接力：
 *  - 卡片进程：onAddForm/onRemoveForm 维护 formId 清单；
 *  - 主进程：播放状态变化时推一份快照进文件，再按 formId 清单逐个 updateForm。
 *
 * 文件很小（几条文本 + 一个 id 数组），读写频率又低，
 * 直接用 fs 全量读写，省掉 preferences 跨进程并发的心智负担。
 */

const FILE_NAME: string = 'form_state.json';

/** 卡片数据的快照结构：卡片 UI 上的每个 @LocalStorageProp 对应一个字段 */
export interface FormSnapshot {
  title: string;
  artist: string;
  playing: boolean;
  lyric: string;
}

function emptySnapshot(): FormSnapshot {
  return { title: '', artist: '', playing: false, lyric: '' };
}

function statePath(context: common.Context): string {
  return context.filesDir + '/' + FILE_NAME;
}

function readIds(context: common.Context): string[] {
  try {
    if (!fs.accessSync(statePath(context))) {
      return [];
    }
    const txt: string = fs.readTextSync(statePath(context));
    const st = JSON.parse(txt) as Record<string, Object>;
    const ids: Object | undefined = st['ids'];
    if (ids === undefined) {
      return [];
    }
    return ids as string[];
  } catch (e) {
    return [];
  }
}

/** 同步写文本文件：fs 的 writeSync 只收 fd，包一层打开/关闭 */
function writeAll(path: string, content: string): void {
  const file: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, content);
  } finally {
    fs.closeSync(file.fd);
  }
}

function writeIds(context: common.Context, ids: string[]): void {
  // 写 ids 时保留主进程留下的快照（按 id 合并），互不覆盖
  let snapshot: FormSnapshot = emptySnapshot();
  try {
    if (fs.accessSync(statePath(context))) {
      const txt: string = fs.readTextSync(statePath(context));
      const st = JSON.parse(txt) as Record<string, Object>;
      const snap: Object | undefined = st['snapshot'];
      if (snap !== undefined) {
        snapshot = snap as FormSnapshot;
      }
    }
  } catch (e) {
  }
  try {
    writeAll(statePath(context), JSON.stringify({ ids: ids, snapshot: snapshot }));
  } catch (e) {
  }
}

function writeSnapshot(context: common.Context, snap: FormSnapshot, ids: string[]): void {
  try {
    writeAll(statePath(context), JSON.stringify({ ids: ids, snapshot: snap }));
  } catch (e) {
  }
}

export class FormSync {
  private static ctx: common.UIAbilityContext | null = null;
  /** 节流：歌词逐行推送很密，卡片更新 1s 一次足够 */
  private static lastPushAt: number = 0;
  private static pending: FormSnapshot | null = null;
  private static timer: number = -1;
  /** formId 清单的进程内缓存：没有新卡片时省一次文件读取 */
  private static idsCache: string[] = [];

  /** 主进程启动时调用 */
  static init(context: common.UIAbilityContext): void {
    FormSync.ctx = context;
    FormSync.idsCache = readIds(context);
  }

  /** 卡片进程：桌面新增一张卡片时登记 */
  static addForm(context: common.Context, formId: string): void {
    const ids: string[] = readIds(context);
    if (ids.indexOf(formId) === -1) {
      ids.push(formId);
      writeIds(context, ids);
    }
  }

  /** 卡片进程：卡片被删时注销 */
  static removeForm(context: common.Context, formId: string): void {
    const ids: string[] = readIds(context);
    const idx: number = ids.indexOf(formId);
    if (idx !== -1) {
      ids.splice(idx, 1);
      writeIds(context, ids);
    }
  }

  /** 卡片进程：新卡片刚落桌时，把主进程留下的最后一份快照刷给它 */
  static flushSnapshotTo(context: common.Context, formId: string): void {
    let snap: FormSnapshot = emptySnapshot();
    try {
      if (fs.accessSync(statePath(context))) {
        const txt: string = fs.readTextSync(statePath(context));
        const st = JSON.parse(txt) as Record<string, Object>;
        const s: Object | undefined = st['snapshot'];
        if (s !== undefined) {
          snap = s as FormSnapshot;
        }
      }
    } catch (e) {
    }
    try {
      formProvider.updateForm(formId, formBindingData.createFormBindingData(snap));
    } catch (e) {
    }
  }

  /** 主进程：播放状态/歌词变化时推送（内部节流，1 秒最多一次） */
  static push(data: FormSnapshot): void {
    FormSync.pending = data;
    const wait: number = FormSync.lastPushAt + 1000 - Date.now();
    if (wait > 0) {
      if (FormSync.timer === -1) {
        FormSync.timer = setTimeout(() => {
          FormSync.timer = -1;
          FormSync.doPush();
        }, wait + 10);
      }
      return;
    }
    FormSync.doPush();
  }

  private static doPush(): void {
    const snap: FormSnapshot | null = FormSync.pending;
    const ctx: common.UIAbilityContext | null = FormSync.ctx;
    if (snap === null || ctx === null) {
      return;
    }
    FormSync.pending = null;
    FormSync.lastPushAt = Date.now();
    if (FormSync.idsCache.length === 0) {
      FormSync.idsCache = readIds(ctx);
      if (FormSync.idsCache.length === 0) {
        // 桌面一张卡片都没有：只把快照存下来，新卡片落桌时用
        writeSnapshot(ctx, snap, []);
        return;
      }
    }
    writeSnapshot(ctx, snap, FormSync.idsCache);
    const binding = formBindingData.createFormBindingData(snap);
    for (let i = 0; i < FormSync.idsCache.length; i++) {
      formProvider.updateForm(FormSync.idsCache[i], binding).catch(() => {
        // 卡片已被删除：清单会在下次卡片进程写文件时修正
      });
    }
  }
}
