<!-- rules:core -->
# 絵の下限

`RawDraw.box` を並べただけの画面は未完成。どの画風で満たすかは自由で、次の 5 つを満たす。

1. 面に階調か質感がある（ベタは「ここは平ら」と決めた後の選択。1px の面を積んだ疑似グラデーションは使わない）
2. 主役が背景から分離して読める（明度差だけで足りるならそれでよい）
3. 層が分かれている（奥・主役・手前。奥行きが要らなくても情報の優先順位は絵に出す）
4. 時間が流れている（静けさが画風でも揺れを極小にするだけでゼロにしない。動く値は `Curve` か `EcsTween.Easing` を通す）
5. 形が物として読める（シルエット・部品の接続・接地・比率。記号が画風なら記号として一意に読める）

- **画風を先に決めて `AGENTS.local.md` に 2〜3 行**（何を見て育った絵か・色・何をしないか）。既定の画風は無く、
  テンプレや他のゲームの見た目を持ってこない。満たせない性質は、理由をそこへ書いて例外にする。
- 先に読む物: ドット絵は `.claude/skills/pixel-art/SKILL.md`（表のお題の行だけ）・格子に乗らない絵は
  `.claude/skills/smooth-render/SKILL.md`・新しい画面の画風決めと部品探しは engine の `docs/art-ref/visual-dict.md`（box と circle で組み始める前に節だけ引く）。

## 良し悪しは人が決める

- 作った・変えたら描き出して（`make render SHOT=<場面>`）人に見せ、確認を取る。「良い絵になりました」で締めない。
  自己批評の手順は `/critique-render`。
- 直す所が複数見えたら、目立つ順に候補を 3 つまで出して番号で選んでもらう（一度に直すのは 1 つ）。
  落ちる・黒い穴・スナップショットの退行だけは聞かずに先に直す。

## 絵の周回

- 周回は `bin/fge rounds snap <名前> <PNG か sprite.json> <台本>` で残し、出る案内に従う（止まる周・聞くこと・上限は口が言う）。
- 呼び出す側は prompt に「N 周まで・直せなければ報告へ」と書かない（口の案内を上書きする）。この節を指すだけにする。
<!-- /rules:core -->

以下は詳しい本文（`.claude/rules/drawing.md` には上の芯だけが出る）。

## 5 性質の手の例

`RawDraw.box` を並べただけの画面は未完成として扱う。次の 5 性質をすべて満たすこと。
**どの画風で満たすかは自由**。下は手の一例で、選択肢の全部ではない。

名前空間（`RawDraw` = 図形プリミティブ）は「気軽に使うと足かせになる」摩擦を作る仕切り。
満たすべき造形の下限は本書が定め、実際に絵が良いかどうかは `/critique-render` の目視が決める。

| 満たす性質 | 手の例 |
|---|---|
| 面に階調か質感がある | `ShaderDoc` + `Render.shaderFill` / `Render.vgrad`・`gradPolygon` / `Render.lightAt`・`darkAt`（放射の明かり・翳り）/ `Material`（粒・きらめき・染み）/ `Render.striped`・`checker` / `PxShade` のディザ |
| 主役が背景から分離して読める | `PxShade`（ふち光・接地影）/ `Render.lightAt`・`darkAt` / `Render.glowAt` / `Render.outline` / 明度差・色相差 |
| 層が分かれている（奥・主役・手前） | `ZStack` の木（奥→手前に積む・`topLayer`）+ `SortingLayer` の表 / 見下ろしは `ZStack.zIndex(Depth.orderAt(y), …)` / `Transition` の覆い / `Pass`（光マップを別の紙に集めて Multiply で本編に掛ける） |
| 時間が流れている | `Fx`・`FxDoc`（粒）/ `Sway`（揺れ）/ `Anim`（コマ替え）/ `Curve`（sine・tri・arch01・pieces・dampedSpring）/ `Scatter` / `Daylight` |
| 形が物として読める（シルエットだけで何か分かる / 部品同士の接続が破綻していない — 入り口・持ち手・関節 / 接地している / 比率が対象らしい） | シルエットの描き出し（`HeadlessRender.silhouettePng` — 対象を黒・背景を白で描き出して、形だけを取り出して目視する） |

記号・幾何が画風なら 5 つ目は「記号として一意に読める」で判定する（接地・関節は具象物の場合の言い換え）。
場面の中に人を置いて光と影をそろえるなら `docs/art-ref/figure-drawing.md` の順序で決める。

光と影で色そのものを分けたいときは `Color.warm` / `Color.cool`。
「暗背景 + 加算グロー + パーティクル + ビネット」は手の**一例**で、毎回それを出すと同じ顔のゲームが並ぶ。

## 部品を選ぶ前に辞書を引く

box と circle だけで組み始めたら、それは辞書を引かなかった証拠。
`RawDraw.star` / `ellipse` / `sector` / `ngon`、`Render.vgrad` / `gradPolygon` / `striped` /
`checker` / `turned` / `clipped`、`PxShade`、`Material`、`Scatter`、`Mirror`、`Daylight` は
**すでに実装もテストもある**。「無いから手組み」の前に必ず一覧を見る。

