---
title: "C++17でDDDの値オブジェクトを実装する：Result型・std::variant・ファクトリパターン"
emoji: "⚙️"
type: "tech"
topics: ["cpp", "ddd", "設計", "クリーンアーキテクチャ"]
published: false
---

## はじめに

DDD（ドメイン駆動設計）の値オブジェクト（Value Object）はPythonやGoで実装する記事が多いですが、C++での実例は少ないです。

本記事では、OKR管理ツールのドメイン層をC++17で実装する中で得た、値オブジェクト設計のパターンを紹介します。特に以下の3点を詳しく解説します。

- `Result<T>` による例外を使わないエラーハンドリング
- `std::variant` を使ったUnion型の値オブジェクト
- イミュータブル・ファクトリパターンの実装

---

## 対象読者

- C++でDDDを実践したい方
- C++の例外を使わずにエラーハンドリングしたい方
- `std::variant` の実用的な使い方を知りたい方

---

## 値オブジェクトの3原則

DDDにおける値オブジェクトは以下の3つを満たします。

1. **イミュータブル**：生成後に値が変わらない
2. **等価性**：IDではなく値で等価比較する
3. **自己検証**：不正な値を持てない

C++で実現するには「コンストラクタをprivate」にして「ファクトリメソッドでバリデーション」する設計が適しています。

---

## Result\<T\>：例外を使わないエラーハンドリング

C++23の `std::expected` を自前実装します。ドメイン層は外部依存ゼロを守るため、STLだけで実装します。

```cpp
template <typename T>
class Result {
public:
    static Result ok(T value) {
        Result r;
        r.storage_ = std::move(value);
        return r;
    }

    static Result err(std::string message) {
        Result r;
        r.storage_ = DomainError{std::move(message)};
        return r;
    }

    bool ok() const {
        return std::holds_alternative<T>(storage_);
    }
    explicit operator bool() const { return ok(); }

    const T& value() const { return std::get<T>(storage_); }
    const std::string& error() const {
        return std::get<DomainError>(storage_).message;
    }

private:
    std::variant<T, DomainError> storage_;
};
```

`Result<void>` は `template<>` で特殊化して、成功/失敗のみを表現します。

### 使い方

```cpp
auto result = UserId::create("invalid-uuid");
if (!result) {
    std::cerr << result.error() << "\n";
    return;
}
auto id = result.value();
```

例外を投げないため、エラーパスが明示的になります。

---

## 値オブジェクトの実装例

### UserId：UUIDバリデーション

```cpp
class UserId {
public:
    static Result<UserId> create(const std::string& value) {
        if (!isValidUuid(value)) {
            return Result<UserId>::err(
                "UserId: 無効なUUID形式です: " + value
            );
        }
        return Result<UserId>::ok(UserId{value});
    }

    const std::string& value() const { return value_; }
    bool operator==(const UserId& other) const {
        return value_ == other.value_;
    }

private:
    explicit UserId(std::string value) : value_(std::move(value)) {}

    static bool isValidUuid(const std::string& s) {
        static const std::regex uuid_regex(
            "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}"
            "-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            std::regex::icase
        );
        return std::regex_match(s, uuid_regex);
    }

    std::string value_;
};
```

コンストラクタを `private` にすることで、バリデーションを経由しない生成を防ぎます。

### Role：列挙型で許容値を制限

文字列ではなく `enum class` で持つことで、コンパイル時に不正な値を防ぎます。

```cpp
class Role {
public:
    enum class Value { Admin, Member };

    static Result<Role> create(const std::string& value) {
        if (value == "admin")  return Result<Role>::ok(Role{Value::Admin});
        if (value == "member") return Result<Role>::ok(Role{Value::Member});
        return Result<Role>::err(
            "Role: 無効なロールです: " + value
        );
    }

    bool isAdmin() const { return value_ == Value::Admin; }

    // DB保存用
    std::string toString() const {
        return value_ == Value::Admin ? "admin" : "member";
    }

private:
    explicit Role(Value value) : value_(value) {}
    Value value_;
};
```

---

## std::variantでUnion型の値オブジェクトを作る

OKRのKR（主要な結果）には2種類の進捗管理があります。

- **数値型**：売上100万円 → 現在60万円
- **チェックボックス型**：完了 / 未完了

これを `std::variant` でUnion型として表現します。

```cpp
// 数値進捗
class NumericProgress {
public:
    static Result<NumericProgress> create(double target, double current) {
        if (target <= 0.0)  return Result<NumericProgress>::err("目標値は0より大きい必要があります");
        if (current < 0.0)  return Result<NumericProgress>::err("現在値は0以上である必要があります");
        return Result<NumericProgress>::ok(NumericProgress{target, current});
    }

    double achievementRate() const { return current_ / target_; }

private:
    NumericProgress(double target, double current)
        : target_(target), current_(current) {}
    double target_, current_;
};

// チェックボックス進捗
class CheckboxProgress {
public:
    static CheckboxProgress create(bool completed) {
        return CheckboxProgress{completed};
    }
    double achievementRate() const { return completed_ ? 1.0 : 0.0; }

private:
    explicit CheckboxProgress(bool completed) : completed_(completed) {}
    bool completed_;
};

// Union型
using KeyResultProgress = std::variant<NumericProgress, CheckboxProgress>;
```

### visitorパターンで達成率を取得

`std::visit` でUnion型を型安全に処理できます。

```cpp
double getAchievementRate(const KeyResultProgress& progress) {
    return std::visit(
        [](const auto& p) { return p.achievementRate(); },
        progress
    );
}

// 使い方
auto numeric = NumericProgress::create(100.0, 60.0).value();
KeyResultProgress progress = numeric;
double rate = getAchievementRate(progress); // 0.6
```

`if` や `dynamic_cast` を使わずに型ごとの処理を書けます。

---

## 設計のポイントまとめ

| 課題 | 解決策 |
|---|---|
| 例外を使いたくない | `Result<T>` で成功/失敗を明示 |
| 不正な値を持たせない | コンストラクタをprivate + ファクトリパターン |
| 文字列の許容値を制限したい | `enum class` で表現、`toString()` でDB変換 |
| 型の分岐を型安全に扱いたい | `std::variant` + `std::visit` |
| 外部ライブラリに依存したくない | STL（C++17）のみで実装 |

---

## おわりに

C++17のSTLだけでDDDの値オブジェクトを実装できます。特に `std::variant` はUnion型を型安全に扱えるため、ドメインモデルの表現力が上がりました。

次回はこれらの値オブジェクトを使ったエンティティと、libpqxxを使ったRepositoryパターンの実装を紹介します。

---

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
