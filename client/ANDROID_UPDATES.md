# Android APK 在线升级

Android TV 和 Android 手机在启动时后台检查版本，只更新「设置 → 关于 → 软件更新」的状态，
不自动下载、安装或弹窗打断播放。确认软件更新后，可以查看版本、安装包大小和更新说明，
选择下载、取消、重试或稍后安装。macOS、Windows 和 iOS 隐藏此入口。

## 遥控器操作

- 设置侧栏选择「关于」，按右键进入内容，软件更新是第一个操作入口。
- 确认键打开更新窗口，初始焦点在下载或检查按钮；左右键切换主操作和「稍后」。
- 上键进入更新说明，上下键滚动；滚动到底部再按下键返回主操作。
- 下载时主操作变为「取消下载」，进度更新不会移走焦点。返回键也能取消并关闭窗口。
- 下载完成后手动确认「安装更新」。首次安装可能需要允许 StreamBox 安装未知应用；
  在系统设置中授权并返回后继续刚才请求的安装。拒绝或取消授权仍可返回、稍后或再次授权。
- 系统安装取消后保留已校验的安装包，焦点返回「安装更新」。关闭更新窗口后恢复软件更新入口焦点。
- 手机窄屏采用上下排列的操作按钮，也支持触摸。

系统安装器和授权页由电视 ROM 提供，应用内完整遥控路径不等于各品牌系统页面已经实测。

## 发布

1. 修改 `client/pubspec.yaml` 中的版本，例如 `0.4.1+5`。`+` 后是 Android `versionCode`，
   每次发布都必须递增；标签名为 `v0.4.1`，须与 APK 的 `versionName` 一致。
2. 沿用仓库现有的 Android Release keystore 和签名 secrets，保持应用 ID
   `com.streambox.streambox` 和证书不变。Debug 签名安装不能被 Release 签名直接覆盖。
3. 推送版本标签，Release workflow 构建并验证签名，从实际 APK 读取包名、版本和最低 Android 版本，
   计算大小及 SHA-256，将 Release 说明写入 `update.json`。
4. 工作流先上传 `StreamBox-v0.4.1-android.apk`，再上传 `update.json`。
   默认客户端读取最新正式 Release 的清单；清单中的 APK 地址始终指向明确的版本标签。

默认检查入口：

```text
https://github.com/huangj17/StreamBox-APP/releases/latest/download/update.json
```

仓库尚未发布包含清单的版本时，手动检查会显示「暂未发布更新信息」，仍可正常使用和返回。
Prerelease 不作为默认最新正式版本推送。

每个清单包含：

| 字段 | 含义 |
| --- | --- |
| `schemaVersion` | 当前为 `1` |
| `packageName` | 应用 ID |
| `versionName` / `versionCode` | APK 实际版本 |
| `minSdk` | 最低 Android API 级别 |
| `downloadUrl` | 该版本的 HTTPS APK 地址 |
| `size` / `sha256` | APK 字节数及 SHA-256 |
| `certificateSha256` | Release 签名证书 SHA-256 |
| `releaseNotes` / `publishedAt` | 更新说明和清单生成时间 |

## 自有服务器或镜像

在 GitHub Repository variables 设置 `STREAMBOX_UPDATE_URL` 为自有 HTTPS 清单地址，
Release 构建会将该地址写入客户端。工作流仍将 APK 和清单上传到 GitHub；维护者需要把生成的
`update.json` 同步到镜像。如同时镜像 APK，修改清单的 `downloadUrl`，保持大小、哈希和签名字段一致。

本地构建也可以指定地址：

```bash
flutter build apk --release --dart-define=STREAMBOX_UPDATE_URL=https://updates.example.com/streambox/update.json
```

升级清单、APK 以及每一跳重定向都要求 HTTPS。APK 最大 512 MiB，下载采用流式写入私有缓存，
不要求共享存储权限；取消、下载不完整或校验失败会清理本次下载。取消后重新下载，当前不支持断点续传。
原生端在下载完成和提交安装前检查路径、大小、哈希、包名、版本、签名和 CPU 架构，
再交给 `PackageInstaller` 进行系统安装。当前不支持签名轮换、降级或跨平台应用更新。

## 验证

在 `client/` 下执行：

```bash
flutter analyze
flutter test
python3 -m unittest discover -s tool/tests -p 'test_*.py'
flutter build apk --debug --target-platform android-arm64
./android/gradlew -p android :app:testDebugUnitTest --no-daemon
```

发布脚本测试检查 APK 元数据解析、证书、标签与版本匹配以及文件大小和哈希。
Flutter 测试覆盖网络错误、下载取消与重试、损坏包、HTTP 降级重定向、授权恢复和遥控器焦点；
Android JVM 测试覆盖路径逃逸、符号链接、哈希、签名、降级和不支持的 CPU 架构。

TV 实机验收应使用同一发布证书签名的旧版和更高 `versionCode` 的新版，完整检查：
远程下载、未知应用授权、系统安装确认、取消安装后的焦点恢复，以及覆盖安装后历史/收藏保留。
另测离线、存储不足、32 位盒子和各品牌 ROM 的授权入口。没有设备时只能报告自动化测试范围。
