---
title: "PostgreSQLでデッドロックを意図的に再現する ― Pythonのthreadingで2セッションを同時実行"
emoji: "💀"
type: "tech"
topics: ["PostgreSQL", "RDB", "Python", "データベース", "SQL"]
published: false
---

## はじめに

「デッドロックは2つのトランザクションが互いにロック解除を待ち続ける状態」とは知っていても、実際にエラーを目にしたことがありませんでした。

この記事では、Pythonの `threading` を使って2セッションを**真の同時実行**で動かし、`deadlock detected` エラーを実際に再現した記録をまとめます。

途中でシェルスクリプトでの実装を3回失敗しており、**なぜうまくいかなかったか**も正直に書いています。

---

## 環境

| 項目 | 内容 |
|---|---|
| PostgreSQL | 16 |
| Python | 3.x（psycopg2使用） |
| 実行環境 | VSCode DevContainer（Docker） |
| 使用テーブル | `tasks`（id=1, id=2） |

---

## デッドロックとは

2つのトランザクションが**お互いに相手のロック解除を永久に待ち続ける状態**です。

```
セッションA: id=1をロック済み → id=2のロックを待つ ⏳
セッションB: id=2をロック済み → id=1のロックを待つ ⏳
→ 両者が永遠に待ち続けて先に進めない
```

PostgreSQLは約1秒でデッドロックを自動検知し、**片方を強制ROLLBACKして解消**します。

---

## シェルスクリプトで3回失敗した話

最初はシェルスクリプトで実装しようとしましたが、うまくいきませんでした。

### 失敗1：psqlを複数回呼び出す

```bash
psql $DB -c "BEGIN; UPDATE tasks SET status='done' WHERE id=1;"
# ↑ ここでpsqlプロセスが終了 → トランザクションが消える
psql $DB -c "UPDATE tasks SET status='done' WHERE id=2;"
# ↑ 別のpsqlプロセス = 別のセッション = BEGINの続きにならない
```

**原因：** psqlを1回呼び出すごとに新しいセッションが生まれるため、`BEGIN` したトランザクションが引き継がれません。

### 失敗2：ヒアドキュメントで1プロセスにまとめる

```bash
psql $DB << 'SQL'
BEGIN;
UPDATE tasks SET status='done' WHERE id=1;
SQL
# ↑ ここで処理が終わってしまう。次のSQLを「待機中」にできない
```

**原因：** ヒアドキュメントはまとめて送り切るため、セッション間の「同期」ができません。

### 失敗3：名前付きパイプ（mkfifo）で同期する

```bash
mkfifo /tmp/pipe_a
psql $DB < /tmp/pipe_a &
echo "BEGIN;" > /tmp/pipe_a
# → ここでブロックした（止まった）
```

**原因：** `mkfifo` は読み手がいないと書き込みでブロックする仕様があり、2セッションの同時実行には向いていません。

---

## Pythonの `threading` で解決した

`threading.Event` を使うと、スレッド間で「ここまで終わったら通知する」という同期ポイントを作れます。

```python
import psycopg2
import threading

DB = "postgresql://postgres:pass@postgres:5432/learning"

# セッション間の同期用イベント
a_locked = threading.Event()  # AがROW1をロックしたらセット
b_locked = threading.Event()  # BがROW2をロックしたらセット

def session_a():
    conn = psycopg2.connect(DB)
    conn.autocommit = False
    cur = conn.cursor()
    try:
        # id=1 をロック
        cur.execute("UPDATE tasks SET status='in_progress' WHERE id=1")
        a_locked.set()    # Bに「id=1をロックした」と通知
        b_locked.wait()   # Bがid=2をロックするまで待つ

        # id=2 のロックを要求 → Bが持っているのでデッドロック
        cur.execute("UPDATE tasks SET status='in_progress' WHERE id=2")
        conn.commit()
    except psycopg2.errors.DeadlockDetected:
        print("[セッションA] ERROR: deadlock detected → 自動ROLLBACK")
        conn.rollback()
    finally:
        cur.close()
        conn.close()

def session_b():
    conn = psycopg2.connect(DB)
    conn.autocommit = False
    cur = conn.cursor()
    try:
        a_locked.wait()   # Aがid=1をロックするまで待つ

        # id=2 をロック
        cur.execute("UPDATE tasks SET status='done' WHERE id=2")
        b_locked.set()    # Aに「id=2をロックした」と通知

        # id=1 のロックを要求 → Aが持っているのでデッドロック
        cur.execute("UPDATE tasks SET status='done' WHERE id=1")
        conn.commit()
    except psycopg2.errors.DeadlockDetected:
        print("[セッションB] ERROR: deadlock detected → 自動ROLLBACK")
        conn.rollback()
    finally:
        cur.close()
        conn.close()

# 2スレッドを同時に起動
t_a = threading.Thread(target=session_a)
t_b = threading.Thread(target=session_b)
t_a.start()
t_b.start()
t_a.join()
t_b.join()
```

