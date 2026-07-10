package m.c.g.a.i_iwara

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Intent
import android.content.pm.ActivityInfo
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.util.Log
import android.view.KeyEvent
import android.view.WindowManager
import android.webkit.MimeTypeMap
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {
    private val CHANNEL = "i_iwara/volume_key"
    private val SCREENSHOT_CHANNEL = "i_iwara/screenshot"
    private val FILE_HANDLER_CHANNEL = "com.example.i_iwara/file_handler"
    private val DEVICE_FORM_FACTOR_CHANNEL = "i_iwara/device_form_factor"
    private val ORIENTATION_CHANNEL = "i_iwara/orientation"
    private val EXIT_INFO_CHANNEL = "i_iwara/exit_info"

    private var volumeKeyEnabled = false
    private var fileHandlerChannel: MethodChannel? = null
    private val mainScope = CoroutineScope(Dispatchers.Main)

    private val REQUEST_CODE_PICK_DIRECTORY = 51423
    private var pendingDirectoryResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
                call,
                result ->
            when (call.method) {
                "enableVolumeKeyListener" -> {
                    volumeKeyEnabled = true
                    result.success(null)
                }
                "disableVolumeKeyListener" -> {
                    volumeKeyEnabled = false
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREENSHOT_CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "preventScreenshot" -> {
                            window.setFlags(
                                    WindowManager.LayoutParams.FLAG_SECURE,
                                    WindowManager.LayoutParams.FLAG_SECURE
                            )
                            result.success(null)
                        }
                        "allowScreenshot" -> {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            result.success(null)
                        }
                        else -> {
                            result.notImplemented()
                        }
                    }
                }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_FORM_FACTOR_CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getDeviceFormFactorInfo" -> result.success(getDeviceFormFactorInfo())
                        else -> result.notImplemented()
                    }
                }

        // 原生强制屏幕方向：setPreferredOrientations 在部分机型 / 关闭系统自动旋转
        // 时不生效（平板竖持点全屏出不来横屏的根因）。SENSOR_LANDSCAPE 由 App 主动请求，
        // 无视系统自动旋转锁，直接把 Activity 转到横屏。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ORIENTATION_CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "setOrientation" -> {
                            val mode = call.arguments as? String
                            runOnUiThread {
                                requestedOrientation = when (mode) {
                                    "landscape" ->
                                            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                                    "portrait" ->
                                            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                                    else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                                }
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }

        // 上一进程死因查询：Dart 层崩溃检测只能覆盖 Dart 异常，系统杀进程（LMK/OOM）、
        // 原生崩溃、ANR 对 Flutter 完全不可见。ApplicationExitInfo (API 30+) 是唯一能在
        // 下次启动时拿到确切死因（reason/importance/死亡时 RSS/tombstone）的通道。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EXIT_INFO_CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getHistoricalExitReasons" -> {
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                                result.success(null)
                            } else {
                                val maxCount = call.argument<Int>("maxCount") ?: 5
                                mainScope.launch {
                                    try {
                                        val payload = withContext(Dispatchers.IO) {
                                            collectExitReasons(maxCount)
                                        }
                                        result.success(payload)
                                    } catch (e: Exception) {
                                        Log.w("MainActivity", "读取历史退出原因失败: ${e.message}")
                                        result.error("EXIT_INFO_FAILED", e.message, null)
                                    }
                                }
                            }
                        }
                        else -> result.notImplemented()
                    }
                }

        // 初始化文件处理 MethodChannel
        fileHandlerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_HANDLER_CHANNEL)
        fileHandlerChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "copyContentUriToCache" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString == null) {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
                        return@setMethodCallHandler
                    }
                    copyContentUriToCache(uriString, result)
                }
                "pickDirectory" -> {
                    if (pendingDirectoryResult != null) {
                        result.error("ALREADY_ACTIVE", "目录选择器已在运行", null)
                    } else {
                        try {
                            pendingDirectoryResult = result
                            startActivityForResult(
                                    Intent(Intent.ACTION_OPEN_DOCUMENT_TREE),
                                    REQUEST_CODE_PICK_DIRECTORY
                            )
                        } catch (e: Exception) {
                            pendingDirectoryResult = null
                            result.error("PICKER_FAILED", e.message, null)
                        }
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    /** 收集本包最近 [maxCount] 条进程退出记录，按时间倒序（最新在前）。IO 线程调用。 */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun collectExitReasons(maxCount: Int): List<Map<String, Any?>> {
        val am = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        return am.getHistoricalProcessExitReasons(packageName, 0, maxCount).map { info ->
            mapOf(
                    "timestampMs" to info.timestamp,
                    "pid" to info.pid,
                    "processName" to info.processName,
                    "reasonCode" to info.reason,
                    "reason" to exitReasonName(info.reason),
                    "status" to info.status,
                    "importanceCode" to info.importance,
                    "importance" to importanceName(info.importance),
                    "pssKb" to info.pss,
                    "rssKb" to info.rss,
                    "description" to info.description,
                    "trace" to readExitTrace(info)
            )
        }
    }

    /**
     * 原生崩溃的 tombstone / ANR 的线程栈。只取头部 96KB：崩溃信号、abort message、
     * 崩溃线程 backtrace 都在文件头部，尾部是可省略的内存映射表。
     */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun readExitTrace(info: ApplicationExitInfo): String? {
        if (info.reason != ApplicationExitInfo.REASON_ANR &&
                info.reason != ApplicationExitInfo.REASON_CRASH_NATIVE
        ) {
            return null
        }
        return try {
            info.traceInputStream?.use { stream ->
                val buffer = ByteArray(96 * 1024)
                var read = 0
                while (read < buffer.size) {
                    val n = stream.read(buffer, read, buffer.size - read)
                    if (n < 0) break
                    read += n
                }
                if (read == 0) null else String(buffer, 0, read, Charsets.UTF_8)
            }
        } catch (e: Exception) {
            Log.w("MainActivity", "读取退出 trace 失败: ${e.message}")
            null
        }
    }

    private fun exitReasonName(reason: Int): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return "UNKNOWN($reason)"
        return when (reason) {
            ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
            ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
            ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
            ApplicationExitInfo.REASON_CRASH -> "CRASH"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
            ApplicationExitInfo.REASON_ANR -> "ANR"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
            ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
            ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
            ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
            ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
            ApplicationExitInfo.REASON_OTHER -> "OTHER"
            ApplicationExitInfo.REASON_FREEZER -> "FREEZER"
            ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> "PACKAGE_STATE_CHANGE"
            ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "PACKAGE_UPDATED"
            else -> "UNKNOWN($reason)"
        }
    }

    private fun importanceName(importance: Int): String {
        return when (importance) {
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> "FOREGROUND"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE -> "FOREGROUND_SERVICE"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE -> "VISIBLE"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_PERCEPTIBLE -> "PERCEPTIBLE"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE -> "SERVICE"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_TOP_SLEEPING -> "TOP_SLEEPING"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_CANT_SAVE_STATE -> "CANT_SAVE_STATE"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED -> "CACHED"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_GONE -> "GONE"
            else -> "OTHER($importance)"
        }
    }

    private fun getDeviceFormFactorInfo(): Map<String, Any?> {
        val smallestWidthDp = resources.configuration.smallestScreenWidthDp
        return mapOf(
                "platformIsTablet" to (smallestWidthDp >= 600),
                "smallestWidthDp" to smallestWidthDp,
                "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
                "source" to "android_smallest_width_dp"
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_CODE_PICK_DIRECTORY) {
            val result = pendingDirectoryResult
            if (result == null) {
                super.onActivityResult(requestCode, resultCode, data)
                return
            }
            pendingDirectoryResult = null
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) {
                // 用户取消选择
                result.success(null)
                return
            }
            try {
                result.success(resolveTreeUriToPath(uri))
            } catch (e: Exception) {
                Log.e("MainActivity", "解析目录路径失败: $uri", e)
                result.error("RESOLVE_FAILED", e.message, null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    /**
     * 将 SAF 目录树 URI 解析为文件系统绝对路径。
     * 不依赖 file_selector 插件的转换逻辑（其不支持外置 SD/TF 卡卷），
     * 主存储与外置存储卷均可解析；写入依赖「所有文件访问」权限而非 SAF。
     */
    private fun resolveTreeUriToPath(uri: Uri): String {
        if (uri.authority != "com.android.externalstorage.documents") {
            throw UnsupportedOperationException("不支持的存储位置，请选择设备存储或 SD 卡中的目录")
        }
        val docId = DocumentsContract.getTreeDocumentId(uri)
        val split = docId.split(":", limit = 2)
        val volumeId = split[0]
        val subPath = if (split.size > 1) split[1] else ""
        val volumeRoot = when {
            volumeId.equals("primary", ignoreCase = true) ->
                    Environment.getExternalStorageDirectory().absolutePath
            volumeId.equals("home", ignoreCase = true) ->
                    File(Environment.getExternalStorageDirectory(), "Documents").absolutePath
            else -> findVolumeRootByUuid(volumeId) ?: "/storage/$volumeId"
        }
        return if (subPath.isEmpty()) volumeRoot else "$volumeRoot/$subPath"
    }

    /** 通过 StorageManager 将存储卷 UUID 映射到挂载根目录 */
    private fun findVolumeRootByUuid(uuid: String): String? {
        // StorageVolume.getDirectory 需要 API 30，R 以下由调用方回退 /storage/<卷ID>
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        return try {
            val storageManager = getSystemService(STORAGE_SERVICE) as StorageManager
            storageManager.storageVolumes
                    .firstOrNull { uuid.equals(it.uuid, ignoreCase = true) }
                    ?.directory
                    ?.absolutePath
        } catch (e: Exception) {
            Log.w("MainActivity", "查找存储卷失败: ${e.message}")
            null
        }
    }

    /**
     * 将 content:// URI 的文件复制到应用缓存目录
     * 这是解决 media_kit/mpv 无法播放 content:// URI 的 workaround
     */
    private fun copyContentUriToCache(uriString: String, result: MethodChannel.Result) {
        mainScope.launch {
            try {
                val uri = Uri.parse(uriString)
                val cachedPath = withContext(Dispatchers.IO) {
                    copyUriToCache(uri)
                }
                result.success(cachedPath)
            } catch (e: Exception) {
                Log.e("MainActivity", "复制文件失败: ${e.message}", e)
                result.error("COPY_FAILED", e.message, e.stackTraceToString())
            }
        }
    }

    /**
     * 在 IO 线程中执行实际的文件复制操作
     */
    private fun copyUriToCache(uri: Uri): String {
        val contentResolver = applicationContext.contentResolver

        // 获取文件名
        var fileName = "video_${System.currentTimeMillis()}"
        var extension = ".mp4"

        // 尝试从 URI 路径获取文件名
        val uriPath = Uri.decode(uri.toString())
        val pathFileName = uriPath.substringAfterLast('/')
        if (pathFileName.isNotEmpty() && pathFileName.contains('.')) {
            fileName = pathFileName.substringBeforeLast('.')
            extension = ".${pathFileName.substringAfterLast('.')}"
        }

        // 尝试从 ContentResolver 获取 MIME 类型来确定扩展名
        val mimeType = contentResolver.getType(uri)
        if (mimeType != null) {
            val mimeExtension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)
            if (mimeExtension != null) {
                extension = ".$mimeExtension"
            }
        }

        // 创建缓存目录
        val cacheDir = File(applicationContext.cacheDir, "local_videos")
        if (!cacheDir.exists()) {
            cacheDir.mkdirs()
        }

        // 清理旧的缓存文件（超过 24 小时的文件）
        cleanOldCacheFiles(cacheDir)

        // 清理文件名中的非法字符
        val safeFileName = fileName.replace(Regex("[^a-zA-Z0-9_\\-\\u4e00-\\u9fa5]"), "_")
        val targetFile = File(cacheDir, "$safeFileName$extension")

        // 如果文件已存在且大小匹配，直接返回（避免重复复制）
        if (targetFile.exists()) {
            val existingSize = targetFile.length()
            val sourceSize = getContentUriSize(uri)
            if (sourceSize > 0 && existingSize == sourceSize) {
                Log.d("MainActivity", "缓存文件已存在且大小匹配，跳过复制: ${targetFile.absolutePath}")
                return targetFile.absolutePath
            }
        }

        Log.d("MainActivity", "开始复制文件: $uri -> ${targetFile.absolutePath}")

        // 复制文件内容
        contentResolver.openInputStream(uri)?.use { inputStream ->
            FileOutputStream(targetFile).use { outputStream ->
                val buffer = ByteArray(8192)
                var bytesRead: Int
                var totalBytes = 0L
                while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                    outputStream.write(buffer, 0, bytesRead)
                    totalBytes += bytesRead
                }
                Log.d("MainActivity", "文件复制完成，大小: $totalBytes bytes")
            }
        } ?: throw Exception("无法打开 content:// URI 的输入流")

        return targetFile.absolutePath
    }

    /**
     * 获取 content:// URI 指向的文件大小
     */
    private fun getContentUriSize(uri: Uri): Long {
        return try {
            applicationContext.contentResolver.openFileDescriptor(uri, "r")?.use {
                it.statSize
            } ?: -1L
        } catch (e: Exception) {
            -1L
        }
    }

    /**
     * 清理超过 24 小时的缓存文件
     */
    private fun cleanOldCacheFiles(cacheDir: File) {
        try {
            val maxAge = 24 * 60 * 60 * 1000L // 24 小时（毫秒）
            val now = System.currentTimeMillis()

            cacheDir.listFiles()?.forEach { file ->
                if (file.isFile && (now - file.lastModified()) > maxAge) {
                    Log.d("MainActivity", "删除过期缓存文件: ${file.name}")
                    file.delete()
                }
            }
        } catch (e: Exception) {
            Log.w("MainActivity", "清理缓存文件失败: ${e.message}")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // 处理启动时的 Intent（从文件管理器打开）
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        
        // 处理新的 Intent（应用已在运行时）
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return

        val action = intent.action
        val data: Uri? = intent.data

        Log.d("MainActivity", "收到 Intent - Action: $action, Data: $data")

        // 处理 VIEW action（打开文件）
        if (action == Intent.ACTION_VIEW && data != null) {
            val uriString = data.toString()
            Log.d("MainActivity", "收到文件打开请求: $uriString")
            
            // 通过 MethodChannel 将文件 URI 传递给 Flutter
            fileHandlerChannel?.invokeMethod("onFileOpened", uriString)
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (volumeKeyEnabled) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, CHANNEL)
                            .invokeMethod("onVolumeKeyUp", null)
                    return true
                }
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, CHANNEL)
                            .invokeMethod("onVolumeKeyDown", null)
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }
}
