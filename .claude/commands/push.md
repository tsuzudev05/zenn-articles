# /push — Zenn 記事バックログ確認・ステータス更新・Git 同期

`push.yml` を読み込んで Zenn 記事の投稿管理と Git への同期を行う。

## 実行手順

### STEP 1: ステータスサマリー表示

`push.yml` を読み込み、以下のフォーマットで表示する。

```
## Zenn 記事ステータス

### 📝 draft（執筆中・未着手）
- [slug] タイトル
  memo: xxx

### 👀 review（投稿判断待ち）
- [slug] タイトル
  memo: xxx

### ✅ done（投稿済み）
- [slug] タイトル（投稿日: YYYY-MM-DD）
```

### STEP 2: Git 未 push 状態チェック

以下を実行して未同期ファイルを検出する。

```bash
# 未コミットの変更（untracked / modified / staged）
git status --short

# コミット済みだが未 push のコミット
git log --oneline @{u}..HEAD 2>/dev/null || git log --oneline origin/main..HEAD 2>/dev/null
```

### STEP 3: 未 push のファイルを自動コミット・push

STEP 2 で未同期ファイルが見つかった場合、以下を実行する。

```bash
# 対象: push.yml / articles/*.md の変更のみを対象とする
git add push.yml articles/

# 変更内容に応じたコミットメッセージを自動生成する
# 例: "docs: Zenn 記事ステータス更新・新規ドラフト追加"
git commit -m "<自動生成メッセージ>"

git push
```

コミットメッセージの自動生成ルール：
- `push.yml` のみ変更 → `chore: Zenn バックログ更新（<変更概要>）`
- 記事ファイルが追加された → `docs: Zenn 記事ドラフト追加（<slug>）`
- 記事ファイルが更新された → `docs: Zenn 記事更新（<slug>）`
- 複数ファイルが混在 → `docs: Zenn 記事・バックログ更新`

未同期ファイルがなければ「✅ すでに最新です」と表示して終了する。

---

## 引数あり操作

`$ARGUMENTS` がある場合は以下の操作を行い、その後 STEP 2〜3 を実行する。

### `done <slug> [published_at]`
指定した slug の status を `done` に変更し、`published_at` を記録する。
`published_at` を省略した場合は今日の日付（YYYY-MM-DD 形式）を使用する。

例:
- `/push done github-actions-issue-from-yaml`
- `/push done github-actions-issue-from-yaml 2026-05-25`

### `review <slug>`
指定した slug の status を `draft` → `review` に変更する。

例:
- `/push review zenn-article-cpp-value-objects`

### `add <slug> <title>`
新しい記事を `status: draft` で `push.yml` に追加する。
`articles/` に対応する `.md` ファイルも作成する（Zenn フロントマター付き）。

例:
- `/push add ddd-go-usecase "Go でDDDユースケース層を実装する"`

---

## ルール

- `articles/` と `push.yml` 以外はコミット対象に含めない
- Zenn 記事ファイルは `published: false` で作成する（公開判断は人間が行う）
- push 完了後は結果をサマリー表示する
