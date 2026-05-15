#!/bin/bash
# =============================================================================
# db-check.sh
# DevContainer内のPostgreSQLの動作確認を行う
#
# 使い方（DevContainer内で実行）:
#   ./scripts/db-check.sh
#   ./scripts/db-check.sh mydb myuser
# =============================================================================

set -e

echo "=== PostgreSQL Connection Check ==="

# デフォルト設定（DevContainer環境に合わせて変更）
DB_HOST="${POSTGRES_HOST:-localhost}"
DB_PORT="${POSTGRES_PORT:-5432}"
DB_NAME="${POSTGRES_DB:-${1:-postgres}}"
DB_USER="${POSTGRES_USER:-${2:-postgres}}"

echo "[INFO] 接続先: $DB_HOST:$DB_PORT / DB=$DB_NAME / USER=$DB_USER"
echo ""

# PostgreSQLの起動確認
if ! pg_isready -h "$DB_HOST" -p "$DB_PORT" -q; then
    echo "[ERROR] PostgreSQL が起動していません: $DB_HOST:$DB_PORT"
    exit 1
fi
echo "[OK] PostgreSQL 起動中"

# 接続確認
if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT version();" &>/dev/null; then
    echo "[OK] 接続成功"
else
    echo "[ERROR] 接続失敗。ユーザー・DB名・パスワードを確認してください"
    exit 1
fi

# テーブル一覧を表示
echo ""
echo "=== テーブル一覧 ==="
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "\dt" 2>/dev/null || echo "(テーブルなし)"

# スキーマ適用確認（schema.sqlが存在する場合）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA_FILE="$SCRIPT_DIR/../05_DDD統合/schema.sql"

if [ -f "$SCHEMA_FILE" ]; then
    echo ""
    echo "=== schema.sql を適用しますか？ ==="
    echo -n "適用する場合は 'y' を入力してください [y/N]: "
    read -r APPLY
    if [ "$APPLY" = "y" ] || [ "$APPLY" = "Y" ]; then
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$SCHEMA_FILE"
        echo "[OK] schema.sql を適用しました"
    fi
fi

echo ""
echo "=== 確認完了 ==="
