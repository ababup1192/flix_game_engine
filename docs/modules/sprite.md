# ドット絵（sprite.json・コマ送り・アトラス）

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| スプライトをコマ送りする | Anim |
| ドット絵を文字格子(*.sprite.json)で宣言して描く | PxSpriteDoc / PxSprite（実例: `templates/game-starter/assets/`配下の `*.sprite.json` + `templates/game-starter/src/Palette.flix`） |
| ドット絵のコマの大きさを知る（当たり・置き場所を絵に追随させる） | PxSprite.sizeOf / PxSpriteDoc.gridSizeOf |
| ドット絵の塗りに光を当てる（ふち光・接地影・ディザ・地肌の粒） | PxShade（実例: `templates/game-starter/src/ThemeDoc.flix`） |
| ドット絵を握るところで回す・左上でそろえて並べる | PxSprite.drawQuadTurned / drawQuadTopLeft |
| 生成したドット絵アトラスを名前付きテクスチャとして使う（1 体 = 1 クアッド） | App.withSpriteAtlases（実例: `templates/tidepool-starter/src/Main.flix`） |
| ドット絵の輪郭をにじませない（カメラと頂点を画素の升目に載せる） | App.withPixelSnap / Render.snapped（実例: `templates/rpg-starter/src/Game.flix`） |

## モジュール 1 行紹介

- **Anim** — スプライトシートのコマ送りを「時刻の純関数」で導く。
- **PxSpriteDoc** — *.sprite.json（文字格子+意味色キー+名前付きコマ+anchor+loop）を読む fail-open の Doc 層。loop はコマの回し方の宣言（forward / pingpong / once・省略時 forward）で、frameIndexAt が通し番号をコマ番号へ写す。宣言が無いと往復のコマ列と本物の破綻を数値で見分けられない（bin/fge anim）。
- **PxSprite** — PxSpriteDoc のコマを box 列（横連続の同色文字は 1 矩形に結合・既定）または drawQuad（アトラス 1 クアッド・opt-in）で描く。色は resolver（キー→実色）が解決。drawQuad の scale は整数のみ（box 列とのバイト一致保証のため）。
- **PxShade** — 文字格子のドット絵に「塗りの仕上げ」を 1 度だけ掛ける純粋な filter（ふち光・接地影・ディザ・地肌の粒）。絵は平らに塗り、光の当て方は後から重みで指定する。掛けるのは読み込み直後の 1 回だけなので走行中の負荷は増えない。
- **PaletteExport** — 導いた意味色キーの実色を色票 Doc（*.palette.json = version / note / colors）として書き出す。Studio のドット絵エディタが legend の名前を解けるようにするためだけの物で、ゲームの絵はここを読まない。fromKeys（意味色キーの列 × resolver → 表）と build（純粋・文字列）と write（Fs.FileWrite）。
- **PxSpriteAtlas** — PxSpriteDoc×resolver を 1 枚のアトラス画素（ARGB+コマ→矩形の目次）に生成する純関数。GL（RenderTexture.loadTextureFromPixels）と PNG（SoftRaster.writeRadialPng）が同じ Baked を読む。
