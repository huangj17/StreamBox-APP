# JAR Bridge Service

StreamBox 的可选后端服务，为 Flutter 客户端提供 TVBox JAR（Spider）插件的运行时环境。

JAR 插件原本只能在 Android TVBox 中运行，Bridge 通过模拟 Android 宿主环境让它们在任意平台（macOS/Windows/Linux）的 JVM 上执行，并以苹果 CMS 兼容的 REST API 暴露数据。Flutter 客户端无法直接运行 JVM 字节码，因此需要 Bridge 中转。

> 本目录是 Monorepo 下的 JVM 服务子项目。仓库总览见 [../README.md](../README.md)，客户端见 [../client/](../client/)。

## 架构关系

```
StreamBox (Flutter)  --HTTP-->  JAR Bridge (JVM)  --反射-->  Spider 实例
                                    |                            |
                                    v                            v
                              plugins/*.jar               内容站点抓取
```

- 客户端把 Bridge 当作一个普通的苹果 CMS 源（`http://<host>:9978`）
- 每个 JAR 插件暴露为独立 API 路径（`/api/{key}`）
- 苹果 CMS 兼容：`ac=class` / `ac=detail` / `wd=` 等参数透传
- Bridge 是可选组件，StreamBox 不连 Bridge 也能用普通 CMS 源

## 快速开始

### 环境要求

- JDK 21+

### 运行

```bash
# 1. 放入 JAR 插件（DEX 格式需先用 dex2jar 转标准 class，详见下文）
cp your_spider.jar plugins/

# 2. 编辑 config.yml，添加插件配置
vim config.yml

# 3. 启动
./gradlew run

# 服务监听 http://0.0.0.0:9978
# Swagger 文档 http://localhost:9978/swagger
```

### 常用命令

```bash
./gradlew build                     # 构建
./gradlew run                       # 启动服务（默认 0.0.0.0:9978）
./gradlew test                      # 运行测试
./gradlew shadowJar                 # 构建 fat JAR（含所有依赖）
java -jar build/libs/jar-bridge-all.jar  # 从打包的 JAR 启动
```

### Docker 运行

```bash
docker compose up -d
```

镜像基于 `eclipse-temurin:21-jre`，默认堆 256m。`plugins/`、`config.yml`、`data/` 通过 volume 挂载，便于热更新插件。

## 配置说明

`config.yml` 示例：

```yaml
server:
  port: 9978
  host: "0.0.0.0"

timeout: 15000        # Spider 方法调用超时（ms），慢站点可调大
logLevel: INFO

plugins:
  - key: "my_source"                    # 唯一标识，对应 API 路径 /api/my_source
    name: "我的源"                       # 显示名称（StreamBox /api/list 会展示）
    jar: "plugins/spider.jar"           # JAR 文件路径
    class: "com.example.MySpider"       # 入口类全限定名
    ext: ""                             # 传给 init() 的扩展参数（字符串或 JSON）
    hidden: false                       # 可选，true 时不出现在 /api/list（手动添加）
```

`hidden: true` 用于不希望客户端自动发现的源（仍可手动把 `http://<bridge>:9978/api/{key}` 当 CMS 源添加）。

## API 端点

| 端点                                  | 说明                                |
| ------------------------------------- | ----------------------------------- |
| `GET /health`                         | 健康检查（服务状态 + 各插件状态）   |
| `GET /api/list`                       | 列出所有已加载插件（不含 hidden）   |
| `GET /api/{key}?ac=class`             | 分类列表                            |
| `GET /api/{key}?t={tid}&pg={n}`       | 分类视频列表                        |
| `GET /api/{key}?ac=detail&ids={id}`   | 视频详情（含播放地址）              |
| `GET /api/{key}?wd={keyword}`         | 搜索                                |
| `GET /api/{key}/play?flag=xx&id=yy`   | 播放地址二次解析                    |
| `GET /swagger`                        | Swagger UI                          |

所有 `/api/{key}` 端点与苹果 CMS 接口格式兼容，StreamBox 把 Bridge 当作普通 CMS 源使用。

## DEX 转换

大多数 TVBox Spider JAR 内部是 Android DEX 格式（`classes.dex`），无法直接被 `URLClassLoader` 加载，必须转换为标准 JVM class：

```bash
# 安装 dex2jar
# macOS: 从 https://github.com/pxb1988/dex2jar/releases 下载，解压后加入 PATH

# 转换（--force 跳过校验失败的类）
d2j-dex2jar.sh original.jar -o converted.jar --force

# 放入 plugins/
cp converted.jar plugins/
```

判断 JAR 是否为 DEX 格式：`unzip -l xxx.jar | grep -i dex`。若有 `classes.dex` 即需转换。

## 项目结构

```
src/main/kotlin/com/streambox/bridge/
├── Application.kt          # Ktor 入口 + CallLogging + Swagger
├── config/BridgeConfig.kt  # YAML 配置解析（SnakeYAML）
├── spider/
│   ├── SpiderManager.kt    # JAR 加载 / ClassLoader 管理 / 实例缓存
│   ├── SpiderWrapper.kt    # 单 Spider 封装（单线程 Executor + 超时）
│   └── SpiderTimeoutException.kt
├── host/
│   ├── MockContext.kt      # Android Context 模拟
│   └── MockSharedPreferences.kt
└── api/Routes.kt           # Ktor 路由（7 端点 + JSON 校验）

src/main/java/                       # Android 宿主 Mock（用 Java 保留原始包名）
├── android/content/Context.java
├── android/util/Base64.java         # → java.util.Base64
├── android/util/Log.java            # → SLF4J
├── android/text/TextUtils.java
└── com/github/catvod/crawler/Spider.java
```

架构与关键设计决策详见 [CLAUDE.md](CLAUDE.md)。

## 关键设计决策

- **反射调用而非接口强制** — 部分 JAR 实现 TVBox 原版 Spider 而非 Bridge 接口，反射更灵活
- **每 Spider 单线程 Executor** — 多数插件非线程安全，串行化避免并发 bug
- **catch Throwable 非 Exception** — `NoClassDefFoundError` 是 Error，加载失败不能崩溃整服务
- **MockContext 必须继承 `android.content.Context`** — Spider 基类的 init 方法签名是 `init(Context, String)`
- **Java 实现 Mock 而非 Kotlin** — 需保留原始 Android 包名，Java 编译输出更可控

## 故障排查

| 现象                                         | 可能原因                                       |
| -------------------------------------------- | ---------------------------------------------- |
| 启动时 `NoClassDefFoundError: android.xxx`   | Mock 缺失，需在 `src/main/java/android/` 下补  |
| `dex2jar` 转换后类反射失败                   | 加 `--force`，部分类校验错误可跳过             |
| Spider 调用超时                              | 调大 `config.yml` 的 `timeout`，或检查源站连通 |
| `/api/list` 看不到某插件                     | 确认 `hidden: false`，且配置语法无误           |
| 健康检查 `status: error`                     | 看 `data/` 下日志，多为 init 阶段抛异常         |

## 技术栈

| 层次       | 选型                                  |
| ---------- | ------------------------------------- |
| 语言       | Kotlin (JVM 21)                       |
| Web 框架   | Ktor 3.2                              |
| 构建       | Gradle (Kotlin DSL) + Shadow plugin   |
| JSON       | kotlinx.serialization + org.json      |
| YAML       | SnakeYAML                             |
| 日志       | SLF4J + Logback                       |

## 设计参考

- [CLAUDE.md](CLAUDE.md) — 架构与设计决策（给 Claude Code 用）

## 许可证

本项目仅供个人学习和研究使用。
