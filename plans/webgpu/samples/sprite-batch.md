# 書き味の見本: 大量のスプライトを渡す口（決まり 11・9.1 の表「スプライトの集まりの口」）

- **見本は型検査を通していない**（Flix 0.78 の書き方に合わせて手で書いた。コンパイルも実行もしていない）。
- **（新）** = まだ無い名前。印の無い名前は今の API（`docs/api-digest/`）にある。
- 数字は `plans/webgpu/survey/G-2d-baseline.md` の物だけ（同じ絵 20,000 個で 1 コマ 32 ms・うち約 25 ms が
  「view → `PlacedItem` → `Drawable` → camera と z の並べ」・1 個 約 1.3 µs）。候補ごとの数字はまだ無い（P1 の後に測る）。

お題 (A): 見下ろしの画面。敵 2,000 体（絵 3 種類・向きで左右反転・被弾で 0.1 秒白く光る）・弾 500 発・経験値の粒 1,000 個。手前（y が大きい）の物が上。
お題 (B): `bench/crowd2d` の今の View（`CrowdBench.view`。位置は `Vector[Float64]` の `xs`・`ys`）。

## 比べの表

| 見る点 | 候補 1: 今のまま | 候補 2: 列（配列）を渡す | 候補 3: 集まりの `Item` を 1 つ足す | 候補 4: component の store から引く |
|---|---|---|---|---|
| ゲームが覚える事 | 無し | 新しい型 2 つ（見た目・列）と「欄ごとに同じ長さの Vector」の決まり | 新しい関数 1 つと小さな record 1 つ | 候補 3 + `Query` の store の形 |
| World の持ち方 | 何でも良い | 列で持っていると 1 行。record の列だと欄の数だけ作り直す | 何でも良い（`map` 1 回） | `Map[EntityId, x]` で持っている時だけ |
| `Render.at`・`clipped`・`fade`・`tintedAll` と混ぜる | 今どおり全部 | 集まり全体に掛かる（1 個ずつには掛からない） | 同左 | 同左 |
| 1 個ごとの反転・回転・色 | `spriteFlipped`・`turned`・`tinted` | 列を足す（無い列は既定） | record の欄 | record の欄 |
| z（手前が上） | 1 個ずつ `zIndex` に y を入れる | 集まりは z 1 つ。中の順は `order`（新）で y 順か、並べた順 | 同左 | 同左 |
| 白く光らせる | 口が無い（下の「引っかかり」） | `flash` の列（新） | `flash` の欄（新） | 同左 |
| SoftRaster | 今のまま | 集まりを `Drawable` の列へ開く関数を 1 つ（`TileScene.toItems` と同じ手） | 同左 | 同左 |
| F8 の注釈 | 今のまま（1 個 = 1 `Hit`） | 開いた列で当てる。名前は「絵の名前 + 番号」 | 同左 | 名前に `EntityId` を出せる |
| エンジンに増える pub | 0 | `Render` に型 3・関数 3〜4、`DrawCmd` に型 1 | `Render.Item` に case 1・型 2・関数 2、`DrawCmd` に型 1 | 候補 3 + 関数 1 |
| effect | 変えない | `Draw2d` に op を 1 つ足すか `renderCommands` に引数を 1 つ足す。handler 全部（偽物・Studio・ブラウザ）に波及 | 同左 | 同左 |
| 1 個あたりで無くなる仕事 | 内側の欄の引き当てだけ（決まり 9） | 値を作る事そのもの（ゲームの側も 0） | `Item.Sprite`（12 欄）と `Drawable`（20 欄）・1 個ずつの camera と z の並べ | 候補 3 と同じ |
| 既存のゲーム | 直さずに速くなる | 書き換えた所だけ | 書き換えた所だけ | 書き換えた所だけ |

## 候補 1: 今の書き方のまま（エンジンの内側だけ速くする）

