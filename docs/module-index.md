# engine_world モジュール索引

「やりたいこと」からモジュールを引くための逆引きと、全モジュールの 1 行紹介。
各モジュールの詳しい説明は `engine_world/src/<名前>.flix` 冒頭の doc コメントにある。
これは `engine_world`（ゲームが直接触る土台）の索引。エンジンの奥（`engine/src`）の索引は
[engine-module-index.md](engine-module-index.md) を参照。

**API の型・引数を調べるとき**は、ソースを grep する前にまず [api-digest.md](api-digest.md)
（全 pub 宣言の自動生成一覧）を引く。ソースの丸読みより桁違いに安い。
**新しい場所でヘッドレスの描き出しを組むとき**は [headless-render-recipe.md](headless-render-recipe.md) を写経する。

**初学者向け概念ノート**（黒箱に見えがちな再利用パーツを1画面で解説）:
- `docs/dual-grid.md` — チップ絵なしでマップ地形を描く仕組み（DualGrid / Material / Terrain の分業と「角の4セル→16ケース」）。
- App のゲームループ（更新系システムで進める → view で描く の2役割と1周の順）は `engine_world/src/App.flix` 冒頭の doc を参照。
- 座標→[0,1) の決定的なばらつき（乱数を使わない理由 = スナップショット決定性）は `engine_world/src/Hash01.flix` を参照。

## 矩形だけの画面から脱する（絵の下限）

`RawDraw.box` を並べただけの画面は未完成。求めるのは次の 4 つの**性質**で、**どの画風で
満たすかは自由**（画風はゲームごとに決める。詳しくは `.claude/skills/visual-dict`、
シェーダーの語彙は [shader-doc.md](shader-doc.md)）。下は手の一例。

| 満たす性質 | 手の例 |
|---|---|
| 面に階調か質感がある | ShaderDoc + Render.shaderFill / Render.vgrad・gradPolygon / Material（粒・きらめき・染み）/ Render.striped・checker / PxShade のディザ |
| 主役が背景から分離して読める | PxShade（ふち光・接地影）/ Render.glowAt / Render.outline / 明度差・色相差 |
| 層が分かれている（奥・主役・手前） | Render.zShifted・zShiftedAll / Depth / Transition の覆い |
| 時間が流れている | Fx・FxDoc（粒）/ Sway（揺れ）/ Anim（コマ替え）/ Scatter / Daylight |

