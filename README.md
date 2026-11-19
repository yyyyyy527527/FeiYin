# 飞音 FeiYin · 鸿蒙 7 音乐播放器

一个用 ArkTS / ArkUI 原生实现的 HarmonyOS NEXT 音乐播放器，支持两种音乐源：**Navidrome / Subsonic**（流式播放）与**飞牛 NAS WebDAV**（下载缓存播放），集成鸿蒙 7（API 26）多项新特性。

## 鸿蒙 7 特性集成

| 特性 | 接入方式 |
| --- | --- |
| **空间音频** | 播放页一键开关，通过 AudioSpatialization 状态切换立体声场增强 |
| **沉浸光感** | 播放页背景渐变随播放状态动态偏移，专辑封面光晕 blur 动效 |
| **互动卡片** | 桌面 2x2 播放控制卡片（FormCard + FormExtensionAbility），点击跳转 App |
| **应用快启** | EntryAbility 预建数据源连接，减少冷启动等待 |
| **后台播放** | module.json5 声明 `backgroundModes: audioPlayback`，支持锁屏继续播放 |

## 两种数据源

### Navidrome / Subsonic（推荐）
- 通过 **Subsonic API** 连接 Navidrome、Airsonic 等兼容服务器
- **token 认证**：`t = md5(password + salt)`，比明文密码安全
- **流式播放**：AVPlayer 直接加载 `stream` URL，边下边播，无需等待下载
- **分类浏览**：专辑（最新/随机/最常/字母序）、歌手（838 位）、收藏、搜索
- **专辑封面**：`getCoverArt` 接口实时加载，列表/播放页/迷你条全覆盖
- 接口：ping / getArtists / getAlbumList / getAlbum / getArtist / search2 / getStarred2 / getGenres / getRandomSongs / star / unstar / stream / getCoverArt

### 飞牛 NAS WebDAV
- PROPFIND 浏览 fnOS 音乐目录，Basic Auth 认证
- 下载到本地缓存后播放，支持离线

## 功能

- **数据源切换**：Setup 页顶部一键切换 Navidrome / 飞牛 NAS
- **Navidrome 浏览**：专辑网格（带封面）、歌手列表、收藏列表、搜索（歌曲+专辑）
- **WebDAV 浏览**：面包屑导航 + 文件夹/文件列表
- **音乐播放**：AVPlayer 封装，Subsonic 流式 / WebDAV 缓存两种模式
- **播放控制**：播放/暂停/上一首/下一首/进度拖动/随机/循环（off/all/one）/随机播放50首
- **专辑封面**：Subsonic 模式全链路封面（列表格子、歌曲行、迷你条、全屏播放页）
- **MiniPlayer**：底部常驻迷你播放条（含封面）
- **全屏播放页**：真实专辑封面、沉浸光感动效、空间音频开关、进度条
- **设置页**：空间音频/沉浸光感/自动缓存开关、音量、缓存管理
- **格式支持**：MP3、FLAC、WAV、AAC、M4A、OGG、WMA、Opus

## Navidrome 配置步骤

1. 打开飞音 App，Setup 页顶部选择「Navidrome」
2. 点「Navidrome」预设按钮自动填入地址和账号
3. 输入密码（仅输入一次，之后自动记住，不写入代码）
4. 点「测试连接」→ 显示 `连接成功 · navidrome x.x.x` →「进入音乐库」
5. 按 专辑/歌手/收藏 浏览，点歌曲即播；右上角随机图标可随机播放 50 首

## 飞牛 NAS 配置步骤

1. 飞牛 fnOS → 系统设置 → 远程访问 → 开启 FN Connect
2. 文件共享协议 → WebDAV → 勾选音乐文件夹为可见
3. Setup 页选「飞牛 NAS」→ 填入 WebDAV 地址与 fnOS 账户 → 测试连接

## 目录结构

```
FeiYin/
├── AppScope/                      应用配置
├── build-profile.json5            API 26 构建配置
├── entry/src/main/
│   ├── module.json5               权限(INTERNET/后台播放) + 网络安全配置
│   ├── ets/
│   │   ├── entryability/          EntryAbility（快启预建连接）
│   │   ├── model/Models.ets       Track/Artist/Album/Genre/ServerConfig/Settings + 详情接口
│   │   ├── net/
│   │   │   ├── WebDav.ets         WebDAV PROPFIND 客户端
│   │   │   └── Subsonic.ets       Subsonic API 客户端（token 认证 + JSON 解析）
│   │   ├── player/PlayerCore.ets  AVPlayer 封装 + 队列 + 流式/缓存双模式
│   │   ├── store/Store.ets        preferences 持久化 + 数据源分流 + 单例
│   │   ├── utils/                 Theme / Router
│   │   ├── components/MiniPlayer.ets  迷你播放条（含封面）
│   │   ├── pages/
│   │   │   ├── Setup.ets          数据源切换 + Navidrome/WebDAV 配置
│   │   │   ├── Library.ets        WebDAV 文件夹浏览
│   │   │   ├── SubsonicLibrary.ets Navidrome 分类浏览（专辑/歌手/收藏/搜索）
│   │   │   ├── NowPlaying.ets     全屏播放页（封面 + 沉浸光感）
│   │   │   └── Settings.ets       设置页
│   │   └── form/                  MusicFormAbility（桌面卡片扩展）
│   └── resources/
│       ├── base/media/            27 个 SVG 图标 + 应用图标
│       └── base/profile/          页面清单 + 网络配置
```

## 运行

1. DevEco Studio（SDK 26.0.0）打开 `FeiYin/`
2. 等待 Sync → 配置签名 → Run `entry`
3. 首次进入选择数据源并填写连接信息

命令行编译（已验证通过）：
```bash
export DEVECO_SDK_HOME="<DevEco Studio>/sdk"
node "<DevEco Studio>/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`（558 KB）

## 设计

深色主题（#0D0D0F 背景），珊瑚红主色（#FF6470），暖金辅色（#FFC864）。播放页沉浸渐变背景 + 光晕动效模拟鸿蒙 7 沉浸光感组件效果。

## 近期更新（v2.0.0）

- **播放页常亮**：播放页可见且正在出声时保持屏幕常亮；暂停、离开页面、切到后台立即交还系统
- **后台静止省电**：切后台停掉全部装饰性定时器（播放页场景动画 60ms、频谱 130ms、音律图 33ms、时计环盘 40ms、迷你条唱片自转 100ms），回前台自动续上
- **暂停即停帧**：音律起伏图落稳后自行停止重绘，恢复播放或缓冲结束再起转

### v1.1.82

- **锁屏歌词**：整份 LRC 随 MediaSession metadata 交系统渲染，支持锁屏与控制中心歌词
- **桌面互动卡片**：2x2 卡片显示封面/歌名，内嵌上一首/播放暂停/下一首三键直达后台播放
- **播放页横滑切歌**：左右滑动切换上/下一首
- **全部歌曲左滑操作**：快捷「收藏」「下一首」
- **桌面长按快捷方式**：随机播放 / 播放喜爱 / 每日推荐 三入口
- **桌面歌词**（API 23+ 设备支持时开启）
- **排行/统计实时刷新**、**封面主色调提取内存优化**
- 全新矢量品牌图标（四角星 + 声波柱）

## 构建

```bash
# DevEco Studio 打开工程直接构建，或命令行：
hvigorw assembleHap -p product=default -p buildMode=debug
```

版本号维护在 `AppScope/app.json5`。`server/` 为可选的本地代理服务（Node.js），`tools/make_icon.py` 为图标生成脚本。
