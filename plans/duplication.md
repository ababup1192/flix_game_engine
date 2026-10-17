# 重複（62 点）を消す — 設計

## この設計が答える問い

「重複は消すべきか」ではない。**どの重複を消し、どの重複を残すか、その線をどこで引くか**。

NOTES.md の材料には既に「触らない方がいい重複」という節があり、線は暗黙に引かれている。
ここでやるのは、その線を基準として明文化し、**個別の直しをその基準の適用として導く**こと。
逆（直したいものを先に決めて、後から理屈を付ける）をやらない。エラー処理の回と同じ進め方。

**基準はこの設計書で終わらせない。** エラー処理の回が `docs/error-handling.md` と
`bin/lint-fallback.py` の EXEMPT 一覧を残したように、この回も `docs/duplication.md` と
**「残した重複の一覧」**を残す（下の「この回が残すもの」）。plans/ の中だけに書いた基準は、
次に「似た関数が 2 本ある」に出くわす人には届かない。

---

## 判定の単位

基準を当てる前に、**何を 1 つの重複と数えるか**を決める。ここが空白だと、切り分け方しだいで
どちらの結論も作れてしまう。

**単位は「同じ引数から同じ値を出す式のまとまり」。** 関数まるごとでなくてよい。
関数全体では差があっても、差を引数か型に出せる部分があるなら、**その部分を切り出してから**
基準を当てる。各裁定の冒頭に、その裁定が何を単位にしているかを書く。

---

## 基準

**重複を消すか残すかは「差が読めるか」で決める。行数では決めない。**

3 層に分かれる。門を通らないものは判定へ進まない。

### 門 0 — その API は誰が呼ぶか

**`pub` の振る舞いと名前は変えない。** 外部リポジトリ 11 本が呼びうるので、呼ぶ側を原理的に
確かめ切れない。repo 内を全部読んで「変えても大丈夫そう」でも、変えない。

private は呼ぶ側がこのリポジトリに閉じている。確かめてから自由に変えてよい。

### 門 1 — その対象は生きているか

そのコードを通るテストがあるか、`make render` の絵に現れて SHA が守っているか。
**どちらも無いなら、それは「壊れていないコード」ではなく「誰も実行していないコード」。**

→ **統合する前に「消すか」を先に決める。** 死んだコードを整備するのは、重複を 1 つ減らして
保守対象を数百行増やす取引になる。テストを足して整備するのは、存廃が決まった後。

この門は D-3（`legacy/MapResource`）と B/C（`Material` 系）の両方に当てはまる。
**同じ事実には同じ結論を出す。**

### 判定 2 — 差が観測できないなら、消す

実際に渡されうるどんな入力を与えても違いが出ないなら、それは重複。1 本にまとめる。

害は行数ではない。**読む人は「違うはずだ」と思って探し、何も見つからずに時間を失う**。
NOTES.md が「その差が意図か事故か読めない」と書いたのはこれ。

### 判定 3 — 差が観測できるなら、残すかを問う。残すなら差を機械が読める形で言う

呼ぶ側の条件が本当に違うなら残す。**ただし差は次の 3 つのどれかで言う。**

1. **型**（引数の位置に出す。`arcStrip` の `segs` と張り角）
2. **名前**（`Float64` 経由であることが名前から読める、など）
3. **絵の SHA / GLSL とのバイト一致が守っている**（テストか reference PNG が、その差を
   変えたら赤くなる形で固定している）

**コメントは証拠に採らない。** `docs/error-handling.md` 決まり 2 が同じことを言っている —
「判定に doc コメントを使わない。そう書けば何でも通ってしまい、決まりが違反を裁けなくなる」。

3 番目が要る理由: このリポジトリには「歴史的な絵とバイト一致する式」という、型でも名前でも
言えない差が実在する（`DualGrid.flix:123` の `hash` が `Hash01` と別式なのは絵の再現のため、
`ShaderGen` の `6.2831853` が 7 桁なのは GLSL 側と厳密一致させるため。`TestShader.flix:377-382`
がそう宣言している）。**この 3 つのどれでも言えない差は、残す資格がない（＝消す）。**

### 打ち切り 4 — 統合が届かないなら、打ち切る。打ち切りを記録に残す

パッケージ依存の向きで届かない、または型で守られている（exhaustive match で拡張漏れが
コンパイルエラーになる）なら、統合しない。

