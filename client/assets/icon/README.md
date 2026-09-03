# Android / TV 启动图标

AndroidManifest.xml 使用原生 `@drawable/streambox_icon` 和
`@drawable/streambox_banner`。背景统一引用 `streambox_icon_background`（纯黑），
由 Android 绘制完整背景，不能仅把透明 Logo 交给电视桌面自行补色。

- Android 7：80dp 黑底图标，Logo 居中，保留裁切留白。
- Android 8+：adaptive icon，前景留白 22%，黑色背景独立声明。
- TV 横幅：160×90dp（xhdpi 为 320×180px），黑底、Logo 和白色 StreamBox 名称。
- `drawable-nodpi/streambox_logo.png` 是 `assets/icon.png` 的原样副本；更新 Logo 时同步复制。
- 旧版图标复用已有各密度 `mipmap-*/ic_launcher.png` 作为前景，由 XML 叠加黑底；更新 Logo 时同步更新这些前景。
- `streambox_wordmark.xml` 将 StreamBox 字样保存为矢量路径，不依赖电视上的字体。

`flutter_launcher_icons.android` 设为 false，防止运行跨平台图标生成器时
将 Manifest 改回透明的 `@mipmap/ic_launcher`。其他平台继续使用原有生成配置。

验收时在 TV 桌面分别检查方形图标、圆形图标和横幅，使用方向键选中、确认打开、
返回桌面，检查背景、Logo 裁切和焦点。升级后若仍显示旧图标，先重启电视刷新桌面缓存。
厂商桌面在应用图标外额外绘制的选中底色由桌面控制。
