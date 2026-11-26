import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'agentic.dart';
import 'knowledge.dart';
import 'runner.dart';
import 'text_utils.dart';

Future<String> createRunDir(String resultsDir, DateTime t) async {
  String two(int x) => x.toString().padLeft(2, '0');
  final name = '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  final dir = Directory(p.join(resultsDir, name));
  await dir.create(recursive: true);
  return dir.path;
}

Map<String, dynamic> modelJson(ModelReport m, RunReport? r) {
  final cbGen = m.knowledge?.accuracy('closed_book', 'general');
  final ragGen = m.knowledge?.accuracy('rag', 'general');
  final eq = r?.equivalence;
  return {
    'model': m.displayName,
    'file': m.entry.fileName,
    'gguf': m.entry.info?.toJson(),
    'load_ms': m.loadMs?.round(),
    if (m.error != null) 'error': m.error,
    if (m.performance != null) 'performance': {
      'summary': m.performance!.summaryJson(),
      'runs': [for (final x in m.performance!.runs) x.toJson()],
    },
    if (m.knowledge != null) 'knowledge': {
      'summary': {
        ...m.knowledge!.summaryJson(),
        if (eq != null && ragGen != null && m.paramsB != null) ...{
          'rag_equivalent_closed_book_params_b': _r3(eq.equivalentParamsB(ragGen)),
          'params_added_by_rag_b': _r3(eq.equivalentParamsB(ragGen) - m.paramsB!),
        },
        'rag_gain_general': (cbGen != null && ragGen != null) ? ragGen - cbGen : null,
      },
      'answers': [for (final a in m.knowledge!.answers) a.toJson()],
    },
    if (m.agentic != null) 'agentic': {
      'summary': m.agentic!.summaryJson(),
      'cases': [for (final c in m.agentic!.cases) c.toJson()],
    },
  };
}

double _r3(double v) => double.parse(v.toStringAsFixed(3));

Future<void> writeModelPartial(String outDir, ModelReport m) async {
  final f = File(p.join(outDir, 'models', '${m.displayName}.json'));
  await f.parent.create(recursive: true);
  await f.writeAsString(const JsonEncoder.withIndent('  ').convert(modelJson(m, null)));
}

Future<void> writeReport(String outDir, RunReport r, KnowledgeDataset ds) async {
  final eq = r.equivalence;
  final json = {
    'started_at': r.startedAt.toIso8601String(),
    'finished_at': r.finishedAt?.toIso8601String(),
    'cancelled': r.cancelled,
    'machine': r.machine,
    'settings': r.settings.toJson(),
    'embedding_model': r.embeddingModel,
    'params_equivalence_fit': eq == null
        ? null
        : {'formula': 'closed_book_accuracy = a + b * log10(params_billions)', 'a': eq.a, 'b': eq.b, 'n_models': eq.n},
    'models': [for (final m in r.models) modelJson(m, r)],
  };
  await File(p.join(outDir, 'results.json'))
      .writeAsString(const JsonEncoder.withIndent('  ').convert(json));
  await File(p.join(outDir, 'report.md')).writeAsString(buildMarkdown(r, ds));
  await _writeCsvs(outDir, r);
}

String _pct(double? v) => v == null || v.isNaN ? '–' : '${(v * 100).toStringAsFixed(0)}%';

