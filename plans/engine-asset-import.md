# 段階 F2: アセットの取り込み（import）（rev2）

rev1 → rev2: 再レビュー 86 点。F1 と `App.freshWorld`（Studio のプレビュー・記録の再生・headless）で watchAsset の f を流す決まり・handler の置き場所・
ContentCache に `.fgetex` を依存として記録させない・予算の門の比べる元・v1 で残る止まり（mipCopyOf の読み戻し）・8192 超え・`make import` の入口を決めた。

rev0 → rev1: レビュー 76 点。登録の絵（project.json の textures）まで取り込みに通すと、STB と ImageIO の解読の違い・2D の論理の大きさ・billboard の regionRect・
GL と CPU への配線で「今の絵を変えない」が守れないので、v1 は glb に埋めた絵だけにして登録の絵は I8 へ回した。
`.fgetex` はレベル 0 だけを持つ形にし、`Texture3d` は変えない。読み直しは `App.watchAsset`（f の effect を広げた新しい関数）1 本に。
パスの正規化・一時ファイルの名前と掃除・知らせ済みの鍵の置き場・固定値のテスト・予算の門・工数（I0 を 0.74.0 で先に出す）を足した。

段階 F（`plans/engine-round7-hdr.md`・v0.73.0 で入った）と段階 G（`plans/engine-round8-linear-color.md`）の間に小さく挟む。
前提は段階 E（`plans/engine-round6-textures.md`）の `Texture3d`・`Mip`・`Gltf.loadTextured`。

用語: 取り込み（import）＝元のファイル（PNG・glb・OBJ）を、描く側がそのまま使える形に作り直す処理。
processed asset ＝作り直した物（Bevy の語）。キャッシュ＝`build/imported_assets/` に置く processed asset のファイル。
鍵＝processed asset のファイル名を決める SHA-256（元の中身・設定・取り込みの版から作る）。

## ねらい

fps3d_lab の起動が読み込みで数秒止まる。大手のエンジンと同じく、重い作り直し（縮小・mip 作り）は**取り込みで 1 回**だけ行い、
起動時と読み直しの時は**作り置きを読むだけ**にする。あわせて、glb に埋めた絵の「最大サイズ」をゲームごと・フォルダごとに書けるようにして、
fps3d_lab の `modeling/shrink_tex.py`（glb の中の絵を 512 に縮める応急）をエンジンの機能で置き換える。

**合格線**:
- 最大サイズを書かないゲームの絵は 1 bit も変えない（make gl-parity の既存の全部の行・テンプレートの reference がバイト一致）。
- キャッシュがあっても無くても、壊れていても、出る絵は同じ（キャッシュは速さだけを変える）。

## 0. 実測（fps3d_lab・engine v0.73.0・家具 OBJ 36 個・絵つき glb 12 個・登録の PNG 14 枚）

依頼の実測（Doc 全体 1.4〜3 秒・OBJ 1.1〜2.3 秒・glb 0.65〜1.2 秒・mip 1024 で約 1.2 秒）を、処理ごとに切り分けた。
engine/src の写しに計測用の main を足して流した（scratchpad。リポジトリと fps3d_lab には書いていない）。同じ JVM で 3 回流し、
**1 回目（JIT が温まる前 = 起動と同じ条件）/ 2〜3 回目**の順に書く。三角 55,802 枚・頂点 167,406 個。

| 処理 | 1 回目 | 2〜3 回目 | 中身 |
|---|---|---|---|
| OBJ の行を words に割るだけ | 80 ms | 30 ms | |
| `Mesh3d.fromObj` ×36 | 470〜580 ms | 160〜220 ms | 内訳の大きい物は下の 3 行 |
| └ `fromPolygons`（List を何重にも作る） | 150〜190 ms | 110〜145 ms | |
| └ `hashOf`（座標を文字列につないで SHA） | 60〜75 ms | 45〜75 ms | |
| `Mesh3d.withBoxUvs(0.6)` ×36 | **1,050〜1,330 ms** | **950〜1,500 ms** | **OBJ の道の大半** |
| └ `pickRows`（座標の写し） | **725 ms** | 720〜770 ms | `Vector.flatMap` で 3 要素の `Vector.slice` を 16.7 万回つなぐ |
| └ uv の並び（`Vector.flatMap` で 2 要素の Vector をつなぐ） | （同じ形） | | |
| └ `computeTangents` | 120〜155 ms | 80〜140 ms | |
| └ `arraysHashOf` + `uvHashOf`（文字列につないで SHA） | 130 ms | 120 ms | |
| └ `splitByFace` | 1 ms | 0 ms | OBJ は多角形ごとに頂点を分けて持つので、分ける頂点がほぼ無い |
| `Gltf.fromGlb` ×12（形だけ・絵を戻さない） | 500 ms | 160 ms | 中で `Vector.flatMap` を 17 か所使う |
| `Gltf.fromGlbTextured` ×12（絵 24 枚・512²） | 510 ms | 580〜610 ms | 差の約 0.4 秒が ImageIO の PNG の解読 |
| `Mip.build`：glb の絵 24 枚（512²） | 490 ms | 350〜590 ms | `halve` がテクセルごとに List とラムダを作る |
| `Texture3d.decode`：登録の PNG 14 枚（512²） | 140 ms | 270 ms | |
| `Mip.build`：登録の PNG 14 枚 | 155 ms | 165〜215 ms | |
| `Texture3d.fromArgb`（SHA）14 枚 | 7 ms | 6 ms | バイトを直に SHA へ流す形なので安い |

