---
title: "DDDを意識したPostgreSQLスキーマ設計：OKR管理ツールを題材に"
emoji: "🗄️"
type: "tech"
topics: ["postgresql", "ddd", "database", "sql", "設計"]
published: false
---

## はじめに

DDD（ドメイン駆動設計）を学ぶとき、コードの設計（値オブジェクト・集約・リポジトリ）に目が向きがちです。しかし「そのドメイン設計をDBスキーマにどう落とし込むか」は意外と語られません。

本記事では、OKR管理ツールを題材に、DDDの概念をPostgreSQLスキーマへ落とし込む際の設計方針と、その具体的な実装を紹介します。

---

## 対象読者

- DDDを勉強中で、DBスキーマ設計への応用を知りたい方
- PostgreSQLのCHECK制約・トリガーを実践的に使いたい方
- 集約境界をどこで引くべきか迷っている方

---

## ドメイン設計：集約の定義から始める

スキーマ設計の前に、まず集約を定義します。

OKR管理ツールの集約は以下の4つです。

```
Team集約      : Team（ルート）+ TeamMember
Period集約    : Period（ルート）
Objective集約 : Objective（ルート）
KeyResult集約 : KeyResult（ルート）+ KrProgressLog
```

### ObjectiveとKeyResultを別集約にした理由

直感的には「ObjectiveがKeyResultを持つ」ので同じ集約にしたくなります。しかし以下の理由で分割しました。

- **トランザクション境界が異なる**：KRの進捗更新（頻繁）とObjectiveの更新（稀）は別々に行われる
- **独立して検索するユースケースがある**：「このKRの進捗履歴を見たい」はObjectiveを経由しない
- **集約を小さく保つ**：並行更新時のロック競合を減らせる

---

## ユビキタス言語の定義

コード・DB・会話で統一して使う用語を先に決めます。

| 日本語 | 英語 | 説明 |
|---|---|---|
| 期間 | Period | 半期単位のOKRサイクル（H1/H2） |
| 目標 | Objective | 定性的な目標（OのO） |
| 主要な結果 | KeyResult | 達成度を測る指標（KR） |
| 進捗ログ | ProgressLog | KRの時系列履歴 |
| オーナー | Owner | ObjectiveまたはKRの責任者 |

テーブル名・カラム名はこのユビキタス言語に揃えます。

---

## スキーマ設計のポイント

### 1. ドメイン知識をCHECK制約で守る

`VARCHAR` で持つカラムは、許容値をCHECK制約で明示します。

```sql
-- ロール：admin / member のみ
role VARCHAR(20) NOT NULL DEFAULT 'member'
    CHECK (role IN ('admin', 'member')),

-- 半期：H1 / H2 のみ
half VARCHAR(2) NOT NULL
    CHECK (half IN ('H1', 'H2')),

-- 期間の整合性
CHECK (start_date < end_date)
```

文字列で持ちながら、DBレベルでドメイン知識を強制できます。

### 2. kr_typeでNumeric/Checkboxを切り替える

KRの進捗管理には「数値型」と「チェックボックス型」の2種類があります。

```sql
CREATE TABLE key_results (
    kr_type       VARCHAR(20) NOT NULL
                      CHECK (kr_type IN ('numeric', 'checkbox')),
    -- numeric 型のみ使用
    target_value  NUMERIC,
    current_value NUMERIC,
    -- checkbox 型のみ使用
    is_completed  BOOLEAN NOT NULL DEFAULT FALSE,

    -- numeric の場合 target_value は必須
    CHECK (
        (kr_type = 'numeric' AND target_value IS NOT NULL)
        OR kr_type = 'checkbox'
    )
);
```

`target_value` / `current_value` はNULLableにして、`kr_type`との整合性をCHECK制約で保証します。ドメイン層では `std::variant<NumericProgress, CheckboxProgress>` として型安全に扱います。

### 3. 進捗履歴はKR本体と分離する

KR本体は「最新値」だけを持ち、履歴は `kr_progress_logs` に積みます。

```sql
-- KR本体：最新値のみ
key_results (
    current_value NUMERIC,
    is_completed  BOOLEAN
)

-- 履歴：時系列で積む
kr_progress_logs (
    key_result_id UUID NOT NULL REFERENCES key_results(id),
    value         NUMERIC,
    completed     BOOLEAN,
    recorded_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
```

KR本体と進捗ログを分離することで、「現在の達成率を素早く取得」と「進捗の推移を可視化」を両立できます。

### 4. owner_idの整合性はドメインサービスで保証する

`objectives.owner_id` が対象チームのメンバーかどうかは、外部キー制約では表現できません。

```sql
-- DBレベルでは users への参照のみ保証
owner_id UUID NOT NULL REFERENCES users(id),
```

チームメンバーかどうかの検証は**ドメインサービス層の責務**として明示します。

```cpp
// ドメインサービス
class ObjectiveService {
public:
    Result<Objective> create(TeamId team_id, UserId owner_id, ...);
    // owner_id が team_id のメンバーか検証してから Repository に渡す
};
```

---

## updated_atの自動更新トリガー

`updated_at` の更新をアプリ層に任せると、更新漏れが起きます。トリガーで自動化します。

```sql
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_objectives_updated_at
    BEFORE UPDATE ON objectives
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
```

---

## インデックス設計

検索パターンを事前に洗い出してインデックスを定義します。

```sql
-- チーム別・期間別の検索
CREATE INDEX idx_periods_team_id          ON periods(team_id);
CREATE INDEX idx_objectives_period_id     ON objectives(period_id);

-- KR別の進捗履歴検索（時系列）
CREATE INDEX idx_kr_progress_logs_kr_id   ON kr_progress_logs(key_result_id);
CREATE INDEX idx_kr_progress_logs_recorded ON kr_progress_logs(recorded_at);
```

---

## まとめ

| 設計方針 | 実装手段 |
|---|---|
| 集約境界をテーブルに反映する | 外部キーのON DELETE CASCADEで集約内を表現 |
| ドメイン知識をDBで守る | CHECK制約で許容値を制限 |
| 型の分岐をNULLableで表現 | kr_typeとCHECK制約の組み合わせ |
| 整合性の責務を明確化 | DBで守れるものはDB、無理なものはドメインサービス |
| 更新漏れを防ぐ | updated_atトリガーで自動化 |

DDDのスキーマ設計は「ドメイン知識をどこで守るか」の責務分担が肝です。DBで守れるものはDB、ドメイン層で守るべきものはドメインサービスに明示する——この原則を意識するだけで設計の迷いが減りました。

---

## 関連リポジトリ

https://github.com/tsuzudev05/rdb-learning-postgres
