import FormExtensionAbility from '@ohos.app.form.FormExtensionAbility';
import formBindingData from '@ohos.app.form.formBindingData';
import formInfo from '@ohos.app.form.formInfo';
import Want from '@ohos.app.ability.Want';
import { FormSync } from '../utils/FormSync';

/**
 * 桌面卡片扩展能力（独立进程）。
 * 播放状态在主应用进程里，这个进程读不到——两边的接力都走 FormSync：
 *  - 新卡片落桌：登记 formId，并把主进程留下的最后一份播放快照刷给它；
 *  - 卡片被删：从清单里注销，主进程后续推送就不再带上它。
 * 实时更新由主进程的 FormSync.push 驱动，这里不做定时轮询。
 */
export default class MusicFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const params: Record<string, Object> | undefined = want.parameters as Record<string, Object> | undefined;
    const formId: string = (params !== undefined && params[formInfo.FormParam.IDENTITY_KEY] !== undefined)
      ? params[formInfo.FormParam.IDENTITY_KEY] as string : '';
    FormSync.addForm(this.context, formId);
    // 卡片刚落桌时要立刻有内容：把主进程最后推的播放状态直接刷进去，
    // 等主进程下一次 push 之前它不会自己更新
    FormSync.flushSnapshotTo(this.context, formId);
    return formBindingData.createFormBindingData({
      title: '星籁',
      artist: '点击开始播放',
      playing: false,
      lyric: ''
    });
  }

  onCastToNormalForm(formId: string): void {
    // 临时卡片转为常态卡片，无需处理
  }

  onUpdateForm(formId: string): void {
    // 定时更新兜底：把最后一份快照再刷一次
    FormSync.flushSnapshotTo(this.context, formId);
  }

  onChangeFormVisibility(newStatus: Record<string, number>): void {
    // 卡片重新可见：逐张补刷最新快照
    const ids: string[] = Object.keys(newStatus);
    for (let i = 0; i < ids.length; i++) {
      FormSync.flushSnapshotTo(this.context, ids[i]);
    }
  }

  onFormEvent(formId: string, message: string): void {
    // 交互走 postCardAction 的 call/router 动作拉起 EntryAbility，这里不处理 message
  }

  onRemoveForm(formId: string): void {
    FormSync.removeForm(this.context, formId);
  }
}
