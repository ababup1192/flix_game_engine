---
name: compile-fix
description: "Flix のコンパイルエラーを既知の落とし穴（予約語・import の位置・エフェクト・Channel・Java 例外・パターン網羅・Float32/64）と照合して直す。flix check / make check / make test が失敗したとき、E3138・E5252・E6217 等のエラー番号、Parse error・Unable to unify・Non-exhaustive match・Unresolved type、「Expected ',' before '='」のような原因の見えないエラーが出たときに使う。"
allowed-tools: Read, Grep, Glob, Bash
sync: 2026-10-17
---

# Flix コンパイルエラー診断

## 手順

0. **型・引数・名前のエラー (Undefined name / Unexpected type / Unable to unify 等) は、
   まず engine の `docs/api-digest.md`（全 pub 宣言のダイジェスト。`make api Q=<名前>` で
   1 行でも引ける）で正しいシグネチャを確かめる** — ソースの grep や unzip より先。
1. エラーメッセージを確認する（ユーザー提示 or `make check`（型検査だけ・一番速い）/ `make test` を実行）
2. 下記の「既知の落とし穴リスト」と照合する
3. 該当する場合は修正方法を提示する
4. 該当しない場合は、エラー箇所と関連する型定義を読んで診断する

補足: `make check` の失敗出力の末尾には `bin/fge explain-error` が処方箋 1 行を自動で添える。
その対応表の実体は `bin/lint-rules/explain-error.json` にあり、由来はこのスキルの落とし穴リスト —
落とし穴を足したら両方を更新する。

## 既知の落とし穴リスト

### 1. 予約語の使用（パースエラー）

**症状**: `Unexpected token` / `Parse error` が変数名や import 文で発生

**修正**: 予約語（`handler`, `do`, `resume`, `run`, `spawn`, `region`, `inject`, `project`, `solve`）を識別子に使わない。別の単語か 2 単語以上で命名する。変数・関数名だけでなく**レコードのフィールド名**（`{ spawn = Cell }` 等）でもパースエラーになる。ゲームで踏みやすいのは `spawn`（湧き位置）と `run`（走り・実行）— `start` / `walkR` などへ逃がす。全量は `bin/lint-rules/flix-reserved.json`。

### 2. import の位置（スコープエラー）

**症状**: Java クラスが見つからない / `Unresolved type`

**修正**: Java の import をモジュール直下（関数の外）に移動する。例は `flix-docs/reference.md` の「Channel と Java interop」。

### 3. Channel API の引数（型エラー）

**症状**: `Channel.buffered` で型が合わない / Region 関連エラー

**修正**: `Channel.buffered(rc)` → `Channel.buffered(size)`。戻り値は `(Sender[t], Receiver[t])`。例は `flix-docs/reference.md` の「Channel と Java interop」。

### 4. try-catch の例外型（型エラー）

**症状**: `##java.io.IOException` が見つからない

**修正**: `##` プレフィックスを外し、`import java.io.IOException` してからクラス名で使う。例は `flix-docs/reference.md` の「Channel と Java interop」。

### 5. エフェクトの伝播忘れ（型エラー）

**症状**: 関数の戻り値型でエフェクトが合わない

**原因**: 呼び出し先のエフェクトを関数シグネチャに含めていない

**修正**: 関数の型注釈にエフェクトを追加する（`\ IO + ef` など）。不明なら型注釈を外して推論に任せる。

### 6. パターンマッチの網羅性（警告/エラー）

**症状**: `Non-exhaustive match`

**修正**: 不足している case を足す。Doc 由来の String で分岐しているなら、読み込む所で enum へ変えて網羅性を効かせる（engine の `docs/flix-conventions.md`「型の設計」）。

### 7. List/Set/Map リテラルの型推論失敗

**症状**: `Unable to unify` / 空リテラルで型が決まらない

**原因**: `Nil` や `Set.empty()` だけでは型が推論できないことがある

**修正**: 型注釈を付ける（例: `(Nil: List[Int32])`）、または要素付きで初期化。

### 8. Float32 と Float64 の食い違い

**症状**: `Expected Float32 but got Float64`

**原因**: `1.0` は Float64。Float32 が出るのは GL / OpenAL / STB を呼ぶ境界の内側だけで、
engine の pub 面（型・関数・eff の op）に Float32 は無い。

**修正**: ゲーム側のコードで出たなら、`f32` を足す前に Float64 のまま渡せる口を探す。
engine の中で境界の内側を書いているなら `1.0f32` のようにサフィックスを付ける。

### 9. engine の名前が見つからない（Flix 0.78 の mount）

**症状**: engine の名前で `Undefined name 'App.run'`（E2136）・
`Undefined type 'Color'`（E2916）が大量に出る

**修正**: `bin/fge engine-uses` で mod ごとに `use flix_game_engine::{...}` を足す。
手で書くなら use は mod の中に置く（ファイル直下の use は mod へ届かない）。
engine の非 pub の mod は届かない（`InaccessibleModule`）。

### 10. 多相 effect の型引数（E6795・E3442）

**症状**: `Mismatched type arguments for effect`・
`Illegal polymorphic effect constructor`・`key not found: (ToString,…)` で落ちる

**修正**: 1 つの関数の中で同じ effect は 1 つの型だけ。型ごとに関数を分ける。
effect の型変数（`ef[t]`）には型を当てない。型引数に trait の制約を付けた
ハンドラはコンパイラが落ちるので、写す関数を引数で渡す。

### 11. 依存の manifest（パッケージ管理）

**症状**: `Missing repository`・`Illegal package key` で依存の解決が止まる

**修正**: flix.toml の `[package]` は version・flix・repository の 3 キーだけ。
依存される側は repository が要る。
