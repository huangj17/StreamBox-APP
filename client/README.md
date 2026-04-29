# StreamBox

**Netflix 风格的跨平台流媒体播放器** — 对接 TVBox 生态片源，打造高颜值影视观看体验。

> 厌倦了 TVBox / 影视仓的"古早"界面？StreamBox 把 Netflix 级的视觉体验带到你的电视盒子和电脑上。

> 本目录是 Monorepo 下的 Flutter 客户端子项目。仓库总览见 [../README.md](../README.md)。可选后端服务见 [../jar-bridge/](../jar-bridge/)。

---

## 特性

- **Netflix 风格 UI** — 深色沉浸设计、Hero Banner 轮播、横向分类滑轨、焦点放大动效
- **TVBox 生态兼容** — 直接导入 TVBox JSON 配置源，复用已有片源生态
- **苹果 CMS 对接** — 支持苹果 CMS V1/V3 接口，自动解析分类、视频列表与播放地址
- **JAR 源支持（可选）** — 通过 [JAR Bridge](../jar-bridge/) 加载 TVBox Spider 插件，使用画质更好的 Type 4 片源
- **流畅播放** — 基于 media_kit (libmpv) 引擎，原生支持 m3u8/HLS 视频流
- **跨平台** — Android TV、Windows 桌面、macOS（开发环境）；v2.0 扩展手机端
- **优雅降级** — 每个内容行独立错误处理，单行失败不影响整页浏览（Netflix 降级策略）
- **搜索聚合** — 跨片源关键词搜索，含搜索历史与最近更新
- **观看历史 + 收藏** — Hive 本地持久化，下次打开自动续播
- **分类智能排序** — 用户观看某分类 ≥3 次后自动提权排到前面

## 预览

![首页截图](assets/screenshot.png)

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
│   ├── player/                  # 播放页
│   ├── search/                  # 搜索页
│   ├── source/                  # 配置源管理
│   ├── favorites/               # 收藏
│   ├── history/                 # 历史
│   └── settings/                # 设置（左右分栏）
└── widgets/                     # 全局共享组件（TopNavBar, SkeletonCard, ErrorRail）
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

1. **添加配置源** — "源管理"页面粘贴 TVBox JSON 配置源 URL 并保存
2. **（可选）启用 JAR 源** — 启动 [JAR Bridge](../jar-bridge/) 服务后，添加源 `http://localhost:9978`
3. **浏览内容** — 返回首页，自动加载分类、Banner 与视频列表
4. **搜索影片** — 顶栏搜索框跨源查找
5. **观看影片** — 视频卡片 → 详情页 → 选集播放，自动记录进度

## 路线图

- [x] **Phase 1** — 基础设施：设计 Token、路由、网络层、数据模型
- [x] **Phase 2** — 首页 UI：Hero Banner、分类滑轨、视频卡片
- [x] **Phase 3** — 详情页 + 播放页 + 搜索页
- [x] **Phase 4** — 配置源管理
- [x] **Phase 5** — 收藏、历史、设置面板
- [x] **Phase 6.2** — 性能优化（骨架屏、错误降级、分类智能排序）
- [ ] **Phase 6.1** — 直播源支持（m3u / IPTV）
- [ ] **Phase 7** — TV 焦点导航系统打磨
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
