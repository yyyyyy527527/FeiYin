# 飞音同步服务（feiyin-sync）

给「飞音」做账号与数据同步的极简服务端：一个 Node 进程 + 一个 `store.json`，无第三方依赖。

同步内容：深浅色、三组开关（空间音频 / 沉浸光感 / 自动缓存）、音量、Navidrome 地址与用户名、
每日听歌时长、单曲播放次数与时长。**密码不同步**，换机后重新输入。

## 1. 部署（NAS / 任意能跑 Docker 的机器）

```bash
# 把本目录拷到 NAS，例如 /vol1/docker/feiyin-sync
cd /vol1/docker/feiyin-sync
docker compose up -d
curl http://127.0.0.1:8787/v1/health   # {"ok":true,...}
```

没有 Docker 时直接跑：`PORT=8787 node index.js`。

数据落在 `./data/store.json`，备份这个文件就等于备份了所有人的云端数据。

### 端口与访问

- 默认 `8787`，容器映射到宿主同端口。
- 手机在外网要用，建议在 NAS 反向代理上加一个 HTTPS 域名（例如 `sync.example.com`），
  或在路由器上做端口映射。App 里填 `https://sync.example.com` 或 `http://公网IP:8787` 都可以。
- App 默认会用 **Navidrome 的主机名 + 8787** 自动填一个地址，同机部署时不用手改。

## 2. App 里的两种登录方式

| 方式 | 前提 | 说明 |
|---|---|---|
| 华为账号一键登录 | AGC 建应用、填 Client ID、配置签名指纹、真机已登录华为账号 | 换机后自动识别，无需输入任何东西 |
| 恢复码登录 | 无 | 登录成功后设置页会显示 16 位恢复码，换机时输入即可取回全部数据 |

恢复码是不依赖任何第三方的兜底路径：模拟器、刷机、华为账号异常时都能用。

### 华为账号的 AGC 配置（真机才需要）

1. AppGallery Connect 创建项目 → 添加应用，包名 `com.limerence.feiyin`。
2. 「项目设置 → 常规 → 应用信息」复制 **Client ID**。
3. 填到 `entry/src/main/module.json5` 的 metadata：

   ```json5
   { "name": "client_id", "value": "你的 Client ID" }
   ```

4. 在 AGC 里登记调试证书的 SHA256 指纹，否则会报「应用签名与 AGC 配置不一致」（1001500001）。
5. 未完成以上步骤时，App 会提示「应用未开通华为账号登录能力」，此时用恢复码照样能同步。

## 3. 服务端如何校验身份

- 客户端把华为 `idToken` 交给服务端，服务端调 `oauth-login.cloud.huawei.com/oauth2/v3/tokeninfo`
  校验签名并取 `openid`；**绝不信任客户端直接传来的 openid**。
- `ALLOW_INSECURE_OPENID=1` 仅供本地调试（跳过校验，直接拿 openid 登录），生产不要开。
- 登录后签发 64 位随机令牌，服务端只存 `sha256(token)`，有效期 90 天，重新登录会轮换。

## 4. 合并规则

多设备同时用，冲突按「谁的数更大/更新」处理，不会翻倍也不会互相覆盖丢数据：

- 每日时长：同一天取**较大值**（两台设备各记一份不会相加）。
- 单曲统计：次数、时长分别取较大值，标题/歌手取 `lastAt` 更新的那份。
- 设置类：客户端带的是**设置最后被改动的时间**（不是请求时间），服务端只在严格更新时才覆盖，
  所以一台从没改过设置的新设备不会拿默认值把云端配置冲掉。
- 日统计最多留 120 天，单曲最多留 400 首（按次数、时长淘汰）。

## 5. 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/v1/health` | 健康检查，App 的「测试」按钮用它 |
| POST | `/v1/auth/login` | `{idToken}` 或（调试）`{openid}` → `{token, userId, recoveryCode, hasCloudData}` |
| POST | `/v1/auth/resume` | `{code}` 恢复码换令牌 |
| GET | `/v1/sync` | 拉取云端数据（需 `Authorization: Bearer <token>`） |
| POST | `/v1/sync` | 上传本地数据，服务端合并后返回全量 |
| POST | `/v1/auth/logout` | 注销当前令牌 |

## 6. 安全提醒

- 恢复码等同于长期密码，明文存在 `store.json` 里（换来的是用户随时能在 App 里重新查看）。
  这个文件别放进任何公开目录，NAS 的共享权限也要收紧。
- 建议只在 HTTPS 下使用；明文 HTTP 会让令牌在链路上裸奔。
