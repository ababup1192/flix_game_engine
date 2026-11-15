# ノベルの語彙の次の段（N4・N4b・N4c・N4d・N6）の設計

- 状態: 第 3 版（2026-11-15。3 回目のレビュー 91 点で合格・残りの小さな指摘 4 つを直した）。1 回目のレビュー（72 点）の M1〜M14 と、2 回目のレビュー（86 点）の R1〜R3 と「できれば」を全部入れた（直した所は 0.1 と 0.2 の表）。実装はまだ。
- 親の計画: [plans/novel-data-only.md](novel-data-only.md) の 3 章（N4〜N6 の表・3.1 の Backdrop3d・3.15〜3.18 の決めた事）。
- 前の段: [plans/novel-vocab-design.md](novel-vocab-design.md)（N1〜N3）。N3（Mark v3・Snapshot・`window off`・`Stage.pages`）は今テンプレートで作っている所なので、あの計画書の 4 章の形を正として前提にする。
- 最終目標: ゲーム 2 本「血鱗」（`~/Documents/flix_ge_workspace/blood-scale/game`）と「廃屋配信」（`~/Documents/flix_ge_workspace/haioku`）を新しい命令で書き直す。そのための標準の語彙とエンジンの部品を決める。
- 範囲: 移すのはこの 2 本だけ。kankan と izakaya は語彙が足りるかを確かめる相手にした（kankan は書き直して build に通した。2.7）。2 本の移行は範囲の外で、移す時は 10 章の門を同じように使う。
- 数は数えた物。【推】は見込み。【未確認】は確かめていない事。スパイクの写しは scratchpad の `n4-spike/`（`convert_n4.py`・`gen_vocab.py`・`kankan_build.py`・`count.py`・`alt.py`・`build/` に書き直した台本と下書きの vocab.json・動画を書き直した物）。前の回の物は `vocab-spike/`。

## 0. 決めた事（要約）

1. **N4 の標準の語彙は 10 個**: 今ある 7 個（`bg`・`window`・`audio`・`fx`・`shake`・`show`・`hide`）を広げ、`move`・`overlay`・`camera` を足す。N4b で `text` と `speak`、N4c で入力の案内（タグ）を足す。語彙 19 の `swap` は `show` に入れる（Ren'Py の `show 名 属性` と同じ形にそろえる。名前が 1 つ減る）。`filter` と `feed` は 1 本でしか使わないので、標準にせずゲームの口に置く（相談 C10）。
2. 後に残る値は全部 `PropertyTween`（鍵は `層.値`）か、今ある自分の形（背景・立ち絵の層）に書く。N3 の Snapshot に乗るので、セーブ・settle・素材待ちのコードは書かない。1 コマンド足すのは「表に 1 行 + View で値を読む」の 2 か所のまま。
3. **N4b**: 話し手を明るく（Naninovel の speaker highlight）は台詞ごとに World が `cast.speaker` を書く。`<<speak 名>>`・絵の中の点（引数の型 `marker` = `名.点`。Godot の Marker2D に合わせた）・「出ている間は枠を消す」（Doc の欄）・メッセージ枠の型を Doc で選ぶ（`<<window 型>>`）・`text`。
4. **N4c**: 払い・タップで選ぶ選択肢は今の血鱗の書き方（`-> 案内 #act:up #at:名 #icon:名 #mute`）をそのまま標準にする。案内の絵と当たりの矩形は新しい Doc `novel.prompts.json`（Unity・Xbox の input prompt の言い方）。タグの値の名前を Doc から集めて go が検査する。
5. **N4d**: 3D の背景は「glb + 光を当てない絵（光は絵か lightmap にベイクする）」を本命にする。今の 2 本がどちらもこの形で、エンジンに要る物（`Gltf`・`Scene3d`・`Scene3d.Lightmap`・`Billboard3d`・`Model3d.findNode`・`Model3d.nodesByName`）は全部ある。動画は大きさを測った（5.1）。デスクトップで流す口がエンジンに無い。スパイクは血鱗の住処で 3 案を同じ物差しで測る。
6. **N6**: 親の計画の「N6 は作品が増えてから汎用の形を決める」に従い、今回は形の案だけを書く。廃屋配信の HUD と流れるメッセージはゲームの口（`GameView.hud`・`GameCommands`）に置く。台本は今から後の形で書く（HUD の値は Yarn の変数 `<<set $battery to 31>>`・メッセージは `<<feed "本文" from=名>>`）。後で標準へ移しても台本を直さずに済む。
7. **置き場（相談 C8）**: N1〜N3 で決めた「コマンドの中身と PropertyTween は N4 でエンジンへ上げる」を、「テンプレートに置いたまま、テンプレートの追随を上書きにする」へ替える案を出す。O3（標準の表はゲームの vocab.json に書かない）は、テンプレートが持つ `vocab.std.json` で守る。engine_world へ上げるのは、実装が 2 つある `Backdrop3d` と、引数の型 `marker` と `text`。
8. **2 本の移行**: 書き直した台本を下書きの vocab で `bin/fge yarn build` に通してから数えた（2.7）。標準の命令か Yarn の `set` で書けるのは血鱗 125/158 行（79.1%）・廃屋配信 78/108 行（72.2%。C10 で filter と feed を標準にすれば 105/108 行・97.2%）。残る Flix は血鱗 約 1,000〜1,400 行・廃屋配信 約 600〜900 行【推】（今は 10,239 行と 6,322 行）。
9. **移行の門**: 移す前の版で flow ごとに tape.json（台詞の時刻・鳴らした音・問いの値・画面の物）・world の層だけのコマ・全部のコマ・古いセーブを撮り、新しい版と突き合わせる。違いは「読み違い（直す）」と「わざと変えた物（人が絵で見て承認）」に分ける。門そのものを確かめる手（同じ版を 2 回流して差が 0・わざと入れた読み違いで落ちる）を道具の完了条件にする（10 章）。

### 0.1 第 2 版で直した所

| 指摘 | 直した所 |
|---|---|
| M1 N1〜N3 の決めた事を黙って覆していた | 7.1・相談 C8 に前の決めた事・根拠・別案・O3 の扱い |
| M2 GameCommands が Cast を触ってよいか | 2.8・相談 C9（`Commands.applyText` の口） |
| M3 vibrate・pan・run の行き先 | 2.2 の `bg` を `transition=` と `pace=` に分け、3D の道筋との関係を 2.3 の表に。vibrate は名前付きの強さ（端末は震えない） |
| M4 1 本だけの部品 | 2.6 に部品ごとの使い手の表と標準に入れる理由。filter と feed はゲームの口へ（C10） |
| M5 kankan・izakaya | 範囲を前書きに。kankan は書き直して build に通した（2.7） |
| M6 GameView の重ね順 | 2.4 で actor と GameView を同じ層の数で並べる |
| M7 道筋の音・暗くなり・揺れ・秒の持ち主 | 5.4 |
| M8 公開済みの古いセーブ | 9.4・10 章の門 |
| M9 SHA では層を分けられない | 10.3 を world の層だけのコマと `objects` の矩形で比べる形に |
| M10 門を確かめる手 | 10.6 を段 10 の完了条件に |
| M11 門の抜け道 | 10.2 にカバー率・承認の上限・画面の大きさ 3 通り |
| M12 当て直しの後に古いコマンドでは組めない | 10.2 で当て直しと台本の書き換えを 1 つのコミットにまとめ、門を 1 回に |
| M13 ゲームが持つファイルの食い違い | 7.2 にゲームの持ち物の一覧と、テンプレートに足す口（`GameRes`・`GameBoot`・`GameView.hud`）。相談 C12 |
| M14 `Model3d.nodeNamed` は無い | `Model3d.findNode`・`Model3d.nodesByName` に |
| できれば | 数の直し（flow は 13 本と 5 本・N1〜N3 の計画書の 6 章）・build に通してからの割合・6 つの意味の崩れ・段のラベル・比べの書き方・縦横・N4c の移す物・HUD の declare・Doc の schema・名前・Mark v3 の mode・見積もり・Sea・`Timeline` と `Transition.Kind` |

### 0.2 第 3 版で直した所

| 指摘 | 直した所 |
|---|---|
| R1 最初の `<<sink>>` で住処のカメラが潜る動きが写されていない | 2.8 に「sink の GameCommands が最初の 1 回だけ `applyText` で `<<camera path=lair.dive>>` を当てる」決まり（台本に行を足すと台詞の行番号がずれるので (b) を取った）。5.3 の paths に `lair.dive`。10.6 のわざと入れる読み違いに |
| R2 住処の 3D の背景が何で出てくるか | `novel.backdrops.json` の `initial`（背景が無い間の背景）を 5.3 に。タイトル画面の背景は initial と分け、`title`（写真・拡大・漂い）を同じ Doc に置く（今の `Lair.titleBackdrop` と同じ絵で、title.png を変えない）。photos に `lair`（still = `lair_still.jpg`）を足す事を 9.1 に |
| R3 `Stage` の `game` の欄に settle と戻しの決まりが無い | `Stage` の `game` の欄はやめ、コメント欄は PropertyTween の `game.feed.<番号>.*` の鍵（列の長さに上限）で持つ形に替えた（6.2）。2 案の比べと C12 の中身の替え |
| できれば | lights のラベル（N4 が 50 行・N4d が 1 行）・objects の id 23 種類の出し手の表（10.2）・全体に出る系統の違いの扱い（10.2 (b)）・短い画面の基準が撮れるか【未確認】（10.2 (c)）・`Timeline.soundsOnClock` と時計（5.4）・C2・C3・C7 の聞き直し（8.2）・下書きの vocab の検査の範囲（2.7）・template-sync の一覧を毎回見る（7.2・段 10）・`Ctx.isLoaded` と `needs`（5.4） |

## 1. 前提（N1〜N3 の結果と、2 本の今の形）

| | 今のテンプレート（N2 段 6 まで） | 血鱗 | 廃屋配信 |
|---|---|---|---|
| 演出コマンド | 7 個（bg・window・audio・fx・shake・show・hide。`Commands.all()`） | 27 個（`Stage.Cue` の case 28） | 19 個（`Stage.Cue` の case 12） |
| src の行数 | 7,014 | 10,239（render 918 は別） | 6,322（render は別） |
| テンプレートの版 | — | v0.94.0 の写しから約 +4,415 行 | それより古い写しから約 +2,450 行 |
| e2e の flow / reference の SHA / テスト | 6 / — / — | 13 / 38 / 323 | 5 / 29 / 131 |
| 公開 | — | GitHub Pages（ブラウザのセーブがある） | 【未確認】 |

- 2 本ともテンプレートの N1〜N3 より前の写しを持つ。移行は「テンプレートを当て直してから、ゲームだけの演出を `GameCommands`・`GameView` と Doc に写す」になる（[novel-vocab-design.md](novel-vocab-design.md) の 6 章の決めた事）。
- `PropertyTween` は数・名前・一度だけの演出（`NumKey`・`NameKey`・`TriggerKey`）と `delay` を持つ。鍵は文字なので、`actor.<名>.x` のように名前ごとの鍵を作れる。
- `Commands.Command` は `spec`・`timing`・`apply`（`Ctx` に `res`）・`needs`。`Out` は `ClearPage`・`TurnPage`・`Sound`・`Event`。
- エンジンにもうある物（api-digest で確かめた）:
  - `Transition.Kind`（FadeOut・FadeIn・WipeLeft・WipeRight）。slide と pan は無い。
  - `CameraRig`（zoom・揺れ）・`FxDoc`（粒の Doc）・`AudioMixer`（バス・ダッキング・スナップショット）。
  - `ShaderDoc` の `Field.Time` と `Field.Param`（時間で動く値と外から渡す値）。
  - `Timeline`（効果音の時刻表。`Timeline.soundsOnClock(clock, at, tl)` が時計（物語の時計など）の今のフレームの間に鳴る音を返す。`soundsBetweenTimes` は時計を持たない実時間の口）。
  - 3D: `Scene3d.Lightmap` と uv2・`Billboard3d`（unlit）・`Model3d.findNode` / `Model3d.nodesByName`・`Gltf.loadTexturedUsing`。
  - 動画を流す部品は無い。
- go の検査（`go/internal/yarn/check_args.go`）が今読む引数の型は `num`・`time`・`name`・`choice`・`flag`・`ease`。タグの値は vocab.json に書いた決まった一覧だけを照らす（Doc から集められない）。

## 2. N4 — 標準の語彙

### 2.1 まとめ方

| まとめた先 | 元の名前（作品） | まとめた理由 |
|---|---|---|
| `overlay` | dim（kankan）・flash（kankan）・black・lights（血鱗） | どれも「画面に被せる色の濃さを時間で変える」。flash は `from=1` で 1 行 |
| `camera` | zoom（kankan）・住処のカメラの動き（血鱗）・部屋を歩く道筋（廃屋配信） | 2D の寄りと 3D の道筋を同じ名前で（Ren'Py の `camera`・Naninovel の `@camera`）。道筋は N4d |
| `show` | char・item・witch・girl・eye・vision・whale の姿の替え（血鱗）・swap 案 | 名前付きの絵を出す・絵を替える（Ren'Py は `show 名 属性` で表情も姿も替える） |
| `move` | sink の見た目・shadow（血鱗）・hop の中身（izakaya） | 出ている絵の位置・大きさ・濃さを時間で動かす（Ren'Py の ATL・Tyrano の `[anim]`） |
| `shake` | shake・vibrate（廃屋配信の画面の小さい揺れ）・shake big（kankan）・刺した物だけの揺れ（血鱗） | 強さを名前（Doc）か数で、揺らす相手を `on=` で選ぶ |
| `audio` | se・ambience・bgm・silence（廃屋配信）・se の後の送れない秒（kankan） | 音のチャンネルを 1 つ目の引数で選ぶ |
| `bg` | bg の pan（血鱗の slide）・dark・pan・run（廃屋配信） | 切り替えの種類を `transition=`、3D の道筋の歩き方を `pace=` で |
| `text`（N4b） | text・speed・hold（kankan） | 文字の置き場・大きさ・揃え・速さ・送れない秒 |

### 2.2 コマンドと引数

書き方は N2 で決めた B（主の引数 1〜2 つは位置、ほかは `key=value`）。共通の引数は `time=`（秒）と `ease=`（`Curve.Ease` の名前）。`ease` の既定は「今の動きに合わせる」（N1〜N3 の計画書の 3.5）を続ける。新しい部品だけ smoothstep。`[ ]` は省ける。★ は N4 で足す引数。

| コマンド | 引数 | 既定 | 書く所 | 他のエンジンの同じ物 |
|---|---|---|---|---|
| `bg 写真` | `grade=` ★`transition=fade\|black\|wipe\|slide\|pan\|cut` ★`pace=walk\|run` `time=` ★`ease=` | transition = Doc の `defaultTransition`（今は fade）・pace = walk・time = 1 | Stage の背景の形（`shot`・`under`・`fadeFrom`・`fadeSeconds`）に ★`transition` と ★`pace` を足す | Ren'Py `scene … with dissolve`・Naninovel `@back … transition:`・Tyrano `[bg method=]` |
| `window 型\|clear\|off\|on` | `time=`（off・on の薄くなる秒だけ。型と clear に書くと Err） | — | `Stage.mode`（型の名前）・`window.hidden`（数。time で tween） | Ren'Py `window hide` / `nvl`・Naninovel `@printer`・`@hidePrinter` |
| ★`text` | `at=top\|center\|bottom`（NVL の頁の中の行の塊の置き場）`size=`（`novel.kind.json` の `textSizes` の名前）`align=left\|center`（1 行に収まる行だけ真ん中へ）`speed=`（設定の文字の速さに掛ける倍率）`lock=`（秒）。どれか 1 つは要る | — | `text.at` `.size` `.align`（名前）・`text.speed`（数）・`text.lock`（一度だけ） | Ren'Py の window の style・Naninovel `@printer`・Tyrano `[position]` / `[delay]` |
| ★`speak 名` | — | — | `cast.speaker`。項目の `speakFx` があれば `markers.mouth` から一度（`fx.once.<粒>`・`fx.onceAt.<粒>`） | — |
| `audio ambience 音[,音]\|off` | ★`volume=` ★`fade=` | volume = Doc の音量 | `audio.ambience`（名前。重ねる時は `,` でつないだ 1 つの値）・★`audio.ambienceVolume`（数） | Naninovel `@sfx loop:true` |
| ★`audio bgm 音\|off` | `volume=`（数か Doc の名前）`fade=` | fade = 0 | ★`audio.bgm`（名前）・★`audio.bgmVolume`（数・tween で fade） | Ren'Py `play music … fadein`・Naninovel `@bgm`・Tyrano `[playbgm]` |
| `audio se 音` | ★`wait=true` | wait = false | `Out.Sound`。wait なら ★`Out.Wait(wav の秒)`。音量はバス（novel.mixer.json）が決め、`volume=`・`fade=` を書くと Err（一発の音は名前しか運べない） | Naninovel `@sfx wait:true`・Tyrano `[playse]` + `[wse]` |
| ★`audio all off` | `fade=` | — | 環境音と音楽（鳴り続ける音）の名前を None。一発の効果音は止めない（8.3 の C14） | Ren'Py `stop sound`・`stop music` |
| `fx 名\|off` | ★`once=true` ★`on=名.点`（N4b。引数の型 `marker`。点から出せるのは `look: puff` の粒だけで、蛍・雪に書くと Err） | 続ける | `fx.particles`・★`fx.particlesAt`（名前）。once は ★`fx.once.<名>`（一度だけの演出）・★`fx.onceAt.<名>` | Naninovel `@spawn Rain` |
| `shake [強さ]` | ★`on=screen\|window\|<絵の名前>` `time=` | 強さ・time = Doc の名前付きの強さ（`novel.kind.json` の `shakes`）。数を書けば px | `camera.shake`（一度だけ）・★`camera.shakeAmp`（数）。on が絵なら ★`actor.<名>.shake` | Tyrano `[quake]`・Naninovel `@shakeCamera` |
| `show 名 [絵]` | `at=` ★`from=left\|right\|top\|bottom` ★`x=` ★`y=` ★`scale=` ★`alpha=` `time=` ★`ease=` | 絵・at = 出ている形か Doc の face・slot | Cast の層（自分の形）。x〜alpha は `actor.<名>.*` | Ren'Py `show 名 属性 at 位置`・Naninovel `@char` / `@spawn`・Tyrano `[chara_show]` + `[chara_mod]` |
| `hide 名\|all` / `hide at=位置` | ★`to=left\|right\|top\|bottom` `time=` ★`ease=` | time = Doc の fadeSeconds | Cast の層 | Ren'Py `hide`・Naninovel `@hideChars`・Tyrano `[chara_hide]` |
| ★`move 名` | `x=` `y=` `dx=` `dy=`（どれも画面に対する割合の数）`scale=` `alpha=` `rotate=`（度）`from=`（出ていない絵だけ）`to=` `time=` `ease=` | time = 0.5・ease = smoothstep | `actor.<名>.x` `.y` `.scale` `.alpha` `.rotate`（数） | Ren'Py ATL `linear 1.0 xalign …`・Naninovel `@char pos:`・Tyrano `[anim]` |
| ★`overlay 濃さ` | `color=black\|white\|#rgb` `from=` `layer=stage\|screen` `time=` `ease=` | color = black・layer = stage・time = 0。始まりの濃さは Doc の `overlayStart`（血鱗は 1 = 真っ黒から） | `overlay.alpha`（数）・`overlay.color`・`overlay.layer`（名前） | Ren'Py `show black` + `with`・Tyrano `[mask]` / `[mask_off]` |
| ★`camera` | `zoom=` `x=` `y=` `path=`（N4d）`time=` `ease=`（2D に `rotate=` は無い: 背景と立ち絵は Shader の面で傾けられない。3D の道筋で足す） | zoom = 1・ease = smoothstep。`path=` を指した時の time の既定は道筋の keys の長さ（最後の key の秒） | `camera.zoom` `.x` `.y` `.rotate`（数）・`camera.path`（名前）・`camera.pathT`（数 0〜1） | Ren'Py `camera: zoom`・Naninovel `@camera zoom: offset:`・Tyrano `[camera]` |

