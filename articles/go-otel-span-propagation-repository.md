---
title: "Go × OpenTelemetry でスパン伝播と Repository トレーシングを実装する"
emoji: "🔗"
type: "tech"
topics: ["go", "opentelemetry", "jaeger", "ddd", "observability"]
published: false
---

# Go × OpenTelemetry でスパン伝播と Repository トレーシングを実装する

前回（[Go × OpenTelemetry + Jaeger を DevContainer に組み込む](./go-opentelemetry-jaeger-devcontainer)）で OTel の基盤を構築した。今回はその続きとして、W3C TraceContext ヘッダーの伝播設定と、DDD の Repository 層へのスパン追加を実装した記録をまとめる。

---

## やったこと

1. **W3C TraceContext プロパゲーター設定**：上流サービスのトレースコンテキストを HTTP ヘッダーから引き継ぐ
2. **Repository 各メソッドへのスパン追加**：HTTP スパン → DB スパンの親子関係を Jaeger で可視化

---

## 1. W3C TraceContext プロパゲーターの設定

### 設定前の問題

`otelecho` ミドルウェアを入れるだけでは、外部サービスから `traceparent` ヘッダーが送られてきても**無視される**。スパンが親子関係にならず、バラバラのトレースとして記録されてしまう。

### 解決策：`SetTextMapPropagator` を呼ぶ

`internal/telemetry/tracer.go` の `InitTracer` 末尾に追加する。

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/propagation"
    // ...
)

func InitTracer(ctx context.Context, serviceName string) (*sdktrace.TracerProvider, error) {
    // ... TracerProvider の初期化 ...

    otel.SetTracerProvider(tp)

    // W3C TraceContext + Baggage ヘッダーの伝播を有効化
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{},
        propagation.Baggage{},
    ))

    return tp, nil
}
```

`propagation.TraceContext{}` が W3C 標準の `traceparent` / `tracestate` ヘッダーを処理する。`propagation.Baggage{}` はオプションだが、将来的にユーザーID等のメタデータを伝播させるときに使える。

### `propagation` パッケージについて

`go.opentelemetry.io/otel/propagation` は `go.opentelemetry.io/otel` に内包されており、**追加の `go get` は不要**。

---

## 2. Repository 各メソッドへのスパン追加

### なぜ Repository にスパンを追加するか

`otelecho` は HTTP ハンドラー全体のスパンを生成するが、その内部でどの DB クエリが何 ms かかっているかは見えない。Repository メソッドにスパンを追加することで：

```
GET /api/v1/users  (5ms)
  └── PgUserRepository.FindAll  (3ms)   ← どのクエリが遅いか分かる
```

という粒度のトレースが取れるようになる。

### 実装パターン

各 Repository ファイルの冒頭でトレーサー名を定数として定義し、各メソッドの先頭でスパンを開始する。

```go
const userTracerName = "okr/infrastructure/repository/user"

func (r *PgUserRepository) FindByID(ctx context.Context, id user.UserId) (*user.User, error) {
    ctx, span := otel.Tracer(userTracerName).Start(ctx, "PgUserRepository.FindByID")
    defer span.End()
    span.SetAttributes(attribute.String("db.user.id", id.Value()))

    // ... SQL クエリ ...
}
```

**3つのポイント：**

1. **`ctx` を上書きする**：`ctx, span := tracer.Start(ctx, ...)` として新しいコンテキストを使い回すことで、後続のネストした処理（例: `loadMembers`）が正しい親スパンを参照できる

2. **`defer span.End()`**：メソッドを抜けるタイミングで必ずスパンを終了する。忘れると Jaeger にエクスポートされない

3. **`span.SetAttributes`**：スパンに属性を付けることで Jaeger UI で検索・フィルタリングが可能になる

### 5リポジトリへの適用

同じパターンを User / Team / Period / Objective / KeyResult の全リポジトリに適用した。

```go
// 各リポジトリのトレーサー名
const userTracerName      = "okr/infrastructure/repository/user"
const teamTracerName      = "okr/infrastructure/repository/team"
const periodTracerName    = "okr/infrastructure/repository/period"
const objectiveTracerName = "okr/infrastructure/repository/objective"
const keyResultTracerName = "okr/infrastructure/repository/keyresult"
```

---

## 3. Jaeger UI で確認する

### トレースを生成

```bash
# API にリクエストを送る
curl -X POST http://localhost:8080/api/v1/users \
  -H "Content-Type: application/json" \
  -d '{"name":"test","email":"test@example.com","password_hash":"hash"}'

curl http://localhost:8080/api/v1/users
```

### Jaeger UI の見方

1. `http://localhost:16686` を開く
2. Service: `okr-api` を選択 → "Find Traces"
3. トレースをクリックすると親子関係が表示される

```
okr-api: POST /api/v1/users          (HTTP スパン)
  └── PgUserRepository.Save          (Repository スパン)
       └── db.user.id: <uuid>        (スパン属性)
```

### W3C TraceContext ヘッダーの伝播テスト

外部からのトレースコンテキストを引き継ぐかテストする：

```bash
curl http://localhost:8080/api/v1/users \
  -H "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
```

Jaeger UI でトレースIDが `4bf92f3577b34da6a3ce929d0e0e4736` になっていれば成功。

---

## まとめ

| やること | コード量 | 効果 |
|---|---|---|
| `SetTextMapPropagator` 設定 | 5行 | 上流サービスとのトレース連携が可能に |
| Repository スパン追加 | メソッドごとに3〜4行 | DB クエリ単位でレイテンシを可視化 |

Repository への追加はボイラープレートが多いが、パターンが統一されているため機械的に適用できる。将来的には `otelpgx`（pgx 用の自動計装ライブラリ）を使えばさらに詳細な SQL クエリ情報（SQL 文字体・テーブル名）も取れる。

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
