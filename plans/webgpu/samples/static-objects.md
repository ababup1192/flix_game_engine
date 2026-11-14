# 書き味の見本: 動かない物の宣言（決まり 10・9.1 の表「動かない物の宣言」）

- **見本は型検査を通していない**（Flix 0.78 の書き方に合わせて手で書いた。コンパイルも実行もしていない）。
- **（新）** = まだ無い名前。`Scene3d.staticGroup`・`withGroupTint`・`withGroupLightmapIntensity`・`withoutItems` は `plans/engine-static-group.md` の案の名前（まだ無い）。
  `visibilityRange` は `plans/engine-city-scale.md` の案の名前（まだ無い）。印の無い名前は今の API にある。
- 数字は `plans/webgpu/survey/F-city-baseline.md` の物だけ（1 棟ずつ置いた都市 12,557 個で 1 コマ 137 ms・うち約 96 ms が毎コマの計画）。候補ごとの数字はまだ無い（P9 の前に測る）。

お題 (A): 町の建物 12,000 棟（形は 1 棟ごとに違う・動かない）・歩く人 200 人・時間で色が変わる街灯 300 本。
お題 (B): 2D の RPG のマップ（タイルの地面・動かない木や家 500 個・歩くキャラ 20 人）。

**前提（3 つの候補の差はここから出る）**: このエンジンは毎コマ、場面を値（`Scene3dCmd`・`List[PlacedItem]`）として作り直して渡す。
Unity・Unreal・Godot は場面が前のコマから残っているので、「物にフラグを付ける」だけでエンジンが同じ物だと分かる。
このエンジンでは、**同じ物だと分かる手がかり（名前か鍵）をゲームが渡すか、エンジンが毎コマ比べるか**のどちらかになる。

## 比べの表

| 見る点 | 候補 1: 集まりとして宣言（`staticGroup`） | 候補 2: 物ごとのフラグ（`Mobility`） | 候補 3: エンジンが自分で見つける | 候補 4（2D）: 今の `withStaticLayer`・`withTileLayers` を広げる |
|---|---|---|---|---|
| 書く量 | 読み込みで 1 回作る + 毎コマ `groups` に載せる | 物を作る所に 1 語 | 0 | App に 1 行 + 作る関数 1 つ |
| 覚える事 | 「グループの中は変えられない・変える物は外して普通に置く」 | 「動かない物の列は World に持ち、毎コマ同じ値を渡す」（書かれない決まり） | 同左（書かれない決まりだけが残る） | 鍵（key）の決まり。今のタイル層と同じ |
| 動く物に付けた | 作った時の場所に止まったまま。すぐ目で分かる | 値が変わったコマに作り直しが走る。絵は正しいが遅い | 起きない | 作った時の場所に止まる |
| 途中で 1 棟だけ色を変える | `withoutItems` で外し、`instances` に置く（計画の問い 2） | そのまま値を変える。持ち越しの単位（下）ごとに作り直し | 同左 | 鍵を変えて層ごと作り直すか、その物を view の側へ移す |
| 壊して消す | `withoutItems(消えた鍵の Set)`。増えすぎたらグループを作り直す | 列から抜く。作り直し | 同左 | 同上 |
| 効かなくなる書き方 | 毎コマ `staticGroup` を呼ぶ（鍵が Lazy なので毎コマ中身を見比べる） | 毎コマ列を作り直す・`++` の左に大きな列を置く | 同左。**黙って遅くなる** | 鍵に毎コマ変わる値を混ぜる |
| 誤りの知らせ方 | 診断にグループの数・作り直しの回数。名前つきなので「town が毎コマ作り直されている」と言える | 「動かない物が N コマ続けて変わった」と言えるが、どの物かは名前が無いと言えない | 知らせる手がかりが無い | 今は無い（足せる） |
| `visibilityRange`（遠くを描かない） | グループの中は間引けない（render bundle の制約）。距離で替える物はグループを分ける（近い形・遠い形）か、区画ごとのグループにする | エンジンが区画に分ける事になる（分け方をエンジンが決める） | 同左 | 2D には無い（画面の外はタイル層がまとめて切る） |
| 影 | 同じグループを影の地図と奥行きの Pass に同じ準備で描く（描き先の形式ごとに bundle が要る） | 同左（集まりを作った後は同じ） | 同左だが、集まりがコマごとに揺れると影の側も作り直し | 2D には無い |
| 持ち越しの単位 | グループ（名前 + 中身の鍵）。行のバッファ・render bundle・境界・batch と描く順 | 場面ごとの「動かない物ぜんぶ」1 つ。1 個変わると全部 | 物 1 個か、決まった数の区切り | 層（鍵ごと）。今と同じ |
| 毎コマの計画で無くなる仕事 | 視錐台の判定（グループ単位になる）・材質ごとの分け・プログラムの引き当て・batch・描く順・行の上げ直し。**12,000 棟を 1 回も見ない** | 上と同じ物が無くなるが、**フラグで分けるために列を 1 巡する仕事は残る** | 上と同じ物が無くなるが、**前のコマと比べる仕事が 1 個ずつ残る** | view → `Drawable` の作り直しと z の並べ |
| エンジンに増える pub | `Scene3d` に型 1・関数 5 ほど、`Scene3dCmd` に欄 1 | `Scene3d` に enum 1・関数 1、`InstanceFields` に欄 1 | 0 | `App` に関数 1（今の物を広げる）、型 1 |

