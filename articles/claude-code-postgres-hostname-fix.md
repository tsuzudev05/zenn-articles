---
title: "Claude Code で make run-api を実行したら postgres ホスト名が解決できなかった話"
emoji: "🐘"
type: "tech"
topics: ["claudecode", "postgresql", "docker", "devcontainer", "makefile"]
published: false
---

## はじめに

DevContainer で開発している Go の API サーバーを Claude Code のターミナルから `make run-api` で起動しようとしたところ、こんなエラーが出ました。

```
DATABASE_URL=postgresql://postgres:pass@postgres:5432/learning go run ./cmd/api
2026/05/30 10:45:09 DB疎通確認失敗: failed to connect to `host=postgres user=postgres database=learning`: hostname resolving error (lookup postgres on 127.0.0.11:53: no such host)
exit status 1
make: *** [Makefile:33: run-api] Error 1
```

`postgres` というホスト名が解決できないというエラーです。DevContainer 内なら問題なく動いていたのに、なぜ？

---

## 原因：Claude Code は DevContainer とは別のコンテナで動いている

エラーの `127.0.0.11` は Docker の内部 DNS サーバーです。つまり、コマンドは何らかのコンテナの中で動いています。

ただし、その「何らかのコンテナ」が DevContainer の `app` コンテナではないことがポイントです。

私のプロジェクトは以下の `docker-compose.yml` で構成されていました。

```yaml
services:
  app:
    # ... 開発コンテナ本体
    networks:
      - dev-network

  postgres:
    image: postgres:16
    networks:
      - dev-network

networks:
  dev-network:
    driver: bridge
```

`postgres` というホスト名は `dev-network` 内でのみ有効です。VS Code の DevContainer として `app` を開いた場合、`app` と `postgres` は同じネットワークに属するため `postgres` が解決できます。

一方、**Claude Code は独自のコンテナ環境で動いており、この `dev-network` には参加していません**。そのため Docker の内部 DNS に `postgres` のレコードが存在せず、ホスト名解決が失敗します。

```
Claude Code コンテナ（dev-network 外）
  ↓ make run-api
  → hostname: postgres を解決しようとする
  → Docker DNS (127.0.0.11) に問い合わせ
  → dev-network を知らないので no such host
```

---

## 対処法

### ステップ 1：PostgreSQL サーバーをインストール・起動する

Claude Code コンテナには PostgreSQL クライアント（`psql`）しか入っていないため、サーバーをインストールします。

```bash
apt-get install -y postgresql
pg_ctlcluster 16 main start
```

### ステップ 2：`/etc/hosts` に `postgres` を登録する

接続文字列 `postgresql://postgres:pass@postgres:5432/learning` は `postgres` というホスト名を使っています。これをローカルの PostgreSQL に向けるため、`/etc/hosts` にエントリを追加します。

```bash
echo "127.0.0.1 postgres" >> /etc/hosts
```

これで `postgres` が `localhost` として解決されるようになります。

### ステップ 3：データベースを作成してスキーマを適用する

```bash
su -c "createdb learning" postgres
su -c "psql -d learning -f /workspace/05_DDD統合/schema.sql" postgres
```

接続確認：

```bash
PGPASSWORD=pass psql -h postgres -p 5432 -U postgres -d learning -c "\dt"
```

テーブル一覧が表示されれば成功です。

---

## 再発防止：`make init` を Makefile に追加する

コンテナは再起動のたびにプロセスが落ちるため、起動するたびに手順を繰り返す必要があります。Makefile にまとめておくと楽です。

```makefile
SCHEMA := /workspace/05_DDD統合/schema.sql

.PHONY: init

# Claude Code 環境：コンテナ再起動のたびに実行する
# DevContainer（VS Code）では postgres コンテナが Docker Compose で自動起動するため不要
init:
	@echo "🔧 PostgreSQL を起動します..."
	@pg_lsclusters | grep -q " online " || pg_ctlcluster 16 main start
	@grep -q "127.0.0.1 postgres" /etc/hosts || echo "127.0.0.1 postgres" >> /etc/hosts
	@echo "🔧 データベース・スキーマを初期化します..."
	@su -c "createdb learning 2>/dev/null || true" postgres
	@su -c "psql -d learning -f $(SCHEMA) 2>/dev/null || true" postgres
	@echo "✅ 初期化完了。make run-api でサーバーを起動できます。"
```

各行は**冪等**に設計しています。

| 処理 | 冪等の工夫 |
|------|------------|
| PostgreSQL 起動 | `grep -q " online "` でチェックしてから起動 |
| `/etc/hosts` 追加 | `grep -q` でチェックしてから追記 |
| DB 作成 | `createdb ... 2>/dev/null \|\| true` で既存時のエラーを無視 |
| スキーマ適用 | `psql ... 2>/dev/null \|\| true` で既存時のエラーを無視 |

これで Claude Code 環境でのセットアップ手順は次の 2 ステップになります。

```bash
make init       # PostgreSQL 起動 + DB・スキーマ初期化
make run-api    # API サーバー起動（http://localhost:8080）
```

---

## 環境別の違いまとめ

| 環境 | `postgres` ホスト名 | 必要な手順 |
|------|---------------------|------------|
| VS Code DevContainer | Docker Compose の `postgres` サービスが自動起動 → 自動解決 | なし |
| Claude Code コンテナ | `dev-network` 外のため解決不可 | `make init` を実行 |

---

## まとめ

- Claude Code は DevContainer とは**別のコンテナ**で動いているため、Docker Compose のサービス名（`postgres`）が DNS 解決できない
- 対処は「ローカルに PostgreSQL を立てて `/etc/hosts` でホスト名をバイパスする」
- コンテナ再起動のたびに必要な操作を `make init` にまとめておくと毎回コマンドを思い出さなくて済む

DevContainer と Claude Code を併用している方の参考になれば幸いです。

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
