class BenchSettings {
  bool runKnowledge;
  bool runPerformance;
  bool runAgentic;

  /// Lets reasoning models think (`enable_thinking` template variable).
  /// Off by default: faster, and comparable across models.
  bool enableThinking;

  int contextSize;
  int ragTopK;
  int perfRepetitions;

  BenchSettings({
    this.runKnowledge = true,
    this.runPerformance = true,
    this.runAgentic = true,
    this.enableThinking = false,
    this.contextSize = 4096,
    this.ragTopK = 3,
    this.perfRepetitions = 3,
  });

  Map<String, bool> get templateVariables => {'enable_thinking': enableThinking};

  /// Max streamed tokens for short-answer tasks.
  int get answerTokenLimit => enableThinking ? 1536 : 96;

  Map<String, dynamic> toJson() => {
    'run_knowledge': runKnowledge,
    'run_performance': runPerformance,
    'run_agentic': runAgentic,
    'enable_thinking': enableThinking,
    'context_size': contextSize,
    'rag_top_k': ragTopK,
    'perf_repetitions': perfRepetitions,
  };
}
