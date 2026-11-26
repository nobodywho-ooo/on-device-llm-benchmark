import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves the benchmark root folder (the one containing `models/` and
/// `results/`).
///
/// Order: `--dart-define=BENCH_ROOT=...`, then walk up from the running
/// executable to find this project's `pubspec.yaml` (works for `flutter run`
/// builds, which live in `<repo>/build/...`), then `~/Documents/llm-bench`.
String resolveBenchRoot() {
  const defined = String.fromEnvironment('BENCH_ROOT');
  if (defined.isNotEmpty) return defined;

  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 12; i++) {
    final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('name: llm_bench')) {
      return dir.path;
    }
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }

  final home = Platform.environment['HOME'] ?? '.';
  return p.join(home, 'Documents', 'llm-bench');
}

class BenchPaths {
  final String root;
  BenchPaths(this.root);

  String get modelsDir => p.join(root, 'models');
  String get embeddingDir => p.join(modelsDir, 'embedding');
  String get resultsDir => p.join(root, 'results');

  /// Default embedding model if none is dropped in `models/embedding/`.
  /// Downloaded once by NobodyWho and cached; everything else stays offline.
  static const defaultEmbeddingModel =
      'hf://CompendiumLabs/bge-small-en-v1.5-gguf/bge-small-en-v1.5-q8_0.gguf';

  Future<void> ensure() async {
    await Directory(modelsDir).create(recursive: true);
    await Directory(embeddingDir).create(recursive: true);
    await Directory(resultsDir).create(recursive: true);
  }

  /// Chat models: every `.gguf` directly inside `models/`, excluding
  /// projection (`mmproj`) files.
  List<File> listChatModels() {
    final dir = Directory(modelsDir);
    if (!dir.existsSync()) return [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.gguf'))
        .where((f) => !p.basename(f.path).toLowerCase().contains('mmproj'))
        .toList()
      ..sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));
    return files;
  }

  String embeddingModelSource() {
    final dir = Directory(embeddingDir);
    if (dir.existsSync()) {
      final local = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.gguf'))
          .toList();
      if (local.isNotEmpty) return local.first.path;
    }
    return defaultEmbeddingModel;
  }
}
