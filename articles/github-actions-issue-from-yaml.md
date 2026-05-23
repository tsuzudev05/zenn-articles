---
title: "YAMLをpushするだけでGitHub Issueを自動登録する仕組みをGitHub Actionsで作った"
emoji: "📋"
type: "tech"
topics: ["githubactions", "github", "yaml", "devcontainer", "ポートフォリオ"]
published: false
---

## はじめに

個人開発でGitHub Issueを使ってバックログを管理しているのですが、IssueをGitHub UIから手動登録するのが地味に面倒でした。

- ブラウザを開く
- タイトル・本文・ラベルをポチポチ入力する
- 何件もある場合はこれを繰り返す

「ローカルのファイルに書いてpushするだけで登録できたら楽なのに」と思い、GitHub Actionsで自動化しました。

---

## 作った仕組みの概要

```
issues/backlog.yml  ← ここにIssue定義を書く
       ↓ push
GitHub Actions が起動
       ↓
gh issue create でIssueを自動作成
```

`issues/backlog.yml` を編集してmainにpushするだけで、未登録のIssueが自動作成されます。重複防止の仕組みも入っているので、同じタイトルのIssueが二重に作られることはありません。

---

## backlog.yml の書き方

```yaml
# issues/backlog.yml
issues:
  - title: "フェーズ4補完: PgTeamRepository / PgPeriodRepository 実装"
    labels: ["enhancement", "C++"]
    body: |
      ## 概要
      フェーズ4（libpqxx 実装）で Team / Period の Repository が未実装のため追加する。

      ## 成果物
      - `src/infrastructure/repository/PgTeamRepository.hpp`
      - `src/infrastructure/repository/PgPeriodRepository.hpp`

  - title: "Go 拡張: Team / Period / Objective / KeyResult の DDD 実装"
    labels: ["enhancement", "Go"]
    body: |
      ## 概要
      Go 側は現在 User のみ実装済み。残る集約を追加する。
```

ファイルを編集 → `git push` だけでIssueが登録されます。

---

## GitHub Actions ワークフロー

```yaml
# .github/workflows/create-issues.yml
name: Create Issues from Backlog

on:
  push:
    paths:
      - "issues/backlog.yml"
    branches:
      - main
  workflow_dispatch:  # GitHub UI からも手動実行できる

jobs:
  create-issues:
    runs-on: ubuntu-latest
    permissions:
      issues: write
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Install yq
        run: |
          wget -qO /usr/local/bin/yq \
            https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
          chmod +x /usr/local/bin/yq

      - name: Create labels if not exist
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          REPO: ${{ github.repository }}
        run: |
          gh label create "enhancement" --repo "$REPO" --color "a2eeef" --force
          gh label create "C++"        --repo "$REPO" --color "f29513" --force
          gh label create "Go"         --repo "$REPO" --color "00ADD8" --force

      - name: Create issues from backlog.yml
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          REPO: ${{ github.repository }}
        run: |
          COUNT=$(yq '.issues | length' issues/backlog.yml)
          echo "📋 登録対象: ${COUNT} 件"

          for i in $(seq 0 $((COUNT - 1))); do
            TITLE=$(yq ".issues[$i].title" issues/backlog.yml)
            BODY=$(yq ".issues[$i].body" issues/backlog.yml)
            LABELS=$(yq ".issues[$i].labels | join(\",\")" issues/backlog.yml)

            # 重複防止：同タイトルが既に存在すればスキップ
            EXISTING=$(gh issue list \
              --repo "$REPO" --state all \
              --search "\"${TITLE}\" in:title" \
              --json title \
              --jq "[.[].title | select(. == \"${TITLE}\")] | length")

            if [ "$EXISTING" -gt 0 ]; then
              echo "⏭️  スキップ（既存）: ${TITLE}"
            else
              gh issue create \
                --repo "$REPO" \
                --title "${TITLE}" \
                --body "${BODY}" \
                --label "${LABELS}" \
              && echo "✅ 作成: ${TITLE}"
            fi
          done
```

---

## ポイント解説

### yq で YAML を読む

シェルスクリプトからYAMLを扱うために `yq` を使っています。`jq` のYAML版のようなツールで、配列要素への添字アクセスや `join()` が使えます。

```bash
COUNT=$(yq '.issues | length' issues/backlog.yml)         # 件数
TITLE=$(yq ".issues[$i].title" issues/backlog.yml)        # タイトル
LABELS=$(yq ".issues[$i].labels | join(\",\")" issues/backlog.yml)  # ラベル
```

### ラベルを事前に作成する（`--force`）

`gh issue create --label "C++"` はラベルがリポジトリに存在しないと失敗します。先に `gh label create --force` でラベルを作成しておきます。`--force` を付けると既存ラベルがあっても上書き（エラーにならない）します。

```bash
gh label create "C++" --repo "$REPO" --color "f29513" --force
```

最初はこれを忘れて全件失敗しました。

### 重複防止

`gh issue list --search` でタイトルを検索し、既存の場合はスキップします。`--state all` で closed な Issue も対象にしているため、一度完了したIssueを再登録することもありません。

```bash
EXISTING=$(gh issue list \
  --repo "$REPO" --state all \
  --search "\"${TITLE}\" in:title" \
  --json title \
  --jq "[.[].title | select(. == \"${TITLE}\")] | length")
```

### `workflow_dispatch` を追加する理由

最初は `push` トリガーのみで作りました。しかしGitHub Actionsの **Re-run は元のコミット時点のワークフローで実行される** 仕様があります。

ワークフローを修正してpushしたのに、Re-runすると修正前のワークフローが動いてしまう、という落とし穴にハマりました。

`workflow_dispatch` を追加しておくと、GitHub UIの「Run workflow」ボタンから**常に最新のワークフローで**実行できます。Re-runではなくこちらを使うのが安全です。

```yaml
on:
  push:
    paths:
      - "issues/backlog.yml"
    branches:
      - main
  workflow_dispatch:  # ← これを追加
```

---

## DevContainer での手動登録（即時版）

`gh` CLIをDockerfileに入れておけば、DevContainer内から即時登録もできます。

```dockerfile
# .devcontainer/Dockerfile
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
```

DevContainer内で：

```bash
gh auth login
gh issue create --title "タイトル" --body "本文" --label "enhancement"
```

---

## まとめ

| 詰まったポイント | 原因 | 解決方法 |
|---|---|---|
| `could not add label: 'C++' not found` | ラベルがリポジトリに存在しない | Issue 作成前に `gh label create --force` でラベルを作成 |
| Re-run しても修正が反映されない | Re-run は元のコミット時のワークフローで動く | `workflow_dispatch` を追加して「Run workflow」から実行 |

`issues/backlog.yml` にIssue定義を書いてpushするだけで自動登録される仕組みはとても快適です。特に複数のIssueをまとめて登録したいときに効果を発揮します。

---

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
