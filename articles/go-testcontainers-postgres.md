---
title: "testcontainers-go で PostgreSQL 統合テストを書く――DevContainer でハマったDB汚染問題と解決策"
emoji: "🐳"
type: "tech"
topics: ["go", "testcontainers", "postgresql", "testing", "ddd"]
published: false
---

## はじめに

Go でリポジトリ層のテストを書くとき、こんな選択肢があります。

- **モックリポジトリ**：interface を手動実装して DB なしでテスト
- **テスト用 DB に直接接続**：ローカルや CI の DB を使う
- **testcontainers-go**：テスト時に Docker コンテナを自動起動して本物の DB で確かめる

この記事では3つ目の **testcontainers-go** を選んだ理由と、
実際に実装したテストヘルパーのコードを紹介します。

題材は OKR 管理ツール（Go × DDD × PostgreSQL）のリポジトリ層テストです。

---

## なぜ testcontainers-go を選んだのか

### モックの限界

DDD でリポジトリ層を interface として定義すると、こんなモックが書けます。

```go
type mockUserRepo struct {
    users map[string]user.User
}

func (m *mockUserRepo) FindByID(ctx context.Context, id user.UserId) (*user.User, error) {
    u, ok := m.users[id.Value()]
    if !ok {
        return nil, nil
    }
    return &u, nil
}
```

UseCase 層の単体テストには十分ですが、リポジトリ層そのもののテストには使えません。

「SQL が正しいか」「ON CONFLICT の upsert が想定どおり動くか」「CASCADE DELETE で関連行が消えるか」——これらはモックでは確認できない、DB との実際のやりとりです。

### ローカル DB に直接接続するアプローチの問題

```bash
export DATABASE_URL=postgres://localhost/okr_test
go test ./...
```

シンプルですが問題があります。

- テスト実行者全員がローカルに PostgreSQL を用意する必要がある
- CI 環境で DB サービスの起動設定が必要
- テスト間でデータが残ると干渉する（テスト順序依存のバグを生む）

### testcontainers-go が解決すること

testcontainers-go は `go test` の中で Docker コンテナを起動・停止します。

- **環境依存ゼロ**：Docker さえあれば誰の環境でも同じ DB で動く
- **完全な分離**：テストごとに TRUNCATE でリセット、テスト終了後はコンテナごと破棄
- **本物の DB**：SQL・制約・トリガーが実際に動く

---

## 実装したテストヘルパー

### ディレクトリ構成

```
05_DDD統合/go/
├── internal/
│   └── testhelper/
│       └── postgres.go   ← 今回実装
├── infrastructure/
│   └── repository/
│       ├── pg_user_repository.go
│       └── pg_user_repository_test.go  ← 次フェーズで実装予定
└── schema.sql
```

### postgres.go 全体

```go
package testhelper

import (
    "context"
    "fmt"
    "os"
    "path/filepath"
    "runtime"
    "testing"
    "time"

    "github.com/jackc/pgx/v5/pgxpool"
    "github.com/testcontainers/testcontainers-go"
    "github.com/testcontainers/testcontainers-go/modules/postgres"
    "github.com/testcontainers/testcontainers-go/wait"
)

// Pool はテストファイルから参照する共有コネクションプール
var Pool *pgxpool.Pool
```

### コンテナ起動：SetupPostgres

```go
func SetupPostgres(ctx context.Context) (pool *pgxpool.Pool, teardown func()) {
    schemaSQL, err := os.ReadFile(schemaPath())
    if err != nil {
        panic(fmt.Sprintf("testhelper: failed to read schema.sql: %v", err))
    }

    pgc, err := postgres.RunContainer(ctx,
        testcontainers.WithImage("postgres:16-alpine"),
        postgres.WithDatabase("okr_test"),
        postgres.WithUsername("postgres"),
        postgres.WithPassword("postgres"),
        testcontainers.WithWaitStrategy(
            wait.ForLog("database system is ready to accept connections").
                WithOccurrence(2).
                WithStartupTimeout(60*time.Second),
        ),
    )
    // ...
    connStr, _ := pgc.ConnectionString(ctx, "sslmode=disable")
    pool, _ = pgxpool.New(ctx, connStr)

    // schema.sql を適用
    pool.Exec(ctx, string(schemaSQL))

    teardown = func() {
        pool.Close()
        pgc.Terminate(ctx)
    }
    return pool, teardown
}
```