外では: Unity = Static フラグ（Static Batching）・Unreal = Mobility（Static / Stationary / Movable）・Godot = 場面に残る `MeshInstance3D`（動かさなければ送り直さない）と `MultiMesh`・
Bevy = change detection（`Changed<Transform>` の物だけ extract し直す）と `Static` の印。Dear ImGui のような毎コマ作り直す作りには「動かない」の宣言が無い。

## 候補 1: 集まりとして宣言（`Scene3d.staticGroup`）

```flix
// 読み込みの時に 1 回（Resources に持つ）。鍵 = 建物の id。
pub def townOf(doc: CityDoc.Rec): Scene3d.StaticGroup =                                              // 型の名前は（新）
    let items = doc#buildings |> List.map(b ->
        (b#id, Scene3d.meshInstance(b#mesh, Mat4.translate(b#position)) |> Scene3d.withMaterial(wallMaterial())));
    Scene3d.staticGroup("town", items)

pub def lampsOf(doc: CityDoc.Rec): Scene3d.StaticGroup =
    Scene3d.staticGroup("lamps", doc#lamps |> List.map(l -> (l#id, lampInstance(l))))

// 毎コマ。動く物だけ instances に置く。
pub def view(_ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
    let town  = res#town  |> Scene3d.withoutItems(w#destroyed)                    // 壊した建物の鍵の Set
                          |> Scene3d.withGroupTint(skyTintAt(w#clock));
    let lamps = res#lamps |> Scene3d.withGroupEmissionIntensity(lampLevelAt(w#clock));     // （新。計画では「emission の倍率」）
    let scene = { instances = w#walkers |> List.map(walkerInstance(res)),
                  groups = town :: lamps :: Nil,
                  directionalLight = Some(sunAt(w#clock))
                  | Scene3d.scene(cameraOf(w), viewSize()) };
    Render.scene3d(Vec2.zero(), scene) :: Nil
```

- 街灯は「形と場所は動かないが、光り方が変わる」物。グループごとの値（tint・emission の倍率）で替える。**1 本ずつ違う色にしたい時はグループを分ける**（早く点く通り・遅く点く通り）。
- 色を変えた 1 棟は `withoutItems` で外して `instances` に置く。ゲームは「外した鍵の Set」と「置き直した物」の 2 つを World に持つ事になる。
- 遠くを描かない: グループの中は間引けないので、**区画ごとのグループ**（`"town/12_7"`）に分けるのはゲームの側。区画の切り方を助ける関数（`Scene3d.staticGroupsByCell`（新））が要りそう。
- グループを作る所は読み込みの中なので、ゲームの World と Resources の分け方（Doc と描く元は Resources）にそのまま乗る。
- **計画にある人への 3 つの問い**（`plans/engine-static-group.md`。P9 の前に改めて伺う）:
  1. ゲームが「動かない」と明示する形（上の `staticGroup`）でよいか。明示しない案（同じ値を渡したら勝手に使い回す）は、ゲームが毎コマ値を作り直すと効かない。
  2. グループの中の 1 個を変える時は「グループから外して、普通の物として置く」でよいか。
  3. `engine-scene3d-cpu.md` の結果を見てから着手、でよいか。

## 候補 2: 物ごとのフラグ（`Mobility`）