光と影で色そのものを分けたいときは **Color.warm / Color.cool**。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| 箱や丸を並べて物・キャラを作りたくなった | PxSprite（+PxShade）/ gradPolygon / Terrain。RawDraw は下地とデバッグ用 |
| メニューを作る（項目列・カーソル・ハイライト） | UiMenu（実例: `templates/novel-starter/src/World.flix`） |
| 表示範囲より長い内容をスクロールで覗く（ログ・履歴・一覧） | UiScroll |
| 描画物を矩形で切り抜く（スクロールの表示範囲・PiP。スクリーン空間） | Render（clipped / clippedAll）（実例: `templates/novel-starter/src/View.flix`） |
| 文章を幅で行に折る・描く前に行数を数える | RichText（wrapLinesBy）（実例: `templates/rpg-starter/src/View.flix`） |
| ホイールの生 delta を目盛りにまとめる | InputMap（wheelSteps） |
| 固定スロットに可変個の項目を流し込む | UiSlots（実例: `templates/novel-starter/src/World.flix`） |
| UI を JSON（ui.json）で宣言する | UiDoc / UiSpec（実例: `templates/novel-starter/assets/ui/dialog.ui.json` / `templates/novel-starter/src/NovelKit.flix`） |
| 宣言した UI の「名前 → 画面上の矩形」を引く（当たり判定を宣言と共有） | UiDoc（rectsOf / renderWithRects）/ Flex（keyed） |
| UI の箱にドット絵の皮を着せる（九分割スキン。box の skin） | UiExtract（boxPlacedItems）/ UiDoc |
| UI 要素を並べる・整列する | UiLayout / Flex（実例: `templates/novel-starter/src/NovelKit.flix`） |
| UI の文字欄に実行時の値を差し込む | UiBinding |
| 会話窓・文字送りを出す | UiDialog / UiTypewriter（実例: `templates/novel-starter/src/World.flix`） |
| マウスの下の UI 要素を知る | UiFocus（実例: `templates/novel-starter/src/Controls.flix`） |
| meta "prefix/N" から番号を読む | UiMeta（実例: `templates/novel-starter/src/Controls.flix`） |
| 粒を舞わせる | Fx / Scatter（実例: `templates/race-starter/src/World.flix`） |
| 疑似遠近のストリップ（横一列）ごとに立ち物・床を敷く | Scatter.strip（実例: `templates/race-starter/src/ViewScene.flix`） |
| 爆発・火花を fx.json で宣言して時刻から描く | FxDoc / Fx（sample / sampleAt）（実例: `templates/race-starter/assets/fx/spark.fx.json`） |
| 粒を輪に等分して撒く・破片を回しながら飛ばす | FxDoc（dir.mode: even / turn）（実例: `templates/race-starter/assets/fx/crash.fx.json` / `nitro-burst.fx.json`） |
| 蛍・湯気をその場でゆらゆら舞わせる | FxDoc（wobble） |
| 雨・火花・流星を速度方向の筋で描く | FxDoc（shape: streak / stretch） |
| 粒をふわっと明滅させる | FxDoc（カーブ pulse） |
| 撃つたびに出る効果を発生・寿命回収・描画で回す | Fx（burst / expire / drawAll）（実例: `templates/race-starter/src/World.flix`） |
| 値を滑らかに動かす | EcsTween / Curve |
| 整数を 1 つずつ動かす（数え下がり・数え上がり・巡って止まるルーレット） | EcsTween（steppedInt） |
| 演出の時刻表（重なってよい拍の並び・音を鳴らす拍・全体の秒）を Doc の秒から組む | Timeline（クリップ: toClips / startedBetween / totalOfClips） |
| ヒットストップ・スローモーション（ゲームの時計を一時的に遅くする） | TimeScale |
| 長押しで決める・飛ばす（会話のスキップ・消去の確認） | HoldPress |
| スプライトをコマ送りする | Anim（実例: `templates/platformer-starter/src/View.flix`） |
| ドット絵を文字格子(*.sprite.json)で宣言して描く | PxSpriteDoc / PxSprite（実例: `templates/game-starter/assets/`配下の `*.sprite.json` + `templates/game-starter/src/Palette.flix`） |
| 一続きの振り付け(歩く→拾う→戻る)の現在区間を時刻から引く | Timeline |
| 経路(脚の列)の現在地・歩き量・到着を時刻から引く | Journey（実例: `templates/rpg-starter/src/World.flix`。住人巡回） |
| イベントシーン(カット列)を世界の状態を見ながら順に演じる | SceneSeq |
| 一定間隔で合図を出す・残り時間を数える | Clock（実例: `templates/rpg-starter/src/World.flix`） |
| 一過性演出（発火→寿命）の経過・進行・生存を時刻から引く | Lifetime |
| 巻き戻し・リプレイ・履歴 | Worldline |
| セーブ・ロード | SaveManager / Persistence |
| タイルのマス目と移動範囲 | Grid / GridSearch（実例: `templates/platformer-starter/src/Stage.flix`） |
| 敵を追わせる・逃がす・ふらつかせる(距離場の 1 歩) | Steering |
| タイルセット PNG + 自前の map.json でマップを貼る | MapResource |
| チップ絵タイルを 1 draw call で敷く(事前に生成・マスごとの照明色 tint・屋根や庇は zIndex で手前にも) | App.withTileLayers / TileScene（実例: `templates/platformer-starter/src/Main.flix` / `templates/rpg-starter/src/TownMap.flix`） |
| チップ絵なしでマップ地形(壁・水)を多角形で描く | DualGrid / Material（repo 内に見本なし。[dual-grid.md](dual-grid.md)） |
| rows の文字格子から地形の見た目を作る(*.terrain.json) | Terrain / TerrainDoc（repo 内に見本なし。[dual-grid.md](dual-grid.md)） |
| 側面・斜めの自然地形（丘・砂丘・崖）を高さの関数で 1px ドット絵に敷く | PxTerrain（init で 1 回組んで持ち回す） |
| 重なり判定・物理 | Collision / Physics2D |
| 当たり判定を JSON で宣言する | HitDoc + Hit（実例: `templates/platformer-starter/src/World.flix`） |
| キーが押された瞬間を取る | InputEdge |
| 複数キーを 1 つの操作にまとめる（WASD と矢印の両対応） | InputMap（実例: `templates/game-starter/src/KeysDoc.flix`） |
| カメラでズームする・追いかける | CameraRig（実例: `templates/platformer-starter/src/World.flix`） |
| 被弾・着弾で画面を揺らす（減衰ノイズの画面揺れ） | CameraRig（addTrauma / tick / shakeOffset）（実例: `templates/platformer-starter/src/World.flix`） |
| 起動中のゲームを外から操作・観測する | RemoteDebug |
| Studio に「いま表示中の Doc」を名乗る（表示中バッジ） | ActiveDocs（実例: `templates/tetris-starter/src/World.flix`） |
| 画面を覆う・晴らす切り替え演出（フェード・ワイプ） | Transition |
| 面を画素ごとの計算で塗る（動く霧・水面・溶岩・vignette。単色 box の置き換え） | ShaderDoc + Render（shaderFill / shaderFillMasked）→ [書き方](shader-doc.md)（実例: `templates/rpg-starter/assets/town.shader.json`） |
| シェーダー面を多角形の形に抜く（池・水たまり） | Render（shaderFillMasked） |
| 光らせる・暗く沈める（加算・乗算の重ね方） | Render（blended） |
| 絵を傾ける・集まりを丸ごと傾ける（カードの傾き・振り子） | Render（turned / turnedAll）/ ui.json の rotation |
| ドット絵のコマの大きさを知る（当たり・置き場所を絵に追随させる） | PxSprite.sizeOf / PxSpriteDoc.gridSizeOf |
| 文字の並び（rows）の大きさを測る・1 マスずつほどく | Grid.dimsOfRows / Grid.cellsOfRows |
| 0〜1 に収める・小数部だけ残す・周期で折り返す（負の値も安全） | Num.clamp01 / clamp / fract / wrapTo / lerp |
| 床丸め・最近整数（0.5 は上へ）で Int32 に落とす（負の座標もマスが揃う） | Num.floorInt / roundInt |
| 素の中心＋幅高の箱どうし・点×箱の重なりを聞く（接するのは外） | Hit.boxBox / pointBox |
| スプライトが無い・読めないとき仮色の板にする（穴を開けない） | RawDraw.orBoxAt |
| Doc の一覧を一覧表 1 枚にし watchFile・一括リロード・表示中バッジを導出 | DocTable |
| 色を作る（0〜1・0〜255・#rrggbb）・2 色を混ぜる・比べる | Color.rgb / rgb8 / hex / mix / channels |
| 置き場所つきの絵に修飾を掛ける・列を丸ごと薄くする | Render.overItem / Render.fadeAll |
| 修飾パイプの末尾で置き場所を与える（`{ at = …, item = … }` の糖衣。中心置きは At 族） | Render.at |
| 列を丸ごと動かす・pivot 不動点で一様に拡縮する（Clipped の切り抜き矩形も追随） | Render.movedAll / Render.scaledAllAround |
| Doc を fail-open で読む（読めない・壊れは既定値へ） | DocJson.loadOr / decodeObject |
| 太さのある線・棒を引く（法線を手計算しない） | RawDraw.lineSeg / Quad.strip |
| 値を範囲に収める（1 軸） | Num.clamp（カメラの寄せ幅は CameraRig.clampAxis） |
| 色を明るく・暗くする | Color.lighten / Color.darken |
| 文字を中央に置く・幅を測る | TextDraw.centered / TextDraw.width |
| 文字格子から 1 種類の文字のマスを集める | Terrain.cellsOf |
| テスト用の入力フレームを組む | App.frameOf |
| 生成した絵に出ない指定を知る（実機との食い違い防止） | SoftRaster（dropped）/ [対応表](backend-parity.md) |
| 縁がふわっと消える光球・煙玉を置く | Render（glowAt）/ fx.json の shape "glow" |
| 放射状の明かり・翳りを 1 枚で置く（松明・スポットライト・vignette。アセット不要） | Render（lightAt / darkAt。組み込みテクスチャは engine の RadialBuiltin） |
| 空・水面・光の帯のグラデを 1 部品で塗る（頂点色つき凸ポリゴン。1px の細い矩形を積まない） | Render（gradPolygon / vgrad） |
| 箱に枠線を付ける（半透明の枠も） | Render（outline / outlineA） |
| 暗い部屋に光源を置く（穴あきの暗くするオーバーレイ+ハロ） | Light |
| 複数光源＋影（光マップ。Pass に灯りを集めて Multiply で貼る） | Light（lightMapPass / lightMapOverlay）+ App.withPasses |
| 光源を JSON で宣言する（light.json） | LightDoc + Light |
| 壁に影を落とす（単一光源のハードシャドウ） | Shadow |
| 夜のガラス・鏡・磨いた床に姿を映す（明るいところは光として返し、暗いところは影として重ねる） | Mirror |
| 効果音を鳴らしたい | App.withAudio（前後 World の差分から鳴らす名前の List を返す。詳しくは [audio.md](audio.md)。実例: `templates/game-starter/src/Main.flix`） |
| 鳴り続ける音を出したい（走行音・風・雨・炎・足音のループ） | App.withSustained（World から「鳴り続けていてほしい音」を宣言。音量と高さを毎フレーム与える。詳しくは [audio.md](audio.md)。実例: `templates/race-starter/src/Sfx.flix`） |
| BGM を流す・止める・音量やループを変える | AudioStreamPlayer（play / stop / setVolume / setLooping。詳しくは [audio.md](audio.md)） |
| BGM をだんだん出す・消す・入れ替える（音量カーブ） | AudioFade |
| 効果音の素材を録音なしで作りたい（波形合成） | SfxSynth（engine_tools。詳しくは [audio.md](audio.md)。実例: `templates/race-starter/src/render/SfxRender.flix`） |
| 揺れる演出を作る（浮遊・風のなびき） | Sway（実例: `templates/tetris-starter/src/View.flix`） |
| リソース JSON の形（型・必須・既定値）を公式スキーマ方言で宣言する | Schema（実例: `templates/race-starter/project.schema.json`） |
| 見下ろしで「足元が下にある物ほど手前」に並べる（人が木の裏に回る） | Depth（実例: `templates/rpg-starter/src/View.flix`） |
| 一人称・疑似 3D（2.5D）で世界の点を画面へ落とす（透視除算・近クリップ・逆投影・距離霧） | Persp |
| マス目の迷路から「カメラに見える壁の面」だけを集める（内部面・裏面は落とす） | WallFaces |
| world 座標を画面へ落とす・戻す（横視点・見下ろし・斜め見下ろし・一人称の 4 通り） | ViewProjection（横視点と見下ろしは CameraRig へ委譲・一人称は Persp・見下ろしの前後は Depth） |
| 「画面のここを 16px 直したい」を配置 Doc の数字へ翻訳する | ViewProjection.inverseOf → toWorldDelta（斜め見下ろしでは x だけ動かしても world は 2 軸とも動く） |
| 斜め見下ろしで画面を覆うマスを列挙する（外接だけでは四隅と高いマスが落ちる） | ViewProjection.quarterOf → coveringCells（軸に平行な盤は Grid.cellsIn） |
| 描き出した 1 枚に「この塊は何として描いたか」の目録を添える（材質の色の潰れ・主役の埋没を数で出す） | RenderManifest（検査を鳴らす条件は intent。実行中の矩形の記録は Annotate、UI の幾何破綻は RenderLint） |
| 距離の遠→近の描画順（zIndex）を振る（疑似 3D の上塗り） | Painter（見下ろしの前後は Depth） |
| 壁越しに見えるか（視線の遮蔽）を判定する（壁の向こうの松明を消す・敵から見えるか） | GridRay |
| ゲームの中の時計と暦を回す（分・時・日・季節・年） | Calendar |
| 時刻で世界の色を変える（朝の青・夕の橙・夜の紺）・影の向きと長さを回す | Daylight（実例: `templates/rpg-starter/src/View.flix`） |
| ドット絵の塗りに光を当てる（ふち光・接地影・ディザ・地肌の粒） | PxShade（実例: `templates/game-starter/src/ThemeDoc.flix`） |
| 見下ろしの落ち影を置く（接地の暗がり + 時刻で回る日影） | Daylight.groundShadow |
| 見えている範囲に重なるマスだけ並べる（盤が広くても仕事は画面ぶん） | Grid.cellsIn |
| ドット絵を握るところで回す・左上でそろえて並べる | PxSprite.drawQuadTurned / drawQuadTopLeft |
| 走行中に生成した絵を静止画の描き出しでも同じ絵にする | HeadlessRender.imagePngs / imageTextureInfo（実例: `templates/race-starter/src/render/SceneRender.flix`） |
| 光側は暖色・影側は寒色へ近づけて階調を増やす | Color.warm / Color.cool |
| 生成したドット絵アトラスを名前付きテクスチャとして使う（1 体 = 1 クアッド） | App.withSpriteAtlases（実例: `templates/race-starter/src/Main.flix`） |
| ドット絵の輪郭をにじませない（カメラと頂点を画素の升目に載せる） | App.withPixelSnap / Render.snapped（実例: `templates/platformer-starter/src/Main.flix`） |
| 同じ絵を色だけ変えて使い回す・重なり順をまとめてずらす | Render.tinted / Render.zShifted |
| マスごとの「いま」を持つ（耕した・濡れた・置いた。セーブに乗る側） | TileState |
| 画面を素材にする・複数光源・残像を作る（レンダーターゲットに描いてテクスチャとして貼り戻す） | Pass（`App.withPasses`）。ターゲットは design 解像度・宣言順に本編より先に描かれ、`Render.sprite(name, z)` で貼れる |
| Pass を描き出し（HeadlessRender の PassSpec）へ詰め替える（Shader 面の外し忘れを防ぐ） | Render.passSpecOf |
| 全面でない面（横長のストリップなど）から pass を等倍・鏡像で読む（陽炎・水面の映り込み） | Render.passStripDy（Shift の dy 場を作る） |

