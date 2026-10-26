---
name: flix-docs
description: "このプロジェクトの Flix の書き方（パイプ・エフェクトの伝播とハンドラ・標準ライブラリ優先・Channel / Java interop の落とし穴）。Flix コードを書く前・直す前、構文や API の書き方に迷ったときに使う。"
sync: 2026-10-26
---

# Flix の書き方

予約語・`let _ =`・型の設計（enum と payload・大きな record を包む）・二乗の禁止は `.claude/rules/flix.md`
（`.flix` を触ると自動で読まれる。本文は engine リポの `docs/flix-conventions.md`）。名前の付け方は AGENTS.md。
ここに無い構文・標準ライブラリは https://doc.flix.dev/ の該当ページ（API は https://api.flix.dev/ ）を引く —
`for-llms.html` は大きいので丸ごと取らない。コンパイルエラーは `compile-fix` スキル、テストは `quality-assurance` スキル。

**例と細かい所は同じフォルダの `reference.md`。** 困ったらその節だけ引く:

| 困った時 | `reference.md` の節 |
|---|---|
| 引数をレコードにする形・type alias の共有 | 「引数をレコードで束ねる」 |
| enum の payload とレコードの分け方の例 | 「型の設計の例」 |
| ハンドラの選び方の例・`run` に `with` を連ねる形 | 「エフェクトとハンドラ」 |
| Java の API を使いたくなった（ファイル・数の変換・乱数） | 「標準ライブラリの対応表」 |
| Channel・Java の import・try-catch の例外 | 「Channel と Java interop」 |

## 書く前に読む・探す（`bin/fge refactor`）

字で探して丸ごと読むと、要らない所まで文脈に入り、肝心の宣言を読み違える。コンパイラの索引で引く。

| したいこと | 口 | 字で探すと困ること |
|---|---|---|
| 関数・型の doc コメントと本文だけを読む | `show <Mod.f>` | 2000 行のファイルを丸ごと読むと長く、本文の終わりも字では分からない |
| 名前の一部から宣言を探す | `search <名前の一部>` | `grep def` は使う所・コメントも拾い、`use` 越しの素の名前を落とす |
| ファイルの形をつかむ | `outline <ファイル>` | 頭から読んでいくと、要る宣言に着くまでに文脈を使い切る |
| 直す前に本文・呼び手・呼ぶ先・型を見る | `context <Mod.f>`（呼ぶ先の木は `trace`） | 呼び手と型を 1 つずつ探し直すたびに往復が増え、直し漏れが出る |
| 名前の使われ所を探す | `usages <名前>` | 同じ名前の別物を拾う |

## 名前と引数

- 変数名は省略しない。型があるならまず型名にそろえる（`p` → `player`、`scn` → `scene`）
- 関数には doc コメント（何をするか・意図）。record の type alias・enum・struct は全体と各フィールドにコメント
- **同じ型・似た型の引数が続く**（`Float64, Float64`）か、**4 つ以上で意味が混ざる**なら、
  named-parameters のレコードにする（取り違えを型で止める）。`Vec2` で束ねられる物は束ねる
- 同じ形のレコードを 2 つ以上の関数で使うなら、シグネチャに書き並べず `type alias` を 1 か所に置く

## パイプと高階関数

- `|>` でつなぎ、一時変数を作らない。インラインで書けるならインライン
- パイプで使いやすいよう、レシーバ（主に操作される値）を**最後の引数**にする
- match を入れ子にせず高階関数で書く。`map` → `flatMap` が続いたら `forM`、`map` → `filter` なら `filterMap` を探す

## エフェクト

- **その場で `run` せず、呼び出し元へ伝播させる。** その場で IO に変えると、シグネチャが `IO` だらけになり
  何の副作用かが型から読めなくなる（`Int64 \ IO` ではなく `Int64 \ Clock`）
- ハンドラは次の順で選ぶ:
  1. 何も書かない — `main` と `@Test` ではコンパイラが `@DefaultHandler` を入れる。シグネチャにエフェクトを書くだけ
  2. ライブラリのハンドラを `with` で（`run f() with Clock.runWithIO`）
  3. `with handler` の手書き — 振る舞いを変えたい時の最後の手
- `run` を入れ子にしない。いくつも剥がすなら 1 つの `run { } with X with Y` に連ねる

## 0.77〜0.78 の新しい書き方

- engine の名前は mod ごとに `use fge::{App, Color}` で取り込む（mount 名 fge は
  flix.toml の依存の `mount = "fge"`。ファイル直下の use は `mod X { }` へ届かない）
- use を足すのは `bin/fge engine-uses`（mount 名は flix.toml から読む。`--check` で検査）
- 音の名前は型で鳴らす: 一発の音は `Sfx.play(Shot.X)`（`\ Sfx[Shot]`）、鳴り続ける
  音は `Loop.hold(Hum.X, mix)`（`\ Loop[Hum]`）。Shot と Hum は別の enum にする
- App へは `Sfx.collect(shotName, ..)` / `Loop.collect(humName, ..)` で名前の列にして渡す
- 多相 effect（実験）: `eff E[t] { .. }`・ハンドラの型は `a \ (ef - E[t])`
- 1 つの関数の中で同じ effect は 1 つの型だけ（`Sfx[A] + Sfx[B]` は E6795）
- 型変数を effect にはできない（`ef[t]` は E3442）
- 型引数に trait の制約を付けたハンドラ（`with ToString[s]`）は 0.78.0 で
  コンパイラが落ちる。使わずに、名前へ写す関数（`shotName`）を引数で渡す
- 外から作らせない値: pub mod の中の非 pub の enum + `pub type alias` で名前だけ出す
  （外で case を書くと E0459・同名の enum は pub が要る E5848）。新しく作る型と、
  直すついでの所から使う（一度に全部は替えない）

## Java より標準ライブラリ

Java の API を呼ぶ前に、Flix の標準ライブラリに同じ物が無いか https://api.flix.dev/ で確かめる。
よく要る物: ファイルは `Fs`、バッファ読みは `BufReader`、乱数は `Math.Random` / `Math.Shuffle`、
数と文字列の変換は `Int32.fromString`・`Int32.toInt64`・`Int32.tryToInt8` など各型のモジュール（`truncateTo*` は精度を捨てる時だけ）。

## 型が教えてくれない落とし穴

- **`List.sortBy` / `List.sort` は安定ソートではない。** 同じキーの要素は入力の順に残らない
  （同じ入力なら結果は毎回同じ）。同じキーの順に意味があるなら、`List.zipWithIndex` で元の位置を
  キーに足して並べる
- Channel・Java の import・例外の型はコンパイラが止める。直し方は `compile-fix`（例は `reference.md`）
