import 'dart:convert';
import 'dart:math' as math;

import 'package:nobodywho/nobodywho.dart' as nw;

import 'generate.dart';
import 'settings.dart';
import 'text_utils.dart';

class KnowledgeDoc {
  final String title;
  final String text;
  KnowledgeDoc(this.title, this.text);
}

class KnowledgeQuestion {
  final String id;
  final String category;
  final String question;
  final List<String> answers;
  final String source;
  KnowledgeQuestion(this.id, this.category, this.question, this.answers, this.source);
}

class KnowledgeDataset {
  final List<KnowledgeDoc> corpus;
  final List<KnowledgeQuestion> questions;
  KnowledgeDataset(this.corpus, this.questions);

  factory KnowledgeDataset.fromJson(String source) {
    final j = jsonDecode(source) as Map<String, dynamic>;
    return KnowledgeDataset(
      [
        for (final d in j['corpus'] as List)
          KnowledgeDoc(d['title'] as String, d['text'] as String),
      ],
      [
        for (final q in j['questions'] as List)
          KnowledgeQuestion(
            q['id'] as String,
            q['category'] as String,
            q['question'] as String,
            (q['answers'] as List).cast<String>(),
            q['source'] as String,
          ),
      ],
    );
  }
}

/// Local vector index over the knowledge corpus, built with a NobodyWho
/// embedding model. Fully offline once the embedding model is on disk.
class RagIndex {
  final nw.Encoder encoder;
  final List<KnowledgeDoc> docs;
  final List<List<double>> _vectors;

  // bge-*-v1.5 retrieval instruction for queries.
  static const queryPrefix = 'Represent this sentence for searching relevant passages: ';

  RagIndex._(this.encoder, this.docs, this._vectors);

  static Future<RagIndex> build(nw.Encoder encoder, List<KnowledgeDoc> docs) async {
    final vecs = await encoder.encodeBatch(
      texts: [for (final d in docs) '${d.title}. ${d.text}'],
    );
    return RagIndex._(encoder, docs, [for (final v in vecs) v.toList()]);
  }

  Future<List<KnowledgeDoc>> search(String query, int k) async {
    final q = (await encoder.encode(text: '$queryPrefix$query')).toList();
    final scored = <(KnowledgeDoc, double)>[
      for (var i = 0; i < docs.length; i++)
        (docs[i], nw.cosineSimilarity(a: q, b: _vectors[i])),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final s in scored.take(k)) s.$1];
  }
}

const closedBookSystemPrompt =
    'Answer the quiz question. Reply with only the answer itself '
    '(for example: Paris, 1945, or Albert Einstein) and nothing else. '
    'If unsure, give your best guess.';

const ragSystemPrompt =
    'Answer the quiz question using the reference passages provided. Reply '
    'with only the answer itself (for example: Paris, 1945, or Albert Einstein) '
    'and nothing else.';

String ragPrompt(String question, List<KnowledgeDoc> ctx) {
  final sb = StringBuffer('Reference passages:\n');
  for (var i = 0; i < ctx.length; i++) {
    sb.writeln('[${i + 1}] ${ctx[i].title}: ${ctx[i].text}');
  }
  sb
    ..writeln()
    ..write('Question: $question');
  return sb.toString();
}

class KnowledgeAnswer {
  final KnowledgeQuestion q;
  final String mode; // closed_book | rag
  final GenResult gen;
  final bool correct;
  final List<String> retrieved;
  KnowledgeAnswer(this.q, this.mode, this.gen, this.correct, this.retrieved);

  bool get retrievalHit => retrieved.contains(q.source);

  Map<String, dynamic> toJson() => {
    'id': q.id,
    'category': q.category,
    'mode': mode,
    'question': q.question,
    'expected': q.answers,
    'answer': gen.text,
    'raw': gen.raw,
    'correct': correct,
    'ttft_ms': gen.ttftMs?.round(),
    'total_ms': gen.totalMs.round(),
    if (mode == 'rag') 'retrieved': retrieved,
    if (mode == 'rag') 'retrieval_hit': retrievalHit,
    if (gen.error != null) 'error': gen.error,
  };
}