---

## 実行結果

```
[セッションA] BEGIN → id=1 をUPDATE（ロック取得）
[セッションA] id=1 ロック完了 → セッションBを待機中...
[セッションB] BEGIN → id=2 をUPDATE（ロック取得）
[セッションB] id=2 ロック完了 → セッションAに通知
[セッションA] id=2 のUPDATEを要求（Bと競合 → デッドロック待ち）
[セッションB] id=1 のUPDATEを要求（Aと競合 → デッドロック待ち）
[セッションA] ERROR: deadlock detected → 自動ROLLBACK   ← Aが犠牲者に
[セッションB] COMMIT完了
```

`deadlock detected` が確認できました。

:::message
**どちらが犠牲者になるか** はPostgreSQLが内部で決定し、アプリ側では制御できません。今回はAが選ばれましたが、毎回同じとは限りません。
:::

---

## 回避策：ロック取得順を統一する

**原因は「ロック取得の順番が逆だったこと」** です。

```
デッドロックが起きたケース
  セッションA: id=1 → id=2 の順
  セッションB: id=2 → id=1 の順  ← 逆順が原因
```

同じ順番でロックを取得すれば発生しません。

```python
# 両方とも id=1 → id=2 の昇順でUPDATE
def session_a():
    cur.execute("UPDATE tasks SET status='in_progress' WHERE id=1")
    cur.execute("UPDATE tasks SET status='in_progress' WHERE id=2")
    conn.commit()

def session_b():
    cur.execute("UPDATE tasks SET status='done' WHERE id=1")
    cur.execute("UPDATE tasks SET status='done' WHERE id=2")
    conn.commit()
```

**実行結果：**

```
[セッションA] COMMIT完了
[セッションB] COMMIT完了（デッドロックなし）
```

両方が正常に完了しました。

---

## デッドロック回避策まとめ

| 方法 | 内容 |
|---|---|
| ロック順を統一する | 複数行を更新する場合は必ずid昇順でUPDATEする |
| トランザクションを短くする | ロック保持時間を最小限にする |
| SELECT FOR UPDATEを使う | 更新前に明示的ロックを取得して順番を制御する |

:::message alert
アプリ側は `deadlock detected` エラーを受け取ったら、**トランザクション全体をリトライする実装**が必要です。指数バックオフを使うと安全です。
:::

---

## DDD × デッドロックの関係

Repository パターンで複数の集約をまたいで更新する場合、取得・更新の順番が一定でないとデッドロックのリスクがあります。

**ユースケース層でどの順番でRepositoryを呼ぶかを統一しておくことが設計上重要です。**

```
// 良い例：常にUserRepository → TaskRepositoryの順で呼ぶ
userRepository.update(user)
taskRepository.update(task)

// 悪い例：呼ぶ順番がユースケースによってバラバラ
// → デッドロックのリスクが生まれる
```

---

## まとめ

- デッドロックは**ロック取得順が逆になる**と発生する
- PostgreSQLは約1秒で自動検知し**片方を強制ROLLBACK**する
- シェルスクリプトでの同時実行は難しく、**Pythonのthreadingが有効**
- 回避策の本質は**ロック取得順を全セッションで統一すること**
- DDD × Repositoryパターンでは**ユースケース層でロック順を統一する**

---

*この記事で使用したコードはすべて以下のリポジトリで公開しています。*
https://github.com/tsuzudev05/rdb-learning-postgres