# StreamBox

**Netflix 风格的跨平台流媒体播放器** — 对接 TVBox 生态片源，以电视遥控器操作为优先，同时适配桌面键鼠与手机触摸。

> 本目录是 Monorepo 下的 Flutter 客户端子项目。仓库总览见 [../README.md](../README.md)。可选后端服务见 [../jar-bridge/](../jar-bridge/)。

---

## 特性

- **Netflix 风格 UI** — 深色沉浸设计、Hero Banner 轮播、横向分类滑轨、焦点放大动效
- **TVBox 生态兼容** — 直接导入 TVBox JSON 配置源，复用已有片源生态
- **苹果 CMS 对接** — 支持苹果 CMS V1/V3 接口，自动解析分类、视频列表与播放地址
- **JAR 源支持（可选）** — 通过 [JAR Bridge](../jar-bridge/) 加载 TVBox Spider 插件，使用画质更好的 Type 4 片源
- **流畅播放** — 基于 media_kit (libmpv) 引擎，原生支持 m3u8/HLS 视频流
- **TV 优先的跨端交互** — Android TV、Windows 桌面、macOS（开发环境）；搜索、设置和播放页已包含窄屏与触摸布局，手机端持续完善
- **优雅降级** — 每个内容行独立错误处理，单行失败不影响整页浏览（Netflix 降级策略）
- **搜索聚合** — 左侧搜索与历史、右侧加宽海报网格，结果逐批展示并标注片源；确认后输入，历史集中管理
- **遥控播放** — 底部时间轴与操作栏、右侧选集和设置面板；左右键松手自动跳转，关闭面板恢复焦点
- **片源管理** — 官方片源与自定义集合分组，首页片源和搜索启用状态分别管理，支持同步与健康检测
- **观看历史 + 收藏** — Hive 本地持久化，下次打开自动续播
- **分类智能排序** — 用户观看某分类 ≥3 次后自动提权排到前面

## 预览

2026-09-03 的 macOS 实际运行截图，展示当前宽屏布局；不代表已完成 TV 实机验收。

![首页：侧边导航、轮播推荐与继续观看](assets/screenshots/home.jpg)

| 搜索：加宽卡片与来源信息 | 设置：片源管理 |
| --- | --- |
| ![搜索结果页面](assets/screenshots/search.jpg) | ![片源管理页面](assets/screenshots/sources.jpg) |
| 播放：底部控制栏 | 播放：设置侧栏 |
| ![播放控制页面](assets/screenshots/player.jpg) | ![播放设置侧栏](assets/screenshots/player-settings.jpg) |

[截图说明](assets/screenshots/README.md)。下方视频保留早期版本的操作演示，当前界面以上方截图为准。

<video src="https://github.com/huangj17/StreamBox-APP/raw/main/client/assets/StreamBox.mp4" controls width="720"></video>

> 视频如未在 GitHub 网页内联播放，可点击 [此处下载查看](assets/StreamBox.mp4)。

## 技术栈

| 领域       | 技术方案                              |
| ---------- | ------------------------------------- |
| 框架       | Flutter 3.11+ / Dart 3.11+            |
| 状态管理   | Riverpod (flutter_riverpod)           |
| 网络请求   | Dio（含重试拦截器，8s 超时）          |
| 视频播放   | media_kit + media_kit_video (libmpv)  |
| 本地存储   | Hive（轻量 KV，无原生配置）           |
| 路由       | go_router（统一 SlideTransition 转场）|
| 图片缓存   | cached_network_image                  |

## 项目结构

