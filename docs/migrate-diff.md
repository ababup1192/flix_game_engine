# 移行の突き合わせ（`bin/fge migrate`）

ゲームを新しいテンプレートへ移す前と後で、同じ flow を流した記録を突き合わせ、前と同じ動きかを確かめる。
決めた事と理由は [plans/novel-vocab-n4-design.md](../plans/novel-vocab-n4-design.md) の 10 章。ここは記録の形と口の使い方だけを書く。
本体は `go/internal/migrate`。

## 合格線（人・2026-11-16）

台詞・選択肢・変数・音の順は完全一致。絵は数画素のずれまで許す。迷った差は止めずに一覧へ溜め、最後に動画を並べて人にまとめて見せる。

| 違い | 扱い |
|---|---|
| 出来事の並び（台詞の字・話し手・選択肢・選んだ物・待ちの秒）・問いの値・音の名前と順・撮れていない記録・どの flow も通らない命令の行 | **門を止める**（終わりの番号 1） |
| コマの画素・画面の物の矩形と区間・音の時刻・バスの音量 | **迷った差**。一覧に溜めて止めない（`--strict` なら止める） |

出来事の並びが違った flow は、後ろ（音・問い・画面の物・コマ）を比べない（読み違いの後の比べは意味が無い）。
出来事の並びの違いと撮れていない記録は承認できない（直す）。

## 口

```
bin/fge migrate diff <baseline> <new> [--accept FILE] [--game DIR] [--out DIR] [--no-coverage] [--strict] [--json]
bin/fge migrate video --old OLD.mp4 --new NEW.mp4 --out OUT.mp4 [--tape NEW/tape.json]
```

- `diff` の既定: `--accept` は `<new の親>/migrate-accept.json`（無ければ承認なし）・`--game`（カバー率で台本を読むゲームのルート）は `<new>` から上へ辿って最初に `project.json` のあるフォルダ・`--out` は `<new の親>/report`。
- `diff` が書く物: `<out>/index.html`（flow と大きさごとに、左に前・右に後・下に差の色の図。止める違い・迷った差・承認済みを分けて並べる）・`<out>/report.json`（同じ中身の JSON）・`<out>/heat/*.png`（線を超えたコマの差の色の図）。
- 終わりの番号: 0 通った・1 止める違いがある（`--strict` なら迷った差も）・2 引数か記録が読めない。
- `video`: 2 本を高さ 960 にそろえて左右に並べる。音は前を左・新しい方を右のチャンネルに入れる（片耳ずつ聞いて間と音量の差を聞き分ける）。`--tape` があれば台詞ごとに「ノード #番号 秒」の字幕を絵に重ねる（`<OUT>.srt` も残る）。ffmpeg は環境変数 `FFMPEG` か PATH の物。

## 記録のフォルダ

```
debug/migrate/
  baseline/                          前の版（git worktree で撮る・git に入れない）
    flows/<flow>/<大きさ>/tape.json   大きさは design・tall・short など自由な名前（前と後で同じ名前にそろえる）
    flows/<flow>/<大きさ>/frames/*.png
    flows/<flow>/tape.json           大きさを分けない時はこちら（大きさの名前は "-"）
    saves/<名前>/restore.json         古いセーブを読み戻した直後の記録
  new/                               新しい版（同じ形）
  migrate-accept.json                承認（人が書く）
  report/                            diff が書く頁
```

## tape.json の欄

今ある欄（`game`・`timeline`・`lines`・`sounds`・`objects`・`probes`・`choices` など）はテープの頁（`bin/fge tape`）と同じ物を読む。
突き合わせのために足す欄は次の 5 つ。**どれも無くてよい**。無ければその比べは「比べていない」と出し、門は落とさない。
`bin/fge tape` はこの 5 つを知っている欄として通す（頁には載せない）。

| 欄 | 型 | 中身 | 無い時 |
|---|---|---|---|
| `events` | `[{t, node, kind, seq, who?, text?, options?, picked?, seconds?, probes?}]` | ノードの中の出来事の並び。`kind` は `line`・`choice`・`wait`（ほかの kind は読み飛ばす）。`seq` は line ならノードに入ってから何番目の台詞か（0 から・ノードに入り直すと 0 から）、choice と wait ならそれまでに出した台詞の数。`seconds` は wait の秒。`probes` は line だけが持つ `{問いの名前: 値}`（その台詞を出し終えた時の問いの値の全部。値は文字か数） | 台詞と選択肢は `timeline`・`lines`・`choices` から組んで比べる。待ちは比べない。問いは問いごとの値の移り変わりの順だけ比べる |
| `buses` | `{バスの名前: [[秒, dB または null]]}` | バスの音量の変わり目（フェードの間は 1 フレームごと）。null は無音 | 音量を比べない |
| `frames` | `[{file, t, node, seq, kind, cmd?, step?, at?, layer, backdrop3d?}]` | 書き出したコマ。`file` は tape.json からの相対パスの PNG。`kind` は `lineDone`（台詞を出し終えた所）か `mid`（時間を取る命令の途中）。`seq` は直前に出し終えた台詞の番号（まだなら -1）。mid は `cmd`（命令の名前）・`step`（その台詞の後で何番目の時間を取る命令か・0 から）・`at`（命令の秒に対する割合。0.25・0.5・0.75）を持つ。`layer` は `world`（文字の枠・HUD・UI を描かない）か `all`。`backdrop3d` は 3D の背景が休みの位置のコマ | コマを比べない |
| `ranLines` | `[行番号]` | 実際に流れた台本の行（台詞と命令）。カバー率に使う | `lines` に出た行（通ったノードの行の全部）を通ったと見る。選ばなかった選択肢の中の行も通った扱いになる |
| `screen` | `{w, h}` | 画面の大きさ（px）。`objects` の割合の矩形を px に直す | `world` のコマの PNG の大きさ。それも無ければ矩形を比べない（数と区間だけ） |

