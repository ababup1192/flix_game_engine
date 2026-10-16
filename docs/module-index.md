# engine_world モジュール索引（分野の目次）

「やりたいこと」からモジュールを引く逆引きは、分野ごとのファイル `docs/modules/<分野>.md` にある。
**丸読みしない。まず 1 行で引く:**

```
make module Q=<語>    # 例: make module Q=スクロール / Q=ツールチップ / Q=ヒットストップ / Q=UiMenu
```

当たった行は `docs/modules/<分野>.md:<行番号>  やりたいこと → モジュール`（または `モジュール — 1 行紹介`）の形で出る。
当たりが無ければ別の言い方で引き直すか、下の目次で分野を選んでそのファイルだけ開く。
重ねる・手前に出す・知らせ・描き出しの確かめ方などのよく引く物は、先に AGENTS.md の「やりたいこと → 道具」の早見表。

| 分野のファイル | 何が載っているか |
|---|---|
| [base.md](modules/base.md) | App・ECS（EntityId / Query）・数の道具（Num / Hash01 / RandomUtil）・重い・fps が落ちるときの症状 → 手 |
| [render.md](modules/render.md) | 絵の下限（矩形だけの画面から脱する）・Render の修飾（切り抜き・傾き・拡縮・枠線・色替え）・ZStack と SortingLayer（重なり）・RawDraw・文字・Quad / Bezier・Transition・Pass |
| [light.md](modules/light.md) | 光と影（Light / LightDoc / Shadow / Mirror・glow・放射状の明かり）・Daylight（時刻の色・落ち影）・Color・ShaderDoc の面・グラデ |
| [sprite.md](modules/sprite.md) | ドット絵（PxSpriteDoc / PxSprite / PxShade / PxSpriteAtlas / PaletteExport）・コマ送り Anim・ピクセルスナップ |
| [fx.md](modules/fx.md) | 粒（Fx / FxDoc の語彙）・無限の撒き方 Scatter・揺れ Sway |
| [ui.md](modules/ui.md) | ui.json（UiDoc / UiSpec）・並べ方（UiLayout / Flex）・メニュー・スクロール・会話窓と文字送り・フォーカス巡り・ツールチップ・文字の折り返し |
| [time.md](modules/time.md) | 演出の時刻表 Timeline（拍・小節）・Tween / Curve・ヒットストップ TimeScale・長押し HoldPress・Clock / Lifetime / Calendar・Journey / SceneSeq（進行 4 抽象の分業） |
| [sound.md](modules/sound.md) | 効果音（App.withAudio）・鳴り続ける音（withSustained）・BGM・イントロのループ点・ミキサーとダッキング・書き出し・合成 |
| [map.md](modules/map.md) | マス目（Grid / GridSearch / Steering / GridRay）・タイル層（App.withTileLayers / TileScene）・DualGrid / Material / Terrain・PxTerrain・TileState |
| [camera.md](modules/camera.md) | CameraRig（ズーム・追従・画面揺れ）・見下ろしの前後 Depth・ViewProjection（4 通りの写し方）・疑似 3D（Persp / WallFaces / Painter）・Viewport |
| [input.md](modules/input.md) | 入力（InputEdge / InputMap / Replay）・当たり判定（Hit / HitDoc / Collision）・Physics2D |
| [data.md](modules/data.md) | Doc を足す順（Schema → Doc → DocJson → DocTable）・fail-open の読み込みと知らせ（Log）・セーブ・Worldline |
| [debug.md](modules/debug.md) | F8 のチケット Annotate・RemoteDebug・ActiveDocs・GameLogger・描き出し（HeadlessRender / SoftRaster / RenderManifest） |

各モジュールの詳しい説明は `engine_world/src/<名前>.flix` 冒頭の doc コメント。型と引数は `make api Q=<名前>`
（[api-digest.md](api-digest.md)）。エンジンの奥（`engine/src`）の索引は [engine-module-index.md](engine-module-index.md)。
新しい場所でヘッドレスの描き出しを組むときは [headless-render-recipe.md](headless-render-recipe.md) を写経する。

**初学者向け概念ノート**（黒箱に見えがちな再利用パーツを 1 画面で解説）:
- [dual-grid.md](dual-grid.md) — チップ絵なしでマップ地形を描く仕組み（DualGrid / Material / Terrain の分業と「角の 4 セル → 16 ケース」）。
- App のゲームループ（更新系システムで進める → view で描く の 2 役割と 1 周の順）は `engine_world/src/App.flix` 冒頭の doc。
- 座標 → [0,1) の決定的なばらつき（乱数を使わない理由 = スナップショット決定性）は `engine_world/src/Hash01.flix`。

**モジュールを足したら**、分野のファイルの「やりたいこと → モジュール」に 1 行と「モジュール 1 行紹介」に 1 行を足す
（`bin/fge check-api-index` が docs/module-index.md と docs/modules/*.md を合わせて見る）。新しい分野を作ったらこの目次にも 1 行。
