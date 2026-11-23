# セーブの後方互換 — 古いセーブを新しい版のゲームで読み続ける

ゲームを更新しても、遊んでいる人のセーブは前の版の形のまま残っている。新しい版がそれを読めないと、
「つづきから」が消えるか、もっと悪いと黙って上書きされる。ここに書く 7 本は、どのゲームでも守る決まり。
道具は engine_world の `SaveFormat`（版と書き換え・上書き前の控え・見本を読むテスト）。

## 1. 並びの番号でなく、変わらない名前（id）で持つ

地図・置き物・頼み事・選択肢・セーブ枠を、リストの何番目かで持たない。間に 1 つ足す・消すと、後ろが全部ずれる。

```json
// 悪い: 開けた宝箱を地図の置き物の並びの番号で持つ。地図に置き物を 1 つ足すと別の箱が開いた扱いになる
{ "opened": [0, 3, 4] }
// 良い: 置き物に名前を付けて、その名前で持つ
{ "opened": ["cave_chest_a", "cave_lever", "town_box_2"] }
```

シナリオの行も同じ。既読を「ファイル:行番号」で持つと、1 行足しただけで下の既読が全部ずれる。
行に名前（Yarn の `#line:` タグなど）があればそれを鍵にする。

## 2. 欄を足す時は「無い時の既定値」で読む。欄の意味は変えない

古いセーブには新しい欄が無い。欄 1 つが無いだけでセーブ全体を読めない扱いにしない
（`JsonCodec.intOr` / `stringOr` / `boolOr`）。意味を変えたくなったら、同じ名前を使い回さず新しい名前の欄を足す。

```flix
// 悪い: 足した欄 gold が無いと全体が None（古いセーブが全部読めなくなる）
gold <- Map.get("gold", obj) |> Option.flatMap(JsonCodec.expectInt);
// 良い: 無ければ 0 で読む
let gold = JsonCodec.intOr("gold", 0, obj);
```

1 行だけ読めない（消した仲間の id など）時も、全体を捨てずにその行だけ落とし、`Log.warnThen` で 1 行言う
（[error-handling.md](error-handling.md) の決まり 3）。enum を字で書く時は `"${enum}"`（case の名前）に頼らず、
固定の字へ `match` で写す。case の名前を変えると、古いセーブが黙って既定値に戻るため。

## 3. 形を変える時は版を上げ、書き換えを登録する

欄の足し算で済まない変え方（名前の付け替え・入れ物の作り替え）は、版を 1 つ上げて「版 n → n+1」の書き換えを書く。
ゲームの読み関数は、いつも最新の形だけを読む。

```flix
def saveFormat(): SaveFormat.Format =
    SaveFormat.make("rune", 3)                       // 形式の名前と今の版
        |> SaveFormat.withMigration(1, renameHpToLife) // 1 版 → 2 版
        |> SaveFormat.withMigration(2, addItems)       // 2 版 → 3 版
        |> SaveFormat.withUnwrappedVersion(json ->     // 包みの無い古いセーブを何版として読むか
            JsonCodec.expectObject(json) |> Option.map(obj -> JsonCodec.intOr("version", 1, obj)) |> Option.getWithDefault(1))
```

書く物は `{"format": "rune", "version": 3, "data": {…}}` の包みになる。読む時は版を見て書き換えを順に通す。
書き換えが抜けている版・書き換えが Err を返した時は、読めないことを Err で返す。

## 4. 出した版ごとのセーブの見本をテストに置き、毎回読む

版を出したら、その版のセーブを 1 つ `test/save-samples/` に置く（消さない）。テストは 1 行。
`toJson` の出力から見本を作らない。`toJson` を直すと見本も一緒に変わり、古い形を読めているか確かめられない。

```flix
@Test
def testEveryReleasedSaveStillLoads(): Unit \ {Assert, Fs.DirList, Fs.FileRead} =
    Assert.assertEq(expected = Nil, SaveFormat.checkSamples("test/save-samples", Saves.fromData, Saves.format()))
```

失敗すると `(見本のファイル名, 理由)` の列が出る。見本が 1 つも無いフォルダも失敗に数える。

## 5. 版が上がる前の中身を控えに残す

`SaveFormat.save` は、今あるセーブが古い版なら、上書きする前にその字を `<道>.v<版>.bak` へ写す。
同じ版の控えが既にあれば写さない（初めて上げた時の 1 つだけ残る）。書き換えに誤りがあっても、控えから戻せる。

- デスクトップ: セーブの隣のファイル（`saves/slot1.json.v2.bak`）
- ブラウザ: localStorage の鍵 `<ゲームの id>/saves/slot1.json.v2.bak`（開発者ツールの Application → Local Storage で見える）。
  ブラウザ版は `saves/` の下しか残らないので、セーブの道は `saves/` の下に置く（[web-export.md](web-export.md)）

## 6. 未来の版は上書きしない

新しい版のゲームで遊んだ後に古い版を開くと、知らない版のセーブがある。`SaveFormat.load` はそれを Err で返し、
`SaveFormat.save` は今のファイルが今より新しい版なら書かずに Err を返す。
ゲームは「新しい版のセーブがあります」と出し、新しく始めても前のセーブを消さない。

## 7. 「全部済み」のようなフラグ 1 つで状態を潰さない

進み具合を 1 本の段階や「全部済み」のフラグにまとめると、後から足した物が飲み込まれる。

```json
// 悪い: 頼み事の進みを 1 本の段階で持つ。段階を間に足すと "reported" のセーブはそれも済んだことになり、2 本目の頼み事も入らない
{ "quest": "reported" }
// 良い: 頼み事ごと・済んだ事ごとに名前で持つ
{ "quests": { "mine_boss": "reported" }, "flags": ["met_smith", "boss_down"] }
```