```
lib/
├── core/                        # 基础设施
│   ├── network/                 # Dio 客户端 + 重试拦截器
│   ├── theme/                   # 设计 Token（颜色/字体/间距/圆角）
│   ├── router/                  # go_router 路由配置
│   └── platform/                # 平台抽象层（TV / Desktop / Mobile）
├── data/
│   ├── models/                  # Site, VideoItem, Category, WatchHistory, FavoriteItem...
│   ├── sources/                 # CmsApi 客户端 + SourceParser（TVBox 配置解析）
│   ├── repositories/            # 数据组装层（HomeRepository）
│   └── local/                   # Hive 存储（History, Favorite, Source, Settings, SearchHistory）
├── features/
│   ├── home/                    # 首页 + 分类详情页
│   ├── detail/                  # 详情页
│   ├── player/                  # 播放页、控制栏、侧栏与播放引擎
│   ├── search/                  # 搜索页、输入/历史弹窗、结果网格
│   ├── source/                  # 配置源管理
│   ├── favorites/               # 收藏
│   ├── history/                 # 历史
│   └── settings/                # 设置（左右分栏）
└── widgets/                     # 全局共享组件（SideNavBar, TvFocusable, TvActionButton 等）
```

架构与设计决策详见 [CLAUDE.md](CLAUDE.md)。

## 快速开始

### 环境要求

- Flutter SDK >= 3.11
- Dart SDK >= 3.11
- macOS 开发需 CocoaPods（若 `pod` 不可用：`/opt/homebrew/opt/ruby/bin/gem install ffi`）

### 安装与运行

```bash
flutter pub get

# macOS 开发
flutter run -d macos

# Windows
flutter run -d windows

# Android TV / Android 真机
flutter run -d <device-id>
```

> **Android Emulator 黑屏非 bug**：libmpv 软件渲染与 Emulator EGL 不兼容（音频和进度正常）。验证 Android 播放请用真机，调播放页 UI 用 macOS 即可。

### 常用命令

```bash
flutter analyze                     # 静态分析 / lint
flutter test                        # 全部测试
flutter test test/widget_test.dart  # 单个测试文件
flutter build apk                   # Android APK
flutter build windows               # Windows 可执行文件
flutter build macos                 # macOS .app
```

## 使用方法

1. **管理配置源** — 设置 → 配置源管理。官方片源后台同步；「添加配置源」支持 CMS 接口、TVBox 单仓/多仓或 OuonnkiTV JSON 列表 URL。选择分组后确认片源行，打开该片源的操作弹窗；相同接口自动去重，异常源可重新检测。
2. **原生产片源与本机 JAR 源** — 官方合并配置发布后，「荐片视频、爱看机器人、异世界动漫」与其他 CMS 源显示在同一个官方列表，可直接选择首页、启停或搜索；无需另加分组。自建时启动 [JAR Bridge](../jar-bridge/) 后，添加 `http://localhost:9978`。
3. **选择首页内容** — 在片源操作弹窗选择「设为首页片源」。首页只加载所选片源的分类、Banner 与视频列表，顶部已移除切源栏。
4. **搜索影片** — 确认关键词入口后输入片名，也可直接选择最近搜索。汇总所有已启用且未检测失败的片源，结果随返回随展示，卡片标明来源；切换首页片源不改变搜索范围。「管理」可删除或清空搜索历史。
5. **观看影片** — 视频卡片 → 详情页 → 选集播放。底部显示片名、集数、片源与线路，自动记录进度；从「选集」「线路」「设置」打开对应侧栏。

健康检测同时运行最多 6 个片源，单个完成后立即检测下一个，无需等待同批慢源。每个片源最多检测 12 秒，超时会取消请求并支持重试；排队显示「等待检测」，实际请求中显示「检测中」，结果逐项更新。重复触发会复用正在进行的检测。

片源集合在启动时后台更新，也可手动点击「更新」。更新失败时保留上次成功加载的列表；首页选择和启用状态会保存在本机。

