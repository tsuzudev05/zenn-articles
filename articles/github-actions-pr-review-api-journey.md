---
title: "GitHub Actions で AI 自動レビューを作るまでに全 API でハマった記録"
emoji: "🔥"
type: "tech"
topics: ["githubactions", "claude", "gemini", "groq", "python"]
published: false
---

## はじめに

PR が来たら AI が自動でコードレビューしてくれる仕組みを作ろうとした。
やることは単純だ。diff を取って AI API に投げ、結果を PR コメントに投稿する。

```
PR open → diff 取得 → AI API → PR コメント投稿
```

…のはずだった。

Claude → Gemini → Groq と3つのサービスを渡り歩き、のべ10回以上エラーを踏んでようやく動いた。
同じ沼にハマる人のために全記録を残す。

## 最終的な構成

| 項目 | 内容 |
|---|---|
| 実行基盤 | GitHub Actions |
| AI モデル | Llama 3.3 70B（Groq） |
| コスト | $0（クレカ不要） |
| トリガー | PR open / synchronize / reopened |

---

## 第1章：Claude Haiku（Anthropic）

### なぜ Claude を選んだか

DDD・C++17・Go に詳しいレビュアーが欲しかった。Claude Haiku はコスト安（$0.80/$4.00 per 1M tokens）で日本語も強い。

### エラー① `Illegal header value b'***'`

```
httpx.LocalProtocolError: Illegal header value b'***'
anthropic.APIConnectionError: Connection error.
```

`b'***'` はGitHub Actions がシークレット値をマスクした表示。API キーをHTTP ヘッダーとして送る際に `h11` ライブラリが弾いた。

**原因：** GitHub Secret への貼り付け時に末尾の改行が混入していた。`.strip()` では端しか除去できないので、正規表現で印字可能 ASCII 以外を全除去する関数を実装した。

```python
def sanitize_api_key(raw: str) -> str:
    cleaned = re.sub(r"[^\x21-\x7E]", "", raw)  # 印字可能 ASCII のみ残す
    if len(raw) != len(cleaned):
        print(f"[info] sanitize: {len(raw)} → {len(cleaned)} 文字")
    return cleaned
```

### エラー② キー名をそのまま貼り付けた

```
[warn] ANTHROPIC_API_KEY が想定外の形式です（先頭8文字: 'github-a'）
anthropic.AuthenticationError: 401 - invalid x-api-key
```

セットアップドキュメントに書いた「キー名の例」（`github-actions-rdb`）を Value に貼っていた。`sanitize_api_key` に追加した形式チェックのデバッグログで即座に判明した。

**教訓：** ログに先頭数文字だけ出すと、全体を晒さずに設定ミスを検出できる。

### エラー③ クレジット残高不足

```
anthropic.BadRequestError: 400
Your credit balance is too low to access the Anthropic API.
```

Anthropic API はプリペイド制。**最低 $5 のチャージ**が必要。

→ 無料で使いたいので Gemini に切り替えを決断。

---

## 第2章：Gemini（Google AI Studio）

「AI Studio のキーは無料枠（1,500 req/日）があってクレカ不要」と思っていた。**その認識は半分間違いだった。**

### エラー① `gemini-2.0-flash` で 429、`limit: 0`

```
google.genai.errors.ClientError: 429 RESOURCE_EXHAUSTED
* Quota exceeded for metric: generate_content_free_tier_requests, limit: 0
```

`limit: 0` に注目。クォータが超過したのではなく、**そもそも上限が 0** に設定されている。

**原因：** Google Cloud プロジェクトに課金アカウントが紐づいていないと、フリー枠クォータが 0 になる。「無料枠あり」と「クレカ不要」は別物だった。

モデルを変えても根本原因は変わらないのに、ここで3モデルを試した。

### エラー② `gemini-1.5-flash` で 404

```
404 NOT_FOUND
models/gemini-1.5-flash is not found for API version v1beta
```

`google-genai` SDK（v1beta）では `gemini-1.5-flash` が廃止済みだった。

### エラー③ `gemini-2.0-flash-lite` でも 429、`limit: 0`

同上。モデルを変えても意味なし。**問題はプロジェクト設定にある。**

### 新しいプロジェクトで API キーを作り直した

AI Studio で「Create API key in **new project**」からキーを再発行。これで課金設定に関係なくフリー枠が使えると思っていたが……

```
429 - Your prepayment credits are depleted.
Please go to AI Studio at https://ai.studio/projects to manage your project and billing.
```

新プロジェクトのプリペイドクレジットが尽きた。

**結論：** Google の仕様として、課金アカウントを紐づけないとフリー枠クォータは 0 のまま。クレカ登録なしで Gemini API を使うのは難しい。