**引数の細かい決まり**:

- `x`・`y` は slot からのずれ（画面に対する割合）。`dx`・`dy` は今の値からの足し算で、単位は x・y と同じ数（N1〜N3 の計画書の 3.3 の `offset` 型（`40px`・`3.2%`）は engine_world の `YarnCommands.Param` に無く、足すのは C の承認の外なので持ち越し）。`dx` は apply の時に「今の終わりの値 + dx」を絶対の値にして書く。相対の値は残さない（N3 の 4.1 の写しで、絶対の値なら戻しで崩れない事を確かめた形）。
- `move 名 from=left to=right time=` は、出ていない絵を端の外から出して、端の外まで動かしてから消す（血鱗の shadow が 1 行で書ける）。
- `show` が出ていない絵を出す時は、その絵の `actor.<名>.*` を Doc の既定に戻す（前に出した時の `move` が残らない）。`hide` の後は鍵を消さない（終わりの値が残っても、出ていなければ読まない）。
- 小物の「同時に 1 つ」は今の決め打ちをやめ、Doc の slot に `exclusive: true` を付ける（その位置に出せるのは 1 つで、後から出した物が前の物を消す）。血鱗の item・still（回想のスチル）がこれ。
- `from=`・`to=` の滑る距離は Doc の `slideDistance`。
- `overlay` は前の値と同じ値へ動かしても何も変わらない（血鱗の `lights` の「明けていれば何もしない」と同じ）。
- `camera` の 2D は world の層（背景・絵・粒・GameView）だけに掛ける（`CameraRig.centerOn`）。文字の枠と HUD には掛けない（kankan の zoom が背景だけに掛かるのと同じ）。
- `text lock=秒` は「その秒の間は押しても送らない」。kankan の se の後の送れない秒（30 行・21 の音）は、音ごとに 1 つの値に決まっていた（数えた）。なので音の Doc の `lockSeconds` に書き、台本からは消す。
- `audio se wait=true` の秒は wav の長さ（`Res#soundSeconds`。テンプレートの `SoundLength` が WAV の頭から読む。App の `lengthOf` は `GameEngine.Audio.audioSeconds` の効果で、Res を作る時には読めない）。`Out.Wait` を受けた World は `<<wait 秒>>` と同じ待ちに入る（送り・選択は効かず、スキップは飛ばす）。Silent の当て直しでは待たない。**後ろの `<<wait 秒>>` とは重なる**（足さずに長い方だけ待つ。実行器はコマンドを返した時にはもう後ろの `<<wait>>` まで流していて、その時刻から数えるため。engine_world の実行器を替えずに済む形を取った）。長さが読めない音は待たず、読み込みの時に 1 回知らせる。**移行では使わない**（待ちが増えると、古いセーブのブックマークの steps がずれる。9.4）。

### 2.3 `transition=` と `pace=` と 3D の道筋（M3）

| 台本 | 2D（道筋が無い・3D が読めていない・スキップ中・当て直し） | 3D の道筋がある（今の場所 → 行き先 に `pace` の合う道筋が `novel.backdrops3d.json` にある） | 元の書き方 |
|---|---|---|---|
| `transition=fade` | 前の写真の上に重ねる | 歩かない（重ねるだけ） | 血鱗の `bg` |
| `transition=black` | 短く暗転してから映る（`Transition.Kind` の FadeOut → FadeIn） | `pace` の道筋を歩く | 廃屋配信の `dark`・秒だけの形 |
| `transition=slide` | 前の写真を左へ送り、新しい写真を右から入れる | 歩かない | 血鱗の `pan` |
| `transition=pan` | カメラを横へ振ったように流れて替わる | `pace` の道筋を歩く | 廃屋配信の `pan` |
| `transition=pan pace=run` | pan と同じ流れ | 走る道筋（chase）を歩く | 廃屋配信の `run`（5 行） |
| `transition=wipe` | `Transition.Kind` の WipeLeft / WipeRight | 歩かない | （4 本で 0 回。Transition にある物を出すだけ） |
| `transition=cut` | すぐ替わる | 歩かない | `time=0` |

- どの transition が道筋を歩くかは Doc（`novel.backdrops3d.json` の `walkOn: ["black", "pan"]`）に書く。廃屋配信の今の決まり（dark と pan と run は道筋があれば歩く）を既定にする。
- slide と pan は `Transition.Kind` に無い。今 2 本のゲームが別々に書いている物をテンプレートの View に移す。engine_world の `Transition` には足さない。足す時は「2 つ目のジャンルが使う時」とする。
- 2D の pan は近似（今の写真を背景の幅の 1/4 だけ寄せながら重ねる）。black の暗転は背景だけでなく world の層の全部（人物・粒・GameView）に掛ける（覆いと同じ層の数に置く。文字の枠と HUD には掛けない）。

### 2.4 描く層（M6）

world の層の中を **actor と GameView と粒が同じ「層の数」（0〜999）で並ぶ**形にする。血鱗の今の z の数（鯨 300・傷 305・スチル 330〜336・少女 600・泡 700・瓶 850・大写し 900・黒の幕 930・結末 940〜947）をそのまま Doc とゲームのコードに写せる。

| 層の数（既定） | 物 | 決める所 |
|---|---|---|
| 0 | 背景（2D の写真か 3D の背景） | 固定 |
| 100 | 背景に付いた絵（Doc の `attach: "bg"`。血鱗の鯨は 300 に置く） | actor の Doc の `layer` |
| 500 | 人物（`cast`） | actor の Doc の `layer`（無ければ 500） |
| 600 | 小物（`props`。今の「人物より小物が手前」） | 同じ（無ければ 600） |
| 700 | 粒（`fx`） | `novel.effects.json` の粒ごとの `layer` |
| 任意 | GameView の物 | `GameView.draw` が返す `(層の数, 物)` |
| 900 | `overlay layer=stage` | `novel.kind.json` の `overlayLayer`（血鱗は 930） |
| hud の範囲 | 文字の枠・HUD・`GameView.hud` | View |
| hud の上 | `overlay layer=screen`・素材待ちの黒 | View |

- View は層の数で並べてから `docs/z-bands.md` の world の範囲の z に詰める。同じ数は「actor → 粒 → GameView」の順。
- `GameView.draw` の型を `List[Render.PlacedItem]` から `List[(Int32, Render.PlacedItem)]` に替える。今の zGameView の 4 つの枠はやめる。

### 2.5 `Out` と `Stage` に足す物

```flix
pub enum Out {
    case ClearPage
    case TurnPage
    case Sound(String)
    case Event(String)
    case Wait(Float64)       // ★ <<audio se 音 wait=true>>。World が <<wait>> と同じ待ちに入る（Silent では落とす）
}
```

- `Stage` に足すのは背景の替え方（`switch`: transition・ease・pace）と、歩いている道筋の名前（5.4）。ほかは全部 `props`（PropertyTween）に入る。`from=`・`to=` の滑りは Cast の層の `Shown` に向きを持たせず、`actor.<名>.x|y` の tween で書く（`move` の from / to と同じ仕組みで、settle とセーブは PropertyTween のまま効く）。
- `Out.StopSounds`（鳴っている一発の効果音を止める）は外した。App に一発の音を止める口が無く、足すのはエンジンの変更になる（8.3 の C14）。
- 2.2 の鍵の一覧を `Stage` に `pub def` で並べる（今の `ambienceKey` と同じ形）。View とゲームの GameView が同じ鍵を読む。

### 2.6 部品ごとの使い手と、標準に入れる理由（M4）

親の計画 3.15 は「部品にするのは 2 本の作品で要った物だけ」。4 本（血鱗・廃屋配信・kankan・izakaya）で数えた。

| 部品 | 使う作品 | 決めた事 | 理由 |
|---|---|---|---|
| bg の transition | 血鱗（slide）・廃屋配信（black・pan）・kankan・izakaya | 標準 | 4 本 |
| overlay | 血鱗・kankan | 標準 | 2 本 |
| move | 血鱗（shadow・沈む）・izakaya（hop の中身） | 標準 | 2 本 |
| camera（2D の寄り） | kankan | 標準 | 道筋（血鱗・廃屋配信）と同じ鍵を使うので、2D だけを分ける方が手間 |
| shake の強さと on= | 廃屋配信・kankan・血鱗（刺す） | 標準 | 3 本 |
| show / hide の広げ | 血鱗・izakaya・テンプレート | 標準 | 3 本 |
| audio の bgm・all・volume | 廃屋配信 | 標準 | 鳴り続ける音はテンプレートの World だけが鳴らせる（GameCommands は一発の `Out.Sound` しか出せない）。ゲームの口で書く道が無い |
| fx の once・on= | 血鱗 | 標準（引数を足すだけ） | fx は既に標準で、izakaya・テンプレートも使う |
| text（N4b） | kankan | 標準 | 文字の枠はテンプレートの持ち物（7.2）で、GameView から描き方を替えられない。ゲームの口を作るなら枠の描き方を丸ごと外へ出す事になり、もっと大きい |
| speak・話し手を明るく（N4b） | 血鱗 | 標準 | 立ち絵の描き方（Cast）はテンプレートの持ち物。理由は text と同じ。話し手を明るくするのは Ren'Py・Naninovel にもある標準の振る舞い |
| 入力の案内（N4c） | 血鱗 | 標準 | 入力（Controls・Gesture）はテンプレートの持ち物で、ゲームの口が無い。払いで選ぶのはスマホの縦のノベルで使い回せる【推】 |
| メッセージ枠の型（N4b） | 血鱗（縦の大きな枠）・廃屋配信（字幕の形）・kankan（NVL の頁の中の置き場） | 標準 | 3 本 |
| filter | 廃屋配信（blood・crash・カメラの質感） | **ゲームの口**（C10） | 1 本。GameView は world の一番手前に ShaderDoc の板を置けるので、ゲームの口で書ける |
| feed・HUD | 廃屋配信 | **ゲームの口**（C10）。台本の書き方だけ先に決める | 1 本。`GameView.hud`（hud の範囲に描く口・C12）で書ける。親の計画も N6 は作品が増えてからと書いた |
| Backdrop3d（N4d） | 血鱗・廃屋配信 | engine_world（C1） | 2 本 |

### 2.7 書き直して build に通した（数えた物）

- `n4-spike/convert_n4.py` が 2 本の台本を書き直し、`gen_vocab.py` が下書きの vocab.json（2.2 の表と、ゲームのコマンドの表）と、名前を引く Doc の写しを作る。`bin/fge yarn build` は 2 本とも通った（血鱗 11 ノード・廃屋配信 8 ノード。廃屋配信は HUD の変数の宣言を別のノードに置いたので「開かれないノード」の注意が 1 つ出る）。
- わざと 4 つ誤りを入れた写し（`overlay 1.4`・`show gril`・`audio se se_bubbel`・`#act:upp`）は 4 件とも build で落ちた。
- **kankan**: 前の回の書き直し（`vocab-spike/out/kankan.yarn`）に、se の送れない秒を音の Doc へ移す・強い揺れを名前の強さ（`shake strong`）にする、の 2 つだけを足した。それで同じ表で build が通った（20 ノード・組み込みと注釈を除く 378 行が全部標準）。
- **izakaya**: build には通していない。前の回の書き直しの数（演出 89 行のうち hop 8 行だけがゲームの口で、81 行・91.0% が標準）だけ。
- **下書きの vocab の検査の範囲**（本物の表で埋める所）: 下書きは名前の多くを Doc の写し（`build/<game>/assets/*.json`）から照らしたが、次は照らしていない。
  - `show` の 2 つ目の引数（表情・姿）に `ref` が無い（本物は actor の Doc の `faces` から。名前ごとに違う集まりなので、go に「1 つ目の引数の名前ごとの集まり」を引く欄が要る【推】。C2 と一緒にする）。
  - `fx` の `on=` を `marker`（actor の名前 + その `markers` の鍵）で照らしていない（C2 の型が go に入ってから）。
  - `#at:`・`#icon:` は下書きでは決まった一覧で照らした。Doc から集める検査（C3）は、わざと入れた誤りの 4 つに入っていない。
  - 本物の表は、どれも Doc の鍵で照らす。わざと入れる誤りに、表情・点・`#at:` の 3 つを足して確かめる（段 5・6 の完了条件）。

意味が崩れないように直した物（レビューの指摘）:

| 元 | 書き直し | 崩れないための決まり |
|---|---|---|
| `<<lights 1.8>>`（12 行） | `<<overlay 0 time=1.8>>`。住処が見えている 22 行目だけ `<<camera path=lair.arrive>>` を足す | overlay は同じ値なら何もしない（2.2）。今の `Lair.cameraMove` は幕が明けるたびに着く動きを流すが、住処が見えるのは背景の無い間（最初のノード）だけで、その間の lights は 22 行目の 1 行。ラベルは 22 行目が N4d・ほかの 11 行が N4 |
| `<<feed lost>>` | `<<set $stream to "lost">>` | コメント欄を隠すのはゲームの GameView が `$stream` を見て決める（状態を 2 つ持たない） |
| `<<signal 4G 3>>`・`<<signal none>>` | `<<set $signal to "4G3">>`・`"none"` | 回線の字と棒の本数と圏外の出し方は、ゲームの HUD の表（値 → 字と絵）で決める |
| `<<blood>>` | `<<blood>>`（ゲームのコマンドのまま） | filter をゲームの口にした（C10）。一度だけの演出なので、ゲームの側で `TriggerKey` に書けば終わった後に残らない |
| `<<breath>>` | `<<fx bubbles_big once=true on=whale.mouth>>` | 口の点は actor の Doc の `markers` |
| 写真ごとの鯨のずれ（`ScenesDoc.whaleShift`） | 台本は替えない | actor の Doc の `attach: { "bg": { "gem": -1.2 } }`（写真の名前 → 横のずれ）。`transition=slide` の間は背景と同じだけ動く |
| `<<vibrate>>` | `<<shake vibrate>>` | 画面の小さい揺れ（端末は震えない。前の回の issues.md）。強さは `novel.kind.json` の `shakes.vibrate` |
| `<<bg hall2 run 0.4>>` | `<<bg hall2 transition=pan pace=run time=0.4>>` | 2.3 の表 |

### 2.8 GameCommands が標準の舞台を替える口（M2）

- 血鱗の `<<scene 名>>` は鯨の姿・目・少女・スチル・瓶・結末のカードをまとめて替える。新しい形では scene の中身を「標準の命令の並び」（`novel.scenes.json` に `"commands": ["<<show whale corpse time=0>>", …]`）と、ゲームだけの値（深さの決まり → `game.girl.depthRule`）に分ける。
- GameCommands が Cast の層（と背景・覆い）を替えるのは、**`Commands.applyText(ctx, "<<show whale corpse time=0>>", st)` の口だけ**にする。標準の命令を同じ表で読み、同じ検査を通す。Cast の型に直に触らない。
- GameCommands が直に書いてよいのは `game.` の鍵と、標準の数の鍵（`actor.<名>.x` など。`Stage` の pub な鍵の def を使う）。少女の沈み（`sink`）は `actor.girl.y` を書く。
- **最初の sink で住処のカメラが潜る**（今の `Lair.cameraMove` の `diveFrom` と LairDoc の `sinkStartSec`・`sinkSeconds`）: `sink` の GameCommands は、**今の背景が `lair`（`initial` の背景か `<<bg lair>>`）で、かつ** `camera.path` がまだ `lair.dive` でなければ `Commands.applyText(ctx, "<<camera path=lair.dive>>", st)` を当てる（最初の 1 回だけ。今の `diveFrom` が 1 度だけ決まるのと同じ）。潜る動き（前へ進んで回り込み、`sinkStartSec` 秒の後に `sinkSeconds` 秒で沈む）は `paths.lair.dive` の keys にベイクする。348 行目の sink（鯨の写真の上・最後に深く沈む所）では背景が lair でないので当たらない。また **`bg` を替えても `camera.path` と `camera.pathT` は消さない**（5.3）ので、住処へ戻っても潜った後の位置のまま（今の「潜った後は終わりまで戻らない」と同じ）。台本に `<<camera path=lair.dive>>` の行を足す案 (a) は取らない: 22〜55 行目の間に詰められる注釈も空行も無く（数えた）、足すと間の台詞 13 行の行番号（既読の鍵）がずれる。
- N1〜N3 の計画書の 3.6「足したコマンドは PropertyTween にだけ値を書く」を広げる決まりの変更なので、相談 C9 に入れた。
- go の検査: `novel.scenes.json` の `commands` は台本と同じ書き方なので、vocab.json の `from` に足せば go が中も検査できる（preset（N5）と同じ形）。

## 3. N4b — 立ち絵の層の標準のふるまいと文字の枠

| 物 | 形 | 書く所 | 他のエンジン |
|---|---|---|---|
| 話し手を明るく・ほかを暗く | 台詞を出すたびに World が `cast.speaker`（話し手の id。地の文は None・同じ話し手は書き直さない）を書く。View が `novel.cast.json` の `highlight`（`dim`・`seconds`）で描く。暗くするのは話し手が出ている間のほかの人物だけ（小物・背景に付く絵は暗くしない）。替わり目は `PropertyTween.namePreviousAt` で前の話し手からつなぐ。話し手の id は cast の鍵と同じにする。台本には書かない | `cast.speaker`（Snapshot に乗る） | Naninovel の speaker highlight・Ren'Py の `say_attribute` |
| 字を出さずに話す | `<<speak 名>>` が `cast.speaker` を書き、項目の `speakFx`（粒の名前）があれば `markers.mouth` からその粒を一度出す（`speakFx` があるのに mouth が無い Doc は Err） | `cast.speaker`・`fx.once.<粒>`・`fx.onceAt.<粒>` | —（血鱗の言い方を残す） |
| 絵の中の点 | 引数の型 `marker`（`whale.mouth`）。点は `novel.cast.json` の絵ごとの `markers`（画像の中の 0〜1）。名前は Godot の Marker2D に合わせた（Unreal は socket・血鱗の今の Doc は marks） | — | Godot Marker2D・Unreal socket |
| 出ている間は文字の枠を消す | 絵の Doc の `hideWindow: true`。View が「その絵が出ているか」から決める（状態を持たない） | 書かない | — |
| メッセージ枠の型 | `<<window 型>>` の型の名前を `novel.theme.json` の `windows` から引く。型ごとに `kind`（nvl / adv）・`place`（bottom / center。adv の枠）・`frame`（縁取り = panel（地を敷く）/ outline（地を敷かず字を周りの影で縁取る・字幕の形））・`showName`（adv の枠と縦の画面に名前を出すか。横の NVL の頁は名前を出さない）・`quotes`（台詞を「」で包むか） | `Stage.mode` を型の名前（文字）に | Naninovel の printer の種類（Dialogue・Wide・Fullscreen・Bubble）・Ren'Py の ADV / NVL |
| `text` | 2.2 の表の書き方（`at`・`size`・`align`・`speed`・`lock`） | `text.at` `.size` `.align`（名前）・`text.speed`（数）・`text.lock`（一度だけ） | Ren'Py の window の style・Naninovel `@printer`・Tyrano `[position]` / `[delay]` |