記録を残さずに終わらせない。**`docs/backlog.md` へトリガー付きで起票する。**
このリポジトリには既に「トリガー付きで将来作業を置く」制度がある（`backlog.md` 冒頭の規約）。
新しい置き場を発明しない。

名前を分ける作業（`numAt` の同名衝突、`*Or` の綴りの重複、`Arc.tau` と `Vec2.tau`）は
門 0 に当たるので**この回ではやらない**。命名の回でリリースとセットにする。

---

## 適用

### F. `clamp01` ほか 0〜1 の道具（判定 2）— 最優先

**単位: 関数まるごと。**

`Num.flix:10` に `pub def clamp01` があり、doc に「書き方が少しずつ違うと結果も少しずつ違う。
同じ答えを全員が使えるよう 1 箇所に置く」と、この設計が言いたいことがそのまま書いてある。
それでも **8 本の private な再定義**がある:

| 場所 | 本体 |
|---|---|
| `engine/src/core/Num.flix:10` | **pub。統合先** |
| `engine/src/ShaderEval.flix:425` | `Float64.max(0.0, Float64.min(1.0, x))` |
| `engine/src/render/RadialBuiltin.flix:79` | 同 |
| `engine_world/src/Transition.flix:42` | 同 |
| `engine_world/src/Lifetime.flix:34` | 同 |
| `engine_world/src/Depth.flix:43` | 同 |
| `engine_world/src/Daylight.flix:174` | 同 |
| `engine_world/src/Fx.flix:254` | 同 |
| `engine_tools/src/RadialGlow.flix:70` | 同 |

（`engine/src/core/Color.flix:122` の `clamp01` は `Float64 -> Float32` で**戻り型が違う別物**。
判定 3 の側なので、これはまとめない。）

同じ調査で出た兄弟:

- `ShaderEval.flix:427` の `lerp` は `Num.lerp`(:35) と一致 → まとめる
- `fract` は `Num.fract`(:19) のほかに **5 本**（`ShaderEval.flix:423` / `Curve.flix:10` /
  `SfxSynth.flix:23` / bench 2 本）。engine / engine_world / engine_tools の 3 本をまとめる。
  **bench の 2 本はまとめない** — bench はエンジンの外から呼ぶ計測台で、まとめると計測対象に
  エンジンの都合が混ざる（判定 3 の 1 番: 別パッケージであることが差を言っている）
- `ShaderDoc.smoothstepF`(:367) と `ShaderEval.smoothstep`(:432) は clamp01 のインライン展開以外
  バイト一致。ただし **`Num.smoothstep` は存在しない**。まとめるには engine に新しい pub を
  生やすことになり、これは重複解消ではなく **engine API の拡張**（AGENTS.md の事前相談の対象）。
  → **この回ではまとめない。**「人へ聞くこと」に追加する（下の工程 0）

**この項目が最優先である理由**: 判定の当てはめが色補間より易しい（全部 private ＝門 0 を通る、
全部バイト一致 ＝判定 2 で即決、`Fx` `Daylight` `Transition` `Lifetime` は絵の SHA が守っている
＝門 1 を通る）。しかも **A で編集する行の 5〜10 行隣にある**（`Fx.mixCh`:249 の 5 行下が :254、
`Daylight.mixColor`:164 の 10 行下が :174）。ここをスキップしたまま「色を混ぜる 6 本を消した」と
言うと、**なぜ 6 本は消して隣の 8 本は残すのかを基準で説明できない**。

→ 8 本を削除して `Num.clamp01` へ。`lerp` / `fract` / `smoothstep` も同様に `Num` へ。

### A. 色を混ぜる 6 実装 → 2 本

**単位: 関数まるごと。**

| 実装 | 場所 | 可視性 | 丸め | 呼ぶ側の t | 門 1 の証拠 |
|---|---|---|---|---|---|
| `Color.mix` | `engine/src/core/Color.flix:36` | **pub** | truncate | — | `TestColor.flix:86` + rpg/race の絵 |
| `ShaderEval.mixColor` | `engine/src/ShaderEval.flix:439` | private | clamp(0,1) | `clamp01` / `smoothstep` 済み | `TestShader.flix:155` + rpg/tetris の絵 |
| `ShaderDoc.mixColorF` | `engine/src/ShaderDoc.flix:296` | private | clamp(0,1) | `smoothstepF`(:370 で clamp) 済み | `TestShader.flix:630` + 絵（下記） |
| `Material.toneMix` | `engine_world/src/Material.flix:334` | private | truncate | `ramp3`(:343) が `phase - floor(phase)` で [0,1) へ落とす | **無し**（門 1 で止まる → B へ） |
| `Daylight.mixColor` | `engine_world/src/Daylight.flix:164` | private | truncate | 3 箇所とも `clamp01` 済み | rpg の絵（`View.flix:91`） |
| `Fx.mixCh` | `engine_world/src/Fx.flix:249` | private | truncate | `frac = pos - idx` で [0,1] | race の絵（`Fx.burst`） |

