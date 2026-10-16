# Flix の書き方 — 例と細かい所

`SKILL.md` の表から、困った節だけ引く。決まりそのものは `SKILL.md` と `.claude/rules/flix.md` が正。

## 引数をレコードで束ねる

https://doc.flix.dev/records.html の named-parameters。

```flix
// NG: Float64 が続く / 4 引数で取り違えやすい
def makeLine(pos: Vec2.Vec2, width: Float64, height: Float64, color: Color): ColorRect

// OK: size を Vec2 にしてレコードで束ねる
def makeLine(line: {pos = Vec2.Vec2, size = Vec2.Vec2}, color: Color): ColorRect
```

一緒に使われ続ける組は type alias にして使い回す
（例: `(rootJsonIndex, scene)` → `EditableNode.LookupCtx`、`(mousePos, mouseLeft)` → `DragInput.MouseSnapshot`）。

```flix
// NG: 同じ形を関数ごとに書く（フィールドを足すとき直し漏れる）
def hitTest(input: {pos = Vec2, button = MouseButton}, scene: Scene): ...
def startDrag(input: {pos = Vec2, button = MouseButton}, scene: Scene): ...

// OK: 1 か所で type alias
type alias MouseSnapshot = {pos = Vec2, button = MouseButton}
def hitTest(input: MouseSnapshot, scene: Scene): ...
def startDrag(input: MouseSnapshot, scene: Scene): ...
```

## 型の設計の例

決まりは `.claude/rules/flix.md` の「型の設計」。その case だけが使う値は payload へ、どの case でも使う値はレコードへ。

```flix
pub enum Playback with Eq, ToString {
    case Stopped
    case Playing(Float64)  // 再生した秒数
    case Paused(Float64)   // 止めた時点の秒数
}
pub type alias Clip = { playback = Playback, name = String, volume = Float64 }
```

## エフェクトとハンドラ

```flix
// NG: その場で run して IO に変える
def getTimestamp(): Int64 \ IO =
    run Clock.currentTime(TimeUnit.Milliseconds) with Clock.runWithIO

// OK: エフェクトを伝播させる（run は呼び出し元に任せる）
def getTimestamp(): Int64 \ Clock =
    Clock.currentTime(TimeUnit.Milliseconds)
```

```flix
// 1. 何も書かない（main と @Test は DefaultHandler が入る）
def main(): Unit \ {Clock, Logger} =
    let ts = Clock.currentTime(TimeUnit.Milliseconds);
    Logger.info("Timestamp: ${ts}")

// 2. ライブラリのハンドラを with で
def example(): Unit \ IO =
    run someEffectfulWork() with Clock.runWithIO

// 3. 手書き（最後の手）
def example2(): Unit \ IO =
    run someEffectfulWork() with handler Clock {
        def currentTime(u, k) = k(0i64)
    }
```

`run` は入れ子にせず連ねる:

```flix
run {
    f()
} with handler X { ... }
  with handler Y { ... }
```

参考: https://doc.flix.dev/default-handlers.html

## 標準ライブラリの対応表

| やりたいこと | 使う物（Java の代わり） |
|---|---|
| ファイルを読む・書く | `Fs.readFile` `Fs.writeFile` `Fs.readLines` `Fs.writeLines` `Fs.appendFile` `Fs.appendLines` |
| ファイルの有無・大きさ・消す・写す・動かす | `Fs.fileExists` `Fs.fileSize` `Fs.deleteFile` `Fs.copyFile` `Fs.moveFile` |
| バッファ読み | `BufReader.withDefaultCapacity(rc, reader)` → `read` `peek` `readWhile` `skip` |
| 乱数・並べ替え | `Math.Random` `Math.Shuffle`（足りなければ RandomUtil を広げる） |
| 文字列 → 数 | `Int32.fromString` → `Option[Int32]`・`Float64.fromString` |
| 数の拡大 | `Int32.toInt64` `Int32.toFloat64` `Float32.toFloat64` |
| 数の縮小（安全） | `Int32.tryToInt8` `Int32.tryToInt16` → `Option`（`truncateTo*` は精度を捨てる時だけ） |

## Channel と Java interop

- Java の atomic 変数を使いたくなったら Channel を見る。`Channel.buffered(size)` は Region を取らずサイズだけ。
  戻り値は `(Sender[t], Receiver[t])`、エフェクトは `Chan` と `NonDet`
  （https://doc.flix.dev/concurrency.html の communicating-with-channels）
- Java の import はモジュールの直下（関数の外）に書く。import せずに `java.Math.abs()` のようには呼べない
- try-catch の例外は import してから名前で使う（`##java.io.IOException` ではなく `IOException`）

## List.sortBy が安定でない例

実測: 同じキーの 7::8::9 が 9::7::8 になる。描き出しの並びをソートで作っても結果は決まっているので
スナップショットは一致するが、「安定だから大丈夫」という理屈は使えない。
