---
title: "Go × OpenTelemetry + Jaeger を DevContainer に組み込む――詰まったポイントと最終構成"
emoji: "🔭"
type: "tech"
topics: ["go", "opentelemetry", "jaeger", "devcontainer", "observability"]
published: false
---

# Go × OpenTelemetry + Jaeger を DevContainer に組み込む

OKR管理ツール（Go + echo v4）に OpenTelemetry によるトレーシングを追加した記録。DevContainer 上で Jaeger UI（`http://localhost:16686`）が開けるまでの手順と詰まったポイントをまとめる。

---

## 最終的な構成

```
DevContainer（app コンテナ）
  ↓ OTLP gRPC（port 4317）
Jaeger（all-in-one コンテナ）
  ↓
Jaeger UI http://localhost:16686
```

使用パッケージ:

| パッケージ | 役割 |
|---|---|
| `go.opentelemetry.io/otel/sdk` | TracerProvider |
| `go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc` | OTLP gRPC exporter |
| `go.opentelemetry.io/contrib/instrumentation/github.com/labstack/echo/otelecho` | echo ミドルウェア（自動スパン生成） |
| `google.golang.org/grpc` | gRPC クライアント |

---

## docker-compose.yml に Jaeger を追加する

```yaml
services:
  app:
    depends_on:
      postgres:
        condition: service_healthy
      jaeger:
        condition: service_started   # ← 追加
    environment:
      DATABASE_URL: postgresql://postgres:pass@postgres:5432/learning
      OTEL_EXPORTER_OTLP_ENDPOINT: jaeger:4317   # ← 追加

  jaeger:
    image: jaegertracing/all-in-one:1.57
    container_name: jaeger
    environment:
      COLLECTOR_OTLP_ENABLED: "true"
    ports:
      - "16686:16686"   # Jaeger UI
      - "4317:4317"     # OTLP gRPC
      - "4318:4318"     # OTLP HTTP
    networks:
      - dev-network
```

**ポイント:** Jaeger v1.35 以降は `COLLECTOR_OTLP_ENABLED: "true"` を設定することで OTLP 受信が有効になる。旧来の `jaeger.thrift` ではなく OTLP を使うのが現在の推奨。

---

## TracerProvider の初期化（internal/telemetry/tracer.go）

```go
package telemetry

import (
    "context"
    "os"
    "time"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/insecure"
)

func InitTracer(ctx context.Context, serviceName string) (*sdktrace.TracerProvider, error) {
    endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    if endpoint == "" {
        endpoint = "jaeger:4317"
    }

    conn, err := grpc.NewClient(endpoint,
        grpc.WithTransportCredentials(insecure.NewCredentials()),
    )
    // ... exporter・resource・TracerProvider の作成
    otel.SetTracerProvider(tp)
    return tp, nil
}
```

`grpc.Dial` は deprecated になっているため `grpc.NewClient` を使う（これが最初に詰まったポイント）。

---

## main.go への組み込み

```go
// 1. TracerProvider を初期化
tp, err := telemetry.InitTracer(ctx, "okr-api")
if err != nil {
    log.Printf("⚠️ OpenTelemetry 初期化失敗（トレースなしで続行）: %v", err)
} else {
    defer tp.Shutdown(ctx)
}

// 2. echo ミドルウェアでリクエストごとにスパンを自動生成
e.Use(otelecho.Middleware("okr-api"))
```

**設計判断:** `InitTracer` が失敗しても API サーバーは起動し続ける。Observability は「ないと動かない」インフラではなく「あると便利」なオプションとして扱う。開発時に Jaeger を起動していない場合でも API が壊れないようにするため。

---

## 詰まったポイント

### 1. `grpc.Dial` が deprecated

`otlptracegrpc.WithEndpoint` + `grpc.Dial` の組み合わせは deprecated。`grpc.NewClient` で接続を作り `otlptracegrpc.WithGRPCConn(conn)` に渡すのが現在のイディオム。

### 2. Zed + DevContainer の Rebuild 方法

Zed は VSCode と異なり「Rebuild Container」ボタンがない。docker-compose.yml を変更した後は Docker CLI で操作する:

```bash
# Jaeger だけ追加起動（既存コンテナを壊さない）
docker compose up -d jaeger

# app コンテナに環境変数を反映させる場合
docker compose up -d --force-recreate app
```

### 3. Jaeger UI が開けない

`16686:16686` のポートフォワードが devcontainer.json に設定されていないと、ホスト（Windows）側から `localhost:16686` にアクセスできない。

```json
// devcontainer.json
{
  "forwardPorts": [8080, 16686]
}
```

---

## 動作確認

```bash
# DevContainer 内で API 起動
go run ./cmd/api

# ログに以下が出れば成功
# ✅ OpenTelemetry TracerProvider 初期化成功
# ✅ DB 接続成功
# 🚀 OKR API サーバーを起動します: http://localhost:8080

# リクエストを送る
curl http://localhost:8080/api/v1/
curl http://localhost:8080/api/v1/users

# Jaeger UI で確認
# http://localhost:16686 → Service: okr-api → Find Traces
```

---

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
