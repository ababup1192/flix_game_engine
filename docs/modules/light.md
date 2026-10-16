# 光・影・色・シェーダー・時刻の色

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| 面を画素ごとの計算で塗る（動く霧・水面・溶岩・vignette。単色 box の置き換え） | ShaderDoc + Render（shaderFill / shaderFillMasked）→ [書き方](../shader-doc.md)（実例: `templates/rpg-starter/assets/town.shader.json`） |
| シェーダー面を多角形の形に抜く（池・水たまり） | Render（shaderFillMasked） |
| 光らせる・暗く沈める（加算・乗算の重ね方） | Render（blended） |
| 色を作る（0〜1・0〜255・#rrggbb）・2 色を混ぜる・比べる | Color.rgb / rgb8 / hex / mix / channels |
| 色を明るく・暗くする | Color.lighten / Color.darken |
| 縁がふわっと消える光球・煙玉を置く | Render（glowAt）/ fx.json の shape "glow" |
| 放射状の明かり・翳りを 1 枚で置く（松明・スポットライト・vignette。アセット不要） | Render（lightAt / darkAt。組み込みテクスチャは engine の RadialBuiltin） |
| 空・水面・光の帯のグラデを 1 部品で塗る（頂点色つき凸ポリゴン。1px の細い矩形を積まない） | Render（gradPolygon / vgrad） |
| 暗い部屋に光源を置く（穴あきの暗くするオーバーレイ+ハロ） | Light |
| 複数光源＋影（光マップ。Pass に灯りを集めて Multiply で貼る） | Light（lightMapPass / lightMapOverlay）+ App.withPasses |
| 光源を JSON で宣言する（light.json） | LightDoc + Light |
| 壁に影を落とす（単一光源のハードシャドウ） | Shadow |
| 夜のガラス・鏡・磨いた床に姿を映す（明るいところは光として返し、暗いところは影として重ねる） | Mirror |
| 時刻で世界の色を変える（朝の青・夕の橙・夜の紺）・影の向きと長さを回す | Daylight（実例: `templates/rpg-starter/src/View.flix`） |
| 見下ろしの落ち影を置く（接地の暗がり + 時刻で回る日影） | Daylight.groundShadow |
| 光側は暖色・影側は寒色へ近づけて階調を増やす | Color.warm / Color.cool |

## モジュール 1 行紹介

- **Daylight** — 1 日の進み（0〜1）から「空気の色」と「太陽の位置」を決める。色は画面全体に乗算で薄く掛け、太陽からは影の向き・長さ（shadowAt）とドット絵に当てる光の向き（lightStepAt）を導く。暗さ（darkness）を読めば、明かりの点灯と空の色が食い違わない。落ち影は見下ろしが groundShadow（円 1 つ）、横視点が sideShadow（横半径と縦半径を別に取り、足元の高さから左右へだけ伸びる）。
- **Light** — 光源の値（位置・半径・色）から灯りの絵を導く。方式は 2 つで使い分ける:暗くするオーバーレイ方式（items。穴の外は一様な闇。pass 不要で rim・ハロ拡大の質感あり。影は単一光源のみ）と光マップ方式（lightMapPass / lightMapOverlay。環境光のある夜。光源が何個でも光ごとに影が落ちる。App.withPasses と組む。光 A の影は光 B の灯りも消す割り切り）。
- **Shadow** — 光と壁の頂点列から影の四角形を導く（当たり判定の形からも作れる）。
- **Mirror** — 面（夜のガラス・鏡・磨いた床）に映る姿を、ドット絵の走り（PxSprite.Run）から組む。映り込み用の絵を別に描かないので、元の絵を直せば映るほうも一緒に直る。映るかどうかと、どのコマをどこへ合わせるかは呼び側の決めごと。
- **LightDoc** — light.json（光源の質感）の宣言層。暗さ・照り返しフチ・ハロの大きさ・環境光・影の濃さ・光源の並びを JSON に書き、Spec へ読み取る。壁の遮蔽形はゲームの World が持つので含まない。ambient / shadowStrength（光マップ方式用）は 0.19 系から — 古いバージョンのエンジンは読み飛ばして既定になる。
