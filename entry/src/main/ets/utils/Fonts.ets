import { UIContext } from '@kit.ArkUI';

/**
 * 全应用统一字体：Tinos —— Times New Roman 的度量兼容开源替代（Apache-2.0）。
 *
 * 说明：Tinos 只含西文（拉丁/希腊/西里尔）字形，中文在这里没有字形，
 * 排版时会自动回退到系统中文字体，观感与系统默认一致。
 * 也就是说：统一字体后，英文与数字变成衬线体，中文仍走系统黑体，
 * 与播放页歌词的表现完全一致。
 *
 * 注册必须走 UIContext.getFont()：@ohos.font 的全局 registerFont 已废弃，
 * 调了不生效（表现为 fontFamily 静默回退到系统默认字体）。
 */
export const APP_FONT: string = 'FeiYinSerif';
export const APP_FONT_BOLD: string = 'FeiYinSerifBold';
/**
 * 刊头题词专用：Playfair Display Italic。
 * 只用在播放页顶部那句标语上——高对比的衬线斜体，14vp 也立得住，
 * 与 Tinos 的正体拉开层次，像唱片内页的题词而不是一行说明文字。
 */
export const APP_FONT_SCRIPT: string = 'FeiYinScript';

let registered: boolean = false;

/** 注册随包字体，进程内只需一次（重复注册会重建字体集，开销很大） */
export function registerAppFonts(ctx: UIContext): void {
  if (registered) {
    return;
  }
  registered = true;
  try {
    const fonts = ctx.getFont();
    fonts.registerFont({ familyName: APP_FONT, familySrc: $rawfile('fonts/Tinos-Regular.ttf') });
    fonts.registerFont({ familyName: APP_FONT_BOLD, familySrc: $rawfile('fonts/Tinos-Bold.ttf') });
    fonts.registerFont({
      familyName: APP_FONT_SCRIPT,
      familySrc: $rawfile('fonts/PlayfairDisplay-Italic.ttf')
    });
  } catch (err) {
    console.error('[font] 字体注册失败：' + JSON.stringify(err));
  }
}
