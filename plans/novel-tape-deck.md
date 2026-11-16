# ノベルの移行の比べを速くする — テープの保存とデッキ（設計の下書き）

- 日付: 2026-11-16
- 状態: **下書き**。デッキは engine の道具を増やすので、作る前にレビュー役に通す。
- 親: [novel-vocab-n4-design.md](novel-vocab-n4-design.md) の 10 章（移行の突き合わせ）・[docs/migrate-diff.md](../docs/migrate-diff.md)・[docs/flow.md](../docs/flow.md)
- 人の方向（2026-11-16）: ① 毎コマの録画をやめて記録で比べ、flow を並べて流す。2 回撮りは engine かゲームが変わった時だけ。
  ② 前の版のゲームの jar をテープと一緒に保存する。③ 再生・一時停止・コマ送り・早送り・頭出しのデッキで、差が出た所だけ並べて見る。
- ① の第 1 段（`bin/fge migrate shoot`）は入れた。この文書は ① の残り（テンプレート側）と ②・③ の設計。

## 1. 測った内訳（血鱗・route_gem・6,583 コマ・30 fps・M 系 12 コア 64 GB）

| 段 | 冷えた時（キャッシュ無し） | 2 回目（render-cache が当たる） | 比べに要るか |
|---|---|---|---|
| JVM の起動・絵と字の読み込み・flow の計算（`Flow.play`。待ちは実時間で待たない） | 1.3 秒 | 1.5 秒 | 要る |
| 音を混ぜて audio.f64（148 MB）に書く | 5〜12 秒 | 5 秒 | 要らない（音は tape.json の sounds・buses で比べる） |
| 全コマの動画（GPU で塗る・ffv1 の frames.mkv 2.6 GB・毎コマの描く命令の鍵） | 55 秒 | 35 秒 | 要らない |
| 比べのコマ: world の層 187 枚（SoftRaster） | 111 秒 | 約 2 秒（写すだけ） | 要る |
| 比べのコマ: all の層 39 枚（SoftRaster） | 27 秒 | 約 0.3 秒 | 画素は比べない（前の版の無い flow で並べるだけ） |
| tape.json・saves.json | 1 秒未満 | 1 秒未満 | 要る |
| mp4 に束ねる（libx264・5 コア） | 40 秒 | 40 秒 | 要らない（`migrate video` で並べる時だけ） |
| 古いセーブの読み戻し（6 枠・JVM 1 回） | 14.5 秒 | 数秒 | 要る |
| `bin/fge migrate diff --strict --times`（13 本・2,220 枚） | 14.5 秒 | — | 要る |

### 1.1 第 1 段（`bin/fge migrate shoot`）の前後（血鱗の 13 本 + 古いセーブ 12 ファイル・写しの作業場で）

| 道 | 冷えた時 | 2 回目（キャッシュが当たる） |
|---|---|---|
| 前: ゲームの Makefile の `migrate-shoot`（1 本ずつ・mp4 も束ねる） | 約 20 分（人の記録） | 855 秒（run2.log の時刻） |
| `shoot --jobs 1`（1 本ずつ・mp4 なし） | 1,154 秒 | 472 秒 |
| `shoot`（既定の 3 本ずつ・mp4 なし） | 978 秒 | **238 秒**（別の回は 402 秒。同じ機械で他の作業の負荷が 60 を超えていた） |

- 2 回目は 3.6 倍速い（855 → 238 秒）。半分は mp4 を止めた分、残りは並べた分。
- 冷えた時は 1.2 倍しか速くならない。どの JVM も SoftRaster（4 本の糸）・GPU の動画の鍵・ffv1 の書き出し（1 本で 340% CPU）で
  コアを食い、3 本でもう 12 コアが埋まる。冷えた時に効くのは 2 章の 1（全コマの動画を書かない）。
- 門: `migrate diff --strict --times` で前と同じ判定（止める違い 0・迷った差 0・比べたコマ 2,220 枚・通らない命令の行 3 行は前の check2 と同じ。
  承認の migrate-accept.json が無いため、check2 も同じ 3 行で落ちる）。