読み取れること:

1. **OBJ が重いのは解読ではなく組み立て**。中でも `withBoxUvs` の `pickRows` と uv の並びで、
   「小さな Vector を `Vector.flatMap` でつなぐ」形が 16.7 万頂点で約 1 秒かかっている。これはキャッシュでなく**書き方の直し**で消える。
2. `Mip.build` も同じく書き方（テクセルごとの List）。直せば数分の 1 になる見込みだが、PNG の解読（ImageIO）は直せない。
3. 起動は必ず JIT が冷えた 1 回目なので、残る「解読 + mip 作り + 頂点の組み立て」の数百 ms は、キャッシュを読むだけにする価値がある。
4. 2D の登録の絵（project.json の `textures`）は GL では STB で上げるが、3D の材質が読む時に `Render3d.mipCopyOf` が
   **GPU からレベル 0 を読み戻して `Mip.build` を回す**（部屋に初めて入ったコマで止まる。`shrink_tex.py` の WhyNot にも書かれている）。
   glb の絵も `Render3d.texture3dBound` で初めて描くコマに `Mip.build` する。

### I0 を入れた後の実測（2026-11-02・同じやり方で前後を続けて流した）

| 処理 | 前（1 回目 / 2〜3 回目） | 後（1 回目 / 2〜3 回目） |
|---|---|---|
| `Mesh3d.fromObj` ×36 | 584 / 156〜173 ms | 316 / 98〜107 ms |
| `Mesh3d.withBoxUvs(0.6)` ×36 | 1,149 / 929〜1,127 ms | 195 / 135〜136 ms |
| └ `pickRows` | 727 / 731〜761 ms | 1 / 1〜4 ms |
| └ ハッシュ（hashOf・arraysHashOf・uvHashOf） | 175・271・162 / 46〜73 ms | 4・6・4 / 3〜5 ms |
| `Gltf.fromGlb` ×12（形だけ） | 263 / 175〜176 ms | 201 / 112〜113 ms |
| `Gltf.fromGlbTextured` ×12 | 495 / 436 ms | 446 / 371〜385 ms |
| `Mip.build`：glb の絵 24 枚（512²） | 419 / 258〜268 ms | 66 / 39〜42 ms |
| `Mip.build`：登録の PNG 14 枚 | 156 / 155 ms | 22 / 21〜22 ms |
| `Texture3d.decode` 14 枚（ImageIO） | 142 / 139 ms | 143 / 142〜147 ms（変わらない） |

OBJ の道（fromObj + withBoxUvs）は 1 回目で約 1.7 秒 → 約 0.5 秒。残る大きい物は ImageIO の PNG の解読（glb 12 個で約 0.3〜0.4 秒）と
`computeTangents`（約 0.12 秒）と形の解読（fromObj・fromGlb で約 0.3〜0.5 秒・1 回目）。I2（絵のキャッシュ）と I5（形のキャッシュ）の判断はこの数字で行う。

## 1. 大手のエンジンの作法（短く）

| | 置き場所 | 設定の書き場所 | 作り直す条件 | 最大サイズ・mip |
|---|---|---|---|---|
| Unity | `Library/`（Artifacts。消してよい） | 元の隣の `.meta`（TextureImporter） | 元・設定・依存・importer の版のハッシュ | Max Size・Generate Mip Maps・圧縮はプラットフォームごと |
| Godot 4 | `.godot/imported/<名前>-<md5>.ctex` | 元の隣の `.import`（INI） | 元の md5 と設定 | `process/size_limit`・`mipmaps/generate`・`compress/mode` |
| Unreal | DDC（Derived Data Cache）と cook の出力 | `.uasset` の中のテクスチャの設定 | 元と設定と版の鍵 | Maximum Texture Size・LOD Bias・cook でプラットフォームの圧縮形式へ |
| Bevy | `imported_assets/`（`AssetMode::Processed`） | 元の隣の `.meta`（`processor` と `settings`） | 元・`.meta`・依存のハッシュ・processor の版 | processor が作り直す（`LoadTransformAndSave`）。dev では元を見張って作り直す |

共通する形: **元のファイルは書き換えない・作り直した物は消してよい場所に置く・鍵は中身のハッシュ（更新時刻ではない）・
取り込みの版を鍵に入れる・設定はファイルごとに書ける**。このエンジンもこの形にそろえ、語は Bevy の
「asset processor・processed asset・`imported_assets`」にそろえる。

違えるのは設定の書き場所。元の隣の `.meta` は置かず、**project.json に書く**（§I1。理由は WhyNot に）。

## 2. 決めたこと

言葉: この計画の「mip レベル」はコードの「段」（`Mip.build` の doc の「段 0」）と同じ物。コードのコメントは今のまま「段」を使い、
新しく書く doc とこの計画は「mip レベル」にそろえる。