## 症状 → モジュール（重い・fps が落ちる）

| 症状 | モジュール |
|---|---|
| 小さすぎて見えない物・画面外の物を大量に作っている | Scatter.strip（作る前に捨てる。reach 余白と cellsMax の倍々間引き） |
| 動かない背景を毎フレーム作り直している | App.withStaticLayer（鍵が同じ間は GPU バッファを使い回す） |
| タイルが多い・タイル宣言の組み立てが毎フレーム走る | App.withTileLayers（tiles はサンク — 鍵が変わるまで評価されない） |
| 遠くで 1px を切る物まで組み立てている | 倍率の床で place ごと切る（実戦の例: templates/race-starter の propCull / palmCull） |
| 1 マスを画素ぶんの box で組んでいる（絵は同じでも桁が違う） | PxSprite.drawQuad（1 コマ = 1 クアッド）。アトラスは PxSpriteAtlas.bake + App.withSpriteAtlases |
| make reference-check / make status が「budget NG」と言う | 絵の値段の検査（決まりと逃がし方は docs/performance.md §9）。静的層ぶんは HeadlessRender.noteStaticItems で申告して引く |

## 土台（App・ECS）

- **App** — ゲームを「宣言」で組み立てて走らせるランナー。
- **EntityId** — entity を識別する番号（共有 ECS lib のトップレベル型）。
- **Query** — 部品ごとに分かれた表から「同じ物が持つ複数の部品」を突き合わせて取り出す。
- **Hash01** — 2 つの整数から 0 以上 1 未満のばらついた数を 1 つ決める（決定論の乱れ）。
- **RandomUtil** — 乱数の小さな操作。リストから 1 つ選ぶ・範囲内の実数を引く。

