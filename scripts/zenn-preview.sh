#!/bin/bash
# =============================================================================
# zenn-preview.sh
# Zenn記事のローカルプレビューサーバーを起動する
# ブラウザ: http://localhost:8000
#
# 前提: Node.js がインストール済みであること
# 初回のみ: npm install zenn-cli を実行する
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Zenn Preview Server ==="

# zenn-cli がインストールされているか確認
if ! npx zenn --version &>/dev/null; then
    echo "[INFO] zenn-cli が見つかりません。インストールします..."
    npm install zenn-cli
fi

# zenn-articles リポジトリに移動
ZENN_DIR="$REPO_ROOT"
if [ ! -f "$ZENN_DIR/package.json" ]; then
    echo "[ERROR] package.json が見つかりません: $ZENN_DIR"
    echo "  zenn-articles リポジトリのルートで実行してください"
    exit 1
fi

cd "$ZENN_DIR"
echo "[INFO] プレビューサーバーを起動します → http://localhost:8000"
echo "[INFO] 終了するには Ctrl+C を押してください"
echo ""
npx zenn preview