### 範囲（v1 に入れる物・後に回す物）

| v1 に入れる | 後に回す（理由） |
|---|---|
| I0: 書き方の直し（Mesh3d・Gltf・Mip・ハッシュ） | — |
| glb に埋めた絵の取り込み（maxSize・キャッシュ） | project.json の登録の絵の maxSize（I8。2D の論理の大きさと GL / CPU の配線が大きい。理由は §I8） |
| ゲームが PNG を `Texture3d` として読む関数 `AssetProcessor.loadTexture`（同じ道） | OBJ / glb の形のキャッシュ（I5。I0 の後に測ってから） |
| 読み直し（`App.watchAsset`）・`make import`・`make clean-imported` | 圧縮形式 BC / ASTC（I7。見送り） |

fps3d_lab の重さのうち、登録の PNG 14 枚はもう 512 で、`Mip.build` の分は I0 で数 ms に縮む見込み。
`shrink_tex.py` が手当てしているのは glb の絵だけなので、v1 の範囲で置き換えられる。

### I0. 先に片づける書き方の直し（キャッシュ無しで働く・絵は 1 bit も変わらない）

実測の大半はここで消える。取り込みより先に入れ、入れた後でもう一度測って I1 以降の値打ちを確かめる。
**I0 だけで 1 本のリリース（0.74.0）にしてよい**（形を何も足さず、効果が一番大きい）。I1 以降は次の版（0.75.0）。

- `Mesh3d.pickRows`・`withBoxUvs` の uv の並び・`fromPolygons` の positions / normals / colors / indices を、
  region の `Array` に書いて最後に `Array.toVector` する形へ（`computeTangents` と同じ書き方）。
  `Gltf.readPrimitive`・`placeTangents`・`readSkinAttributes`・`flatShaded` の `Vector.flatMap` も同じ。
- `Mip.halve` を、テクセルごとの List をやめて Int32 の算術だけで書く（平均の式 `(和 + 2) / 4` の切り捨ては変えない）。
- `Mesh3d.hashOf` / `arraysHashOf` / `uvHashOf` を、`Texture3d.hashOf` と同じく**バイトを直に MessageDigest へ流す**形へ。
  - WhyNot: 文字列につないで SHA を取らない — 16.7 万頂点の座標を `Double.toString` でつなぐだけで数十 ms かかる。
  - **`contentHash` の字が変わる**。使う所は GL の頂点バッファの鍵・headless の RenderCache の鍵・
    `SoftRaster.warnNormalMapWithoutUv` の知らせの重複を防ぐ鍵で、どれも絵を変えない。RenderCache は 1 回だけ全部作り直しになる（移行メモに 1 行）。
- 確かめ方: 直す前後で `Mesh3d` の各並びと `Mip.build` の全部のレベルの全部の画素が等しいこと（下の §3 の固定値のテスト）。
  render-all と gl-parity がバイト一致。
- 性能の門（docs/performance.md §1）: pub の形・戻り値は変えない。contentHash は字の中身だけが変わり、doc の約束（同じ中身なら同じ字）は保つ。
- 見込み: OBJ の道 1.1〜2.3 秒 → 0.3〜0.5 秒、`Mip.build` 1 枚 512² が 10〜20 ms → 数 ms（I0 の後に測って計画を直す）。

### I1. 設定の書き場所（project.json）

```jsonc
{
  "import": {
    "maxSize": 0,                                   // 既定。0 = 縮めない
    "overrides": [
      { "path": "assets/models", "maxSize": 512 },  // フォルダか 1 ファイル
      { "path": "assets/models/altar_tex.glb", "maxSize": 1024 }
    ]
  }
}
```