## 描画

- **Render** — 「何をどう見せたいか」だけ書いた Item を、描画部が食べられる形に変換する。
- **RawDraw** — 単色ベタの図形プリミティブ（box / circle / star / ellipse / sector / ngon など）。材料であって、
  View に直接並べる完成品ではない。正当な用途は HUD 下地・デバッグ描画・fail-open の仮板。
- **CameraRig** — world のどこを・どれだけズームして映すかを描画物の列に掛ける道具箱。
- **Depth** — 見下ろし画面で「足元が下にある物ほど手前」を重なり順（zIndex）の数として決める。1 画面に帯が何本も要るとき（奥・遠景・地面・影・中景・近景・手前）は Bands で名前を付けて並べる（bandZ = 帯の底の z・bandRange = その帯の中の足元順）。
- **Persp** — 疑似 3D（2.5D）カメラの数学一式。世界の点を前後 fwd・左右 lat に分解し、透視除算で画面へ落とす。近クリップ・逆投影（depthAtY）・距離霧の式も持つ。焦点距離や霧の色の実体はゲーム側の意見（theme Doc など）。
- **WallFaces** — マス目の迷路から「カメラに見える壁の境界面」だけを集める純幾何。壁どうしの内部面と、カメラに背を向けた裏面は落とす。solid の判定は関数で注入する（MapDoc の形を知らない）。
- **Painter** — カメラからの距離で遠→近に並べ、zBase から zStride 刻みの zIndex を振る（画家の順）。疑似 3D は z バッファを持たないので、遠い物から上塗りして前後を作る。見下ろしの前後は Depth（別物）。
- **ViewProjection** — world 座標を画面（design px）へ写す 4 通り（Side / TopDown / Quarter / FirstPerson）と、その逆算。**斜め見下ろし（Quarter）の world↔screen はここにしかない**（横視点・見下ろしは CameraRig の centerOn / toWorldPos へそのまま渡す・一人称は Persp・見下ろしの前後は Depth）。**「その写し方にその操作が有るか」は Option で返さず、持ち物を取り出す口（quarterOf / firstPersonOf / inverseOf）で 1 回だけ捌く** — 取り出した後の toWorld / toWorldDelta / coveringCells / yawOf / distanceOf / visibleFraction / wallQuad は Option を返さない。Option が残るのは toScreen（カメラの後ろに来た点）だけ。画面を覆うマスの列挙は coveringCells（外接だけでは落ちるマスがある。契約は Grid.cellsIn とそろえてあり、cols / rows で盤の外を落とし margin で余分を足す）。壁の台形は wallQuad（四隅 + 描画順の dist + 模様を世界に固定する t0 / t1）。タイルの大きさ・カメラ・焦点距離は既定値を持たない（ゲーム側の意見）。
- **RenderManifest** — 描き出した 1 枚の「目録」を JSON にする。1 行（Claim）は kind / material / role（4 つで閉じた enum） / layer / world 座標 / src / intent を持ち、画面ぜんたいの下地の色は design の隣にトップレベルで出る。PNG からは読めない欠陥（材質どうしの色が同じに潰れた・主役が背景に溶けた・地形が Doc と違う高さで描かれた）が数で出る。**検査は作者が intent に書いたことについてだけ動き、書かなかった行は undeclared に id を並べる**（沈黙もさせず、止めもしない）。**aabb と colors は作者の申告であって描き出した画素の計測ではない** — build が unmeasured にその断りを必ず 1 本足す。書き出し（write）は失敗を Result で返す（PaletteExport と同じ形）。
- **Daylight** — 1 日の進み（0〜1）から「空気の色」と「太陽の位置」を決める。色は画面全体に乗算で薄く掛け、太陽からは影の向き・長さ（shadowAt）とドット絵に当てる光の向き（lightStepAt）を導く。暗さ（darkness）を読めば、明かりの点灯と空の色が食い違わない。落ち影は見下ろしが groundShadow（円 1 つ）、横視点が sideShadow（横半径と縦半径を別に取り、足元の高さから左右へだけ伸びる）。
- **TextDraw** — 文字列を「中心をここに置きたい」で配置する。
- **RichText** — 一部だけ色や太さの違う文章をスパンの列として持ち、描画アイテムへ組む。
- **Quad** — 回転した矩形や太さのある線の、四隅の座標を計算する。
- **Bezier** — ベジエ曲線の平坦化と、曲線から作る描画部品。
- **Fx** — たくさんの粒を、保存せず「今の時刻から計算」して並べる薄い仕組み。「撃つたびに出る」効果の器（burst / expire / drawAll）も持つ。
- **FxDoc** — fx.json（閉形式パーティクル）を Spec に読むパーサ。絵は Fx.sample が導く。語彙は mode: loop（常時系）/ spawn（発生源の広がり）/ accel（重力/風・½at²）/ seed（決定的シードの上乗せ）/ dir.mode: even（粒の番号で射出方向を等分 — 衝撃の輪・花火）/ turn（粒の傾き base・spread と回る速さ spin・spinSpread。単位は回転数で 1 周 = 1.0）/ wobble（位置の正弦揺らぎ amp・freq・vary — 蛍・湯気の有界運動）/ shape: streak + stretch（速度方向に伸びた筋 — 雨・火花・流星）/ カーブ pulse（1 と min の間の正弦明滅）/ parseWith（"@名前" の色キーをパレットで解決）。
- **Scatter** — どこまでスクロールしても同じ配置が再現される、無限の「物の撒き方」。field は見えている矩形を升目走査、strip は疑似遠近のストリップ 1 本（ストリップごとに見える幅が違う画面）を span + reach + cellsMax で敷き、画面外のセルは作る前に捨てる。fieldExcept は「ここだけ空ける」帯（主役の立つ帯・道・水面）をセル単位で落とす（落ちるセル以外は field と 1 個も変わらない）。
- **Anim** — スプライトシートのコマ送りを「時刻の純関数」で導く。
- **PxSpriteDoc** — *.sprite.json（文字格子+意味色キー+名前付きコマ+anchor+loop）を読む fail-open の Doc 層。loop はコマの回し方の宣言（forward / pingpong / once・省略時 forward）で、frameIndexAt が通し番号をコマ番号へ写す。宣言が無いと往復のコマ列と本物の破綻を数値で見分けられない（bin/fge anim）。
- **PxSprite** — PxSpriteDoc のコマを box 列（横連続の同色文字は 1 矩形に結合・既定）または drawQuad（アトラス 1 クアッド・opt-in）で描く。色は resolver（キー→実色）が解決。drawQuad の scale は整数のみ（box 列とのバイト一致保証のため）。実数倍率のクアッドは templates/race-starter の ViewCar.pxQuadScaled が実戦例（遠景のヤシ・ニトロ残像。2 本目の使い手が現れたら昇格を相談）。
- **PxShade** — 文字格子のドット絵に「塗りの仕上げ」を 1 度だけ掛ける純粋な filter（ふち光・接地影・ディザ・地肌の粒）。絵は平らに塗り、光の当て方は後から重みで指定する。掛けるのは読み込み直後の 1 回だけなので走行中の負荷は増えない。
- **PaletteExport** — 導いた意味色キーの実色を色票 Doc（*.palette.json = version / note / colors）として書き出す。Studio のドット絵エディタが legend の名前を解けるようにするためだけの物で、ゲームの絵はここを読まない。fromKeys（意味色キーの列 × resolver → 表）と build（純粋・文字列）と write（Fs.FileWrite）。
- **PxSpriteAtlas** — PxSpriteDoc×resolver を 1 枚のアトラス画素（ARGB+コマ→矩形の目次）に生成する純関数。GL（RenderTexture.loadTextureFromPixels）と PNG（SoftRaster.writeRadialPng）が同じ Baked を読む。
- **Viewport** — 画面の矩形の外へ出た物を見つけて返す。
- **Transition** — 進行度 t から画面を覆う/晴らす描画物を作る（フェード・ワイプ）。
- **Light** — 光源の値（位置・半径・色）から灯りの絵を導く。方式は 2 つで使い分ける:
  暗くするオーバーレイ方式（items。穴の外は一様な闇。pass 不要で rim・ハロ拡大の質感あり。影は単一光源のみ）と
  光マップ方式（lightMapPass / lightMapOverlay。環境光のある夜。光源が何個でも光ごとに影が落ちる。
  App.withPasses と組む。光 A の影は光 B の灯りも消す割り切り）。
