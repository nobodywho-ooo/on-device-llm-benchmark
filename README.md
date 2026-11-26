# on-device-llm-benchmark

A small macOS benchmark for local LLMs, built with Flutter + [NobodyWho](https://github.com/nobodywho-ooo/nobodywho) (llama.cpp / Metal) and `shadcn_ui`.

Drop `.gguf` files into `models/`, run the app, and get a report in `results/<timestamp>/`.

## Quick start

```bash
flutter pub get
./scripts/download_models.sh        # embedding model + Qwen3 0.6B / 1.7B / 4B (use --small for 0.6B + 1.7B)
make run                            # interactive app
make bench                          # headless: release build, runs every model, prints log, quits
```

Any chat `.gguf` placed directly in `models/` is picked up (files containing `mmproj` are ignored). The embedding model used for retrieval lives in `models/embedding/` (if empty, `bge-small-en-v1.5` is downloaded once via `hf://` and cached).

The app finds the repo folder automatically when launched with `flutter run`. To use another folder: `--dart-define=BENCH_ROOT=/path/to/folder`. The macOS sandbox is disabled so the app can read `models/` and write `results/`.

## Suites

### 1. Performance — TTFT & tok/s
* **Short prompt** (~20 tokens → up to 256 generated) and **long prompt** (~2k tokens → up to 128 generated).
* 1 warm-up run, then N runs (default 3), median reported. Each run uses a **fresh context** so prefix caching doesn't flatter TTFT.
* **TTFT** = prompt sent → first streamed token. **Decode** = (tokens − 1) / (last token − first token). **Prefill** = prompt tokens / TTFT.
* Greedy sampling, thinking disabled. Model load time is recorded too.

### 2. General knowledge — closed-book vs. retrieval
35 general questions (from easy to obscure) + 4 "private" questions about NobodyWho that a model can't know without retrieval. Each is asked twice:

* **Closed-book**: question only.
* **RAG**: top-3 passages retrieved from a local corpus (`assets/data/knowledge.json`, 53 passages including distractors) with a NobodyWho `Encoder` (bge-small) + cosine similarity, injected in the prompt.

Answers are scored by normalized whole-word match against accepted aliases. Retrieval recall@k is reported separately so you can tell retrieval failures from reading failures.

**"How many billions of parameters does retrieval add?"** — with ≥ 2 models of different sizes, the report fits `closed-book accuracy = a + b·log10(params)` across your models and inverts it at each model's RAG accuracy: *"a closed-book model would need ~X B params to match this model with retrieval"*. Parameter counts are exact (summed from the GGUF tensor shapes, so they include embeddings). The more model sizes you run, the better the fit; values far beyond the tested range are extrapolations.

#### Why offline RAG rather than web search (Exa)
* **No external service, no API key, fully reproducible**: the same passages every run, so differences come from the model, not from search results changing.
* It isolates what you want to measure — *how much the model gains from being handed the right facts* — from search-engine quality.
* It's what an on-device app would actually ship (NobodyWho `Encoder` + local index).
* Tool-based search would mix two skills (deciding to search + using results); that's measured separately in the agentic suite.

To extend it, add passages to `corpus` and questions to `questions` in `assets/data/knowledge.json` (set `source` to the passage title to get retrieval recall).

### 3. Agentic — tool calling
9 mock tools (`get_location`, `get_weather`, `get_current_time`, `search_contacts`, `send_email`, `calculate`, `convert_currency`, `set_timer`, `create_calendar_event`) with deterministic results (the user is in Copenhagen, today is 2026-11-26). 12 cases, e.g.

| Prompt | Expected |
|---|---|
| What is the weather today? | `get_location` → `get_weather(city≈Copenhagen)` |
| What's the weather like in Paris right now? | `get_weather(city≈Paris)`, **not** `get_location` |
| Email Alice to tell her I'll be 10 minutes late… | `search_contacts(Alice)` → `send_email(to=alice.martin@example.com)` |
| What is the capital of France? / haiku / greeting | **no tool** |

Each case checks: right tools selected, no unnecessary tools, argument values, call order, forbidden tools, no tool-call loop, and whether the final answer uses the tool result. Pass = all checks pass. Cases live in `lib/bench/agentic.dart`.

## Output

`results/<timestamp>/`

| File | Content |
|---|---|
| `report.md` | Summary table + per-question / per-case matrices |
| `results.json` | Everything: settings, machine, GGUF metadata, every answer, every tool call, every perf run |
| `knowledge_answers.csv` | One row per (model, question, mode) |
| `agentic_calls.csv` | One row per (model, case) with the tool calls and failed checks |
| `performance_runs.csv` | One row per perf run |
| `models/<model>.json` | Written after each model, so partial results survive a crash/stop |

## Options

* **Allow thinking** (off by default): sets the `enable_thinking` template variable for reasoning models (knowledge + agentic). `<think>` blocks are stripped before scoring.
* Context size 4096, greedy sampling, top-3 retrieval, 3 perf repetitions — see `lib/bench/settings.dart`.
