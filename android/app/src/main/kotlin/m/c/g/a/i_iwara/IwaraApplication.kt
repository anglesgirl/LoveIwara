package m.c.g.a.i_iwara

import android.app.Application
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.FileProvider
import echproxy.Echproxy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File

/**
 * 内置 ECH 代理：App 启动时自动拉起 ech-proxy-go
 * 监听 127.0.0.1:8080（只本机可用）
 *
 * Flutter 侧 dio 通过 X-Ech-Target 头走本代理 → DoH 干净解析 + ECH 直连
 * media_kit 播放器通过 http-proxy 指向本代理（CONNECT → DoH 去污染）
 */
class IwaraApplication : Application() {

    companion object {
        private const val TAG = "IwaraEchProxy"
        private const val LISTEN = "127.0.0.1:8080"

        @Volatile
        var proxyRunning: Boolean = false
            private set

        @Volatile
        var proxyStatus: String = "not started"
            private set

        /** DoH 端点：seed TXT 下发的 Cloudflare Gateway（海外干净、JSON 格式） */
        private val DOH = "https://pieqllv9i7.cloudflare-gateway.com/dns-query," +
            "https://al62jgpda0.cloudflare-gateway.com/dns-query," +
            "https://2w59vnepne.cloudflare-gateway.com/dns-query," +
            "https://m2b4x7vw98.cloudflare-gateway.com/dns-query," +
            "https://xzam891f5d.cloudflare-gateway.com/dns-query," +
            "https://dz1598pphb.cloudflare-gateway.com/dns-query," +
            "https://e6i0vltnvu.cloudflare-gateway.com/dns-query"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()
        startEchProxy()
    }

    /** 后台线程启动 ECH 代理（不能卡主线程） */
    private fun startEchProxy() {
        scope.launch {
            try {
                val cachePath = File(cacheDir, "ech-cache").absolutePath
                // MITM 模式：播放器/图片/API 都能走 ECH（客户端跳过证书校验即可）
                Echproxy.setMitm(true)
                // gomobile：仅返回 error 的 Go 函数映射为 Unit，错误通过异常抛出
                Echproxy.start(LISTEN, DOH, cachePath, false)
                proxyRunning = true
                proxyStatus = "running on $LISTEN"
                Log.i(TAG, "ECH proxy started: $proxyStatus")
            } catch (e: Throwable) {
                proxyStatus = "start failed: $e"
                Log.e(TAG, "ECH proxy start failed: $e")
            }
        }
    }

    /** Flutter 查询代理状态 */
    fun getStatus(): Map<String, Any?> {
        return mapOf(
            "running" to proxyRunning,
            "status" to proxyStatus
        )
    }

    /** 开关代理（UI 调用） */
    fun toggleProxy() {
        if (proxyRunning) {
            stopProxy()
        } else {
            startEchProxy()
        }
    }

    fun isProxyRunning(): Boolean = proxyRunning

    fun proxyPort(): Int = LISTEN.substringAfterLast(':').toIntOrNull() ?: 8080

    /** Go 内部诊断日志 */
    fun diag(): String {
        return try {
            Echproxy.diagnostics()
        } catch (e: Throwable) {
            "diagnostics error: $e"
        }
    }

    /** 导出 MITM CA 证书并直接拉起系统安装向导（API 24+） */
    fun exportCA(): String {
        return try {
            val pem = Echproxy.getCAPem()
            if (pem.isEmpty()) return "CA not available (MITM not enabled or proxy not running)"
            // 真正的公共 Download 目录：/storage/emulated/0/Download/
            val publicDownloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            publicDownloadDir.mkdirs()
            val file = File(publicDownloadDir, "ech_proxy_ca.crt")
            file.writeText(pem)
            // 兼容 Android 10+：同时用 MediaStore 插入 Downloads 集合，让系统文件管理器立即可见
            try {
                val resolver = contentResolver
                val values = android.content.ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, "ech_proxy_ca.crt")
                    put(MediaStore.MediaColumns.MIME_TYPE, "application/x-x509-ca-cert")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                }
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                uri?.let { resolver.openOutputStream(it)?.use { it.write(pem.toByteArray()) } }
            } catch (e: Throwable) {
                Log.w(TAG, "MediaStore insert failed (non-fatal): $e")
            }
            // Android 7.0+ (API 24): 直接用 Intent 拉起证书安装向导，预选文件
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                try {
                    val uri = FileProvider.getUriForFile(
                        this, "${packageName}.fileprovider", file
                    )
                    val intent = Intent(Intent.ACTION_INSTALL_CERTIFICATE)
                        .putExtra(Intent.EXTRA_CERTIFICATE, uri)
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    startActivity(intent)
                    return "已拉起系统证书安装向导，请输入锁屏密码完成安装"
                } catch (e: Throwable) {
                    Log.w(TAG, "ACTION_INSTALL_CERTIFICATE failed, fallback to manual: $e")
                }
            }
            "已导出到公共下载目录: ${file.absolutePath}\n请在系统设置→安全→安装证书→CA证书中选择该文件"
        } catch (e: Throwable) {
            "export CA failed: $e"
        }
    }

    private fun stopProxy() {
        scope.launch {
            try {
                Echproxy.stop()
                proxyRunning = false
                proxyStatus = "stopped"
                Log.i(TAG, "ECH proxy stopped")
            } catch (e: Throwable) {
                proxyStatus = "stop failed: $e"
            }
        }
    }
}