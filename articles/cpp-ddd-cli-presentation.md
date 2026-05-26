---
title: "C++17 × DDD でCLIプレゼンテーション層を実装する――UseCase の DI と対話型 REPL 設計"
emoji: "🖥️"
type: "tech"
topics: ["cpp", "ddd", "クリーンアーキテクチャ", "cli"]
published: false
---

## はじめに

OKR管理ツールを C++17 × DDD（ドメイン駆動設計）で実装しています。
これまでのフェーズで値オブジェクト・エンティティ・Repository・UseCase を実装してきました。

今回のフェーズ7では **CLIプレゼンテーション層** を実装しました。
`src/presentation/cli/CliApp.hpp` に対話型 REPL（Read-Eval-Print Loop）を実装し、
`user create`・`team list`・`objective create` などのコマンドで OKR データを操作できるようにしました。

実装で意識したポイントをまとめます。

---

## 対象読者

- C++ × DDD でクリーンアーキテクチャを実践したい方
- UseCase に CLI を接続する設計を見てみたい方
- テスト可能な CLI を C++ で書きたい方

---

## アーキテクチャの全体像

```
main_cli.cpp
    │
    └── CliApp（プレゼンテーション層）
            │  ← shared_ptr で DI
            ├── UserUseCase
            ├── TeamUseCase       （アプリケーション層）
            ├── PeriodUseCase
            └── ObjectiveUseCase
                    │  ← shared_ptr で DI
                    ├── PgUserRepository
                    ├── PgTeamRepository      （インフラ層）
                    ├── PgPeriodRepository
                    └── PgObjectiveRepository
```

CliApp は UseCase のインターフェースにしか依存しません。
`main_cli.cpp` でインフラ層（libpqxx）を組み立てて DI するので、
**プレゼンテーション層がDBを知らない** 設計になっています。

---

## CliApp.hpp の設計

### コンストラクタ：UseCase を DI で受け取る

```cpp
class CliApp {
public:
    CliApp(
        std::shared_ptr<UserUseCase>      userUC,
        std::shared_ptr<TeamUseCase>      teamUC,
        std::shared_ptr<PeriodUseCase>    periodUC,
        std::shared_ptr<ObjectiveUseCase> objectiveUC,
        std::ostream&                     out = std::cout
    );
```

UseCase を `shared_ptr` で受け取ります。`std::ostream&` も外から渡せるようにしており、テスト時は `std::ostringstream` を渡せばターミナルに出力せずに結果を検査できます。

### メインループ：run()

```cpp
void run(std::istream& in = std::cin) {
    printBanner();
    std::string line;
    while (true) {
        out_ << "\nokr> ";
        out_.flush();
        if (!std::getline(in, line)) break;  // EOF で終了

        auto tokens = tokenize(line);
        if (tokens.empty()) continue;        // 空行は無視

        if (tokens[0] == "quit" || tokens[0] == "exit") break;
        dispatch(tokens);
    }
}
```

`std::cin` と `std::cout` を直接使わず、引数として受け取っています。
これにより `run(iss, oss)` のようにテストから呼び出せます。

### コマンドディスパッチ

```
okr> user create 田中太郎 taro@example.com
okr> user list
okr> team create 開発チーム
okr> team add-member <team-id> <user-id> admin
okr> period create <team-id> 2025-H1 H1 2025-01-01 2025-06-30
okr> objective create <period-id> <owner-id> "売上を2倍にする"
okr> help
okr> quit
```

名前空間（`user` / `team` / `period` / `objective`）でサブコマンドに分岐します。

```cpp
void dispatch(const std::vector<std::string>& tokens) {
    const std::string& ns = tokens[0];
    if      (ns == "user")      dispatchUser(tokens);
    else if (ns == "team")      dispatchTeam(tokens);
    else if (ns == "period")    dispatchPeriod(tokens);
    else if (ns == "objective") dispatchObjective(tokens);
    else out_ << "❌ 不明なコマンド: " << ns << "\n";
}
```

---

## 詰まったポイント① addMember の戻り型が Result\<void\>

最初、`team add-member` の処理を次のように書いていました。

```cpp
auto result = teamUC_->addMember(input);
if (!result) { out_ << "❌ " << result.error() << "\n"; return; }
printTeam(result.value());  // ← コンパイルエラー！
```

