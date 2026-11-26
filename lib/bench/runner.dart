import 'dart:io';

import 'package:nobodywho/nobodywho.dart' as nw;
import 'package:path/path.dart' as p;

import 'agentic.dart';
import 'generate.dart';
import 'gguf.dart';
import 'knowledge.dart';
import 'paths.dart';
import 'performance.dart';
import 'report.dart';
import 'settings.dart';

class ModelEntry {
  final File file;
  GgufInfo? info;
  String? error;
  bool selected = true;
  ModelEntry(this.file);

  String get fileName => p.basename(file.path);
}

class ModelReport {
  final ModelEntry entry;
  double? loadMs;
  KnowledgeResult? knowledge;
  PerfResult? performance;
  AgenticResult? agentic;
  String? error;
  ModelReport(this.entry);

  String get displayName => entry.fileName.replaceAll(RegExp(r'\.gguf$', caseSensitive: false), '');
  double? get paramsB => entry.info?.paramsBillions;
}

class RunReport {
  final DateTime startedAt;
  final BenchSettings settings;
  final Map<String, String> machine;
  final String? embeddingModel;
  final List<ModelReport> models = [];
  ParamsEquivalence? equivalence;
  DateTime? finishedAt;
  bool cancelled = false;

  RunReport(this.startedAt, this.settings, this.machine, this.embeddingModel);
}

typedef LogFn = void Function(String line);
typedef ProgressFn = void Function(String status, double overall);

Future<List<ModelEntry>> scanModels(BenchPaths paths) async {
  await paths.ensure();
  final entries = [for (final f in paths.listChatModels()) ModelEntry(f)];
  for (final e in entries) {
    try {
      e.info = await readGguf(e.file.path);
    } catch (err) {
      e.error = err.toString();
      e.selected = false;
    }
  }
  return entries;
}

Future<Map<String, String>> machineInfo() async {
  Future<String> sysctl(String key) async {
    try {
      final r = await Process.run('sysctl', ['-n', key]);
      return (r.stdout as String).trim();
    } catch (_) {
      return '?';
    }
  }

  final mem = int.tryParse(await sysctl('hw.memsize'));
  return {
    'cpu': await sysctl('machdep.cpu.brand_string'),
    'memory_gb': mem == null ? '?' : (mem / (1 << 30)).toStringAsFixed(0),
    'os': Platform.operatingSystemVersion,
    'cores': Platform.numberOfProcessors.toString(),
  };
}

class BenchRunner {
  final BenchPaths paths;
  final KnowledgeDataset dataset;
  final BenchSettings settings;
  final CancelToken cancel;
  final LogFn log;
  final ProgressFn progress;

  BenchRunner({
    required this.paths,
    required this.dataset,
    required this.settings,
    required this.cancel,
    required this.log,
    required this.progress,
  });

  Future<(RunReport, String)> run(List<ModelEntry> models) async {
    final embeddingSource = settings.runKnowledge ? paths.embeddingModelSource() : null;
    final report = RunReport(DateTime.now(), settings, await machineInfo(), embeddingSource);
    final outDir = await createRunDir(paths.resultsDir, report.startedAt);
    log('Results → $outDir');

    nw.Encoder? encoder;
    RagIndex? rag;
    try {
      if (settings.runKnowledge) {
        progress('Loading embedding model…', 0);
        log('Embedding model: $embeddingSource');
        encoder = await nw.Encoder.fromPath(
          modelPath: embeddingSource!,
          onDownloadProgress: (d, t) => progress(
            'Downloading embedding model ${(d / (1 << 20)).toStringAsFixed(0)}/${(t / (1 << 20)).toStringAsFixed(0)} MB',
            0,
          ),
        );
        rag = await RagIndex.build(encoder, dataset.corpus);
        log('RAG index: ${dataset.corpus.length} passages embedded');
      }

      for (var mi = 0; mi < models.length; mi++) {
        if (cancel.isCancelled) break;
        final entry = models[mi];
        final mr = ModelReport(entry);
        report.models.add(mr);
        final base = mi / models.length;
        final span = 1 / models.length;
        final suites = [
          if (settings.runPerformance) 'perf',
          if (settings.runKnowledge) 'knowledge',
          if (settings.runAgentic) 'agentic',
        ];
        void suiteProgress(int idx, String label, double p) => progress(
          '${entry.fileName} · $label',
          base + span * ((idx + p) / (suites.isEmpty ? 1 : suites.length)),
        );

        log('');
        log('━━ ${entry.fileName}  (${entry.info?.paramsBillions.toStringAsFixed(2)}B params, ${entry.info?.quantization})');
        nw.Model? model;
        try {
          progress('Loading ${entry.fileName}…', base);
          final sw = Stopwatch()..start();
          model = await nw.Model.load(modelPath: entry.file.path, useGpu: true);
          mr.loadMs = sw.elapsedMilliseconds.toDouble();
          log('Loaded in ${mr.loadMs!.round()} ms');

          var si = 0;
          if (settings.runPerformance) {
            log('▸ Performance');
            mr.performance = await runPerformance(
              model: model,
              loadMs: mr.loadMs!,
              scenarios: buildScenarios(_longContext()),
              settings: settings,
              cancel: cancel,
              onProgress: (m, p) {
                log('  $m');
                suiteProgress(si, 'performance', p);
              },
            );
            si++;
          }
          if (settings.runKnowledge) {
            log('▸ Knowledge (closed-book + RAG)');
            mr.knowledge = await runKnowledge(
              model: model,
              dataset: dataset,
              rag: rag,
              settings: settings,
              cancel: cancel,
              onProgress: (m, p) {
                log('  $m');
                suiteProgress(si, 'knowledge', p);
              },
            );
            final k = mr.knowledge!;
            log('  closed-book ${_pct(k.accuracy('closed_book', 'general'))} → RAG ${_pct(k.accuracy('rag', 'general'))} (general)');
            si++;
          }
          if (settings.runAgentic) {
            log('▸ Agentic (tool calling)');
            mr.agentic = await runAgentic(
              model: model,
              settings: settings,
              cancel: cancel,
              onProgress: (m, p) {
                log('  $m');
                suiteProgress(si, 'agentic', p);
              },
            );
            log('  pass rate ${_pct(mr.agentic!.passRate)}');
            si++;
          }
        } on CancelledException {
          mr.error = 'cancelled';
          report.cancelled = true;
        } catch (e) {
          mr.error = e.toString();
          log('  ERROR: $e');
        } finally {
          model?.dispose();
        }
        await writeModelPartial(outDir, mr);
      }
    } finally {
      encoder?.dispose();
    }

    report.cancelled = report.cancelled || cancel.isCancelled;
    report.equivalence = ParamsEquivalence.fit([
      for (final m in report.models)
        if (m.paramsB != null && m.knowledge?.accuracy('closed_book', 'general') != null)
          (m.paramsB!, m.knowledge!.accuracy('closed_book', 'general')!),
    ]);
    report.finishedAt = DateTime.now();
    await writeReport(outDir, report, dataset);
    progress(report.cancelled ? 'Cancelled — partial results saved' : 'Done', 1);
    log('');
    log('Saved: ${p.join(outDir, 'report.md')}');
    return (report, outDir);
  }

  String _longContext() => [for (final d in dataset.corpus) '${d.title}. ${d.text}'].join('\n');
}

String _pct(double? v) => v == null ? '–' : '${(v * 100).toStringAsFixed(0)}%';
