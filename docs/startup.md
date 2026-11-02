# 起動の流れと、読み込み中に見せる物

実機の起動は次の順に進む。どこで何が画面に出るかを決めておくと、「起動画面のまま固まって見える」を区切りで直せる。

| 順 | 誰が | 何をする | 画面 |
|---|---|---|---|
| 1 | `LwjglLayer.withProject` | ウィンドウを出す | エンジンの起動画面（`starting up...`） |
| 2 | 同上 | テクスチャ・フォントを読む | エンジンの起動画面（`loading images...` など） |
| 3 | 同上 | 音を読む | 同上（`loading sounds...`） |
| 4 | ゲームの main（`App.loadAndLaunch` に渡す関数） | Doc・形・絵を読む・描く元（Res）を組む | 同上（`preparing game...` のまま。区切れば進む） |
| 5 | `App.loadAndLaunch` / `App.launch` | init・startupSystems・始まり（`withStarts`。Doc は読み直さない。`App.launch` で flow を記録する時だけ読み直す） | 同上 |
| 6 | `App.launch` のループ | 最初のコマ | ゲームの画面 |

4 と 5 を走っている間は、ゲームのループがまだ回っていない。誰もウィンドウのイベントを poll しないので、数秒続くと
macOS は応答なしのくるくるを出す。

## 読み込みを区切る（`LoadProgress`）

例の `LayoutDoc`・`ObjMesh` はゲームの中の名前（engine の物ではない）。

```flix
pub def loadDocs(): Res.Docs \ Fs.FileRead + IO + LoadProgress =
    LoadProgress.report("reading docs...", 0, 0);                    // 区切り 1 つ（本数不明の流れるバー）
    let layout = LayoutDoc.load(LayoutDoc.path());
    let files = LayoutDoc.models(layout)
        |> LoadProgress.mapWithProgress("reading models...", name -> (name, ObjMesh.readFiles(path(name))));
    let meshes = files
        |> LoadProgress.parMapWithProgress("building models...", e -> (fst(e), ObjMesh.build(snd(e))));
    ...
```

- `report(phase, done, total)`: phase は起動画面の字（組み込みのフォントなので英数字）・done / total は今の phase の中の本数。total 0 以下は本数不明。
- `mapWithProgress`: 1 つ作るたびに知らせる。
- `parMapWithProgress`: 並列に作る（スレッドは CPU の数まで・結果の並びは元のまま）。待つ間も 50 ms ごとに知らせるので、1 つが長くてもウィンドウが応答する。
  渡す関数は `IO` だけ — effect の handler はスレッドをまたがないので、`Fs.FileRead` で読む物は先に読んでおく。
- 本体のスレッドで、知らせの間が 0.5 秒を超えないように区切る。エンジンは 1 つの区切りの中に割り込めない。
- 自前の handler（テストで知らせを集める時など）は必ず `k` を呼んで返す。RenderTarget を開いたまま（Pass に描いている途中で）`report` を呼ばない。

受ける側:

| 経路 | 知らせは |
|---|---|
| 実機（`LwjglLayer.withProject`） | 起動画面を進めて poll する（間引きは 80 ms）。最初のコマの後に来た知らせは何もしない |
| headless の描き出し・動画・flow・テスト | 入口で `LoadProgress.runNoop` を張って捨てる |
| `LoadProgress` を使わないゲーム | 何も変わらない |

- 読み込み中に閉じるボタンが押されたら、読み込みの後の最初のコマで、いつもの閉じる処理（`App.withCloseRequest`）が受ける。
- 読み込み中に回したホイールは捨てる。押していたボタンは、一度離すまでエッジにならない。

## 最初のコマの後の読み込み

GPU への転送（絵・形）は GL の文脈がループの中にしか無いので、最初のコマの後に回る。数が多いゲームは、
World にローディング画面（`Screen.Loading` などの case）を持ち、1 コマに少しずつ上げる。
`LoadProgress` はループが回る前だけの物で、ループの中の重い処理は区切れない。
