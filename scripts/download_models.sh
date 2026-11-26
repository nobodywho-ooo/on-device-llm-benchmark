#!/usr/bin/env bash
# Downloads a starter set of models:
#   - embedding model (required for the offline RAG part of the knowledge suite)
#   - a small Qwen3 ladder (0.6B / 1.7B / 4B) so the "RAG ≈ closed-book size" fit has several sizes
# Usage: ./scripts/download_models.sh [--small]   (--small: only 0.6B + 1.7B)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="$ROOT/models"
mkdir -p "$MODELS/embedding"

fetch() {
  local url="$1" out="$2"
  if [ -f "$out" ]; then echo "✓ $(basename "$out") already present"; return; fi
  echo "↓ $(basename "$out")"
  curl -L --fail --progress-bar -o "$out.part" "$url" && mv "$out.part" "$out"
}

fetch "https://huggingface.co/CompendiumLabs/bge-small-en-v1.5-gguf/resolve/main/bge-small-en-v1.5-q8_0.gguf" \
      "$MODELS/embedding/bge-small-en-v1.5-q8_0.gguf"
fetch "https://huggingface.co/NobodyWho/Qwen_Qwen3-0.6B-GGUF/resolve/main/Qwen_Qwen3-0.6B-Q4_K_M.gguf" \
      "$MODELS/Qwen3-0.6B-Q4_K_M.gguf"
fetch "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf" \
      "$MODELS/Qwen3-1.7B-Q4_K_M.gguf"
if [ "${1:-}" != "--small" ]; then
  fetch "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf" \
        "$MODELS/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
fi
echo "Done. Drop any other .gguf into $MODELS"
