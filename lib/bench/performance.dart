import 'package:nobodywho/nobodywho.dart' as nw;

import 'generate.dart';
import 'settings.dart';
import 'text_utils.dart';

class PerfScenario {
  final String id;
  final String description;
  final String prompt;
  final int maxTokens;
  PerfScenario(this.id, this.description, this.prompt, this.maxTokens);
}

/// Builds the scenarios. The long prompt reuses the knowledge corpus so it is
/// deterministic and ~2k tokens.
List<PerfScenario> buildScenarios(String longContext) => [
  PerfScenario(
    'short_prompt',
    'Short prompt, up to 256 generated tokens',
    'Write a detailed story about a lighthouse keeper who finds a message in a bottle.',
    256,
  ),
  PerfScenario(
    'long_prompt',
    'Long prompt (~2k tokens), up to 128 generated tokens',
    '$longContext\n\nSummarize the text above in five bullet points.',
    128,
  ),
];

class PerfRun {
  final String scenario;
  final int rep;
  final int promptTokens;
  final int generatedTokens;
  final double? ttftMs;
  final double? decodeTokPerSec;
  final double? prefillTokPerSec;
  final double totalMs;
  final String? error;

  PerfRun({
    required this.scenario,
    required this.rep,
    required this.promptTokens,
    required this.generatedTokens,
    required this.ttftMs,
    required this.decodeTokPerSec,
    required this.prefillTokPerSec,
    required this.totalMs,
    this.error,
  });

  Map<String, dynamic> toJson() => {
    'scenario': scenario,
    'rep': rep,
    'prompt_tokens': promptTokens,
    'generated_tokens': generatedTokens,
    'ttft_ms': ttftMs?.round(),
    'decode_tok_per_sec': _r(decodeTokPerSec),
    'prefill_tok_per_sec': _r(prefillTokPerSec),
    'total_ms': totalMs.round(),
    if (error != null) 'error': error,
  };
}

double? _r(double? v) => v == null ? null : double.parse(v.toStringAsFixed(2));

class PerfSummary {
  final String scenario;
  final double ttftMs;
  final double decodeTokPerSec;
  final double prefillTokPerSec;
  PerfSummary(this.scenario, this.ttftMs, this.decodeTokPerSec, this.prefillTokPerSec);

  Map<String, dynamic> toJson() => {
    'scenario': scenario,
    'median_ttft_ms': ttftMs.isNaN ? null : ttftMs.round(),
    'median_decode_tok_per_sec': _r(decodeTokPerSec.isNaN ? null : decodeTokPerSec),
    'median_prefill_tok_per_sec': _r(prefillTokPerSec.isNaN ? null : prefillTokPerSec),
  };
}

class PerfResult {
  final double loadMs;
  final List<PerfRun> runs;
  PerfResult(this.loadMs, this.runs);

  PerfSummary summary(String scenario) {
    final xs = runs.where((r) => r.scenario == scenario && r.error == null);
    return PerfSummary(
      scenario,
      median([for (final r in xs) if (r.ttftMs != null) r.ttftMs!]),
      median([for (final r in xs) if (r.decodeTokPerSec != null) r.decodeTokPerSec!]),
      median([for (final r in xs) if (r.prefillTokPerSec != null) r.prefillTokPerSec!]),
    );
  }

  List<String> get scenarios => {for (final r in runs) r.scenario}.toList();

  Map<String, dynamic> summaryJson() => {
    'model_load_ms': loadMs.round(),
    for (final s in scenarios) s: summary(s).toJson(),
  };
}

/// TTFT = time from `ask()` to the first streamed token (includes prompt
/// processing). Decode speed = (tokens − 1) / (last token − first token).
/// Prefill speed = prompt tokens / TTFT. A fresh chat (empty KV cache) is
/// used for every run so prefix caching doesn't flatter TTFT.
Future<PerfResult> runPerformance({
  required nw.Model model,
  required double loadMs,
  required List<PerfScenario> scenarios,
  required BenchSettings settings,
  required CancelToken cancel,
  required void Function(String msg, double progress) onProgress,
}) async {
  nw.Chat freshChat() => nw.Chat(
    model: model,
    contextSize: settings.contextSize,
    templateVariables: {'enable_thinking': false},
    sampler: nw.SamplerPresets.greedy(),
  );

  // Warm-up (Metal shader compilation, caches) — not recorded.
  onProgress('warm-up…', 0);
  await generate(freshChat(), 'Say hello.', maxTokens: 16, cancel: cancel);

  final runs = <PerfRun>[];
  final total = scenarios.length * settings.perfRepetitions;
  var done = 0;
  for (final s in scenarios) {
    for (var rep = 1; rep <= settings.perfRepetitions; rep++) {
      final chat = freshChat();
      final promptTokens = (await chat.tokenize(s.prompt)).length;
      final gen = await generate(chat, s.prompt, maxTokens: s.maxTokens, cancel: cancel);
      final decode = (gen.decodeMs != null && gen.decodeMs! > 0 && gen.chunks > 1)
          ? (gen.chunks - 1) / (gen.decodeMs! / 1000)
          : null;
      final prefill = (gen.ttftMs != null && gen.ttftMs! > 0)
          ? promptTokens / (gen.ttftMs! / 1000)
          : null;
      runs.add(PerfRun(
        scenario: s.id,
        rep: rep,
        promptTokens: promptTokens,
        generatedTokens: gen.chunks,
        ttftMs: gen.ttftMs,
        decodeTokPerSec: decode,
        prefillTokPerSec: prefill,
        totalMs: gen.totalMs,
        error: gen.error,
      ));
      done++;
      onProgress(
        '[${s.id} #$rep] TTFT ${fmt(gen.ttftMs, 0)} ms · ${fmt(decode)} tok/s · prefill ${fmt(prefill, 0)} tok/s',
        done / total,
      );
    }
  }
  return PerfResult(loadMs, runs);
}
