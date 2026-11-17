import { curves } from '@kit.ArkUI';

/**
 * 全局动效令牌。
 *
 * 之前各处的时长与曲线是就地写死的：页面切换 64ms + spring(0.42, 0.95)、
 * 弹层 spring(0.34, 0.86)、遮罩 180ms 线性、迷你条 160ms……同一套界面里
 * 出现了五六个互不相干的节奏，切换时就会显得"各动各的"，整体发硬。
 *
 * 这里按鸿蒙的动效分层收敛成三档：
 *
 *   微动效（按压、状态翻转）  120~180ms   —— 只做反馈，不能拖
 *   容器动效（弹层、迷你条）  240~320ms   —— 有实体感，用弹簧收尾
 *   页面动效（转场、换层）    300~380ms   —— 空间关系，位移 + 透明度
 *
 * 曲线选择的原则：
 *   · 进入/展开用 spring：起步快、收尾自带减速，落位"有重量"，不会撞停；
 *   · 退出/收起用 FastOutSlowIn：干脆、不拖尾，避免用户等第二下；
 *   · 遮罩用 Friction：前段变化快、后段几乎不动，和面板的弹簧节奏对齐。
 *
 * dampingFraction 的取值经验：
 *   0.7~0.8  明显回弹（适合小控件，如 tab 指示）
 *   0.85~0.9 轻微过冲（弹层、卡片）
 *   0.92~1.0 几乎不过冲（整页内容，过冲会让人晕）
 */
export class Motion {
  // ---------- 时长 ----------
  /** 页面进入：略慢于系统默认，给位移留出可读的时间 */
  static readonly PAGE_IN: number = 340;
  /** 页面退出：比进入快，返回操作要"立刻有反应" */
  static readonly PAGE_OUT: number = 280;
  /**
   * 模态页（播放页）转场：整屏从底部推上来 / 滑下去。
   *
   * 播放页是从迷你播放条"长出来"的，纵向展开才对应这个来源；
   * 之前用横向 18% 推入，下拉返回时页面却横着滑走，方向都不一致，
   * 这是"割裂"最直接的一层。
   */
  static readonly MODAL_IN: number = 400;
  static readonly MODAL_OUT: number = 320;
  /** 模态页拖拽时圆角（vp）：拉下来一点才出现，模拟"卡片被拉出" */
  static readonly MODAL_RADIUS: number = 26;
  /** 内容层退场（换 tab / 换视图） */
  static readonly CONTENT_OUT: number = 110;
  /** 弹层遮罩：进场比面板慢一点，退场比面板快一点 */
  static readonly SCRIM_IN: number = 240;
  static readonly SCRIM_OUT: number = 190;
  /** 微动效：按压、图标状态 */
  static readonly MICRO: number = 160;
  /** 底色 / 明暗过渡 */
  static readonly THEME: number = 300;

  // ---------- 位移 ----------
  /** 换层时旧内容后退的距离（vp），负值表示沿行进反方向让位 */
  static readonly PUSH_BACK: number = 14;
  /** 换层时新内容进入的起始距离（vp） */
  static readonly PUSH_IN: number = 28;
  /** 同层切换（tab）只做纵向微动，不做横向 */
  static readonly TAB_RISE: number = 10;
  /** 换层时的轻微缩放，给"更深一层"的空间暗示 */
  static readonly PUSH_SCALE: number = 0.985;
  /**
   * 上层页面覆盖时，下层页面压暗到的不透明度。
   * 只压暗、不位移——上层有两种进入方向（纵向模态 / 横向推入），
   * 位移方向不能统一，变暗可以。
   */
  static readonly DIM: number = 0.72;

  // ---------- 曲线工厂 ----------

  /** 进入 / 展开：弹簧，起步快、收尾自然 */
  static enter(response: number = 0.36, damping: number = 0.92): AnimateParam {
    return { curve: curves.springMotion(response, damping) };
  }

  /** 退出 / 收起：固定时长缓动，干脆不拖尾 */
  static exit(duration: number = Motion.CONTENT_OUT, curve: Curve = Curve.FastOutSlowIn): AnimateParam {
    return { duration: duration, curve: curve };
  }

  /** 遮罩：与面板节奏对齐，前段快、后段稳 */
  static scrim(duration: number): AnimateParam {
    return { duration: duration, curve: Curve.Friction };
  }

  /** 弹层容器：比内容层稍重（response 更大、damping 更低），推上来有实体感 */
  static sheet(): AnimateParam {
    return { curve: curves.springMotion(0.34, 0.86) };
  }

  /** 微动效 */
  static micro(): AnimateParam {
    return { duration: Motion.MICRO, curve: Curve.FastOutSlowIn };
  }

  /**
   * 模态页被拖拽后"飞出去"的收尾：比常规退出更快，跟手的手感才不断。
   */
  /**
   * 模态页被拖拽后「飞出去」的收尾。
   * 时长由剩余距离决定（见 NowPlaying.flyOut）：已经拉到一半再松手，
   * 若还用固定 240ms 慢慢蹭出去，手感会立刻从「跟手」变成「被拖住」。
   */
  static modalFling(ms: number = 240): AnimateParam {
    return { duration: ms, curve: Curve.Friction };
  }

  /** 拖拽取消、弹回原位：轻微回弹，像卡片被松手吸回去 */
  static modalSnapBack(): AnimateParam {
    return { curve: curves.springMotion(0.3, 0.9) };
  }
}
