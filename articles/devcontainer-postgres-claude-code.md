---
title: "DevContainer+Claude CodeでRDB学習環境を構築した ― 詰まったポイント3つも解説"
emoji: "🐳"
type: "tech"
topics: ["DevContainer", "Docker", "PostgreSQL", "ClaudeCode", "VSCode"]
published: false
---

## はじめに

「ローカルに色々インストールしたくない」「チームで同じ環境を共有したい」そんな思いからVSCodeのDevContainerを使い始めました。

この記事では、RDB学習用にPostgreSQL・Go・Rust・Claude Codeが揃ったDevContainer環境を構築した手順と、**詰まったポイント3つ**を記録します。

同じ構成で試したい方のために、設定ファイルをGitHubで公開しています。

---

## 作った環境の全体像

```
VSCode DevContainer
├── PostgreSQL 16（学習・ポートフォリオ統合用）
├── Go 1.22（Webアプリケーション開発）
├── Rust（CLI ツール開発）
├── Node.js 20（Claude Code の実行に必要）
├── Claude Code（ターミナルでAIと対話しながらコーディング）
└── psql 16（PostgreSQL クライアント）
```

---

## 前提条件

- Docker 26以上
- VSCode
- VSCode拡張機能：[Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)

---

## ファイル構成

```
rdb-learning-postgres/
└── .devcontainer/
    ├── devcontainer.json      # VSCode DevContainer 設定
    ├── docker-compose.yml     # appコンテナ + PostgreSQL 16
    ├── Dockerfile             # Go / Rust / Node.js / Claude Code 入り
    ├── setup.sh               # 初回セットアップスクリプト
    ├── .env.example           # 環境変数テンプレート
    └── init/
        └── 01_init_schema.sql # 初期スキーマ（起動時に自動実行）
```

---

## 設定ファイルの中身

### devcontainer.json

```jsonc
{
  "name": "rdb-learning-postgres",
  "dockerComposeFile": "docker-compose.yml",
  "service": "app",
  "workspaceFolder": "/workspace",

  "customizations": {
    "vscode": {
      "extensions": [
        "mtxr.sqltools",
        "mtxr.sqltools-driver-pg",
        "anthropic.claude-code",
        "ms-azuretools.vscode-docker",
        "yzhang.markdown-all-in-one"
      ],
      "settings": {
        "sqltools.connections": [
          {
            "name": "PostgreSQL (pg-dev)",
            "driver": "PostgreSQL",
            "host": "postgres",
            "port": 5432,
            "database": "learning",
            "username": "postgres",
            "password": "pass"
          }
        ]
      }
    }
  },

  "postCreateCommand": "bash .devcontainer/setup.sh"
}
```

### docker-compose.yml

```yaml
version: "3.9"

services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    volumes:
      - ..:/workspace:cached
    command: sleep infinity
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_DB: learning
      POSTGRES_USER: postgres
      # ※ローカル学習環境用のため簡易パスワードを使用しています
      # 本番環境では必ず強力なパスワードを設定してください
      POSTGRES_PASSWORD: pass
      DATABASE_URL: postgresql://postgres:pass@postgres:5432/learning

  postgres:
    image: postgres:16
    container_name: pg-dev
    environment:
      # ※ローカル学習環境用のため簡易パスワードを使用しています
      # 本番環境では必ず強力なパスワードを設定してください
      POSTGRES_PASSWORD: pass
      POSTGRES_DB: learning
      POSTGRES_USER: postgres
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init:/docker-entrypoint-initdb.d
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d learning"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  postgres_data:
```

### Dockerfile

```dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=ja_JP.UTF-8

# Step 1: 基本パッケージ + PostgreSQLクライアント
RUN apt-get update && apt-get install -y \
    curl wget git vim bash-completion \
    ca-certificates gnupg \
    postgresql-client-16 \
    tar gzip locales \
    && locale-gen ja_JP.UTF-8 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Step 2: Node.js 20（Claude Code の実行に必要）
# ※ apt-get install と同じRUN命令に混在させるとビルドエラーになる
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Step 3: Claude Code
RUN npm install -g @anthropic-ai/claude-code

# Step 4: Go 1.22
RUN curl -OL https://go.dev/dl/go1.22.3.linux-amd64.tar.gz \
    && tar -C /usr/local -xzf go1.22.3.linux-amd64.tar.gz \
    && rm go1.22.3.linux-amd64.tar.gz
ENV PATH=$PATH:/usr/local/go/bin
ENV GOPATH=/root/go
ENV PATH=$PATH:/root/go/bin

# Step 5: Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH=$PATH:/root/.cargo/bin

WORKDIR /workspace
CMD ["bash"]
```