差の理由を説明したコメントは、6 実装のどこにも無い。

**裁定 A-0（門 0）— `Color.mix` の振る舞いは変えない。** pub なので無条件。
（repo 内 37 箇所の呼び出しは全部読んで、t が [0,1] を外れるものは 1 つも無かった。
つまり repo 内では clamp を足しても 1 画素も変わらない。**それでも変えないのが門 0**。
「頑張って全部確かめたから変えてよい」を許すと、門が門でなくなる。）

**裁定 A-1（判定 2）— clamp と truncate の差は、実際に渡される入力では観測できない。**
Flix stdlib `Float64.flix:308-314` / `:339-340` の定義上、`clampToFloat32(min=0,max=1,x)` は
x ∈ [0,1] で `truncateToFloat32` と一致（NaN は両方 NaN）。private 実装は全部、呼ぶ側で
t が [0,1] に入る（表の 5 列目。`toneMix` の `ramp3` 経由も確認済み）。

→ `ShaderEval.mixColor` / `ShaderDoc.mixColorF` / `Daylight.mixColor` の 3 本を削除して
`Color.mix` へ。`Material.toneMix` は門 1 で止まるので B の答え待ち。

**この裁定の証拠を自分で作る**: 判定 2 は「どんな入力でも差が出ない」を要求するのに、
stdlib の等価は地の文の断定になっている。**旧 3 本と `Color.mix` が同じ値を返すことを pin する
テストを 1 本足す**（`Daylight` の Float64 clamp 経路は別ケースで）。門 1 を他人に課して
自分に課さないのは通らない。

**裁定 A-2（判定 3）— `Fx.mixCh` は残す。**
他が Float32 で補間するのに対し、これは Float64 に上げて補間し最後に 1 回だけ float へ落とす。
**真に値が違いうる。** シグネチャも Color でなく 1 チャンネル（`Fx.flix:246` が 3 ch を個別に呼ぶ）。

race の SHA が一致したとしても、それは「この 1 枚では観測されなかった」であって
「差が無い」ではない。→ **まとめない。判定 3 の 2 番（名前）で差を言う**
（`Float64` 経由であることが名前から読める形へ改名。private なので門 0 は通る）。

結果: 6 本 → 2 本（`Color.mix` と `Fx.mixCh`）。

### G. `RadialGlow` ↔ `RadialBuiltin`（門 0 で止まる → 起票のみ）

**単位: 関数まるごと（5 本）。**

`engine/src/render/RadialBuiltin.flix`（80 行）と `engine_tools/src/RadialGlow.flix`（71 行）。
**実測すると「逐語一致」は思ったより狭い**:

| 関数 | 一致の程度 |
|---|---|
| `toByte`（Glow:66 / Builtin:75） | コメント込みで完全一致（3 行） |
| `clamp01`（:70 / :79） | 完全一致（1 行）→ **F に含まれるのでそちらで消える** |
| `argb`（:59 / :68） | 本体は一致、コメントは書き方が違う |
| `falloff`(Builtin:56) ↔ `smoothstepCurve`(Glow:29) | 本体がバイト一致（`let x = clamp01(1.0 - t); x*x*(3.0-2.0*x)`）。名前が違う |
| `normalizedRadius`（:?/:?） | **一致しない。** Glow は `pub def normalizedRadius(size, x, y)` で size を引数で受け、
Builtin は `def normalizedRadius(x, y)` で `size()` を呼ぶ。シグネチャも可視性も違う |

逐語なのは実質 4〜5 行。「40 行が逐語」ではない。

**裁定 G（門 0）— この回ではまとめない。起票のみ。**