- 血鱗の `item`（小物の間は枠を消す・2 行）と `vial gem|bone` の大写し（2 行）の「枠を消す」は `hideWindow` で書ける。
- **Mark v3 の `mode` の読み替え**: N3 の Mark v3 は `"mode": "Nvl"` / `"Adv"`（enum の名前）を書く。N4b で型の名前（文字）に替えるので、Mark の読み手は `novel.theme.json` の **`legacyModes`**（`{ "Nvl": "nvl", "Adv": "bottom" }`。空の舞台の Nvl もここで引く）の行き先と読む（レビュー 2 で、`windows` の鍵の字の順で決まる形から替えた）。行き先が無い・windows に無い・出し方が違う Doc は、読み込みの時に 1 行ずつ知らせ（`ThemeDoc.legacyProblemsOf`）、その出し方の最初の型（鍵の順。その出し方の型が無ければもう一方の出し方の最初の型）へ落ちる。新しいゲームの最初の型は `ThemeDoc.startWindowName`（legacyModes の Nvl の行き先が nvl の型ならそれ、無ければ nvl の最初の型、nvl の型が無ければ adv の最初の型）。書く方は型の名前（`WorldRead.restore`・`World.emptyRead` で本当の名前に直す）。Mark の version は 3 のまま、値の形で見分ける（Doc の型の名前に `Nvl`・`Adv` を使わない決まりは、schema の方言に鍵を縛る欄が無いので、読み手が落としてテストで止める）。型ごとに default を付ける案は、同じ出し方の型が 2 つ default を持つ食い違いを読み手が決めることになるので取らなかった。
- `<<text at=>>` は NVL の頁の中の置き場なので、ADV の型の間に書くと Err（ADV の枠の置き場は型の `place`）。
- `Page.show` は型の `kind` だけを見る。

## 4. N4c — 払い・タップで選ぶ選択肢と入力の案内

- 書き方は血鱗のまま: `-> 案内 #act:up|down|left|right|tap [#at:名] [#icon:名] [#mute]`。組の全部の選択肢に `#act:` があれば、ボタンを出さずに案内を出して操作を待つ。選んだら今の `Choose(番号)` の道を通るので、セーブ・ロード・戻るはふつうの選択肢と同じ（血鱗の Gate の決まり）。
- 名前: 部品は「入力の案内」（input prompt。Unity の Input System・Xbox の button prompt の言い方）。QTE（quick time event）は時間の制限がある物の名前で、血鱗の払いには時間の制限が無いので使わない。
- タグの検査（C3）: 今の go はタグの値を決まった一覧で照らす。`#at:` と `#icon:` の値を `novel.prompts.json` の鍵から集める（`from`）ように go を広げる。`#act:` は決まった一覧のまま。
- 新しい Doc `novel.prompts.json`: `icons`（名前 → 絵（project.json の textures・正方形に貼る）と色）・`arrow`（矢印の色・流れる速さ・矢印の真ん中の高さ）・`edge`（押し始めが左右の端からこの幅の内なら払いにしない帯）・`targets`（名前 → `photo`（背景の写真）か `actor`（名前付きの絵）と、その矩形の中の `rect`（0〜1））・`pulse`（tap の輪の脈打つ速さと広がり）。血鱗の `ScenesDoc.targets` をここへ移す（血鱗の鯨の姿の上の当たる物は、移行で `actor` に書く）。
- 移す物（血鱗から）:
  - `Gate`（79 行）と `Hint`（200 行）を World・View へ。
  - Controls と Layout の払いの判定（約 240 行【推】）を Controls と `Gesture` へ。
  - キーボード（矢印のキー）とマウスのドラッグでの払い。
  - オートとスキップの時の振る舞い（どちらもゲートで止まる。今の血鱗の決まり）。
  - flow で払う手順。今は `wait … at=x,y mouse` を 4 行並べている（route_gem.flow）。**決めた事（段 6）**: ゲートでは役のキー（`tap prev`・`tap next`・`tap left`・`tap right`・tap の選択肢が 1 つなら `tap confirm`）が払いになるので、それを正にする。flow の語彙に `swipe` を足すのは engine_world の `Flow` を替えることになり C の承認の外。マウスのドラッグ（`wait … at= mouse`）も今のまま使える。
  - E2e の問い `gate`（`until gate=tap:gem`）をテンプレートの問いに。
- テンプレートの既定の案内は「矢印 + 字」だけにする。血鱗の赤いナイフは `icons` の 1 つとして Doc で足す。

## 5. N4d — 3D の背景 `Backdrop3d`

### 5.0 決め（2026-11-16）: `Backdrop3d` は作らず、汎用の口だけにする

人の指示「無理矢理な命令になりそうであれば、切り上げるか、汎用な命令にまとめて進みましょう」を受けて、5.3 の形をやめる。
5.3 の `animated` の 4 種（振り子・くらげの道筋・粒の層・光だまりが電灯を追う）と道筋・揺れ（creep・chase）は、2 本のどちらか 1 本だけの物で、
2 本で共通なのは「glb を光なしで描く」「届く前・読めない時は still で進める」だけだった（血鱗は休みの位置で動き続ける・廃屋配信は部屋から部屋へ歩く）。
抽象の境目は実装が 2 つある所にだけ置く（`docs/flix-conventions.md` の「層を置く物差し」）ので、ここは境目にならない。

- **やめる物**: engine_world の `Backdrop3d`（C1）・`novel.backdrops3d.json`・`<<camera path=>>` の専用の命令・`animated` の種類の表。3D の描き方と道筋・揺れ・粒は各ゲームの GameView と Doc に残す。
- **テンプレートに置く汎用の口**（段 9 の口と同じ種類なので、段 8 と 9 を 1 つにまとめる）:
  1. 背景をゲームが描く口: `<<bg 名>>` の名前に対し、ゲームが背景の層（層の番号 0）を描けるなら描き、描けない・届いていない時はテンプレートが still の写真を描く（fail-open。`needs` は still だけ・3D の素材は待たない・`Ctx.isLoaded` は描き出しと flow では全部 true。5.4 の「素材を待つか」の行はそのまま生きる）。
  2. 背景を替える時間をゲームが決める口: `bg` の apply がゲームに「この切り替えに何秒かけるか（と、その間に鳴らす音の Timeline）」を聞く。無ければ今の `transition=`・`pace=` の秒。歩いている間は次の台詞を出さない（5.4 の「文字を待たせる」）・Silent とスキップでは 0 秒・音は物語の時計（5.4 の「鳴らす音」の行）。
  3. カメラの道筋は専用の命令にせず、既にある `game.<鍵>` の tween（PropertyTween）で書く（例: `game.lair.pathT` を 0→1）。ゲームの GameView がその値を読んで 3D のカメラを置く。
  4. 最初の背景（`initial`）とタイトルの背景（`title`）は `novel.backdrops.json` に置く（5.3 の箇条のまま。3D に限らない汎用の欄なので残す）。縦と横の決まり（5.5 の still の切り抜き）もテンプレートの still の描き方として残す。
- 足りない時: 2 本の移行（段 11・12）で、この口で書けない物が出たら、その時に足すかを決める（先回りして足さない）。

### 5.1 比べる前に分かる事

| | (a) Blender で動画・連番に書き出して 2D で流す | (b) glb + 光を当てない絵（光は絵か lightmap にベイクする） | (c) 実行中の光と影 |
|---|---|---|---|
| 今の 2 本 | — | **2 本ともこの形**（血鱗の Lair3d・廃屋配信の Rooms + Walk。写真を粗い箱に投影した glb を光なしで描く） | — |
| エンジンに要る物 | 動画を読む部品が無い。Web は `<video>` を texture に写せる【未確認】が、デスクトップ（JVM）は新しいデコーダーが要る（新しい機種の切れ目 = `Platform.Services`） | 全部ある（Gltf・Scene3d・`Scene3d.Lightmap`・uv2・Billboard の unlit・`Model3d.findNode` / `nodesByName`） | ある（`LightModel3d`・影） |
| 大きさ（測った物） | 廃屋配信の歩きの動画 20 秒を書き直した（`n4-spike/walk_*.mp4`）。540×960 の H.264: crf 28 = 2.0 MB・crf 32 = 671 KB。360×640 の crf 28 = 654 KB。VP9 crf 36 = 5.0 MB。歩きは全部で 62.3 秒（道筋 16 本の out 32.7 秒 + arrive 29.6 秒。walks.json から数えた）なので、**540×960 の crf 28 で 6.2 MB（今の 4.5 MB より大きい）・crf 32 で 2.1 MB**【推】。元の動画は UI と粒状のノイズ込みで、背景だけならもっと小さい【推】 | 廃屋配信 `assets/walk` 4.5 MB（glb 13 個・jpg 13 枚・walks.json 309 KB）。血鱗 `assets/lair` 1.9 MB（glb 518 KB・still 132 KB・絵 6 枚） | (b) と同じ形 + 法線と材質の絵 |
| 読んでいる間の動き | 血鱗の住処は読んでいる間ずっと動く（電灯の振り子・くらげ・粒）。動画なら継ぎ目の無いループを作る | 毎コマ、カメラと動く部品だけを動かす | 同じ |
| 縦横の画面 | 画面の比ごとに書き出しが要る | 5.5 の決まりで 1 組 | 同じ |
| 速さ | デコードだけ | fps3d_lab の部屋で p50 8.8 ms（**デスクトップの値**・記録）。スマホの値は無い【未確認】 | fps3d-room で 46.5 fps・cpu 20.7 ms（Galaxy S24 Ultra・記録）。2 本の絵は手で描いた光なので、実行中の光を足すと絵に合わせ直しになる |
| 揺れ・暗くなり | 書き出しにベイクすると、タップで飛ばす・走る/歩くの選び直しができない | 実行時に足す（廃屋配信の creep・chase の揺れ） | 同じ |

ここまでで (a) には「デスクトップで流す口を新しく作る」重さがあり、(c) には「2 本の絵の作り方を替える」重さがある。どちらも 2 本の今の見た目を変えずに移す目標と合わない。**(b) を本命にし、スパイクは (b) の lightmap 版が今の「絵に光を描き込む」版より良いか、と (a) の大きさの確かめに絞る。**

### 5.2 スパイクの手順（血鱗の住処・段 7 で）

1. 物差しを先に決める: (i) 届く大きさ（gzip の後）(ii) S24 Ultra での 1 コマの cpu と gpu の ms（`FrameDiagnostics`）(iii) 休みの位置のコマと `lair_still.jpg` の差（画素の差の平均と最大）(iv) 5.5 の 3 つの画面の大きさで崩れないか。
2. (b-1) 今のまま（光を絵に描き込んだ glb）を基準として測る。
3. (b-2) Blender で lightmap を焼き、uv2 付きの glb + lightmap の絵にして `Scene3d.withLightmap` で描く。光の筋・床の光だまりを lightmap に入れて、毎コマの板（`fx_pool`・`fx_beam`）を減らせるかを見る。
4. (a) Blender で休みの位置から 8 秒の着く動きと 10 秒のループを 540×960 で書き出し、大きさだけ測る（流す部品は作らない）。
5. (c) は測らない（5.1 の理由）。ただし `LightModel3d` で電灯の振り子に合わせて光が揺れる版を 1 コマだけ描き、(b) のベイクした光より良く見えるかを人に見せる（揺れる光はベイクできないため）【推】。
6. 表にして人に見せ、(b-1) と (b-2) のどちらを部品の既定にするかを決める。どちらでも部品の形（5.3）は同じ。

### 5.3 部品の形

```jsonc
// assets/novel.backdrops3d.json（新しい Doc）
{ "version": 1,
  "walkOn": ["black", "pan"],
  "backdrops": {
    "lair": { "glb": "lair/lair.glb", "textures": ["lair/tex/lair_bg.jpg"], "lightmap": null,
              "still": "lair",                   // novel.backdrops.json の photos の名前（3D が読めない時と描き出しの基準）
              "rest": { "eye": [0, 1.0, 0], "yaw": 0, "pitch": 0.10472, "hfov": 0.62 },
              "fog": { "color": "#1d5a74", "near": 2, "far": 16 },
              "animated": [ { "node": "lamp", "kind": "sway", "pivot": [0.15, 3.25, 5.06], "deg": 5, "period": 7 },
                            { "node": "jelly_*", "kind": "path", "keys": "jellyLow", "pulse": { "every": 2.4, "squeeze": 0.2 } },
                            { "kind": "billboardParticles", "texture": "lair/tex/fx_mote.png", "layers": [ … ] },
                            { "node": "pool", "kind": "followPoint", "of": "lamp" } ] } },
  "paths": {
    "lair.arrive": { "backdrop": "lair", "keys": [ … ], "drift": { "amp": [0.03, 0.02], "period": [7.3, 9.1] } },
    "lair.dive":   { "backdrop": "lair", "keys": [ … ] },     // 前へ進んで回り込み、5 秒の後に 3 秒で沈む（LairDoc の move をベイクした物）。終わりの位置のまま
    "gate>entrance_out": { "from": "gate", "to": "entrance_out", "pace": "walk", "out": [ … ], "arrive": [ … ], "repeat": null,
                           "shake": "creep", "fade": { "out": [0.6, 1.0], "arrive": [0.0, 0.4] }, "dissolve": 0.5,
                           "sounds": [ { "t": 0.4, "part": "out", "name": "se_step" } ] } },
  "shakes": { "creep": { … }, "chase": { … } } }   // 廃屋配信の walks.json の shake.byMood
```

- **最初の背景**: `novel.backdrops.json` に `"initial": { "photo": "lair", "grade": "clear" }` を足す。背景が無い間（`Stage` の `shot` が None・最初の `<<bg>>` の前）は、この背景を描く。今の血鱗の「背景が無ければ住処」と同じ動きで、台本に行を足さない（台詞の行番号を守る）。v2 のセーブで `photo` が null の物も、この背景で戻る。
- **タイトル画面の背景は initial と分ける**: 今の血鱗のタイトルは住処ではなく、海中の遠景の 2D の絵（`Lair.titleBackdrop`: 画面いっぱいに敷き、1.05 倍に広げ、sin でゆっくり漂わせる）。同じ Doc に `"title": { "photo": "title_sea", "scale": 1.05, "drift": { "amp": [10, 6], "rate": [0.13, 0.09], "phase": [0, 1.0] } }` を置き、テンプレートのタイトル画面がこれを描く（photos に `title_sea` = 今の `titleBackdrop` の絵）。値は今のコードの数のままなので、reference の `title.png`・`portrait-title.png` の SHA は変わらないはず。10 章の門でも見る。`title` が無いゲームは今のテンプレートのタイトルのまま。
- still の名前は `novel.backdrops.json` の photos の名前。血鱗の photos に `lair`（絵は今の `assets/lair/lair_still.jpg`）を足す（9.1）。
- `bg` を替えても `camera.path` と `camera.pathT` は消さない（道筋は背景ごとの物なので、別の背景の間は読まれないだけ）。
- 台本: `<<bg 名>>`（Doc に 3D があれば 3D・無ければ写真）、`<<camera path=名 time=>>`（`camera.path` と `camera.pathT` を 0→1 へ tween。settle で終わりの位置）、背景から背景へ歩く道筋は 2.3 の表（台本に道筋の名前を書かない）。
- `animated` の `kind` は 2 本で要った 4 つだけ: `sway`（振り子）・`path`（くらげ・道筋を往復）・`billboardParticles`（粒の層）・`followPoint`（光だまりが電灯を追う）。くらげの傘の縮み（`pulse`）は 1 本だけの物なので `path` の小さな欄に留める。足りない物はゲームの GameView で描く（3D の上に 2D を重ねる）。
- glb の node は `Model3d.findNode`（1 つ）・`Model3d.nodesWithPrefix`（`jelly_*` のような頭の一致）で引く。毎コマ引くなら `Model3d.nodesByName` を読み込みの時に 1 回作る。
- 届く前・読めない時は still で進める（fail-open）。台本の流れと時刻は 3D の有無で変えない。
- シェーダーは部品の中。ゲームが選べるのは fog・lightmap の有無・ShaderDoc の名前まで。
- 揺れ（creep・chase）の式は廃屋配信の `Walk` の式（歩みの上下・うなずき・横の揺れ・手ぶれ）をそのまま部品へ移す。Camera3d に roll が無い件（今のコメント）はそのまま持ち越す。動きのぶれ（`motionBlurShutter`）と四隅の暗さ（`darken`）も部品の中。

### 5.4 道筋の秒・音・暗くなり・揺れの持ち主（M7）

| 物 | 持ち主 | 形 |
|---|---|---|
| 歩く秒 | `bg` の apply | Doc の道筋の out + arrive × repeat + dissolve の秒を足して、背景の重ねの秒（`fadeSeconds`）と `camera.pathT` の tween の秒に書く。台本の `time=` は道筋がある時は使わない（今の廃屋配信と同じ） |
| どの道筋を歩くか | `bg` の apply | 今の場所・行き先・`pace`・`walkOn` と、`Ctx` に足す `isLoaded`（その glb が届いているか）で決め、`Stage` の背景に道筋の名前を書く。届いていなければ 2D（今の廃屋配信の `roomsReady`）。Silent とスキップの時は歩かない（秒 0） |
| 素材を待つか | `bg` の `needs` と `Ctx.isLoaded` を使い分ける | `needs` には still の写真だけを入れる（今と同じく、届くまで黒で待つ）。glb と 3D の絵は `needs` に入れない。3D は待たない（fail-open）: 届く前は待たずに 2D で切り替え、届いた後の切り替えから 3D になる。`isLoaded` は描き出しと flow では全部 true（全部を読んでから流す）なので、門の比べで揺れない |
| 鳴らす音 | **World**（物語の時計） | 道筋の `sounds` から `Timeline` を作り（読み込みの時に 1 回。`Timeline.insert` と `withSoundAt`）、毎フレーム `Timeline.soundsOnClock(物語の時計, 歩き始めた時刻, tl)` で鳴る音を出す。時計は物語の時計（`Clock.Clock[Stage.Story]`。画面を開くと止まる。背景の重ねと `<<wait>>` と同じ時計）。実時間で鳴らす `soundsBetweenTimes`（App の `realNow` を渡す口）は使わない。画面を開いている間に足音が鳴り進まないようにするため。`Out.Sound` と同じ道（World の出来事）を通るので、Silent では鳴らず、tape.json の `sounds` にも出る。今の廃屋配信の `Controls.walkSounds` の置き場をテンプレートの World に移す形 |
| 暗くなり・継ぎ目 | View（状態を持たない） | Doc の `fade` と、歩き始めてからの秒から決める |
| 揺れ | Backdrop3d の部品（状態を持たない） | Doc の `shake` と、歩き始めてからの秒（creep は歩いた距離）から決める |
| 文字を待たせる | World | 歩いている間は次の台詞を出さない（廃屋配信の `testLineWaitsUntilTheWalkEnds`）。Yarn の `<<wait>>` ではないので、ブックマークの steps は増えない |

- 歩き始めた時刻は `Stage` の背景の `fadeFrom`。セーブは settle した後なので、歩きの途中の状態は持たない。

### 5.5 縦と横・画面の大きさ

- 2 本とも縦（`portraitDesign` の幅 540・高さ 960 以上）で、スマホでは縦に長い画面になる。
- 決まり: 3D の背景は **横の画角（hfov）を固定**にする（Godot の Camera3D の `keep_aspect = KEEP_WIDTH`）。縦に長い画面では上下が多く見える。
- still は一番縦に長い画面（9:21【推】）で描き出した 1 枚にし、画面ごとに真ん中を切り抜いて敷く。3D も同じ横の画角なので、休みの位置で still と重なる。
- `rest` は 1 組のまま。今の 2 本が縦に長い画面でどう合わせているかは【未確認】。移行の門の画面の大きさ 3 通り（10.2）で見張る。

