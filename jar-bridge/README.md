# StreamBox Gateway（JAR Bridge）

StreamBox 的可选后端服务。它在 JVM 中加载本地配置的 TVBox Spider JAR，并以苹果 CMS
兼容 REST API 提供给 Flutter 客户端。Gateway 属于 StreamBox 本仓库，不依赖外部配置
聚合服务，也不会自动提供或下载片源。

> JAR 插件本身才包含具体站点的抓取逻辑。启动 Gateway 前，需要自行准备来源可信、
> 与当前 JVM 宿主兼容的插件。

## 架构

```text
StreamBox (Flutter) --HTTP--> Gateway (JVM) --Spider--> 内容站点
                              |
                              └── plugins/*.jar + config.yml
```

- 客户端默认通过 `GET /api/list` 发现公开的 JAR 片源。
- 每个插件使用独立路径 `/api/{key}`，响应格式兼容苹果 CMS。
- Gateway 是可选组件；普通 CMS 源可以由客户端直接连接。

## 本地运行

环境要求：JDK 21+。

```bash
# 1. 把已转换为标准 JVM class 的 Spider JAR 放入 plugins/
cp your_spider.jar plugins/

# 2. 计算 JAR 哈希，并在 config.yml 中添加路径、入口类和 sha256
shasum -a 256 plugins/your_spider.jar

# 3. 启动
./gradlew run
```

默认只监听 `http://127.0.0.1:9978`。API 文档默认关闭，需要时设置
`server.enableDocs: true` 后访问 `http://127.0.0.1:9978/swagger`。

常用命令：

```bash
./gradlew test
./gradlew build
./gradlew run
./gradlew fatJar
java -jar build/libs/jar-bridge-all.jar
```

## Docker 运行

```bash
docker compose up -d --build
curl -fsS http://localhost:9978/health
curl -fsS http://localhost:9978/api/list
```

Compose 只把端口发布到宿主机 `127.0.0.1`，并只读挂载 `config.yml` 与 `plugins/`。
运行镜像使用无 shell 的 distroless JRE、非 root 用户和只读根文件系统，仅 `data` 卷
和 `/tmp` 可写。

> Spider JAR 是可执行代码，`URLClassLoader` 不是安全沙箱。生产环境应使用 Docker
> 作为最小隔离边界；不同来源、不同信任等级的 JAR 应拆到不同 Gateway 容器，并在
> 宿主机防火墙中限制容器出站目标。不要用 `./gradlew run` 执行不可信 JAR。

## 配置

```yaml
server:
  port: 9978
  host: "127.0.0.1"
  publicBaseUrl: "http://127.0.0.1:9978"
  enableDocs: false

timeout: 15000
logLevel: INFO

catalog:
  retirementGraceMs: 30000

security:
  allowedPrivateHosts: []
  allowedPrivateCidrs: []
  requireAuth: false
  rateLimitPerMinute: 120
  rateLimitBurst: 30
  maxConcurrentRequests: 32
  maxResponseBytes: 10485760
  maxQueryLength: 4096

plugins:
  - key: "my_source"
    name: "我的源"
    jar: "plugins/spider.jar"
    sha256: "将 shasum -a 256 的结果填在这里"
    class: "com.example.MySpider"
    ext: ""
    hidden: false
```

- `key` 必须唯一，并成为 `/api/{key}` 中的路径参数。
- `jar` 是相对于 `jar-bridge/` 运行目录的本地文件路径。
- `class` 是 Spider 入口类全限定名。
- `sha256` 是必填的 64 位小写 SHA-256；文件被替换后 Gateway 会拒绝加载。
- `ext` 会原样传给插件的 `init()`。
- `hidden: true` 的插件仍可调用，但不会出现在 `/api/list`。
- `timeout` 是单次 Spider 方法调用的毫秒超时。
- `publicBaseUrl` 是 Gateway 写入代理链接的可信公开 Origin，不读取请求的 Host 头。
- `requireAuth: true` 时必须通过环境变量 `BRIDGE_API_TOKEN` 提供至少 32 字符的 Token。
- 远程部署必须使用 HTTPS 反向代理、开启认证，并限制来源 IP；不要直接发布 9978。

远程认证示例：

```bash
export BRIDGE_REQUIRE_AUTH=true
export BRIDGE_API_TOKEN='至少-32-字符-的-随机-token-请自行替换'
export BRIDGE_PUBLIC_BASE_URL='https://gateway.example.com'
./gradlew run

curl -H "Authorization: Bearer $BRIDGE_API_TOKEN" \
  https://gateway.example.com/api/list
```

Flutter 客户端通过 `--dart-define` 注入同一个 Token，不把密钥放进源 URL：

```bash
flutter run -d macos \
  --dart-define=STREAMBOX_GATEWAY_TOKEN='至少-32-字符-的-随机-token-请自行替换'
```

## API

| 端点 | 说明 |
| --- | --- |
| `GET /health` | Gateway、目录与插件健康状态 |
| `GET /health/live` | 不需要认证的最小存活检查 |
| `GET /api/list` | 列出所有公开插件 |
| `GET /api/{key}?ac=class` | 分类列表 |
| `GET /api/{key}?t={tid}&pg={n}` | 分类视频列表 |
| `GET /api/{key}?ac=detail&ids={id}` | 视频详情 |
| `GET /api/{key}?wd={keyword}` | 搜索 |
| `GET /api/{key}/play?flag={flag}&id={id}` | 播放地址二次解析 |
| `GET /swagger` | Swagger UI（默认关闭） |

验证示例：

```bash
curl -fsS http://localhost:9978/health
curl -fsS http://localhost:9978/api/list
curl -fsS 'http://localhost:9978/api/jianpian?ac=class'
curl -fsS 'http://localhost:9978/api/jianpian?wd=流浪地球'
```

只有 `/api/list` 出现 `status: ready`，并且分类或搜索接口返回有效 JSON，才表示插件源
配置成功。Gateway 启动成功不等于插件一定可用。

## DEX 转换

很多 TVBox 插件包内含 Android `classes.dex`，JVM 无法直接加载。可以先检查：

```bash
unzip -l your_spider.jar | grep -i dex
```

若存在 `classes.dex`，需要使用 dex2jar 转换：

```bash
d2j-dex2jar.sh original.jar -o converted.jar --force
cp converted.jar plugins/
```

转换不保证兼容。依赖 Android WebView、原生库、JavaScript/Python 运行时或大量未模拟
Android API 的插件仍可能无法运行。

## 已知限制

- 不自动下载、更新或生成 Spider JAR。
- 不运行原始 DEX 或混合 DEX/JVM JAR。
- 不支持 JavaScript、Python Spider、WebView 嗅探和 `parse=1` 网页解析。
- 插件依赖的 Android API 若未被宿主 Mock，会加载失败。
- CMS `/play` 仅接受 HTTP(S) 直接播放地址。

## 代码结构

```text
src/main/kotlin/com/streambox/bridge/
├── Application.kt          # Ktor 启动与生命周期
├── api/                    # 路由、缓存、图片代理
├── catalog/                # 手工插件目录与请求 Lease
├── cms/                    # CMS 代理能力
├── config/                 # YAML 配置与校验
├── host/                   # Android 宿主模拟
├── security/               # 远程目标安全策略
└── spider/                 # JAR 加载、反射调用与超时控制
```

## 许可证

本项目仅供个人学习和研究使用。