理由 2 つ。(a) `RadialGlow` の `normalizedRadius` / `smoothstepCurve` / `haloPixel` / `maskPixel` は
**pub**。(b) 統合先になる engine 側の `argb` / `toByte` は **private** なので、まとめるには
**engine に新しい pub を生やす**ことになる。これは重複解消ではなく **engine API の拡張**で、
AGENTS.md の事前相談の対象。実測 4〜5 行の重複の対価としては高い。

`RadialBuiltin.flix:5-6` に「engine から engine_tools へは依存できないため式はここに自前で持つ」と
現状を正当化するコメントがあり、これもまとめるなら同時に直す対象になる。

→ `docs/backlog.md` へ起票（トリガー: engine に ARGB 詰めの pub を置くと決まったとき）。
**`clamp01` の 2 本は F で消えるので、この回でも一部は減る。**

なお ARGB 詰めは `PxSpriteAtlas.argbOf:141` / `SoftRaster.argbOf:364` / `BootFont.flix` /
`render_gl/Readback.flix` に加え、**テスト 3 本**（`TestSoftRaster.flix` / `TestRenderPasses.flix` /
`TestRadialGlow.flix:80`）にも散っている。テストが実装の式を書き写しているのは、テストが誤りを
検出しない形。これも起票に含める。

### B / C. `Material` 系 — **門 1 で止まる。着手前に人へ聞く**

**単位: B はレコードの一部フィールド（75 個中 30 個の埋め草）、C は関数の中の骨格部分
（外周 → 内周逆順 → append のストリップ生成）。C は関数まるごとでは差があるので、
単位の定義（差を引数に出せる部分を切り出す）が働く唯一の裁定。**

**この設計で最も重い判断。**

現物で確かめた事実:

- `Material` を呼ぶのは `Terrain.flix:79` と `TerrainDoc.flix:277-307` の 2 つだけ
- `Terrain.flix` は repo 内に呼び出し元が 1 つも無い
- `templates/` `bench/` `editor_server/` からの参照は **0 件**
- `Material.*` を叩くテストは **0 本**（`TestTerrainDoc.flix` は JSON デコードの 3 本だけで、
  冒頭 :4 で「描画の導出はテストしない — スナップショットと目視の仕事」と宣言している）
- **その言うところのスナップショットが 1 枚も無い**
- `.terrain.json` は **0 件**
- `grain` は `isKnownPreset`(`TerrainDoc.flix:240`) に無いので JSON から到達すらできない

→ **`Material` / `Terrain` はこのリポジトリで 1 度も実行されない。**
`make test-engine_world` も SHA も、値を取り違えても緑になる。一致は「変えていない証拠」ではなく
「実行されていない証拠」。

**門 1 の結論: 統合する前に「この経路を残すのか」を人へ聞く。**
前の版はここでテストを 0.5 日かけて足す方針だったが、それは門 1 を D-3 にだけ当てて
B/C には当てない二重基準だった。同じ事実には同じ結論を出す。

聞くこと（D-3 とまとめて 1 回で）:

1. `Material` / `Terrain` / `TerrainDoc` の地形経路は残すのか。残すなら誰が使う予定か
2. `legacy/MapResource`（692 行・呼び出し元ゼロ）は消してよいか
3. `grain` は `isKnownPreset` に足すのか、`grain` ごと消すのか
   （足すなら `count = 16` の性能が同時に問題になる。40×30 マス × 16 で 1 フレーム 19,200 個。
   コード自身が `Material.flix:70-71` で警告している）

**「残す」と決まった場合にやること**（1.75 日）:

- B-0: `TestMaterial.flix` 新設（プリセット 5 本の 15 フィールドを現在値で pin）
- B-1: `baseFx(color)` を置いて 5 プリセットを差分記述へ（判定 3 の「型で言う」）。
  75 個の値のうち 30 個が埋め草で、どれが本当のノブか読めないのが欠陥。
  型 alias 越し・関数呼び出しの結果へのレコード更新は書ける（`Flex.flix:63-64` が同型）。
  ケース名は完全修飾（`SurfaceShape.Speck`）が `Material.flix` の流儀。
  **危険**: 少数派が既定値を上書きし直さないと値が変わる（`bubble` の
  `sizeBase = 0.0` / `sizeSpan = 0.0` は `Material.flix:149-150`）。B-0 のテストだけがこれを落とす
