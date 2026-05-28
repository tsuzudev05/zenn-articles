---
title: "ZedエディタでDevContainerを使う on Windows ― 詰まったエラー2つと解決策"
emoji: "🐳"
type: "tech"
topics: ["zed", "devcontainer", "docker", "windows", "個人開発"]
published: false
---

## はじめに

VSCodeからZedエディタに移行しようとしたとき、「DevContainerはZedで使えるの？」が最初の疑問でした。

結論：**使えます**。ただしWindows環境では2つのエラーに引っかかりました。同じところで詰まる人の助けになればと思い、セットアップの流れとエラーの解決策をまとめます。

## 環境

- OS: Windows 11
- Zed: v1.4.2
- Docker Desktop: 使用（WSL2バックエンド）
- プロジェクト: PostgreSQL 16 / Go 1.22 / C++17 を使うDDD学習リポジトリ

## 前提：Zed の DevContainer サポートについて

ZedのDevContainer機能は2026年1月にリリースされ、現在も開発中のフィーチャーです。基本的な動作は次のとおりです。

- `.devcontainer/devcontainer.json` があるプロジェクトを開くと自動でプロンプトが表示される
- 「Open in Container」を選ぶとビルド → 起動 → 接続まで自動でやってくれる
- 接続後のターミナル・LSP・タスク実行はすべてコンテナ内で動く

**VSCode拡張（`customizations.vscode`）は反映されません**。ZedはZed独自の拡張エコシステムなので、言語サーバーはZedが自動で管理します。

## セットアップ手順

### 1. Docker Desktopを起動する

Zedは内部で `docker` コマンドを直接呼び出します。Docker Desktopが起動していないとコンテナが立ち上がりません。

### 2. 環境変数を設定する（`remoteEnv` を使っている場合）

`devcontainer.json` で `${localEnv:xxx}` を参照している場合、Windowsのユーザー環境変数に設定する必要があります。

```json
"remoteEnv": {
  "GIT_USER_NAME": "${localEnv:GIT_USER_NAME}",
  "GIT_USER_EMAIL": "${localEnv:GIT_USER_EMAIL}"
}
```

`Win + S` → 「システム環境変数の編集」→ユーザー環境変数に追加して、Zedを再起動します。

> **`.env` + `source` ではダメ？**
>
> `source .env` で設定した変数はそのシェルセッションのみ有効で、GUIアプリのZedには引き継がれません。スタートメニューからZedを起動する場合はシステム環境変数に設定するのが確実です。

### 3. プロジェクトを開いてコンテナで起動

`rdb-learning-postgres` フォルダをZedで開くと「Open in Container」プロンプトが表示されます。

表示されない場合はコマンドパレット（`Ctrl + Shift + P`）から `Project: Open Remote` を実行します。

---

## エラー1：`exit code: 126` でビルドが失敗する

### エラー内容

```
failed to solve: process "...devcontainer-features-install.sh" did not complete
successfully: exit code: 126
Failed to start dev container: DevContainerUpFailed
```

### 原因

`devcontainer.json` の `features` セクションで指定したフィーチャーのインストールスクリプトが、Windowsのファイルシステムとの権限の兼ね合いで実行できない（exit code 126 = permission denied）。

```json
// これが原因
"features": {
  "ghcr.io/devcontainers/features/git:1": {}
}
```

### 解決策

**Dockerfileで既にインストールしているツールを `features` で再インストールしない。**

今回のDockerfileを確認すると、`apt-get install -y git` で既にgitが入っていました。

```dockerfile
RUN apt-get update && apt-get install -y \
    curl wget git vim bash-completion \
    ...
```

`features` は完全に不要だったので、`devcontainer.json` から丸ごと削除しました。

```diff
- "features": {
-   "ghcr.io/devcontainers/features/git:1": {}
- },
```

**教訓：** `devcontainer.json` で `features` を使う前に、Dockerfileと重複していないか確認する。特にWindowsではスクリプトの実行権限問題が起きやすい。

---

## エラー2：コンテナ名の競合でビルドが失敗する

### エラー内容

```
Conflict. The container name "/pg-dev" is already in use by container "0061c1a7...".
You have to remove (or rename) that container to be able to reuse that name.
```

### 原因

エラー1で失敗したビルドの途中で、PostgreSQLコンテナ（`pg-dev`）だけが中途半端に起動・停止した状態で残っていた。2回目の起動時に名前が衝突した。

### 解決策

Docker Desktopのターミナル（またはGit Bash）で残ったコンテナを削除してから再起動する。

```bash
# 残ったコンテナを強制削除
docker rm -f pg-dev

# 念のためネットワークも削除（エラーが出ても無視してOK）
docker network rm rdb-learning-postgres_devcontainer_dev-network
```

削除後にZedで再度「Open in Container」を選ぶと正常に起動しました。

---

## 番外：無視してよいエラー

ログに以下が出ることがありますが、動作には影響しません。

```
pull access denied for rdb_le-8febdd3cc0dba9dd-features, repository does not exist
```

Zedがキャッシュされたfeatureイメージをまずpullしようとして失敗し、ローカルビルドにフォールバックする挙動です。正常です。

---

## 起動後の確認

コンテナへの接続に成功するとZedのタイトルバーにコンテナ名が表示されます。ターミナル（`Ctrl + ~`）を開くとコンテナ内のbashが起動します。

```bash
# Go の動作確認
go version
# → go version go1.22.3 linux/amd64

# PostgreSQL 接続確認
psql -U postgres -h postgres -d learning -c "SELECT version();"
```

## まとめ

| エラー | 原因 | 解決策 |
|---|---|---|
| exit code: 126 | `features` のスクリプトが実行不可 | Dockerfileと重複する `features` を削除 |
| コンテナ名の競合 | 前回の失敗でコンテナが残存 | `docker rm -f <コンテナ名>` で削除 |

ZedのDevContainerサポートはまだ発展途上ですが、基本的なワークフローは十分機能します。VSCodeで使っていた `devcontainer.json` がほぼそのまま使えるのは便利です。同じ環境で詰まっている方の参考になれば幸いです。

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
