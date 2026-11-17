import { motion } from '@kit.MultimodalAwarenessKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'FeiYin.Grip';

/**
 * 智感握姿：感知握持手，结果写入 AppStorage 'gripHand'（'left' | 'right'），
 * 供收起态的迷你播放栏唱片与底部导航圆钮换边。
 *
 * 信号源两级：
 *  1. motion.on('holdingHandChanged')  —— 握持手（首选，边框电容传感器识别，API 20+）；
 *  2. 订阅失败（801 设备不支持 / 201 权限等）→ 降级 motion.on('operatingHandChanged')
 *     —— 操作手（用户最近用哪只手触屏）。
 *
 * 状态策略（避免 UI 抖动）：只认 LEFT_HAND_HELD 一个信号换到左边，
 * 其余（右手/双手/未握持/未知）一律回落默认右侧。
 * 设备不支持时静默降级，不影响 App 其他功能；错误码走 hilog 便于真机诊断。
 */
export function startGripWatch(): void {
  AppStorage.setOrCreate('gripHand', 'right');

  const applyHand: (left: boolean) => void = (left: boolean) => {
    AppStorage.setOrCreate('gripHand', left ? 'left' : 'right');
  };

  let subscribed: boolean = false;
  try {
    motion.on('holdingHandChanged', (st: motion.HoldingHandStatus) => {
      console.info(TAG + ' holdingHand=' + st.toString());
      applyHand(st === motion.HoldingHandStatus.LEFT_HAND_HELD);
    });
    subscribed = true;
    console.info(TAG + ' holdingHandChanged subscribed');
  } catch (err) {
    const e = err as BusinessError;
    console.error(TAG + ' holdingHandChanged failed: code=' + e.code + ' msg=' + e.message);
  }

  if (!subscribed) {
    // 握持手不可用：降级用操作手（用户最近用哪只手点屏幕）
    try {
      motion.on('operatingHandChanged', (st: motion.OperatingHandStatus) => {
        console.info(TAG + ' operatingHand=' + st.toString());
        applyHand(st === motion.OperatingHandStatus.LEFT_HAND_OPERATED);
      });
      console.info(TAG + ' fallback operatingHandChanged subscribed');
    } catch (err) {
      const e = err as BusinessError;
      console.error(TAG + ' operatingHandChanged failed: code=' + e.code + ' msg=' + e.message);
      console.error(TAG + ' 握姿感知不可用，悬浮控件保持默认右侧');
    }
  }
}
