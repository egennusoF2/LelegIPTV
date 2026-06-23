package com.lelegiptv.leleg_iptv

import android.app.DownloadManager
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Environment
import android.view.KeyEvent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var nativeChannel: MethodChannel? = null
    private var remoteKeyPassthrough = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        nativeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.lelegiptv.native/storage"
        )
        nativeChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "downloadsDirectory" -> {
                    val externalDownloads =
                        getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                    val fallback = File(filesDir, "downloads")
                    result.success((externalDownloads ?: fallback).absolutePath)
                }

                "isTelevision" -> {
                    val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                    val isTv =
                        uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
                            packageManager.hasSystemFeature("android.software.leanback")
                    result.success(isTv)
                }

                "isTvFlavor" -> {
                    val fromManifest =
                        applicationInfo.metaData?.getString("leleg.tv.flavor") == "true"
                    result.success(BuildConfig.LELEG_TV_FLAVOR || fromManifest)
                }

                "setRemoteKeyPassthrough" -> {
                    remoteKeyPassthrough = call.argument<Boolean>("enabled") == true
                    result.success(true)
                }

                "notifyFileSaved" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    MediaScannerConnection.scanFile(
                        this,
                        arrayOf(path),
                        null,
                        null
                    )
                    result.success(true)
                }

                "enqueueDownload" -> {
                    val url = call.argument<String>("url")
                    val filename = call.argument<String>("filename")
                    val referer = call.argument<String>("referer")
                    val userAgent = call.argument<String>("userAgent")
                    if (url.isNullOrBlank() || filename.isNullOrBlank()) {
                        result.error("invalid_args", "Missing url or filename", null)
                        return@setMethodCallHandler
                    }
                    runCatching {
                        val request = DownloadManager.Request(Uri.parse(url)).apply {
                            setTitle(filename)
                            setDescription("Download Leleg IPTV")
                            setNotificationVisibility(
                                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
                            )
                            setAllowedOverMetered(true)
                            setAllowedOverRoaming(true)
                            setMimeType("*/*")
                            if (!referer.isNullOrBlank()) {
                                addRequestHeader("Referer", referer)
                            }
                            if (!userAgent.isNullOrBlank()) {
                                addRequestHeader("User-Agent", userAgent)
                            }
                            setDestinationInExternalFilesDir(
                                this@MainActivity,
                                Environment.DIRECTORY_DOWNLOADS,
                                filename
                            )
                        }
                        val manager =
                            getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                        manager.enqueue(request)
                        val destination =
                            File(
                                getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS),
                                filename
                            )
                        result.success(destination.absolutePath)
                    }.getOrElse {
                        result.error("enqueue_failed", it.message, null)
                    }
                }

                "openFile" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val file = File(path)
                    if (!file.exists()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val uri: Uri = FileProvider.getUriForFile(
                        this,
                        "$packageName.fileprovider",
                        file
                    )
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "*/*")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    runCatching {
                        startActivity(intent)
                        result.success(true)
                    }.getOrElse {
                        result.success(false)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (remoteKeyPassthrough) {
            return super.dispatchKeyEvent(event)
        }
        if (event.action == KeyEvent.ACTION_DOWN) {
            val key = when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_UP -> "up"
                KeyEvent.KEYCODE_DPAD_DOWN -> "down"
                KeyEvent.KEYCODE_DPAD_LEFT -> "left"
                KeyEvent.KEYCODE_DPAD_RIGHT -> "right"
                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER,
                KeyEvent.KEYCODE_BUTTON_A -> "select"
                KeyEvent.KEYCODE_BACK,
                KeyEvent.KEYCODE_ESCAPE,
                KeyEvent.KEYCODE_BUTTON_B -> "back"
                else -> null
            }
            if (key != null) {
                nativeChannel?.invokeMethod("remoteKey", mapOf("key" to key))
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