ポイントは `WithWaitStrategy` です。PostgreSQL は起動時に
`"database system is ready to accept connections"` を **2回** 出力します
（1回目：初期化完了、2回目：サービス開始）。
`WithOccurrence(2)` で2回目を待つことで、接続可能になってから次の処理に進めます。

### schema.sql のパス解決

```go
func schemaPath() string {
    _, thisFile, _, _ := runtime.Caller(0)
    // thisFile = .../go/internal/testhelper/postgres.go
    // schema.sql = .../schema.sql（3階層上）
    return filepath.Join(filepath.Dir(thisFile), "..", "..", "..", "schema.sql")
}
```

`go test` はパッケージごとに作業ディレクトリが変わるため、相対パスは壊れます。
`runtime.Caller(0)` はコンパイル時のソースファイルパスを返すので、
実行場所に依存せず正しいパスを得られます。

### テスト間リセット：TruncateAll

```go
func TruncateAll(t *testing.T, pool *pgxpool.Pool) {
    t.Helper()
    const q = `
        TRUNCATE
            kr_progress_logs,
            key_results,
            objectives,
            periods,
            team_members,
            teams,
            users
        RESTART IDENTITY CASCADE`
    if _, err := pool.Exec(context.Background(), q); err != nil {
        t.Fatalf("testhelper.TruncateAll: %v", err)
    }
}
```

テーブルを外部キー制約の子→親の順に TRUNCATE します。
`CASCADE` を付けているので順序は厳密でなくても動きますが、
依存関係を明示することでスキーマの変更に気づきやすくなります。

### テストでの使い方

```go
// infrastructure/repository/pg_user_repository_test.go

var testPool *pgxpool.Pool

func TestMain(m *testing.M) {
    ctx := context.Background()
    pool, teardown := testhelper.SetupPostgres(ctx)
    defer teardown()
    testPool = pool
    os.Exit(m.Run())
}

func TestPgUserRepository_Save(t *testing.T) {
    t.Cleanup(func() { testhelper.TruncateAll(t, testPool) })

    repo := repository.NewPgUserRepository(testPool)
    ctx := context.Background()

    id, _ := user.NewUserId("550e8400-e29b-41d4-a716-446655440000")
    email, _ := user.NewEmail("alice@example.com")
    u, _ := user.NewUser(id, "Alice", email, "hash", time.Now(), time.Now())

    if err := repo.Save(ctx, u); err != nil {
        t.Fatalf("Save: %v", err)
    }

    got, err := repo.FindByID(ctx, id)
    if err != nil || got == nil {
        t.Fatalf("FindByID: got=%v err=%v", got, err)
    }
    if got.Email().Value() != "alice@example.com" {
        t.Errorf("email mismatch: %s", got.Email().Value())
    }
}
```

`TestMain` でコンテナを1回だけ起動し、各テストは `t.Cleanup` で TRUNCATE します。
コンテナの起動コストをテストスイート全体で1回に抑えつつ、テスト間の独立性を保てます。

---

## モック vs testcontainers の使い分け

| テスト対象 | 推奨アプローチ | 理由 |
|---|---|---|
| UseCase のビジネスロジック | モック | DB なしで高速に実行。ロジックに集中できる |
| Repository の SQL | testcontainers | 実際の SQL・制約・トリガーを確認する必要がある |
| Handler の E2E | testcontainers or httptest | 全体の疎通確認 |

