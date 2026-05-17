---
title: "C++17 x DDD でエンティティを実装する――値オブジェクトからエンティティへ"
emoji: "🏛️"
type: "tech"
topics: ["cpp", "ddd", "クリーンアーキテクチャ", "oop"]
published: false
---

## はじめに

OKR管理ツールを C++17 × DDD（ドメイン駆動設計）で実装しています。
フェーズ1では値オブジェクト（`UserId`, `Email`, `Role` など）を実装しました。
今回のフェーズ2では、値オブジェクトを組み合わせた **エンティティ**（`User`, `Team`, `Period`, `Objective`, `KeyResult`）を実装しました。

実装中に気づいたことや詰まったポイントをまとめます。

---

## 対象読者

- [前回の値オブジェクト記事](https://zenn.dev/tsuzudev05/articles/zenn-article-cpp-value-objects)を読んだ方
- C++17 × DDD でエンティティを実装したい方
- 集約ルート・内部エンティティの区別を実装レベルで理解したい方

---

## 実装したエンティティ一覧

| エンティティ        | 集約の種類          | 特徴                                      |
|---------------------|---------------------|-------------------------------------------|
| `User`              | 集約ルート          | 名前変更・パスワードハッシュ更新          |
| `Team`              | 集約ルート          | `TeamMember` を内包、admin 最低 1 人保証  |
| `TeamMember`        | Team 集約内エンティティ | ロール変更                              |
| `Period`            | 集約ルート          | 半期サイクル（Half + DateRange）          |
| `Objective`         | 集約ルート          | 表示順管理、オーナー変更                  |
| `KeyResult`         | 集約ルート          | 進捗更新 + KrProgressLog の時系列追記     |
| `KrProgressLog`     | KeyResult 集約内エンティティ | numeric / checkbox の2種別            |

---

## 詰まったポイント① Result<T> の default constructor 問題

### 問題

値オブジェクトのコンストラクタは `private` にしてファクトリパターンを使っています。
そのため `UserId` はデフォルトコンストラクタを持ちません。

フェーズ1で書いた `Result<T>` の実装は次のようなものでした。

```cpp
template <typename T>
class Result {
public:
    static Result ok(T value) {
        Result r;               // ← ここでデフォルトコンストラクタが必要！
        r.storage_ = std::move(value);
        return r;
    }
private:
    std::variant<T, DomainError> storage_;
};
```

`std::variant<UserId, DomainError>` のデフォルト構築は「第1型（`UserId`）がデフォルト構築可能」であることを要求します。
`UserId` のコンストラクタは `private` なので、コンパイルエラーになりました。

### 解決策

`std::in_place_type<T>` を使って直接構築に変更しました。

```cpp
static Result ok(T value) {
    return Result{std::variant<T, DomainError>{
        std::in_place_type<T>, std::move(value)}};
}

static Result err(std::string message) {
    return Result{std::variant<T, DomainError>{
        std::in_place_type<DomainError>, std::move(message)}};
}

private:
    explicit Result(std::variant<T, DomainError> storage)
        : storage_(std::move(storage)) {}
```

これにより `T` がデフォルト構築可能かどうかに依存しなくなります。

---

## 詰まったポイント② Result<void> の ok() 名前衝突

### 問題

`Result<void>` の特殊化で、「成功を生成する static `ok()`」と「成功を確認する instance `ok()`」を両方定義しようとしました。

```cpp
template <>
class Result<void> {
public:
    static Result ok() { ... }   // 成功を生成
    bool ok() const { ... }      // 成功を確認 ← コンパイルエラー！
};
```

C++ では **static メンバ関数と非 static メンバ関数を同名にできない**ため、コンパイルエラーになります。
（`Result<T>` では `static Result ok(T value)` と `bool ok() const` が引数の数で区別されていたため問題なかった）

### 解決策

instance `ok()` を削除し、`operator bool()` で成功確認を行うように変更しました。

```cpp
template <>
class Result<void> {
public:
    static Result ok() { ... }              // 成功生成
    explicit operator bool() const { return success_; }  // 成功確認
    // bool ok() const は持たない
};
```

呼び出し側は `if (!result)` の形で確認します。

---

## 詰まったポイント③ インクルードパスの相対パス誤り

### 問題

`src/domain/model/user/UserId.hpp` で `../../common/Result.hpp` と書いていましたが、
正しくは `../../../common/Result.hpp`（3段上）でした。

```
src/
├── common/
│   └── Result.hpp      ← ここにある
└── domain/
    └── model/
        └── user/
            └── UserId.hpp  ← ここから3段上がって common/ に到達
```

`../../` では `domain/common/` を指してしまいます。

### 解決策

全ての値オブジェクトのインクルードパスを `../../../common/` に修正しました。
コンパイル時は `-I src/` フラグを指定します。

```bash
g++ -std=c++17 -Wall -I"05_DDD統合/src" -o build/test tests/test_entities.cpp
```

---

## 型安全な UUID ID テンプレート

各エンティティの ID は全て UUID v4 形式ですが、`TeamId` を `UserId` として誤って渡せてしまうのは危険です。
`UuidId<Tag>` テンプレートを使うことで型レベルで区別しました。

```cpp
// common/UuidId.hpp
template <typename Tag>
class UuidId {
public:
    static Result<UuidId<Tag>> create(const std::string& value);
    const std::string& value() const;
    bool operator==(const UuidId<Tag>&) const;
    // ...
};

// 各 ID の定義
struct TeamTag {};
using TeamId = UuidId<TeamTag>;

struct PeriodTag {};
using PeriodId = UuidId<PeriodTag>;
```

これで `TeamId` と `PeriodId` を混在させるとコンパイルエラーになります。

---

## エンティティの設計で意識したこと

### 集約ルートと内部エンティティの区別

- `Team` が `TeamMember` を `std::vector<TeamMember>` として内包する
- `TeamMember` の追加・削除・ロール変更は必ず `Team` のメソッドを経由する
- admin が 0 人になる操作は `Team` 側でガード

```cpp
Result<void> Team::removeMember(const UserId& userId) {
    if (it->role().isAdmin() && adminCount() <= 1) {
        return Result<void>::err("Team: チームには admin が最低 1 人必要です");
    }
    // ...
}
```

### タイムスタンプの扱い

`created_at` / `updated_at` はインフラ層（DB）で管理するものなので、
エンティティのファクトリには含めず、別途 `setTimestamps()` で設定できるようにしました。

```cpp
// DB再構築時のみ呼び出す
void User::setTimestamps(std::string createdAt, std::string updatedAt) {
    createdAt_ = std::move(createdAt);
    updatedAt_ = std::move(updatedAt);
}
```

`setTimestamps()` は `public` のままですが、呼び出しを Repository 実装に限定するのが設計上の意図です。
本来は `friend class` や内部ファクトリで呼び出し元を制限する方が安全です。

---

## 次のステップ

フェーズ3では Repository インターフェース（`IUserRepository` など）を実装し、
フェーズ4で libpqxx を使った PostgreSQL 実装につなげます。

---

## おわりに

値オブジェクトをエンティティに組み上げる過程で、C++ の型システムをどこまで活用できるかが設計の鍵になると感じました。
特に `UuidId<Tag>` テンプレートと `Result<T>` の組み合わせは、ドメインの制約をコンパイル時に表現する上で有効なパターンです。

---

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
