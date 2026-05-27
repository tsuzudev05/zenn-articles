---
title: "Go × DDD で全集約を実装する――C++17実装との比較でパターンの本質を理解する"
emoji: "🐹"
type: "tech"
topics: ["go", "ddd", "postgresql", "pgx", "cpp"]
published: false
---

# Go × DDD で全集約を実装する

C++17 で作ったOKR管理ツール（値オブジェクト → エンティティ → Repository インターフェース → libpqxx 実装）を、Go + pgx v5 で書き直した。User 集約に続き、今回は **Team / Period / Objective / KeyResult** の4集約を一気に実装した記録。

C++ と Go で「同じ設計思想を別言語で表現する」ときの対応関係に注目しながら解説する。

---

## 対応言語マップ：C++17 → Go

| C++17 の概念 | Go の対応表現 |
|---|---|
| `Result<T>` | `(T, error)` の多値返却 |
| `Result<void>` | `error` 単独 |
| `std::optional<T>` | `*T`（nil ポインタ） |
| `std::variant<Numeric, Checkbox>` | `KrType` + フィールド分岐 |
| `private` コンストラクタ + `create()` | パッケージ外非公開フィールド + `New*()` ファクトリ |
| `shared_ptr<IRepository>` DI | インターフェース型の引数渡し |
| `pqxx::work` トランザクション | `pgx.Tx` |

---

## Team 集約：集約ルートとメンバー管理

### C++17 版

```cpp
class Team {
    TeamId id_;
    std::string name_;
    std::vector<TeamMember> members_;
public:
    Result<void> addMember(UserId userId, Role role);
    Result<void> removeMember(TeamMemberId memberId);
    Result<void> changeMemberRole(TeamMemberId memberId, Role role);
};
```

### Go 版

```go
type Team struct {
    id      TeamId
    name    string
    members []TeamMember
}

func (t *Team) AddMember(userId user.UserId, role Role) error {
    for _, m := range t.members {
        if m.UserId() == userId {
            return fmt.Errorf("Team.AddMember: already a member: %s", userId)
        }
    }
    memberId, err := NewTeamMemberId(uuid.New().String())
    if err != nil {
        return err
    }
    t.members = append(t.members, NewTeamMember(memberId, t.id, userId, role))
    return nil
}
```

**ポイント:** C++ の `Result<void>` が Go では `error` に直接対応する。エラーがなければ `nil` を返す。ドメインロジック（重複チェック）は言語に関係なく集約ルート内に閉じ込める。

---

## Period 集約：値オブジェクトの組み合わせ

### DateRange の設計

```go
// C++: DateRange(start, end) → start < end を保証して Result<DateRange> を返す
// Go:  同様に NewDateRange でバリデーション

type DateRange struct {
    start time.Time
    end   time.Time
}

func NewDateRange(startStr, endStr string) (DateRange, error) {
    start, err := time.Parse("2006-01-02", startStr)
    if err != nil {
        return DateRange{}, fmt.Errorf("DateRange: invalid start date: %w", err)
    }
    end, err := time.Parse("2006-01-02", endStr)
    if err != nil {
        return DateRange{}, fmt.Errorf("DateRange: invalid end date: %w", err)
    }
    if !start.Before(end) {
        return DateRange{}, fmt.Errorf("DateRange: start must be before end")
    }
    return DateRange{start: start, end: end}, nil
}
```

C++ では `start < end` の判定に `std::chrono::system_clock::time_point` を使うが、Go では `time.Time.Before()` がよりシンプルに書ける。

### Half（半期）値オブジェクト

```go
type Half string

const (
    H1 Half = "H1"
    H2 Half = "H2"
)

func NewHalf(s string) (Half, error) {
    switch Half(s) {
    case H1, H2:
        return Half(s), nil
    }
    return "", fmt.Errorf("Half: invalid value: %s", s)
}
```

C++ の `enum class Half { H1, H2 }` に対して、Go では `type Half string` + 定数が慣用的。DBのtext型とのマッピングが自然になる。

---

## Objective / KeyResult：シンプルな集約ルート