## 6. N6 — HUD と流れるメッセージ（形の案だけ。今回はゲームの口）

### 6.1 HUD は Yarn の変数を読む

```jsonc
// 後で標準にする時の assets/novel.hud.json の案
{ "version": 1,
  "items": [
    { "kind": "text",  "var": "viewers", "format": "{} 人", "at": "topRight", "hideWhen": -1 },
    { "kind": "icon",  "var": "signal",  "map": { "4G3": { "label": "4G", "icon": "bars3" }, "none": { "label": "圏外" } }, "at": "statusBar" },
    { "kind": "gauge", "var": "battery", "max": 100, "low": 20, "at": "statusBar" },
    { "kind": "clock", "var": "stream",  "startWhen": "live", "format": "mm:ss", "at": "topLeft" },
    { "kind": "clock", "real": true, "format": "HH:mm", "at": "statusBar" } ] }
```

- 台本は `<<set $battery to 31>>`。値は YarnStorage にあるので、セーブ・戻るは今の道で戻る。go の `yarn check` は変数の宣言を見ていて、`novel.story.json` の `vars` に表示名があればテープの状態の表にも出る（親の計画 3.19）。`<<if $battery < 10>>` の分岐もそのまま書ける。
- **今回はこの表を読む部品を作らず、廃屋配信の `GameView.hud` が変数を読んで描く**（今の状態バーのコードを、Stage の値でなく変数を読むように替える）。
- 廃屋配信の台本には `<<declare>>` が 0 件だった（数えた）。HUD の 4 つの変数（`$battery`・`$viewers`・`$signal`・`$stream`）の宣言と初めの値（まだ出さない = -1・`"none"`・`"off"`）を、台本の行番号を変えないように別のノード（`hud.yarn`）に書く。go は「開かれないノード」と 1 行知らせる（止めない）。
- **別案と比べた**（`alt.py`・廃屋配信の 15 行）: `<<hud battery 31>>` のようにコマンドで書く案は字が短い（273 字。変数の案は 384 字・1.41 倍）。ただしコマンドの案は値が `Stage` にしか無く、分岐の式から読めず、テープの状態の表にも別の口が要る。時間で動くゲージ（`time=`）が要る所は 2 本で 0 だった。**変数の案に決めた。**
- `clock` の `startWhen` の時刻（標準にする時）: World が台詞と命令を当てるたびに HUD の Doc に出てくる変数だけを見比べ、替わった物語の時刻を `hud.<変数>.since` に書く（Snapshot に乗る）。廃屋配信の今の形（配信を始めた時刻を Stage に持つ）は、ゲームの側でも同じ形で書ける。
- `clock real:true` は実の時刻なので、描き出しと門では flow の中で時刻を固定する（10.6）。

### 6.2 流れるメッセージ（`feed`）

| | 形 |
|---|---|
| 台本 | `<<feed "本文" from=名 [tone=plain\|red]>>`・`<<feed clear>>`（廃屋配信の comment・comment_red・comment_clear の 3 つを 1 つに） |
| 今回の置き場 | 廃屋配信の `GameCommands` の `feed` と `GameView.hud`。列は PropertyTween の `game.feed.<番号>.*` の鍵で持つ（下の比べ） |
| 標準にする時の Doc | `novel.feed.json`: 置き場・行の数・流れる向き・tone ごとの色・`authors`・出る時の効果音・`stagger`・`hideWhen` |
| 引数の型 | `text`（`"…"`。C2）。`from` は自由な字 |
| 他のエンジン | 同じ名前の標準は無い（Ren'Py は NVL の頁で、Naninovel は custom UI で作る）。SNS・配信の画面の「feed」の呼び方 |

**コメントの列の持ち方: 2 案を比べた**（R3）

| | (i) `Stage` に `game` の欄（型の無い JSON 1 つ）を足し、`GameCommands.settle(game: Json): Json` の口も足す | (ii) PropertyTween の `game.feed.<番号>.*` の鍵（列の長さに上限） |
|---|---|---|
| 形 | ゲームが列を JSON に入れて読み書きする。settle はゲームが書く | 枠を N 個（コメント欄に見える数。Doc の `rows`）持つ。`<<feed>>` は次の枠（`game.feed.next` の数で回す）に `text`・`from`・`tone`（名前）と `seq`（数・並べる順）を `setName` / `setNum` で書き、出る動き（`enter`）を `trigger` で書く。`delay` で時間差に出せる |
| settle | ゲームが書く（書き忘れると、settle の後も途中の動きが残る） | PropertyTween の settle がそのまま効く（遅れて出る物も出し切り、出る動きは消える） |
| セーブ・戻し | ゲームが型と JSON の往復を書き、ゲームのテストで確かめる | PropertyTween の JSON がそのまま運ぶ。往復はテンプレートのテストが見ている |
| 決まりの抜け道 | 型の無い JSON に何でも書けるので、「後に残る値は PropertyTween に書く」決まりの外に出られる | 決まりの中 |
| 書けない物 | — | 見える数より古いコメントは消える（今の廃屋配信のコメント欄も見える数しか出さない【推】） |

**決めた: (ii)**。`Stage` の `game` の欄は足さない。列を持つ作品が別に出たら、その時に (i) を `settle` の口とゲームのテスト付きで相談する。

## 7. 置き場

### 7.1 テンプレートに残す物と engine_world へ上げる物（M1）

**前に決めた事**（[novel-vocab-design.md](novel-vocab-design.md)）:
- 9 章の 2: コマンドの中身（bg・show など）は N2 ではテンプレートに置き、N4 でエンジンへ上げる。
- 5 章: `PropertyTween` は N4 までテンプレート。N4 でコマンドの中身と一緒にエンジンへ上げる。
- 3.6 の O3: N4 で標準の表がエンジンに上がったら、標準の表はエンジンの版と一緒に配り（go が持つ）、ゲームの `vocab.json` には GameCommands の分だけを書く。

**この版の案**（相談 C8）: 標準のコマンド・Stage・Cast・`PropertyTween`・Doc の読み手はテンプレートに置いたまま、テンプレートの追随を上書きにする（7.2）。O3 の目的（標準の表をゲームごとに書き出し直さない・ゲームの vocab.json には自分の分だけ）は、テンプレートが持つ `assets/talk/vocab.std.json`（標準の表・テンプレートの追随で上書き）とゲームの `vocab.json`（GameCommands の分と `from`）を go が合わせて読む形で守る。

| | (A) 前の決めた事: engine_world へ上げる | (B) この版の案: テンプレートに置き、追随を上書きに | (C) 混ぜる: `PropertyTween` と `Commands` の型だけ engine_world、中身はテンプレート |
|---|---|---|---|
| 上げる量 | コマンドの中身が使う Stage・Cast・CastDoc・BackdropDoc・KindDoc・Res の Doc の組まで（テンプレートの約 1,500 行【推】）。中身は Res の Doc を読むので、中身だけを上げられない | 0 | 約 450 行（PropertyTween 187・Commands の型の部分）【推】 |
| 語彙を 1 つ足す時 | エンジンのリリースが要る | テンプレートだけ | テンプレートだけ |
| ゲームの追随 | エンジンの版を上げるだけ（テンプレートの残りの約 5,500 行は今のまま当て直し） | テンプレートのファイルを上書き（ゲームが直していない事を門で守る） | (B) と同じ |
| O3 | go がエンジンの版の表を持つ | テンプレートの `vocab.std.json` | (B) と同じ |
| 「層は実装が 2 つある所にだけ」 | 使い手はノベルのテンプレート 1 つ | 合う | `PropertyTween` の 2 つ目の使い手がまだ無い |
| N7（共通のプレイヤー 1 本）への道 | 半分（残りはテンプレート） | テンプレートの持ち物がそのまま共通のプレイヤーになる | (B) と同じ |

**勧め: (B)**。前の決めた事の理由は「ゲームが写しを持たずに済む事」だった。(A) でも残りの約 5,500 行の写しは残る。(B) の上書きなら写しの手間そのものが消える。engine_world へ上げるのは、実装が 2 つある物だけにする:

| 物 | 置き場 | 理由 |
|---|---|---|
| `Backdrop3d`（部品と Doc の読み手） | engine_world（C1） | 実装が 2 つある（血鱗の Lair3d・廃屋配信の Rooms + Walk） |
| 引数の型 `marker`・`text` | engine_world の `YarnCommands.Param`（C2） | 型の表は engine_world にある（N2）。go の検査と同じ型 |
| `Curve.Ease` の名前を足す時 | engine_world | 今の 26 で足りる見込み【推】 |

### 7.2 ゲームが持つファイル（M13）

N4〜N6 の後にゲームが持つ .flix は次だけにする。ほかのテンプレートのファイルはゲームで直さない。追随は「テンプレートのファイルを上書き → `flix check`」になる。

| ファイル | 中身 | 今あるか |
|---|---|---|
| `src/GameCommands.flix` | ゲームのコマンド | ある（N2） |
| `src/GameView.flix` | `draw`（world の層・層の数つき）と ★`hud`（hud の範囲）と ★`objects`（tape.json の画面の物に出す矩形。10.2 の id の表） | `draw` だけある |
| ★`src/GameRes.flix` | ゲームの Doc を読む（血鱗の ScenesDoc・LairDoc など）・Res に入れる値の型 | 無い（C12） |
| ★`src/GameBoot.flix` | 起動の時の口（血鱗のドットのアトラスを `App.withSpriteAtlases` で渡す・後から取る素材） | 無い（C12） |
| `src/E2e.flix` の `gameProbes` | ゲームの問い（`place`・`viewers`・`ending` など） | 問いの表はテンプレートの E2e の中（口を分ける） |
| `src/Shots.flix` の `extra()` | コードで組む場面（3D の部屋） | ある（N1） |
| `src/game/*.flix` | 上の口が呼ぶ、1 本だけの部品（血鱗の Whale・Vial など） | 決まりだけ |

- 血鱗が今テンプレートのファイルを直している 3 か所の行き先:
  - Art のアトラス（Game の `App.withSpriteAtlases`・View）→ `GameBoot` と `GameView`。
  - ScenesDoc（Res）→ `GameRes`。
  - 縦の Layout・Controls → 払いは N4c で標準。残りの縦の Layout の違いは、当て直してから数えて Doc（`novel.portrait.json`）へ出す【未確認】。
- それでも直したい所が出たら、テンプレートに口を足す（ゲームでは直さない）。
- `make template-sync`: テンプレートのファイルを上書きし、ゲームが直したテンプレートのファイルの一覧を出す。コミット前の門は、テンプレートの持ち物（`templates/sound-novel-starter` から写したファイルの名前の一覧を `.template-files` に置く）が直されていたら知らせる（止めない）【推】。
- 止めないので、知らせが流れて見落とされうる。そこで **段 10 と移行の段（11・12）の作業に「template-sync の一覧を毎回見て、0 件か、口を足す相談に回したかを書く」を入れる**。移行の完了条件は一覧が 0 件（直したテンプレートのファイルが無い）。

## 8. 相談事

**決め（2026-11-15）**: 人が 8.2 の C2・C3・C7 の替わった所と、8.3 の C8〜C13 を「おすすめで進めて」と承認した。どれも勧める案で作る。

### 8.1 承認済み（人が「足していいよ」と言った・2026-11-15）

| # | 足す・変える物 | 根拠 | 別案 |
|---|---|---|---|
| C1 | **取りやめ（5.0・2026-11-16）**。元: engine_world に `Backdrop3d`（Doc の読み手・休みのカメラ・道筋・揺れ・`animated` の 4 種・still への fail-open）。pub は 20 前後【推】。engine（core）は変えない見込み（要る物は全部ある。5.1） | 2 本が別々に約 920 行と約 530 行を書いた（親の計画 1 章）。同じ形（glb を光なしで描き、休みのカメラで still と合わせ、Blender の道筋で動かす） | テンプレートに置く・ゲームに残す |
| C2 | engine_world の `YarnCommands.Param` に `marker`（`名.点`。第 1 版では `point`）と `text`（`"…"`）の型。go の検査も | N1〜N3 の計画書の 3.3 で N4b と N6 に回した型 | `name` で受けて apply で割る |
| C3 | go がタグの値を Doc の鍵から集める（`#at:`・`#icon:` を `novel.prompts.json` から）。第 1 版の「タグの型」は、今の go が決まった一覧の照らしを既に持っていたので「Doc から集める」所だけになった | 今は `#at:` の打ち間違いが実行まで分からない | タグは決まった一覧のまま |
| C4 | `Out` に `Wait` と `StopSounds`（テンプレート） | `se wait`・`audio all off` | 台本で `<<wait 秒>>` |
| C5 | テンプレートの追随を上書きにする決まりと `make template-sync`・コミット前の知らせ | 追随の手間が一番大きい（親の計画 1 章） | 今のまま当て直す |
| C6 | 動画を流す部品は作らない（N4d は (b)） | 5.1 | スパイクで (a) が勝てば作る |
| C7 | 移行の門の道具 `bin/fge migrate diff`（go）と、FlowVideo の書き出しに足す欄 | 前と同じ動きかを機械で見る | 人が動画だけを見る |

### 8.2 中身を変えた相談事（承認の後に第 2 版で替えた）

C2・C3・C7 は承認の後に中身が替わったので、**替わった所だけを人に聞き直す**（承認そのものは残す）。聞き直すまで、替わった所は実装しない。

| # | 何が替わったか | なぜ |
|---|---|---|
| C2 | 型の名前を `point` から `marker` に | 業界の呼び方（Godot の Marker2D）にそろえた |
| C3 | 「タグの型を vocab.json に書く」から「タグの値を Doc から集める」に縮んだ | go が決まった一覧の照らしを既に持っていた（`check.go` の `checkTags`） |
| C7 | 門の道具に、world の層だけのコマの書き出し・カバー率・古いセーブの読み戻し・門そのものの確かめを足した（10 章）。FlowVideo に足す欄も広げた | M9〜M11・M8 |

### 8.3 新しい相談事（2026-11-15 に勧める案で承認）

| # | 足す・変える物 | 根拠 | 別案 |
|---|---|---|---|
| C8 | **N1〜N3 の決めた事を替える**: コマンドの中身と `PropertyTween` を N4 でエンジンへ上げず、テンプレートに置く。O3 はテンプレートの `vocab.std.json` で守る（7.1） | (A) でも写しの約 5,500 行が残る。(B) の上書きなら写しの手間が消える。語彙を足すたびにエンジンのリリースが要らない | (A) 前の決めた事のまま上げる・(C) 型だけ上げる |
| C9 | **N1〜N3 の計画書の 3.6 の決まりを広げる**: GameCommands は `game.` の鍵に加え、標準の数の鍵（`actor.<名>.*` など）を書いてよい。Cast の層・背景・覆いを替えるのは `Commands.applyText` の口だけ（2.8） | 血鱗の scene（鯨・目・少女・スチルをまとめて替える）と sink（少女の高さ）。標準の命令と同じ検査を通るので、Cast の型をゲームに見せずに済む | (i) scene を N5 の preset に回し、移行を N5 の後にする (ii) Cast の pub な関数をゲームに開く（型が外に出る） |
| C10 | filter と feed（と HUD の描き方）を標準にせず、廃屋配信のゲームの口に置く（2.6） | 1 本でしか使わない（親の計画 3.15）。親の計画も N6 は作品が増えてからと書いた。台本の書き方は先に決めておくので、後で標準へ移しても台本は直さない | 標準にする（廃屋配信の残る Flix が約 300 行減り、台本の 97.2% が標準になる） |
| C11 | `GameView.draw` の型を `(層の数, 物)` の列に替える（2.4） | 血鱗の重ね順（鯨 300 → 傷 305 → スチル 330 → 少女 600）を 1 帯では描けない | GameView に帯を複数（actor の前・後）持たせる（血鱗の 300〜336 の間の差し込みは書けない） |
| C12 | テンプレートにゲームの口を足す: `GameRes`（ゲームの Doc）・`GameBoot`（起動）・`GameView.hud`（hud の範囲）・`GameView.objects`（tape.json の画面の物）。第 2 版の「`Stage` の `game` の欄（JSON 1 つ）」はやめた。settle と戻しの決まりが無く、PropertyTween だけに書く決まりの抜け道にもなるため（6.2 の比べ。コメントの列は `game.feed.<番号>.*` の鍵で持つ） | 7.2 の 4 つだけでは血鱗の Art・ScenesDoc を持てず、ゲームの絵を tape.json の画面の物に出せない | ゲームがテンプレートのファイルを直してよいとする（C5 の上書きが崩れる）・`Stage` の `game` の欄に `GameCommands.settle(game: Json): Json` の口を付け、型と JSON の往復をゲームのテストで見る（6.2 の (i)） |
| C14 | **相談中**: 鳴っている一発の効果音を止める口（`Out.StopSounds` と App の口）。`audio all off` で効果音も止めたい作品が出たら、エンジンに足すかを決める | 2.5 から外した（段 3） | 足さない（今は鳴り続ける音だけ止める） |
| C2 の広げ（scope・`*`）**承認済み（2026-11-16）** | engine_world の `YarnCommands.Row` の `scope` と `Param.scopedBy`、go の from の keys / path の `*` の段と、引数の `scope` の照らし。段 5 で入れた（コードは入っている） | C2 の承認は `marker` と `text` の型と go の検査だった。`<<show 名 表情>>` の表情を名前ごとの faces で照らす（2.7 の「名前ごとの集まり」・段 5・6 の完了条件）のと、`marker` を `cast.*.markers` から集めるのに要った | 表情専用の型を足す・表情は照らさない |
| C13 | 公開済みの古いセーブ: 血鱗は読む（v2 の Mark を今のテンプレートの読み手で読み、既読の鍵と台本の行番号をそろえる）。廃屋配信は読まずに「版が違うのでセーブを読めない」と知らせる（9.4） | 血鱗は公開済み。廃屋配信は選択肢が無く 10 分ほどで読み終わり、古い Mark にゲームだけの欄（視聴者数・電波・バッテリー・配信の表示）がある | 廃屋配信もゲームの口で読み替える（約 40 行【推】） |

## 9. 2 本の移行

### 9.1 台本の行（書き直して build に通してから数えた）

`//` で始まる行は数えない。`wait`・`jump`・`stop` は Yarn の組み込みなので分母から外す。下書きの vocab（`n4-spike/build/<game>/assets/talk/vocab.json`）で `bin/fge yarn build` が通った台本で数えた（`n4-spike/build/<game>.rows.tsv` に 1 行ずつ）。

| | 血鱗 | 廃屋配信 |
|---|---|---|
| 演出コマンドの行（組み込みを除く） | 158 | 108 |
| 標準の命令で書ける | 125（N2 で既に 66・N4 で 50・N4b で 8・N4d で 1） | 63（N2 で 35・N4 で 28） |
| Yarn の `set` で書ける（HUD の変数） | — | 15 |
| 合わせた割合 | **79.1%**（入力の案内の 15 行を足すと 80.9%） | **72.2%**（C10 で標準にすれば 97.2%） |
| GameCommands に残る | 30（scene 10・wound 5・vial 5・stab 5・sink 3・roll 1・days 1） | 27（feed 26・blood 1） |
| N5 の preset に回す（それまで GameCommands） | 3（end） | 3（apparition 2・crash 1） |