```flix
// (B) bench/crowd2d の今の View そのまま
pub def view(w: World): List[Render.PlacedItem] =
    let xs = w#crowd#xs;
    let ys = w#crowd#ys;
    List.range(0, Vector.length(xs))
        |> List.map(i -> { at = { x = Vector.get(i, xs), y = Vector.get(i, ys) }, item = Render.sprite("enemy", 10) })

// (A)
pub def view(_ctx: App.ViewCtx, w: World): List[Render.PlacedItem] =
    let bullets = w#bullets |> List.map(b -> Render.sprite("bullet", zOf(b#pos)) |> Render.turned(b#angle) |> Render.at(b#pos));
    let gems    = w#gems    |> List.map(g -> Render.sprite("gem", zOf(g#pos)) |> Render.at(g#pos));
    List.flatMap(enemyItems, w#enemies) ++ bullets ++ gems

def enemyItems(e: Enemy): List[Render.PlacedItem] =
    let body = Render.spriteFlipped(textureOf(e#kind), zOf(e#pos), { flipH = e#vx < 0.0, flipV = false });
    // tinted は掛け算なので白くできない。同じ絵を Add で重ねて明るくする（真っ白にはならない）。
    let flash = if (e#hitTimer > 0.0) Render.at(e#pos, Render.blended(DrawCmd.BlendMode.Add, body)) :: Nil else Nil;
    Render.at(e#pos, body) :: flash

def zOf(pos: Vec2.Vec2): Int32 = actorsZ() + (Float64.floor(pos#y) |> Float64.tryToInt32 |> Option.getWithDefault(0))
```

- 覚える事は増えない。今ある `Render` の関数が全部そのまま使える。
- z は 1 個ずつ `zIndex` に y を入れる（y の幅だけ z の範囲を使う。`docs/z-bands.md` の仕切りと当たらない幅にする）。
- 無くなる仕事は内側だけ: `Render.drawWith` と描き手の中で record の欄を引く回数・`List` の作り直し（決まり 9）。
  ゲームが `Item.Sprite` を 1 個ずつ作る代金と、エンジンがそれを `Drawable` に写す代金は残る。
- 被弾の光は draw を切る（Add は Normal と pipeline が別）。光っている敵が画面中に散ると run が細かく割れる。
- 外では: Unity の SpriteRenderer（1 個ずつ置き、dynamic batching がまとめる）・Bevy（`Sprite` を 1 個ずつ spawn、batch は自動）がこの形。
  どちらも「物は前のコマから残っている」ので、毎コマ値を作り直すこのエンジンより 1 個あたりが安い。

## 候補 2: 列（配列）を渡す新しい口

```flix
// (B) World が列で持っているので 1 行。ゲームの側の 1 個ごとの仕事は 0。
pub def view(w: World): List[Render.PlacedItem] =
    let look = { texture = "enemy", zIndex = 10 | Render.spriteBatchLook() };                        // （新）
    Render.spriteBatch(look, Render.spriteColumns(w#crowd#xs, w#crowd#ys)) |> Render.at(Vec2.zero()) :: Nil   // （新）

// (A) World が record の列（List[Enemy]）だと、欄の数だけ列を作る。
pub def view(_ctx: App.ViewCtx, w: World): List[Render.PlacedItem] =
    let look = { texture = "actors", frames = w#atlasFrames, zIndex = actorsZ(),
                 order = Render.SpriteOrder.ByY | Render.spriteBatchLook() };                        // （新）ByY = 中を y の小さい順に描く
    let es = List.toVector(w#enemies);
    let enemies = { frame = Some(Vector.map(e -> frameOf(e#kind), es)),
                    flipH = Some(Vector.map(e -> e#vx < 0.0, es)),
                    flash = Some(Vector.map(e -> flashOf(e#hitTimer), es))                           // 0 = 元の絵・1 = 真っ白
                    | Render.spriteColumns(Vector.map(e -> e#pos#x, es), Vector.map(e -> e#pos#y, es)) };
    let bs = List.toVector(w#bullets);
    let bullets = { frame = Some(Vector.repeat(Vector.length(bs), bulletFrame())),
                    rotation = Some(Vector.map(b -> b#angle, bs))
                    | Render.spriteColumns(Vector.map(b -> b#pos#x, bs), Vector.map(b -> b#pos#y, bs)) };
    let gems = gemColumns(w#gems);
    Render.spriteBatch(look, Render.appendColumns(enemies :: bullets :: gems :: Nil)) |> Render.at(Vec2.zero()) :: Nil
```

`SpriteColumns`（新）= `{ xs, ys: Vector[Float64], frame: Option[Vector[Int32]], rotation・scale・alpha・flash: Option[Vector[Float64]], flipH: Option[Vector[Bool]], tint: Option[Vector[Color]] }`。
`None` の列は既定の値（等倍・回さない・白）。

- 列で World を持つゲーム（crowd2d・`SpatialGrid` を使う群れ）には一番短い。record の列で持つゲームには一番長く、列を作る `map` が欄の数だけ回る。
- 欄ごとの長さがずれる誤りは型で止まらない。作る時に長さを見て、合わなければ短い方に合わせて `Log.warnThen` で 1 行言う（`docs/error-handling.md`）。
- 手前が上は `order = ByY`。**種類の違う物（敵・弾・粒）を y で混ぜたければ、同じアトラスの 1 つの集まりに入れる**（集まりどうしは z でしか並ばない）。
- `Float32` の 1 本の配列（1 個 = 決まった数の Float32 を並べた行）で受ける形は、ゲームが行の並びを覚える事になるので見本にしていない。
  速さが足りない時にエンジンの内側の形として使う（ゲームには `Float64` の列を見せる。写す代金は測る）。
