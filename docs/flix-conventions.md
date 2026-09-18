# Flix を書くときの決まり

## 予約語を識別子に使わない

**全量は `bin/lint-rules/flix-reserved.json` が source of truth**（0.75.1 で実測した 43 語）。
よく踏むのは `from` / `into` / `run` / `spawn` / `region` / `project` / `solve` / `inject` /
`handler` / `query` / `select` / `where` / `force` / `discard`。

変数・関数名だけでなく**レコードのフィールド名**でも落ちる（`{ spawn = ... }` は不可）。
エラーは `Expected ',' before '='` のような間接的なパースエラーで出るので、原因に見えない。

**型検査が終わらないときも、まずこれを疑う。** Flix はパースで止まらず、壊れた構文木の
まま型検査へ進んで発散することがある — 赤も警告も出ず、ただ何分でも回り続ける
（2026-08-19 に `{ into = …, from = … }` で 6 時間溶かした）。
`bin/fge flix-reserved <ファイル…>`（全量は `--all`）が保存時とコミット時に自動で走る。
ゲームで踏みやすいのは `spawn`（湧き位置 → `start`）、`run`（走り → `walkR` 等)、
`project`（→ `apply`）、グラデーションの両端の `from` / `to`（→ `top` / `bottom`。
engine の `Render.vgrad` も同じ理由で `{ top, bottom }`）。

## コメントの流儀

- コードには **How**
- テストコードには **What**
- コミットログには **Why**
- コードコメントには **WhyNot**

How と What をコメントに書かない。実装の由来・旧実装・移行史も書かない。
独自の比喩を使わない（「局面」「店」ではなく、フェーズ・Map のような直接表現）。

**単語は業界の言葉をそのまま使う。** ゲーム業界・ソフトウェア業界で通じる語を優先し、
カタカナ（和製英語）か英語のまま書く（レイヤー・バージョン・ボタン・キャッシュ・
`Layer` `Version`）。和語へ言い換えず、造語も作らない。読み手はエンジニア。

**説明は平易に。** 難しい数学用語・専門用語に寄りかからず、何が起きるのかを普通の
言葉で書く（「線形補間する」ではなく「2 つの値の間をなめらかにつなぐ」）。

## 名前の付け方（モジュール・関数・変数）

**英語にすれば安全、ではない。** `bless` `carve` のように、英単語でも
このリポジトリだけの意味を持たせると、初めて読む人にも海外の人にも通じない。
上の言葉づかいの決まりは、そのまま識別子にも当てはまる。

### 1. 同じ物を指す言葉が業界にあるなら、それを使う

探す順番:

1. **ゲーム業界の語** — `sprite` `tilemap` `viewport` `hitbox` `atlas` `tween`
2. **ソフトウェア一般の語** — `cache` `buffer` `snapshot` `pipeline` `handler` `registry`
3. **他のゲームエンジンが同じ物をどう呼んでいるか** — Unity / Unreal / Godot / Bevy。
   同じ物に別の名前を付けない（このエンジンは Bevy の render-from-World の考え方に
   そろえているので、迷ったら Bevy の語を見る）

3 つとも当てはまらない物にだけ、説明的な名前を組み立てる（`silhouettePng` のように、
読んで何をする物か分かる形）。**比喩で名付けない。**

### 2. 動詞は大手の命名規則に合わせる

| 動詞 | 意味 |
|---|---|
| `get*` | 取り出すだけ（安い・失敗しない） |
| `load*` / `fetch*` | 外から取ってくる（遅い・失敗しうる） |
| `build*` / `make*` / `compute*` | 計算して作る |
| `is*` / `has*` / `can*` | Bool を返す |
| `set*` / `with*` | 値を差し替える（`with*` は元を変えず新しい値を返す） |
| `to*` / `as*` | 型を変える（`to*` は作り直す・`as*` は見方を変えるだけ） |

**1 つの動詞に 2 つの意味を持たせない。** `get` が実は読み込みに行く、のような名前は
呼ぶ側が値段を読み違える。

### 3. 迷ったときの決め方

その名前を英語で読んだ人に意味が通るか。通らないなら、業界の語をもう一度探す。

## 型の設計（データの持ち方）

- **取りうる値が決まっている物（状態・モード・種別）は String で持たない。enum にする。**
  文字列の等値で分岐すると網羅性チェックが効かない。Doc(JSON) から来る String は、
  読み込む所で 1 回だけ enum へ変換して内側は enum で回す
- **その case だけが使う値は、レコードに平らに並べず enum の payload へ入れる。**
  並べると、どのフィールドがどの case の物か型から読めなくなる。
  どの case でも使う値はレコード側に残す
  - payload にレコードは置けない（下の `Eq` の落とし穴）。値が 2 つ以上要るときは
    case へ並べるか、`Eq` を derive した別の enum で包む

詳しくと例は `.claude/skills/flix-docs/SKILL.md` の「型の設計」。

### World が直接持つ大きな record は enum で包む（型検査の速さ）

