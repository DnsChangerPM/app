package com.dnschanger.app

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** App-private APK handoff. Android, not this app, asks the user to confirm installation. */
@Suppress("DEPRECATION")
class ApkInstaller(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.dnschanger.app/updater"
        private const val SOURCES_REQUEST = 102
        private const val INSTALL_REQUEST = 103
    }

    private val executor = Executors.newSingleThreadExecutor()
    private var pendingResult: MethodChannel.Result? = null
    private var pendingApk: File? = null
    private var destroyed = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getUpdateDirectory" -> {
                try {
                    result.success(updateDirectory().canonicalPath)
                } catch (_: Exception) {
                    result.error("storage_error", "Update storage is unavailable", null)
                }
            }
            "installApk" -> {
                if (pendingResult != null) {
                    result.error("install_busy", "Installation is already in progress", null)
                    return
                }
                pendingResult = result
                val path = call.argument<String>("path")
                val digest = call.argument<String>("sha256")
                // Hashing / parsing a large universal APK must not freeze the UI.
                executor.execute {
                    try {
                        val file = validateApk(path, digest)
                        activity.runOnUiThread {
                            if (!destroyed) {
                                pendingApk = file
                                requestInstall()
                            }
                        }
                    } catch (error: InstallFailure) {
                        activity.runOnUiThread { fail(error.code) }
                    } catch (_: Exception) {
                        activity.runOnUiThread { fail("invalid_apk") }
                    }
                }
            }
            "exitApp" -> {
                // Exiting a mandatory update must not leave the old VPN active.
                // Invalidate a pending VPN permission result too; a late grant
                // must not start a tunnel after the update screen exits.
                try {
                    VpnController.stopNative(activity)
                } catch (_: Exception) {
                    result.error("exit_failed", "Could not disconnect the VPN", null)
                    return
                }
                result.success(null)
                activity.finishAndRemoveTask()
            }
            else -> result.notImplemented()
        }
    }

    private fun updateDirectory(): File {
        val directory = File(activity.cacheDir, "updates")
        if (!directory.isDirectory && !directory.mkdirs()) throw InstallFailure("storage_error")
        return directory
    }

    private fun validateApk(path: String?, digest: String?): File {
        if (path == null) throw InstallFailure("missing_apk")
        val file = File(path).canonicalFile
        // Only the complete APK in our narrow FileProvider directory can be shared.
        if (file != File(updateDirectory(), "update.apk").canonicalFile || !file.isFile) {
            throw InstallFailure("missing_apk")
        }
        if (digest != null) {
            if (!Regex("[a-fA-F0-9]{64}").matches(digest)) throw InstallFailure("checksum_mismatch")
            val hash = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    hash.update(buffer, 0, count)
                }
            }
            val actual = hash.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
            if (!actual.equals(digest, ignoreCase = true)) throw InstallFailure("checksum_mismatch")
        }
        val pm = activity.packageManager
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val candidate = pm.getPackageArchiveInfo(file.path, flags)
            ?: throw InstallFailure("invalid_apk")
        val installed = pm.getPackageInfo(activity.packageName, flags)
        if (candidate.packageName != activity.packageName) throw InstallFailure("invalid_apk")
        if (versionCode(candidate) <= versionCode(installed)) throw InstallFailure("not_newer")
        if (!sameSigner(installed, candidate)) throw InstallFailure("signature_mismatch")
        return file
    }

    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()

    private fun sameSigner(installed: PackageInfo, candidate: PackageInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val current = installed.signingInfo ?: return false
            val next = candidate.signingInfo ?: return false
            val currentSigners = current.apkContentsSigners.toSet()
            if (currentSigners.isEmpty()) return false
            return if (current.hasMultipleSigners() || next.hasMultipleSigners()) {
                currentSigners == next.apkContentsSigners.toSet()
            } else {
                // Also allow Android's verified signing-certificate rotation lineage.
                val history = next.signingCertificateHistory?.toSet() ?: return false
                history.containsAll(currentSigners)
            }
        }
        val current = installed.signatures?.toSet() ?: return false
        return current.isNotEmpty() && current == candidate.signatures?.toSet()
    }

    private fun requestInstall() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !activity.packageManager.canRequestPackageInstalls()) {
                val intent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}")
                )
                activity.startActivityForResult(intent, SOURCES_REQUEST)
            } else {
                openInstaller()
            }
        } catch (_: Exception) {
            fail("install_unavailable")
        }
    }

    private fun openInstaller() {
        val file = pendingApk ?: return fail("missing_apk")
        if (!file.isFile) return fail("missing_apk")
        try {
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
            val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                data = uri
                clipData = ClipData.newRawUri("APK update", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                putExtra(Intent.EXTRA_RETURN_RESULT, true)
            }
            activity.startActivityForResult(intent, INSTALL_REQUEST)
        } catch (_: Exception) {
            fail("install_unavailable")
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        when (requestCode) {
            SOURCES_REQUEST -> {
                if (pendingResult != null) {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                        activity.packageManager.canRequestPackageInstalls()) {
                        // Continue automatically after the user grants permission.
                        openInstaller()
                    } else {
                        fail("permission_denied")
                    }
                }
            }
            INSTALL_REQUEST -> {
                if (resultCode == Activity.RESULT_OK) {
                    pendingResult?.success(null)
                    clearPending()
                } else {
                    fail("install_cancelled")
                }
            }
            else -> return false
        }
        return true
    }

    private fun fail(code: String) {
        pendingResult?.error(code, "The update could not be installed", null)
        clearPending()
    }

    private fun clearPending() {
        pendingResult = null
        pendingApk = null
    }

    fun dispose() {
        destroyed = true
        fail("install_cancelled")
        executor.shutdownNow()
    }

    private class InstallFailure(val code: String) : Exception()
}