前と後のコマは `layer|node#seq|kind`（mid は `|step@at` も）の鍵で組にする（時刻は版で揺れるので鍵に入れない）。画素を比べるのは `layer: world` だけ。

## restore.json の欄

| 欄 | 型 | 中身 |
|---|---|---|
| `save` | 文字 | 読み戻したセーブのファイルの名前 |
| `refused` | 真偽 | 「版が違うので読めない」と知らせて、はじめから始めた |
| `node`・`seq` | 文字・数 | 戻った所（ノードと台詞の番号） |
| `probes` | `{名前: 値}` | 読み戻した直後の問いの値の全部 |
| `objects` | tape.json の objects と同じ | 読み戻した直後に出ている物 |
| `frames` | tape.json の frames と同じ | 読み戻した直後のコマ（lineDone の線で比べる） |
| `screen` | `{w, h}` | 画面の大きさ |

`refused`・`node`・`seq`・`probes` の違いは止める。`objects` と `frames` の違いは迷った差。

## 線の既定（`go/internal/migrate` の `DefaultThresholds`・`DefaultLimits`）

| 物 | 既定 |
|---|---|
| 絵のずれ | 2 px まで許す（相手の同じ所から 2 px 以内でいちばん近い色との差を、その画素の差にする。両向きに探して大きい方） |
| 台詞を出し終えたコマ（`lineDone`）・古いセーブのコマ | 差が 2/255 以内の画素が 99.5% 以上 |
| 3D の背景の休みの位置（`backdrop3d`） | 差が 3/255 以内の画素が 99% 以上 |
| 途中のコマ（`mid`） | 画素の差（RGB）の平均が 3/255 以下 |
| 画面の物の矩形 | ±2 px（区間は ±1 フレーム） |
| 音の時刻 | ±1 フレーム（`1 / fps`） |
| バスの音量 | 0.1 秒ごとに ±1 dB。-60 dB 以下は無音。続けて超えた所は 1 件にまとめる |
| 承認の時刻の範囲 | 1 件 3 秒まで |
| 承認の件数 | 1 本の flow で 20 件まで（同じ `why` はまとめて 1 件） |
| systematic で通せるコマ | 名指しの命令（`command`）が時間を取っている間の `mid` のコマで、差の平均が 6/255 以下 |

## migrate-accept.json

```json
{
  "idMap":    { "lamp": "lair_lamp" },
  "rectFree": [ "fx_bubbles" ],
  "restore":  { "quick1": "refused" },
  "entries": [
    { "id": "a1", "kind": "intended", "flow": "route_gem", "size": "design", "what": "frame",
      "node": "Lair", "seq": 3, "why": "背景の色を Doc の既定に合わせた",
      "images": ["baseline/flows/route_gem/design/frames/x.png", "new/flows/route_gem/design/frames/x.png"], "approved": true },
    { "id": "s1", "kind": "systematic", "flow": "route_gem", "what": "frame", "command": "overlay",
      "why": "overlay の ease の既定が古い曲線と 1 フレームずれる", "approved": true },
    { "id": "n1", "kind": "nobaseline", "flow": "full_story", "size": "short", "why": "前の版は短い画面で撮れない", "approved": true }
  ],
  "coverage": [ { "yarn": "assets/talk/kesshou.yarn", "line": 260, "why": "結末の後の stop は flow で届かない", "approved": true } ]
}
```

- `kind`: `intended`（わざと変えた物）・`systematic`（全体に出る系統の違い。コマだけ・`command` を名指し・件数の上限に数えない）・`nobaseline`（前の版の記録が無い大きさや flow）。
- 当てる所: `node` と `seq`（台詞の番号）か、`from` と `to`（秒の範囲・3 秒まで）のどちらか 1 つ。`size` を書かなければどの大きさにも当てる。
- `what`: `sound`・`bus`・`probe`・`object`・`frame`・`restore`。
- `approved: true` の無い件は「承認待ち」と出し、通さない。書き方の誤りと上限を超えた件は止まった理由に出し、その件は承認に使わない。
- `idMap` は前の版の objects の id → 新しい版の id、`rectFree` は矩形を比べず数と区間だけを見る id（粒・揺れ）、`restore` はセーブの名前 → `"refused"`（新しい版は読まずに知らせる。読み戻したら止める）。
