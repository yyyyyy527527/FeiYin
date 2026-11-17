import { authentication } from '@kit.AccountKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 华为账号一键登录（Account Kit）。
 *
 * 前置条件（缺一不可，否则会报错）：
 *  1. 在 AppGallery Connect 创建项目并添加本应用，包名 com.limerence.feiyin；
 *  2. 在 AGC「项目设置 → 常规 → 应用信息」拿到 Client ID，填进 module.json5 的 client_id metadata；
 *  3. AGC 里配置调试/发布证书的 SHA256 指纹；
 *  4. 真机登录华为账号（模拟器与未登录账号的设备会失败）。
 *
 * 拿到的是 idToken（JWT）与 openID：idToken 交给同步服务端向华为校验，
 * 客户端不自己解析用户身份，也不把 openID 当成可信凭证使用。
 */
export interface HuaweiLoginResult {
  ok: boolean;
  msg: string;
  /** 华为侧应用内唯一标识 */
  openid: string;
  /** 交给服务端校验的 JWT */
  idToken: string;
}

export class HuaweiAuth {
  static async signIn(ctx: common.UIAbilityContext): Promise<HuaweiLoginResult> {
    try {
      const controller: authentication.AuthenticationController =
        new authentication.AuthenticationController(ctx);
      // 必须由 HuaweiIDProvider 创建请求对象。
      // 直接 new LoginWithHuaweiIDRequest() 会让服务端拿到空参数，
      // 日志表现为 "LoginWithHuaweiIDRequestConstructor args is empty"
      // → "args is invalid" → 回调 1001502009（Internal error）。
      const provider: authentication.HuaweiIDProvider = new authentication.HuaweiIDProvider();
      const req: authentication.LoginWithHuaweiIDRequest = provider.createLoginWithHuaweiIDRequest();
      // 已授权过时静默拿凭证，没有则拉起华为账号授权页
      req.forceLogin = false;
      req.state = 'feiyin_' + Date.now();
      const resp: authentication.LoginWithHuaweiIDResponse =
        await controller.executeRequest(req) as authentication.LoginWithHuaweiIDResponse;
      const data: authentication.LoginWithHuaweiIDCredential | undefined = resp.data;
      if (data === undefined) {
        return { ok: false, msg: '没有拿到华为账号信息', openid: '', idToken: '' };
      }
      const idToken: string = data.idToken === undefined ? '' : data.idToken;
      if (idToken.length === 0) {
        return { ok: false, msg: '华为账号未返回身份令牌，请重试', openid: '', idToken: '' };
      }
      return { ok: true, msg: '', openid: data.openID, idToken: idToken };
    } catch (e) {
      return { ok: false, msg: describeError(e), openid: '', idToken: '' };
    }
  }
}

/** 把 Account Kit 的错误码翻译成人话 */
function describeError(e: Object): string {
  const err = e as BusinessError;
  const code: number = err !== null && err.code !== undefined ? err.code : 0;
  if (code === 1001502001) {
    return '设备未登录华为账号，请先在系统设置里登录';
  }
  if (code === 1001502002) {
    return '当前账号不支持该应用登录';
  }
  if (code === 1001502003) {
    return '登录被取消';
  }
  if (code === 1001502014) {
    return '应用未开通华为账号登录能力，请检查 AGC 配置';
  }
  if (code === 1001502009) {
    return '华为账号服务内部错误（1001502009），请检查 AGC 配置后重试';
  }
  if (code === 1001500001) {
    return '应用签名与 AGC 配置不一致';
  }
  const msg: string = err !== null && err.message !== undefined ? err.message : '';
  // 设备上根本没有 Account Kit（非华为设备 / 精简系统）时，动态 import 会抛模块找不到
  if (msg.indexOf('Cannot find') >= 0 || msg.indexOf('module') >= 0 &&
    (msg.indexOf('not found') >= 0 || msg.indexOf('not exist') >= 0)) {
    return '当前设备不支持华为账号登录，请使用恢复码登录';
  }
  if (msg.length > 0) {
    return msg + (code > 0 ? '（' + code + '）' : '');
  }
  return '华为账号登录失败';
}
