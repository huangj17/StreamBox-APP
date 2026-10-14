# GitHub → Gitee 代码与 APK 同步

GitHub 为主仓库，Gitee 目标为 `huangj17/StreamBox-APP`。

- `main` 的 CI 成功后，同步 GitHub 的所有分支与标签。
- Release 的 Android 任务成功上传 APK 后，同步代码，并把该版本的
  APK、标题、说明、预发布标记发布到 Gitee Release。桌面构建失败不影响此步骤。
- 手动补构建已有 tag 的 Android APK，也会触发同步。
- APK 直接复制 GitHub 已构建的文件，不重新打包或签名。
- 附件通过 Ubuntu runner 自带的 curl 流式上传；连接超时 30 秒，总时限 10 分钟，
  连续 60 秒低于 1 KB/s 时中止并报告错误。令牌通过标准输入传入，不写入文件或命令参数。

## 首次设置

1. 在 Gitee 创建 `huangj17/StreamBox-APP`。建议使用空仓库，不初始化 README、License
   或 `.gitignore`；已从 GitHub 导入且历史一致的仓库也可以使用。根据需要设置公开/私有。
2. 在 Gitee「设置 → 私人令牌」创建专用令牌，勾选 `projects` 权限。
   令牌所属账号需要有该仓库的代码推送和 Release 管理权限。
3. 打开 GitHub 仓库的 **Settings → Secrets and variables → Actions → Secrets →
   New repository secret**，名称填 `GITEE_TOKEN`，值填刚创建的 Gitee 私人令牌。
   不要把令牌发到聊天、提交到代码或写入仓库 URL。
4. 将本次流程配置和脚本合并到 GitHub 默认分支后，在 **Actions → Sync to Gitee →
   Run workflow** 运行一次。`tag` 留空只同步代码；填已有版本（例如 `v0.4.0`）则同时
   复制该 GitHub Release 的所有 APK，无需重新构建。
5. 在 Gitee 检查分支、标签和对应 Release，下载 APK 验证。

GitHub 设置入口：
https://github.com/huangj17/StreamBox-APP/settings/secrets/actions

Gitee 私人令牌入口：
https://gitee.com/profile/personal_access_tokens

缺少 `GITEE_TOKEN` 时会输出提示并跳过同步，原有 GitHub 构建与发布仍可使用。
Android 原有发布签名 Secrets 仍须完整配置，参见 CONTRIBUTING.md。

## 同步范围与重试

- 同步所有普通分支和标签，不同步 GitHub PR 内部 refs、Issues、PR、Secrets 或 Git LFS 对象。
- 不强制覆盖分叉历史，也不删除 Gitee 独有分支和标签。建议只在 GitHub 修改代码；如 Gitee
  有独立初始提交或保护规则阻止推送，需先处理目标仓库历史/权限，再重试。
- 不同步桌面安装包；只复制 `.apk`。Gitee 同名 APK 会先删除再上传，其他附件保留。
  若中途失败，可用相同 tag 手动重跑，补齐 APK。
- 不复制 `update.json` 或修改应用内升级源；此次配置仅增加 Gitee 的 APK 下载入口。
- 令牌过期、API 配额或附件上传限制导致失败时，GitHub Release 中的 APK 保留。
  处理原因后手动运行 Sync to Gitee，即可补同步，无需重新构建 APK。
- 若更换目标仓库或令牌所属用户，修改 `.github/workflows/gitee-sync.yml` 中的
  `GITEE_REPOSITORY`、`GITEE_USERNAME`，并更新 Secret。

API 参数依据 Gitee 官方定义：https://gitee.com/api/v5/swagger
