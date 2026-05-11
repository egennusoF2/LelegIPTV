package com.infinitel8p.xtream

import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.GeolocationPermissions
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.PermissionRequest
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebSettings
import android.widget.FrameLayout
import android.widget.Toast
import androidx.activity.enableEdgeToEdge
import androidx.activity.OnBackPressedCallback
import androidx.core.view.WindowCompat
import android.app.PictureInPictureParams
import android.net.Uri
import android.util.Log
import android.util.Rational
import android.os.Build
import android.webkit.JavascriptInterface
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebViewClient
import androidx.annotation.RequiresApi
import java.util.concurrent.atomic.AtomicBoolean

@RequiresApi(Build.VERSION_CODES.O)
private class RenderGoneGuardingClient(
  private val delegate: WebViewClient,
  private val onRenderGone: (WebView, RenderProcessGoneDetail) -> Unit,
) : WebViewClient() {
  override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
    delegate.shouldInterceptRequest(view, request)

  override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
    delegate.shouldOverrideUrlLoading(view, request)

  override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
    delegate.onPageStarted(view, url, favicon)
  }

  override fun onPageFinished(view: WebView, url: String) {
    delegate.onPageFinished(view, url)
  }

  override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
    delegate.onReceivedError(view, request, error)
  }

  override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
    onRenderGone(view, detail)
    return true
  }
}

private class FullscreenAwareChromeClient(
  private val delegate: RustWebChromeClient,
  private val onShow: (View, CustomViewCallback) -> Unit,
  private val onHide: () -> Unit,
) : WebChromeClient() {
  override fun onShowCustomView(view: View, callback: CustomViewCallback) {
    onShow(view, callback)
  }

  override fun onHideCustomView() {
    onHide()
  }

  override fun onPermissionRequest(request: PermissionRequest) {
    delegate.onPermissionRequest(request)
  }

  override fun onJsAlert(view: WebView, url: String, message: String, result: JsResult): Boolean =
    delegate.onJsAlert(view, url, message, result)

  override fun onJsConfirm(view: WebView, url: String, message: String, result: JsResult): Boolean =
    delegate.onJsConfirm(view, url, message, result)

  override fun onJsPrompt(
    view: WebView,
    url: String,
    message: String,
    defaultValue: String,
    result: JsPromptResult,
  ): Boolean = delegate.onJsPrompt(view, url, message, defaultValue, result)

  override fun onGeolocationPermissionsShowPrompt(
    origin: String,
    callback: GeolocationPermissions.Callback,
  ) {
    delegate.onGeolocationPermissionsShowPrompt(origin, callback)
  }

  override fun onShowFileChooser(
    webView: WebView,
    filePathCallback: ValueCallback<Array<Uri?>?>,
    fileChooserParams: FileChooserParams,
  ): Boolean = delegate.onShowFileChooser(webView, filePathCallback, fileChooserParams)

  override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean =
    delegate.onConsoleMessage(consoleMessage)

  override fun onReceivedTitle(view: WebView, title: String) {
    delegate.onReceivedTitle(view, title)
  }
}

class StatusBarBridge(private val activity: TauriActivity) {
  @JavascriptInterface
  fun setAppearance(isLight: Boolean) {
    activity.runOnUiThread {
      val controller = WindowCompat.getInsetsController(activity.window, activity.window.decorView)
      controller.isAppearanceLightStatusBars = isLight
      controller.isAppearanceLightNavigationBars = isLight
    }
  }
}

class WebSettingsBridge(
  private val activity: TauriActivity,
  private val webViewRef: () -> WebView?,
  private val defaultUa: String,
) {
  @JavascriptInterface
  fun setUserAgent(ua: String?) {
    val target = if (ua.isNullOrEmpty()) defaultUa else ua
    activity.runOnUiThread {
      webViewRef()?.settings?.userAgentString = target
    }
  }
}

class DeviceInfoBridge(private val activity: TauriActivity) {
  @JavascriptInterface
  fun isLeanback(): Boolean =
    activity.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)

  @JavascriptInterface
  fun isTelevisionUiMode(): Boolean {
    val uiMode = activity.resources.configuration.uiMode and
      Configuration.UI_MODE_TYPE_MASK
    return uiMode == Configuration.UI_MODE_TYPE_TELEVISION
  }

  @JavascriptInterface
  fun isTv(): Boolean = isLeanback() || isTelevisionUiMode()
}

class PipBridge(private val activity: TauriActivity) {
  @JavascriptInterface
  fun isSupported(): Boolean =
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
    activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

  @JavascriptInterface
  fun isInPip(): Boolean =
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity.isInPictureInPictureMode

  @JavascriptInterface
  fun enter() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      activity.runOnUiThread {
        val params = PictureInPictureParams.Builder()
          .setAspectRatio(Rational(16, 9))
          .build()
        activity.enterPictureInPictureMode(params)
      }
    }
  }

  // Programmatically expand out of PiP by bringing the Activity to the front
  @JavascriptInterface
  fun expand() {
    activity.runOnUiThread {
      val intent = Intent(activity, MainActivity::class.java)
        .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
      activity.startActivity(intent)
    }
  }

  @JavascriptInterface
  fun toggle() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    if (activity.isInPictureInPictureMode) expand() else enter()
  }
}

