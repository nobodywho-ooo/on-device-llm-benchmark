import 'package:nobodywho/nobodywho.dart' as nw;

import 'generate.dart';
import 'settings.dart';
import 'text_utils.dart';

// ---------------------------------------------------------------------------
// Tool call recording + mock tools
// ---------------------------------------------------------------------------

class RecordedCall {
  final String name;
  final Map<String, dynamic> args;
  RecordedCall(this.name, this.args);
  Map<String, dynamic> toJson() => {'name': name, 'args': args};
  @override
  String toString() => '$name(${args.entries.map((e) => '${e.key}: ${e.value}').join(', ')})';
}

class ToolRecorder {
  final calls = <RecordedCall>[];
  static const maxCalls = 8;

  /// Called when the model loops on tools; stops generation.
  void Function()? onRunaway;

  String record(String name, Map<String, dynamic> args, String result) {
    calls.add(RecordedCall(name, args));
    if (calls.length >= maxCalls) onRunaway?.call();
    return result;
  }
}

/// Mock world: the user is in Copenhagen, today is 2026-11-26 (Thursday).
const benchToday = '2026-11-26';

// Tool parameter names are snake_case on purpose: they are the names the model sees.
// ignore_for_file: non_constant_identifier_names
List<nw.Tool> buildTools(ToolRecorder rec) => [
  nw.Tool(
    name: 'get_location',
    description: "Get the user's current location (city, country, coordinates).",
    function: () => rec.record('get_location', {},
        '{"city": "Copenhagen", "country": "Denmark", "latitude": 55.68, "longitude": 12.57, "timezone": "Europe/Copenhagen"}'),
  ),
  nw.Tool(
    name: 'get_weather',
    description: 'Get the current weather for a city.',
    parameterDescriptions: {'city': 'City name, e.g. "Paris"'},
    function: ({required String city}) => rec.record('get_weather', {'city': city},
        '{"city": "$city", "temperature_c": 7, "condition": "light rain", "wind_kmh": 18}'),
  ),
  nw.Tool(
    name: 'get_current_time',
    description: 'Get the current local time in a timezone.',
    parameterDescriptions: {'timezone': 'IANA timezone, e.g. "Europe/Paris"'},
    function: ({required String timezone}) => rec.record(
        'get_current_time', {'timezone': timezone}, '{"timezone": "$timezone", "time": "14:32"}'),
  ),
  nw.Tool(
    name: 'search_contacts',
    description: "Search the user's address book by name. Returns name and email.",
    parameterDescriptions: {'name': 'Name (or part of it) to search for'},
    function: ({required String name}) => rec.record('search_contacts', {'name': name},
        normalize(name).contains('alice')
            ? '[{"name": "Alice Martin", "email": "alice.martin@example.com"}]'
            : '[]'),
  ),
  nw.Tool(
    name: 'send_email',
    description: 'Send an email.',
    parameterDescriptions: {
      'to': 'Recipient email address',
      'subject': 'Email subject',
      'body': 'Email body',
    },
    function: ({required String to, required String subject, required String body}) =>
        rec.record('send_email', {'to': to, 'subject': subject, 'body': body}, '{"status": "sent"}'),
  ),
  nw.Tool(
    name: 'calculate',
    description: 'Evaluate an arithmetic expression (+, -, *, /, parentheses).',
    parameterDescriptions: {'expression': 'Expression, e.g. "(2 + 3) * 4"'},
    function: ({required String expression}) {
      String result;
      try {
        result = _Calc(expression).parse().toString();
      } catch (e) {
        result = 'Error: invalid expression';
      }
      return rec.record('calculate', {'expression': expression}, result);
    },
  ),
  nw.Tool(
    name: 'convert_currency',
    description: 'Convert an amount of money between currencies (ISO codes like EUR, USD).',
    parameterDescriptions: {
      'amount': 'Amount to convert',
      'from_currency': 'Source currency ISO code',
      'to_currency': 'Target currency ISO code',
    },
    function: ({required double amount, required String from_currency, required String to_currency}) =>
        rec.record('convert_currency',
            {'amount': amount, 'from_currency': from_currency, 'to_currency': to_currency},
            '{"result": ${(amount * 1.08).toStringAsFixed(2)}, "currency": "$to_currency"}'),
  ),
  nw.Tool(
    name: 'set_timer',
    description: 'Start a countdown timer.',
    parameterDescriptions: {'minutes': 'Duration in minutes'},
    function: ({required int minutes}) =>
        rec.record('set_timer', {'minutes': minutes}, '{"status": "timer set", "minutes": $minutes}'),
  ),
  nw.Tool(
    name: 'create_calendar_event',
    description: "Create an event in the user's calendar.",
    parameterDescriptions: {
      'title': 'Event title',
      'date': 'Date as YYYY-MM-DD',
      'time': 'Start time as HH:MM (24h)',
    },
    function: ({required String title, required String date, required String time}) =>
        rec.record('create_calendar_event', {'title': title, 'date': date, 'time': time},
            '{"status": "created"}'),
  ),
];