- 書き換えの形（`build/` の台本から）:
  - 血鱗: `<<whale lying 0>>` → `<<show whale lying time=0>>`・`<<vision fish>>` → `<<show vision_fish at=still>>`・`<<shadow 2.4>>` → `<<move shadow from=left to=right time=2.4>>`・`<<puff>>` → `<<fx bubbles once=true on=girl.mouth>>`・`<<bg gem clear 1.8 pan>>` → `<<bg gem grade=clear time=1.8 transition=slide>>`。
  - 廃屋配信: `<<bg hall1 pan 0.8>>` → `<<bg hall1 transition=pan time=0.8>>`・`<<battery 31>>` → `<<set $battery to 31>>`・`<<comment ろん 不法侵入ｗｗ>>` → `<<feed "不法侵入ｗｗ" from=ろん>>`・`<<bgm bgm_suspense up>>` → `<<audio bgm bgm_suspense volume=raised>>`。
- **Doc に足す物（台本は替えない）**: 血鱗の `novel.backdrops.json` の photos に `lair`（`assets/lair/lair_still.jpg`・grade は clear）と `initial`（5.3）。`novel.backdrops3d.json` の paths に `lair.arrive` と `lair.dive`（2.8）。
- **台詞の行番号を変えない**: 血鱗の最初の `lights` が 2 行になる分、ファイルの頭の注釈を 1 行詰めた。台詞と選択肢の行（血鱗 72・廃屋配信 131）は 1 つも行番号が替わっていない（`convert_n4.py` が数えた）。行番号が替わったのは血鱗のコマンドとノードの頭の 7 行だけ。既読の鍵（台詞の行の場所）がそのまま使える（9.4）。

### 9.2 GameCommands / GameView に残る物

| 作品 | 残る物 | 今の在りか |
|---|---|---|
| 血鱗 | 深さの決まり（scene・sink・`Stage.pages`）・scene の命令の並び（`Commands.applyText`）・遺体の傷の線と血の粒（wound）・刺す（ナイフの振り・暗がり・血飛沫）・瓶（段ごとの血の高さのシェーダー・核の大写し）・日々の窓（昼夜と針）・光の点が跳ねて転がる（roll）・結末のカード（N5 まで）・ドットと水彩の絵の切り替え（Art の Style）・scene の頁の上限の検査（StageAudit の残り） | Stage・Whale・Vial・Sea・Ending・Lair・Art・ScenesDoc・StageAudit |
| 廃屋配信 | apparition・crash（N5 まで）・blood（画面の上から血が垂れる ShaderDoc）・カメラの質感（ずっと掛かる ShaderDoc）・状態バーと配信の表示（`GameView.hud`。変数を読む）・コメント欄（`feed`）・`Shots.extra()` の 3D の場面・E2e の問い・古いセーブを読まない知らせ | Stage・View・Shots・E2e・Saves |

### 9.3 残る Flix の行数の見込み【推】

| 作品 | 今 | 移した後 | 内訳の見込み |
|---|---|---|---|
| 血鱗 | 10,239（+ render 918） | **約 1,000〜1,400** | GameCommands 約 120（8 コマンド）・Whale の傷と刺すと転がる 約 250（449 行のうち姿の替えと口の泡は標準へ）・Sea 約 60（349 行のうち日々の窓だけ。回想のスチル・目・影・黒の幕・漂う粒・宝石のきらめきと当たりは show・move・overlay・fx・入力の案内へ）・Vial 約 180・Ending 約 136（N5 の後は約 30）・深さと scene 約 140・Art の絵の切り替え 約 100・GameRes と GameBoot 約 80・E2e の問い 約 40・StageAudit の残り 約 30。Lair3d・LairDoc・Gate・Hint・Stage の大半・View と Layout と Controls の差は消える |
| 廃屋配信 | 6,322 | **約 600〜900** | 状態バーと配信の表示 約 200・コメント欄 約 130・blood とカメラの質感の ShaderDoc 約 150・apparition と crash 約 80（N5 の後は 0）・3D の場面の描き出し 約 30・E2e の問い 約 40・縦の画面の端末の飾り（今の約 565 行のうち、テンプレートの縦の画面で書けない残り）約 0〜200。Walk・WalkDoc・Rooms は消える。C10 で filter と feed を標準にすれば約 300 減る |

テストも移る。血鱗 323 本（test 4,011 行）のうち、舞台のコマンドの読み方のテスト（TestStage・TestCast・TestSpeaker の一部）はテンプレートの TestCommands に任せ、ゲームの決まり（深さ・ゲートの道・瓶・結末）のテストは残す【推】。振り分けの手間は 11 章の見積もりに入れた。

### 9.4 古いセーブ（M8・C13）

- **血鱗**（公開済み）: 古いセーブは version 2 で、欄はテンプレートの v2 と同じ（bookmark・photo・grade・ambience・particles・mode・cast・seen）。血鱗だけの舞台（鯨・海・瓶・結末）はセーブに無く、ノードの頭の 4 文（scene・bg・ambience・lights）を当て直して作っている（StageAudit の決まり）。
  - 読み方: N3 の v2 の読み替えで読む。環境音の短い名前に `amb_` を付ける読み替えは N2 で済んでいる。v2 には Snapshot が無いので、ノードの頭から当て直して舞台を作る。**移行ではノードの頭の 4 文を消さない**（N3 の 4.3 の「機械で消す」を血鱗ではしない）。
  - ブックマーク: `{ node, storage, steps }`。steps は Advance・Choose の並びなので、ノードごとの「台詞・選択肢・`<<wait>>`」の並びが前と同じなら同じ所へ戻る。移行で待ちを足さない（`audio se wait=true` を使わない）。門で並びを比べる（10.2 の 1）。
  - 既読（`seen`）: 鍵は台詞の行の場所（`line#source`）。9.1 のとおり台詞の行番号を変えないので、そのまま使える。
  - 門: 移す前の版で、各ノードの 2 つ目の台詞でクイックセーブしたセーブのファイルを撮る（10.1）。新しい版で読み戻し、問いの値・tape.json の画面の物・world の層のコマが、移す前の版で読み戻した物と合うかを見る。
- **廃屋配信**: 古い Mark にゲームだけの欄（place・music・viewers・feed・signal・battery）がある。HUD の値が Yarn の変数へ移るので、読み替えには欄ごとに変数へ写すコードが要る。選択肢が無く 10 分ほどで読み終わる作品なので、**読まずに「版が違うのでセーブを読めない」と知らせる**（勧め）。門では、古いセーブを読んだ時にその知らせが出て、はじめから始まる事を見る。

## 10. 移行で前と同じ動きかを確かめる門

いまある物（数えた物）: 血鱗 reference の SHA 38 枚・e2e の flow 13 本・テスト 323 本。廃屋配信 reference の SHA 29 枚・e2e の flow 5 本・テスト 131 本。

### 10.1 移す前に古い版で基準を撮る

- 古い版のコミットを `git worktree` で別のフォルダに出し、そこで撮る（ゲームのリポジトリの本筋には書かない）。撮った物は `debug/migrate/baseline/` に置き、git には入れない。
- **flow ごとの記録（tape.json）**: テンプレートの FlowVideo は flow を流しながら `tape.json` を書く。中身は台詞ごとの時刻（`timeline`・`lines`）・鳴らした音の列（`sounds`: 時刻・種類・名前）・問いの値が替わった時刻の列（`probes`）・画面の物の矩形と出ていた区間（`objects`）・選択肢と選んだ物（`choices`）。血鱗は既にこれを書く（`debug/video/tape_gem/tape.json` を見た）。廃屋配信の写しは TapeOut を持たないので、worktree の中にだけテンプレートの `TapeOut` と FlowVideo の差を入れて撮る。
- 足す欄（C7）: 1 フレームごとのバスの音量（BGM のフェード・ダッキング）・台詞ごとの「その台詞を出し終えた時の問いの値の全部」・ノードごとの出来事の並び（台詞・選択肢・待ち）。問いの名前は移した後も同じ名前・同じ意味で出す（E2e のゲームの問いはゲームの持ち物。7.2）。
- **コマ（2 種類）**: (i) 全部の層のコマ（今と同じ）(ii) **world の層だけのコマ**（文字の枠・HUD・UI を描かない。FlowVideo に `FLOW_LAYERS=world` を足し、描く物を `ZBand` の world の範囲で絞る）。撮る時刻は、時間を取る命令の始まりから 0.25・0.5・0.75 の所と、台詞を出し終えた所（`lineDone`）。全コマから選び、時刻は tape.json の `timeline` と台本の秒から決める。
- **古いセーブ**: 血鱗はノードごとに 2 つ目の台詞でクイックセーブしたファイル（9.4）。廃屋配信は 1 つ。
- **mp4**: 各 flow（人が見る用。10.5）。
- 全部の flow を 1 回で流して上の全部を同時に書く（`make migrate-baseline`【推】）。

### 10.2 新しい版で同じ物を撮って突き合わせる門

- 新しい版で同じ flow を同じ手で流し、同じ物を `debug/migrate/new/` に書く。`bin/fge migrate diff baseline new` が flow ごと・台詞ごとに次を並べ、HTML の頁（左に前・右に後・下に差の色の図）にする。
  1. ノードごとの出来事の並び（台詞・選択肢・待ち）と、選んだ選択肢。違えば読み違いで、後ろの比べは意味が無いのでそこで止める（古いセーブのブックマークもこれで守る）
  2. 鳴らした音の列（名前と順番と時刻）
  3. 台詞を出し終えた時の問いの値
  4. 画面の物の矩形（`objects`）と、台詞の字（`lines`）
  5. コマの画素（10.3 の線引き）
  6. 古いセーブの読み戻し（9.4）
- 違いは全部どちらかに振り分ける:
  - **読み違い**（直す）: 一覧の行が消えるまで直してから先へ進む。
  - **わざと変えた物**（人が絵で見て承認）: `migrate-accept.json` に `{ flow, 画面の大きさ, ノードと台詞の番号か時刻の範囲, 何が, なぜ, 前後の絵のパス }` を書き、人が頁で前後の絵を見て「承認」を付ける。承認の無い違いが 1 つでも残れば門は落ちる。
- **抜け道を塞ぐ**（M11）:
  - (a) **カバー率**: どの flow も通らなかった台本のコマンドの行の一覧を出す（tape.json の `lines` に出た行と、台本の全部のコマンドの行の差）。0 にするか（flow を足す）、行ごとに承認させる。
  - (b) **承認の上限**: 1 件の時刻の範囲は 3 秒まで、1 本の flow で 20 件まで。同じ「なぜ」の物は頁で 1 つにまとめて出し、件数もまとめた数で数える（1 つの承認で同じ理由の物を全部通さない。まとめた中の絵を全部並べる）。
    - **全体に出る系統の違い**（ease の既定の差・粒の式の差など、多くの flow と時刻に同じ理由で出る物）は、別の種類 `systematic` として承認する。理由は 1 つ・当たった絵を全部並べる・件数の上限（20 件）は数えない。代わりに、当たった所ごとの差の大きさ（画素の差の平均が 6/255 以下）に上限を置き、超えた所は個別の件に戻す。この承認で通せるのは、名指しの命令が時間を取っている間（その命令の始まりから time の秒が終わるまで）のコマだけ。その外のコマに出た差は、同じ理由でも個別の件にする。系統の違いの承認には、理由を作った命令（例: `overlay` の ease の既定）を名指しで書く。
  - (c) **画面の大きさ 3 通り**: 2 本とも縦なので、design の 540×960・スマホの縦に長い画面（9:19.5）・短い画面（`short-*` の大きさ）の 3 通りで流す。廃屋配信の古い版が短い画面の形で撮れるかは【未確認】（`short-*` の場面はテンプレートの後の版の物）。撮れない大きさは基準なしで、新しい版の絵を人が頁で見る（承認の種類 `nobaseline`）。
- 古い版の台詞は「ノード + ノードの中の何番目の台詞 + 本文」で突き合わせる（本文は書き換えない）。
- **画面の物（`objects`）の id は前と同じ id を出す**。血鱗の tape.json 4 本に出た id は 23 種類（数えた）。移した後の出し手:

| id | 移した後に出す物 |
|---|---|
| `title_logo`・`title_menu`・`quick_menu`・`message` | テンプレート（今と同じ） |
| `girl`・`witch`・`whale`・`eye`・`bottle`・`knife`・`vision_fish`・`vision_drowned`・`vision_plant`・`vision_tea`・`vision_meal` | 標準の actor（id は actor の Doc の名前。人に見せる名前は Doc の `label`） |
| `lamp`・`rock` | Backdrop3d（id は glb の node の名前。`novel.backdrops3d.json` の `objects` に出す node と名前を書く） |
| `target_gem`・`target_bone` | 入力の案内（id は `target_` + `novel.prompts.json` の `targets` の鍵） |
| `vial`・`ending_label`・`end_gem`・`end_bone` | ゲームの `GameView.objects`（瓶と結末のカード。N5 の後は結末のカードと絵は標準の actor） |

  同じ id を出せない物は `migrate-accept.json` の `idMap`（前の id → 後の id）に書き、人が承認する。廃屋配信の id も同じ形で表にする（段 11 の頭で数える）。
- **コミットの分け方**（M12）: テンプレートを当て直すと Stage と Commands が替わり、古いコマンドの台本では組めない。そこで (1) テンプレートの当て直しと台本の書き換えと GameCommands・GameView への写しを 1 つのコミットにまとめ、ここで門を 1 回流す。(2) 古いコードの削除（使われなくなったゲームの .flix）。(2) は絵が変わらないはずなので、門をもう 1 回流して違いが 0 である事だけを見る。

### 10.2.1 当て直しで壊れる API（N4 の段 1〜4）

ゲームが前の写しのまま持っている .flix で、テンプレートを当て直すと型が合わなくなる物。移行の段で直す。

| 物 | 前 | 後 |
|---|---|---|
| `GameView.draw` の型 | `List[Render.PlacedItem]`（z は `View.zGameView()` から） | `List[(Int32, Render.PlacedItem)]`（層の数, 物）。物の中の z は 0..7 |
| `View.zGameView` | あった | 消した（層の数で並べる） |
| `Stage.shakeOffset` の引数 | `(now, seconds, px, stage)` | `(now, Stage.ShakeTarget, stage)`（長さと幅は鍵から） |
| `Stage.particleNames` | 決め打ちの名前 | 消した（`novel.effects.json` の particles） |
| `Cast.Layer` の形 | `{ cast, prop, leaving }` | `{ shown, leaving }`（Shown に `kind`） |
| `Cast.Mark` の形・セーブの JSON | `prop`（1 つか null） | `props`（列）。前の `"prop"` の枠も読む |
| `Cast.Cue` | `Show(Kind, Figure, Keep, 秒)`・`Hide(Kind, 名前, 秒)` | `Show(ShowCue)`・`Hide(HideCue)`（`exclusive`・`delay` を持つ） |
| `Cast.presenceOf` | `(now, layer)` | `(now, doc, layer)`（背景に付く絵を数えない） |
| `Cast.Env` | — | `props`・`photo`・`backdropShift` を足した |
| `Res` | — | `mixerExtras`・`soundSeconds`・`effects` を足した |
| `Stage.Mode` と `Stage#mode` | enum（Nvl・Adv） | 消した。`Stage#mode` はメッセージ枠の型の名前（文字）。出し方は `Stage.kindOf(theme, stage)`（`ThemeDoc.WindowKind`）・型は `Stage.windowOf` |
| `Page.lineOf` / `Page.show` / `Page.isFullFor` | `(name, line)` / `(Stage.Mode, …)` | `(name, quotes, line)` / `(ThemeDoc.WindowKind, …)` |
| `Stage.withParticles` | `(now, name, stage)` | `(now, name, at, stage)`（at = 出す点） |
| `World.emptyRead` | `()` | `(theme)`（空の舞台の型を windows の最初の NVL の型にする） |
| View の文字の層 | `View.textLayer`・`nvl`・`adv`・`portraitPage`・`keepLatest`・`Block` | `ViewText` へ移した |
| `CastDoc.Entry` / `CastDoc.Rec` | — | Entry に `markers`・`hideWindow`・`speakFx`、Rec に `highlight` を足した |
| `EffectsDoc.Look` | Fireflies・Snow（Eq・ToString） | `Puff(Puff)` を足した（Eq・ToString は外した） |
| e2e の問い `mode` | `Nvl`・`Adv` | 型の名前（作例は `nvl`・`bottom`） |
| `KindDoc.gestureLimits` / `Gesture.Limits` | `(kind)` / 4 つの欄 | `(kind, edge, width)` / `edge`・`width` を足した |
| `web.touchGestures` の縦の払い | `advance` のキー | `flickUp` / `flickDown` のキー（`novel.keys.json` に足した） |
| `Res` | — | `prompts`（`novel.prompts.json`）を足した |

### 10.3 一致を求める所と許容差を持つ所（M9）

SHA はコマ全体の値なので、層を分けて比べられない。当て直しで文字を描くコードも替わる。そこで **world の層だけのコマ（10.1 の (ii)）と、`objects` の矩形で切った所**で比べる。

| 物 | 求める物 | 理由 |
|---|---|---|
| 出来事の並び・選択肢・ノード・問いの値（文字と数）・音の名前と順番・台詞の字 | **完全に一致** | 物語の動きそのもの |
| セーブ → ロードの戻り（flow の bookmark・古いセーブ） | 完全に一致（問いの値と出来事の並び） | N3 の Snapshot の約束・公開済みのセーブ |
| world の層だけのコマ・演出の終わった後（`lineDone` で全部の tween が終わっている） | 画素の差が 2/255 以内の画素が 99.5% 以上（最大の差も記録） | 縁のなめらかさ・半画素のずれ。これを超えたら振り分ける |
| world の層だけのコマ・演出の途中 | 画素の差の平均が 3/255 以下。超えた物だけ振り分ける | ease の既定の差・1 フレームの量子化 |
| 文字の枠・UI（全部の層のコマを `objects` の矩形で切った所） | 画素は比べず、矩形（±2 px）と字（`lines`）だけ。見た目は頁で人が見る | テンプレートの当て直しで描くコードが替わる。字と置き場が合えば読み違いではない |
| 3D の背景の休みの位置 | world の層のコマで、画素の差が 3/255 以内の画素が 99% 以上 | 同じ glb と同じカメラなら同じ絵になるはず |
| 音の時刻 | ±1 フレーム（33 ms） | 命令の当たるフレームの差 |
| バスの音量（BGM のフェード） | 100 ms ごとの値で ±1 dB | フェードの ease の差 |
| 粒（fx）・揺れ | 画素は比べず、`objects` の数と区間だけ | 種と式が替わる。見た目は 10.5 で人が見る |
| 移した後の reference の SHA | 新しい版の SHA を新しい基準として書き直す | 移した後の退行の見張り（今までの使い方） |

- ease の差は先に潰す: 古いコードの曲線（血鱗の `Lair.easeOut` など）を移す時に、Doc の既定の ease を古い曲線と同じ名前にする（`Curve.Ease` に同じ物があれば）。同じ物が無い時だけ「わざと変えた物」にする。

**合格線の決め（人・2026-11-16）**: 台詞・選択肢・変数・音の順は完全一致。絵は数画素のずれまで許す。迷った差は移行を止めずに一覧へ溜め、最後に動画を並べて人にまとめて見せる（10.5）。上の表の許容差はこの線に合わせて決める。

### 10.4 古い版にだけ入れる差

- 廃屋配信の worktree に TapeOut を入れる。2 本の worktree に `FLOW_LAYERS=world` と足す欄の差を入れる。どれも撮るためだけの差で、ゲームのリポジトリにはコミットしない（worktree ごと捨てる）。

### 10.5 自動では見えない物は動画を並べて人が見る