- render-cache は動いている jar の SHA-256 を鍵に入れる（`RenderCache.programDigest`）。jar を作り直すと全部のコマが冷える。
  写しの作業場では 1 回 jar が作り直された（理由は【未確認】）。

JVM は flow ごと・セーブのファイルごとに 1 回ずつ起こす（13 + 13 回）。起動は 1.5 秒なので常駐にする得は小さい。
重いのは「要らない」の行（全コマの動画と mp4 で 1 本 75〜95 秒）と、冷えた時の SoftRaster。

## 2. ① の残り: テンプレート側の変更（Timeline の担当へ渡す粒度）

`templates/sound-novel-starter/src/render/FlowVideo.flix` の `playJob`:

1. **`FLOW_VIDEO=off` で全コマの動画と音を書かない**。`MIGRATE_OUT` がある時に `write`（`writeAudio` と `VideoOut.writeFrames` の全コマ）と
   FLOW_OUT の `writeTape` を飛ばし、`writeMigrate` だけを流す。`painter` は `VideoOut.Painter.KeysOnly` を渡せば型が合う。
   見込み: `playJob` に 1 つの分かれ道（10 行前後）。1 本 44 秒 → 約 8 秒（2 回目）。
   - WhyNot: `FGE_VIDEO_PAINT=none` では代わりにならない — `shootFrames` が `{ gpu = Off, gl = None | settings }` で paint を引き継ぐので、比べのコマの PNG も塗られなくなる。
   - `bin/fge migrate shoot` は `--video` の無い時に既に `FLOW_VIDEO=off` を渡している（今の FlowVideo は読まずに書くので、shoot が消している）。
2. **all の層を前の版が無い時だけ撮る**（任意）。`MIGRATE_ALL=off` で `shootFrames` の層の列から `AllLayers` を外す。冷えた時 1 本 27 秒。
   diff は all の画素を比べないので門は変わらない。ただし nobaseline の頁で並べる絵が無くなるので、基準を撮る回（`migrate-baseline`）は撮る。
3. **Makefile の `migrate-shoot` を `bin/fge migrate shoot` に置き換える**:
   ```make
   migrate-shoot = HEADLESS_RUN='$(HEADLESS_RUN)' "$(ENGINE)/bin/fge" migrate shoot $(1) $(if $(MIGRATE_VIDEO),--video) $(MIGRATE_FLOWS) || code=1
   ```
   `migrate-video` は OLD= の撮り直しで足りるので、基準の video.mp4 は `MIGRATE_VIDEO=1` の時だけにする。
4. 待ちの早送りは要らない — `Flow.play` は待ちを実時間で待っていない（6,583 コマの計算が 1 秒以内）。
5. コマを「ハッシュだけ」にする案は採らない: diff は world のコマを 2 px のずれまで許して画素で比べるので、鍵（drawhash）の一致・不一致だけでは
   合格線（数画素まで許す）を表せない。render-cache が同じ鍵の PNG を写すので、2 回目はほぼ只。

## 3. ② テープと前の版の jar を一緒に保存する

### 何を保存するか（`debug/migrate/<名前>/` に足す）

```
debug/migrate/baseline/
  flows/…・saves/…                 今の記録（そのまま）
  game/                             前の版を流し直すための物
    headless.jar                    build/headless/headless.jar の写し（入口の main 込み・依存も中に入っている）
    jar.manifest                    jar を作った src・flix.toml・lib の指紋（build/headless/jar.manifest）
    assets.manifest                 project.json と assets の SHA-256 の一覧
    assets/・project.json・e2e/      jar の外で読む物（cp -c で写す。APFS なら場所を食わない）
    source.json                     { commit, branch, engineVersion, flix, shotAt }
```