// ---------------------------------------------------------------------------
// Test cases
// ---------------------------------------------------------------------------

class ArgCheck {
  final String description;
  final bool Function(dynamic v) test;
  const ArgCheck(this.description, this.test);
}

ArgCheck containsText(String s) =>
    ArgCheck('contains "$s"', (v) => v != null && normalize('$v').contains(normalize(s)));
ArgCheck anyText(List<String> xs) => ArgCheck(
    'contains one of ${xs.map((x) => '"$x"').join(' | ')}',
    (v) => v != null && xs.any((s) => normalize('$v').contains(normalize(s))));
ArgCheck numEquals(num n) =>
    ArgCheck('== $n', (v) => v is num ? (v - n).abs() < 1e-6 : num.tryParse('$v') == n);

class ExpectedCall {
  final String name;
  final Map<String, ArgCheck> args;
  const ExpectedCall(this.name, [this.args = const {}]);
}

class AgenticCase {
  final String id;
  final String prompt;
  final List<ExpectedCall> expected;

  /// Pairs (a, b): the first call to `a` must happen before the first call to `b`.
  final List<(String, String)> order;

  /// Tools that must not be called.
  final List<String> forbidden;

  /// Substrings (any) the final answer should contain.
  final List<String> answerContains;

  const AgenticCase({
    required this.id,
    required this.prompt,
    this.expected = const [],
    this.order = const [],
    this.forbidden = const [],
    this.answerContains = const [],
  });

  bool get expectsNoTools => expected.isEmpty;
}

final agenticCases = <AgenticCase>[
  AgenticCase(
    id: 'weather_here',
    prompt: 'What is the weather today?',
    expected: [ExpectedCall('get_location'), ExpectedCall('get_weather', {'city': containsText('Copenhagen')})],
    order: [('get_location', 'get_weather')],
    answerContains: ['7', 'rain'],
  ),
  AgenticCase(
    id: 'weather_city',
    prompt: "What's the weather like in Paris right now?",
    expected: [ExpectedCall('get_weather', {'city': containsText('Paris')})],
    forbidden: ['get_location'],
    answerContains: ['7', 'rain'],
  ),
  AgenticCase(
    id: 'time_tokyo',
    prompt: 'What time is it in Tokyo?',
    expected: [ExpectedCall('get_current_time', {'timezone': containsText('Tokyo')})],
    forbidden: ['get_location'],
    answerContains: ['14:32', '2:32'],
  ),
  AgenticCase(
    id: 'calc',
    prompt: 'Compute 1234.5 * 678.9 / 3.7 for me.',
    expected: [ExpectedCall('calculate', {
      'expression': ArgCheck('has 1234.5, 678.9 and 3.7',
          (v) => '$v'.contains('1234.5') && '$v'.contains('678.9') && '$v'.contains('3.7')),
    })],
    answerContains: ['226514'],
  ),
  AgenticCase(
    id: 'timer',
    prompt: 'Set a timer for 15 minutes.',
    expected: [ExpectedCall('set_timer', {'minutes': numEquals(15)})],
  ),
  AgenticCase(
    id: 'currency',
    prompt: 'How much is 250 euros in US dollars?',
    expected: [ExpectedCall('convert_currency', {
      'amount': numEquals(250),
      'from_currency': anyText(['EUR', 'euro']),
      'to_currency': anyText(['USD', 'dollar']),
    })],
    answerContains: ['270'],
  ),
  AgenticCase(
    id: 'email_contact',
    prompt: "Email Alice to tell her I'll be 10 minutes late to our meeting.",
    expected: [
      ExpectedCall('search_contacts', {'name': containsText('Alice')}),
      ExpectedCall('send_email', {
        'to': containsText('alice.martin@example.com'),
        'body': anyText(['10 min', 'ten min', 'late']),
      }),
    ],
    order: [('search_contacts', 'send_email')],
  ),
  AgenticCase(
    id: 'calendar',
    prompt: 'Schedule a meeting called "Design Review" tomorrow at 3pm.',
    expected: [ExpectedCall('create_calendar_event', {
      'title': containsText('Design Review'),
      'date': containsText('2026-11-27'),
      'time': anyText(['15:00', '15']),
    })],
  ),
  AgenticCase(
    id: 'weather_and_time_here',
    prompt: "What's the weather where I am, and what time is it here?",
    expected: [
      ExpectedCall('get_location'),
      ExpectedCall('get_weather', {'city': containsText('Copenhagen')}),
      ExpectedCall('get_current_time', {'timezone': anyText(['Copenhagen', 'Europe'])}),
    ],
    order: [('get_location', 'get_weather'), ('get_location', 'get_current_time')],
  ),
  AgenticCase(id: 'no_tool_capital', prompt: 'What is the capital of France?', answerContains: ['Paris']),
  AgenticCase(id: 'no_tool_haiku', prompt: 'Write a haiku about autumn leaves.'),
  AgenticCase(id: 'no_tool_greeting', prompt: 'Hi! How are you doing?'),
];