- 手触り（払いの効き・タップの間）・テンポ（待ちの長さ・音の間）・音の混ざり具合は、機械の比べでは見えない。
- 書き出し: 前の版（worktree）と新しい版で同じ flow を `make flow-video NAME=<flow>` で撮り、ffmpeg の `hstack` で横に並べた mp4（`debug/migrate/<flow>.sbs.mp4`）にする。音は 2 本を混ぜず、**前の音を左・新しい音を右**のチャンネルに入れる（`amerge` + `pan`）。片耳ずつ聞けば、音の間と音量の差が分かる。上に台詞の行（ノード・番号）と時刻の字幕をベイクする（tape.json の `timeline` から）。`make migrate-video FLOW=<flow>` の 1 つの口にする【推】。
- 見る flow: 血鱗は route_gem・route_bone・route_leave・showcase・final_swipe（払い）、廃屋配信は full_story・walk_tour・showcase。人が見て気になった時刻を `migrate-accept.json` か読み違いの一覧に書く。
- 実機の手触り（スマホの払い）は動画では見えないので、移した後の Web 版をスマホで 1 回通して触る（血鱗のゲート 15 か所）。

### 10.6 門そのものを確かめる（M10・段 10 の完了条件）

1. **同じ版を 2 回流して差が 0**: 古い版を 2 回撮り、`migrate diff` の違いが 0 件になる。粒の種・`clock real:true` の時刻・`maxDeltaTime` を flow の中で固定する（今の FlowVideo が固定していない物があれば足す）。0 にならない欄が残れば、その欄は門に使わない。
2. **わざと入れた読み違いで落ちる**: 新しい版にわざと 4 つ入れる（`overlay` の秒を 1 つ替える・効果音を 1 つ消す・選択肢の後の `jump` を 1 つ替える・sink の GameCommands が `lair.dive` を当てないようにする）。それぞれ 10.2 の 5・2・1・5 で落ちる事を見る。最後の 1 つは、住処が見えている最初のノードの world の層のコマで落ちるはず（潜る動きが無い）。
3. **カバー率**: 2 本で、どの flow も通らない行の一覧が出る。その数を記録する。

### 10.7 門を作る手間【推】

| 物 | 実時間 |
|---|---|
| tape.json に足す欄（バスの音量・台詞ごとの問い・出来事の並び）と、world の層だけのコマと途中のコマの書き出し（テンプレートの FlowVideo） | 2〜3 時間 |
| 2 本の worktree に撮るための差を入れて撮る（流す時間を含む。血鱗 13 本・廃屋配信 5 本 × 画面の大きさ 3 通り） | 2〜3 時間 |
| `bin/fge migrate diff`（go: 突き合わせ・閾値・カバー率・承認の上限・HTML の頁・古いセーブの読み戻し） | 3〜4 時間 |
| 横並びの動画の書き出し（make の 1 つの口） | 0.5 時間 |
| 門そのものを確かめる（10.6） | 1 時間 |
| 合計 | **8.5〜11.5 時間** |

振り分け（読み違いを直す・人に見せる）は移行の見積もり（11 章）に入れた。

### 10.8 段 10 の go の道具の記録（2026-11-16）

`bin/fge migrate diff`・`bin/fge migrate video` を作った（`go/internal/migrate`）。記録の形・承認のファイル・線の既定の全文は [docs/migrate-diff.md](../docs/migrate-diff.md)。

- **合格線（10.3 の後の段落）に合わせた分け方**: 出来事の並び・問いの値・音の名前と順・撮れていない記録・通らない命令の行は門を止める（終わりの番号 1）。コマの画素・`objects` の矩形と区間・音の時刻・バスの音量は「迷った差」として一覧（頁と端末）に溜め、止めない。人が `migrate video` の横並びの動画と一緒に見て、残す物を `migrate-accept.json` で承認する。10.6 の 2（わざと入れた読み違いで落ちる）のうちコマで落ちる物は、`--strict` で流すか迷った差の一覧に出る事で確かめる。
- **tape.json に足す欄の名前と型**（テンプレートの FlowVideo / TapeOut が書く。無い記録は「比べていない」と出して落とさない。`bin/fge tape` は知っている欄として通す）:
  - `events: [{t, node, kind: line|choice|wait, seq, who?, text?, options?, picked?, seconds?, probes?}]` — 10.1 の「ノードごとの出来事の並び」と「台詞ごとの問いの値の全部」（line の `probes`）を 1 つにした。`seq` は line ならノードの中の台詞の番号（0 から）、choice と wait ならそれまでに出した台詞の数。
  - `buses: {バス: [[秒, dB|null]]}` — バスの音量の変わり目。null は無音。ミキサーの音量を World か Res から読めなければ欄ごと出さない【未確認: 読めるか】。
  - `frames: [{file, t, node, seq, kind: lineDone|mid, cmd?, step?, at?, layer: world|all, backdrop3d?}]` — 書き出したコマ（PNG・tape.json からの相対パス）。前と後は `layer|node@visit#seq|kind(|step@at)` の鍵で組にする（visit はノードの何回目の訪問かで、読む側が出来事の並びから数える）。
  - `ranLines: [行番号]` — 流れた台本の行（カバー率。無ければ `lines` の行を通ったと見る）。インタープリタが実行した文を全部その時に記録する（コマの台本の位置を写すと、同じフレームの `bg`・`set`・`jump` が抜けて偽の「通らない行」になる）。
  - `screen: {w, h}` — 矩形を px に直す画面の大きさ。
- **記録のフォルダ**: `debug/migrate/{baseline,new}/flows/<flow>/<大きさ>/tape.json`（大きさを分けなければ `flows/<flow>/tape.json`）と `saves/<名前>/restore.json`（`{save, refused, node, seq, probes, objects, frames, screen}`）。
- **線の既定**: 絵は 2 px のずれまで許す（相手の 2 px 以内でいちばん近い色との差・両向き）。lineDone は 2/255 以内が 99.5% 以上・backdrop3d は 3/255 以内が 99% 以上・mid は平均 3/255 以下・矩形 ±2 px・音の時刻と区間 ±1 フレーム・バス 0.1 秒ごとに ±1 dB（両方を -60 dB で下に止めてから差を取る）。mid のコマにはずれの探しをかけない（なめらかな背景で overlay の濃さの差が隠れる）。承認は 1 件 3 秒まで・1 本の flow で 20 件まで（同じ why は 1 件）・systematic は名指しの命令の mid のコマで平均 6/255 以下。
- **レビュー 1 回目（80 点）で足した物**: `migrate-accept.json` の `probeMap`（問いの値の言い方の読み替え。10.2.1 の e2e の問い `mode` の `Nvl`・`Adv` → `nvl`・`bottom`。読み替えは頁の承認済みの節に回数ごと出す）・systematic は flow を省ける（全部の flow に当て、頁で 1 つの理由にまとめる）・nobaseline の flow と大きさは新しい版のコマを頁に並べる・どの差にも当たらない承認を「使われていない承認」に出す・新しい版で撮っていないコマは撮れていない記録として止める（承認できない）・同じフレームの音の順は比べない。
- **頁の置き場**: 既定 `debug/migrate/report/`（`index.html`・`report.json`・`heat/*.png`）。承認は既定 `debug/migrate/migrate-accept.json`。どちらも new の記録のフォルダの隣。
- **横並びの動画**: `bin/fge migrate video --old <前.mp4> --new <後.mp4> --out debug/migrate/<flow>.sbs.mp4 --tape <new の tape.json>`。10.5 の `make migrate-video FLOW=` はゲームの Makefile の口なので、テンプレートの側で `make flow-video` の 2 回とこの 1 行をつなぐ（段 10 のテンプレートの担当）。
- 血鱗の今の tape.json 3 本（`debug/video/tape_*`）を前と後の両方に置いて流すと、止める違い 0・迷った差 0 で、通らない命令の行が 3 行（結末の 3 つのノードの「タイトルへ戻る」の選択肢の中の `<<stop>>`）出た。テープの flow はその選択肢を選ばず、`lines` にもその行が載らないため（260 行目で確かめた。328・355 行目は同じ形と見た【推】）。
- agents-pack の早見表と eval のお題には足さない。この道具はエンジンの作業場で 2 本の移行（段 11・12）にだけ使い、ゲームを作る人が普段使う口ではない。`make migrate-baseline` と `make migrate-video` をテンプレートの Makefile に足す段で、早見表に 1 行と eval のお題を 1 本足す（ゲームに配る口になるため）。

## 11. 小分けの順と見積もり

物差し:
- N1〜N3 の実績: N2 の段 5・6 は計画で 8〜9 時間と見たが、実際は約 2〜3 時間だった。レビューの直しは 1 回約 20 分。部品を作る段は、この比（計画の約 3 分の 1）で見積もった。
- **移行の物差しは、テンプレートの追随の実績**: 血鱗はテンプレートへの当て直しに約 5 時間かかった（親の計画 1 章）。移行はこれにゲームの部品の写しとテストの振り分けを足して見る。

全部【推】。レビューは 5 回（N4 の後・N4b〜N4c の後・N4d と口の後・門の道具の後・移行の後）。各段の後に `flix check` と波及したパッケージのテストだけ回す。

| # | 段 | 中身 | 実時間【推】 |
|---|---|---|---|
| 1 | N4 | `show`・`hide` を広げる（名前付きの絵を任意の数・`from`・`to`・slot の `exclusive`・`attach: bg`）・`move`・`actor.<名>.*` の鍵・`Out.Wait` | 2.5〜3.5 時間 |
| 2 | N4 | `overlay`・`camera`（2D）・`shake` の強さと `on=`・層の数で並べる View（C11） | 2〜3 時間 |
| 3 | N4 | `bg transition= pace=`（slide と pan を View へ）・`audio`（bgm・all・volume・fade・list・wait・音の Doc の lockSeconds）・`fx` と `novel.effects.json` | 2.5〜3.5 時間 |
| 4 | N4 | 新しい Doc と広げた Doc の schema と `editor.resources`（`novel.effects.json`・kind の `shakes`・mixer の `volumes` と `lockSeconds`（テンプレートの `assets/mixer.schema.json`）・cast の `layer` `attach`・backdrops の `defaultTransition`。theme の `windows` と cast の `markers` `hideWindow` は N4b の段 5 へ） | 1〜1.5 時間 |
| — | レビュー 1 | 指摘を全部出させ、まとめて直す | 0.5〜1 時間 |
| 5 | N4b | `cast.speaker`・`speak`・`marker` の型（C2・engine_world）・`hideWindow`・メッセージ枠の型と Mark v3 の mode の読み替え・`text` | 3〜4 時間 |
| 6 | N4c | 入力の案内をテンプレートへ（Gate・Hint・払いの判定・キーボードとマウス・オートとスキップ・flow の払い・E2e の問い）・`novel.prompts.json` と schema・go のタグの値の from（C3） | 3.5〜5 時間 |
| — | レビュー 2 | | 0.5 時間 |
| 7 | N4d | スパイク（5.2）。表を人に見せる | 2〜3 時間 |
| 8 | N4d | **5.0 で取りやめ・段 9 に合流**（汎用の口 3 つと initial・title・still の切り抜き）。元の中身: engine_world の `Backdrop3d`（C1）・テンプレートの bg と `camera path=` の配線・道筋の選び方と音（World の `Timeline`）・still の切り抜き（5.5）・`novel.backdrops3d.json` の schema | 5〜7 時間 |
| 9 | 口 | `GameRes`・`GameBoot`・`GameView.hud`・`GameView.objects`（C12）・`Commands.applyText`（C9）・`vocab.std.json`（C8） | 1.5〜2.5 時間 |
| — | レビュー 3 | | 0.5〜1 時間 |
| 10 | 門 | 10.7 の道具と 10.6 の確かめ・`make template-sync`（C5）と、その一覧を毎回見る手順（7.2） | 9.5〜13 時間 |
| — | レビュー 4 | 門の道具 | 0.5〜1 時間 |
| 11 | 移行 | 廃屋配信（先に。分岐が無く flow が短いので門の道具の確かめになる）: 基準を撮る・テンプレートの当て直し（追随の実績から 3〜4 時間）・Walk を `novel.backdrops3d.json` へ（1〜2 時間）・状態バーとコメント欄を `GameView.hud` と変数へ・HUD の変数の宣言（0.5 時間）・テスト 131 本の振り分け（1〜2 時間）・門の振り分け（1〜2 時間） | 8〜12 時間 |
| 12 | 移行 | 血鱗: 基準を撮る・テンプレートの当て直し（実績 約 5 時間 → 上書きの決まりで 3〜5 時間）・Whale・Sea・Vial・Ending を GameView の層の数と `src/game/` へ写す（4〜6 時間）・テスト 323 本の振り分け（2〜3 時間）・門の振り分けと古いセーブ（2〜3 時間） | 11〜17 時間 |
| — | レビュー 5 | 移行の後 | 1 時間 |
| 13 | — | agent-eval（新しい語彙のお題を 1 本）・早見表・`docs/modules` の行・`forbid.json` で古い名前（`<<char>>` など）を止める | 1〜2 時間 |

合計 **約 56〜82 時間**。

- 順番の理由: N4 → N4b は同じ Cast の層を触るので続ける。N4c は World と Controls を触るので N4b の後。N4d はスパイクの結果で形が変わりうるので、エンジンの部品を書く前に人の判断を挟む。口（段 9）は移行の前に要る。
- N5（preset）は範囲の外。2 本で preset に回る行は 6 行なので、移行の時点では GameCommands に置き（約 200 行【推】）、N5 で preset に移す。N5 を移行の前にやれば二度手間は消えるが、N5 の形（Doc の時刻表）を決める相談が先に要る。
- 並行: 段 5〜6（テンプレート）と段 8 の engine_world の部分は別のパッケージなので並べられる（同じパッケージを 2 人に触らせない）。段 10 の go の道具も段 1〜9 と並べられる。

### 11.1 段 1 の記録（2026-11-16）

触ったのはテンプレート（sound-novel-starter）だけ。engine_world・engine・render_gl は触っていない。

**決めた物**

- Cast の層を `{ shown: List[Shown], leaving }` の 1 列にした（Shown に `kind`）。人物と小物の決め打ち（1 位置に 1 人・小物は同時に 1 つ）をやめ、Doc の slot の `exclusive`（既定 true。段 2 の前に false から替えた）で「その位置に 1 つ」を決める。テンプレートと fixture の Doc は今の位置を全部 `exclusive: true` にしたので、作例の見た目は変わらない。
- Doc（`novel.cast.json`）に `slideDistance`（既定 1.0 = 画面の外まで）・slot の `exclusive`・項目の `layer`（既定 人物 500・小物 600・背景に付く絵 100）と `attach`（`{ "bg": { 写真の名前: 横のずれ } }`）を足し、schema にも足した（段 4 の schema の分を先にした）。
- `actor.<名>.x|y|scale|alpha|rotate` の鍵は `Stage.actorKey(名, Stage.ActorField)`。x・y は画面の幅・高さに対する割合、scale は足元を据えて掛ける、rotate は度（時計回り）。出ていない絵を出す時に `Stage.withActorReset` で既定へ戻す。
- `show` に `from=`・`x=`・`y=`・`scale=`・`alpha=`・`ease=`、`hide` に `to=`・`ease=`、`move` を新しく（`x|dx`・`y|dy`・`scale`・`alpha`・`rotate`・`from`・`to`・`time=0.5`・`ease=smoothstep`）。`move from=left to=right` は秒 0 で出し、端の外へ着いた時に消す（Cast の消えていく物に「始まる時刻」を足し、それまで濃さのまま描く）。
- `attach: bg` の絵は背景のすぐ上（今の z 3 の頭・蛍の下）に描き、今の写真のずれだけ横へずらす。ほかの絵は z 5 の中で Doc の `layer` の順に描く（同じ layer は消えていく物 → 出ている物、出した順）。particles と GameView を層の数で並べるのは段 2（C11）。
- `Out.Wait(秒)`: World の Read に `pause`（明ける時刻・待ちの後ろの出来事・戻れる所の元）を足した。コマンドが Wait を出すと、`absorbFrom` が残りの出来事を pause に預けて止まり、物語の時計で明けたら（スキップ中はすぐ）続きを反映する。待ちの間は送り・選択が効かず、セーブは `<<wait>>` の間と同じくバックログの頭の台詞の戻れる所。Silent では Commands.execute が落とす。

**比べた別案**

| 決めた所 | 取った案 | 比べた案と取らなかった理由 |
|---|---|---|
| from= / to= の滑り | actor.<名>.x / y の tween（PropertyTween） | 2.5 の「Shown に from・to を足す」案: View で滑りのずれと move のずれを 2 つ足し、Cast にも別の settle が要る。move の from / to はどのみち鍵で書くので、仕組みが 2 つになる |
| 待ち（Out.Wait） | テンプレートの World が残りの出来事を預かる（素材の待ち Hold と同じ形） | 実行器（engine_world の YarnRunner）に外から待ちを差し込む口を足す案: C の承認の外。実行器はコマンドを返した時にはもう次の台詞まで流し終えている |
| 傾き（rotate） | 面を外接する矩形にし、Param（turn_a〜turn_d）で読む座標を回し、絵の外を Step で透かす | `ShaderDoc.Field.Rotate`: 回す量が Const なので、傾きが動く間ずっと Spec が替わり実機がシェーダーを組み直す。`Render.turned` は Shader の面を傾けない。小さく描き出して確かめた（20 度・左へ 0.2。縁の切れ・はみ出しなし） |

**設計とのずれ**

- 2.5 の「Shown に from・to を足す」はしなかった（上の表）。
- 2.2 の `dx`・`dy` は offset 型（`40px`・`3.2%`）でなく数（画面に対する割合・x / y と同じ単位）。offset 型は engine_world の `YarnCommands.Param` に無く、足すのは C の承認の外。要るなら相談する。
- 2.2 の `audio se wait=true` は段 3 に残した（音の長さを Res に持たせる所が段 3 の audio の分と重なる）。そのため Out.Wait を出すコマンドはまだ無く、World の待ちのテストは pause を組んだ World で見た（Wait → pause を作る 1 行と、残りの出来事を預ける所は段 3 で `wait=true` と一緒にテストする）。
- 「Doc の既定に戻す」の既定は固定の値（ずれ 0・倍率 1・濃さ 1・傾き 0）。actor ごとの既定は Doc に無い。

**門の結果**

- テンプレート: `make check` OK・`make test` 319 緑（前は 294。TestActors 25 本を足した）・`make reference-check` 45 枚すべて一致（絵は変わっていない）・`bin/fge yarn check assets/talk` ok（9 ノード）。
- e2e の flow 6 本（bookmark・showcase・tape・tape_own_pace・tape_thanks・true_ending）すべて ok。
- `make lint`: lint-doc-refs は前からの 16 件のまま（増やしていない）。render-lint・lint-record-wrap・lint-forbid は OK。根の `make check-docs-sync` OK。

**持ち越し**

- 段 2: 粒（700）と GameView を同じ層の数で並べる View（C11）。今は背景に付く絵 = z 3・ほか = z 5 の中だけで layer の順。
- 段 3: `audio se wait=true`（Out.Wait を出す最初のコマンド）と、Res に音の長さ。`transition=slide` の間に背景に付く絵を背景と一緒に動かす → 段 3 で入れた（下）。
- 縦の頁の覆いを薄くする量（`Cast.presenceOf`）は背景に付く人物も数える → 段 2 で直した（数えない）。
- テンプレートの追随: `exclusive` の既定を true にしたので、前の Doc のままでも人物は重ならない（何人も立てたい位置にだけ `exclusive: false` を書く）。
- agent-eval のお題（show from= / move）は段 13。