class MainActivity : TauriActivity() {

  private var fullscreenView: View? = null
  private var fullscreenCallback: WebChromeClient.CustomViewCallback? = null
  private var originalSystemUi: Int = 0

  // Cached so the back-press handler can call onHideCustomView without re-walking the view tree.
  private var hostedWebView: WebView? = null

  private val rendererRecreating = AtomicBoolean(false)

  private lateinit var rustChromeClient: RustWebChromeClient

  companion object {
    private const val RENDER_GONE_REPEAT_WINDOW_MS = 60_000L
    @Volatile
    private var lastRenderGoneAt: Long = 0L
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)

    rustChromeClient = RustWebChromeClient(this)

    // Back button exits fullscreen first, then falls back to default behavior.
    onBackPressedDispatcher.addCallback(
      this,
      object : OnBackPressedCallback(true) {
        override fun handleOnBackPressed() {
          if (fullscreenView != null) {
            (hostedWebView?.webChromeClient as? WebChromeClient)?.onHideCustomView()
          } else {
            isEnabled = false
            onBackPressedDispatcher.onBackPressed()
          }
        }
      }
    )
  }

  // See https://github.com/tauri-apps/tauri/issues/13049.
  override fun onWebViewCreate(webView: WebView) {
    super.onWebViewCreate(webView)
    hostedWebView = webView

    webView.addJavascriptInterface(PipBridge(this), "AndroidPip")
    webView.addJavascriptInterface(StatusBarBridge(this), "AndroidStatusBar")
    webView.addJavascriptInterface(DeviceInfoBridge(this), "AndroidDeviceInfo")
    webView.addJavascriptInterface(
      WebSettingsBridge(this, { hostedWebView }, webView.settings.userAgentString),
      "AndroidWebSettings"
    )
    val isDebuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    WebView.setWebContentsDebuggingEnabled(isDebuggable)

    // Keep the renderer process from being reclaimed under TV / low-RAM
    // pressure. Default WAIVED is what triggers most renderer-gone crashes
    // on cheap Android TV boxes.
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      webView.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false)
    }

    webView.settings.javaScriptEnabled = true
    webView.settings.setSupportMultipleWindows(true)
    webView.settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
    webView.settings.mediaPlaybackRequiresUserGesture = false

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      webView.post {
        val tauriClient = webView.webViewClient
        webView.webViewClient = RenderGoneGuardingClient(tauriClient) { deadView, detail ->
          if (!rendererRecreating.compareAndSet(false, true)) {
            return@RenderGoneGuardingClient
          }
          val now = System.currentTimeMillis()
          val sinceLast = now - lastRenderGoneAt
          lastRenderGoneAt = now
          val didCrash = detail.didCrash()
          val isRepeat = sinceLast in 1..RENDER_GONE_REPEAT_WINDOW_MS
          Log.w(
            "xtream-rs",
            "WebView render process gone (didCrash=$didCrash, priority=${detail.rendererPriorityAtExit()}, sinceLast=${sinceLast}ms, repeat=$isRepeat)"
          )
          val messageRes = when {
            isRepeat -> R.string.render_gone_repeat
            didCrash -> R.string.render_gone_crash
            else -> R.string.render_gone_oom
          }
          Toast.makeText(applicationContext, messageRes, Toast.LENGTH_LONG).show()
          hostedWebView = null
          fullscreenView = null
          fullscreenCallback = null
          (deadView.parent as? ViewGroup)?.removeView(deadView)
          deadView.destroy()
          if (isRepeat) {
            return@RenderGoneGuardingClient
          }
          if (!isFinishing && !isDestroyed) {
            recreate()
          }
        }
      }
    }

    webView.webChromeClient = FullscreenAwareChromeClient(
      delegate = rustChromeClient,
      onShow = { view, callback ->
        if (fullscreenView != null) {
          callback.onCustomViewHidden()
        } else {
          fullscreenView = view
          fullscreenCallback = callback

          val decor = window.decorView as FrameLayout
          originalSystemUi = decor.systemUiVisibility
          decor.addView(
            view,
            FrameLayout.LayoutParams(
              ViewGroup.LayoutParams.MATCH_PARENT,
              ViewGroup.LayoutParams.MATCH_PARENT
            )
          )
          decor.systemUiVisibility =
            (View.SYSTEM_UI_FLAG_FULLSCREEN
              or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
              or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY)
        }
      },
      onHide = {
        val decor = window.decorView as FrameLayout
        fullscreenView?.let { decor.removeView(it) }
        decor.systemUiVisibility = originalSystemUi
        fullscreenCallback?.onCustomViewHidden()
        fullscreenView = null
        fullscreenCallback = null
      }
    )
  }

  override fun onUserLeaveHint() {
    super.onUserLeaveHint()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && fullscreenView != null) {
      val params = PictureInPictureParams.Builder()
        .setAspectRatio(Rational(16, 9))
        .build()
      enterPictureInPictureMode(params)
    }
  }

  override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean) {
    super.onPictureInPictureModeChanged(isInPictureInPictureMode)
  }
}