- A の残り: `Material.toneMix` を `Color.mix` へ
- C: `arcStrip(center, radius, width, fromT, toT, segs)` を切り出して `crescent`(:352) と
  `ring`(:437) を薄いラッパに。骨格は同一で、差は戻り型・色/z の有無・`segs` 6 対 12・張り角の有無。
  **なぜ 6 と 12 かはどこにも書かれていない** → 引数の位置に出す（判定 3 の「型で言う」）。
  `fromT + (toT - fromT) * i / segs` と書けば `crescent`(:358) とも `ring`(:442) とも
  **厳密にビット一致する**（1.0 倍と 0.0 加算は IEEE で厳密）。`fromT +` を落とさないこと
- C の doc 修正: `Material.flix:350` は crescent を「相対頂点で返す」と書くが、実装(:357)も
  呼び側(:396-398)も絶対座標。`ring` の doc(:436) は正しく、**同じ事実に逆の説明が並んでいる**

**「残す」でもやらないこと**:

- **B-2（`scales` の `color2`/`color3` と `ramp3` の引数順）はやらない。**
  `Material.flix:121-122` は `color3 = mid, color2 = lite` で、`:393` の
  `ramp3(fx#color, fx#color3, fx#color2, phase)` が打ち消している。値は正しく出ている。
  素直な形へ直しても絵は 1 画素も変わらず、**`SurfaceFx` は pub type alias(:35)・`scales` は
  pub(:117) なので、フィールドの意味の入れ替えは門 0 に当たる**。
  → B-0 のテストで「入れ替わっている」ことを値として固定するだけにして、
  直しは backlog へ（トリガー: 命名の回で pub API を触るとき）
- **E-2（`6.28` → `Vec2.tau()`）はやらない。** 重複解消でなく挙動変更（sin の位相が動く）。
  しかも `Material` は描かれないので SHA でも裁けない。backlog へ

### D. JSON アクセサ 4 セット

**裁定 D-1（打ち切り 4）— `ShaderJson`（engine）と `DocJson` / `JsonCodec`（engine_world）は
統合しない。** `engine/flix.toml` の `[dependencies]` は空で、engine から engine_world は
物理的に見えない。`numAt` / `numOr` が `ShaderJson.flix:551,578`（private）と
`DocJson.flix:103,107`（pub）に同名・同シグネチャで 2 つある事実は、**`docs/backlog.md` へ
トリガー付きで起票**（トリガー: 命名の回で pub API を触るとき）。

**裁定 D-2（判定 3）— `JsonCodec` の `*Or`（fail-open で生値）と `ShaderJson` の `*Or`
（`Result`）は残す。** エラー処理の決まり 1 がまさにこの差を要求している。
差は戻り型で言えている（判定 3 の 1 番）。綴りの重複は門 0 → 命名の回。

**裁定 D-3（門 1）— `legacy/MapResource`（692 行）は人へ聞く。** 上の B/C とまとめて 1 回で。
→ 0.35.38 で決着: テンプレートとゲームで使われていないので `legacy/MapResource`・`legacy/Resource` ごと消した。

**裁定 D-4（判定 2・前の版が落としていた）— `DocJson` と `JsonCodec` は同じ engine_world にある。**
依存の向きの言い訳が通らない唯一の組で、前の版はここを裁いていなかった。
`DocJson.numOr:107`（`Result[JsonError, Float64]`）と `JsonCodec.floatOr:166`（`Float64` 生値）は
「キーと既定値を渡して数を取る」同じ仕事で、戻り型だけが違う。
→ **残す。** 理由は「決まり 1 が `numOr` に `Result` を要求している」ではない（決まり 1 が要求するのは
`load*` / `loadOr` / `loadOrBug` の三分割であって、アクセサの戻り型ではない）。
残す理由は、**fail-open する API と fail-closed な API の両方が実際に要る**から。差は戻り型で言えている
（判定 3 の 1 番）。ただし `DocJson.numOr` が `Result` を返すのは `*Or` の綴りに対して欠陥で、
`docs/error-handling.md:26`「名前が実態と合っていないなら、直すのは名前の方」に当たる。
両方 pub なので門 0 → 命名の回へ起票。

**この回で統合される JSON アクセサは 0 セット。** NOTES.md の材料の 5 分の 1 が
doc の起票だけで終わることを、隠さず書いておく。

### E. 重複ではないもの

