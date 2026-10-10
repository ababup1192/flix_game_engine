---
name: flix-docs
description: "このプロジェクトの Flix の書き方（パイプ・エフェクトの伝播とハンドラ・標準ライブラリ優先・Channel / Java interop の落とし穴）。Flix コードを書く前・直す前、構文や API の書き方に迷ったときに使う。"
sync: 2026-08-13
---

# Flix ドキュメント参照

このプロジェクトの Flix の書き方。公式の構文・標準ライブラリで分からない所があるときだけ
https://doc.flix.dev/ の該当ページ（API は https://api.flix.dev/ ）を引く — `for-llms.html` は全文が大きいので丸ごとは取らない。
予約語・型の設計・二乗の禁止は `.claude/rules/flix.md`、名前の付け方は AGENTS.md が正。

---

## Flix コーディングスタイル

### 全般

- **変数名は省略せず、意味が伝わる名前にすること**
  - 型がある場合は、まず型名と揃えられないかを検討する
  - `p` → `player`、`scn` → `scene`、`btn` → `button` のように省略しない

```flix
// NG: 略しすぎて意味が伝わらない
def update(p: Player, scn: Scene): Scene = ...

// OK: 型名と揃えて明確にする
def update(player: Player, scene: Scene): Scene = ...
```

- 関数には必ずドキュメントコメントを書くこと。何の処理をしているか、意図が読み手に明確に伝わること
- type alias でレコード定義、enum、struct は、全体のコメントと各フィールドの役割のコメントを書くこと
- 関数の引数にプリミティブな引数が並ぶ場合は、named-parameters と syntax sugar を採用すること
  - https://doc.flix.dev/records.html?highlight=name#named-parameters
  - 特に **同じ型・似た型が連続するとき**（例: `Float64, Float64`）は取り違えバグの温床になるので必ずレコード化すること
  - **4 つ以上の引数**で意味の単位が混在しているときも検討する
  - 一緒に使われ続けるパラメータセットは型エイリアスにして再利用する
    - 例: `(rootJsonIndex, scene)` → `EditableNode.LookupCtx`、`(mousePos, mouseLeft)` → `DragInput.MouseSnapshot`
  - **同じ形のレコードを複数の関数で使うときは、シグネチャにインライン定義せず `type alias` を共有する**（フィールド追加時の修正漏れを防ぐ）

```flix
// NG: 同じ形を複数の関数で繰り返す
def hitTest(input: {pos = Vec2, button = MouseButton}, scene: Scene): ...
def startDrag(input: {pos = Vec2, button = MouseButton}, scene: Scene): ...

// OK: 1 か所で type alias 定義
type alias MouseSnapshot = {pos = Vec2, button = MouseButton}
def hitTest(input: MouseSnapshot, scene: Scene): ...
def startDrag(input: MouseSnapshot, scene: Scene): ...
```

```flix
// NG: Float64 連続 / 4 引数で取り違え危険
def makeLine(pos: Vec2.Vec2, width: Float64, height: Float64, color: Color): ColorRect

// OK: size を Vec2 にしてレコードで束ねる
def makeLine(line: {pos = Vec2.Vec2, size = Vec2.Vec2}, color: Color): ColorRect
```

### 型の設計（データの持ち方）

- **取りうる値が決まっている物（状態・モード・種別）は String で持たない。enum にする。**
  文字列の等値で分岐すると網羅性チェックが効かず、打ち間違えが `else` に吸われて
  別の値としてエラーも出ずに通る
  - Doc(JSON) から来る値は String なので、**読み込む所で 1 回だけ enum へ変換**して
    内側は enum で回す
- **その case だけが使う値は、レコードに平らに並べず enum の payload へ入れる。**
  並べると、どのフィールドがどの case の物か型から読めなくなる。
  **どの case でも使う値はレコード側に残す**（payload へ動かさない）
  - payload に**レコードは置けない**（`Eq` を derive できなくなる。理屈は
    `docs/flix-conventions.md` の落とし穴）。値が 2 つ以上要るときは case へ並べるか、
    `Eq` を derive した別の enum で包む

```flix
// OK: その case だけが使う値は payload へ / どの case でも使う値はレコードへ
pub enum Playback with Eq, ToString {
    case Stopped
    case Playing(Float64)  // 再生した秒数
    case Paused(Float64)   // 止めた時点の秒数
}
pub type alias Clip = { playback = Playback, name = String, volume = Float64 }
```

### パイプスタイル

- なるべくパイプスタイルを使い `|>` で一時変数を作らないこと
- インラインで書ける場合は、インラインで書いて、一時変数を作らないこと
- `|>` で書きやすいように、レシーバとなる変数を最後の引数として関数を作ること

### 高階関数

- パターンマッチ(match, case)がネストしないように、高階関数をなるべく利用すること
  - `map`, `flatMap` などが続いたら、`forM` が使えないか検討すること
  - `map`, `filter` などが続いたら、`filterMap` 等の関数が使えないか検討すること

### Algebraic Effect の扱い方

- **エフェクトはすぐに `run` せず、呼び出し元へ伝播させること**
  - その場で `run` すると IO に変換され、関数シグネチャが `IO` だらけになる
  - IO が伝播すると「何の副作用が起きているか」が型から読み取れなくなる
  - エフェクトを具体的に残すことで、関数の副作用が明示的になる

