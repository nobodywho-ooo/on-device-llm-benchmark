.PHONY: run bench models build

# Interactive app (debug build)
run:
	flutter run -d macos

# Headless: run every model in models/ with all suites, print the log, quit.
# Release build so TTFT / tok/s numbers aren't affected by debug mode.
bench:
	flutter run -d macos --release --dart-define=AUTORUN=true

models:
	./scripts/download_models.sh

build:
	flutter build macos --release
