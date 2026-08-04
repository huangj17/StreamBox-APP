# StreamBox Gateway（JAR Bridge v2）

StreamBox 的可选后端服务，为 Flutter 客户端统一提供 Aggregator CMS、自动 JAR 和
手工 JAR（Spider）运行时。Gateway 不包含 Aggregator 源码，二者始终是独立服务。

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
# 必须显式指定经过评审的完整镜像引用；Compose 不接受隐式 latest。
export AGGREGATOR_IMAGE=<registry>/<repository>@sha256:<reviewed-digest>
docker compose up -d --build
```

Compose 会启动两个独立服务：`aggregator:5678` 仅在 Compose 网络内提供配置，
`gateway:9978` 是唯一对宿主机公开的入口。Gateway 使用
[`config.compose.yml`](config.compose.yml) 通过内部 DNS 名访问 Aggregator；两个服务
分别使用 `aggregator-data` 和 `gateway-data` 数据卷。首次启动会在 Gateway 数据卷
生成权限受限的 SecretStore master key，也可以通过 `BRIDGE_SECRET_KEY` 注入 Base64
编码的 32 字节密钥。

Gateway 镜像基于 `eclipse-temurin:21-jre`，以 UID 10001 非 root 用户运行，默认堆
256m。Compose 默认使用只读根文件系统，只允许写入数据卷和 `/tmp`，并移除 Linux
capabilities、禁止提权、限制进程数/内存/CPU。`plugins/` 与配置文件均只读挂载。

Aggregator 管理端口默认不映射到宿主机。如需管理，应在受控部署中临时增加仅绑定
回环地址的端口映射。上游公开 Compose 当前使用 `build: .`，未声明可直接拉取的
官方镜像，因此这里不猜测镜像名。可以在独立目录检出已审核 tag 后自行构建并推送
到受控仓库，再把完整 digest 传给 `AGGREGATOR_IMAGE`。本仓库仅通过 HTTP 黑盒集成，
不复制其源码。

> JAR 插件是可执行代码，`URLClassLoader` 不是安全沙箱。不要在宿主机上用
> `./gradlew run` 加载不可信插件；这类插件必须使用上述加固后的容器运行。
> 容器仍允许外网访问（Spider 抓取所需），因此只应安装来源可信或已审计的 JAR。

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

v2 推荐在 Compose 中使用 [`config.compose.yml`](config.compose.yml)。核心配置：

```yaml
aggregator:
  enabled: true
  baseUrl: "http://aggregator:5678"
  syncInterval: "PT15M"
catalog:
  mode: "hybrid"       # manual | aggregator | hybrid
  snapshotRetention: 2
security:
  secretKeyEnv: "BRIDGE_SECRET_KEY"
  allowedPrivateHosts: ["aggregator"]
admin:
  enabled: false
  tokenEnv: "BRIDGE_ADMIN_TOKEN"
```

- `manual`：完全关闭 Aggregator 同步，是 v1 兼容回退模式。
- `aggregator`：只使用 Aggregator 自动目录。
- `hybrid`：合并两类目录，手工 `plugins` 同 key 时优先，自动条目标记为 shadowed。
- Token 只能通过对应环境变量注入，不写入 YAML、快照或日志。
- 未提供 `BRIDGE_SECRET_KEY` 时，首次启动会生成 `data/secrets/master.key`（0600）。
  必须随数据卷一起备份；密钥丢失后加密 ext 无法恢复。

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
| `GET /sync/status`                    | 脱敏同步状态                        |
| `POST /admin/sync`                    | Bearer 鉴权的手工同步               |

所有 `/api/{key}` 端点与苹果 CMS 接口格式兼容，StreamBox 把 Bridge 当作普通 CMS 源使用。

常用请求：

```bash
curl -fsS http://localhost:9978/api/list
curl -fsS 'http://localhost:9978/api/agg_cms?ac=class'
curl -fsS 'http://localhost:9978/api/agg_cms?ac=detail&ids=123'
curl -fsS http://localhost:9978/sync/status
curl -X POST http://localhost:9978/admin/sync \
  -H "Authorization: Bearer $BRIDGE_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"allowEmpty":false}'
```

## v1 → v2 升级、备份与回退

1. 停止 v1，备份原 `config.yml`、`plugins/` 和 `data/`。
2. 保留现有 `plugins` 配置不变；v2 会先构建手工目录，因此旧配置无需迁移。
3. 按需增加 `aggregator/catalog/artifacts/security/admin`，首次建议先保持
   `catalog.mode: manual` 验证 v1 回归。
4. 启动 v2 后检查 `/health` 和 `/api/list`，再切换到 `hybrid`。
5. 备份时同时保存整个 Gateway 数据卷，特别是 `catalog/`、`artifacts/`、`secrets/`。
   `current.json` 损坏时服务会尝试 `previous.json`；不要只恢复密文而遗漏 master key。

紧急回退只需停止服务，把 `catalog.mode` 改回 `manual` 并重启；这不会删除 v2 快照或
制品。需要回滚二进制时，可用原 v1 镜像挂载原配置和 `plugins/`，保留 v2 数据卷以便
之后重新升级。

## v2.0 已知限制

- 原始 DEX 或混合 DEX/JVM JAR 只会被识别和隔离；v2.0 不自动运行 dex2jar。
- JavaScript、Python Spider、WebView 嗅探和 `parse=1` 网页解析不受支持。
- CMS `/play` 只接受已经是 HTTP(S) 的直接播放地址。
- 自动 JAR 是可执行代码，ClassLoader 不是安全沙箱；生产环境仍须使用容器隔离。
- Aggregator README 声称 MIT，但 Gitee 仓库元数据未声明许可证且根目录没有独立
  `LICENSE` 文件；部署方须在组合分发前向上游核实。Compose 强制显式完整镜像引用，
  本项目不对镜像来源或再分发授权作推定。

常见错误：`REMOTE_TARGET_FORBIDDEN` 表示 SSRF 策略拒绝目标；
`JAR_REQUIRES_CONVERSION` 表示 DEX；`JAR_MD5_MISMATCH` 表示摘要不符；
`SPIDER_INIT_TIMEOUT`/`SPIDER_PROBE_INVALID` 表示运行时未通过激活门槛；
`AGGREGATOR_SCHEMA_INVALID` 不会替换当前有效目录。

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
