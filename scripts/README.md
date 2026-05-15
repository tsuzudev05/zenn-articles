# scripts/

開発を効率化するためのシェルスクリプト集。

すべてリポジトリルートから実行することを想定しています。

---

## セットアップ

初回のみ実行権限を付与してください。

```bash
chmod +x scripts/*.sh
```

---

## スクリプト一覧

### zenn-preview.sh

Zenn記事のローカルプレビューサーバーを起動する。

```bash
./scripts/zenn-preview.sh
# → http://localhost:8000 でプレビュー確認
```

**前提**：`zenn-articles` リポジトリのルートに `package.json` が存在すること。

---

### zenn-new-article.sh

Zennの新規記事ファイルを作成する。

```bash
# スラッグを引数で指定
./scripts/zenn-new-article.sh ddd-repository-pattern

# 対話形式で入力
./scripts/zenn-new-article.sh
```

---

### git-new-branch.sh

featureブランチをIssue番号と紐付けて作成する。

```bash
./scripts/git-new-branch.sh <issue番号> <ブランチ名>

# 例：Issue #5 に紐付けた feature/cpp-entity を作成
./scripts/git-new-branch.sh 5 cpp-entity
```

`main` または `develop` ブランチが存在する場合は `develop` をベースにする。

---

### db-check.sh

DevContainer内のPostgreSQLの接続確認とテーブル一覧表示を行う。

```bash
# DevContainer内で実行
./scripts/db-check.sh

# DB名・ユーザー名を指定
./scripts/db-check.sh mydb myuser
```

`schema.sql` が存在する場合、対話形式で適用するか選択できる。

---

## 環境変数（DevContainer）

`db-check.sh` は以下の環境変数を参照します。`.devcontainer/.env` に設定してください。

```env
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_DB=postgres
POSTGRES_USER=postgres
```