UseCase 層のテスト（重複メールエラー・進捗型ミスマッチなど）はモックで十分です。
Repository 層の `ON CONFLICT DO UPDATE` や CASCADE DELETE は testcontainers で確かめます。

---

## セットアップ手順

```bash
cd 05_DDD統合/go
go get github.com/testcontainers/testcontainers-go@latest
go get github.com/testcontainers/testcontainers-go/modules/postgres@latest
go mod tidy
go test ./infrastructure/repository/...
```

---

## 詰まりポイント：DevContainer 内で Docker が使えない

実際に DevContainer 内で `go test` を実行したところ、次のエラーが出ました。

```
panic: testhelper: failed to start postgres container:
  run postgres: generic container: get provider:
  rootless Docker not found, failed to create Docker provider
```

### 原因

testcontainers-go はテスト内で Docker コンテナを起動しますが、DevContainer 自体が Docker コンテナとして動いているため、**Docker-in-Docker** の状態になります。Docker ソケット（`/var/run/docker.sock`）を DevContainer にマウントしていなければ、内側から Docker デーモンに接続できません。

```yaml
# docker-compose.yml に以下がないと Docker が使えない
volumes:
  - /var/run/docker.sock:/var/run/docker.sock  # ← これが必要
```

### 解決策：環境に応じて接続先を切り替えるハイブリッド方式

Docker ソケットをマウントする方法もありますが、セキュリティ上の懸念（ホストの Docker デーモンへのフルアクセスを与える）があります。

代わりに **`DATABASE_URL` の有無で動作を切り替える**設計にしました。

```go
func SetupPostgres(ctx context.Context) (pool *pgxpool.Pool, teardown func()) {
    if connStr := os.Getenv("DATABASE_URL"); connStr != "" {
        // DevContainer: 既存の PostgreSQL に直接接続
        return setupWithExistingDB(ctx, connStr)
    }
    // CI / スタンドアロン: testcontainers でコンテナを起動
    return setupWithTestcontainers(ctx)
}
```

| 環境 | `DATABASE_URL` | 動作 |
|---|---|---|
| DevContainer | `postgresql://postgres:pass@postgres:5432/learning` | 既存 DB に直接接続 |
| GitHub Actions / ローカル | 未設定 | testcontainers でコンテナ自動起動 |

DevContainer 環境では docker-compose.yml で `DATABASE_URL` が既に設定されているため、追加の設定なしにそのまま動きます。

```yaml
# docker-compose.yml（抜粋）
environment:
  DATABASE_URL: postgresql://postgres:pass@postgres:5432/learning
```

この設計により、**テストコードを一切変えずに**両方の環境で動作します。

```
# DevContainer 内（DATABASE_URL あり）
go test ./infrastructure/repository/...
[testhelper] Using existing PostgreSQL (DATABASE_URL)
ok  github.com/tsuzudev05/rdb-learning-postgres/okr/infrastructure/repository  0.936s

# CI（DATABASE_URL なし）
go test ./infrastructure/repository/...
[testhelper] Starting PostgreSQL container via testcontainers-go
ok  github.com/tsuzudev05/rdb-learning-postgres/okr/infrastructure/repository  12.4s
```

---

## 続きの詰まり：既存DBへの接続でDB汚染と「already exists」エラー

ハイブリッド方式を実装して DevContainer で動かしたところ、今度は別の問題が出ました。

### 症状

```
panic: testhelper: failed to apply schema.sql:
  ERROR: relation "users" already exists (SQLSTATE 42P01)
```

### 原因

2つの問題が重なっていました。

**問題1：メインDBに直接 CREATE TABLE していた**  
`DATABASE_URL` はアプリ開発用の DB（`learning`）を指しており、そこにテストが `schema.sql` を流してテーブルを作っていました。開発データを汚染するうえ、テーブルが既存だと2回目以降の `CREATE TABLE` が失敗します。

**問題2：schema.sql が `IF NOT EXISTS` なし**  
`schema.sql` は素の `CREATE TABLE users (...)` 形式だったため、テーブルが存在するとエラーになります。