**exclusive の既定（段 2 の前に直した）**: 設計書の 2.2 は「slot に `exclusive: true` を付ける」と書くだけで、書かない時の値を決めていない。既定 false のままだと、当て直していないゲームで人物が同じ位置に重なる。そこで既定を true（今の動きのまま）にし、何人でも立てる位置にだけ `exclusive: false` を書く形にした。fixture の `crowd` はそう書いた。

### 11.2 段 2 の記録（2026-11-16）

**決めた物**

- `overlay 濃さ [color=black|white|#rrggbb] [from=] [layer=stage|screen] [time=0] [ease=smoothstep]`。鍵は `overlay.alpha`（数）・`overlay.color`・`overlay.layer`（名前）。一度も書いていない間の濃さは `novel.kind.json` の `overlayStart`、stage の層の数は `overlayLayer`（既定 900）。同じ濃さへ動かす時（`from=` 無し）は何もしない。screen は hud の z 44（本文とボタンの上・素材待ちの黒の下）。
- `camera [zoom=] [x=] [y=] [time=0.5] [ease=smoothstep]`。鍵は `camera.zoom|x|y`（`Stage.CameraField`）。world の層だけに、画面の真ん中を軸に zoom 倍してずらす（`Render.scaledAllAround`・`movedAll`）。文字の枠と HUD には掛けない。
- `shake [強さ] [on=screen|window|絵の名前] [time=]`。強さは `novel.kind.json` の `shakes`（名前 → seconds・px）か px の数、省くと今の `shakeSeconds`・`shakePx`。鍵は `camera|window|actor.<名>` の `.shake`（一度だけ）と `.shakeAmp`（数）。`PropertyTween.triggerSpanAt`（始まってからの秒と長さ）を足して、だんだん収まる量を鍵から出す。絵の揺れは `Cast.Transform` の `jitter`（px）。
- **層の数で並べる View（C11）**: 新しい `ViewStage`（world の層）が、背景（0）・絵（Doc の layer）・粒・GameView・覆いを「まとまり」にし、層の数（同じ数なら 絵 → 粒 → GameView → 覆い）で並べてから、まとまりの順番 × `View.zWorldStride()`（8）+ まとまりの中の z を z にする。並んだ同じ層の数のまとまりは同じ z の幅を使う（今の「人物はみな z 5」と同じ絵になる）。`GameView.draw` は `List[(Int32, Render.PlacedItem)]` を返す。`zGameView` はやめた。サムネは z を 0..9 に詰める（字が z 10 から）。
- **View.flix を分けた**: world の層の描き方（背景・立ち絵と小物・粒・覆い・カメラ・揺れ・z の付け替え）を `ViewStage.flix` へ移し、View.flix は 1,277 → 1,130 行。
- `Cast.presenceOf` は背景に付く絵を数えない（Doc を受ける）。

**比べた別案**

| 決めた所 | 取った案 | 比べた案と取らなかった理由 |
|---|---|---|
| world の z の付け方 | まとまりごとに z の幅（8）を割り当てる | 層の数をそのまま z にする案: 層の数 0〜999 と、背景の中の z（0〜2）・粒の中の z（3・4）が混ざって前後が崩れる。`ZStack` の木にする案: 今の View は z の数で組んであり、段 2 で全部を木に替えると reference の絵を守れるか確かめる手間が大きい（ZStack へは z の数の表を 1 か所に集めた上で後から移せる） |
| camera の rotate | 入れない | 2.2 の表は `rotate=` を持つが、背景と立ち絵は Shader の面で、`Render.turned` も Shader を傾けない。2D で効かない引数を置くと書いても何も起きない。3D の道筋（N4d）で `camera.rotate` を足す |

**設計とのずれ**: camera の `rotate=` と `path=` は無い（`path=` は N4d）。

**門の結果**: `make check` OK・`make test` 335 緑・`make reference-check` 45 枚すべて一致（絵は変わっていない）・`bin/fge yarn check assets/talk` ok・e2e の flow 6 本すべて ok・`make lint` の lint-doc-refs は 15 件（前の 16 件から 1 件減った。ほかは OK）・根の `make check-docs-sync` OK。

### 11.3 段 3 の記録（2026-11-16）

**決めた物**

- `bg 写真 [transition=fade|black|wipe|slide|pan|cut] [pace=walk|run] [ease=linear]`。`Stage` に `switch`（transition・ease・pace）を足した。省いた transition は `novel.backdrops.json` の `defaultTransition`（既定 fade）。cut は秒 0。描き方は ViewStage: black = 前半は前の写真に暗い地を濃く、後半は今の写真から薄く／slide = 前の写真を左へ、今の写真を右から幅いっぱい送る／pan = 幅の 1/4 だけ寄せながら重ねる／wipe = 今の写真を左から `shaderFillMasked` で塗る。背景に付く絵は slide と pan の間、今の写真と同じだけ動く（`Cast.Env#backdropShift`）。pace は Stage に残すだけ（使うのは N4d）。
- `audio ambience 音[,音]|off [volume=] [fade=]`・`audio bgm 音|off [volume=] [fade=]`・`audio se 音 [wait=true]`・`audio all off [fade=]`。鍵は `audio.ambience`（, でつないだ名前）・`audio.ambienceVolume`・`audio.bgm`・`audio.bgmVolume`。`Controls.ambience` が環境音の列と音楽を鳴り続ける音にする（音量 = 鍵 × バス）。音楽は `bgm_` で始まる名前を新しい bgm のバスへ（`novel.mixer.json` に bus と route を足し、設定の環境音の音量を掛ける）。fade は鳴らす時は音量 0 から、止める時は音量 0 まで動かしてから名前を消す。
- volume の名前と効果音の後に送れない秒は `novel.mixer.json` の `volumes`・`lockSeconds`。テンプレートの `MixerDoc` が読む（バスの欄はエンジンの AudioMixerDoc が同じファイルから読む）。送れない秒は `text.lock`（一度だけ）に書き、押しても・オートでも送らない（スキップは止めない）。
- `audio se 音 wait=true` は `Out.Wait(音の長さ)` を出す。長さは `SoundLength` が project.json の鳴り続けない音の WAV の頭（fmt の byteRate と data の大きさ）から読み、`Res#soundSeconds` に置く。読めない音は 1 行言って待たない。
- `fx 名|off [once=true]`。名前は新しい Doc `novel.effects.json` の `particles`（名前 → `look`（fireflies・snow）・`layer`（既定 700）・`onceSeconds`）。once は `fx.once.<名>`（一度だけ）で、秒の間だけ薄くなりながら出す。作例は蛍と雪を layer 400（人物の奥）に置き、今の絵を変えない。`Stage.particleNames` の決め打ちはやめた。

**比べた別案**

| 決めた所 | 取った案 | 比べた案と取らなかった理由 |
|---|---|---|
| 音の長さ | 起動の時に WAV の頭から読む | 音の Doc に秒を書く案: ファイルから出せる値を手で写すので、音を差し替えると食い違う。全部の音を読む重さは、鳴り続ける音（大きいループ）を除けば小さい |
| volumes・lockSeconds の置き場 | `novel.mixer.json` にテンプレートの欄として足す | 新しい音の Doc を作る案: 設計書 11 章の段 4 が mixer の欄と決めている。エンジンの読み手は知らない欄を読まないので、同じファイルに置いても食い違わない |
| 粒の手触りの数 | `novel.kind.json` の fireflies・snow のまま | effects.json へ移す案: 数の Doc が 2 つに割れるだけで、段 3 で要るのは層の数と一度だけの秒だけ |

**設計とのずれ**

- `Out.StopSounds` は入れていない。一発の効果音を止める口がエンジン（App）に無く、足すのは承認の外。`audio all off` は環境音と音楽（鳴り続ける音）だけを止める。
- pan は「幅の 1/4 寄せながら重ねる」の 2D の形にした（2.3 の表の「カメラを横へ振ったように流れて替わる」の近似）。
- transition の切り替えの絵は reference の場面に無いので、目では確かめていない（テストで矩形と覆いの濃さを見た）。

**門の結果**: `make check` OK・`make test` 356 緑（TestAudio 21 本。うち Out.Wait を端から端まで見る 2 本は `test/fixtures/wait`）・`make reference-check` 45 枚すべて一致・`bin/fge yarn check assets/talk` ok・e2e の flow 6 本すべて ok・`make lint` の lint-doc-refs 15 件のまま・根の `make check-docs-sync` OK。

### 11.4 段 4 の記録（2026-11-16）

- 新しい Doc `novel.effects.json` の schema（`effects.schema.json`）と `editor.resources` の行は段 3 で入れた（コミット前の門が schema の無い Doc を止めるため）。
- `novel.backdrops.json` の `defaultTransition` を schema と Doc に足した。cast の `exclusive`（既定 true）・`layer`・`attach`・`slideDistance`（段 1）と kind の `shakes`・`overlayStart`・`overlayLayer`（段 2）の schema は各段で入れた。
- mixer の `volumes`・`lockSeconds`: 相談の答え（ノベル専用なのでテンプレートが自分の schema を持つ）で、`assets/mixer.schema.json`（エンジンの `docs/mixer.schema.json` の形に 2 つの欄を足した物）を作り、`editor.resources` の mixer をそこへ向けた（レビュー 1 の直し）。エンジンの schema は変えていない。Studio のフォームは Doc.elm が知らない鍵を検出しない作りで、schema に書いた欄は消えない見込み【未確認】（Studio で保存して確かめていない）。
- theme の `windows`・cast の `markers`・`hideWindow` は N4b の物なので段 5 で入れる。
- `agents-pack/AGENTS.core.md` の早見表に、画面の演出の行（bg の替え方・overlay・camera・shake・audio・fx）を 1 行足し、演出コマンドの行の GameView の層の数と `Out.Wait` を直した。agent-eval のお題は段 13。

**門の結果**: 段 3 と同じ（make check OK・make test 356 緑・reference-check 45 枚一致・yarn check ok・flow 6 本 ok・lint-doc-refs 15 件・check-docs-sync OK）。

**段 1〜4 の持ち越し**

- dx・dy の offset 型（px・%）は数のまま（engine_world の `YarnCommands.Param` に足すのは承認の外）。
- `Out.StopSounds`（一発の効果音を止める）はエンジンに口が要る。
- camera の rotate（2D）は Shader の面を傾ける口が要る。3D は N4d。
- mixer の schema の置き場の相談。
- transition の切り替えの途中の絵を見る場面が reference に無い（人が見る場面を足すかは段 13 か レビュー 1 で）。
- agent-eval のお題（段 13）。

### 11.5 レビュー 1（84 点）の直し（2026-11-16）

| # | 指摘 | 直した所 |
|---|---|---|
| 必須 1 | 開き直し（`WorldRead.reopenNode`）で待ち（pause）が残る | `pause = None` を足した。舞台は開き直しで当て直すので `Stage.settle` は要らない。テスト `testReopeningTheNodeDropsThePause` |
| 必須 2 | `se wait=true` と後ろの `<<wait>>` | engine_world は替えず「重なる（長い方だけ）」に決め、2.2 と Commands の頭（WhyNot）に書いた。テスト 2 本（3 秒でなく 2 秒で出る・1 秒では出ない。`test/fixtures/wait` の WaitLonger） |
| 必須 3 | 黙って捨てる引数 | 一発の音（`Out.Sound`）は名前しか運べないので、se の `volume=`・`fade=`、ambience / bgm の `wait=true`、all の `volume=`・`wait=` は Err（`Commands.misuseOf`）。テスト 2 本 |
| 必須 4 | exclusive の既定のテスト | `CastDoc.fromJson` に exclusive を書かない位置を渡し、2 人目で 1 人目が消えるテスト。テンプレートの novel.cast.json から明示の true を消した（既定が見本） |
| 必須 5 | 暗転は world 全体 | 暗転の黒を覆いと同じ層の数（overlayLayer）のグループに移した（人物・粒・GameView も暗くなる・文字の枠は暗くしない）。テスト 1 本と、描き出しで途中（進み 0.35・暗さ 0.7）の絵を 1 枚撮って目で見た（scratchpad の `blackout-mid.png`。背景と人物が同じく暗くなり、ADV の枠と字はそのまま） |
| 必須 6a | SoundLength | エンジンの長さの口は `GameEngine.Audio.audioSeconds`（App の `applyMixed` が `AudioMixer.step` に渡す・効果の中だけ）で、Res を作る時には読めない。WAV の頭を読む形のまま。ブラウザ版は `WebFs` の `readBytes` が埋め込みと起動前に取った素材の表から読むので、後回し（web.deferred）の音は起動の時に読めない【未確認】（実機で流していない）。読めない音は、シナリオが wait=true で鳴らす物だけを読み込みのたびに 1 回知らせる（`Controls.loadSoundSeconds`・`Commands.waitSoundsOf`）。シナリオの読み直しの行でも読み直す |
| 必須 6b | mixer の schema | テンプレートの `assets/mixer.schema.json` を作り（エンジンの形 + volumes・lockSeconds）、editor.resources を向けた（11.4） |
| 必須 7 | 設計書へ書き戻す | 2.2 の表（dx / dy は数・camera に rotate 無し・all off は鳴り続ける音だけ・se の音量はバス・wait の重なり）、2.3（pan は近似・black は world 全体）、2.5（`Out.StopSounds` を外して 8.3 の C14 へ・Shown に from / to を足さず actor の鍵の tween）、11 章の段 4 の行（windows・markers・hideWindow は N4b へ）、10.2.1 に当て直しで壊れる API の表 |
| 任意 8 | サムネの z の詰め方 | 10 段を超える時は奥の段から重ねて詰め、手前（覆い・小物・人物）の前後を崩さない |
| 任意 9 | z の付け直し | docs/z-bands.md の決まりから外れる理由を ViewStage に WhyNot で書いた。GameView の z を丸める時の warnOnce は入れていない（純粋な描き物の中で毎コマ知らせることになり、1 回だけにする口が Log に無い） |
| 任意 10 | 出ている絵への `move from=` | Err。テスト 1 本 |
| 任意 11 | 同じ bgm への fade | 鳴らし直さず今の音量から動かす。テスト 1 本 |
| 任意 12 | shakes の既定・上限 | 名前付きの揺れの書かない欄は同じ Doc の shakeSeconds・shakePx から。強さの数の上限を schema と同じ 80 に |
| 任意 13 | 重複 | `PropertyTween.triggerAt` を `triggerSpanAt` から出す。テストの `near` を TestKit へ |
| 任意 14 | 名前 | `Res#sounds` → `mixerExtras`・`withEffect` → `applyEffect`・`colorOfName` → `Stage.overlayColorOf` |
| 任意 15 | 言葉 | 「まとまり」→ グループ・「塊」→ チャンク。How のコメント 3 か所（move の entryCue・WorldRead の 2 か所）を消すか doc コメントへ |
| 任意 16 | テスト | and でつないだアサートを分けた・粒（既定 700）が人物より手前のテスト・`Controls.ambience` の音量と mixerOf の bgm バスのテスト |
| 任意 17 | Doc の書き損じ・▼ | `novel.effects.json` の粒 1 つの書き損じは、その 1 つだけ既定（雪・700）にして知らせる（テストは書いていない: 知らせる 1 行が stderr に出るとテストが落ちる）。待ちの間は送りの印（▼）を出さない |

**門の結果**: `make check` OK・`make test` 368 緑・`make reference-check` 45 枚すべて一致（絵は変わっていない）・`bin/fge yarn check assets/talk` ok・e2e の flow 6 本すべて ok・render-lint・lint-record-wrap・lint-forbid OK・lint-doc-refs 15 件（増えていない）・根の `make check-docs-sync` OK。

### 11.6 段 5 の記録（2026-11-16）

触ったのはテンプレート（sound-novel-starter）・engine_world（`YarnCommands`・`YarnCommands.Param`。C2）・go（`go/internal/yarn`。C2 の検査）。engine・render_gl は触っていない。

**決めた物**

- 引数の型（C2・engine_world）: `Param.marker(name, refs)`（`名.点` を (名前, 点) で読む）・`Param.text(name)`（空でない字・`"…"`）・`Param.scopedBy(other, h)`（build が ref を「同じ行の other の値 + . + この値」で照らす）。vocab.json の `type: marker`・`type: text`・`scope`。go の from の `keys`・`path` に `*` の段（object の値を全部たどり、たどった鍵を名前の頭に付ける）。受ける行と断る行の見本 `go/internal/yarn/testdata/command-args.json` に足した（go と Flix が同じ見本を読む）。
- `show` の表情を `scopedBy("name")` と `cast.*.faces[]`・`props.*.faces[]` で照らす（2.7 の「名前ごとの集まり」）。`fx on=` は `cast.*.markers`・`props.*.markers` の鍵で照らす。わざと入れた誤り（表情・点・型・字の大きさ・話し手の 5 つ）は 5 件とも `bin/fge yarn check` で落ちた。
- メッセージ枠の型: `novel.theme.json` の `windows`（作例は `nvl` と `bottom`。今の見た目のまま）。`Stage#mode` は型の名前で、空の舞台と Mark v3 の古い値 `Nvl`・`Adv` は「その出し方の最初の型（鍵の順）」と読み（`ThemeDoc.windowOf`）、`World.emptyRead`・`WorldRead.restore`・ノードに着いた時の舞台で本当の型の名前に直す（`Stage.withModeResolved`）。書くのはいつも型の名前。ADV の center は `Layout.advPanelAt`、outline は字の周り 8 方向に影を置き、地と縁を敷かない。
- `<<window off|on time=>>`: `window.hidden` を tween し、View が文字の層を途中の濃さで描く（`Stage.windowAlphaAt`）。
- `<<text>>`: `at` は NVL の頁の中の行の塊の置き場（頁の下は上の余白と同じだけ画面の下から上）・`size` は `novel.kind.json` の `textSizes` の倍率（NVL の頁の行の数え方 `WorldRead.fitsNvl` も同じ倍率で数える）・`align=center` は 1 行に収まる行だけ真ん中へ・`speed` は文字送りの速さの倍率・`lock` は押しても送らない秒。
- `cast.speaker` と話し手を明るく: `WorldRead.showLine` が台詞ごとに書く（`Stage.withSpeaker`。同じ話し手は書き直さない）。立ち絵の面に Param `lit` を足して明るさを掛ける（Spec を替えずに毎コマ変えられる。1.0 なら絵は変わらない）。
- `hideWindow`: 出ている物に `hideWindow` の絵があれば、文字の枠と字だけを描かない（選択肢とボタンは描く。消えていく途中の物は数えない）。
- 粒の点: `novel.effects.json` に `look: puff`（count・rise・spread・size・life）を足し、点（`Cast.markerPointOf`。出ている絵の矩形の中の markers の割合の所）から立ちのぼらせる。作例に `breath`、toma に `markers.mouth` と `speakFx: breath` を足した（台本は使っていないので絵は変わらない）。
- View.flix の文字の層（NVL・ADV・縦の頁・1 行の置き方・送りの印）を `ViewText.flix` へ分けた（View.flix は 1,130 → 約 980 行）。

**比べた別案**