String buildMarkdown(RunReport r, KnowledgeDataset ds) {
  final sb = StringBuffer();
  final eq = r.equivalence;
  sb.writeln('# On-device LLM benchmark — ${r.startedAt.toIso8601String().substring(0, 16).replaceAll('T', ' ')}');
  sb.writeln();
  sb.writeln('Machine: ${r.machine['cpu']}, ${r.machine['memory_gb']} GB RAM · ${r.machine['os']}  ');
  sb.writeln('Engine: NobodyWho (llama.cpp, Metal) · thinking ${r.settings.enableThinking ? 'on' : 'off'} · '
      'context ${r.settings.contextSize} · greedy sampling${r.cancelled ? ' · **run cancelled (partial)**' : ''}');
  sb.writeln();

  // ---- Summary
  sb.writeln('## Summary');
  sb.writeln();
  sb.writeln('| Model | Params | Quant | File | Load | TTFT short | TTFT long | Decode | Prefill | Closed-book | RAG | RAG ≈ closed-book size | Agentic |');
  sb.writeln('|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|');
  for (final m in r.models) {
    final i = m.entry.info;
    final perf = m.performance;
    final short = perf?.summary('short_prompt');
    final long = perf?.summary('long_prompt');
    final cb = m.knowledge?.accuracy('closed_book', 'general');
    final rag = m.knowledge?.accuracy('rag', 'general');
    String eqCell = '–';
    if (eq != null && rag != null && m.paramsB != null) {
      final e = eq.equivalentParamsB(rag);
      eqCell = '${fmt(e, 1)}B (+${fmt(e - m.paramsB!, 1)}B)';
    }
    sb.writeln('| ${m.displayName}${m.error != null ? ' ⚠️' : ''} '
        '| ${fmt(i?.paramsBillions, 2)}B | ${i?.quantization ?? '?'} | ${fmt(i?.fileSizeGb, 2)} GB '
        '| ${m.loadMs == null ? '–' : '${fmt(m.loadMs! / 1000, 1)} s'} '
        '| ${short == null ? '–' : '${fmt(short.ttftMs, 0)} ms'} '
        '| ${long == null ? '–' : '${fmt(long.ttftMs, 0)} ms'} '
        '| ${short == null ? '–' : '${fmt(short.decodeTokPerSec)} tok/s'} '
        '| ${long == null ? '–' : '${fmt(long.prefillTokPerSec, 0)} tok/s'} '
        '| ${_pct(cb)} | ${_pct(rag)} | $eqCell '
        '| ${m.agentic == null ? '–' : _pct(m.agentic!.passRate)} |');
  }
  sb.writeln();
  sb.writeln('- **TTFT**: time from sending the prompt to the first streamed token (includes prompt processing), median of ${r.settings.perfRepetitions} runs, fresh context each run. Short ≈ 20-token prompt, long ≈ 2k-token prompt.');
  sb.writeln('- **Decode**: generated tokens/s after the first token (short-prompt scenario). **Prefill**: prompt tokens / TTFT (long-prompt scenario).');
  sb.writeln('- **Closed-book / RAG**: exact-match accuracy on ${ds.questions.where((q) => q.category == 'general').length} general-knowledge questions, without and with top-${r.settings.ragTopK} passages retrieved from the local corpus (embedding model: `${r.embeddingModel ?? '–'}`).');
  if (eq != null) {
    sb.writeln('- **RAG ≈ closed-book size**: fit of closed-book accuracy vs. log10(params) over the ${eq.n} models in this run '
        '(acc = ${eq.a.toStringAsFixed(3)} + ${eq.b.toStringAsFixed(3)}·log10(B)), inverted at each model\'s RAG accuracy. '
        'It answers "how big a model without retrieval would need to be to match this model with retrieval". '
        'Values far outside the range of model sizes tested are extrapolations — treat them as indicative.');
  } else {
    sb.writeln('- **RAG ≈ closed-book size** needs ≥ 2 models of different sizes whose closed-book accuracy increases with size.');
  }
  sb.writeln();

  // ---- Knowledge details
  final withK = r.models.where((m) => m.knowledge != null).toList();
  if (withK.isNotEmpty) {
    sb.writeln('## Knowledge');
    sb.writeln();
    sb.writeln('| Model | Closed-book (general) | RAG (general) | Gain | Closed-book (private docs) | RAG (private docs) | Retrieval recall@${r.settings.ragTopK} |');
    sb.writeln('|---|---:|---:|---:|---:|---:|---:|');
    for (final m in withK) {
      final k = m.knowledge!;
      final cb = k.accuracy('closed_book', 'general'), rag = k.accuracy('rag', 'general');
      sb.writeln('| ${m.displayName} | ${_pct(cb)} | ${_pct(rag)} | '
          '${cb != null && rag != null ? '${((rag - cb) * 100).toStringAsFixed(0)} pts' : '–'} | '
          '${_pct(k.accuracy('closed_book', 'private'))} | ${_pct(k.accuracy('rag', 'private'))} | ${_pct(k.retrievalRecall)} |');
    }
    sb.writeln();
    sb.writeln('<details><summary>Per-question results (CB = closed-book, R = RAG)</summary>');
    sb.writeln();
    sb.writeln('| Question | Expected | ${withK.map((m) => m.displayName).join(' | ')} |');
    sb.writeln('|---|---|${withK.map((_) => '---').join('|')}|');
    for (final q in ds.questions) {
      final cells = withK.map((m) {
        bool? res(String mode) {
          final a = m.knowledge!.answers.where((a) => a.q.id == q.id && a.mode == mode);
          return a.isEmpty ? null : a.first.correct;
        }
        String mark(bool? b) => b == null ? '·' : (b ? '✓' : '✗');
        return 'CB ${mark(res('closed_book'))} R ${mark(res('rag'))}';
      });
      sb.writeln('| ${_md(q.question)} | ${_md(q.answers.first)} | ${cells.join(' | ')} |');
    }
    sb.writeln();
    sb.writeln('</details>');
    sb.writeln();
  }

  // ---- Agentic details
  final withA = r.models.where((m) => m.agentic != null).toList();
  if (withA.isNotEmpty) {
    sb.writeln('## Agentic (tool calling)');
    sb.writeln();
    sb.writeln('| Model | Pass rate | Check score | Tool cases | No-tool cases |');
    sb.writeln('|---|---:|---:|---:|---:|');
    for (final m in withA) {
      final a = m.agentic!;
      sb.writeln('| ${m.displayName} | ${_pct(a.passRate)} | ${_pct(a.meanScore)} | ${_pct(a.toolCasePassRate)} | ${_pct(a.noToolCasePassRate)} |');
    }
    sb.writeln();
    sb.writeln('| Case | Expected | ${withA.map((m) => m.displayName).join(' | ')} |');
    sb.writeln('|---|---|${withA.map((_) => '---').join('|')}|');
    for (final c in agenticCases) {
      final cells = withA.map((m) {
        final res = m.agentic!.cases.where((x) => x.c.id == c.id);
        if (res.isEmpty) return '·';
        final x = res.first;
        final calls = x.calls.isEmpty ? '_none_' : x.calls.map((k) => '`${_md(k.toString())}`').join(' → ');
        return '${x.passed ? '✓' : '✗'} $calls';
      });
      final exp = c.expectsNoTools ? '_no tool_' : c.expected.map((e) => '`${e.name}`').join(' → ');
      sb.writeln('| ${_md(c.prompt)} | $exp | ${cells.join(' | ')} |');
    }
    sb.writeln();
  }

  // ---- Errors
  final errs = r.models.where((m) => m.error != null);
  if (errs.isNotEmpty) {
    sb.writeln('## Errors');
    sb.writeln();
    for (final m in errs) {
      sb.writeln('- ${m.displayName}: ${m.error}');
    }
    sb.writeln();
  }
  return sb.toString();
}

