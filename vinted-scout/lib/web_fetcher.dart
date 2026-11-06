import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class WebFetchException implements Exception {
  final String message;
  WebFetchException(this.message);
  @override
  String toString() => message;
}

/// Loads a page in a hidden real browser engine (WebView2 on Windows,
/// Android System WebView on phones) and returns its visible text. Sites
/// that bot-check plain HTTP clients (eBay) accept this.
class WebFetcher {
  static bool isChallenge(String text) {
    final t = text.toLowerCase();
    return t.contains('pardon our interruption') ||
        t.contains('checking your browser') ||
        t.contains('verify you are a human') ||
        t.contains('access denied') ||
        t.contains('please verify') ||
        t.contains('reference #') && t.length < 1500;
  }

  Future<String> pageText(
    String url, {
    Duration loadTimeout = const Duration(seconds: 30),
    int settlePolls = 8,
  }) async {
    final loaded = Completer<void>();
    String? loadError;
    final headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSize: const Size(1280, 2000),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useOnLoadResource: false,
        mediaPlaybackRequiresUserGesture: true,
        transparentBackground: true,
      ),
      onLoadStop: (controller, uri) {
        if (!loaded.isCompleted) loaded.complete();
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame == true) {
          loadError = error.description;
          if (!loaded.isCompleted) loaded.complete();
        }
      },
    );
    try {
      await headless.run();
      try {
        await loaded.future.timeout(loadTimeout);
      } on TimeoutException {
        throw WebFetchException('Page did not finish loading in ${loadTimeout.inSeconds}s: $url');
      }
      if (loadError != null) {
        throw WebFetchException('Page failed to load: $loadError');
      }
      String last = '';
      for (var i = 0; i < settlePolls; i++) {
        final c = headless.webViewController;
        if (c == null) break;
        final r = await c.evaluateJavascript(
            source: 'document.body ? document.body.innerText : ""');
        final text = (r ?? '').toString();
        if (text.trim().isNotEmpty && !isChallenge(text)) return text;
        last = text;
        // Challenge pages usually resolve themselves after a moment.
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (isChallenge(last)) {
        throw WebFetchException('Site showed a bot-check page that did not clear.');
      }
      return last;
    } finally {
      try {
        await headless.dispose();
      } catch (_) {}
    }
  }
}