`addMember` は `Result<void>` を返すので `result.value()` は存在しません。
UseCase 側を確認せずに「他のコマンドと同じパターンで書ける」と思い込んでいたのが原因です。

修正は「追加後に `getTeam` で再取得して表示する」方針にしました。

```cpp
auto result = teamUC_->addMember(input);
if (!result) { out_ << "❌ " << result.error() << "\n"; return; }
out_ << "✅ メンバーを追加しました\n";
// 追加後の状態を表示するため再取得
auto getResult = teamUC_->getTeam(GetTeamInput{tokens[2]});
if (getResult) printTeam(getResult.value());
```

**教訓:** UseCase の戻り型（`Result<T>` の `T` が何か）は都度確認する。`void` 系は `.value()` が存在しない。

---

## 詰まったポイント② コメント内の `\` が warning になる

`main_cli.cpp` に次のようなコメントを書いていました。

```cpp
// g++ -std=c++17 -Wall -I src \
//     src/main_cli.cpp \
```

これがコンパイル時に警告を出しました。

```
warning: multi-line comment [-Wcomment]
```

`//` コメントの末尾の `\` は「次の行もコメントに含める」行継続として解釈されます。
`-Wextra` を有効にしているとこれが警告になります。

修正はシェルの複数行記法を `\` で表現するのをやめ、コマンド例をコメントに含めないようにしました。

---

## main_cli.cpp：DI の組み立て

```cpp
int main() {
    auto conn = std::make_shared<pqxx::connection>(connectionString());

    // インフラ層
    auto userRepo      = std::make_shared<PgUserRepository>(conn);
    auto teamRepo      = std::make_shared<PgTeamRepository>(conn);
    auto periodRepo    = std::make_shared<PgPeriodRepository>(conn);
    auto objectiveRepo = std::make_shared<PgObjectiveRepository>(conn);

    // アプリケーション層
    auto userUC      = std::make_shared<UserUseCase>(userRepo);
    auto teamUC      = std::make_shared<TeamUseCase>(teamRepo);
    auto periodUC    = std::make_shared<PeriodUseCase>(periodRepo);
    auto objectiveUC = std::make_shared<ObjectiveUseCase>(objectiveRepo);

    // プレゼンテーション層
    CliApp app{userUC, teamUC, periodUC, objectiveUC};
    app.run();
}
```

`pqxx::connection` を `shared_ptr` で作り、全 Repository に渡しています。
1本の DB 接続をすべての Repository で共有する設計です。

---

## ビルドと実行

DevContainer 内で以下を実行します。

```bash
# ビルドのみ
bash /workspace/scripts/build-cli.sh

# ビルド + 起動（DB接続確認付き）
bash /workspace/scripts/run-cli.sh

# または Makefile から
cd /workspace/05_DDD統合
make run-cli
```

起動すると対話プロンプトが表示されます。

```
========================================
 OKR管理ツール CLI（フェーズ7）
 'help' でコマンド一覧  'quit' で終了
========================================

okr> user create 田中太郎 taro@example.com
✅ ユーザーを作成しました
  id        : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  name      : 田中太郎
  email     : taro@example.com
  createdAt : 2026-05-26T...

okr> user list
ユーザー一覧（1件）
----------------------------------------
  id        : xxxxxxxx-...
  name      : 田中太郎
  ...

okr> quit
bye.
```

---

## まとめ

| 設計のポイント | 内容 |
|---|---|
| UseCase を `shared_ptr` で DI | CLI → UseCase → Repository の依存方向を一方向に保つ |
| `std::ostream&` を注入 | テスト時に `ostringstream` を渡して出力を検査できる |
| `std::istream&` も注入 | スクリプトや自動テストから `istringstream` を渡せる |
| `Result<T>` でエラーを表示 | 失敗しても CLI ループが継続する（落ちない設計） |
| スモークテストと CLI を分離 | `main.cpp`（テスト）/ `main_cli.cpp`（CLI）を別ファイルに |

クリーンアーキテクチャを徹底したおかげで、CLI を追加するときに既存のドメイン層・インフラ層を一切触らずに済みました。

次は KeyResultUseCase を CLI に組み込み、OKR の進捗更新まで操作できるようにする予定です。

---

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
