---
title: "Go + pgx v5 で DDD の Repository パターンを実装する：C++ 実装との比較"
emoji: "🐹"
type: "tech"
topics: ["go", "postgresql", "ddd", "pgx", "クリーンアーキテクチャ"]
published: false
---

## はじめに

OKR 管理ツールのドメイン層を C++ で実装した後、同じ設計を Go + pgx v5 に移植しました。

「C++ では `Result<T>` と `std::optional<T>` でエラーと null を表現していたが、Go ではどう書くのか」という疑問から始まり、2 言語の対応関係が見えてきました。本記事では **DDD の Repository パターンを Go で実装する際の設計ポイント** を、C++ との比較を交えながら解説します。

---

## 対象読者

- Go で DDD（ドメイン駆動設計）を実践したい方
- C++ / Java など他言語の DDD 経験を Go に活かしたい方
- pgx v5 の使い方を学びたい方

---

## ディレクトリ構成

クリーンアーキテクチャの原則に従い、ドメイン層とインフラ層を分離します。

```
go/
├── go.mod
├── cmd/smoke/main.go               # スモークテスト
├── domain/
│   ├── model/user/
│   │   ├── user_id.go              # 値オブジェクト: UserId
│   │   ├── email.go                # 値オブジェクト: Email
│   │   └── user.go                 # エンティティ: User
│   └── repository/
│       └── user_repository.go      # インターフェース（依存なし）
└── infrastructure/repository/
    └── pg_user_repository.go       # pgx 実装
```

**原則**：`domain/` は外部ライブラリに依存しない（標準ライブラリのみ）。

---

## 値オブジェクトの実装

### C++ との対応：Result\<T\> → (T, error)

C++ では `std::expected` 風の自前 `Result<T>` を使いました。

```cpp
// C++
static Result<UserId> create(const std::string& value) {
    if (!isValidUuid(value))
        return Result<UserId>::err("無効なUUID: " + value);
    return Result<UserId>::ok(UserId{value});
}
```

Go では多値返却でシンプルに表現できます。

```go
// Go
func NewUserId(value string) (UserId, error) {
    if !uuidV4Regex.MatchString(value) {
        return UserId{}, fmt.Errorf("UserId: 無効なUUID形式です: %s", value)
    }
    return UserId{value: value}, nil
}
```

どちらも「コンストラクタをprivate / unexported にしてファクトリ経由でバリデーション」する設計は共通です。

---

## Repository インターフェース

インターフェースは **ドメイン層に定義**します。インフラ層（pgx）への依存はここには持ち込みません。

```go
// domain/repository/user_repository.go
package repository

import (
    "context"
    "github.com/tsuzudev05/rdb-learning-postgres/okr/domain/model/user"
)

type UserRepository interface {
    FindByID(ctx context.Context, id user.UserId) (*user.User, error)
    FindByEmail(ctx context.Context, email user.Email) (*user.User, error)
    FindAll(ctx context.Context) ([]user.User, error)
    Save(ctx context.Context, u user.User) error
    Remove(ctx context.Context, id user.UserId) error
}
```

### std::optional\<T\> → *T（nil ポインタ）

「見つからない場合」の表現が C++ と Go で異なります。

```cpp
// C++: std::optional<User>
Result<std::optional<User>> findById(const UserId& id) const override;
// 見つからない → Result::ok(std::nullopt)
// 見つかった  → Result::ok(std::optional<User>{user})
```

```go
// Go: *User（nil ポインタ）
FindByID(ctx context.Context, id user.UserId) (*user.User, error)
// 見つからない → return nil, nil
// 見つかった  → return &user, nil
// エラー      → return nil, err
```

---

## pgx 実装

### コネクションプール

pgx v5 では `pgxpool.Pool` でコネクションプールを管理します。goroutine セーフなので Web サーバーから並行呼び出しが可能です。

```go
pool, err := pgxpool.New(ctx, "postgresql://postgres:pass@postgres:5432/learning")
```

### Save（upsert）

SQL は C++ 実装とまったく同じです。言語が変わっても SQL 資産は再利用できます。

```go
func (r *PgUserRepository) Save(ctx context.Context, u user.User) error {
    const q = `
        INSERT INTO users (id, name, email, password_hash)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (id) DO UPDATE SET
            name          = EXCLUDED.name,
            email         = EXCLUDED.email,
            password_hash = EXCLUDED.password_hash`

    _, err := r.pool.Exec(ctx, q,
        u.ID().Value(),
        u.Name(),
        u.Email().Value(),
        u.PasswordHash(),
    )
    return err
}
```

### DB 行 → エンティティ変換の集約

`pgx.Row` と `pgx.Rows` 両方に対応できるよう `scanner` インターフェースで抽象化し、再構築ロジックを 1 箇所にまとめます。

```go
type scanner interface {
    Scan(dest ...any) error
}

func scanUser(s scanner) (*user.User, error) {
    var rawID, name, rawEmail, hash string
    var created, updated time.Time

    if err := s.Scan(&rawID, &name, &rawEmail, &hash, &created, &updated); err != nil {
        return nil, err
    }
    id, _ := user.NewUserId(rawID)
    email, _ := user.NewEmail(rawEmail)
    u, _ := user.NewUser(id, name, email, hash, created, updated)
    return &u, nil
}
```

---

## インターフェース実装チェック

Go のイディオムとして、コンパイル時に実装漏れを検出できます。

```go
// コンパイル時チェック：PgUserRepository は UserRepository を満たすか？
var _ domainrepo.UserRepository = (*PgUserRepository)(nil)
```

メソッドが未実装だとコンパイルエラーになるため、実装漏れを早期に発見できます。

---

## C++ と Go の対応表まとめ

| 概念 / 機能              | C++                          | Go                              |
|--------------------------|------------------------------|---------------------------------|
| エラーハンドリング       | `Result<T>`                  | `(T, error)` 多値返却           |
| 値なし                   | `std::optional<T>`           | `*T`（nil ポインタ）            |
| コネクション管理         | `pqxx::connection`           | `pgxpool.Pool`                  |
| パラメータ付きクエリ     | `tx.exec_params(...)`        | `pool.Exec(ctx, q, args...)`    |
| 型安全 Union             | `std::variant<A, B>`         | interface / sum type（別記事）  |
| インターフェース実装確認 | 仮想関数の override          | コンパイル時チェックイディオム  |

---

## まとめ

Go + pgx v5 で DDD の Repository パターンを実装してみると、以下のことが分かりました。

- **設計方針は言語をまたいで共通**：ドメイン層をインフラ層から隔離し、インターフェースをドメイン側に置く原則は C++ も Go も同じ
- **Go 側の表現はシンプル**：`Result<T>` の自前実装が不要で多値返却で事足りる
- **SQL は再利用できる**：upsert の `ON CONFLICT` など、DB 層のロジックは言語間で共通

次のステップは **アプリケーション層（ユースケース）**の実装です。

---

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