**E-3（この回で拾う）— stale コメント 3 箇所。** `MapResource.flix:686`（「`Resource.flix` の同名
helper と同じ実装」と書くが、`Resource.flix:199` は `use JsonCodec.{... intToBd}` で借りる形へ
移っていて同名 helper は無い。**本当の問題は `MapResource.intToBd:687` が pub の
`JsonCodec.intToBd:68` の重複だということ** — ただし門 1 で止まるので結論は変わらない）、
`Resource.flix:519`（`engine/src/JsonCodec.flix` は存在しない。正しくは `engine_world/src/`）、
`TestMapResource.flix:193`（同じくパス誤り）。`bin/check-refs.py` は `.flix` 内コメントのパスを
見ないので**機械では落ちない。だから腐った。**

**E-4（この回で 30 分だけ使う）— `sparkle` の channel 衝突の確認。**
`speckItems`(:317) が `ch = channel + k*4` で `ch`〜`ch+3` を使い、`sparkle` は `count=3`
`channel=71` なので **71..82 を占有**。`DualGrid.flix:133` の `hash(i, j, 81)`（角スタイル）と
**81 で重なる**。`sparkle` の doc(:91) は「81 と重ならない」と書いており実装に対して偽。
→ **衝突しているかの確認だけは今回やる**（B/C の答えを待たない）。次に誰かが `Material.flix` を
開くのは年単位で先で、確認できる唯一のタイミング。結果は backlog へ。

**E-1（`grain` の到達不能）** は上の「人へ聞くこと 3」に統合。

### 触らないもの（打ち切り 4）

- `ShaderDoc.Field` の 30 ケース × 4 モジュール、`CollisionShape2D.flix:506-508` の 25 ケース直積 —
  exhaustive match で拡張漏れがコンパイルエラーになる。:506 に理由も書いてある
- `DualGrid.flix:123` の `hash` と `Hash01.flix:19` の `at` — 判定 3 の 3 番（絵の再現が差を守る）
- `ShaderGen` の `6.2831853`（7 桁）と `Vec2.tau()` — 同上（`TestShader.flix:377-382` が
  GLSL との厳密一致のためと宣言）
- `Arc.flix:28` の `pub def tau()` と `Vec2.flix:24` の `pub def tau()` — 同値だが両方 pub（門 0）。
  backlog へ

---

## この回が残すもの

実装が終わった後、基準がどこからも参照されない文書になるのを防ぐ。

1. **`docs/duplication.md`** — 判定の単位と 5 つの基準。`AGENTS.md` の設計・実装リストへ 1 行。
   **置くだけではどの機械も見ない。配線を 2 つやる**:
   - `Makefile:645-661` の check-docs-sync は「AGENTS.md から docs/ への導線があるか」を
     **ハードコードのキーワード表**で検査する。`docs/duplication.md` をこの表へ足さないと、
     AGENTS.md の 1 行が消えても緑のまま通る
   - `bin/gen-rules.py:27-43` は `drawing-floor` / `flix-conventions` / `error-handling` の 3 本だけを
     `.claude/rules/*.md` へ変換する。**duplication は rules に載せない** — rules は
     「`*.flix` を編集するたびに読む物」で、重複の判定は編集のたびには要らない（設計の回にだけ要る）。
     載せない理由を `docs/duplication.md` の冒頭に 1 行書く
2. **「残した重複の一覧」**（`docs/duplication.md` の末尾）— `bin/lint-fallback.py` の EXEMPT に
   相当する、**残りの宿題の一覧**。今回の時点では `Fx.mixCh` / `DualGrid.hash` /
   `ShaderGen` の 7 桁 π / `ShaderDoc.Field` 30 ケース / `CollisionShape2D` 25 ケース /
   `ShaderJson`↔`DocJson` / `DocJson`↔`JsonCodec` / `Arc.tau`↔`Vec2.tau` / `Color.clamp01`（Float32 版）。
   lint は作らない（静的な重複検出は引数名を変えるだけで逃げられる）が、**一覧すら無いと
   基準が違反を裁けない**。
   **腐り止めに `backlog.md:42` 式の「最終確認日」を付ける** — 腐った `backlog.md:29` を直す
   設計書が、腐り止めの無い一覧を新設しては同じことの繰り返しになる
