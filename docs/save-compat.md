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

## SaveFormat と Persistence・SaveManager

| 道具 | 持つ事 |
|---|---|
| `Saveable`（Persistence） | 値 ⇄ JSON の変換（型ごとの `toJson` / `fromJson`） |
| `SaveFormat` | 包み（形式の名前・版）・書き換え・控え・未来の版の判断・見本のテスト |
| `SaveManager` | `saves/slot{N}.json` の道の決まりだけ（`SaveManager.slotPath`） |

`Saveable` の型なら `SaveFormat.saveValue(SaveManager.slotPath(1), value, format)` /
`SaveFormat.loadValue(道, format)`（ファイルが無ければ `Ok(None)`）。JSON のまま扱うなら `save` / `load`。
読み書きは `Fs.FileRead` / `Fs.FileWrite` の上だけなので、デスクトップもブラウザ（`WebFs`）も同じコードで動く。