ObjectiveはKeyResultを集約として持たず、独立した集約ルートとして設計した（C++版と同様）。

```go
type Objective struct {
    id       ObjectiveId
    periodId period.PeriodId
    ownerId  user.UserId
    title    string
}

func NewObjective(id ObjectiveId, periodId period.PeriodId,
    ownerId user.UserId, title string) (Objective, error) {
    if strings.TrimSpace(title) == "" {
        return Objective{}, fmt.Errorf("Objective: title must not be empty")
    }
    return Objective{id: id, periodId: periodId, ownerId: ownerId, title: title}, nil
}
```

---

## KeyResult 集約：Union型の Go 的表現

C++17 では `std::variant<NumericProgress, CheckboxProgress>` でKRの種別を表現した。Go には variant がないため、`KrType` フィールド + 条件分岐で表現する。

```go
type KrType string

const (
    KrTypeNumeric  KrType = "numeric"
    KrTypeCheckbox KrType = "checkbox"
)

type KeyResult struct {
    id          KeyResultId
    objectiveId objective.ObjectiveId
    ownerId     user.UserId
    title       string
    krType      KrType
    // numeric用
    targetValue  *float64
    currentValue *float64
    unit         *string
    // checkbox用
    isDone *bool
    // 進捗ログ（append-only）
    progressLogs []KrProgressLog
}
```

### 進捗更新メソッドの分離

```go
func (kr *KeyResult) UpdateNumericProgress(value float64, note string) error {
    if kr.krType != KrTypeNumeric {
        return fmt.Errorf("KeyResult.UpdateNumericProgress: not a numeric KR")
    }
    kr.currentValue = &value
    logId, _ := NewKrProgressLogId(uuid.New().String())
    kr.progressLogs = append(kr.progressLogs,
        NewKrProgressLog(logId, kr.id, value, nil, note, time.Now()))
    return nil
}

func (kr *KeyResult) UpdateCheckboxProgress(isDone bool, note string) error {
    if kr.krType != KrTypeCheckbox {
        return fmt.Errorf("KeyResult.UpdateCheckboxProgress: not a checkbox KR")
    }
    kr.isDone = &isDone
    logId, _ := NewKrProgressLogId(uuid.New().String())
    var val *float64
    if isDone {
        one := 1.0
        val = &one
    }
    kr.progressLogs = append(kr.progressLogs,
        NewKrProgressLog(logId, kr.id, 0, val, note, time.Now()))
    return nil
}
```

C++ では variant の型チェックが `std::holds_alternative<>` で行えるが、Go では `krType` フィールドによるランタイムチェックになる。型安全性は落ちるが、コードの明快さは上がる。

---

## Infrastructure 層：pgx v5 のトランザクション設計

### Team：集約の全置換パターン

Team集約はメンバーリストを「現在の全メンバー」として保持するため、Saveのたびにteam_membersを全置換する。

```go
func (r *PgTeamRepository) Save(ctx context.Context, team domain.Team) error {
    return pgx.BeginTxFunc(ctx, r.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
        // 1. teams テーブルをupsert
        _, err := tx.Exec(ctx, `
            INSERT INTO teams (id, name, updated_at)
            VALUES ($1, $2, now())
            ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, updated_at = now()
        `, team.Id().String(), team.Name())
        if err != nil {
            return err
        }

        // 2. team_members を全削除 → 全挿入（Read-Modify-Write の結果を信頼）
        _, err = tx.Exec(ctx, `DELETE FROM team_members WHERE team_id = $1`,
            team.Id().String())
        if err != nil {
            return err
        }
        for _, m := range team.Members() {
            _, err = tx.Exec(ctx, `
                INSERT INTO team_members (id, team_id, user_id, role)
                VALUES ($1, $2, $3, $4)
            `, m.Id().String(), team.Id().String(), m.UserId().String(), string(m.Role()))
            if err != nil {
                return err
            }
        }
        return nil
    })
}
```

**なぜ全置換か？** 集約ルートが「現在のメンバーリスト」を正として持っているため、差分管理（追加/削除を個別に追跡）は不要。集約境界がDBのトランザクション境界と一致する。