```flix
// 読み込みの時に 1 回。置いた物に「動かない」を付ける。
pub def buildingsOf(doc: CityDoc.Rec): List[Scene3d.Instance3d] =
    doc#buildings |> List.map(b ->
        Scene3d.meshInstance(b#mesh, Mat4.translate(b#position))
            |> Scene3d.withMaterial(wallMaterial())
            |> Scene3d.withName(b#id)
            |> Scene3d.withMobility(Scene3d.Mobility.Static))                     // （新）Static / Movable（既定）

// 毎コマ。全部を同じ instances に置く。
pub def view(_ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
    let walkers = w#walkers |> List.map(walkerInstance(res));
    let lamps   = res#lamps |> List.map(Scene3d.withTint(lampColorAt(w#clock)));  // 色が変わるので Movable のまま
    // WhyNot: res#buildings を ++ の左に置かない — 左の列は毎コマ写し直され、エンジンから「前のコマと同じ列」に見えなくなる。
    let scene = { instances = walkers ++ lamps ++ res#buildings,
                  directionalLight = Some(sunAt(w#clock))
                  | Scene3d.scene(cameraOf(w), viewSize()) };
    Render.scene3d(Vec2.zero(), scene) :: Nil
```

- 読んだ時は一番分かりやすい（Unity・Unreal と同じ語）。ただしエンジンは毎コマ、12,000 個の列を 1 巡して Static の物を集め、「前のコマと同じ集まりか」を確かめる事になる。
  確かめる手は 2 つ: 中身の鍵を毎コマ計算する（重い）か、同じ列の値そのものかを見る（速いが、上の `++` の向きのような書かれない決まりが要る）。
- 色を変える・壊すは値を変えるだけで書けるが、持ち越しの単位が「動かない物ぜんぶ」なので、1 棟で 12,000 棟ぶんの作り直しが走る。細かくするにはエンジンが区画に分ける。
- 街灯のような「動かないが光り方が変わる」物は Unreal では Stationary。入れると enum が 3 つになり、何を持ち越すかの決まりが増える。見本では Movable にした（300 本は毎コマ計画を通る）。
- 壊した建物は列から抜く。`res#buildings` を World の側へ移す事になる（Resources は変えない物の置き場）。

## 候補 3: エンジンが自分で見つける

```flix
// 今の書き方そのまま。ゲームは何も足さない。
pub def view(_ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
    let walkers = w#walkers |> List.map(walkerInstance(res));
    let lamps   = res#lamps |> List.map(Scene3d.withTint(lampColorAt(w#clock)));
    let scene = { instances = walkers ++ lamps ++ res#buildings,                  // 建物の列は読み込みで作った値をそのまま渡す
                  directionalLight = Some(sunAt(w#clock))
                  | Scene3d.scene(cameraOf(w), viewSize()) };
    Render.scene3d(Vec2.zero(), scene) :: Nil

// 効かなくなる書き方（絵は同じ・黙って遅い）: 毎コマ Doc から置いた物を作り直す。
//     instances = walkers ++ (res#doc#buildings |> List.map(buildingInstance))
```

- 書く量は 0。ただし「効く書き方」と「効かない書き方」の差がコードに出ず、型でも止まらない。効いているかは診断の数を見るしかない。
- 比べ方は、同じ値そのものか（速い・上の決まりが要る）、中身を比べるか（record の欄を 1 個ずつ引く。今の計画で一番重い仕事と同じ種類）。どちらでも 1 個ずつ見る仕事は残る。
- Bevy の change detection は「component に書いた事」を ECS が印として持つので比べずに済む。このエンジンは値を渡すだけなので、同じ仕組みにはならない。
- `Scene3d.withName` の名前を手がかりにする案もあるが、「名前が同じなら中身も同じ」とは言えないので、結局中身を比べる。

## 候補 4（2D）: 今の `withStaticLayer`・`withTileLayers` を広げる

今の使われ方: rpg-starter は地面を `App.withTileLayers(Resources.read(View.tileLayers))`（鍵 = マップとアトラス。作り直しはマップを移った時だけ）、
木・家・人は毎コマ view で `Sheet.drawAnchored` の列。tidepool-starter は画面の縁の枠（多角形）を `App.withStaticLayer(鍵, View.frameBorder)`。
`withStaticLayer` は 1 つの App に 1 つ・多角形だけ・それ以外の item は黙って無視される。