const agenticSystemPrompt =
    'You are a helpful assistant with access to tools. Call a tool only when it '
    'is needed to answer; otherwise answer directly. Never ask the user for '
    'information that a tool can provide. Today is Thursday $benchToday.';

// ---------------------------------------------------------------------------
// Scoring
// ---------------------------------------------------------------------------

class CheckResult {
  final String check;
  final bool passed;
  final String? detail;
  CheckResult(this.check, this.passed, [this.detail]);
  Map<String, dynamic> toJson() => {'check': check, 'passed': passed, if (detail != null) 'detail': detail};
}

class AgenticCaseResult {
  final AgenticCase c;
  final List<RecordedCall> calls;
  final GenResult gen;
  final List<CheckResult> checks;
  AgenticCaseResult(this.c, this.calls, this.gen, this.checks);

  bool get passed => checks.every((x) => x.passed);
  double get score => checks.isEmpty ? 0 : checks.where((x) => x.passed).length / checks.length;

  Map<String, dynamic> toJson() => {
    'id': c.id,
    'prompt': c.prompt,
    'expected_tools': [for (final e in c.expected) e.name],
    'calls': [for (final x in calls) x.toJson()],
    'answer': gen.text,
    'passed': passed,
    'score': double.parse(score.toStringAsFixed(3)),
    'checks': [for (final x in checks) x.toJson()],
    'total_ms': gen.totalMs.round(),
    if (gen.error != null) 'error': gen.error,
  };
}

List<CheckResult> scoreCase(AgenticCase c, List<RecordedCall> calls, String answer) {
  final checks = <CheckResult>[];
  final called = calls.map((x) => x.name).toList();

  if (c.expectsNoTools) {
    checks.add(CheckResult('no tool called', calls.isEmpty, calls.isEmpty ? null : called.join(', ')));
  } else {
    final expectedNames = c.expected.map((e) => e.name).toSet();
    final calledSet = called.toSet();
    checks.add(CheckResult(
      'right tools selected',
      calledSet.containsAll(expectedNames),
      'expected ${expectedNames.join(', ')}; got ${called.isEmpty ? 'none' : called.join(', ')}',
    ));
    final extra = calledSet.difference(expectedNames);
    checks.add(CheckResult('no unnecessary tools', extra.isEmpty, extra.isEmpty ? null : extra.join(', ')));

    for (final e in c.expected.where((e) => e.args.isNotEmpty)) {
      final candidates = calls.where((x) => x.name == e.name).toList();
      final ok = candidates.any((x) => e.args.entries.every((a) => a.value.test(x.args[a.key])));
      checks.add(CheckResult(
        '${e.name} arguments',
        ok,
        '${e.args.entries.map((a) => '${a.key} ${a.value.description}').join('; ')}'
            '${candidates.isEmpty ? '' : ' — got ${candidates.map((x) => x.args).join(' / ')}'}',
      ));
    }
    for (final (a, b) in c.order) {
      final ia = called.indexOf(a), ib = called.indexOf(b);
      checks.add(CheckResult('$a before $b', ia >= 0 && ib >= 0 && ia < ib));
    }
    if (calls.length >= ToolRecorder.maxCalls) {
      checks.add(CheckResult('no tool-call loop', false, '${calls.length} calls'));
    }
  }
  for (final f in c.forbidden) {
    checks.add(CheckResult('does not call $f', !called.contains(f)));
  }
  if (c.answerContains.isNotEmpty) {
    final n = normalize(answer).replaceAll(' ', '');
    final ok = c.answerContains.any((s) => n.contains(normalize(s).replaceAll(' ', '')));
    checks.add(CheckResult('final answer uses result', ok));
  }
  return checks;
}