---

## 詰まったポイント3つ

### 1. `runArgs: --env-file` が docker-compose 使用時に効かない

**状況：** `devcontainer.json` に以下を書いたが、環境変数が読み込まれなかった。

```jsonc
"runArgs": ["--env-file", ".devcontainer/.env"]
```

**原因：** `dockerComposeFile` を使う場合、`runArgs` はdocker-composeのコンテナには適用されません。

**解決方法：** `docker-compose.yml` の `app` サービスに `env_file` を追加する。

```yaml
services:
  app:
    env_file:
      - .env   # ← これを追加
```

あわせて `devcontainer.json` から `runArgs` を削除します。

---

### 2. Node.js のインストールを apt-get と同じ RUN に書くとビルドエラー

**状況：** 以下のように書いたらDockerビルドが失敗した。

```dockerfile
# NG：apt-get install の途中にパイプコマンドを混在させている
RUN apt-get update && apt-get install -y \
    curl wget git \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs
```

**原因：** `apt-get install` の引数としてパイプコマンドを渡そうとしているため、構文エラーになります。

**解決方法：** Node.jsのインストールを**別のRUN命令に分ける**。

```dockerfile
# OK：別のRUN命令に分離する
RUN apt-get update && apt-get install -y curl wget git \
    && apt-get clean

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs
```

---

### 3. WindowsのCRLF改行コードでシェルスクリプトが動かない

**状況：** DevContainerでシェルスクリプトを実行するとエラーが出た。

```bash
$ ./benchmark_index.sh
benchmark_index.sh: line 10: $'\r': command not found
```

**原因：** Windowsで作成したファイルはCRLF（`\r\n`）改行コードになっており、Linux（DevContainer）ではLF（`\n`）しか解釈できません。

**解決方法①：その場で変換する（一時的な対処）**

```bash
sed -i 's/\r//' benchmark_index.sh
```

**解決方法②：`.gitattributes` で根本解決する（恒久的な対処）**

```
# .gitattributes
* text=auto eol=lf
*.sh text eol=lf
*.sql text eol=lf
*.md text eol=lf
```

リポジトリに `.gitattributes` を追加しておくと、以降のファイルは自動的にLFに変換されます。

---

## 起動手順

```bash
# 1. リポジトリをクローン
git clone https://github.com/tsuzudev05/rdb-learning-postgres.git
cd rdb-learning-postgres

# 2. VSCode でフォルダを開く
code .

# 3. コマンドパレットを開く（Cmd/Ctrl + Shift + P）
#    「Dev Containers: Reopen in Container」を選択

# 4. コンテナ起動後、PostgreSQL への接続確認
psql $DATABASE_URL

# 5. Claude Code を起動
claude login   # 初回のみ（ブラウザでAnthropicアカウント認証）
claude         # 対話モードで起動
```

---

## Claude Codeの活用例

DevContainer内でClaudeにそのまま質問できます。

```bash
claude

# 使用例
# → EXPLAINの結果を貼って「これを読み解いて」と聞く
# → SQLエラーをそのまま貼って原因を教えてもらう
# → 「このクエリを最適化して」とコードと一緒に聞く
```

RDB学習中に詰まったらそのままターミナルで質問できるため、調べる時間が大幅に減りました。

---

## まとめ

| 詰まったポイント | 原因 | 解決方法 |
|---|---|---|
| `runArgs --env-file` が効かない | docker-compose使用時は非対応 | `docker-compose.yml` に `env_file` を書く |
| Dockerビルドエラー | apt-getにパイプコマンドを混在 | Node.jsのインストールを別RUNに分離 |
| シェルスクリプトが動かない | WindowsのCRLF改行コード | `sed -i 's/\r//'` または `.gitattributes` で解決 |

設定ファイル一式はGitHubで公開しています。クローンしてすぐ使えます。

---

*この記事で使用した設定ファイルはすべて以下のリポジトリで公開しています。*
https://github.com/tsuzudev05/rdb-learning-postgres