---

## 第3章：Groq API（最終解）

完全無料・クレカ不要。[console.groq.com](https://console.groq.com) でアカウント登録 → API キー発行だけで使える。

```python
from groq import Groq

client = Groq(api_key=os.environ["GROQ_API_KEY"])
chat_completion = client.chat.completions.create(
    messages=[
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": user_message},
    ],
    model="llama-3.3-70b-versatile",
    max_tokens=2048,
)
review = chat_completion.choices[0].message.content
```

### エラー① 401 Invalid API Key

```
groq.AuthenticationError: 401 - Invalid API Key
```

GitHub Secret の `GROQ_API_KEY` に間違った値が入っていた。コードは正しかった。

### エラー② 413 Request too large

```
groq.APIStatusError: 413
Limit 12,000, Requested 27,305 tokens
```

無料枠の TPM（トークン/分）上限が 12,000 に対して、80,000文字の diff が約27,000トークンになってしまった。

**修正：** `MAX_DIFF_CHARS` を 80,000 → **25,000** に縮小。

```python
MAX_DIFF_CHARS = 25_000  # 約8,500トークン、TPM 上限に余裕を持たせる
```

### 寄り道：インラインコメント方式を試みた

「PR の該当行に直接コメントしたい」という欲が出て、GitHub Reviews API + JSON 出力に変更した。ところが Llama が `summary` フィールドを複数のキーに分散させる誤動作が発生。

```json
// Llamaが返した壊れたJSON（一部）
{
  "summary": "## ヘッダー",
  "\n\n### 概要\n": "内容...",
  "\n\n### 良い点": ["- DDD設計...", "- テスト..."]
}
```

プロンプトを簡略化したり、パーサーを強化したりしたが安定しなかった。**シンプルな方式に戻した方が確実**と判断し、全体評価コメント方式に revert した。

### 最終的に動いた

```
[info] diff: 24,891 文字
[info] llama-3.3-70b-versatile（Groq）にリクエスト中...
[info] 完了 — input: 7,821 tok / output: 634 tok / 参考コスト: $0.0051
[info] コメント投稿完了: https://github.com/tsuzudev05/rdb-learning-postgres/pull/XX#issuecomment-XXXXXXX
```

PR の Conversation タブにこのようなコメントが投稿された。

```markdown
## 🤖 AI コードレビュー（Llama 3.3 70B / Groq）

### 概要
Go（pgx）による UserRepository の実装を追加している。...

### ✅ 良い点
- DDD の Repository パターンに沿ったインターフェース設計
- pgxpool を使用した接続プールの適切な管理
...

### 📊 総評
LGTM
```

---

## まとめ：各 API 比較

| | Claude Haiku | Gemini Flash | Groq |
|---|---|---|---|
| **無料枠** | なし | あり（要カード） | あり（カード不要） |
| **セットアップ** | △ | △（カード必須） | ◎ |
| **モデル品質** | ◎ | ○ | ○ |
| **安定性** | ◎ | △ | △ |
| **個人利用コスト** | $5〜 | $0 | $0 |

個人開発の自動レビューには **Groq が一番手軽**。モデル品質を重視するなら Claude（クレジット購入）が最善。

---

## ハマりポイント早見表

| エラー | 原因 | 対処 |
|---|---|---|
| `Illegal header value b'***'` | Secret に改行混入 | `re.sub(r"[^\x21-\x7E]", "", key)` |
| `401 invalid x-api-key` | キー名を Value に貼った | Anthropic Console から正しいキーを取得 |
| `400 credit balance too low` | Anthropic 残高不足 | $5 以上チャージ |
| `429 limit: 0`（Gemini） | 課金アカウント未設定 | カード登録 or 別サービスへ |
| `404 NOT_FOUND`（Gemini） | モデル廃止 | 別モデルに変更 |
| `401 Invalid API Key`（Groq） | Secret の値が間違い | Secret を正しい値で更新 |
| `413 Request too large`（Groq） | diff がTPM上限超過 | `MAX_DIFF_CHARS` を縮小 |

---

## 教訓

1. **「無料枠あり」と「クレカ不要」は別物**（Gemini はカード登録しないとクォータが 0）
2. **エラーメッセージをよく読む**（`limit: 0` と `balance too low` は全く別の問題）
3. **API キーは登録直後に動作確認する**（後から気づくとデバッグが辛い）
4. **シンプルさを保つ**（インライン方式に挑戦したが、LLM の JSON 出力は不安定。全体評価コメントで十分）
5. **うまくいかなかったら別サービスに切り替える勇気も必要**

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