class KnowledgeResult {
  final List<KnowledgeAnswer> answers;
  KnowledgeResult(this.answers);

  double? accuracy(String mode, String category) {
    final xs = answers.where((a) => a.mode == mode && a.q.category == category);
    if (xs.isEmpty) return null;
    return xs.where((a) => a.correct).length / xs.length;
  }

  double? get retrievalRecall {
    final xs = answers.where((a) => a.mode == 'rag');
    if (xs.isEmpty) return null;
    return xs.where((a) => a.retrievalHit).length / xs.length;
  }

  Map<String, dynamic> summaryJson() => {
    'closed_book_general': accuracy('closed_book', 'general'),
    'rag_general': accuracy('rag', 'general'),
    'closed_book_private': accuracy('closed_book', 'private'),
    'rag_private': accuracy('rag', 'private'),
    'retrieval_recall_at_k': retrievalRecall,
  };
}

Future<KnowledgeResult> runKnowledge({
  required nw.Model model,
  required KnowledgeDataset dataset,
  required RagIndex? rag,
  required BenchSettings settings,
  required CancelToken cancel,
  required void Function(String msg, double progress) onProgress,
}) async {
  final answers = <KnowledgeAnswer>[];
  final modes = ['closed_book', if (rag != null) 'rag'];
  final total = dataset.questions.length * modes.length;
  var done = 0;

  for (final mode in modes) {
    final chat = nw.Chat(
      model: model,
      systemPrompt: mode == 'rag' ? ragSystemPrompt : closedBookSystemPrompt,
      contextSize: settings.contextSize,
      templateVariables: settings.templateVariables,
      sampler: nw.SamplerPresets.greedy(),
    );
    for (final q in dataset.questions) {
      await chat.resetHistory();
      var retrieved = <KnowledgeDoc>[];
      String prompt = q.question;
      if (mode == 'rag') {
        retrieved = await rag!.search(q.question, settings.ragTopK);
        prompt = ragPrompt(q.question, retrieved);
      }
      final gen = await generate(
        chat,
        prompt,
        maxTokens: settings.answerTokenLimit,
        timeout: const Duration(minutes: 2),
        cancel: cancel,
      );
      final correct = gen.error == null && matchesAny(gen.text, q.answers);
      answers.add(KnowledgeAnswer(q, mode, gen, correct, [for (final d in retrieved) d.title]));
      done++;
      onProgress(
        '[$mode] ${q.id} ${correct ? '✓' : '✗'}  ${_oneLine(gen.text)}',
        done / total,
      );
    }
  }
  return KnowledgeResult(answers);
}

String _oneLine(String s) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 80 ? '${t.substring(0, 80)}…' : t;
}

/// Fits closed-book accuracy ≈ a + b·log10(params) across models and inverts
/// it to estimate how many parameters a closed-book model would need to match
/// each model's RAG accuracy.
class ParamsEquivalence {
  final double a;
  final double b;
  final int n;
  ParamsEquivalence(this.a, this.b, this.n);

  static ParamsEquivalence? fit(List<(double paramsB, double accuracy)> points) {
    final distinct = points.map((p) => p.$1.toStringAsFixed(2)).toSet();
    if (points.length < 2 || distinct.length < 2) return null;
    final xs = [for (final p in points) _log10(p.$1)];
    final ys = [for (final p in points) p.$2];
    final mx = xs.reduce((s, x) => s + x) / xs.length;
    final my = ys.reduce((s, y) => s + y) / ys.length;
    var num = 0.0, den = 0.0;
    for (var i = 0; i < xs.length; i++) {
      num += (xs[i] - mx) * (ys[i] - my);
      den += (xs[i] - mx) * (xs[i] - mx);
    }
    if (den == 0) return null;
    final b = num / den;
    if (b <= 0) return null; // bigger models aren't better here: can't invert
    return ParamsEquivalence(my - b * mx, b, points.length);
  }

  /// Closed-book-equivalent size (billions) for a given accuracy.
  double equivalentParamsB(double accuracy) =>
      _pow10((accuracy - a) / b);

  static double _log10(double x) => math.log(x) / math.ln10;
  static double _pow10(double x) => math.pow(10, x).toDouble();
}
