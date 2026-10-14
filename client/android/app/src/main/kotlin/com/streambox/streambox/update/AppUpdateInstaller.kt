package com.streambox.streambox.update

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.util.concurrent.Executors

/** Installs only a verified replacement of this app, through Android's own UI. */
class AppUpdateInstaller(private val activity: Activity) {
    private val worker = Executors.newSingleThreadExecutor()
    private val root get() = File(activity.cacheDir, "updates")
    private var installResult: MethodChannel.Result? = null
    @Volatile private var sessionId: Int? = null
    private var confirmation: Intent? = null
    private var resumed = false
    @Volatile private var closed = false

    init { active = WeakReference(this) }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceInfo" -> {
                try {
                    val installed = installedIdentity()
                    result.success(mapOf(
                        "packageName" to installed.packageName,
                        "versionName" to installed.versionName,
                        "versionCode" to installed.versionCode,
                        "certificates" to installed.certificates.toList(),
                        "sdkInt" to Build.VERSION.SDK_INT,
                        "cacheDirectory" to root.path,
                    ))
                } catch (error: Exception) { result.error("UPDATE_INFO", "无法读取应用版本", null) }
            }
            "canInstallPackages" -> result.success(canInstall())
            "openInstallPermissionSettings" -> {
                try {
                    val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
                    } else {
                        Intent(Settings.ACTION_SECURITY_SETTINGS)
                    }
                    try { activity.startActivity(intent) }
                    catch (_: android.content.ActivityNotFoundException) {
                        // Some TV ROMs omit the per-app settings activity.
                        activity.startActivity(Intent(Settings.ACTION_SETTINGS))
                    }
                    result.success(null)
                } catch (_: Exception) {
                    result.error("UPDATE_PERMISSION", "请在系统设置中允许 StreamBox 安装应用", null)
                }
            }
            "verifyApk" -> worker.execute {
                try {
                    verify(call)
                    activity.runOnUiThread { if (!closed) result.success(null) }
                } catch (error: Exception) {
                    activity.runOnUiThread { if (!closed) result.error("UPDATE_INVALID_APK", validationMessage(error), null) }
                }
            }
            "installApk" -> {
                if (installResult != null) {
                    result.error("UPDATE_BUSY", "已有安装任务，请先完成系统安装", null)
                    return
                }
                installResult = result
                worker.execute {
                    try {
                        val file = try { verify(call) } catch (error: Exception) {
                            activity.runOnUiThread { finishError("UPDATE_INVALID_APK", validationMessage(error)) }
                            return@execute
                        }
                        if (!canInstall()) {
                            activity.runOnUiThread { finishError("UPDATE_PERMISSION", "请先允许 StreamBox 安装应用") }
                            return@execute
                        }
                        if (closed) return@execute
                        val installer = activity.packageManager.packageInstaller
                        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                            setAppPackageName(activity.packageName)
                            setSize(file.length())
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
                            }
                        }
                        val id = installer.createSession(params)
                        sessionId = id
                        installer.openSession(id).use { session ->
                            session.openWrite("base.apk", 0, file.length()).use { output ->
                                file.inputStream().use { it.copyTo(output) }
                                session.fsync(output)
                            }
                            if (closed) {
                                session.abandon()
                                return@execute
                            }
                            val intent = Intent(activity, AppUpdateReceiver::class.java).apply {
                                action = "${activity.packageName}.UPDATE_RESULT"
                            }
                            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
                            val callback = PendingIntent.getBroadcast(activity, id, intent, flags)
                            session.commit(callback.intentSender)
                        }
                    } catch (error: Exception) {
                        activity.runOnUiThread {
                            val message = when (error) {
                                is java.io.IOException -> "无法准备安装包，请检查可用存储空间"
                                is SecurityException -> "系统阻止了安装，请检查安装权限"
                                else -> "无法启动系统安装，请重试"
                            }
                            finishError("UPDATE_INSTALL", message)
                        }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun validationMessage(error: Exception): String =
        if (error is IllegalArgumentException) error.message ?: "安装包校验失败，请重新下载"
        else "安装包无法读取或解析，请重新下载"

    @Suppress("DEPRECATION")
    private fun canInstall(): Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        activity.packageManager.canRequestPackageInstalls()
    } else {
        Settings.Secure.getInt(activity.contentResolver, Settings.Secure.INSTALL_NON_MARKET_APPS, 0) == 1
    }

    @Suppress("DEPRECATION")
    private fun identity(info: PackageInfo): ApkIdentity {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners.orEmpty()
        } else {
            info.signatures.orEmpty()
        }
        return ApkIdentity(
            packageName = info.packageName,
            versionName = info.versionName ?: "",
            versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong(),
            certificates = signatures.map {
                ApkUpdatePolicy.hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray()))
            }.toSet(),
            minSdk = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) info.applicationInfo?.minSdkVersion ?: 1 else 1,
        )
    }

    private val signatureFlags get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        PackageManager.GET_SIGNING_CERTIFICATES
    } else {
        @Suppress("DEPRECATION")
        PackageManager.GET_SIGNATURES
    }

    @Suppress("DEPRECATION")
    private fun installedIdentity() = identity(activity.packageManager.getPackageInfo(activity.packageName, signatureFlags))

    @Suppress("DEPRECATION")
    private fun verify(call: MethodCall): File {
        val expected = UpdateExpectation(
            packageName = requireNotNull(call.argument<String>("packageName")),
            versionName = requireNotNull(call.argument<String>("versionName")),
            versionCode = requireNotNull(call.argument<Number>("versionCode")).toLong(),
            size = requireNotNull(call.argument<Number>("size")).toLong(),
            sha256 = requireNotNull(call.argument<String>("sha256")),
            certificateSha256 = requireNotNull(call.argument<String>("certificateSha256")),
        )
        val file = ApkUpdatePolicy.verifyFile(root, File(requireNotNull(call.argument<String>("path"))), expected)
        val archive = activity.packageManager.getPackageArchiveInfo(file.path, signatureFlags)
            ?: throw IllegalArgumentException("安装包无法解析，请重新下载")
        ApkUpdatePolicy.verifyIdentity(installedIdentity(), identity(archive), expected, Build.VERSION.SDK_INT)
        ApkUpdatePolicy.verifyAbi(file, Build.SUPPORTED_ABIS.toList())
        return file
    }

    fun onResume() {
        resumed = true
        launchConfirmation()
    }

    fun onPause() { resumed = false }

    private fun launchConfirmation() {
        if (!resumed || closed) return
        val intent = confirmation ?: return
        confirmation = null
        try { activity.startActivity(intent) }
        catch (_: Exception) { finishError("UPDATE_INSTALL_UI", "无法打开系统安装界面，请重试") }
    }

    @Suppress("DEPRECATION")
    fun receive(intent: Intent) {
        if (closed || installResult == null ||
            intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) != sessionId) return
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                confirmation = intent.getParcelableExtra(Intent.EXTRA_INTENT)
                if (confirmation == null) finishError("UPDATE_INSTALL_UI", "系统安装界面不可用")
                else launchConfirmation()
            }
            PackageInstaller.STATUS_SUCCESS -> {
                installResult?.success(true)
                installResult = null
                sessionId = null
            }
            PackageInstaller.STATUS_FAILURE_ABORTED -> {
                installResult?.success(false)
                installResult = null
                sessionId = null
            }
            PackageInstaller.STATUS_FAILURE_STORAGE -> finishError("UPDATE_STORAGE", "存储空间不足，请清理后重试")
            PackageInstaller.STATUS_FAILURE_BLOCKED -> finishError("UPDATE_BLOCKED", "系统阻止了安装，请检查安装权限")
            PackageInstaller.STATUS_FAILURE_CONFLICT -> finishError("UPDATE_CONFLICT", "安装包与当前应用冲突，请检查发布签名")
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> finishError("UPDATE_INCOMPATIBLE", "安装包不支持当前设备")
            else -> finishError("UPDATE_INSTALL", "系统安装失败，请重试")
        }
    }

    private fun finishError(code: String, message: String) {
        sessionId?.let { id ->
            try { activity.packageManager.packageInstaller.abandonSession(id) } catch (_: Exception) {}
        }
        sessionId = null
        confirmation = null
        installResult?.error(code, message, null)
        installResult = null
    }

    fun close() {
        closed = true
        finishError("UPDATE_CLOSED", "安装页面已关闭，请重试")
        if (active?.get() === this) active = null
        worker.shutdown()
    }

    companion object {
        internal var active: WeakReference<AppUpdateInstaller>? = null
    }
}

/** Explicit, non-exported receiver used by PackageInstaller's mutable callback. */
class AppUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AppUpdateInstaller.active?.get()?.receive(intent)
    }
}
