---
title: "Claude Codeのカスタムスラッシュコマンドで開発ルーティンを自動化する"
emoji: "⚡"
type: "tech"
topics: ["claudecode", "claude", "ai", "開発効率化", "git"]
published: false
---

## はじめに

Claude Code を使っていると、毎回同じプロンプトを打っていることに気づきます。

- 「git diff を見て PR のタイトルと本文を書いて」
- 「git status を見て未コミットのファイルをプッシュして」

これ、**カスタムスラッシュコマンドとして登録しておくと一発で呼び出せます**。

この記事では `.claude/commands/` にファイルを置くだけで作れる Claude Code のカスタムコマンド機能を、実例とともに紹介します。

---

## カスタムスラッシュコマンドとは

Claude Code には `/help` や `/clear` などの組み込みコマンドがありますが、**自分で追加することもできます**。

方法は簡単で、プロジェクトの `.claude/commands/` ディレクトリに Markdown ファイルを置くだけです。

```
プロジェクトルート/
└── .claude/
    └── commands/
        ├── pr-description.md   → /pr-description
        ├── zenn.md             → /zenn
        └── career-push.md      → /career-push
```

ファイル名がそのままコマンド名になります。Claude Code を起動したディレクトリの `.claude/commands/` が読み込まれるので、**プロジェクトごとにコマンドを使い分けることも、ルートに集約して全体で使うことも**できます。

---

## 実例①：git diff から PR 文を自動生成する `/pr-description`

PRを出す前に毎回「git diff を読んでいい感じに PR 文を書いて」と打っていたのを、コマンドにしました。

**`.claude/commands/pr-description.md`**

```markdown
# /pr-description — PR タイトル・本文ジェネレーター

git の差分情報から GitHub PR のタイトルと本文を生成する。
ベースブランチは引数で指定、省略時は main を使う。

## 実行手順

### STEP 1: 差分情報を収集する

以下を実行して差分情報を収集する。

​```bash
git branch --show-current
git log $BASE_BRANCH..HEAD --oneline
git diff --stat $BASE_BRANCH
git diff $BASE_BRANCH
​```

### STEP 2: PR タイトルを生成する

以下のフォーマットで生成する。

​```
<type>: <変更の要約>（50文字以内）
​```

type の選択基準:
- feat  : 新機能追加
- fix   : バグ修正
- docs  : ドキュメントのみ
- chore : 設定変更
- test  : テストのみ

### STEP 3: PR 本文を生成する

​```markdown
## 概要
## 変更内容
## テスト方法
## 関連 Issue
## チェックリスト
​```

結果はコードブロックで出力し、そのまま GitHub にコピーできる形にする。
```

使い方はこれだけです：

```bash
/pr-description        # main との差分で生成
/pr-description develop  # develop との差分で生成
```

### ポイント：なぜうまくいくのか

カスタムコマンドの中で `git diff $BASE_BRANCH` のように**シェルコマンドを実行する指示を書けます**。Claude Code は bash ツールを持っているので、コマンド内の指示に従って実際にターミナルコマンドを叩き、その結果を読んで PR 文を生成してくれます。

「差分を渡す」という手順を毎回自分でやらなくてよくなるのが大きいです。

---

## 実例②：Zenn 記事の管理コマンド `/zenn`

Zenn 記事のバックログを YAML ファイルで管理しているのですが、ステータス更新 → git push までをコマンド一発にしました。

```bash
/zenn                          # 記事ステータス一覧を表示
/zenn done <slug>              # 投稿済みにして push
/zenn review <slug>            # draft → review に昇格して push
/zenn add <slug> <title>       # 新規ドラフトを作成して push
```

コマンドファイルの中では「`push.yml` を読んでステータスを表示する」「`articles/` 配下に未 add のファイルがあれば commit して push する」といった手順を日本語で書いています。Claude Code がその通りに動いてくれます。

---

## 実例③：日次まとめを push する `/career-push`

学習ログの Markdown ファイルを毎日 push する作業もコマンド化しました。

```markdown
# /career-push

1. `git status --short` で未コミットの .md ファイルを特定する
2. ファイルパスからコミットメッセージを決定する
   - daily-summary/ 配下 → `docs: YYYY-MM-DD 日次まとめ追加`
   - week-summary/ 配下  → `docs: YYYY年Ww週 週次振り返り追加`
3. git add → git commit → git push を実行する
4. 完了を報告する
```

ファイル名から日付を読んでコミットメッセージを自動生成してくれるので、毎日の push が `/career-push` だけで完結します。

---

## 複数リポジトリを横断して使う方法

私のように複数のリポジトリ（学習用・記事用・ログ用）を 1 つのワークスペースで管理している場合、**ワークスペースルートの `.claude/commands/` に集約すると便利です**。

```
転職に向けたスキルアップ/          ← ここで claude を起動
├── .claude/
│   └── commands/
│       ├── pr-description.md     # rdb-learning-postgres の PR 文生成
│       ├── zenn.md               # zenn-articles の管理
│       └── career-push.md        # career-log の push
├── rdb-learning-postgres/
├── zenn-articles/
└── career-log/
```

各コマンドの中で `cd rdb-learning-postgres` のように**操作対象ディレクトリへの移動を明示**することで、どのコマンドがどのリポジトリを操作するかを制御できます。

---

## コマンドファイルを書くコツ

実際に使ってみてわかったことをまとめます。

**手順を番号で書く**：Claude Code は手順書どおりに動いてくれるので、「STEP 1 → STEP 2 → STEP 3」のように明確に書くと迷いなく動きます。

**引数は `$ARGUMENTS` で受け取る**：コマンド実行時に渡した引数は `$ARGUMENTS` で参照できます。`/zenn done my-article` と打つと、`$ARGUMENTS` が `done my-article` になります。

**「何をしないか」も書く**：例えば `articles/` と `push.yml` 以外はコミット対象に含めない、のように制約を明示すると誤操作を防げます。

**日本語で書いて OK**：英語でなくても問題なく動きます。読みやすさ優先で書きましょう。

---

## まとめ

Claude Code のカスタムスラッシュコマンドは、`.claude/commands/` に Markdown を置くだけで作れます。

毎回同じプロンプトを打っている作業を見つけたら、それがコマンド化のサインです。PR 文の生成・git push・バックログ更新など、ルーティン作業をコマンドに落とし込むと、Claude Code がワークフローの一部として自然に組み込まれていきます。

ぜひ自分のプロジェクトに合わせてカスタマイズしてみてください。

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
