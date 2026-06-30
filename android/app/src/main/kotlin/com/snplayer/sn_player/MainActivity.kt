package com.snplayer.sn_player

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.snplayer.sn_player/file"

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
            } else {
                result.notImplemented()
            }
        }
    }

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