- 外では: Godot の `MultiMesh`（`instance_count` と `buffer: PackedFloat32Array` を直に渡す・`MultiMeshInstance2D` に載せる）・
  Unity の `Graphics.RenderMeshInstanced`（行列の配列を渡す）・Entities Graphics（列で持つ component から直に）。行の並びを覚えさせるのは Godot だけ。

## 候補 3: 集まりを表す `Render.Item` を 1 つ足す

```flix
// (B)
pub def view(w: World): List[Render.PlacedItem] =
    let (xs, ys) = (w#crowd#xs, w#crowd#ys);
    let enemies = Vector.range(0, Vector.length(xs))
        |> Vector.map(i -> Render.spriteInstance({ x = Vector.get(i, xs), y = Vector.get(i, ys) }));  // （新）
    Render.sprites({ texture = "enemy", zIndex = 10 | Render.spriteBatchLook() }, enemies) |> Render.at(Vec2.zero()) :: Nil  // （新）

// (A)
pub def view(_ctx: App.ViewCtx, w: World): List[Render.PlacedItem] =
    let look = { texture = "actors", frames = w#atlasFrames, zIndex = actorsZ(),
                 order = Render.SpriteOrder.ByY | Render.spriteBatchLook() };
    let enemies = w#enemies |> List.map(e ->
        { frame = frameOf(e#kind), flipH = e#vx < 0.0, flash = flashOf(e#hitTimer) | Render.spriteInstance(e#pos) });
    let bullets = w#bullets |> List.map(b -> { frame = bulletFrame(), rotation = b#angle | Render.spriteInstance(b#pos) });
    let gems    = w#gems    |> List.map(g -> { frame = gemFrame() | Render.spriteInstance(g#pos) });
    let actors  = Render.sprites(look, List.toVector(enemies ++ bullets ++ gems));
    // 集まりは Item なので、今の関数とそのまま混ざる（ここでは遊びの枠で切り抜いて、HUD の列とつなぐ）。
    Render.at(Vec2.zero(), Render.clipped(playRect(), actors)) :: hudItems(w)
```

`SpriteInstance`（新）= `{ at: Vec2, frame: Int32, rotation: Float64, scale: Float64, flipH: Bool, tint: Color, alpha: Float64, flash: Float64 }`。
`Item` に足す case は `Sprites({ look = SpriteBatchLook, instances = Vector[SpriteInstance] })`（新）。

- 覚える事は「同じアトラス・同じ blend の物は `Render.sprites` にまとめる」の 1 つ。候補 1 の書き方から `Render.sprite(..) |> Render.at(pos)` を record に替えるだけで移れる。
- `fade`・`tinted`・`clipped`・`scaled`・`movedAll` は集まり全体に効かせる（`Item` を受ける関数の `match` に case を 1 つ足す。数は digest で 15 ほど）。
  `turned`（自分の軸で回す）と `masked` は集まりには効かせず、作る時に 1 行言う。
- 1 個の値は残る（8 欄の record 1 つ）。無くなるのは `PlacedItem` + `Item.Sprite`（12 欄）→ `Drawable`（20 欄）の作り直し・1 個ずつの camera の掛け算・1 個ずつの z の並べ
  （集まりは z の列の 1 点に入る。`Item.Scene3d` と同じ扱い）。
- F8 は集まりを開いて 1 個ずつ `Hit` にする（`kind = "sprite"`・名前は絵の名前と番号）。SoftRaster も同じ「開く関数」を通るので絵の正は 1 つ。
- 外では: LÖVE の `SpriteBatch`（`newSpriteBatch(image)` に `add(quad, x, y, r, sx, sy)` して `love.graphics.draw(batch)` 1 回。集まりが 1 つの描く物）・
  MonoGame / XNA の `SpriteBatch.Begin(sortMode, blendState)` 〜 `Draw(texture, pos, sourceRect, color, rotation, …)` 〜 `End()`
  （`Begin` の引数が上の `look`、`Draw` の引数が `SpriteInstance`、`SpriteSortMode.BackToFront` が `order`）・Godot の `CanvasItem.draw_multimesh`。

## 候補 4: component の store（`Query`）から直に引く