### 解決策：テスト専用DBを作って毎回クリーンリセット

`setupWithExistingDB` を以下の4ステップに修正しました。

```go
func setupWithExistingDB(ctx context.Context, connStr string) (pool *pgxpool.Pool, teardown func()) {
    // Step 1: okr_test DB を作成（既存なら無視）
    // CREATE DATABASE はトランザクション外で実行する必要があるため adminPool を別途作成
    adminPool, _ := pgxpool.New(ctx, connStr)
    _, err := adminPool.Exec(ctx, `CREATE DATABASE okr_test`)
    if err != nil && !isPgErrorCode(err, "42P04") { // 42P04 = duplicate_database
        panic(...)
    }
    adminPool.Close()

    // Step 2: okr_test に切り替えて接続（メインDBは無傷）
    cfg, _ := pgxpool.ParseConfig(connStr)
    cfg.ConnConfig.Database = "okr_test"
    pool, _ = pgxpool.NewWithConfig(ctx, cfg)

    // Step 3: スキーマをまるごとリセット（IF NOT EXISTS なしのDDLでも安全）
    pool.Exec(ctx, `DROP SCHEMA public CASCADE; CREATE SCHEMA public;`)

    // Step 4: schema.sql を適用
    schemaSQL, _ := os.ReadFile(schemaPath())
    pool.Exec(ctx, string(schemaSQL))

    return pool, func() { pool.Close() }
}
```

エラーコード判定のヘルパー：

```go
func isPgErrorCode(err error, code string) bool {
    var pge interface{ SQLState() string }
    if errors.As(err, &pge) {
        return pge.SQLState() == code
    }
    return false
}
```

### ポイント解説

**①CREATE DATABASE は adminPool で単独実行する**  
`CREATE DATABASE` はトランザクション内で実行できません。接続先DBの切り替えも pgxpool では接続後にはできないため、元の `connStr` で adminPool を作り、`okr_test` 作成だけを担当させます。

**②`42P04` のみ無視して冪等化する**  
PostgreSQL の SQLSTATE `42P04`（`duplicate_database`）だけを握りつぶし、それ以外のエラーは正常に panic させます。

**③`DROP SCHEMA public CASCADE` で毎回クリーンリセット**  
TruncateAll はデータを消すだけですが、これはスキーマごと再作成します。`IF NOT EXISTS` なしのDDLでも何度でも安全に適用できます。

### 修正後の動作確認

```
[testhelper] Using existing PostgreSQL (DATABASE_URL)
--- PASS: TestPgUserRepository_Save_and_FindByID (0.01s)
--- PASS: TestPgUserRepository_Save_Upsert (0.00s)
--- PASS: TestPgUserRepository_FindByEmail (0.00s)
--- PASS: TestPgUserRepository_FindAll (0.01s)
--- PASS: TestPgUserRepository_Remove (0.00s)
--- PASS: TestPgTeamRepository_Save_WithMembers (0.01s)
--- PASS: TestPgTeamRepository_Save_FullReplace_Members (0.01s)
--- PASS: TestPgTeamRepository_Remove_CascadesMembers (0.00s)
ok  github.com/tsuzudev05/rdb-learning-postgres/okr/infrastructure/repository
```

---

## さらなる詰まり：KeyResult の `current_value` がテストで nil になる

DB汚染問題を解決して全テストを流したところ、今度は KeyResult 関連のテストが失敗しました。

### 症状

```
--- FAIL: TestPgKeyResultRepository_Save_WithProgressLog
    pg_key_result_repository_test.go:XX:
        CurrentValue = <nil>, want 75.0
```

ProgressLog を追加して Save した後、`FindByID` で取得した KeyResult の `CurrentValue()` が `nil` になっていました。

### 原因の特定

`pg_key_result_repository.go` の `scanKeyResult` を読むと、こんなコードがありました。

