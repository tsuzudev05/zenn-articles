#!/bin/bash
# =============================================================================
# git-new-branch.sh
# feature ブランチを作成し、Issue番号と紐付ける
#
# 使い方:
#   ./scripts/git-new-branch.sh <issue番号> <ブランチ名>
#   ./scripts/git-new-branch.sh 5 cpp-entity
#   → feature/cpp-entity を作成（#5 に紐付け）
# =============================================================================

set -e

echo "=== Git New Feature Branch ==="

# 引数チェック
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "使い方: $0 <issue番号> <ブランチ名>"
    echo "例:     $0 5 cpp-entity"
    exit 1
fi

ISSUE_NUMBER="$1"
BRANCH_NAME="feature/$2"

# 現在のブランチを確認
CURRENT_BRANCH=$(git branch --show-current)
echo "[INFO] 現在のブランチ: $CURRENT_BRANCH"

# main または develop から作成する
BASE_BRANCH="main"
if git show-ref --quiet refs/heads/develop; then
    BASE_BRANCH="develop"
fi

echo "[INFO] ベースブランチ: $BASE_BRANCH"
echo "[INFO] 作成するブランチ: $BRANCH_NAME（Issue #$ISSUE_NUMBER）"
echo ""

# 最新を取得してブランチ作成
git fetch origin "$BASE_BRANCH" --quiet
git checkout -b "$BRANCH_NAME" "origin/$BASE_BRANCH"

echo ""
echo "[INFO] ブランチ作成完了: $BRANCH_NAME"
echo "[INFO] コミット時は 'Refs #$ISSUE_NUMBER' または 'Closes #$ISSUE_NUMBER' を付けてください"
