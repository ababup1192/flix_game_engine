# ノベルの「命令に隠れた決まり」を Doc の欄へ出す

状態: **段階 1a と段階 3 を入れた**（枝 `novel-doc-rules`・main の 05926221 から）。段階 1b と段階 2 は保留。
設計スパイク（案の比べ・他のエンジンの調べ・AI での試し・レビュー 2 回）は枝 `worktree-agent-a71631ac48886a454` の
コミット ea2fb21b の同じファイルにある。ここは決まった事と入れた物だけを書く。

## 0. 何が困っていたか

古いゲーム（血鱗）を新しいテンプレートへ移したら、yarn を読んでも分からない決まりで見た目が変わった
（話し手が出ていないと誰も暗くしない・暗転のかかり方・立ち絵の出入りの濃さの曲線）。どれもテンプレートのコードの中の既定値で、
「Flix を先に固め、あとは yarn と JSON だけで回す」（`AGENTS.local.md` の「速く作る流れ」）の 2 段階目で直せなかった。

## 1. 決まった事

| 段階 | 中身 | 決定 |
|---|---|---|
| 1a | 暗転の形を Doc の欄へ（`novel.backdrops.json` の `black`） | **入れた** |
| 1b | `bin/fge yarn explain`（行で省いた値の出どころを出す道具）・`TalkExplain`・vocab の `defaultFrom` / `rules` | **保留** |
| 2 | 場面ごとの上書きの命令（`<<bg … hold=>>`・`<<highlight voices=…>>` など） | **保留** |
| 3 | 欄の無い決まりに Doc の欄を足す | **入れた** |
| 4 | engine へ移す（`YarnCommands.Param.defaultFrom` など） | 1b を入れる時に相談 |

保留の理由:
- **1b**: スパイクの試し（13 回）で、AI が explain を使ったのは 1 回だけだった。役に立ったのは主に「Doc に欄があること」で、
  スキーマの label と Doc の note から欄へ辿れた。explain は go の道具と vocab の JSON の約束を増やす（engine 側の道具の値段）ので、
  欄を出した後でも出どころが分からずに困る例が出てから入れる。
- **2**: Stage とセーブの形が変わり、比べ（migrate）の基準の撮り直しが要る。場面ごとに出し分けたい例（血鱗の移しで要る物）がまだ無い。
  その行だけ変えたい時は、今ある命令の引数（`time=`・`ease=`・`transition=`・`<<text align=>>`）で足りる。

## 2. 入れた欄（どれも既定値は今と同じ）

| Doc | 欄 | 意味 | その行だけ変える |
|---|---|---|---|
| `novel.backdrops.json` | `black`（`fadeOut`・`hold`・`fadeIn`） | 暗転の秒を、暗くなる・暗いまま止まる・明ける の比で分ける（Ren'Py の `Fade(out, hold, in)` の形）。写真は止まる間の真ん中で替わる。既定 0.5・0・0.5 | `<<bg … time=>>`（合計の秒） |
| `novel.backdrops.json` | `defaultSeconds`・`defaultEase` | `time=` / `ease=` を省いた `<<bg>>` の秒と進みの曲線。既定 1.0・linear | `time=`・`ease=` |
| `novel.cast.json` | `fadeEase` | 立ち絵と小物の出入りの濃さの曲線。既定 inOutSine | `<<show>>` / `<<hide>>` の `ease=`（濃さにも掛かるようにした） |
| `novel.cast.json` | `highlight.narration` | 地の文の行での明るさ。`brighten` = 全員を明るく戻す（既定）・`keep` = 前の台詞の話し手を強調したまま | — |
| `novel.cast.json` | `props.<名>.onPage` | 頁の幕がある間のその小物の重なり順。書かなければ一番上の `propsOnPage` | — |
| `novel.kind.json` | `windowFadeSeconds` | `time=` を省いた `<<window off>>` / `<<window on>>` で文字の枠が薄くなる・戻る秒。既定 0 | `<<window off time=>>` |
| `novel.theme.json` | `windows.<型>.align` | その型の本文の揃え（left・center）。書くと型に替えた時にこの揃えへ戻る。書かない型は今どおり `<<text align=>>` が続く | `<<text align=>>` |