class AgenticResult {
  final List<AgenticCaseResult> cases;
  AgenticResult(this.cases);

  double get passRate => cases.isEmpty ? 0 : cases.where((c) => c.passed).length / cases.length;
  double get meanScore => cases.isEmpty ? 0 : cases.map((c) => c.score).reduce((a, b) => a + b) / cases.length;

  double _rate(Iterable<AgenticCaseResult> xs) =>
      xs.isEmpty ? double.nan : xs.where((c) => c.passed).length / xs.length;
  double get toolCasePassRate => _rate(cases.where((c) => !c.c.expectsNoTools));
  double get noToolCasePassRate => _rate(cases.where((c) => c.c.expectsNoTools));

  Map<String, dynamic> summaryJson() => {
    'pass_rate': passRate,
    'mean_check_score': meanScore,
    'tool_cases_pass_rate': toolCasePassRate.isNaN ? null : toolCasePassRate,
    'no_tool_cases_pass_rate': noToolCasePassRate.isNaN ? null : noToolCasePassRate,
  };
}

Future<AgenticResult> runAgentic({
  required nw.Model model,
  required BenchSettings settings,
  required CancelToken cancel,
  required void Function(String msg, double progress) onProgress,
}) async {
  final rec = ToolRecorder();
  final chat = nw.Chat(
    model: model,
    systemPrompt: agenticSystemPrompt,
    contextSize: settings.contextSize,
    templateVariables: settings.templateVariables,
    tools: buildTools(rec),
    sampler: nw.SamplerPresets.greedy(),
  );
  rec.onRunaway = chat.stopGeneration;

  final results = <AgenticCaseResult>[];
  for (var i = 0; i < agenticCases.length; i++) {
    final c = agenticCases[i];
    await chat.resetHistory();
    rec.calls.clear();
    final gen = await generate(
      chat,
      c.prompt,
      maxTokens: settings.enableThinking ? 3072 : 512,
      timeout: const Duration(minutes: 3),
      cancel: cancel,
    );
    final calls = List<RecordedCall>.of(rec.calls);
    final r = AgenticCaseResult(c, calls, gen, scoreCase(c, calls, gen.text));
    results.add(r);
    onProgress(
      '[${c.id}] ${r.passed ? '✓' : '✗'}  ${calls.isEmpty ? 'no tools' : calls.join(' → ')}',
      (i + 1) / agenticCases.length,
    );
  }
  return AgenticResult(results);
}

// ---------------------------------------------------------------------------
// Tiny arithmetic parser for the calculate tool.
// ---------------------------------------------------------------------------

class _Calc {
  final String s;
  int i = 0;
  _Calc(String input) : s = input.replaceAll(' ', '').replaceAll('×', '*').replaceAll('÷', '/');

  double parse() {
    final v = _expr();
    if (i != s.length) throw FormatException('Unexpected "${s[i]}"');
    return v;
  }

  double _expr() {
    var v = _term();
    while (i < s.length && (s[i] == '+' || s[i] == '-')) {
      final op = s[i++];
      final r = _term();
      v = op == '+' ? v + r : v - r;
    }
    return v;
  }

  double _term() {
    var v = _factor();
    while (i < s.length && (s[i] == '*' || s[i] == '/')) {
      final op = s[i++];
      final r = _factor();
      v = op == '*' ? v * r : v / r;
    }
    return v;
  }

  double _factor() {
    if (i < s.length && s[i] == '-') {
      i++;
      return -_factor();
    }
    if (i < s.length && s[i] == '(') {
      i++;
      final v = _expr();
      if (i >= s.length || s[i] != ')') throw const FormatException('Missing )');
      i++;
      return v;
    }
    final start = i;
    while (i < s.length && RegExp(r'[0-9.]').hasMatch(s[i])) {
      i++;
    }
    return double.parse(s.substring(start, i));
  }
}
