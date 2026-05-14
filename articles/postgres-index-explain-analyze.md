---
title: "PostgreSQLのインデックスをEXPLAIN ANALYZEで体感する ― UNIQUE制約の罠も解説"
emoji: "🔍"
type: "tech"
topics: ["PostgreSQL", "RDB", "SQL", "初心者", "データベース"]
published: false
---

## はじめに

「インデックスを貼ると速くなる」とは知っていても、実際にどう変わるのかを手で確認したことがありませんでした。

C++/Rustエンジニアとして日々開発していますが、ポートフォリオ開発に向けてRDBを基礎から学ぶことにしました。この記事では、実際に手を動かして気づいた **UNIQUE制約の罠** と、**Seq Scan → Index Scan に変化する様子** を記録します。

同じように「なんとなく知っているが手で確認したことがない」という方の参考になれば幸いです。

---

## 環境

| 項目 | 内容 |
|---|---|
| PostgreSQL | 16 |
| 実行環境 | VSCode DevContainer（Docker） |
| 使用テーブル | `users`（10,003件） |

---

## 検証の準備：10,000件のデータを生成する

インデックスの効果を体感するには、ある程度の件数が必要です。`generate_series` を使って一気に10,000件を投入します。

```sql
INSERT INTO users (name, email)
SELECT
    '田中' || i,
    'user' || i || '@example.com'
FROM generate_series(1, 10000) AS i
ON CONFLICT DO NOTHING;

-- 件数確認
SELECT COUNT(*) FROM users;
-- → 10003
```

---

## 最初の罠：emailカラムでSeq Scanが出なかった

まず `email` カラムで検証しようとしました。

```sql
EXPLAIN ANALYZE
SELECT * FROM users WHERE email = 'user5000@example.com';
```

**結果**

```
Index Scan using users_email_key on users
  (cost=0.29..8.30 rows=1 width=42)
  (actual time=0.009..0.009 rows=1 loops=1)
Planning Time: 0.159 ms
Execution Time: 0.019 ms
```

インデックスを作成していないのに **最初から Index Scan になっていました。**

### 原因：UNIQUE制約には暗黙のインデックスが存在する

`users` テーブルの `email` カラムには `UNIQUE NOT NULL` 制約がついていました。

```sql
email VARCHAR(255) UNIQUE NOT NULL
```

PostgreSQL は UNIQUE 制約を作った時点で **自動的にインデックスを作成します。** そのため「インデックスなし」の状態が作れなかったのです。

`\di` コマンドでインデックス一覧を確認すると、存在が分かります。

```sql
\di users*
```

```
 Index Name       | Type  | Table | Column
------------------+-------+-------+-------
 users_email_key  | btree | users | email   ← UNIQUE制約が自動作成
 users_pkey       | btree | users | id      ← PRIMARY KEYが自動作成
```

:::message
**学び：** インデックスを手動で追加する前に `\di テーブル名*` で確認する習慣をつけると、二重インデックスの無駄を防げます。
:::

---

## 正しい検証：UNIQUE制約のない `name` カラムで試す

`name` カラムに切り替えて再度検証します。

### インデックスなし（Seq Scan）

```sql
EXPLAIN ANALYZE
SELECT * FROM users WHERE name = '田中5000';
```

```
Seq Scan on users  (cost=0.00..219.04 rows=1 width=42)
                   (actual time=0.582..1.090 rows=1 loops=1)
  Filter: ((name)::text = '田中5000'::text)
  Rows Removed by Filter: 10002
Planning Time: 0.285 ms
Execution Time: 1.118 ms
```

**読み方：**
- `Seq Scan`：テーブルの全件を先頭から順番にスキャンしている
- `Rows Removed by Filter: 10002`：10,002件を読み込んで1件だけ残した

### インデックスを作成する

```sql
CREATE INDEX idx_users_name ON users(name);
```

### インデックスあり（Index Scan）

```sql
EXPLAIN ANALYZE
SELECT * FROM users WHERE name = '田中5000';
```

```
Index Scan using idx_users_name on users  (cost=0.29..8.30 rows=1 width=42)
                                          (actual time=0.016..0.016 rows=1 loops=1)
  Index Cond: ((name)::text = '田中5000'::text)
Planning Time: 0.085 ms
Execution Time: 0.024 ms
```

**読み方：**
- `Index Scan`：B-Tree インデックスを使って目的のレコードに直接アクセス
- `Rows Removed by Filter` の記載なし：無駄なスキャンがなかった

---

## 結果の比較

| 項目 | インデックスなし | インデックスあり | 改善率 |
|---|---|---|---|
| スキャン方式 | Seq Scan（全件） | Index Scan（直接） | — |
| スキャン件数 | 10,003件 | 1件 | 約10,000倍削減 |
| 実行時間 | 1.118 ms | 0.024 ms | 約46倍高速化 |

---

## なぜ速くなるのか：B-Tree構造の仕組み

PostgreSQL のデフォルトインデックスは **B-Tree（バランス木）構造** です。

```
インデックスなし：テーブルを先頭から全件スキャン → O(N)
インデックスあり：B-Treeで二分探索して直接アクセス → O(log N)
```

10,000件なら log₂(10000) ≈ 13 回の比較で見つかります。全件スキャンの10,000回と比べると差は明らかです。

---

## インデックスのトレードオフ

インデックスは SELECT を速くする一方で、デメリットもあります。

| 操作 | インデックスなし | インデックスあり |
|---|---|---|
| SELECT | 遅い | 速い ✅ |
| INSERT | 速い | 遅い（インデックスも更新が必要）|
| UPDATE | 速い | 遅い（インデックスも更新が必要）|
| DELETE | 速い | 遅い（インデックスも更新が必要）|

**貼りすぎは禁物です。** 以下のカラムに絞って使うのが原則です。

- WHERE句で頻繁に検索するカラム
- JOIN条件に使うカラム
- 読み取り頻度が書き込み頻度より高いカラム

---

## ベンチマークスクリプト

検証を自動化するシェルスクリプトも作成しました。実行するとインデックス有無を自動で比較して高速化倍率を表示します。

```bash
./benchmark_index.sh

# 出力例
# 🚀 高速化倍率: 約 46.5 倍
```

GitHubで公開しています。

https://github.com/tsuzudev05/rdb-learning-postgres

---

## まとめ

- UNIQUE制約・PRIMARY KEYには **PostgreSQLが自動でインデックスを作成する**
- インデックスを追加する前に **`\di テーブル名*`** でインデックス一覧を確認する
- `EXPLAIN ANALYZE` で **Seq Scan が出たらインデックス不足を疑う**
- インデックスは SELECT を速くするが **INSERT/UPDATE/DELETE は遅くなる**
- B-Tree構造により検索計算量が **O(N) → O(log N)** に改善される

次回はトランザクションのACID特性とデッドロックの再現について書く予定です。

---

*この記事で使用したコードはすべて以下のリポジトリで公開しています。*
https://github.com/tsuzudev05/rdb-learning-postgres