package com.snplayer.sn_player

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.snplayer.sn_player/file"
    private val REQUEST_OPEN_FOLDER = 1001
    private var pendingFolderResult: Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "openFile") {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("NO_PATH", "path is null", null)
                    return@setMethodCallHandler
                }
                try {
                    val file = File(path)
                    if (!file.exists()) {
                        result.error("FILE_NOT_FOUND", "file not found: $path", null)
                        return@setMethodCallHandler
                    }

                    // FileProvider first, fallback to file:// URI for public dirs
                    var uri: Uri
                    try {
                        uri = FileProvider.getUriForFile(
                            this,
                            "${applicationContext.packageName}.fileprovider",
                            file
                        )
                    } catch (e: IllegalArgumentException) {
                        uri = Uri.fromFile(file)
                    }

                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, getMimeType(path))
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }

                    // Check if any app can handle this intent
                    if (packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) == null) {
                        result.error("NO_PLAYER", "no video player installed", null)
                        return@setMethodCallHandler
                    }

                    // Let user choose a player
                    startActivity(Intent.createChooser(intent, "选择播放器"))
                    result.success(true)
                } catch (e: Exception) {
                    result.error("OPEN_FAILED", e.message, null)
                }
            } else if (call.method == "openFolder") {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("NO_PATH", "path is null", null)
                    return@setMethodCallHandler
                }
                openFolder(path, result)
            } else {
                result.notImplemented()
            }
        }
    }

    // ----------------------------------------------------------------
    // 打开文件夹
    // ----------------------------------------------------------------

    /**
     * 尝试打开文件夹的三种策略：
     * 1. file:// URI (Android 6 兼容)
     * 2. SAF content URI (Android 7-9)
     * 3. ACTION_OPEN_DOCUMENT_TREE + EXTRA_INITIAL_URI (Android 10+)
     */
    private fun openFolder(path: String, result: Result) {
        val folder = File(path)
        if (!folder.exists() || !folder.isDirectory) {
            result.error("FOLDER_NOT_FOUND", "folder not found: $path", null)
            return
        }

        // 策略 1: 先尝试 file:// URI (Android 6 及部分 ROM 仍兼容)
        try {
            val fileUri = Uri.fromFile(folder)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(fileUri, "resource/folder")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) != null) {
                startActivity(Intent.createChooser(intent, "打开文件夹"))
                result.success(true)
                return
            }
        } catch (_: Exception) {
            // file:// 不可用，继续下一个策略
        }

        // 策略 2: 尝试 SAF content URI
        try {
            val safUri = buildFolderContentUri(path)
            if (safUri != null) {
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(safUri, DocumentsContract.Document.MIME_TYPE_DIR)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                }
                if (packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) != null) {
                    startActivity(Intent.createChooser(intent, "打开文件夹"))
                    result.success(true)
                    return
                }
            }
        } catch (_: SecurityException) {
            // SAF URI 无权限，进入策略 3
        } catch (_: Exception) {
            // 其他错误，进入策略 3
        }

        // 策略 3: ACTION_OPEN_DOCUMENT_TREE + EXTRA_INITIAL_URI (最终兜底)
        // 弹出系统文件选择器，预选目标文件夹，用户点"允许"即可
        val initialUri = buildFolderContentUri(path)
        if (initialUri != null) {
            pendingFolderResult = result
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri)
                }
            }
            startActivityForResult(intent, REQUEST_OPEN_FOLDER)
        } else {
            result.error("OPEN_FOLDER_FAILED", "cannot build SAF URI for: $path", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_OPEN_FOLDER) { return }

        val result = pendingFolderResult ?: return
        pendingFolderResult = null

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.error("OPEN_FOLDER_FAILED", "user cancelled or permission denied", null)
            return
        }

        // 拿到了 tree URI 权限，通过其打开文件管理器
        try {
            val treeUri = data.data!!
            // 持久化权限，下次打开无需再授权
            contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )

            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(treeUri, DocumentsContract.Document.MIME_TYPE_DIR)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            if (packageManager.resolveActivity(viewIntent, PackageManager.MATCH_DEFAULT_ONLY) != null) {
                startActivity(Intent.createChooser(viewIntent, "打开文件夹"))
                result.success(true)
            } else {
                // 无文件管理器能响应，但仍然成功了（权限已获得）
                result.success(true)
            }
        } catch (e: Exception) {
            result.error("OPEN_FOLDER_FAILED", e.message, null)
        }
    }

    /**
     * 将文件系统绝对路径转换为 SAF 内容 URI。
     *
     * /storage/emulated/0/Download/MewTool  →  content://...tree/primary:Download/MewTool
     */
    private fun buildFolderContentUri(absPath: String): Uri? {
        val externalStorage = Environment.getExternalStorageDirectory().absolutePath
        if (!absPath.startsWith(externalStorage)) { return null }

        val relativePath = absPath
            .removePrefix(externalStorage)
            .trimStart('/')

        return DocumentsContract.buildTreeDocumentUri(
            "com.android.externalstorage.documents",
            "primary:$relativePath"
        )
    }

    // ----------------------------------------------------------------
    // MIME 类型映射
    // ----------------------------------------------------------------

    private fun getMimeType(path: String): String {
        return when {
            path.endsWith(".mp4", true) -> "video/mp4"
            path.endsWith(".mkv", true) -> "video/x-matroska"
            path.endsWith(".avi", true) -> "video/x-msvideo"
            path.endsWith(".mov", true) -> "video/quicktime"
            path.endsWith(".flv", true) -> "video/x-flv"
            path.endsWith(".wmv", true) -> "video/x-ms-wmv"
            path.endsWith(".webm", true) -> "video/webm"
            path.endsWith(".m4v", true) -> "video/x-m4v"
            path.endsWith(".3gp", true) -> "video/3gpp"
            path.endsWith(".ts", true) -> "video/mp2t"
            else -> "video/*"
        }
    }
}