main で先に入っていた `highlight.voices`（立ち絵を持たない話し手も強調に数える）と `propsOnPage` と合わせて、
この枝で足した欄は 7 つ（§2 の表の行）。main の 2 つと合わせて、§3 の表の 10 行のうち 8 行が Doc の欄になった。
欄の字が読めない時（曲線の名前の打ち間違い・知らない narration / onPage / align）は、既定で続けて `Log.fellBackThen` で 1 行言う。

### 決めたこと（細かい所）

- **`ease=` を濃さにも掛けた**: 今まで `<<show>>` / `<<hide>>` の `ease=` は from= や x= の動きにだけ掛かり、濃さは inOutSine に決まっていた。
  業界（Naninovel の `@char easing:`）では 1 つの曲線が全部に掛かるので合わせた。リポジトリと手元のゲームの yarn に `<<show … ease=>>` を
  書いた所は 0 件だったので、今のゲームの見た目は変わらない。動きの既定（smoothstep）はそのまま。
- **`ease=` は vocab の型が `choice` になった**: engine の `YarnCommands.Param.ease` は既定を表に持つ（Req）ので、書いたかが分からず Doc の既定へ落とせない。
  engine を触らずに済ませるため、`Curve.easeTable` の名前の `choice` で受けた（`<<bg>>`・`<<show>>`・`<<hide>>`。`<<move>>` などは今のまま）。
  build の検査は同じ名前を通す。engine に `Param.easeOpt` を足すかは段階 4 で相談。
- **`align` は書いた型だけ戻す**: 型を替えるたびに型の既定へ戻すと、今のシナリオの `<<text align=center>>` の後の `<<window 型>>` で見た目が変わる。
  型に `align` を書いた時だけ戻す（スパイクのレビュー 2 回目 R-g）。
- **`onPage` は小物ごとの欄まで。命令ごとは入れない**: 同じ小物を場面で幕の上と奥へ出し分ける例が無く、命令ごとにするとセーブの形が変わる。
- **濃さの曲線は Curve.ease に任せた**: inOutSine を今の式（sin と位相）から `Curve.ease`（cos）に替えても、reference-check の 45 枚と
  比べの 473 コマがバイトまで同じだったので、特別扱いは入れていない。

### 欄に出さないと決めた物

親から「出す価値があるか判断」を頼まれた 3 つ:

| 決まり | 判断 | 理由 |
|---|---|---|
| 地の文で全員が明るく戻る | **出した**（`highlight.narration`） | ゲームの好みで分かれる（地の文の間も直前の話し手に目を向けたい作品がある）。2 つの場合分けで、式は `Stage.withLineSpeaker` に残る |
| ADV の枠の間は `<<bg>>` で頁を送る | 出さない | 頁の区切りの構造の決まりで、送らないと前の背景の台詞が新しい背景に残る。変えたい例がまだ無い。要るならゲームの命令（`GameCommands`）で包める |
| 出入りで大きさが変わらない | 出さない | 拡大しながら出す等は演出の振り付け（`/doc-design` の「振り付けはコード」）。場面ごとなら `<<show>>` の後の `<<move scale=>>` で書ける |

振る舞いの決まり（人物だけを暗くする・表情替えはクロスフェード・前の背景が無い時の暗転・暗転が人物も暗くする）は、スパイクの線のまま出さない。

## 3. 棚卸し（スパイクの 36 行から、ゲームごとに変えたくなる物だけ）

| 決まり | 今 |
|---|---|
| 話し手が出ていない台詞で誰も暗くしない | Doc `highlight.voices`（main） |
| 地の文で全員が明るく戻る | Doc `highlight.narration`（この枝） |
| 立ち絵の濃さの曲線（ease= を無視していた） | Doc `fadeEase`・`ease=` が濃さにも掛かる（この枝） |
| `<<bg>>` の既定の秒と曲線 | Doc `defaultSeconds`・`defaultEase`（この枝） |
| 暗転の形 | Doc `black`（この枝） |
| `<<window off/on>>` の既定の秒 | Doc `windowFadeSeconds`（この枝） |
| 字の揃えの既定 | Doc `windows.<型>.align`（この枝） |
| 小物の重なり（ゲーム全体・小物ごと） | Doc `propsOnPage`（main）・`onPage`（この枝） |
| ADV で `<<bg>>` が頁を送る | コード（出さない。§2） |
| 出入りで大きさが変わらない | コード（出さない。§2） |