- **パスの決まり**: ゲームのフォルダ（root）からの相対・区切りは `/`。読む側は渡されたパスを root からの相対に直し、
  `\` を `/` に替え、`./` と重なった `/` を 1 つにしてから比べる。
  override の `path` は「同じ字」か「`path + "/"` で始まる」時だけ当たる（`assets/models` は `assets/models_old/x.glb` に当たらない）。
- 決まる順: 一番長く当たる override → `import.maxSize` → 0。glb に埋めた絵は glb のパスで引く（1 つの glb の中の絵は全部同じ設定）。
- `maxSize` の意味: **長い方の辺が maxSize 以下になるまで、mip レベルを上から捨てる**（512 を書いた 1024² の絵は、レベル 1 がレベル 0 になる）。
  2 の累乗でない辺は `Mip.build` と同じく floor(n / 2) で縮むので、結果が maxSize よりかなり小さくなることがある（doc に書く）。
  - `Mip.build` は半分にするのを繰り返すだけなので、縮めた絵の `Mip.build` は元の絵の `Mip.build` のレベル k 以降と画素まで同じ。
    つまり縮めた絵は「新しい元の絵」として扱ってよく、GL と CPU の mip の作り方を何も変えない。
  - WhyNot: 高品質の縮小（Lanczos・sips）を入れない — 縮め方がもう 1 つ増え、CPU（SoftRaster）と GL で縮め方をそろえる仕事が増える。
    `shrink_tex.py`（sips）からの切り替えで見た目がわずかに柔らかくなるかは、I4 で前後を並べて確かめる。
  - WhyNot: 元の隣に `.meta` / `.import` を置かない — 絵ごとのファイルが倍に増え、Blender の書き出しのたびに消えたり残ったりする。
    設定は project.json の 1 か所にあれば Studio のフォームで 1 画面に出せ、フォルダ単位の overrides で数行に収まる。
- 読み方: `AssetProcessor.loadSettings(root)` が project.json の `import` 節だけを読む。
  - WhyNot: `ProjectLoader.ProjectConfig` に欄を足さない — `ProjectConfig` は `GameEngine.EngineConfig` と同じ形にそろえてあり
    （構造的なレコードで `LwjglLayer.withLwjgl` へそのまま渡す）、欄を足すと手でレコードを書いている所が全部止まる。
    同じ project.json を 2 回読むが、数 KB の JSON で 1 ms 未満。
  - Flix の型の欄名は `importSettings` のように予約語を避ける（JSON のキーは `import` のまま）。
- `import` 節は任意（無ければ全部 0）。テンプレートの `project.schema.json` と Studio のフォーム（Studio のリポジトリの側）に足す。
  外形の決まりは docs/doc-conventions.md に従う。

### I2. processed asset とキャッシュ（engine の新しいモジュール `AssetProcessor`）

置き場所: ゲームのフォルダの `build/imported_assets/`（git 管理外・消してよい・次の起動で作り直し）。
ゲームの側で消すターゲットは `make clean-imported`（engine の `make clean-game-builds` は engine のリポジトリの templates と bench の build しか消さない）。

```
build/imported_assets/
  textures/<鍵の頭 32 字>.fgetex
  tmp/                                  ← 書きかけの一時ファイル
