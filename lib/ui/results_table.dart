import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../bench/runner.dart';
import '../bench/text_utils.dart';

String _pct(double? v) => v == null || v.isNaN ? '–' : '${(v * 100).toStringAsFixed(0)}%';

class ResultsTable extends StatelessWidget {
  final RunReport report;
  const ResultsTable({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final eq = report.equivalence;
    const headers = [
      'Model', 'Params', 'Quant', 'TTFT short', 'TTFT long', 'Decode', 'Prefill',
      'Closed-book', 'RAG', 'RAG ≈ size', 'Agentic',
    ];
    const widths = [260.0, 80.0, 90.0, 100.0, 100.0, 100.0, 110.0, 110.0, 80.0, 150.0, 90.0];

    final rows = <List<String>>[
      for (final m in report.models)
        () {
          final short = m.performance?.summary('short_prompt');
          final long = m.performance?.summary('long_prompt');
          final cb = m.knowledge?.accuracy('closed_book', 'general');
          final rag = m.knowledge?.accuracy('rag', 'general');
          var eqCell = '–';
          if (eq != null && rag != null && m.paramsB != null) {
            final e = eq.equivalentParamsB(rag);
            eqCell = '${fmt(e, 1)}B (+${fmt(e - m.paramsB!, 1)}B)';
          }
          return [
            '${m.displayName}${m.error != null ? '  ⚠ ${m.error}' : ''}',
            '${fmt(m.paramsB, 2)}B',
            m.entry.info?.quantization ?? '?',
            short == null ? '–' : '${fmt(short.ttftMs, 0)} ms',
            long == null ? '–' : '${fmt(long.ttftMs, 0)} ms',
            short == null ? '–' : '${fmt(short.decodeTokPerSec)} t/s',
            long == null ? '–' : '${fmt(long.prefillTokPerSec, 0)} t/s',
            _pct(cb),
            _pct(rag),
            eqCell,
            m.agentic == null ? '–' : _pct(m.agentic!.passRate),
          ];
        }(),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ShadTable.list(
            columnSpanExtent: (i) => FixedTableSpanExtent(widths[i]),
            header: [for (final h in headers) ShadTableCell.header(child: Text(h))],
            children: [
              for (final r in rows) [for (final c in r) ShadTableCell(child: Text(c, overflow: TextOverflow.ellipsis))],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          eq == null
              ? 'RAG ≈ size needs ≥ 2 models of different sizes (closed-book accuracy must grow with size).'
              : 'RAG ≈ size: closed-book model size needed to match the RAG accuracy, from a log-linear fit over ${eq.n} models. Full details in report.md / results.json.',
          style: theme.textTheme.muted,
        ),
      ],
    );
  }
}