- **Shadow** — 光と壁の頂点列から影の四角形を導く（当たり判定の形からも作れる）。
- **Mirror** — 面（夜のガラス・鏡・磨いた床）に映る姿を、ドット絵の走り（PxSprite.Run）から組む。映り込み用の絵を別に描かないので、元の絵を直せば映るほうも一緒に直る。映るかどうかと、どのコマをどこへ合わせるかは呼び側の決めごと。
- **LightDoc** — light.json（光源の質感）の宣言層。暗さ・照り返しフチ・ハロの大きさ・環境光・影の濃さ・光源の並びを JSON に書き、Spec へ読み取る。壁の遮蔽形はゲームの World が持つので含まない。ambient / shadowStrength（光マップ方式用）は 0.19 系から — 古いバージョンのエンジンは読み飛ばして既定になる。

## UI

- **UiDoc** — ui.json 方言の唯一のパーサ。JSON のノード木を Spec へ読み取る。
- **UiSpec** — UiDoc の Spec を UiStore 向けに射影し、spawn / リロードを担う宣言層。
- **UiStore** — UI を作る「部品ごとの表」の束と、その足し引きの基本操作。
- **UiLayout** — 縦か横に並べる指定から、各 UI 要素の画面上の矩形を自動で決める。
- **Flex** — 宣言的なノード木を UiLayout でレイアウトし、描画物の列に落とす薄い汎用層。
- **UiWidget** — UI 要素の「見た目の中身」（箱・文字・スプライト）の属性と操作。
- **UiShape** — 図形 widget の共有語彙（circle / star / line などのパラメトリック図形）。
- **UiExtract** — 配置と表示可否が決まった UI を、描画部が食べられる絵の列に変換する。
- **UiRender** — UI 全体を毎フレーム、そのまま描ける絵の列に変換する入口。
- **UiHierarchy** — UI entity の親子ツリー走査（完全純粋）。
- **UiFocus** — マウス座標の下にある一番手前の UI 要素を見つけて返す。
- **UiBinding** — UI のテキスト欄に付けた「差し込み名」を実行時の値に置き換える。
- **UiSlots** — ui.json に用意した固定数のスロットへ、可変個の項目を先頭から流し込む。
- **UiMenu** — 選択メニュー共通の「項目の並べ方」「選択中の見せ方」「カーソルの動かし方」。
- **UiScroll** — 表示範囲より長い内容を位置ひとつで覗く共通の勘定（末尾基準 offset・両端 clamp・▲▼判定）。
- **UiMeta** — UI の目印（meta 文字列）の共通の読み方（接頭辞 + 番号）。
- **UiDialog** — 会話窓の中身（誰が・何を・どこまで見せたか）と、その進め方。
- **UiTypewriter** — 文章を 1 文字ずつ現す「文字送り」の進み具合を持つ小さな値。