3. **`docs/backlog.md` の起票** — D-1・B-2・E-2・E-4 の結果・`Arc.tau`。
   ついでに `backlog.md:29` の **「lighten / darken の重複を一本化」項目を決着させる**。
   トリガー（`Color.lighten` / `Color.darken` が engine に入る）は `Color.flix:62,70` で
   **既に発火済み**、テンプレ側も `Color.lighten` を呼ぶ形へ移行済みで、項目の言う
   「3 箇所に散っている」は今は偽。**決着は「項目を閉じる」の一択**
   （`race-starter/ThemeDoc.flix:74-100` は素通しラッパではなく係数を固定した Doc アクセサなので
   消す対象ではない）。

   **その調査で出た A の数え漏れも同時に片付ける**: `Color.lighten`(:62) / `darken`(:70) は
   `Color.mix(c, white/black, t)` と同型で、`Color.flix:34` の doc が自分で「片方が決め打ち」と
   書いている。さらに `Material.flix:207` と `Terrain.flix:153` のコメントが
   「`lighten(fill, t)` と等価」と**インライン展開の存在を自白している**。
   → `lighten` / `darken` 本体は **pub なので門 0**（残す。`mix` の特殊化として名前が差を言っている
   ＝判定 3 の 2 番）。インライン展開 2 箇所は `Material` / `Terrain` 側なので**門 1 で止まり、
   工程 0 の答え待ち**
4. **NOTES.md への書き戻し** — (a) 材料 5 項目それぞれの決着、(b)「`Material` / `Terrain` は
   repo 内で 1 度も実行されない」という**この回でしか得られない事実**、(c) 残した重複の一覧の在り処、
   (d) 今回拾わなかった重複の残高。NOTES.md の材料が言う「色補間が 5 実装」は 6 が正しい

---

## 順番と検証

engine と engine_world と engine_tools に触る。**engine/ に触るので、実装前に改めて人へ確認する**。

**各段階の前に `make sync`。** `sync-engine` → `sync-render-gl` → `sync-engine-world` →
`sync-engine-tools` → `sync-engine-full` → `sync-root-src` の順で fpkg を再ビルドして
templates/bench へ配る（`Makefile:322`）。忘れると **templates は古い fpkg のまま緑になり
SHA も一致する**（`/release` skill が名指しで警告している罠）。順序依存があるので `make sync` 一発。

| 順 | 内容 | 触る | 証拠 |
|---|---|---|---|
| **0** | **人へ聞く**（Material 経路・MapResource・grain・`Num.smoothstep` を engine に足すか） | — | 答え次第で 5・6 が消える |
| 1 | E-4 の衝突確認（30 分） | 読むだけ | 結果を backlog へ |
| 2 | F（`clamp01` 8 本 + `lerp` + `fract` 3 本） | engine / engine_world / engine_tools | `make test-par` + 5 テンプレの SHA + **`make gl-parity`** |
| 3 | A-1 の等価 pin テスト 1 本 | engine/test | 緑 |
| 4 | A（`ShaderEval` / `ShaderDoc` / `Daylight` の 3 本削除、`Fx.mixCh` 改名） | engine / engine_world | `make test-engine` + rpg/tetris/race の SHA + `gl-parity` |
| 5 | B（`TestMaterial` → `baseFx` → `toneMix`） | engine_world | **0 で「残す」が出た場合のみ** |
| 6 | C（`arcStrip` + doc 修正） | engine_world | 同上 |
| 7 | E-3 / 起票（G・D-1・B-2・E-2・E-4・`Arc.tau`・backlog:29 の決着）/ `docs/duplication.md` / NOTES.md | docs | `make check-docs-sync` + `make api-digest` |

**F は描画経路（`RadialBuiltin` は `LwjglLayer.flix:723-730` が GPU へ上げ、
`SoftRaster.flix:548-551` がテクスチャ表へ混ぜる列）に触るので、`gl-parity` と 5 テンプレの SHA が要る。**

**`make gl-parity`**（`Makefile:266`）は「描画経路（render_gl / SoftRaster / Frame / ShaderEval）を
触ったら回す」と `Makefile:263-265` が指定している。F と A が該当。

**`make reference-check` はルートに無い。** 実体はテンプレ単位（`templates/*/Makefile:110` 等）で、
ルートからは `make render-par` → 各テンプレで打つ。`game-starter` だけ `SHA256SUMS.txt` を
持たない（打つと `bin/reference-check.sh:14-17` で exit 1）。

**doc を触るときの副作用**: `DocJson` は pub なので、doc の**1 行目**に足すと
`bin/gen-api-digest.py:262-268` の拾う範囲に入る（2 行目以降は捨てられる）。
1 行目を触ったら `make api-digest` を回して `docs/api-digest*` を一緒にコミットする。
`baseFx` / `arcStrip` は private のままにする（門 0）。

