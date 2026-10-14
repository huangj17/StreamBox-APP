# 直播订阅远程配置

将本目录的 **`live_sources.json`** 上传到服务器的 `/streambox/live_sources.json`，客户端默认读取：

`http://1.14.171.39/streambox/live_sources.json`

此文件与点播 `sources.json` 独立，上传时不要覆盖点播文件。先安装包含此功能的新客户端；之后修改服务器的直播 JSON 即可更新预置订阅，无需重新打包 App。

## 文件格式

JSON 顶层为数组，已包含 Guovin IPv4、ngo5 IPv4 与 IPv6。Guovin 放在首项，新安装无观看记录时优先使用首个启用订阅。

| 字段 | 说明 |
| --- | --- |
| `id` | 必填，稳定且唯一的英文、数字、下划线或短横线标识，最长 80 字符。改名称或地址时保持不变，以迁移缓存和观看记录。 |
| `name` | 必填，客户端显示名称，最长 100 字符。 |
| `url` | 必填，公开 HTTPS M3U **频道列表**地址，不能填某个频道的 HLS 视频清单。 |
| `isEnabled` | 可选布尔值，默认 `true`；`false` 表示从预置订阅中停用。 |
| `fallbackUrls` | 可选，最多 5 个公开 HTTPS 地址，提供同一份 M3U 的备用下载路径。仅网络连接失败时尝试，不代表频道的备用播放线路。 |

频道名称、分组、台标和各频道的备用播放线路继续由订阅中的 M3U 提供。无需把数百条频道地址手动搬进 JSON。EPG 本阶段不读取。

## 上传与验证

1. 在 `client/` 运行：

   ```bash
   dart run tool/validate_live_sources.dart ../deploy/streambox/live_sources.json
   ```

2. 保留服务器上一版文件，先上传临时文件，再重命名为 `live_sources.json`，避免客户端读到半份 JSON。
3. 确保目标 URL 直接返回完整 UTF-8 JSON，响应 `Content-Type: application/json`；不要返回登录页或 HTML。
4. 检查服务器：

   ```bash
   curl --fail --max-time 15 http://1.14.171.39/streambox/live_sources.json
   ```

5. App → 直播 → 直播设置 → **更新直播配置**。加载后可选择订阅并播放；每份 M3U 的「刷新」只更新频道清单。

2026-10-14 上传后检查：`http://1.14.171.39/streambox/live_sources.json` 返回 200、`application/json` 和 803 字节，内容与本目录文件逐字节一致，通过客户端解析器校验（3 个启用订阅）。原域名 HTTPS 连接失败，域名 HTTP 转向 DNSPod 拦截页，因此经用户确认改用此 HTTP IP 入口。

## 更新行为

- App 启动、进入直播或回到前台时检查配置；前台每 30 分钟自动刷新。更新按钮立即刷新，后台不轮询。
- 下载限制为 256 KiB、最多 200 个订阅，连接/接收超时后继续使用缓存；格式错误整份拒绝，不覆盖成功配置。
- HTTP 例外仅用于构建时指定的直播 JSON 地址；重定向仍限制同一服务器、端口和路径，可升级到同 IP 同路径的有效 HTTPS，升级后不能降级。JSON 内的 M3U 和备用下载地址仍要求公开 HTTPS。HTTP 配置不提供传输完整性保护，条件允许时可重新配置为 HTTPS。
- 首次安装不再生成应用内写死的直播清单，需成功下载该 JSON 或手动添加 M3U；旧版用户保留已有订阅和频道缓存直到成功同步。
- 稳定 `id` 更换 M3U 地址时迁移缓存、选择与观看记录，并立即获取新 M3U；新地址暂不可用时仍可使用迁移的旧频道缓存。有效的 `[]` 明确下架全部预置订阅，自定义订阅保留。
- 本地移除的预置订阅不会因更新被重新加回，可用「恢复预置订阅」恢复；旧版已移除的三份预置订阅偏好也保留。
- 直播设置新增更新状态与可通过遥控器操作的更新按钮，观看时不弹窗。
- 若另用 HTTPS 服务器，在构建时设置 `--dart-define=STREAMBOX_LIVE_SOURCES_URL=https://你的域名/streambox/live_sources.json`。点播配置入口不受影响。