```flix
// NG: その場で run して IO に変換してしまう
def getTimestamp(): Int64 \ IO =
    run Clock.currentTime(TimeUnit.Milliseconds) with Clock.runWithIO

// OK: エフェクトを伝播させる（run は呼び出し元に任せる）
def getTimestamp(): Int64 \ Clock =
    Clock.currentTime(TimeUnit.Milliseconds)
```

- **ハンドラの選択は以下の優先順位に従うこと**
  1. **DefaultHandler（何も指定しない）** — `main` や `@Test` ではコンパイラが `@DefaultHandler` を自動挿入するので、明示的なハンドラは不要
  2. **組み込みハンドラを `with` で指定** — ライブラリが提供する `runWithIO` 等を使う
  3. **`with handler` で手書き** — カスタムの振る舞いが必要な場合の最終手段

```flix
// 優先度1: DefaultHandler に任せる（推奨）
// main や @Test ではエフェクトをシグネチャに書くだけでよい
def main(): Unit \ {Clock, Logger} =
    let ts = Clock.currentTime(TimeUnit.Milliseconds);
    Logger.info("Timestamp: ${ts}")

// 優先度2: 組み込みハンドラを with で指定
def example(): Unit \ IO =
    run someEffectfulWork() with Clock.runWithIO

// 優先度3: 手書き handler（最終手段）
def example2(): Unit \ IO =
    run someEffectfulWork() with handler Clock {
        def currentTime(u, k) = k(0i64)
    }
```

- 参考: https://doc.flix.dev/default-handlers.html

- **`run` はネストしないこと** — 複数のエフェクトを 1 ブロックで剥がすときは `run { } with X with Y with Z` の連結構文を使う

```flix
// NG: run の入れ子
run {
    run f() with handler X { ... }
} with handler Y { ... }

// OK: 1 つの run に with を連結
run {
    f()
} with handler X { ... }
  with handler Y { ... }
```

### ライブラリ選択（Java interop より標準ライブラリを優先）

Java の API を直接使う前に、Flix 標準ライブラリに同等の機能がないか必ず確認すること。
API リファレンス: https://api.flix.dev/

- **Random**: `Math.Random`, `Math.Shuffle` を使う。うまくいかない場合は RandomUtil を拡張
- **ファイル読み書き**: `Fs` モジュールを使う（Java の `Files` / `FileInputStream` 等は使わない）
  - `Fs.readFile`, `Fs.writeFile`, `Fs.readLines`, `Fs.writeLines`
  - `Fs.appendFile`, `Fs.appendLines`
  - `Fs.fileExists`, `Fs.fileSize`, `Fs.deleteFile`, `Fs.copyFile`, `Fs.moveFile`
- **ストリーム処理 / バッファ読み込み**: `BufReader` を使う
  - `BufReader.withDefaultCapacity(rc, reader)` で生成
  - `BufReader.readWhile`, `BufReader.peek`, `BufReader.read`, `BufReader.skip`
- **数値型変換**: 各型のモジュールにある変換関数を使う（Java の `Integer.parseInt` 等は使わない）
  - 安全な縮小変換: `Int32.tryToInt8`, `Int32.tryToInt16` → `Option` を返す
  - 拡大変換: `Int32.toInt64`, `Int32.toFloat64` → 精度を保つ
  - 文字列変換: `Int32.fromString` → `Option[Int32]`, `Int32.toString`
  - Float も同様: `Float64.fromString`, `Float32.toFloat64` など
  - `truncateToXxx` は精度が落ちるので意図的な場合のみ使用

---

## テストコードスタイル

`quality-assurance` スキルが正（1 テスト 1 アサート・分岐を書かない・`@Test` は `Unit \ Assert` を返す）。

---

## Flix 固有の注意点（公式ドキュメントに載っていない）

### 予約語に注意

- 全リストと理屈は `.claude/rules/flix.md` が正（変数・関数名だけでなく**レコードのフィールド名**でも落ち、エラーは「Expected ',' before '='」など間接的な形で出る）
- ゲームコードで特に踏みやすいのは `spawn`（湧き位置）と `run`（走り・実行）— `start` / `walkR` などへ逃がす

### Channel API

- Java の atomic 変数を使いたくなったら見ること
- `Channel.buffered(size)` — Region を受け取らない、サイズのみ
- 戻り値は `(Sender[t], Receiver[t])` のタプル
- エフェクトは `Chan` と `NonDet`
- 参考: https://doc.flix.dev/concurrency.html?highlight=Channel#communicating-with-channels

### List.sortBy / List.sort は安定ソートではない

- 同キーの要素の並びが入力順に保たれない（実測: 同キー 7::8::9 が 9::7::8 になる）。
  入力が同じなら結果は毎回同じ（決定的）だが、「渡した順のまま」は保証されない
- 同キーの順序に意味があるときは、キーにタイブレーク（元 index など）を含めて
  `List.zipWithIndex` + 複合キーで並べる
- スナップショット（バイト一致）に関わる描画順をソートで作る場合、この非安定性ごと
  結果が決定的なので一致は保てる — ただし「安定だから大丈夫」という理屈は使えない

### try-catch での Java 例外

- import してから使う（`##java.io.IOException` ではなく `IOException`）

### Java interop

- Java の import をするときは、モジュールのトップレベルに書く必要がある
- import を書かずに `java.Math.abs()` のようには呼び出せない