`pub type alias Doc = { ... }` のような record の型エイリアスは、使われるたびに中身の
まま展開される。`World` がそれを何個も持つと、`w: World` を取る全 def で型の木が巨大に
なり、`flix check` の Typer が行数と釣り合わずに伸びる（17k 行のゲームで Typer 22 秒
→ 包んで 9 秒。合成では 33 秒 → 3 秒）。名前付きの型（enum）で包むと展開が止まる。

- **対象**: `World` が直接フィールドに持つ大きな record — Doc（`*Doc.Doc`）、盤や
  戦いの場のような「状態のかたまり」。数値・文字列・小さな record（`Vec2` 程度）は対象外
- **形**: 中身は `Rec`、公開の型は 1 case の enum、読むのは `rec`

  ```flix
  mod PuzzleDoc {
      pub type alias Rec = { swapSeconds = Float64, ... }
      pub enum Doc(Rec)
      pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }
      pub def defaults(): Doc = Doc.Doc({ swapSeconds = 0.12, ... })
      pub def swapSecondsOf(d: Doc): Float64 = rec(d)#swapSeconds
  }
  ```

- **ロジックの内部は record のまま**。`{ x = v | s }` を連ねる規則の本体は `Rec` を
  受け渡し、World に戻す公開の入口（`start` / `step` など）だけで包み直す。1 行ごとに
  `rec()` を挟むと読めなくなる
- モジュール名と同じ enum（`mod Battle { pub enum Battle(...) }`）は companion 扱いで、
  **モジュールの先頭の宣言に置く**
- 包んだ enum に `Eq` は derive できない（payload が record）。比較したい値は
  `rec(a) == rec(b)` の形か、比較する部分だけを取り出して比べる
- モジュールの外から値を作るときは `PuzzleDoc.Doc.Doc({ ... })` と 2 段（enum 名 + case 名）。
  `PuzzleDoc.Doc({ ... })` は E2136 で止まる。テストの fixture でまず踏む
- 同じ関数で欄を何度も読むなら先頭で `let r = rec(doc)` を 1 回。`doc: Doc` を引数に取る
  private ヘルパが多いモジュール（View）は、ヘルパの引数を `Rec` にして呼び側で 1 回だけ
  剥がす方が差分が小さい
- 置き換え漏れは `fixture()#start` のような「Doc を返す関数の戻り値に直接 `#`」と、
  `{ x = v | defaults() }` のような「既定値の上書き」（`Doc.Doc({ x = v | rec(defaults()) })`）に
  集まる。E6794（`Doc` と record の unify）が出たらこの 2 つを疑う

## 二乗を書かない

N はゲームが決める。エンジンは N を知らない（今のテンプレが 9 要素だから軽い、は
エンジンの性質ではない）。次の 5 つは、実害が見えなくても書かない。

- **`List.foldLeft` の中で蓄積を `List.append` の第 1 引数に置かない。**
  `::` で先頭へ積んで、最後に `List.reverse`（手本は `Text.groupRows`）。
  名前が `acc` でなくても、タプルを分解した別名でも同じ
- **文字列も同じ。1 文字ずつ足して伸ばさない。** `foldLeft(String.concat, "")` も
  `"${acc}${ch}"` も、1 回ごとに全体を作り直すので文字数の二乗になる。
  `List[Char]` を `::` で積んで、最後に region + `StringBuilder` で 1 回だけ組む:
  ```flix
  region rc {
      let sb = StringBuilder.empty(rc);
      List.forEach(ch -> StringBuilder.append(ch, sb), chars);
      StringBuilder.toString(sb)
  }
  ```
- **ループの中で `List.exists` / `List.memberOf` を呼ばない。** 会員判定は `Set` / `Map`。
  順序も要るなら「順序つきの蓄積 + 判定用の `Set`」の二本立て
- **`List.range` を回して `List.nth` で引かない。** 1 巡で済ませる
  （`List.zip` は短い方で打ち切るので、余った側の後始末が要るなら先に長さをそろえる）
- **`List.sortBy` のキーに重い関数を渡さない。** `sortBy` は
  `sortWith(Order.compare `on` f)` なので、**1 回の比較でキー関数を 2 回呼ぶ**。
  先に `(キー, 要素)` を作って `sortBy(fst)` で並べ、最後に戻す。
  キー列が同じなら並びはビット同一になるので、この置き換えで絵は変わらない

機械で裁く lint は無い。基準・測り方・残っている二乗の一覧は engine リポの
`docs/performance.md`。

## その他の落とし穴

- レコードは `Eq` / `Order` を持てない。比較したい値は名前付き 1 フィールドの enum で包む
- `forM` は効果の逐次実行には使えない
- 小数は Float64 で書く（`1.0` は Float64。Float32 のリテラルには `f32` サフィックスが要る）。
  engine の pub 面に Float32 は出さない決まりで、Float32 は GL / OpenAL / STB を呼ぶ
  境界の内側だけ（engine のリポジトリでは `make lint-f32` が検査する）

## 迷ったら引く

- 構文・パイプスタイル・エフェクト・テストの書き方: `.claude/skills/flix-docs/SKILL.md`
- コンパイルエラーが出た: `.claude/skills/compile-fix/SKILL.md`
- テストを設計する: `.claude/skills/quality-assurance/SKILL.md`