- jar は 56 MB 前後（血鱗の build/headless）。assets は jar に入らないので、assets も一緒に写す（前の版の絵と音で流し直すため）。
- 2 回撮りの省き: `shoot` の頭で、今のゲームの jar の指紋（`bin/fge resident manifest`）と assets の指紋が基準の `game/` と同じなら、
  「engine もゲームも変わっていない」として記録を写すだけにする（`--force` で撮り直す）。人の方向「2 回撮りは engine かゲームが変わった時だけ」を指紋で決める。
- 前の版を流す口: `bin/fge migrate shoot --game debug/migrate/baseline/game <名前> …` で、`java -jar headless.jar` をその `game/` を今のフォルダにして流す
  （FGE_ENTRY は headless-run と同じ）。worktree を作り直さずに前の版を撮り直せる。

### 決めること（レビューで）

- assets を写すか、assets の指紋だけにして git のコミットから戻すか（写すと確実・場所はクローンなら只）。
- `game/` を基準に必ず付けるか、`--keep-game` の時だけか。

## 4. ③ デッキ（`bin/fge tape play` 相当）

### 何を見せるか

`migrate diff` の頁（report/index.html）で「止める違い」「迷った差」を押すと、前と後をその所から並べて流す。録画は無いので、
**保存した jar（②）と記録から、その場で塗る**。

### しおり（頭出しの位置）

- しおりは **beat の頭のセーブ**: flow を流す時に、出来事（line・choice・wait）ごとに World のセーブ（`Saves.toJson` と同じ形）と
  Timeline の再生位置を `bookmarks.jsonl` に 1 行ずつ書く（1 本で数百行・数 MB）。
- 頭出しは、近いしおりを読み戻してから、そこから目的のコマまで flow を流し直す。
- Timeline の中の位置は engine_world の `Timeline.PlaybackLog` の `seekOn`（スキップと同じ: 飛ばした音は鳴らさず、飛ばした所の命令は当てる）と
  `resumeOn`（待ちを明ける）で戻す。新しく足す口は無い見込み【推】。

### 操作

| 操作 | 中身 |
|---|---|
| 再生・一時停止 | 前と後の 2 つの JVM（デッキの常駐）に同じコマ番号を送り、塗った絵を左右に並べる |
| コマ送り・戻し | 1 コマ進める（戻しは近いしおりから流し直す） |
| 早送り | 塗らずに World だけ進め、n コマに 1 枚塗る |
| 頭出し | 頁の差の行・台詞の一覧・しおりの一覧から |
| 差の色 | `migrate diff` の heat と同じ物を重ねる |

### engine に足す口の候補

- `App.Headless` の常駐（`serveJobs`・`bin/fge resident`）に「flow を n コマ目まで流して止まる」「1 コマ進めて塗る」ジョブを足す。
  今の常駐は 1 回流して返すだけ。
- 塗りは SoftRaster（`VideoOut` の Soft の道）か GPU（`GpuShot`）。デッキは 1 コマずつなので GPU で足りる。
- 画面は `bin/fge tape` の頁（plans/tape/spec.md）の再生部を使い回し、動画の代わりに常駐から PNG を取る。

### 既にある物

- `Timeline.PlaybackLog`（playbackLog / resumeOn / seekOn / skipToNextWait → playheadOn）: Timeline の中の頭出し。
- 決定性の門 `make determinism`（bin/determinism.sh）: 実機の道で遊んだ記録が、画面なしの再生で同じ World になるかを見る。デッキの「流し直すと同じ所に来る」の前提。
- `bin/fge tape`: tape.json から頁（帯・台詞・音）を作る。デッキの画面の土台。
- `bin/fge migrate video`: 2 本の mp4 を左右に並べる。デッキができるまでの代わり（`shoot --video` で撮った時だけ使える）。
- render-cache（`~/.cache/flix-render-cache`）: 同じ描く命令のコマは塗らずに写す。

## 5. 残っている問い

- しおりのセーブに Timeline の再生位置まで入るか（今のセーブは beat の頭で取るので入らなくてよい見込み【推】）。
- デッキを頁（ブラウザ）にするか、窓（GL）にするか。頁なら `bin/fge tape` の資産が使える。
