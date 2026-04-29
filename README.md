# StreamBox

Netflix 风格的跨平台流媒体播放器，对接 TVBox 生态片源。本仓库为 Monorepo，包含 Flutter 客户端和 JAR Bridge 中间服务。

## 仓库结构

| 目录             | 说明                                  | 技术栈                              | README                                         |
| ---------------- | ------------------------------------- | ----------------------------------- | ---------------------------------------------- |
| `client/`        | Flutter 客户端（主应用）              | Flutter/Dart + Riverpod + media_kit | [client/README.md](client/README.md) |
| `jar-bridge/`    | JAR Bridge 中间服务（JAR 插件运行时） | Kotlin + Ktor + Gradle              | [jar-bridge/README.md](jar-bridge/README.md)   |

## 架构关系

```
StreamBox (Flutter)  --HTTP-->  JAR Bridge (JVM)  --Spider-->  内容站点
                                    |
                                    v
                              plugins/ 目录下的 .jar 文件
```

- 客户端通过 HTTP 连接 Bridge，Bridge 对客户端来说就是一个普通的 CMS 源
- 每个 JAR 源的 API 格式与苹果 CMS 完全兼容（`ac=class`、`ac=detail`、`wd=` 等）
- Bridge 是可选组件，StreamBox 在没有 Bridge 时仍可正常使用 CMS 源
- 客户端默认连接 `http://localhost:9978`

## 快速开始

无根级构建工具。命令必须在子项目目录下执行。

### 仅 CMS 源（不需要 JAR 插件）

```bash
cd client
flutter pub get
flutter run -d macos
```

### 含 JAR 源（需要 Bridge）

```bash
# 终端 1：启动 Bridge
cd jar-bridge
./gradlew run                       # 监听 0.0.0.0:9978

# 终端 2：启动客户端
cd client
flutter run -d macos
```

详细配置（添加 JAR 插件、DEX 转换、API 端点等）见 [jar-bridge/README.md](jar-bridge/README.md)。

## 环境要求

| 子项目        | 依赖                                          |
| ------------- | --------------------------------------------- |
| client        | Flutter SDK >= 3.11、Dart SDK >= 3.11、CocoaPods（macOS） |
| jar-bridge    | JDK 21+                                       |

## 许可证

[MIT License](LICENSE)。本项目仅作技术研究与学习用途，使用者需自行确保所接入的内容源合法合规，与本项目作者无关。
