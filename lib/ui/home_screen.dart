import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../bench/generate.dart';
import '../bench/knowledge.dart';
import '../bench/paths.dart';
import '../bench/runner.dart';
import '../bench/settings.dart';
import '../bench/text_utils.dart';
import 'results_table.dart';

const _autorun = bool.fromEnvironment('AUTORUN');

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum _Pane { log, results }

class _HomeScreenState extends State<HomeScreen> {
  final paths = BenchPaths(resolveBenchRoot());
  final settings = BenchSettings();
  final _log = <String>[];
  final _logScroll = ScrollController();

  List<ModelEntry> _models = [];
  KnowledgeDataset? _dataset;
  bool _scanning = false;
  bool _running = false;
  CancelToken? _cancel;
  String _status = 'Idle';
  double _progress = 0;
  RunReport? _lastReport;
  String? _lastOutDir;
  _Pane _pane = _Pane.log;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final raw = await rootBundle.loadString('assets/data/knowledge.json');
    _dataset = KnowledgeDataset.fromJson(raw);
    await _scan();
    if (_autorun && _models.any((m) => m.selected)) {
      await _run();
      exit(0);
    }
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final models = await scanModels(paths);
    setState(() {
      _models = models;
      _scanning = false;
    });
  }

  void _addLog(String line) {
    setState(() => _log.add(line));
    if (_autorun) stdout.writeln(line);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _run() async {
    final selected = _models.where((m) => m.selected).toList();
    if (selected.isEmpty || _dataset == null) return;
    final cancel = CancelToken();
    setState(() {
      _running = true;
      _cancel = cancel;
      _log.clear();
      _progress = 0;
      _pane = _Pane.log;
    });
    try {
      final runner = BenchRunner(
        paths: paths,
        dataset: _dataset!,
        settings: settings,
        cancel: cancel,
        log: _addLog,
        progress: (s, v) => setState(() {
          _status = s;
          _progress = v.clamp(0, 1);
        }),
      );
      final (report, outDir) = await runner.run(selected);
      setState(() {
        _lastReport = report;
        _lastOutDir = outDir;
        _pane = _Pane.results;
      });
    } catch (e) {
      _addLog('FATAL: $e');
      setState(() => _status = 'Failed: $e');
    } finally {
      setState(() {
        _running = false;
        _cancel = null;
      });
    }
  }

  void _open(String path) => Process.run('open', [path]);

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.background,
      body: Column(
        children: [
          _header(theme),
          const Divider(height: 1),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 380, child: _sidebar(theme)),
                const VerticalDivider(width: 1),
                Expanded(child: _main(theme)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(ShadThemeData theme) {
    final selectedCount = _models.where((m) => m.selected).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'On-device LLM Benchmark',
              style: theme.textTheme.h4,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 16),
          ShadButton.outline(
            leading: const Icon(LucideIcons.folderOpen, size: 16),
            onPressed: () => _open(paths.modelsDir),
            child: const Text('Models folder'),
          ),
          const SizedBox(width: 8),
          ShadButton.outline(
            leading: const Icon(LucideIcons.fileChartColumn, size: 16),
            onPressed: () => _open(_lastOutDir ?? paths.resultsDir),
            child: const Text('Results'),
          ),
          const SizedBox(width: 16),
          ShadSwitch(
            value: settings.enableThinking,
            onChanged: _running
                ? null
                : (v) => setState(() => settings.enableThinking = v),
            label: const Text('Allow thinking'),
          ),
          const SizedBox(width: 16),
          if (_running)
            ShadButton.destructive(
              leading: const Icon(LucideIcons.square, size: 16),
              onPressed: () {
                _cancel?.cancel();
                setState(() => _status = 'Stopping…');
              },
              child: const Text('Stop'),
            )
          else
            ShadButton(
              leading: const Icon(LucideIcons.play, size: 16),
              onPressed:
                  selectedCount == 0 ||
                      !(settings.runKnowledge ||
                          settings.runPerformance ||
                          settings.runAgentic)
                  ? null
                  : _run,
              child: Text(
                'Run on $selectedCount model${selectedCount == 1 ? '' : 's'}',
              ),
            ),
        ],
      ),
    );
  }

  Widget _sidebar(ShadThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ShadCard(
          title: Row(
            children: [
              const Text('Models'),
              const Spacer(),
              ShadIconButton.ghost(
                icon: _scanning
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(LucideIcons.refreshCw, size: 16),
                onPressed: _running ? null : _scan,
              ),
            ],
          ),
          description: Text('Every .gguf in models folder'),
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _models.isEmpty
                ? ShadAlert(
                    icon: const Icon(LucideIcons.info),
                    title: const Text('No models found'),
                    description: Text(
                      'Drop .gguf files into\n${paths.modelsDir}\nthen press refresh.',
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final m in _models)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: ShadCheckbox(
                            value: m.selected,
                            onChanged: _running || m.info == null
                                ? null
                                : (v) => setState(() => m.selected = v),
                            label: Text(
                              m.fileName,
                              overflow: TextOverflow.ellipsis,
                            ),
                            sublabel: Text(
                              m.info == null
                                  ? 'Unreadable: ${m.error}'
                                  : '${fmt(m.info!.paramsBillions, 2)}B params · ${m.info!.quantization ?? '?'} · '
                                        '${fmt(m.info!.fileSizeGb, 2)} GB · ${m.info!.architecture ?? '?'}',
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 16),
        ShadCard(
          title: const Text('Suites'),
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _check(
                  'Performance',
                  'TTFT, decode & prefill tok/s (short + ~2k-token prompt)',
                  settings.runPerformance,
                  (v) => settings.runPerformance = v,
                ),
                _check(
                  'General knowledge',
                  '${_dataset?.questions.length ?? 0} questions, closed-book vs. offline RAG',
                  settings.runKnowledge,
                  (v) => settings.runKnowledge = v,
                ),
                _check(
                  'Agentic',
                  'Tool selection, order & arguments (12 cases)',
                  settings.runAgentic,
                  (v) => settings.runAgentic = v,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _check(String label, String sub, bool value, void Function(bool) set) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ShadCheckbox(
        value: value,
        onChanged: _running ? null : (v) => setState(() => set(v)),
        label: Text(label),
        sublabel: Text(sub),
      ),
    );
  }

  Widget _main(ShadThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ShadCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (_running)
                      const Padding(
                        padding: EdgeInsets.only(right: 10),
                        child: SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        _status,
                        style: theme.textTheme.small,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${(_progress * 100).toStringAsFixed(0)}%',
                      style: theme.textTheme.muted,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ShadProgress(value: _progress),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _paneButton('Live log', LucideIcons.terminal, _Pane.log),
              const SizedBox(width: 6),
              _paneButton('Results', LucideIcons.chartBar, _Pane.results),
              const Spacer(),
              if (_lastOutDir != null)
                ShadButton.link(
                  onPressed: () => _open(p.join(_lastOutDir!, 'report.md')),
                  child: const Text('Open report.md'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ShadCard(
              padding: const EdgeInsets.all(12),
              child: switch (_pane) {
                _Pane.log => _logView(theme),
                _Pane.results =>
                  _lastReport == null
                      ? Center(
                          child: Text(
                            'Run the benchmark to see results here.',
                            style: theme.textTheme.muted,
                          ),
                        )
                      : ResultsTable(report: _lastReport!),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _paneButton(String label, IconData icon, _Pane pane) {
    final active = _pane == pane;
    final child = Text(label);
    final leading = Icon(icon, size: 16);
    void onPressed() => setState(() => _pane = pane);
    return active
        ? ShadButton.secondary(
            size: ShadButtonSize.sm,
            leading: leading,
            onPressed: onPressed,
            child: child,
          )
        : ShadButton.ghost(
            size: ShadButtonSize.sm,
            leading: leading,
            onPressed: onPressed,
            child: child,
          );
  }

  Widget _logView(ShadThemeData theme) {
    if (_log.isEmpty) {
      return Center(
        child: Text(
          'Select models and press Run.',
          style: theme.textTheme.muted,
        ),
      );
    }
    return SelectionArea(
      child: ListView.builder(
        controller: _logScroll,
        itemCount: _log.length,
        itemBuilder: (_, i) => Text(
          _log[i],
          style: theme.textTheme.small.copyWith(
            fontFamily: 'Menlo',
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}