## 時間と動き

- **AudioFade** — 進行度 t から音量をひとつ決める（フェードイン・アウト・クロスフェード）。
- **Calendar** — ゲームの中の時計と暦。実時間の秒を分・時・日・季節・年へ換算し、日またぎを合図する。
- **Clock** — 経過時間を貯めて「一定間隔で合図」「残り時間を数える」を数値だけで扱う。
- **Lifetime** — 一過性のもの（発火して時刻で進み寿命で消える）の「誕生時刻＋長さ」から経過・進行(0..1)・残り・生存を now の純関数で導く。得点ポップ等の表示期間や Fx.Burst の寿命に使う（now から導くので巻き戻しに強い）。
- **Curve** — 時間や進行度から、放物線の山・周回・揺れなどの値を計算する、状態を持たない小さな関数の詰め合わせ。
- **EcsTween** — 値をある値から別の値へ、時間をかけて滑らかに動かす（補間する）。整数を 1 つずつ動かすのは steppedInt（数え下がり・ルーレット）。
- **Journey** — 脚(出発点・行き先・速さ)の列を「時刻の純関数」で歩く。到着判定(done)と絵の位置(pos)を同じ戻り値で返す。
- **Motion** — 物の動かし方の小さな道具箱（等速移動と往復運動）。
- **Timeline** — 区間(名前+長さ)の列を「時刻の純関数」でサンプルする。範囲外は None = 終わり。履歴・巻き戻しは Worldline（別物）。演出の時刻表には重なってよいクリップ（tag + start + dur。tag はゲームの enum）を使い、音は startedBetween、全体の秒は totalOfClips で引く。
- **TimeScale** — ヒットストップ・スロー。合図からの実秒で「止める → 遅く流す → 等速へ戻す」を決め、毎フレームの dt を gameDt で直す（ゲームの時計ごと遅くする）。光や揺れは realAt の実秒で動かせる。
- **HoldPress** — 長押しで決める。押している間だけ秒を貯め、満ちたフレームで 1 回だけ合図、合図の後は離すまで貯めない。押した瞬間の拍そのものは InputEdge。
- **SceneSeq** — カット列の逐次シーケンサ骨格。perform（カットを 1 コマ演じる）と idle（尽きたあと時間だけ流す）を注入し、Skip・打ち切りは notes に残す（fail-open だが無音ではない）。
- **Sway** — 時刻から微小な揺れを作る純粋な道具（蓮の葉の浮遊・草や旗の風・吊るした物）。一様にずらせば浮遊（drift）、高さに比例して曲げれば根が止まって先だけしなる（wave）。掛け方は呼び側が決める。