## 書いたゲームの版を包みに残す（gameVersion）

包みの `version` はセーブの**形**の番号で、遊ぶ人が見るゲームの版（1.4.0 など）ではない。
どの版のゲームが書いたセーブかを残すには `withGameVersion` を足す。包みに `"gameVersion"` が入る
（Minecraft の level.dat の `Version.Name`・Unity の `Application.version` と同じ物）。

```flix
def gameVersion(): String = "1.4.0"            // 出すたびに上げる（形が変わらない更新でも上げる）

def saveFormat(): SaveFormat.Format =
    SaveFormat.make("rune", 3)
        |> SaveFormat.withMigration(1, renameHpToLife)
        |> SaveFormat.withMigration(2, addItems)
        |> SaveFormat.withGameVersion(gameVersion())
```

書く物は `{"format": "rune", "version": 3, "gameVersion": "1.4.0", "data": {…}}`。読む側:

- `SaveFormat.gameVersionOf(json)` — 読んだ字の JSON から `Some("1.4.0")`。`gameVersion` の無い古い包み・包みの無いセーブ・字でない値は `None`。
  形式の名前は照らさない
- 未来の版を断る `Err` の文面に「・1.6.0 で書いた」が入る（`load` / `decode` と、上書きを断る `save`）
- 不具合の報告にセーブを添えてもらえば、どの版で書いたか分かる。見本（決まり 4）を置く時も出どころが字で残る

**`gameVersion` で読み方を分けない。** 形の違いは包みの `version` と書き換えが持つ。ゲームの版で分けると、
形の変わらない更新ごとに分岐が増え、`gameVersion` の無い古いセーブを読めない道ができる。
`gameVersion` は**最後に書いた**版で、上書きのたびに今の版になる（初めて書いた版は残らない）。

engine は project.json も git も読まない（ブラウザの束には flix.toml も git も無い）。
字はゲームが持ち、下の flix.toml と照らすテストで古くならないようにする。

### 上げ忘れを止めるテスト

版を出す時は flix.toml の `[package]` の `version` を上げる。セーブの字がそれとずれたら、デスクトップのテストで止める
（テストはゲームの根で走るので flix.toml を `Fs.FileRead` で読める）。
project.json の `"version"` は project.json というファイル自身の形の番号なので、ゲームの版には使わない。

```flix
@Test
def testSaveGameVersionMatchesFlixToml(): Unit \ {Assert, Fs.FileRead} =
    Assert.assertEq(expected = flixTomlVersion(), SaveFormat.getGameVersion(Saves.format()))

/// flix.toml の [package] の version の字。
def flixTomlVersion(): Option[String] \ Fs.FileRead =
    Fs.FileRead.readLines("flix.toml") |> Result.toOption |> Option.flatMap(List.findMap(line ->
        match String.splitOn({substr = "="}, line) {
            case key :: value :: Nil if String.trim(key) == "version" =>
                Some(String.trim(value) |> String.stripPrefix({substr = "\""}) |> Option.flatMap(String.stripSuffix({substr = "\""})) |> Option.getWithDefault(String.trim(value)))
            case _ => None
        }))
```

## アップデートで何をしたか → ゲーム側がすること

| アップデートでしたこと | ゲーム側がすること | 道具 |
|---|---|---|
| 版を出した（形は不変） | ゲームの版の字を上げる | `withGameVersion`（flix.toml と照らすテスト） |
| 欄を足した | 無い時の既定値で読む・形の版は上げない | `JsonCodec.*Or`（決まり 2） |
| Doc に物を足した | 何もしない（id で持てば新しい物として出る）・頼み事など順に意味がある物は末尾へ | 決まり 1・7 |
| Doc から物を消した | 何もしない（知らないキーは遊びに出さず書き戻す） | ゲーム側のキーと値の置き場 |
| 欄の名前・入れ物の形を変えた | 形の版を上げ n→n+1 の書き換えを足す（Doc を見ない・知らないキーと `applied.*` の印を残す） | `withMigration`・`checkSamples` |
| 古いセーブの遊びの状態に一度だけ手を入れる | 名前付きの手順を列の末尾に足す（版で分けない・名前を変えない・消さない・最初の失敗で止まる） | 名前付きの手順（今はゲーム側で試し中。2 つ目の使い手が出たら engine へ） |
| 新しい版のセーブを古いゲームで開いた | 何もしない（Err で断り上書きしない） | 決まり 6・Err の文面の版 |

境目の決まり:

- 書き換え（migration）は形だけを変え Doc を見ない（JSON → JSON）。手順（upgrade step）は今の形の上で Doc を見てよい。
  流れる順は 書き換え → 中間形 → 手順 → 遊びの状態。
- `gameVersion` は診断用で判断に使わない。版で分けたくなったら名前付きの手順を足す。

## SaveFormat と Persistence・SaveManager

| 道具 | 持つ事 |
|---|---|
| `Saveable`（Persistence） | 値 ⇄ JSON の変換（型ごとの `toJson` / `fromJson`） |
| `SaveFormat` | 包み（形式の名前・版・書いたゲームの版）・書き換え・控え・未来の版の判断・見本のテスト |
| `SaveManager` | `saves/slot{N}.json` の道の決まりだけ（`SaveManager.slotPath`） |

`Saveable` の型なら `SaveFormat.saveValue(SaveManager.slotPath(1), value, format)` /
`SaveFormat.loadValue(道, format)`（ファイルが無ければ `Ok(None)`）。JSON のまま扱うなら `save` / `load`。
読み書きは `Fs.FileRead` / `Fs.FileWrite` の上だけなので、デスクトップもブラウザ（`WebFs`）も同じコードで動く。
