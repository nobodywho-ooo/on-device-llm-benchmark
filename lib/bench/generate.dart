import 'dart:async';

import 'package:nobodywho/nobodywho.dart' as nw;

import 'text_utils.dart';

/// Cooperative cancellation shared by the runner and the UI.
class CancelToken {
  bool _cancelled = false;
  nw.Chat? activeChat;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    activeChat?.stopGeneration();
  }
}

class CancelledException implements Exception {
  @override
  String toString() => 'Benchmark cancelled';
}

class GenResult {
  final String raw;
  final int chunks;
  final double? ttftMs;
  final double totalMs;
  final double? decodeMs; // first token -> last token
  final bool hitLimit;
  final bool timedOut;
  final String? error;

  GenResult({
    required this.raw,
    required this.chunks,
    required this.ttftMs,
    required this.totalMs,
    required this.decodeMs,
    required this.hitLimit,
    required this.timedOut,
    this.error,
  });

  String get text => stripThinking(raw);
}

/// Sends [prompt] to [chat], streaming tokens and measuring timing.
///
/// Stops generation after [maxTokens] streamed chunks or after [timeout].
Future<GenResult> generate(
  nw.Chat chat,
  String prompt, {
  int? maxTokens,
  Duration timeout = const Duration(minutes: 3),
  CancelToken? cancel,
  void Function(String token)? onToken,
}) async {
  if (cancel?.isCancelled ?? false) throw CancelledException();
  cancel?.activeChat = chat;

  final sb = StringBuffer();
  var chunks = 0;
  var hitLimit = false;
  var timedOut = false;
  String? error;
  final sw = Stopwatch()..start();
  double? ttft;
  double? lastTokenAt;

  final timer = Timer(timeout, () {
    timedOut = true;
    chat.stopGeneration();
  });

  try {
    await for (final token in chat.ask(prompt)) {
      final now = sw.elapsedMicroseconds / 1000.0;
      ttft ??= now;
      lastTokenAt = now;
      chunks++;
      sb.write(token);
      onToken?.call(token);
      if (!hitLimit && maxTokens != null && chunks >= maxTokens) {
        hitLimit = true;
        chat.stopGeneration();
      }
    }
  } catch (e) {
    error = e.toString();
  } finally {
    timer.cancel();
    sw.stop();
    cancel?.activeChat = null;
  }

  if (cancel?.isCancelled ?? false) throw CancelledException();

  return GenResult(
    raw: sb.toString(),
    chunks: chunks,
    ttftMs: ttft,
    totalMs: sw.elapsedMicroseconds / 1000.0,
    decodeMs: (ttft != null && lastTokenAt != null) ? lastTokenAt - ttft : null,
    hitLimit: hitLimit,
    timedOut: timedOut,
    error: error,
  );
}
