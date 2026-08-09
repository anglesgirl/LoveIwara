package m.c.g.a.i_iwara

import android.app.Application
import android.util.Log
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
}