```go
func scanKeyResult(row pgx.Row) (keyresult.KeyResult, error) {
    var (
        // ...
        currentValue *float64
        // ...
    )
    err := row.Scan(
        // ..., &currentValue, ...
    )
    _ = currentValue  // ← 読んで捨てていた！
    // ...
}
```

DB から `current_value` を読み込んでいるのに `_ = currentValue` で捨てており、KeyResult の組み立て時に使われていませんでした。

`WithProgressLogs`（`key_result.go`）も問題でした。

```go
// 修正前
func (k KeyResult) WithProgressLogs(logs []KrProgressLog) KeyResult {
    k.progressLogs = logs  // ログをセットするだけ
    return k
}
```

`FindByID` の実装では `scanKeyResult` でキーリザルト本体を読んだ後、`WithProgressLogs` でログを付け直す設計になっています。しかし `currentValue` が復元されていないため、ProgressLog があっても `CurrentValue()` は常に `nil` でした。

### 修正

**`WithProgressLogs` で最新ログから `currentValue` / `isCompleted` を再導出する**方針で修正しました。ProgressLog は `recorded_at ASC` 順で取得されるため、スライスの末尾が最新値になります。

```go
// 修正後
func (k KeyResult) WithProgressLogs(logs []KrProgressLog) KeyResult {
    k.progressLogs = logs
    if len(logs) == 0 {
        return k
    }
    latest := logs[len(logs)-1]
    if k.krType == KrTypeNumeric && latest.NumericValue() != nil {
        k.currentValue = latest.NumericValue()
    }
    if k.krType == KrTypeCheckbox && latest.Completed() != nil {
        k.isCompleted = *latest.Completed()
    }
    return k
}
```

合わせて `scanKeyResult` の死んだコード（`_ = currentValue`）を削除しました。

### この問題が起きやすい背景

DDD の集約を DB から復元するとき、「どこで状態を組み立てるか」が分散しがちです。

今回のケースは以下の2箇所が責務を中途半端に持っていました。

| 場所 | 本来の責務 | 実際の状態 |
|---|---|---|
| `scanKeyResult` | KeyResult 本体（`current_value` 含む）を復元 | `current_value` を読んで捨てていた |
| `WithProgressLogs` | ProgressLog をアタッチ | ログをセットするだけで状態を更新しなかった |

**統合テストがなければ気づけなかったバグ**です。モックでは Repository の実装ロジックを通らないため、このような「DB→ドメインオブジェクトへの変換ミス」は単体テストでは発見できません。

### 修正後の出力

```
--- PASS: TestPgKeyResultRepository_Save_and_FindByID_Numeric (0.01s)
--- PASS: TestPgKeyResultRepository_Save_and_FindByID_Checkbox (0.01s)
--- PASS: TestPgKeyResultRepository_Save_WithProgressLog (0.01s)
--- PASS: TestPgKeyResultRepository_FindByObjectiveID (0.01s)
--- PASS: TestPgKeyResultRepository_Remove (0.01s)
ok  github.com/tsuzudev05/rdb-learning-postgres/okr/infrastructure/repository
```

---

## まとめ

- testcontainers-go を使うと `go test` だけで本物の PostgreSQL コンテナが起動する
- `WithWaitStrategy` + `WithOccurrence(2)` で確実に起動を待ち、`TruncateAll` でテスト間の独立性を担保する
- DevContainer 内は Docker-in-Docker の制約があるため `DATABASE_URL` の有無で接続先を切り替えるハイブリッド方式が現実的
- 既存DBに直接接続する場合は **専用テストDBを作成 → `DROP SCHEMA public CASCADE` でクリーンリセット** が安全
- `CREATE DATABASE` の重複エラーは SQLSTATE `42P04` で識別して無視することで冪等化できる
- DB→ドメインオブジェクトへの変換ミスはモックでは発見できない。**統合テストが「実装が本当に正しいか」を保証する最後の砦**

---

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