String _md(String s) => s.replaceAll('|', '\\|').replaceAll('\n', ' ');

String _csv(Object? v) {
  final s = v?.toString() ?? '';
  return '"${s.replaceAll('"', '""')}"';
}

Future<void> _writeCsvs(String outDir, RunReport r) async {
  final k = StringBuffer('model,question_id,category,mode,question,expected,answer,correct,ttft_ms,total_ms,retrieval_hit\n');
  final a = StringBuffer('model,case_id,prompt,passed,score,calls,failed_checks,answer\n');
  final pr = StringBuffer('model,scenario,rep,prompt_tokens,generated_tokens,ttft_ms,decode_tok_per_sec,prefill_tok_per_sec,total_ms\n');
  for (final m in r.models) {
    for (final x in m.knowledge?.answers ?? const <KnowledgeAnswer>[]) {
      k.writeln([
        m.displayName, x.q.id, x.q.category, x.mode, x.q.question, x.q.answers.join(' / '),
        x.gen.text, x.correct, x.gen.ttftMs?.round(), x.gen.totalMs.round(),
        x.mode == 'rag' ? x.retrievalHit : '',
      ].map(_csv).join(','));
    }
    for (final x in m.agentic?.cases ?? const <AgenticCaseResult>[]) {
      a.writeln([
        m.displayName, x.c.id, x.c.prompt, x.passed, x.score.toStringAsFixed(3),
        x.calls.join(' -> '),
        x.checks.where((c) => !c.passed).map((c) => '${c.check}${c.detail == null ? '' : ' (${c.detail})'}').join('; '),
        x.gen.text,
      ].map(_csv).join(','));
    }
    for (final x in m.performance?.runs ?? const []) {
      pr.writeln([
        m.displayName, x.scenario, x.rep, x.promptTokens, x.generatedTokens, x.ttftMs?.round(),
        x.decodeTokPerSec?.toStringAsFixed(2), x.prefillTokPerSec?.toStringAsFixed(2), x.totalMs.round(),
      ].map(_csv).join(','));
    }
  }
  await File(p.join(outDir, 'knowledge_answers.csv')).writeAsString(k.toString());
  await File(p.join(outDir, 'agentic_calls.csv')).writeAsString(a.toString());
  await File(p.join(outDir, 'performance_runs.csv')).writeAsString(pr.toString());
}
