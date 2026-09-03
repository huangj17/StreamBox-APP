# 更新日志

本文件记录 StreamBox 各版本的主要变更。版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)，
完整发布产物见 [Releases](https://github.com/huangj17/StreamBox-APP/releases)。

## [v0.4.0] — 2026-09-03

### 界面与交互

- 首页移除顶部片源切换栏，首页片源统一在设置中管理。
- 设置与片源管理采用 TV 优先的分区布局，区分白色焦点和红色选中态；片源操作集中在确认后打开的弹窗中。
- 搜索页采用左侧搜索与历史、右侧结果网格；卡片加宽，网格最多 6 列，手机竖屏保留双列。确认后打开输入弹窗，历史记录通过「管理」删除。
- 播放页改为底部时间轴与操作栏，选集、线路和设置使用侧栏；暂停、缓冲和操作面板期间保持控件可见。
- 快进与快退在左右方向键松开时自动跳转，长按逐级加速，无需额外按确认；取消预览后松键不会误跳转。

### 片源与检测

- 官方片源支持远程同步：启动时后台更新，前台每 30 分钟检查，也可手动立即更新；网络失败继续使用缓存，保留首页、启停偏好及自定义源。
- 片源健康检测改为最多 6 路持续并发，完成即补位；每个片源 12 秒总超时并取消底层请求，防止慢源拖住后续检测。区分等待与检测状态，合并重复请求，移除片源时取消任务并忽略迟到结果。
- 官方配置合并原生产「荐片视频、爱看机器人、异世界动漫」，与现有源共用列表；保留历史身份、首页及启用偏好。为指定生产端点恢复 HTTP 和 Bridge 解析支持，隔离个人 Gateway Token。
- 影片详情保留字符串 ID，Bridge 相对剧集地址进入解析流程，避免异世界动漫收藏、播放和续播使用错误的影片 ID。

### 修复与文档

- 修复回车确认「退出播放」后立即重新进入的问题：控件只响应自身完整的按下与松开，忽略焦点切换后遗留的松键事件。
- 保留搜索结果跨屏移动、异步追加、详情返回和播放侧栏关闭后的焦点。
- 更新根目录与客户端 README 的操作说明，并补充 2026-09-03 的首页、搜索、片源管理、播放控制和播放设置侧栏截图；旧视频标记为早期演示。

### 升级与验证

- 本次片源兼容修复需要安装新版客户端；更新后在「设置 → 配置源管理 → 官方片源」选择「立即更新」，加载合并后的 19 个官方片源。
- Android 沿用原正式签名配置，支持覆盖升级；同时提供 macOS 和 Windows 安装包。
- 175 项 Flutter 测试及静态分析通过，CI 的 Flutter 检查与 JAR Bridge 构建通过；已验证 macOS 键盘操作及荐片视频样片播放，尚未完成 TV 实机验收。
- 需要网页解析的剧集仍可能无法直接播放，例如本次抽查的异世界动漫样片；片源恢复不代表所有剧集均可直连播放。

## [v0.3.0] — 2026-08-14

### 新增

- **片源健康检测**：片源管理页显示「可用 / 不可用 / 检测中 / 待验证」，支持一键重新检测；
  检测会从最新条目抽取少量直链，继续验证 HLS 清单与首个分片/密钥，真正测通播放链路
  （二进制资源只读第一个网络分块，不产生大流量）
- **苹果 CMS XML 方言解码**：此前只支持 JSON 的站点现在也能接入
- Gateway Token 支持通过 `--dart-define=STREAMBOX_GATEWAY_TOKEN=...` 注入，无需写进片源 URL
- **Android 正式签名安装包**：Release 产物新增 `StreamBox-v0.3.0-android.apk`（arm64-v8a / armeabi-v7a），
  证书 SHA-256 指纹 `7620C762…A9B32F`，后续版本沿用同一证书，可直接覆盖升级

### 安全

- 新增统一 URL 策略 `UrlPolicy`：配置源 / Gateway 强制 HTTPS（仅本机允许 HTTP），
  CMS 与播放地址禁止指向本机及私网地址；重定向逐跳校验
- 响应体大小与解码边界收紧（`BoundedResponse`），避免超大响应打爆内存
- Android `network_security_config` 收敛明文流量白名单，iOS / macOS ATS 例外同步收紧
- Bridge 新增 `GatewayRequestGuard`：常量时间 Token 校验、按客户端 IP 令牌桶限流、
  全局并发上限；显式不信任 `X-Forwarded-For`
- Bridge 容器改用 distroless + `nonroot` 运行，健康检查用纯 Java 实现（镜像内无需 shell / curl）
- Gradle 依赖锁定（`gradle.lockfile` + `verification-metadata.xml`）与基础镜像 digest 固定，构建可复现
- 发布流水线接入 Android 正式签名与 `apksigner` 证书指纹校验，签名不符即构建失败

### 修复与优化

- 播放缓冲重写：仅合并包含当前播放位置的连续区间，进度条不再把空洞画成已缓存；
  新增缓冲健康度分级与播放时钟推进检测，卡死可被准确识别并触发恢复；自适应预加载
- 修复多处异步竞态：页面销毁后的 setState、过期请求覆盖新结果、无谓的 UI 重建
- 片源解析与模型层补齐字段容错，脏数据不再直接抛异常

### 变更

- Bridge 移除聚合器、artifact store、catalog 同步等历史模块，回归
  「加载 JAR → 暴露 CMS 兼容 API」的单一职责
- 播放器、设置页、片源管理页按 widget / panel 拆分
  （`player_widgets`、`settings_panels`、`source_manage_widgets`）
- 新增回归测试：健康检测、缓冲计算、CMS 兼容性、搜索 provider、异步 widget、Bridge 路由契约

## [v0.2.0] — 2026-05-09

### 新增

- **首页导航重做**：`SideNav` 替代 `TopNav`，悬浮 80→240dp 展开，左红条 + 红环焦点态
- 全站统一焦点视觉：详情 / 搜索 / 设置 / 收藏 / 历史 / 错误页统一走 `TvFocusable` 规范
- 详情页强化：autofocus「播放 / 继续第 N 集」、长按 OK 弹出「从头播放 / 复制链接」、
  长简介可展开模态阅读
- 搜索页改造：进页 autofocus 输入框、历史 chip 长按 OK 删除、结果 grid 顶行 ↑ 锚回搜索栏
- 抽出共享 `TvActionButton` 与 `TvBackButton`，移除散落的内联焦点样式

### 修复与优化

- 失效片源跳转：由「点不动」改为 SnackBar 提示 +「去搜索」一键跨源回查；历史 tile 失效降级展示
- 播放器 30 秒首帧超时兜底，卡 buffering 不报错时弹出可重试 / 切线路的错误遮罩
- 用 DNS 预解析替代 HEAD 预热，修复部分 CDN 单次 token 被消耗导致永远 loading 的问题
- libmpv 调优（64 MiB 缓冲 / `cache-secs 30` / `demuxer-readahead-secs 20` / 4 线程解码）
- 搜索与详情错误文案分类化，不再向大屏 dump 异常堆栈

### 变更

- 默认片源调整：移除失效的「金鹰资源」，「暴风资源」升至首位并默认选中；Hive 自动迁移旧数据
- 本地 Bridge 自动探测：`localhost:9978` 在线时自动使用本地，否则回退远程
- Bridge 响应缓存 60 秒、双 https URL sanitize、`/docs` 别名与根路径跳转 Swagger UI；
  客户端首页 rail 限制并发 4

## [v0.1.2] — 2026-05-07

### 新增

- 搜索页遥控交互重做：取消输入框 autofocus 避免输入法抢焦点、历史 chip 长按删除、
  提交后焦点转移到首个结果、Esc / 浏览器返回 / 手柄 B 统一「返回或清空」、
  错误与空态下的操作按钮可聚焦
- 新增 `CONTRIBUTING.md` 与 Bug / Feature Issue 模板，并禁用空白 Issue
- README 补充首页截图、演示视频、安装说明与 Roadmap

### 修复与优化

- 播放器抽出 `_isConfirmKey` / `_isPlayPauseKey`，重构按键处理逻辑
- 首页 Banner 复用首批动态分类数据，减少冷启动网络请求并预热 rail 缓存
- chip 保留 2px 透明边框，焦点切换不再引起布局抖动

### 变更

- CI 移除 Linux 构建（客户端暂无 `linux/` 工程）

## [v0.1.1] — 2026-04-29

### 新增

- 新增 GitHub Actions 发布工作流：推送 `v*` tag 时自动构建客户端并挂载到 Release
  （Android / macOS / Windows / Linux）；Android APK 使用调试签名兜底，仅供侧载

## [v0.1.0] — 2026-04-29

首个开源版本。

- `client/` — Flutter 跨平台客户端（macOS / Windows / Linux / Android / iOS）
- `jar-bridge/` — Kotlin/Ktor 服务，运行 TVBox JAR 插件并暴露苹果 CMS 兼容 API
- 技术栈：Flutter + Riverpod + media_kit / Kotlin + Ktor + Gradle
- 许可：MIT，仅供技术研究学习，使用者自行确保片源合法合规

[v0.4.0]: https://github.com/huangj17/StreamBox-APP/releases/tag/v0.4.0
[v0.3.0]: https://github.com/huangj17/StreamBox-APP/releases/tag/v0.3.0
[v0.2.0]: https://github.com/huangj17/StreamBox-APP/releases/tag/v0.2.0
[v0.1.2]: https://github.com/huangj17/StreamBox-APP/releases/tag/v0.1.2
[v0.1.1]: https://github.com/huangj17/StreamBox-APP/releases/tag/v0.1.1
[v0.1.0]: https://github.com/huangj17/StreamBox-APP/releases/tag/v0.1.0
