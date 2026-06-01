# THIS FILE IS AUTO-GENERATED. DO NOT MODIFY!!

# Copyright 2020-2023 Tauri Programme within The Commons Conservancy
# SPDX-License-Identifier: Apache-2.0
# SPDX-License-Identifier: MIT

-keep class com.lelegiptv.player.* {
  native <methods>;
}

-keep class com.lelegiptv.player.WryActivity {
  public <init>(...);

  void setWebView(com.lelegiptv.player.RustWebView);
  java.lang.Class getAppClass(...);
  int getId();
  java.lang.String getVersion();
  int startActivity(...);
}

-keep class com.lelegiptv.player.Ipc {
  public <init>(...);

  @android.webkit.JavascriptInterface public <methods>;
}

-keep class com.lelegiptv.player.RustWebView {
  public <init>(...);

  void loadUrlMainThread(...);
  void loadHTMLMainThread(...);
  void evalScript(...);
}

-keep class com.lelegiptv.player.RustWebChromeClient,com.lelegiptv.player.RustWebViewClient {
  public <init>(...);
}