```

- **鍵** = SHA-256（元の絵のバイト ‖ 設定の正規の字（`maxSize=512`）‖ 取り込みの版）。
  - 元の絵のバイト: glb の絵はその bufferView のバイト（glb 全体ではない — 形だけ直した glb で絵を作り直さない）、`loadTexture` はファイルのバイト。
  - 取り込みの版は `AssetProcessor` の中の非 pub の定数。`.fgetex` の形・縮め方・解読の決まりを変えたら 1 上げる（全部作り直しになる）。
    段階 G で色の空間（Srgb / Linear）が入ったら、それも設定の字に入れる。
  - WhyNot: 更新時刻で作り直しを決めない — git の checkout・Studio の書き戻し・写しで時刻だけ変わる。`ContentCache` と同じく中身だけを見る。
    元のバイトの SHA は 512² の PNG で 1 ms 未満。
- **`.fgetex` に入れる物**: 縮めた後のレベル 0 だけ（`"FGET"`・版・w・h・ARGB の Int32 の並び・全体の CRC32。リトルエンディアン）。
  mip は今と同じく使う時に `Mip.build` で作る（I0 の後で 512² が数 ms の見込み）。
  - キャッシュが本当に省くのは ImageIO の PNG の解読（glb 12 個で約 0.4 秒）と縮小。レベル 0 だけなら版を上げる理由（halve の式）が減り、
    ファイルは全部のレベルを持つ形の約 3/4（512² で 1 MB・fps3d_lab で約 24 MB）。
  - I0 の後に測り、絵を初めて描くコマの `Mip.build` がまだ目立つ（場面 1 つで 16 ms を超える）時だけ、全部のレベルを持つ形に変える（版を上げる）。
  - WhyNot: KTX2 にしない — 無圧縮の RGBA8 だけなら得が無く、DFD（データの形の記述）を正しく書く手間が増える。圧縮形式（§I7）を入れる時に KTX2 へ移る。
  - WhyNot: Deflate で縮めない — 解凍の時間が読む時間を上回り、ねらい（起動を速く）に反する。
- **レベル 0 を作る解読**: `Texture3d.decode`（ImageIO）のまま。今の glb の絵と同じ解読なので、maxSize 0 の絵は今と画素まで同じ
  （キャッシュを読んでも `Texture3d.fromArgb` で同じ画素・同じ contentHash になる）。
- **書き方**: `build/imported_assets/tmp/` に、名前に pid と乱数を入れた一時ファイルを書き（`Fs.FileWrite.writeBytes`）、
  `Fs.FileWrite.moveWith(..., Set#{MoveOption.AtomicMove})` で置き換える（Flix 0.78 の標準ライブラリにある）。
  同じ鍵は同じ中身になるので、ゲームと Studio のプレビューと headless が同時に書いても、最後に勝った物が正しい。
  - Windows で相手が開いている先への置き換えに失敗した時は、作った物をそのまま使って続ける（下の表の「書けない」）。
  - 一時ファイルの掃除: `Processor` を作る時に `tmp/` の中の 1 時間より古いファイルを消す（他のプロセスが書いている途中の物は消さない）。
    `make clean-imported` は全部消す。
- **読む時の振る舞い**（docs/error-handling.md の使い分け）:

  | 場面 | 振る舞い | 知らせ |
  |---|---|---|
  | キャッシュがある・CRC と版と寸法が合う | 読むだけ | 黙る |
  | キャッシュが無い（初回・掃除の後） | その場で作り（解読 → 縮める）、書いて使う | 黙る（正常系。読み込みの終わりに「取り込み 作った n 件・使った m 件・k ms」を 1 行） |
  | キャッシュが壊れている（magic・版・長さ・CRC が合わない） | 無い時と同じく作り直して上書き | `Log.fellBack("import", パス, "作り直し", 理由)` を 1 行 |
  | キャッシュに書けない（読み取り専用・容量・置き換えの失敗） | 作った物をそのまま使って続ける（fail-open） | 鍵ごとに初回 1 回だけ 1 行（覚えておくのは `Processor` の中の Ref） |
  | 元の絵が壊れている | 今と同じ（glb の絵はその材質を頂点の色で描き 1 行・`loadTexture` は `Err`） | 今と同じ |

  キャッシュの事故で止まることは無い（キャッシュは速さだけを変える）。

- **API**（`AssetProcessor`。取り込みの全部をここに置く）:

  ```flix
  pub mod AssetProcessor {
      /// 取り込みの設定（閉じた型）。
      pub type alias Settings = ImportSettingsData
      /// project.json の import 節だけを読む（無ければ defaultSettings）。崩れている時は Err。
      pub def loadSettings(root: String): Result[String, Settings] \ Fs.FileRead
      pub def defaultSettings(): Settings                       // 全部 0（縮めない）
      pub def maxSizeFor(path: String, s: Settings): Int32

      /// 置き場所（ゲームのフォルダ）と設定の組（閉じた型。知らせ済みの鍵の Ref を持つ）。
      pub type alias Processor = ProcessorData
      pub def processor(root: String, s: Settings): Processor \ IO

      /// 絵のバイトを processed asset にして Texture3d で返す（キャッシュを読む → 無ければ作って書く）。
      /// sourcePath は設定を引くパス（root からの相対に直して比べる）。
      pub def textureOf(p: Processor, sourcePath: String, bytes: Vector[Int8]): Result[String, Texture3d.Texture3d]
          \ Fs.FileRead + Fs.FileWrite + IO
      /// path の PNG / JPEG を読んで textureOf に通す（ゲームが絵を Texture3d として読む関数）。
      pub def loadTexture(p: Processor, path: String): Result[String, Texture3d.Texture3d] \ Fs.FileRead + Fs.FileWrite + IO
  }
  ```

  - テストは `Fs.FileRead` / `Fs.FileWrite` をメモリの Map で受けるハンドラで回す（ディスクを触らない）。
  - engine に置く理由: 3D の読み込み（`Gltf`）が engine にあり、project.json を読む `ProjectLoader` も engine にある（`Util.Json` は標準ライブラリ）。
  - `Texture3d` は何も変えない。返す絵は縮めた画素から `Texture3d.fromArgb` で作るので、`width` / `height` / `contentHash` は縮めた後の物。
    3D の材質は uv が 0..1 なので、元の寸法（論理の大きさ）は要らない。GL の `texture3dBound` も CPU の `sceneTexturesOf` も今のまま
    （contentHash の表で引き、使う時に `Mip.build`）。
  - RenderCache の鍵: 絵は contentHash（縮めた後の画素の SHA）で鍵に入るので、maxSize を変えれば鍵も変わる。足す物は無い。
  - **ContentCache との相性**: `.fgetex` は `Fs.FileRead` を通さず IO で直に読む（`ContentCache.loadOrBuild` が依存として記録しない道）。
    依存として記録するのは元の glb のバイトだけ。WhyNot: `Fs.FileRead` で読まない — 初回に「無い」と記録した `.fgetex` を同じ build で書くので、
    次の 1 回が「中身が変わった」と判定され、キャッシュが揃うまで ContentCache が外れ続ける。
  - **8192 を超える元の絵**: 今と同じく Err（`Texture3d.decode` が辺の上限で止める）。maxSize を書いても縮める前に止まる（doc に 1 行）。

### I3. glb に埋めた絵を取り込みに通す

- `Gltf.loadImported(p: Processor, path)` / `fromGlbImported(p: Processor, path: String, bytes)` を足す（`\ Fs.FileRead + Fs.FileWrite + IO`）。
  `decodeImage` の `Texture3d.decode(viewBytes)` を `AssetProcessor.textureOf(p, path, viewBytes)` に替えた版。中の組み立ては共有する。
- 今の `loadTextured` / `fromGlbTextured` は残す（pub 不変の門。取り込みを使わないゲームの API として）。
- 同じ絵を 2 つの glb が埋めていれば、鍵が同じなので 1 つの processed asset を共有する（設定が同じ時）。
- `Field.TexSize`（段階 F）は縮めた後のテクセルの数を返す。GL も CPU も同じ Texture3d を読むので食い違わない（backend-parity.md に 1 行）。

### I4. fps3d_lab に入れて前後を比べる（ゲーム側の作業）

- project.json に `"import": { "overrides": [ { "path": "assets/models", "maxSize": 512 } ] }`。
- `Controls.loadMeshes`（`ObjMesh.build`）と `loadModels` の `Gltf.fromGlbTextured` を `fromGlbImported` に。`Processor` は `loadDocs` で 1 つ作って渡す。
- `modeling/shrink_tex.py` を外し、`modeling/pre_shrink/` の 1024 の元の glb を `assets/models/` へ戻す（以後は Blender の書き出しのままで良い）。
- 測る物: 起動から最初のコマまで（キャッシュ無し・有り）・部屋に初めて入ったコマの時間・`make render` の 1 枚。
  **v1 で残る止まり**: 登録の絵（project.json の textures）を 3D の材質が読む時の `Render3d.mipCopyOf` の GPU からの読み戻し（`glGetTexImage`）は I8 まで残る
  （`Mip.build` は I0 で速くなる）。部屋に初めて入ったコマの時間のうちこの分を分けて測り、I8 の値打ちを決める材料にする。前後の絵を並べる（sips の縮小と mip の縮小の差を見る）。
- fps3d_lab は別の作業が編集中なので、入れる時にその作業と順番を相談する。

### I5. 形（OBJ / glb）の解読結果のキャッシュ — I0 の後に測ってから決める

- I0 の後の見込みは、OBJ 36 個の `fromObj` + `withBoxUvs` で 1 回目 0.3〜0.5 秒・glb の形 12 個で 0.2〜0.5 秒（JIT が冷えた値）。
- キャッシュにすると、Mesh3d の並び（Float64 のまま。頂点 16.7 万で約 20 MB）を読むだけで数十 ms。
  Float32 に落とさない — SoftRaster が Float64 で読むので、GL と CPU の値が変わる。
- **判断**: I0 の後に起動の内訳を測り、形の分がまだ 0.3 秒を超えていれば入れる。入れる時は `.fgemesh` を同じ置き場・同じ鍵の決まり
  （元の OBJ と .mtl のバイト ‖ `withBoxUvs` の scale のような作り方の引数 ‖ 版）で、`AssetProcessor.meshOf(p, key, build: Unit -> Mesh3d)`（作る関数を渡す）の形にする。

### I6. 走らせながらの読み直し・Studio・headless・parity

- **watchFile の f は `Fs.FileRead` だけ**で、PNG の解読（ImageIO）とキャッシュの書き込みが要る glb の読み直しはできない（fps3d_lab の `reloadMeshes` の WhyNot もこれ）。
  **`App.watchAsset(path, f: w -> w \ {Fs.FileRead, Fs.FileWrite, IO}, app)`** を足す。違いは f の effect だけで、見張り方（withDebug の時だけ・約 0.5 秒ごと・登録順に発火）は watchFile と同じ。
  - App の Rec に見張りの列をもう 1 本持ち、`App.loop`（IO を持つ）から呼ぶ。`Processor` はゲームが f の中に閉じ込めて渡す（App は取り込みのことを知らない）。
  - 取り込みの失敗の扱いは f の責務（watchFile と同じく、今の World を返す fail-open を勧める）。
  - WhyNot: watchFile の f の effect を広げない — 全部のゲームの読み直しの関数の型が変わる（pub 不変の門）。新しい関数を足すだけなら既存の型は変わらない。
  - WhyNot: 「見張りの回し手が先に取り込みを流し、f はキャッシュを読むだけ」にしない — App が拡張子を見て glb を開く結びつきと、読むだけの API がもう 1 組要る。
- **F1 と World の組み直しの決まり**（新しい API は足さない）: F1 は今の reload（`withDocTable` の `DocTable.reloadAll` か `reloadOn` の 1 枠）を流した**後に**、
  watchAsset の列の f を登録順に全部流す。`App.freshWorld`（Studio のプレビュー・`/start`・記録の再生と headless の `buildCached` が使う）も同じ規則で、
  「reload か watch の f」の後に watchAsset の列を流す。
  - `freshWorld` の effect は広げない（pub 不変の門）。非 pub の `freshWorldWithAssets` を足し、`App.loop` と headless の組み立てはそちらを呼ぶ。
    `Fs.FileWrite` と IO を受ける handler は `App.loop`（今の `applyWatch` / `applyReload` の `{Fs.FileRead, IO}` の外側）と headless の側に 1 つずつ置く。
  - 記録の再生（`recordedReload`）でも watchAsset の f を同じく流す（再生の World が glb を持たないと、記録した時と絵が変わる）。
  - I4 の「`Processor` は `loadDocs` で作る」は、`loadDocs` が呼ばれる effect の中に `Fs.FileWrite` があるかを I6 の初めに確かめ、無ければ起動の main で作って渡す。
- **Studio**: Studio のプレビューは headless で同じ `build/imported_assets/` を読む（置き場所はゲームのフォルダの下なので同じ）。同時に書いても安全（§I2）。
  Studio のフォームに `import` 節を出す（Studio のリポジトリの側）。
- **headless の描き出し（SoftRaster）**: ゲームの読み込み（`loadDocs` など）が `fromGlbImported` を呼べば、GL と同じ Texture3d が届く。engine_tools は何も変えない。
- **gl-parity**: GL と CPU が同じ Texture3d を読むので、既存の行は変わらない。足す行は `importedMaxSize`（A 段階・バイト一致。1024² の絵に maxSize 512 を書いた 3D の材質）。
- **ゲームの書き出し（Studio の export）**: processed asset を同梱するかは論点（§5）。同梱しなくても初回の起動で作られる。

### I7. 圧縮形式（BC / ASTC）— 今回は見送る

- 対象の Mac の OpenGL は 4.1 で止まっていて、BC7（BPTC）は 4.2 の機能・ASTC は Mac の OpenGL に出ていない。使えるのは BC1〜3（S3TC）だけ。
- CPU の描き出しで同じ画素を出すには CPU 側に BC の展開を書く必要があり、展開の丸めが GPU ごとに違う（parity が近似になる）。
- JDK に BC のエンコーダは無く、外の道具を足すことになる。
- 今の問題は起動の時間で、GPU のメモリは足りている（fps3d_lab で 512² × 38 枚 ≈ 53 MB・mip 込み）。
- **見直す時**: VRAM が足りなくなった時か、2048 以上の絵を多く使うゲームが出た時。その時は `.fgetex` を KTX2 に替えて版を上げる。

### I8. project.json の登録の絵の maxSize — 後のフェーズ

登録の絵は 2D（sprite・UI・billboard）と 3D の材質で 1 枚の GPU の絵を共有していて、縮めると次が全部要る。v1 に入れない理由はこれ。

- **論理の大きさ**: Drawable の uv は 0..1 の比なので切り出しは変わらないが、描く大きさを画素の寸法でなく論理の大きさから取る所
  （SoftRaster の BufferedImage の幅・`RenderAsset.TextureInfo` の width を読む 11 か所）を全部洗い、「論理の大きさ」と「テクセルの数」のどちらを読むかの表が要る。
  `Billboard3d` の `regionRect` はテクスチャの px なので、GL と CPU の両方で論理の大きさとの換算が要る。`Render3d.mipCopyOf` は `t#width / height` を読み戻しの寸法に使っている。
- **解読のずれ**: GL は STB（`hasAlpha=false` なら RGB で読む）、CPU と processed asset は ImageIO。PNG の α・JPEG の IDCT で画素が違いうるので、
  processed asset で GL の絵を置き換えると maxSize 0 の絵まで変わりかねない。`hasAlpha=false` は α を 255 に固定し、STB で読み戻した画素との一致をテストで押さえる。
- **配線**: 起動時の取り込みの結果（名前 → processed asset）を Render3d の State と SoftRaster の MipSource へ渡す値と、それを通す pub の形（LwjglLayer・RenderConfig）の門の判定。
- 入れる時の条件: 登録の絵を縮めたいゲームが出た時（今の fps3d_lab の登録の絵は 512 で足りている）。

## 3. テスト・検証・文書

- engine（I0）— **固定値で残す**（後の退行も止める）:
  - 小さな OBJ（四角・五角形・vt の有無）の `fromObj` + `withBoxUvs` の各並び、小さな絵（4 × 4・3 × 5・1 × 7）の `Mip.build` の全部のレベルの画素を、
    直す前の実装で出した値として書き込む。
  - contentHash: 同じ中身で同じ字・1 つの座標が違えば違う字・uv の無い形と有る形が違う字。
- engine（I1〜I3）:
  - パスの正規化: `./assets/models/a.glb`・`assets\models\a.glb`・`assets//models/a.glb` が同じ・`assets/models` が `assets/models_old/x.glb` に当たらない・一番長く当たる override。
  - maxSize の意味: 1024² に 512 → レベル 0 が `Mip.build` のレベル 1 と同じ画素。1000 × 600 に 512 → 500 × 300。maxSize 0 → `Texture3d.decode` と同じ画素・同じ contentHash。
  - `.fgetex` の往復（書いて読むと画素と contentHash が同じ）。
  - 鍵: 元の 1 バイト違い・設定違い・版違いで別の鍵。同じ物は同じ鍵。
  - 壊れたキャッシュ（magic・版・長さ・CRC）で作り直し、1 行知らせる。書けない時は作った物で続け、鍵ごとに 1 回だけ知らせる。
  - 2 つのスレッドが同じ鍵へ同時に書いても、読めるのは完全なファイルだけ（一時ファイルの名前がぶつからない）。古い一時ファイルを掃除し、新しい物は残す。
  - glb: 同じ絵を 2 つの glb が埋めていたら 1 つの processed asset を共有する。`fromGlbImported` の maxSize 0 の結果が `fromGlbTextured` と同じ。
- engine_world: `watchAsset` の f が保存のたびに呼ばれ、watchFile と同じ順に発火する。
- gl-parity: `importedMaxSize`（A 段階）。
- フェーズごとの合格線: make gl-parity の既存の全部の行と render-all がバイト一致。
- **予算の門**（docs/performance.md）: 比べる元は「I0 の後・今の素材（`shrink_tex.py` で 512 に縮めた glb）・取り込み無し」の起動。合格線は 2 本:
  キャッシュ有り（1024 の元の glb）≦ 比べる元、キャッシュ無しの初回（1024 の元の glb を解読して縮める）≦ 比べる元 ＋ 1 秒。I4 で測る。
- engine_world（追加）: F1 と `freshWorldWithAssets` が reload の後に watchAsset の f を流す・記録の再生でも流す。
- engine（追加）: `ContentCache.loadOrBuild` の中で `fromGlbImported` を 2 回呼ぶと、2 回目は前の値が返る（`.fgetex` が依存に混ざらない）。
- 性能の確かめ: §0 の計測を `engine_tools` の小さなコマンド（`bin/fge load-profile <ゲーム>`・処理ごとの ms）として残すかは I0 の時に決める
  （残すなら make help と AGENTS.core の早見表に 1 行）。
- docs: `docs/assets.md`（新しく。取り込み・置き場所・設定・作り直す条件・消してよいこと）・backend-parity.md に 1 行（TexSize は縮めた後）・
  AGENTS.core の早見表に 2 行（`import` 節と `Gltf.loadImported` / `AssetProcessor.loadTexture`、`App.watchAsset`）。

### make のターゲット・agent-eval・forbid

- `make import`（ゲームの足元。CI と、初回の起動を待ちたくない時に）: ゲームの jar を headless で起動する入口（`bin/headless-run` と同じ道）に
  `--import` を足し、`AssetProcessor.loadSettings(root)` で設定を引いて `assets/` の下の `*.glb` を全部 `fromGlbImported` に通す
  （ゲームの読み込みを流すのではなく、engine だけで glb を拾う）。`make clean-imported` は `build/imported_assets/` を消す。どちらも `make help` に 1 行。
- agent-eval のお題 1 本（`agents-pack/agent-eval/engine.json`）: 「glb の絵が大きくて起動が遅い。絵を 512 にしたい」
  → 当たり = project.json の `import.overrides` に maxSize を書き、`Gltf.loadImported` / `fromGlbImported` を使う（PNG を縮めるスクリプトを書かない）。
- forbid.json の候補: ゲームの `.flix` の `Gltf.fromGlbTextured` / `Gltf.loadTextured` → `Gltf.loadImported`（engine の中とテストは除く・
  `whenProject` で project.json に `import` 節があるゲームだけ）。強すぎるならお題だけにして forbid は見送る（実装の時に決める）。
- 移行メモ: 0.74.0（I0）に「`Mesh3d.contentHash` の字が変わる（絵は同じ・RenderCache は 1 回作り直し）」。
  0.75.0（I1 以降）に「project.json に `import` 節を書ける（書かなければ今と同じ）」「`shrink_tex.py` のような縮める手当ては外してよい」。

## 4. 進め方と工数

| フェーズ | 中身 | 工数（目安） | 合格線 |
|---|---|---|---|
| I0 | 書き方の直し（Mesh3d・Gltf・Mip・ハッシュ）→ 0.74.0 | 1.5〜2 日 | 固定値のテスト・render-all と gl-parity がバイト一致・§0 を測り直して I2 のレベルの持ち方と I5 を決める |
| I1 + I2 | 設定・パスの正規化・`AssetProcessor`・`.fgetex`・テスト | 2〜2.5 日 | §3 の engine のテスト |
| I3 | glb の絵（`fromGlbImported`）・parity の行 | 1 日 | `importedMaxSize`・既存の全部の行がバイト一致 |
| I6 | watchAsset・F1 と freshWorldWithAssets・handler・make import / clean-imported・Studio の確かめ | 1.5〜2 日 | engine_world のテスト・Studio で glb を書き出し直して反映を見る |
| I4 | fps3d_lab に入れて前後を比べる | 0.5 日 | 起動・部屋に入るコマの時間・絵の前後・予算の門 |
| 文書 | assets.md・移行メモ・早見表・agent-eval のお題・make help・api-digest | 0.5 日 | `make agent-eval ONLY=<お題>` が当たる |
| I5（要れば） | 形のキャッシュ | 1〜1.5 日 | I0 後の計測で 0.3 秒を超える時だけ |
| I8（後） | 登録の絵の maxSize | 3〜4 日 | §I8 の表と配線 |

v1（I0〜I4・I6・文書）で 7〜8.5 日。I5 を入れると 8〜10 日。

## 5. 人に決めてほしいこと

1. **I0 だけを先に出すか**: 書き方の直しだけで OBJ の時間の大半が消える見込み。I0（0.74.0）→ 測り直し → I1 以降（0.75.0）の順でよいか。
2. **v1 の範囲**: glb に埋めた絵（と `AssetProcessor.loadTexture`）だけにし、project.json の登録の絵の maxSize を後（I8）に回してよいか。
3. **設定の書き場所**: project.json の `import` 節（フォルダ単位の overrides）でよいか。大手のように元の隣に `.meta` を置く案もある。
4. **maxSize の縮め方**: mip レベルを捨てる（GL と CPU がそろう・sips よりわずかに柔らかい）でよいか。
5. **キャッシュの置き場所**: ゲームの `build/imported_assets/` でよいか。
6. **ゲームの書き出しに processed asset を同梱するか**: 同梱すれば配った先の初回起動も速い。しなければ配る物が小さい。
7. **圧縮形式の見送り**（§I7）でよいか。
8. **段階の名前**: 「段階 F2」として段階 G の前に挟む扱いでよいか。