- 技法 → 部品の翻訳表: `docs/art-ref/visual-dict/reference.md`
- 採用ゼロ〜1 の部品一覧: `docs/art-ref/visual-dict/unused-parts.md`
- 画風の決め方と手順: `docs/art-ref/visual-dict.md`
- シェーダーの語彙（Field / Shade の全 kind）: `docs/shader-doc.md`
- 逆引き全体: `make module Q=<語>`（目次は `docs/module-index.md`）

## この画面の画風

同じゲームの `AGENTS.local.md` の画風の節が正（色 3 つ・やらないこと 1 つ）。
場面ごとに画風を変えるゲームでは、そこが指す `docs/style-<slug>.md` が正。
どちらも無ければ**先に書いてから**描き始める。

画風はゲームごとに決め直す物で、既定は無い。**テンプレどうしで画風をそろえない** —
揃えると「この画風が正解」という手本になってしまう。

## ドット絵（`*.sprite.json`）

**画素を 1 つ置く前に `.claude/skills/pixel-art/SKILL.md` を読み、表からお題の種類
（キャラ・敵・歩き・小物・背景・地面タイル）の行のファイルだけを読む**。読まずに打った絵はここで差し戻す。
`docs/art-ref/` の長い参考（色の予算・タイル地形・オートタイル・大きい物の描き方は `retro-pixel.md`、
顔と四足は `px-character.md`、3 面図からの歩きは `carve-sprite.md`）は既定では読まない。
pixel-art の「困った時」の表から、その節だけを引く
（描き比べで、全部を読ませた組は読む量が 50 倍で質は上がらなかった。2026-10-16）。

`legend` に書いた意味色キーは、`*.theme.json` のトップレベル・`paletteFile` の指す色票・
sprite Doc 直下の `palette` のどれかに**実体が無いと Studio が仮色で塗る**
（編集画面と実機で配色が食い違う）。

## 画素の格子に乗せない絵（シェーダーの面・なめらかな輪郭・高解像度）

**面を `ShaderDoc` で塗る前・なめらかな輪郭で絵を組む前に
`.claude/skills/smooth-render/SKILL.md` を読む**（エッジの硬さの使い分け・面積と彩度・
質感の重ね方・なめらかな面に出る縞（banding）の消し方）。
ドット絵の作法（色数の切り詰め・ディザ・タイル）をここへ持ち込むと品質が落ちる。
`Field` / `Shade` の語彙そのものは `docs/shader-doc.md` が正。

## 絵の周回の理由

局所の欠陥（拡大して見つけた物）を潰し続ける周回は、費用を積むだけで絵が良くならない — 悪化すらする。
効くのは**作りを変えた周**と**原因を特定して直した周**だけで、どちらに当たるかを判定できるのは絵を見る
依頼主だけ（実測: 2026-08-15 の style_lab）。だから `bin/fge rounds` は r2 で止めて聞く。

## 機械で確かめる（人に見せる前の下ごしらえ）

下限を満たしているかだけは、どの OS・どのエージェントでも機械が見られる。
**これが通っても「絵が良い」ことにはならない。**
下の 4 つは、ファイルを書いた直後にフック（`bin/fge hook-art-edit`）が書いたファイルだけに走らせ、
失敗したときだけ Claude へ返す（`.flix` は view・`*.sprite.json` は palette と sprite・`*.anim.json` は anim）。
絵を描く View を書いたときは、セッションに 1 回だけ `.claude/rules/drawing.md` を指す 1 行も返す。

```
bin/fge view [ファイル...]   # 矩形と円だけになっていないか
bin/fge palette              # 意味色キーが色票から解けるか
bin/fge sprite [ファイル...] # ドット絵の画素の並び(浮き・階段・細長さ・色数)
bin/fge anim [ファイル...]   # コマ間の飛び・体積・接地と 4 方向のそろい
```

`make lint-view` / `make lint-palette` / `make lint-sprite` / `make lint-anim` でも同じ。
lint-sprite の意図的な例外は、スプライトに理由付きで
`"lint-sprite": "対象外(orphan) — 火の粉は浮かせたい"` と書く(黙って除外はしない)。

### シルエット生成（造形が怪しいときの材料づくり）

「形が物として読める」が怪しいときは、対象を黒・背景を白だけにして生成すると、
色や質感に紛れていた形の破綻（浮き・つながらない接続・崩れた比率）が浮き上がる。
既存の描き出しの配管（`docs/headless-render-recipe.md` の cfg と描画コマンド列）にそのまま流せる:

```flix
// 既定は「主役の z-index の範囲だけ」= world の範囲(ゲームの絵)。UI・HUD は形の検査の対象外。
HeadlessRender.silhouettePng(cfg, HeadlessRender.SilhouetteScope.WorldBand, drawables, polygons, "scene_sil")
```

`SilhouetteScope.All`（全アイテム黒）も選べるが、画面全体が 1 つの塊に融けて個々の形は
見えなくなるので、**用途は画面全体の重心確認に限る**。
形の良し悪しを決めるのは目視のまま — 機械がやるのは「見やすい材料を出す」まで。