| 決めた所 | 取った案 | 比べた案と取らなかった理由 |
|---|---|---|
| 話し手の替わり目のつなぎ | `cast.speaker` の 1 つ前の値を `PropertyTween.namePreviousAt` で読む（表は今の値と 1 つ前の値を持っている） | 人物ごとの数の鍵 `actor.<名>.dim` を World が台詞ごとに tween する案: 台詞のたびに出ている人物の数だけ鍵を書き、Snapshot も太る。名前 1 つの鍵（設計書 3 章）のままで済む |
| 明るさの掛け方 | 立ち絵の面の Param `lit` | 色の倍率の Const に掛ける案: 替わり目の間ずっと Spec が替わり、実機がシェーダーを組み直す |
| 表情の照らし | `scope`（同じ行の別の引数の値を頭に付けて照らす）と `*` | 表情だけの専用の型を足す案: 小物の絵・背景の写真の時間帯など、名前ごとの集まりは他にも出る。汎用の 2 つで書ける |
| `*` の後の欄が どの項目にも無い時 | `*` より前の段に届いていれば「空の集まり」と読み、検査は飛ばさない | 今の「名前を 1 つも拾わない時は検査を飛ばす」のまま: 作例のように markers をまだ誰も書いていない Doc で、`on=` が何でも build を通り、実行時に Err になる |
| Nvl・Adv の型の名前を止める所 | `ThemeDoc` の読み手が落として知らせる・テスト | schema で止める（設計書 3 章）: Studio の sections 方言に catalog の鍵を縛る欄が無い |

**設計とのずれ**

- 3 章の「縁取り」は `frame`（panel / outline）の 1 欄にした（地を敷くか、字を縁取るか）。`showName` は横の NVL の頁では効かない（頁に名前の置き場が無い。schema の文に書いた）。
- 3 章の「Doc の型の名前に Nvl・Adv を使わない決まりを schema で止める」は、読み手とテストで止める（上の表）。
- 3 章の `speak` の粒は Doc に名前が無かったので、項目の `speakFx` を足した。点から出す粒（`on=`）は `look: puff` だけにし、蛍と雪（画面に広げる粒）に書くと Err。
- 2.2 の `window` に `on` と、off・on の `time=` を入れた。
- `text` の `at` は NVL の頁だけ（ADV の枠の置き場は型の `place`）。`align=center` は 1 行に収まる行だけ（描く RichText に揃えの口が無い）。
- e2e の問い `mode` の値が型の名前になった（flow の `mode=Nvl` → `nvl`・`mode=Adv` → `bottom`）。

**門の結果**

- テンプレート: `make check` OK・`make test` 401 緑（前は 368。TestSpeaker 33 本・TestCommands の見本に text・speak）・`make reference-check` 45 枚すべて一致（途中で縦の画面の 4 枚が変わったのは nvl の型の showName を false にしていたためで、true に直して一致）・`bin/fge yarn check assets/talk` ok（9 ノード）・わざと入れた誤り 5 件は 5 件とも落ちた。
- e2e の flow 6 本すべて ok。
- `make lint`: lint-doc-refs 15 件のまま・lint-record-wrap・lint-forbid・lint-cast OK。根の `make check-docs-sync` OK。
- engine_world: `make sync-layers` の後 .layers/engine_world で flix test 1506 緑。go: `go test ./internal/yarn/` ok・`go vet` 指摘なし。rpg-starter・tidepool-starter の `make reference-check` 一致。

**持ち越し**

- 新しい見た目（ADV の center・outline・話し手を暗くする・puff の粒）を写す場面が reference に無い。目では確かめていない（テストで矩形と明るさの値を見た）。
- 話し手の id と cast の鍵をそろえる決まりは Doc の note にだけ書いた（食い違いを見るテストは無い）。
- `text.at` の center・bottom で頁の下に入り切らない時の扱い（今は上から積むのと同じ所まで上げる）。

### 11.7 段 6 の記録（2026-11-16）

触ったのはテンプレート（sound-novel-starter）と go（`go/internal/yarn`。C3）。engine_world・engine・render_gl は触っていない。

**決めた物**

- `Gate`（血鱗の Gate を写した。`#act:` の読み・選び方・`actText`）と、vocab.json の tags（`Gate.tagsJson`: act は決まった一覧・at と icon は `novel.prompts.json` の `targets`・`icons` の鍵・mute は値を取らない）。`Talk.vocabJson` が書く。
- `WorldRead.gateOf`・`gateHere`・`passGate`: 出ている選択肢の全部に `#act` があるか、今の台詞を送ると選択肢だけが出る時（viaLine）にゲート。素材を待つ間とコマンドが出した待ち（pause）の間は無い。`advance` はゲートの頁では字を出し切るだけ。選ぶ物が 1 つのゲートはバックログに選んだ行を残さない。オートとスキップはゲートで手動に戻る。
- 入力（`Controls`）: 離した払い・タップ（`Gesture`）と、払いのキー（↑↓←→ / WASD・`flickUp`・`flickDown`）と決定（tap の選択肢が 1 つの時）。ゲートはキーの列（戻る・ログ…）より先に見る（ブラウザ版の横の払いは、離したフレームで swipeLeft のキー = 戻るも出すため）。ゲートの間は選択肢のボタンの入力を受けない。tap の当たりは描く所と同じ `ViewStage.targetRectOf`（`Hint.targetRect`）。
- ブラウザ版の縦の払いは `web.touchGestures` の `swipeUp` / `swipeDown` を新しいキー `flickUp` / `flickDown`（`novel.keys.json`・既定 Numpad8 / Numpad2）へ替えた。ゲートの外では今までどおり 1 行送る。
- `Gesture.Limits` に `edge`（`novel.prompts.json`）と画面の幅を足し、端の帯から始めた払いはドラッグにする（血鱗と同じ）。
- `Hint`（血鱗の Hint を写した）: 矢印の色・速さ・高さ、#icon の色と絵、輪は Doc から。字の地と字の色は `novel.theme.json` の panel と ink。縦の画面では右の列の左までに収める。View は選択肢のボタンと送りの印をゲートの間は出さず、縦の頁はゲートの間は選択肢の分を縮めない。
- e2e の問い `gate`（選べる操作を `|` でつなぐ）。drive の reader はゲートで押さない（flow が役のキーで選ぶ）。
- go（C3）: vocab.json の tags の値に `{"from": [...]}` を書けるようにした（`Vocab.TagsFrom`）。from のタグは値が要り、Doc に無い値は近い名前の案つきで止める。Doc を読めない時はそのタグの値を照らさず 1 行知らせる。
- 新しい Doc の schema（`assets/prompts.schema.json`）と `editor.resources` の行（prompts）を足した。

**比べた別案**

| 決めた所 | 取った案 | 比べた案と取らなかった理由 |
|---|---|---|
| flow の払い | 役のキー（`tap left` など）を正にする | flow の語彙に `swipe 向き` を足す案: engine_world の `Flow` を替える（C の承認の外）。キーの道は Controls の同じ `gateInputOf` を通るので、払いの判定（Gesture）はテストで別に見る |
| ブラウザ版の縦の払い | 新しいキー `flickUp` / `flickDown`（血鱗と同じ） | `advance` のキーのまま、ゲートでは前のフレームのホイールの向きで上下を決める案: ホイールの刻みは動かしている間に出し、最初の向きと逆を捨てるので、向きを読み違える |
| ゲートとキーの列の順 | ゲートを先に見る | 血鱗の順（キーの列の後）: テンプレートは swipeLeft を戻るに割り当てているので、左へ払うゲートで 1 行戻る（テスト `testMouseSwipeLeftPicksAndDoesNotRollBack`） |
| 当たる物の載る先 | `photo` か `actor` の 2 つ | 血鱗の「写真か鯨の姿」: 姿はゲームの物なので、名前付きの絵（actor）に一般化した |
| 案内の絵の貼り方 | 正方形の Shader の面（2 つの画素の間をなめらかにつなぐ） | `Render.sprite`: 絵の画素の大きさが Doc に無く、正方形へ収める倍率が決められない |

**設計とのずれ**

- 4 章の `arrow` の「矢印の絵」は持たない（矢印は線で描き、色・速さ・高さだけを Doc に出した）。高さ `y` は 4 章に無かった欄。
- `edge` の帯はゲートの外の払い（ドラッグになる）にも効く（血鱗と同じ）。
- ブラウザ版の `touchGestures` の縦の払いの割り当てを替えた（上の表）。
- テンプレートの物語（yukidoke.yarn）にはゲートを入れていない。e2e の flow はゲートを通らず、ゲートは test/fixtures/gate の台本で見る。
- 段 5 の続き: 縁取りの型（outline）で ADV の枠の名前にも縁取りを付けた（描き出しで見て、明るい写真の上で名前が読めなかった）。

**門の結果**

- テンプレート: `make check` OK・`make test` 427 緑（前は 401。TestGate 25 本・TestGesture に端の帯 1 本）・`make reference-check` 45 枚すべて一致・`bin/fge yarn check assets/talk` ok（9 ノード）・わざと入れた誤り（`#at:` の Doc に無い値・`#act:upp`・`#icon:` の Doc に無い値）は 3 件とも落ちた。
- e2e の flow 6 本すべて ok。
- 目で見た物（scratchpad の写し・reference は変えていない）: 選択肢の頁のゲート（左の払いと #icon の色の下の払い。`gate-hint.png`）・縁取りで真ん中に置いた ADV の枠（`adv-outline-center.png`）。
- go: `go test ./...` ok（tags の from のテスト 5 本）・`go vet` 指摘なし。
- `make lint`: lint-doc-refs 15 件のまま・ほか OK。根の `make check-docs-sync` OK。

**持ち越し**

- 当たる物の輪・#icon の絵・縦の画面のゲートは描き出しで見ていない（テストで矩形と入力を見た）。
- 血鱗のゲートの案内の高さは鯨の上の空きで決めていた（ゲームの絵の位置）。テンプレートは Doc の固定の高さ `arrow.y` だけ。移行で要るならゲームの口を相談する。
- テンプレートの物語にゲートの見本が無い（agent-eval のお題と一緒に段 13 で足すか決める）。

### 11.8 レビュー 2（85 点）の直し（2026-11-16）

| # | 指摘 | 直した所 |
|---|---|---|
| 必須 1 | hideWindow の小物が NVL と縦の画面で消える | `ViewStage.propsOnPage`（頁に幕があり hideWindow の絵が出ていない）で、小物を頁に描くかを決める（`isPropOnPage`・サムネも）。テスト `testHideWindowPropIsDrawnInTheWorldLayerOnTheNvlPage`。縦の画面と NVL の描き出しで目で見た（scratchpad の `vis/hide-portrait.png`・`vis/hide-nvl.png`。小物が world の層に出て、本文と枠は消え、選択肢は出る） |
| 必須 2 | Mark v3 の Nvl / Adv の読み替え先が鍵の字の順 | `novel.theme.json` の `legacyModes` と schema・note。3 章に書き戻した |
| 必須 3 | 本物のセーブで確かめる | version 3 のセーブの JSON の `"mode": "Adv"` を `Saves.fromJson` から `WorldRead.restore` まで通すテスト（期待値は legacyModes の Adv） |
| 必須 4 | C2 の承認の表から出ている | 8.3 に「C2 の広げ（scope・`*`）」の行（人の承認待ち） |
| 任意 5 | gateOf が実行器を何度も進める | 出来事を反映した時に 1 回求めて Read の `gate` に持たせる（`WorldRead.withGate`）。`gateOf` は待ちを見て `gate` を返すだけ |
| 任意 6 | 端の帯から始めた払いがゲートで戻る | ゲートの間は、動いた押しと同じフレームの戻るのキーを受けない（`Controls.isMoved`）。テスト 1 本 |
| 任意 7 | `window off time=` の後に頁の小物が消えてから戻る | 頁の小物に文字の枠の薄さを掛けない（`View.pageProps` を薄くする列の外へ） |
| 任意 8 | 選べる物が 0 のゲートで詰む | `Gate.ofOptions` は選べる物が 0 なら None。テスト 1 本 |
| 任意 9 | ADV の間の `text at=` | Err。3 章に 1 行。テスト 1 本 |
| 任意 10 | Hint の数の直書き | `novel.prompts.json` の `margin`・`captionSize`（schema も） |
| 任意 11 | 書き方 | `Param.scopedBy` の WhyNot を `//` の行に。「行の塊」→ ブロック |
| 任意 12 | テスト | ゲートでセーブして戻すと同じゲート（台詞の頁・選択肢の頁の 2 本）・go で作例の toma.mouth が on= の照らしに拾われる |
| 持ち越し | 描き出しで見ていない見た目 | 話し手を暗くする・puff の粒（`vis/speaker-dim-puff.png`）・当たる物の輪と #icon の色（`vis/gate-ring.png`）・縦の画面のゲート（`vis/gate-portrait.png`）を描き出して見た。見て直した物: 輪の横の字がほかの選択肢の矢印に重なる（空きを矢印までにした）・縦の画面で輪の上の字が画面の端で切れる（地を内へ寄せた）・作例の toma の口の点の高さ（0.17 → 0.24） |

- 残り: 縦の画面では背景を画面より横に広く敷くので、写真に対する割合で書いた当たる物は横の画面より大きく、端にかかることがある（Doc の値の決め方。描き出しで見た）。

### 11.9 レビュー 2 の 2 回目（92 点）の任意の直し（2026-11-16）

| # | 直した所 |
|---|---|
| B1 | `ThemeDoc` の読み込みで legacyModes の欠け・行き先が windows に無い・出し方が違うを 1 行ずつ知らせる。新しいゲームの最初の型を `ThemeDoc.startWindowName` にし（`Stage.emptyFor`）、nvl の型が無い Doc でも windows にある型で始まる。3 章・schema・note を合わせた。テスト 4 本 |
| B2 | ゲートを求めるのは出来事ごとでなく、`absorbFrom` の終わりと待ちで止まる所（`pauseOrGo`）の 1 回 |
| B3 | `reopenNode` でも `gate = None` を並べる |
| B4 | 端の帯は横の払いだけに効かせる（`Gesture.isEdgeSideSwipe`）。OS の戻る操作は横だけで、ブラウザ版の縦の払い（flickUp / flickDown のキー）は帯を見ずに届くので、縦はデスクトップでもブラウザ版でも帯の内から選べる形にそろえた。テスト 1 本 |
| B5 | 11.8 の残りを 14 章へ移した |
| 絵 | 作例の toma の口の点を x 0.58・y 0.225 に直し、粒が口から立ちのぼるのを描き出しで見た（scratchpad の `vis/speaker-dim-puff-2.png`・`vis/puff-zoom.png`） |

## 12. 試した事（スパイク）

| 試した事 | 置き場 | 結果 |
|---|---|---|
| 2 本の台本を N4 の語彙で書き直し、下書きの vocab で build に通した | `n4-spike/convert_n4.py`・`gen_vocab.py`・`build/` | 2 本とも通った。割合は 9.1。台詞の行番号は 1 つも替わっていない |
| わざと 4 つ誤りを入れて build に通した | `n4-spike/build/neg/` | 4 件とも落ちた（範囲・名前・音・タグの値） |
| kankan を同じ表で build に通した | `n4-spike/kankan_build.py` | 通った（378 行が全部標準。se の送れない秒は音ごとに 1 つの値で、音の Doc に移せた） |
| 覆いと寄り: 専用のコマンドと汎用の `tween` を同じ 75 行で | `n4-spike/alt.py` | 汎用は 1.43 倍の字で、値の範囲が鍵ごとに違うので引数の表 1 つで検査できない → 専用 |
| HUD: コマンドと Yarn の変数を同じ 15 行で | `n4-spike/alt.py` | 変数は 1.41 倍の字。セーブ・分岐・テープの表がただで付く → 変数 |
| 3D の背景を動画にした時の大きさ | `n4-spike/walk_*.mp4` | 5.1 の表 |
| 前の回: 4 本の 924 行を語彙 19 で書き直した | `vocab-spike/` | 書けなかった行 0（親の計画 3.17） |

- 姿の替え（`swap` を `show` に入れる）は字数が同じ（6 行で 158 字）だったが、これは決めた理由にしていない。理由は名前が 1 つ減る事と、Ren'Py の形にそろう事。
- 試していない事: 名前の表を渡さない時に AI が新しい語彙で書く誤り方（親の計画 3.18 の注意のまま）・`<video>` を texture に写す Web の口【未確認】・lightmap 版の住処の見た目（段 7 のスパイク）・izakaya の build。

## 13. 名前を決めた物

| 物 | 決めた名前 | 比べた呼び方 |
|---|---|---|
| 背景の切り替えの種類の引数 | `transition=` | Ren'Py の `with`（Yarn の key=value の鍵としては読みにくい）・Naninovel の `transition:`・Tyrano の `method=`・第 1 版の `via=` |
| 3D の道筋の歩き方 | `pace=walk\|run` | 廃屋配信の Mood（creep・chase。Doc の揺れの名前に残す） |
| 名前付きの絵 1 つ（鍵の頭） | `actor`（`actor.<名>.x`） | Naninovel の actor（人物・背景・枠をまとめて呼ぶ）・Ren'Py の displayable・Tyrano の chara・第 1 版の figure |
| 絵の中の点 | `markers`（引数の型 `marker`） | Godot の Marker2D・Unreal の socket・Unity の anchor・血鱗の今の marks |
| 払い・タップで選ぶ選択肢の案内 | 入力の案内（input prompt）・Doc `novel.prompts.json` | QTE（時間の制限がある物）・第 1 版の gate |
| 粒と画面の質感の Doc | `novel.effects.json`（`particles` と、後で標準にする時の `filters` を 1 つの Doc の 2 つの欄に） | 別々の Doc 2 つ（`/doc-design` の「Doc を増やしすぎない」。どちらも名前 → 素材のファイルの短い表なので 1 つで足りる） |

## 14. 持ち越しと未確認

- 【未確認】廃屋配信の「縦の UI と入力」（約 565 行）のうち、今のテンプレートの縦の画面（PortraitDoc・Layout）で書ける量。廃屋配信の写しはテンプレートが縦の画面を持つ前の物なので、当て直してから数える。9.3 の幅はここが大きい。
- 【未確認】血鱗の縦の Layout と Controls の違いのうち、払い以外の物の行き先（7.2）。
- 【未確認】血鱗の Art のドットと水彩の切り替え（Style）を Cast の Doc の「絵の組」（`variants`）で書けるか。書ければ約 100 行が消える。
- 【未確認】`audio.ambience` を `,` でつないだ 1 つの名前で持つ形と、AudioMixer の sustained の渡し方が合うか。
- 【未確認】今の 2 本の 3D の背景が、縦に長い画面でどう合わせているか（5.5）。
- 【未確認】廃屋配信が公開済みか（C13 の勧めは公開済みでも同じ）。
- 廃屋配信の「カメラの質感」（約 200 行）を ShaderDoc で書けるか。粒状のノイズ・周辺の暗さ・色のずれは `Field.Hash1`・`RadialAspect`・`Tex` の `Shift` で書ける見込み【推】。
- go の `parse.go` の `"…"` は N2 で入れた。`feed` の本文に `>>` を含めない決まりは今のまま。
- 【未確認】ブラウザ版で後回し（`web.deferred`）にした効果音は、起動の時に長さが読めず、`audio se … wait=true` が待たない見込み（読めない音は読み込みのたびに 1 回知らせる）。直すなら、音が届いた時に長さを読む。
- 【未確認】Studio のミキサーのフォームで保存した時に、テンプレートの `assets/mixer.schema.json` に書いた `volumes` と `lockSeconds` が残るか。
- 縦の画面では背景を画面より横に広く敷くので、`novel.prompts.json` の写真に対する割合で書いた当たる物は横の画面より大きく、画面の端にかかることがある（Doc の値の決め方。レビュー 2 で描き出して見た）。
- 相談中: C14（一発の効果音を止める口・8.3）。決まるまで `audio all off` は鳴り続ける音だけを止める。
- GameView の物の中の z を 0〜7 へ丸める時に知らせが無い。描き物は純粋で、Log に「1 回だけ知らせる」口が無いため。
- `templates/sound-novel-starter/assets/mixer.schema.json` はエンジンの `docs/mixer.schema.json` の写しに `volumes`・`lockSeconds` を足した物。エンジンの schema に欄が増えたら、ここへも写す。