原生产源地址及发布步骤见 [恢复原生产片源](../README.md#恢复原生产片源)。升级客户端后同步合并配置，保留原首页、启用偏好和历史身份；异世界动漫的字符串影片 ID 不再被转换为 0。该源抽样播放仍需网页解析，播放器会提示，不能据分类或搜索成功认定可播放。

### 遥控器操作

| 页面 / 位置 | 操作 |
| --- | --- |
| 搜索入口 | 按确认打开输入弹窗；关闭后回到原控件，不会进页就弹出输入法 |
| 搜索结果 | 方向键按行列移动并自动滚动；首列按左返回搜索区，首行按上回到关键词入口 |
| 搜索返回 | 搜索结果中按返回先回到最近更新，再按返回退出搜索；从详情返回保留原卡片焦点 |
| 设置 | 分类中按确认或右键进入内容区；返回先回分类导航，再退出设置 |
| 播放控制栏 | 左右选择操作，上键进入时间轴；隐藏时按确认或上下唤起控件 |
| 调整播放进度 | 时间轴上按左右键预览，长按加速，**松开方向键自动跳转**；返回或离开时间轴取消尚未提交的预览 |
| 选集 / 线路 / 设置侧栏 | 上下选择、确认应用；返回关闭当前层并恢复焦点 |
| 退出播放 | 确认左上角「退出播放」直接返回；返回键依次关闭面板或取消预览、收起控制栏、退出播放 |

正常播放时控制栏闲置 5 秒后收起；暂停、缓冲、预览进度和打开侧栏时保持可见。桌面全屏下，收起控制栏后按返回会先退出全屏。手机可拖动时间轴，松手跳转。

### 布局与验证范围

搜索页在宽屏上保留左侧操作区，结果按可用宽度排列为 2–6 列；先为卡片和间距留足空间，再增加列数。手机竖屏保持双列，搜索与历史移至顶部。播放侧栏在窄屏铺满宽度，底部按钮随焦点或触摸横向滚动。

搜索、设置和播放交互已有 Flutter 按键与响应式布局测试，并在 macOS 上复核页面。Android TV 实机仍需验证遥控器长按频率、系统中文输入法、返回键顺序、远距离可读性与屏幕安全留白。

## 路线图

- [x] **Phase 1** — 基础设施：设计 Token、路由、网络层、数据模型
- [x] **Phase 2** — 首页 UI：Hero Banner、分类滑轨、视频卡片
- [x] **Phase 3** — 详情页 + 播放页 + 搜索页
- [x] **Phase 4** — 配置源管理
- [x] **Phase 5** — 收藏、历史、设置面板
- [x] **Phase 6.2** — 性能优化（骨架屏、错误降级、分类智能排序）
- [ ] **Phase 6.1** — 直播源支持（m3u / IPTV）
- [ ] **Phase 7** — 搜索、设置与播放页焦点导航已更新，继续完成 TV 实机验收与打磨
- [ ] **v2.0** — Android / iOS 手机端适配

## 配置源格式

兼容 TVBox 生态 JSON 格式：

```json
{
  "sites": [
    {
      "key": "site_key",
      "name": "站点名称",
      "type": 1,
      "api": "https://example.com/api.php/provide/vod/",
      "searchable": 1
    }
  ]
}
```

支持的接口类型：

| Type   | 格式               | 备注                          |
| ------ | ------------------ | ----------------------------- |
| Type 1 | 苹果 CMS V1（XML） |                               |
| Type 3 | 苹果 CMS V3（JSON）| 推荐                          |
| Type 4 | JAR (Spider)       | 通过 JAR Bridge 转 CMS 暴露   |

苹果 CMS API 速查：

```
GET {api}?ac=class                  → 分类列表
GET {api}?ac=detail&t={id}&pg={n}   → 分类视频列表
GET {api}?ac=detail&ids={id}        → 视频详情（含播放地址）
GET {api}?wd={keyword}              → 搜索
```

播放地址格式：`名称$url#名称$url$$$名称$url#名称$url` — `$$$` 分隔不同播放源，`#` 分隔集数，第一个 `$` 分隔集名和播放地址。

## 设计参考

- [CLAUDE.md](CLAUDE.md) — 架构、关键设计决策、生命周期注意事项（给 Claude Code 用）

## 许可证

本项目仅供个人学习和研究使用。

## 致谢

- [TVBox](https://github.com/CatVod/CatVod) — 片源生态
- [media_kit](https://github.com/media-kit/media-kit) — 跨平台视频播放引擎
- [Netflix](https://www.netflix.com) — UI 设计灵感