### KeyResult：append-only の進捗ログ

進捗ログは一度記録したら変更しない（履歴として蓄積する）設計。`ON CONFLICT (id) DO NOTHING` でべき等な保存を実現する。

```go
// KrProgressLog の保存（upsertではなくINSERT ... DO NOTHING）
for _, log := range kr.ProgressLogs() {
    _, err = tx.Exec(ctx, `
        INSERT INTO kr_progress_logs (id, key_result_id, numeric_value, is_done, note, recorded_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        ON CONFLICT (id) DO NOTHING
    `, log.Id().String(), kr.Id().String(),
       log.NumericValue(), log.IsDone(), log.Note(), log.RecordedAt())
    if err != nil {
        return err
    }
}
```

team_membersは「最新状態」なので全置換、kr_progress_logsは「不変な履歴」なので追記のみ。同じDBスキーマ上でも、集約の性質によって保存戦略を使い分ける。

---

## FindById のパターン：C++ vs Go

### C++ (libpqxx)

```cpp
Result<std::optional<User>> PgUserRepository::findById(const UserId& id) {
    try {
        pqxx::nontransaction tx{conn_};
        auto row = tx.exec_params1(
            "SELECT id, email FROM users WHERE id = $1", id.toString());
        // ...
    } catch (pqxx::unexpected_rows&) {
        return Result<std::optional<User>>::ok(std::nullopt);
    }
}
```

### Go (pgx v5)

```go
func (r *PgUserRepository) FindByID(ctx context.Context, id domain.UserId) (*domain.User, error) {
    var idStr, emailStr string
    err := r.pool.QueryRow(ctx,
        "SELECT id, email FROM users WHERE id = $1", id.String(),
    ).Scan(&idStr, &emailStr)
    if errors.Is(err, pgx.ErrNoRows) {
        return nil, nil  // 見つからない場合は nil, nil
    }
    if err != nil {
        return nil, fmt.Errorf("PgUserRepository.FindByID: %w", err)
    }
    // ドメインオブジェクトを再構築...
}
```

C++ の `std::optional<User>` が Go では `*User` + nil になる。`pgx.ErrNoRows` と一般エラーを `errors.Is` で区別するのが pgx v5 のイディオム。

---

## スモークテストの設計

User〜KeyResultの全集約をカバーするスモークテストを `cmd/smoke/main.go` に実装した。

```
[1] User Save
[2] User FindByID
[3] User FindByEmail
[4] User FindAll
[5] User Remove（冪等）
[6] User Save（upsert）
[7] User FindAll（更新確認）
[8] Team Save（+メンバー）
[9] Team FindByID
[10] Team FindByUserID
[11] Team FindAll
[12] Team Remove
[13] Period Save
[14] Period FindByID
[15] Period FindByTeamID
[16] Period FindAll
[17] Period Remove
[18] Objective Save
[19] Objective FindByID
[20] Objective FindByPeriodID
[21] Objective Remove
[22] KeyResult Save（numeric）
[23] KeyResult FindByID（ProgressLog付き）
[24] KeyResult FindByObjectiveID
[25] KeyResult UpdateProgress（checkpoint）
[26] KeyResult Remove
```

DevContainer 内での実行方法：

```bash
bash /workspace/scripts/go-test.sh smoke
```

---

## まとめ：言語が変わっても変わらないもの

C++ と Go でDDDを実装して気づいたのは、**言語構文の違いよりもドメインの設計意図の方が実装量に占める割合が大きい**ということだ。

- 集約境界（何がルートで何が内部エンティティか）
- 保存戦略（全置換 vs upsert vs append-only）
- バリデーション責務（どのレイヤーで何を検証するか）

これらはどちらの言語でも同じ判断が必要になる。

言語固有の表現（`Result<T>` vs `(T, error)`、`std::optional<T>` vs `*T`）はイディオムの問題であって、設計の問題ではない。DDD を学ぶなら複数言語で同じ設計を実装してみることで、「本質」と「構文糖衣」の区別がつくようになると感じた。

---

## リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
