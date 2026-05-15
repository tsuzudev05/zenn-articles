#!/bin/bash
# =============================================================================
# zenn-new-article.sh
# Zennの新規記事ファイルを作成する
#
# 使い方:
#   ./scripts/zenn-new-article.sh
#   ./scripts/zenn-new-article.sh my-article-slug
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Zenn New Article ==="

# スラッグを引数またはユーザー入力で取得
if [ -n "$1" ]; then
    SLUG="$1"
else
    echo -n "記事のスラッグを入力してください（英数字・ハイフン）: "
    read -r SLUG
fi

# バリデーション
if [[ ! "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "[ERROR] スラッグは英小文字・数字・ハイフンのみ使用できます: $SLUG"
    exit 1
fi

ZENN_DIR="$REPO_ROOT"
cd "$ZENN_DIR"

npx zenn new:article --slug "$SLUG"

echo ""
echo "[INFO] 作成完了: articles/$SLUG.md"
echo "[INFO] プレビュー: ./scripts/zenn-preview.sh"