**ミラー木**: `engine_full/src/` と ルート `src/` に同内容のファイルがあり、`make sync` が
再生成する。1 つの変更が 3 ファイルに出るので、diff を読むときに面食らわないこと。

締めに 1 回: `make sync` → `make test-par` → `make render-par` → 5 テンプレの `reference-check`
→ `make gl-parity` → `python3 bin/lint-images.py` → `make lint-view lint-palette lint-ui lint-audio`
→ `make lint-jargon`（新しく書いた doc を全部見るので pre-commit で止まる前に手で回す）。

### 証拠が何を守るか（正直な表）

| 対象 | テスト | 絵の SHA |
|---|---|---|
| `clamp01` 8 本（F） | `Fx` `Transition` `Lifetime` `Depth` にあり | race / rpg |
| `ShaderEval` / `ShaderDoc` | `TestShader.flix:155,630` | rpg / tetris（`Render.flix:893-894` が「GL の無い経路向け」と明記） |
| `Daylight` | 色は見ていない | rpg（`View.flix:91`） |
| `Fx.mixCh` | 色は見ていない | race（ただし `Fx.flix` の `gradient` は色 1 本だと短絡するので、2 色以上の fx.json が要る。`assets/fx/nitro-flame.fx.json` は 2〜3 色で届く） |
| `RadialBuiltin`（F に含まれる `clamp01`） | `TestRadialBuiltin.flix` | GL アップロード経路（`LwjglLayer.flix:723-730`）→ **`gl-parity` 必須** |
| **`Material` 全般（B/C）** | **無し** | **無し** |

---

## 規模

1 日 = 実作業 6h。

| 項目 | 日 |
|---|---|
| 0. 人へ聞く | — |
| 1. E-4 の確認 | 0.1 |
| 2. F（`clamp01` 8 本 + `lerp` + `fract` 3 本） | 0.5 |
| 3. A-1 の pin テスト | 0.15 |
| 4. A（3 本削除 + `mixCh` 改名） | 0.5 |
| 7. E-3 / 起票 / `docs/duplication.md` + 配線 / NOTES.md | 0.5 |
| 検証の一巡 | 0.5 |
| **小計（0 の答えに依らない分）** | **2.25** |
| 5〜6. B / C（「残す」が出た場合のみ） | +1.75 |

前の版は 3.5 日で、うち 1.75 日が「1 度も実行されないコード」への投機だった。
**その 1.75 日を門 1 の答え待ちにし、代わりに F（0.5）を入れた。**
F は生きているコードで、テストと絵の SHA が守っている。

G（`RadialGlow`）は最初 0.5 日で入れていたが、実測すると逐語重複は 4〜5 行で、
まとめるには engine に新しい pub が要る（門 0 + engine 拡張）。**基準から導くと降格**なので
起票へ回した。`Num.smoothstep` も同じ理由で工程 0 の質問に移した。

---

## 見送る案（なぜ採らないか）

- **共通の `Mix` モジュールを新設する** — 統合先の `Color.mix` が既にある。新設は 7 本目を作るだけ
- **`Color.mix` にクランプを足して安全側に倒す** — 門 0。安全側に倒したいなら、重複解消とは
  別の提案として単独で出す
- **JSON アクセサを engine へ持ち上げて 1 本化** — `engine/flix.toml` が engine を
  「GL-free で native 依存の無い契約層」と宣言している。層の意味を変える判断で、対価が高い
- **重複を lint で機械検査する** — 静的な重複検出は引数名を変えるだけで逃げられ、守れない決まりに
  なる。代わりに「残した重複の一覧」を置く
- **`Material` のプリセットを Doc(JSON) へ外に出す** — `TerrainDoc.flix:293-295` が
  「細部ノブは Material のプリセット関数内の定数（ロジックを JSON に書かない原則）」と既に宣言している
- **テンプレに地形シーンを足して `Material` を絵の SHA で守る** — 正道だが `.terrain.json` も
  テンプレ側の配線も無く数日仕事。門 1 の答えが「残す」でも、まず単体 pin で足りる
- **`Text.flix` の行数の 2 乗（`foldLeft` の中で `List.append`）を拾う** — 生きたコードで
  30 分の直しだが、これは性能の回の材料。射程を伸ばすと基準が弱くなる。backlog へ起票して
  性能の回に渡す
