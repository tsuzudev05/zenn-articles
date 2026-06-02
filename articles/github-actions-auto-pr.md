---
title: "GitHub Actions で PR を自動作成する――詰まったポイント5つと解決策"
emoji: "🤖"
type: "tech"
topics: ["githubactions", "github", "go", "python", "ci"]
published: false
---

## はじめに

「ブランチを push したら自動で PR を作ってほしい」——シンプルな要求に見えて、実装してみると意外な落とし穴がいくつもありました。

この記事では GitHub Actions で AI（Groq / Llama 3.3 70B）を使った PR 自動作成ワークフローを実装する過程で詰まったポイントを5つまとめます。

完成したワークフローの概要はこうです。

```
ブランチを push or Actions から手動実行
  ↓
git diff origin/main...origin/feature/xxx で差分取得
  ↓
Groq（Llama 3.3 70B）が PR タイトル・本文を日本語生成
  ↓
GitHub REST API で PR 自動作成
  ↓
ai-review.yml が PR opened を検知してコードレビューも自動実行
```

---

## 詰まりポイント① GITHUB_TOKEN では PR が作れない

最初に `gh pr create` を使った実装を書いたところ、以下のエラーが出ました。

```
pull request create failed: GraphQL: GitHub Actions is not permitted to create or approve pull requests (createPullRequest)
```

### 原因

GitHub Actions のデフォルト設定では `GITHUB_TOKEN` に PR 作成権限がありません。

### 解決策A（Settings で許可）

`Settings → Actions → General → Workflow permissions` で以下を設定します。

- **"Read and write permissions"** を選択
- **"Allow GitHub Actions to create and approve pull requests"** にチェック
- **Save** を押す（押し忘れに注意）

### 解決策B（PAT を使う）← こちらを採用

`GITHUB_TOKEN` の制限を完全に回避するために、Personal Access Token（PAT）を使います。

1. `https://github.com/settings/tokens` で classic PAT を作成（`repo` スコープのみ）
2. `Settings → Secrets → Actions` に `GH_PAT` として登録
3. `gh` CLI の代わりに GitHub REST API を直接呼ぶ

```python
def create_pr_via_api(title, body, head, base, repo):
    token = os.environ.get("GH_PAT") or os.environ.get("GITHUB_TOKEN")
    url  = f"https://api.github.com/repos/{repo}/pulls"
    data = json.dumps({"title": title, "body": body,
                       "head": head, "base": base}).encode()
    headers = {
        "Authorization":        f"Bearer {token}",
        "Accept":               "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req) as resp:
        result = json.loads(resp.read())
        print(f"✅ PR created: {result['html_url']}")
```

PAT はトークン形式が `ghp_` から始まります。

---

## 詰まりポイント② Re-run は変更を拾わない

Settings の権限変更後、失敗したジョブを **Re-run** しても同じエラーが出続けました。

### 原因

Re-run は**同じジョブの再実行**であり、ワークフローファイルやシークレットの変更を反映しません。

### 解決策

権限変更・シークレット追加・ワークフロー修正後は必ず**新しいトリガーで実行**します。

- `push` トリガー：新しいコミットを push する
- `workflow_dispatch` トリガー：Actions タブから **Run workflow** ボタンを押す

---

## 詰まりポイント③ Run workflow ボタンが表示されない

`workflow_dispatch` を追加したのに、Actions タブに「Run workflow」ボタンが出ませんでした。

### 原因

`workflow_dispatch` のボタンは**デフォルトブランチ（main）にワークフローファイルが存在するときだけ**表示されます。feature ブランチにしかファイルがない状態では表示されません。

### 解決策

ワークフローファイルだけを先に main へ push します。

```bash
git checkout main
git checkout feature/xxx -- .github/workflows/auto-pr.yml
git checkout feature/xxx -- scripts/auto_pr.py
git add .github/workflows/auto-pr.yml scripts/auto_pr.py
git commit -m "ci: auto PR 作成ワークフロー追加"
git push origin main
```

---

## 詰まりポイント④ スクリプトが feature ブランチの古い版で動く

main にワークフローを push して Run workflow を実行しても、修正前の古いスクリプトが動き続けました。

### 原因

Checkout ステップで **feature ブランチを checkout** していたため、スクリプトも feature ブランチの古い版が使われていました。

