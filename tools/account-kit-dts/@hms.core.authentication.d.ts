/*
 * Account Kit（华为账号统一认证）最小声明文件，用于无 HMS SDK 的离线构建环境。
 * 接口形状与官方 @hms.core.authentication（API 12+）一致，只声明登录链路用到的部分；
 * 运行时由真机 HMS Core（华为账号服务）提供实现，模拟器/无 HMS 设备不可用。
 */
import type common from '@ohos.app.ability.common';

declare namespace authentication {
  /** 认证请求基类：state 用于响应校验（防跨站） */
  interface AuthenticationRequest {
    state?: string;
  }

  /** 认证响应基类 */
  interface AuthenticationResponse {
    state?: string;
  }

  /** idToken 签名算法 */
  enum IdTokenSignAlgorithm {
    ES256 = 0,
    PS256 = 1
  }

  /** 华为账号登录请求 */
  interface LoginWithHuaweiIDRequest extends AuthenticationRequest {
    /** 用户未登录/未授权时是否强制拉起登录或授权页 */
    forceLogin: boolean;
    idTokenSignAlgorithm?: IdTokenSignAlgorithm;
  }

  /** 登录成功返回的凭据 */
  interface LoginWithHuaweiIDCredential {
    /** 应用维度用户标识（必返回） */
    openID: string;
    /** 开发者维度用户标识 */
    unionID?: string;
    /** 用户身份令牌（JWT），交给服务端校验 */
    idToken?: string;
    /** 授权码 */
    authorizationCode?: string;
  }

  /** 登录响应 */
  interface LoginWithHuaweiIDResponse extends AuthenticationResponse {
    data?: LoginWithHuaweiIDCredential;
  }

  /** 授权请求（头像、昵称等扩展资料） */
  interface AuthorizationWithHuaweiIDRequest extends AuthenticationRequest {
    permissions?: Array<string>;
    scopes?: Array<string>;
    forceAuthorization?: boolean;
  }

  /** 授权成功返回的凭据 */
  interface AuthorizationWithHuaweiIDCredential {
    openID?: string;
    unionID?: string;
    idToken?: string;
    authorizationCode?: string;
    avatarUri?: string;
    nickName?: string;
  }

  /** 授权响应 */
  interface AuthorizationWithHuaweiIDResponse extends AuthenticationResponse {
    data?: AuthorizationWithHuaweiIDCredential;
  }

  /** 取消授权请求 */
  interface CancelAuthorizationRequest extends AuthenticationRequest {
  }

  /**
   * 华为账号服务认证工厂类：按场景创建请求对象。
   * 登录请求必须由它创建——直接 new LoginWithHuaweiIDRequest 会拿到空参数，
   * 运行时报 "args is invalid" → 1001502009。
   */
  class HuaweiIDProvider {
    constructor();
    createLoginWithHuaweiIDRequest(): LoginWithHuaweiIDRequest;
    createAuthorizationWithHuaweiIDRequest(): AuthorizationWithHuaweiIDRequest;
    createCancelAuthorizationRequest(): CancelAuthorizationRequest;
  }

  /**
   * 认证服务控制器：接收并执行请求。
   * 需在页面或组件生命周期内调用 executeRequest。
   */
  class AuthenticationController {
    constructor(context?: common.Context);
    executeRequest(request: AuthenticationRequest): Promise<AuthenticationResponse>;
  }
}

export default authentication;