```flix
// お題 (B)。地面は今のまま。木と家を「鍵つきの動かない層」へ出す（スプライトも受ける・層は何枚でも）。
pub def staticLayers(res: Res.Res, w: World.World): List[App.StaticLayerSpec] =                        // （新）
    World.shownFieldOf(w)
        |> Option.map(r -> { key = "${MapDoc.nameOf(r#map)}/props/${res#atlasKey}",
                             items = () -> FieldView.propItems(res, r#map) } :: Nil)       // 木・家 500 個。z は 1 個ずつ（足元の y）
        |> Option.getWithDefault(Nil)

App.game({ init = .., update = .., view = Resources.view(View.frame), reloads = Nil })     // view は歩くキャラ 20 人と開け閉めする物だけ
    |> App.withTileLayers(Resources.read(View.tileLayers))
    |> App.withStaticLayers(Resources.read(View.staticLayers))                             // （新）今の withStaticLayer を置き換える
```

- 形は今の `TileLayerSpec`（`key` と、鍵が変わった時だけ呼ばれる `tiles = Unit -> List`）と同じ。覚える事は増えない。CPU の描き手と F8 は `items()` をそのまま今の道へ流す（`TileScene.toItems` と同じ手）。
- **キャラが木の後ろを歩く**ので、層は z を 1 つにできない。中の物は 1 個ずつ z を持ち、エンジンが動く物の z の間へ差し込む（差し込んだ所で draw は切れる）。
- 開ける宝箱・消える物は層に入れない（今の `FieldScreen.thingPart` が状態で絵を変えている物）。層に入れた物を消すには鍵を変えて作り直す。
- 3D の候補 1 と同じ考え（鍵つきの集まり・中は変えない）なので、2D と 3D で覚える事がそろう。view の列に混ぜる形（`Render.staticItems(key, () -> items)`（新）の `Item`）にもできるが、
  今のタイル層が App の宣言なので、そろえるなら App の側。
- 500 個なら今の道でも代金は小さい（1 個 約 1.3 µs として 1 ms に届かない）。効くのは数千個のマップと、ブラウザ・スマホ。

2D に候補 2・3 を当てた時: フラグ（`Render.static(item)`（新））は、view が毎コマ `List[PlacedItem]` を作り直す以上、作る代金そのものが残るので得が薄い。自分で見つける形も同じ。

## 読んでいて見つけた今の API の引っかかり

1. `withStaticLayer` は多角形しか受けず、スプライトを入れても黙って消える（知らせが無い）。1 つの App に 1 つだけ。
2. `withPreload3d` も `StaticKey` を使うが、こちらは「先に上げる」だけで持ち越しではない。名前が近く、役目を取り違えやすい。
3. `Scene3dCmd#instances` が `List` なので、動く物と動かない物をつなぐ `++` の向きで毎コマの写し直しの量が変わる。
4. 建物 1 棟の `Instance3d` を作る所と、毎コマ場面を組む所の間に「読み込みで作って持っておく場所」の手本が無い（テンプレートに 3D の物が無い）。

## 私ならこれを推す

- **3D は候補 1（`staticGroup`）、2D は候補 4（タイル層と同じ形の `withStaticLayers`）。** どちらも「鍵つきの集まり・中は変えない・変える物は外へ出す」で、覚える事が 1 つにそろう。
- 理由: 毎コマ場面を値で作り直すこのエンジンでは、フラグと自動は「1 個ずつ見る仕事」が残り、効かない書き方が黙って遅くなる。
  集まりは 12,000 棟を 1 回も見ずに済み、名前があるので誤りを診断で言える。render bundle の制約（中を間引けない・描き先ごと）とも単位が合う。
- 候補 2 の `Mobility` は語としては一番通じるので、`staticGroup` の説明に「Unity の Static・Unreal の Mobility = Static に当たる」と書いて引けるようにする。
- 測って確かめたい事:
  1. `bench/scene3d` で動く物の割合を 0・1・10・50% に振った時の、候補 1 と「今のまま内側だけ速くした物」の 1 コマ。
  2. 都市 12,000 棟を区画ごとのグループに分けた時の、区画の数と 1 コマ（区画が細かいほど間引けるが draw が増える）。
  3. `withoutItems` の Set が大きくなった時（100・1,000 棟）の代金と、作り直しに掛かる時間（1 コマに収まるか）。
  4. 候補 3 の「同じ値そのものかを見る」だけを足した時にどこまで下がるか（ゲームを直さずに得られる分の上限として）。
  5. 2D: 木と家 500・5,000 個で、層にした時と今の道の差。z の間へ差し込んだ時の draw の数。
