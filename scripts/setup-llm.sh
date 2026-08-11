#!/bin/sh
# One-time setup for whispr's local AI cleanup layer (PLAN.md §4.4 / M4).
# Creates a Python venv with mlx-lm and prefetches the cleanup model
# (~2.3 GB). Requires `uv` (brew install uv) and network for the download.
set -e

DIR="$HOME/Library/Application Support/whispr/llm"
MODEL="${WHISPR_LLM_MODEL:-mlx-community/Qwen3-4B-Instruct-2507-4bit}"

echo "==> Creating venv at $DIR/venv"
uv venv --python 3.12 "$DIR/venv"

echo "==> Installing mlx-lm"
VIRTUAL_ENV="$DIR/venv" uv pip install --python "$DIR/venv/bin/python" mlx-lm

echo "==> Prefetching model $MODEL (~2.3 GB, one time)"
"$DIR/venv/bin/python" - <<EOF
from huggingface_hub import snapshot_download
snapshot_download("$MODEL")
print("model ready")
EOF

echo "==> Done. Restart whispr; Settings should show 'Local AI model: Ready' shortly after launch."