コードの既定のうち、vocab の default に出ているだけの物（`<<move>>`・`<<camera>>`・`<<tween>>` の 0.5 秒と smoothstep）は、
ゲームごとに変える要求が弱いので今のまま。

## 4. 確かめた事

- テンプレートの `make test` **637 本緑**（足したテスト 28 本: 暗転の形 5・`<<bg>>` の既定 5・`windowFadeSeconds` 2・`onPage` 2・`narration` 4・
  `fadeEase` と `ease=` 4・`align` 5・スキーマの曲線の名前が `Curve.easeTable` と同じ 1）。暗転と narration は、描く元の Doc を替えて舞台と描いた物で確かめるテストも置いた。
- `make reference-check` **45 枚すべてバイト一致**・budget OK。
- 比べ: main（05926221）で `make migrate-baseline` → この枝で `make migrate-new` が**通った**（止める違い 0 件・比べたコマ 473 枚）。
- 新しいゲーム（`make new-game … TEMPLATE=sound-novel-starter`）の足元で `make agent-eval ONLY=novel-blackout-hold` が 100 点（2 回目）。
  1 回目は答えが正しいのに 50 点で、期待の語を括弧の中の説明（`black（fadeOut・hold・fadeIn）`）に当てていたのを、
  choice の名前に当たる形へ直した（括弧の中が採点に入らないのは答えと点からの推定）。
- engine の Flix は触っていない（pub API の増減 0）。go の道具も触っていない。

## 5. 残した事・人に伺う事

1. 段階 1b（explain）を入れるか。入れるなら agent-eval で AI が使うのを確かめてから（スパイクでは 13 回に 1 回）。
2. engine に `YarnCommands.Param.easeOpt`（既定を持たない ease）を足すか。足せば `<<bg>>`・`<<show>>`・`<<hide>>` の vocab の型を `ease` へ戻せる。
3. 段階 2（場面ごとの上書きの命令）は、血鱗の移しで要った時に。
4. 「頁の幕」と「頁の覆い」が同じ物を指す言葉の揺れ（main 由来を含む）。テンプレート全体の言葉の直しなので別の仕事にする。

## 6. 設計レビュー（最後の 1 回）

**86 点・必須 0 件**（正しさ・設計・テスト・Doc の形・計画書）。既定値が今と同じになる理屈（暗転の式・inOutSine の式・onPage の分け方・align の順）を式の上で確かめた、との評。

推奨で直した物:
- 欄の字が読めない時に黙って既定へ戻していた → `Log.fellBackThen` で 1 行言う（曲線の名前・narration・onPage・align）。前からある `propsOnPage` は main の物なので触っていない。
- Doc から振る舞いへつなぐ所のテストが 2 か所無かった → 暗転は Doc の `black` を替えて覆いの濃さを、narration は Doc から Bool にする所（`CastDoc.keepsSpeakerOnNarration`）を確かめるテストを足した。
- 曲線の名前を引く処理が 3 か所にあった → `BackdropDoc.easeOf` / `easeIn` の 1 か所にした。スキーマの名前の一覧と `Curve.easeTable` を比べるテストを足した。
- 計画書の数（7 つ / 8 行）と空の節。
- 好みのうち: `fadeIn = 0` を比の足し算でなく直に見分ける・既定値を `defaults()` から引く・`windowFadeSeconds` の label（次の台詞で戻る時はすぐ）・前の背景が無い時の暗転の説明。

残した物（好み）: 秒の上限がスキーマと命令でそろっていない・`Cast.layerOf` の効かない曲線の値・タプル 1 つで 2 つの事実を見るテスト。
知らない名前で既定へ戻るテストは、`Log.fellBackThen` が標準エラーに書くとテストの道具が落とすので置いていない（言うことは手で確かめた）。
