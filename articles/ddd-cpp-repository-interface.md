---
title: "C++ × DDDでRepositoryインターフェースを設計する — 純粋仮想クラスで依存を逆転させる"
emoji: "🔌"
type: "tech"
topics: ["cpp", "ddd", "cleanarchitecture", "oop", "designpattern"]
published: false
---

## はじめに

OKR管理ツールを C++ × DDD / クリーンアーキテクチャで実装しています。フェーズ1（値オブジェクト）・フェーズ2（エンティティ）に続き、フェーズ3として **Repositoryインターフェース** を設計しました。

本記事では C++ で Repository パターンを実現する際の設計判断をまとめます。

---

## Repositoryインターフェースの役割

DDD における Repository は「集約のコレクション」を抽象化したものです。ドメイン層はデータの永続化方法を知らず、インターフェースだけに依存します。

```
domain/repository/IUserRepository.hpp   ← ドメイン層（依存される側）
infrastructure/repository/PgUserRepository.cpp ← インフラ層（依存する側）
```

この逆転した依存関係（依存性逆転の原則 / DIP）により、PostgreSQL を SQLite に差し替えてもドメインコードは一切変更不要になります。

---

## C++ での実装：純粋仮想クラス

Java や TypeScript では `interface` キーワードが使えますが、C++ にはありません。代わりに **純粋仮想関数のみを持つ抽象クラス** で同等のインターフェースを実現します。

```cpp
class IUserRepository {
public:
    virtual ~IUserRepository() = default;

    virtual Result<std::optional<User>> findById(const UserId& id) const = 0;
    virtual Result<std::optional<User>> findByEmail(const Email& email) const = 0;
    virtual Result<std::vector<User>>   findAll() const = 0;
    virtual Result<void>                save(const User& user) = 0;
    virtual Result<void>                remove(const UserId& id) = 0;
};
```

### ポイント①：仮想デストラクタは必須

基底クラスポインタ経由でオブジェクトを削除するため、`virtual ~IUserRepository() = default;` が必要です。これを忘れると派生クラスのデストラクタが呼ばれず未定義動作になります。

### ポイント②：戻り値は `Result<T>`

例外を使わない設計のため、すべての操作で `Result<T>`（`std::expected` の自前実装）を返します。呼び出し側は戻り値を見てエラーを処理します。

```cpp
auto result = userRepo.findById(userId);
if (!result) {
    // result.error() でエラーメッセージ取得
    return Result<void>::err(result.error());
}
auto user = result.value(); // std::optional<User>
```

### ポイント③：存在しない場合は `std::optional`

`findById` などの検索系は「見つからない」が正常ケースなので `Result<std::optional<T>>` にしています。`Result<T>` のエラーは DB 接続失敗などの異常系専用です。

---

## 集約境界とRepositoryの対応

DDDでは **集約ルートのみが Repository を持ちます**。集約内のエンティティは集約ルート経由でのみ管理します。

| 集約ルート    | Repository              | 集約内エンティティ |
| ------------- | ----------------------- | ----------------- |
| `User`        | `IUserRepository`       | なし              |
| `Team`        | `ITeamRepository`       | `TeamMember`      |
| `Period`      | `IPeriodRepository`     | なし              |
| `Objective`   | `IObjectiveRepository`  | なし              |
| `KeyResult`   | `IKeyResultRepository`  | `KrProgressLog`   |

`Team` を保存するとき `TeamMember` も一緒に保存・削除するのが Repository の責務です。これが「集約の整合性を保証する」という意味になります。

```cpp
// ITeamRepository の save は Team + TeamMember を一括処理する
virtual Result<void> save(const Team& team) = 0;
```

---

## クエリメソッドの設計

ユースケースから逆算して必要なクエリを洗い出しました。

```cpp
// IObjectiveRepository
virtual Result<std::vector<Objective>> findByPeriodId(const PeriodId& periodId) const = 0;
virtual Result<std::vector<Objective>> findByOwnerId(const UserId& ownerId) const = 0;

// IKeyResultRepository
virtual Result<std::vector<KeyResult>> findByObjectiveId(const ObjectiveId& objectiveId) const = 0;
virtual Result<std::vector<KeyResult>> findByOwnerId(const UserId& ownerId) const = 0;
```

`findAll` は開発・デバッグ用途であり、本番では `findByXxx` を使う想定です。

---

## インターフェースがコンパイルエラーを防ぐ

純粋仮想クラスは **インスタンス化できません**。`PgUserRepository` がメソッドを実装し忘れると、コンパイル時にエラーになります。

```
error: cannot instantiate abstract class 'PgUserRepository'
note: unimplemented pure virtual method 'findByEmail' in 'PgUserRepository'
```

インターフェースがドキュメントであり、同時に実装漏れを防ぐ型チェックになっています。

---

## 次のステップ：フェーズ4 libpqxx 実装

インターフェースが揃ったので、次はインフラ層で libpqxx を使った具体的な実装を行います。

- `PgUserRepository` / `PgTeamRepository` / `PgPeriodRepository`
- `PgObjectiveRepository` / `PgKeyResultRepository`

特に `save` の upsert（INSERT ON CONFLICT DO UPDATE）と、集約内エンティティの差分更新が実装のポイントになりそうです。

---

## まとめ

- C++ のインターフェースは **純粋仮想クラス** で実現する
- 仮想デストラクタを忘れない（`= default`）
- 戻り値は `Result<T>` で例外を使わないエラーハンドリング
- 存在しない場合は `std::optional<T>` で表現する
- **集約ルートのみが Repository を持つ**（集約内エンティティは集約ルート経由）
- ドメイン層はインターフェースのみ知り、DB の詳細を知らない（DIP）

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
