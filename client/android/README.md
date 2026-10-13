# Android 本机 Spider 宿主

StreamBox 全平台保留 CMS；`csp_` JAR/DEX 站点只在 Android TV / Android 手机显示和使用。
无需 JVM Bridge、远程插件服务器或 DEX 转 JVM class。

## 数据与播放路径

Flutter 的 `CmsApi` 保持分类、列表、详情、搜索和播放接口，在 JAR 站点上调用
`com.streambox/spider` 原生通道。通道连接同一 APK 内、不可导出的 `:spider` Service。
该进程运行 `DexClassLoader`、真实 Android Context、插件及所需 JNI。
数据响应通过私有临时文件返回，避免超过 Binder 消息限制。

每个站点独立实例与串行调用队列；相同类名配不同 `ext` 不会合并。站点身份取配置 URL
和原始站点 key，运行指纹另包含完整配置。插件按需下载和初始化，不在导入时启动全部站点。
宿主支持包级 `Init.init`、经典 Spider 数据接口、旧 `SpiderApi` 回调和 `Proxy.proxy` / `Init.proxyInvoke`。
初始化传入当前进程真实的 Application，兼容插件的类型转换和生命周期回调注册。

每个 JAR 剧集，包括 HTTP 形式的 ID，都先调用 `playerContent`。宿主可使用声明的 JSON
解析接口或屏幕外 WebView 取得媒体 URL，并把必要请求头交给现有播放器。WebView 不进入
TV 焦点树；关闭解析时释放资源。

本地代理只监听 `127.0.0.1` 的动态端口，使用随机 token 和独立站点路径；仅用于媒体和
插件代理回调，不提供远程分类、搜索或配置 API。播放器只授权当前原生宿主发出的代理地址。
代理透传流、响应头和 Range 请求参数，重写 HLS 中旧本地端口和相对分片地址；
插件自身仍需实现对应媒体代理逻辑。

## 配置与兼容范围

- 支持含注释和尾逗号的 TVBox JSON、单仓和多仓。
- 支持全局 `spider`、单站点 `jar`、`;md5;` 声明和字符串/对象/数组 `ext`。
- 解析相对插件、脚本和外部参数路径；完整保存其他站点配置与解析规则。
- 包必须包含 `classes.dex`；不运行仅含 JVM class 的 JAR。
- 原生库按当前进程 ARM ABI 选择；包内缺少相应 ABI 或新版 Android 不兼容时明确报错。
- 宿主提供 OkHttp、Gson 和公开 QuickJS API。依赖其他 App 的私有类、被混淆过的旧版
  QuickJS 接口、指定签名/包名或其他私有宿主组件的插件，不保证兼容。
- 尚未接入独立 JS/Python 站点运行时，也未实现第三方配置中心、App 商店等自定义界面。
- 网盘登录等额外授权、网站有效性和媒体可用性由具体源决定；能加载插件不代表所有线路可播。

插件缓存在应用私有代码目录，校验声明 MD5 后原子替换，加载文件按 Android 动态代码要求
设为只读。JNI 崩溃隔离在插件进程；调用或初始化超时后重启宿主，Flutter 界面保持可返回。
独立进程用于故障隔离，与主应用共享 UID，并非权限沙箱。

## 迁移

客户端过滤旧 Bridge 官方记录和缓存 Gateway 元数据，清理旧 9978 Bridge 订阅及选择记录。
普通 CMS 和 TVBox 配置保留，非 Android 隐藏 JAR 时不删除其缓存或偏好。历史/收藏数据
不会清空；旧远程插件的记录不自动映射为另一份原始配置中的站点。

## 检查

在 `client/` 中执行：

```bash
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
./android/gradlew -p android :app:testDebugUnitTest
```

受控 DEX 验收在 ARM Android 设备或模拟器中执行，不依赖第三方片源：

```bash
cd android
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest -Ptarget-platform=android-arm64
adb install -r ../build/app/outputs/apk/debug/app-debug.apk
adb install -r ../build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w com.streambox.streambox.test/com.streambox.streambox.spider.HostInstrumentation
```

该验收覆盖真实 DEX 加载、独立参数、数据和播放解析、缓存淘汰后继续代理、Range、
HLS 地址重写、无效 token 和 MD5 拒绝，以及私有进程通信；不证明第三方线路或视频解码可用。

TV 验收应在 ARM Android TV 真机上检查导入、选源、分类、搜索、详情、播放、换集、
解析超时重试和返回后的焦点恢复。桌面或手机模拟器验证不能替代 TV 真机验收。