進行 4 抽象の分業（どれも「列を順に消化する」が、決め手が違う）:

| 抽象 | 決め手 | 向く場面 |
|---|---|---|
| Timeline | 尺が既知。時刻 t から現在区間を引くだけの純関数 | 振り付け（歩く→しゃがむ→戻る） |
| Timeline（クリップ） | 尺が既知で拍が重なる。拍の頭と音の拍を引く | 演出の時刻表（巡る → 止まる → 飛ぶ → 弾む） |
| Journey | 脚の列（出発点・行き先・速さ）の時刻純関数 | 経路の現在地・到着判定 |
| Replay | 入力が固定。入力列を tick へ流す再生 | プレイの再現・自動操作 |
| SceneSeq | 世界を見て尺が決まる再生。終わりは世界の状態から判定 | イベントシーン（カット列） |

## 盤面

- **Grid** — 正方タイルの「何列目・何行目」と画面上のピクセル位置を相互に変換する。セル座標の規約は 2 つ: 左上原点・tileSize 割りの系（cellAt）と、セル中心が整数・境界 ±0.5 の系（cellAtCentered — GridRay / WallFaces が使う）。
- **TileState** — マス目の「いま」を持つ疎な表（耕した・濡れた・置いた）。日ごとの一斉更新とセーブの往復を持つ。地図の形（読むだけの設計図）とは置き場所を分ける。
- **GridSearch** — マス目の上で「どこまで行けるか・何歩かかるか・どこが射程か」を求める。
- **Steering** — 距離場（GridSearch）の 1 歩 chase / flee / wander。「入れるか」は canEnter で注入。敵 AI とイベントシーンが同じ 1 歩を使う。乱数を持たず同着は固定順 — 何度描き出しても毎回同じ。
- **GridRay** — マス目の世界で「start から goal の間に壁が挟まるか」（視線の遮蔽）。壁の向こうの松明を消す・敵から主人公が見えるか、の見通し判定。solid の判定は関数で注入する。
- **Dir4** — 上下左右の 4 方向を 1 つの値としてまとめて表す。
- **MapResource**（legacy/） — タイルセット PNG + 自前の map.json でマップを貼る旧世代層。新規は DualGrid / Material / TerrainDoc を使う(棲み分けは docs/dual-grid.md)。
- **TileScene** — App.withTileLayers のタイル層宣言(TileLayerSpec)を CPU 投影で普通の絵へ変換する。ヘッドレス生成・F8 停止画面・スナップショットが GPU の事前生成と同じ絵になるための橋。
- **DualGrid** — セル4角の埋まり方から 16 ケースの地形多角形(丸/四角/ひし形/揺らぎ)を作る純幾何。概念: docs/dual-grid.md。
- **Material** — DualGrid のタイルに質感(塗り・フチ・持ち上げ・表面の粒)を着せる。チップ絵は使わない。MapResource が「タイルセット PNG を貼る」のに対し、こちらは「色と質感パラメータで手続き生成する」並立の経路。
- **Terrain** — 「どのセル文字に、どの質感を着せるか」の表と rows アダプタ。rows の文字格子を塗るだけで DualGrid の角の変化形が自動生成される。fromRows は Doc+rows だけで完結する教科書 API。
- **TerrainDoc** — セル文字→質感の表の宣言(*.terrain.json)を読む codec。色は #rrggbb か @キー(テーマ参照)。

