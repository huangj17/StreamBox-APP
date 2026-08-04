# StreamBox Gateway v2.0 Release Notes

## 交付范围

- 通过 HTTP 接入独立 TVBox Source Aggregator，不复制或编译其源码。
- 将 Aggregator CMS、自动 JVM JAR 和手工 JAR 合并为统一 Catalog。
- 候选目录先完成 Secret、制品、init/probe 和快照提交，再原子切换活动目录。
- 支持 current → previous → manual 恢复、请求 Lease、退役宽限和旧 runtime 降级回退。
- StreamBox 客户端通过 `/api/list` Schema 探测任意域名、端口和 HTTPS Gateway。
- 提供双服务 Compose、非 root/只读 Gateway 容器和独立持久卷。

## 验收证据

- Gateway：`./gradlew build --offline` 与全量 85 个测试通过。
- Flutter：`flutter analyze` 无问题；全量 23 个测试通过。
- Compose：使用显式完整 `AGGREGATOR_IMAGE` 引用的 `docker compose config` 校验通过。
- 自动化覆盖：Aggregator 2xx/304/超时/重定向/限额、Schema 归一化、稳定 key、
  Catalog Lease、AES-GCM、current/previous 恢复、同步单飞、CMS dialect、SSRF、JAR
  摘要/ZIP 检查、ClassLoader 代际、Spider init/probe、坏包回退和离线自动 JAR 恢复。

## 安全与运维

- Aggregator、CMS 与 JAR 下载使用共享远程目标策略；图片代理复用同一公网地址判定。
- 每次重定向和实际 DNS 连接均重新校验；跨 origin 的 Aggregator 重定向不携带凭据。
- ext 使用 AES-256-GCM，仅在运行时初始化前解密；快照只保存 `secretRef/extDigest`。
- 管理同步使用恒定时间 Bearer 比较和速率限制；访问日志不记录 query string。
- 管理同步占用单飞 job 后立即返回 `202`，后台执行结果通过 `/sync/status` 查询。
- 自动清理 current/previous 均未引用的 Secret 与 JAR，启动清理遗留 `.part` 文件。

## 已知限制

- 原始 DEX、混合 DEX/JVM、JavaScript、Python、WebView 嗅探和 `parse=1` 不支持。
- DEX 转换属于 v2.1；目录 override/rollback/retry UI 属于 v2.2。
- 上游公开 Compose 使用本地 `build: .`，未提供可确认的官方镜像；README 声称 MIT，
  但 Gitee 仓库元数据未声明许可证且没有独立 `LICENSE` 文件。正式发布或组合分发前，
  部署方必须核实所选源码 tag、镜像来源及实际授权。
- 当前性能验收以自动化并发/引用/去重测试为门槛；生产规模压测应在目标硬件和最终
  Aggregator 固定镜像上复测并记录冷启动、完整同步与 P95 API 延迟。