```flix
// (A) 位置と見た目を Map[EntityId, x] の store で持つゲーム向け。中身は候補 3 と同じ Item になる。
pub def view(_ctx: App.ViewCtx, w: World): List[Render.PlacedItem] =
    let look = { texture = "actors", frames = w#atlasFrames, zIndex = actorsZ(),
                 order = Render.SpriteOrder.ByY | Render.spriteBatchLook() };
    Render.spritesFrom(look, w#positions, w#looks, (_id, pos, l) ->                                    // （新）
        { frame = l#frame, flipH = l#facingLeft, flash = flashOf(l#hitTimer) | Render.spriteInstance(pos) })
        |> Render.at(Vec2.zero()) :: hudItems(w)
```

- `Query.with2List` と `Render.sprites` を 1 つにつないだ近道。間の `List` を作らず、F8 の名前に `EntityId` を出せる。
- 今の `Query` は `Map[EntityId, x]` を引く作りで、列（`Vector`）で持つ store ではない。`Map` を回す代金が 1 個ごとに乗るので、候補 3 より速くはならない見込み。
- 今のテンプレートに store で持つゲームは無い（rpg-starter・tidepool-starter・game-starter とも record の列）。足すなら候補 3 が入った後に、使うゲームが出てから。
- 外では: Bevy（`Query<(&Transform, &Sprite)>` を extract の段が自分で回す）・Unity の Entities Graphics。どちらも列で持つ ECS が前提。

## エンジンの側（候補 2・3・4 に共通）

- `DrawCmd` に集まりの値（新。仮に `SpriteBatchCmd`）を 1 つ。`Platform.Draw2d` は、op を 1 つ足す（`drawSurface`・`drawScene3d` と同じ「次の `renderCommands` の列へ積む」形）か、
  `renderCommands` に引数を足す。**op を足す方が今ある handler の書き換えが少ない**（引数を足すと全部の呼び手と handler が変わる）。
- 描き手は集まりを 1 つの run として受け、行のバッファへ続けて書く（決まり 5・6 の形にそのまま乗る）。z の並べの中では 1 点。
- `gl-parity` は「集まりで描いた場面」と「同じ物を `Render.sprite` で 1 個ずつ置いた場面」の対で比べる（static group の決まりと同じ考え）。
- `flash`（白く光る）はスプライトのシェーダーに 1 つ値を足す話で、口の形とは別に決められる。足すなら今の `Item.Sprite` にも同じ欄を足して `Render.flashed`（新）で付ける。

## 読んでいて見つけた今の API の引っかかり

1. **白く光らせる口が無い。** `tinted` は掛け算で、白 = 元の絵。Add で重ねる回り道は真っ白にならず、draw も切れる。
2. **y で並べる近道が無い。** z は `Int32` を 1 個ずつ自分で決める。見下ろしのゲームは全部 `zOf(pos)` を自前で書く事になる。
3. **`Render.rotated`・`Render.flipH` は頂点の列を受ける関数**で、`Item` を回すのは `turned`・反転は `spriteFlipped`。名前から引くと取り違える。
4. アトラスのコマを番号で指す口が無い（`regionRect = Option[Rect2]` を 1 個ずつ持つ）。集まりの口では `frames: Vector[Rect2]` と番号に分けた。

## 私ならこれを推す

- **候補 1 を先に入れ（決まり 9。全部のゲームに効く）、口は候補 3 の形で足す。** 理由: `Item` として今の関数と混ざり、候補 1 の書き方から 1 行の書き換えで移れ、
  SoftRaster と F8 が「開く関数」1 つで済む。LÖVE・MonoGame の `SpriteBatch` と同じ形で、初めての人にも通じる。
- 候補 2 は別の口にせず、**候補 3 の `Item` の作り方をもう 1 つ**（`Render.spritesFromColumns`（新）: 列から同じ `Item` を作る）として、測って要ると分かった時に足す。
- 候補 4 は見送る（列で持つ store が無い間は得が無い）。
- 測って確かめたい事:
  1. `crowd2d` 20,000 体で、候補 1（内側だけ）・候補 3（record の `Vector`）・候補 2（列）の 1 コマ。候補 3 と 2 の差が小さければ候補 2 は足さない。
  2. `order = ByY` の並べの代金（2,000〜20,000 個）。ゲームが並べて渡す形とどちらが安いか。
  3. `Float64` の列を行のバッファ（Float32）へ写す代金。ブラウザ（WASM）でも同じ比になるか。
  4. お題 (A) で、光っている敵が散った時の draw の数（`flash` を値にした時と、Add で重ねた時）。