**この 4 つ(DualGrid / Material / Terrain / TerrainDoc)を呼ぶ見本はこのリポジトリに無い。**
`templates/` にも `bench/` にも呼び出し元は 0 件で、`.terrain.json` も 1 つも無い。
使うときの写経元は `engine_world/src/Terrain.flix` / `Material.flix` / `TerrainDoc.flix` の
冒頭 doc コメントと、Doc の形は `engine_world/test/TestTerrainDoc.flix`。仕組みの説明は
[dual-grid.md](dual-grid.md)。

## 物理・衝突

- **Physics2D** — 物理を「積分・検出・反射・分離」の 4 つの純関数に切り出して合成する。
- **Collision** — たくさんの物体の中から、実際に重なっている組を見つけて返す。
- **Hit** — JSON で宣言した形（円・箱の列）で「触れているか」だけを聞く照会専用の判定。
- **HitDoc** — 当たりの形の宣言（hitbox.json）を読む codec。欠け・間違いは位置付きで断る。

## データと保存

新しい Doc（*.kind.json）を 1 つ足すときは、この順で使う:

1. **Schema** — 形を宣言する（`*.schema.json`。任意）
2. **`<X>Doc.flix`** — 型と fromJson/toJson を書く（decode は JsonCodec、エラー位置は DocJson.atNode）
3. **DocJson** — decodeObject で fromJson を 1 行に / loadOr で fail-open 読み
4. **DocTable** — 一覧表に 1 行足す（watch・F1 リロード・表示中バッジが導出される）
5. **Persistence / EcsCodec** — セーブに乗る値だけ（表なら EcsCodec）

- **Persistence** — 値をディスクに保存し、また読み戻すための汎用のしくみ。
- **SaveManager** — セーブデータをスロット番号でファイルに保存・読み出しする薄い層。
- **Worldline** — World の軌跡（履歴・巻き戻し・リプレイ・分岐の土台）。時間区間の振り付けは Timeline（別物）。
- **JsonCodec** — 値 ⇄ JSON の純変換ヘルパ（expect 系 / encode・decode）。
- **DocJson** — Doc を読むときの JSON 道具箱。parse・デコード補助（atNode 等）と fail-open 読み込み（loadOr・checkVersion）。
- **EcsCodec** — 「番号ごとの値の表」を JSON と相互変換する共通ヘルパ。
- **Resource**（legacy/） — 旧世代のスキーマ方言。新規は Schema を使う。
- **CatalogContainer** — 「1 ファイル = 1 種類の一覧」を表す汎用の入れ物。
- **Schema** — リソース（ゲームデータ JSON）の形を宣言する公式スキーマ方言（例: level.json の隣の level.schema.json）。データの形（type / required / default）はゲームも検証に使い、見せ方（widget）はエディタ専用でエンジンは開けない封筒として運ぶ。未知の type タグ・kind は黙って通さず Err にする。

## 入力

- **InputEdge** — キーが「今まさに押された瞬間」か「押しっぱなし」かを見分ける。
- **InputMap** — 生のキーを「操作の意図」へ写す表。同じ意図に複数キーを並べられる（WASD と矢印の両対応など）。
- **Replay** — 入力の列を順番に tick へ流し込む（再現・自動操作）。

## デバッグ・開発

- **ActiveDocs** — 「いま表示に使っている Doc(JSON)はどれか」を debug/active-docs.json に名乗る（Studio の「表示中」バッジはこれを読む。同じ内容なら書かない）。
- **DocTable** — Doc の一覧表（id・パス・読み直し）1 枚から、watchFile の配線・一括リロード・ActiveDocs の名乗りを導出する。一覧の手写しを 1 か所に。既定は `row` で 1 行、外れる行に `watchOnly` / `reloadAllOnly` / `activeWhen` を被せる。
- **Annotate** — 実行中のゲームを一時停止して、画面の気になる場所を矩形で囲んで記録する。
- **RemoteDebug** — 起動中のゲームを外部プロセスが HTTP で操作・観測する口。POST /render は App.onRenderRequest で登録した「描き出しの実体」を温まった JVM で実行し、描き出したパス列を返す（プレイ状態には触れない）。
- **GameLogger** — 起きたことを 1 行ずつログに積み、あとでまとめて取り出す effect。