```yaml
# ❌ これが原因
- uses: actions/checkout@v4
  with:
    ref: ${{ inputs.head_branch || github.ref }}  # feature ブランチを checkout
```

### 解決策

スクリプトは常に main から取得し、差分取得だけ feature ブランチを参照します。

```yaml
# ✅ main を checkout してスクリプトを取得
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
    ref: main

# feature ブランチは fetch だけする
- run: git fetch origin ${{ inputs.head_branch || github.ref_name }}

# diff は origin/xxx 形式で明示的に指定
- run: |
    git diff origin/main...origin/${{ env.HEAD_BRANCH }} > diff.txt
```

---

## 詰まりポイント⑤ 「Use workflow from」で間違ったブランチを選ぶ

Run workflow ダイアログに **"Use workflow from"** というブランチ選択欄があり、ここで feature ブランチを選んでしまうと feature ブランチのワークフローが動きます。

### 原因

`workflow_dispatch` は「どのブランチのワークフロー定義を使うか」を毎回選択できます。feature ブランチを選ぶと古い定義が使われます。

### 解決策

**常に `Branch: main` を選択**します。ワークフローコメントにも明記しておくと忘れにくいです。

```yaml
on:
  # 手動実行は必ず "Use workflow from: main" を選択すること
  workflow_dispatch:
    inputs:
      head_branch:
        description: "PR にするブランチ名"
        required: true
        type: string
```

---

## 完成したワークフロー全体

```yaml
name: Auto PR Creator

on:
  # 手動実行は必ず "Use workflow from: main" を選択すること
  workflow_dispatch:
    inputs:
      head_branch:
        description: "PR にするブランチ名（例: feature/xxx）"
        required: true
        type: string
      base_branch:
        description: "マージ先ブランチ（デフォルト: main）"
        required: false
        default: "main"
        type: string

jobs:
  create-pr:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write

    steps:
      - name: Checkout main (scripts always from main)
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          ref: main

      - name: Fetch head branch
        run: git fetch origin ${{ inputs.head_branch }}

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install dependencies
        run: pip install groq

      - name: Resolve branch names
        run: |
          echo "HEAD_BRANCH=${{ inputs.head_branch }}" >> $GITHUB_ENV
          echo "BASE_BRANCH=${{ inputs.base_branch || 'main' }}" >> $GITHUB_ENV

      - name: Generate diff
        run: |
          git diff origin/${{ env.BASE_BRANCH }}...origin/${{ env.HEAD_BRANCH }} \
            -- . ':(exclude)*.sum' ':(exclude)*.lock' > diff.txt

      - name: Get commit log
        run: |
          LOG=$(git log origin/${{ env.BASE_BRANCH }}..origin/${{ env.HEAD_BRANCH }} --oneline)
          echo "COMMIT_LOG<<EOF" >> $GITHUB_ENV
          echo "$LOG"           >> $GITHUB_ENV
          echo "EOF"            >> $GITHUB_ENV

      - name: Create PR with AI-generated description
        env:
          GROQ_API_KEY: ${{ secrets.GROQ_API_KEY }}
          GH_PAT:       ${{ secrets.GH_PAT }}
          HEAD_BRANCH:  ${{ env.HEAD_BRANCH }}
          BASE_BRANCH:  ${{ env.BASE_BRANCH }}
          REPO:         ${{ github.repository }}
          COMMIT_LOG:   ${{ env.COMMIT_LOG }}
        run: python scripts/auto_pr.py
```

---

## まとめ

| 詰まりポイント | 原因 | 解決策 |
|---|---|---|
| PR 作成権限エラー | `GITHUB_TOKEN` のデフォルト制限 | PAT（`GH_PAT`）を使う |
| Re-run で変更が反映されない | Re-run は同じジョブを再実行する | 新しいトリガーで実行する |
| Run workflow ボタンが出ない | ファイルが main にない | ワークフローファイルを先に main に push |
| 古いスクリプトが動く | feature ブランチを checkout していた | `ref: main` で固定し diff は `origin/xxx` で取る |
| Use workflow from の選択ミス | 手動実行時にブランチを選べる | 常に main を選ぶ・コメントで明記 |

GitHub Actions は「動いている」ように見えて設定ミスが発見しにくいのが難点です。エラーが出たときは「どのブランチのどのファイルが実行されているか」を起点に調べると原因に早くたどり着けます。

---

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
