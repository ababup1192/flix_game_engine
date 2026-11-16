# 移行の突き合わせ（`bin/fge migrate`）

ゲームを新しいテンプレートへ移す前と後で、同じ flow を流した記録を突き合わせ、前と同じ動きかを確かめる。
決めた事と理由は [plans/novel-vocab-n4-design.md](../plans/novel-vocab-n4-design.md) の 10 章。ここは記録の形と口の使い方だけを書く。
本体は `go/internal/migrate`。

## 合格線（人・2026-11-16）

台詞・選択肢・変数・音の順は完全一致。絵は数画素のずれまで許す。迷った差は止めずに一覧へ溜め、最後に動画を並べて人にまとめて見せる。

| 違い | 扱い |
|---|---|
| 出来事の並び（台詞の字・話し手・選択肢・選んだ物・待ちの秒）・問いの値・音の名前と順・撮れていない記録（flow・大きさ・演出の後のコマ・古いセーブとそのコマ）・撮っていない途中のコマ（intended で承認できる）・前の版の記録が無い flow と大きさ（nobaseline で承認するまで）・コマの大きさの違い・どの flow も通らない命令の行 | **門を止める**（終わりの番号 1） |
| コマの画素・途中のコマの命令の秒（`seconds`）・画面の物の矩形と区間・音の時刻・バスの音量・（`--times` の時）台詞・選択肢・待ちの前の出来事からの間 | **迷った差**。一覧に溜めて止めない（`--strict` なら止める） |

出来事の並びが違った flow は、後ろ（音・問い・画面の物・コマ）を比べない（読み違いの後の比べは意味が無い）。
出来事の並びの違いと撮れていない記録は承認できない（直す）。途中のコマ（`mid`）だけは、命令を組み替える（古い命令 2 つを `overlay` 1 つにまとめる等）と生まれなくなる事があるので、撮っていなければ止める側の差にしたうえで `what: frame` の intended（`node` と `seq` か時刻の範囲）で承認できる。systematic では通せない。

## 口

```
bin/fge migrate diff <baseline> <new> [--accept FILE] [--game DIR] [--out DIR] [--no-coverage] [--strict] [--times] [--json]
bin/fge migrate video --old OLD.mp4 --new NEW.mp4 --out OUT.mp4 [--tape NEW/tape.json]
bin/fge migrate shoot <名前> <flow>... [--jobs N] [--video] [--run CMD] [--saves-from DIR] [--no-saves] [--overwrite]
```

- `shoot`（ゲームの根で）: flow を並べて流し、記録を `debug/migrate/<名前>` に撮る。flow ごとに `FlowVideo.play` を `FLOW`・`FLOW_OUT`・`MIGRATE_OUT` 付きで流し、続けて `--saves-from`（既定 `debug/migrate/baseline`）の `flows/*/saves.json` を `FlowVideo.restore` で読み戻す。どれも別の JVM で、`--jobs` 本ずつ並べる（既定はコア 4 つに 1 本・メモリ 8 GB に 1 本の少ない方・6 本まで）。並べる時は JVM ごとのヒープを `HEADLESS_JAVA_OPTS` の `-XX:MaxRAMPercentage=60/本数` に絞る（自分で `-Xmx` か `MaxRAMPercentage` を渡せばそれが勝つ）。長い flow（基準の tape.json が大きい物）から流す。
  - 流す口は `--run`、無ければ環境変数 `HEADLESS_RUN`（ゲームの Makefile の物をそのまま渡せる）、無ければ engine の `bin/headless-run`。
  - `--video` の無い時は flow ごとの video.mp4 を束ねず、`FLOW_VIDEO=off` を渡す（読む FlowVideo は全コマの動画と音を書かない。読まない版は書くので、shoot が消す）。diff は video.mp4 を読まない。
  - ログと秒: `<記録>/logs/<flow>.log`・`restore-<flow>.log`・`shoot.json`（JVM ごとの秒と終わりの番号）。終わりの番号: 0 全部撮れた・1 どれかが止まった・2 引数の誤り。
  - 速さの内訳と、テンプレート側に残っている変更は [plans/novel-tape-deck.md](../plans/novel-tape-deck.md)。

- `diff` の既定: `--accept` は `<new の親>/migrate-accept.json`（無ければ承認なし）・`--game`（カバー率で台本を読むゲームのルート）は `<new>` から上へ辿って最初に `project.json` のあるフォルダ・`--out` は `<new の親>/report`。
- `diff` が書く物: `<out>/index.html`（flow と大きさごとに、左に前・右に後・下に差の色の図。止める違い・迷った差・承認済みを分けて並べる）・`<out>/report.json`（同じ中身の JSON）・`<out>/heat/*.png`（線を超えたコマの差の色の図。毎回消してから書く）。
- 頁の上の「承認済みの読み替えと系統の違い」に、`probeMap` で読み替えた値と回数・`restore: refused` で比べたセーブ・systematic の承認（1 つの理由に全部の flow の当たった絵）を並べる。前の版の記録が無い flow と大きさは、新しい版のコマ（`world` と `all`）を全部並べる（承認の後も並べたまま）。どの差にも当たらなかった承認・どの値にも当たらなかった `probeMap`・通る行を指す `coverage` の承認は「使われていない承認」に出す（止めない）。
- `layer: all` のコマは画素を比べない。頁に並べるのは nobaseline の時だけで、文字の枠と UI の見た目は `video` の横並びの動画で見る。
- `--times`: 並びの同じ出来事（line・choice・wait）の時刻を、前の出来事（最初は記録の頭）からの間で比べ、1 フレームを超えたら迷った差（`what: eventTime`）にする。頭からの時刻で比べないのは、前の版が待ちの明けるたびに 1 フレーム遅れる事があり（浮動小数の足し算の丸めで出たり出なかったりする）、続く `<<wait>>` でずれが積み上がるため。待ちを時刻表に移す直し（plans/novel-waits-timeline.md）の門は `--strict --times`。
- 終わりの番号: 0 通った・1 止める違いがある（`--strict` なら迷った差も）・2 引数か記録が読めない。
- `video`: 2 本を高さ 960 にそろえて左右に並べる。短い方は最後のコマと無音で長い方の長さまで伸ばす（長さが替わった所を見るため）。音の無い mp4 は無音として並べる。動画が無い時の終わりの番号は 2。音は前を左・新しい方を右のチャンネルに入れる（片耳ずつ聞いて間と音量の差を聞き分ける）。`--tape` があれば台詞ごとに「ノード #番号 秒」の字幕を絵に重ねる（`<OUT>.srt` も残る）。ffmpeg は環境変数 `FFMPEG` か PATH の物。長さと音の有無を読む ffprobe は ffmpeg と同じフォルダの物を使い、無ければ終わりの番号 1 で落ちる。

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
| `events` | `[{t, node, kind, seq, who?, text?, options?, picked?, seconds?, probes?}]` | ノードの中の出来事の並び。`kind` は `line`・`choice`・`wait`（ほかの kind は読み飛ばす）。`seq` は line ならノードに入ってから何番目の台詞か（0 から・ノードに入り直すと 0 から）、choice と wait ならそれまでに出した台詞の数。`seconds` は wait の秒。**書き手への約束**: line の `text` と choice の `options` は台本の字（始まりの引数の直しは当てるが、テンプレートの `novel.story.json` の `replace` のような画面だけの置き換えは当てない。前の版が置き換えていても台本の字で突き合わせる）。**書き手への約束**: wait は台本の `<<wait 秒>>` だけにする（命令が出す待ち（テンプレートの `Commands.Out.Wait`・押すと明ける `Commands.Out.WaitOrTap`）は wait にせず、その命令の秒として frames の mid の `seconds` に入れる。WaitOrTap を押して早く明けた時も予定の秒。flow の reader はその間は押さない）。`probes` は line だけが持つ `{問いの名前: 値}`（その台詞を出し終えた時の問いの値の全部。値は文字か数） | 台詞と選択肢は `timeline`・`lines`・`choices` から組んで比べる。待ちの時刻は比べない（`--times` の時は前の出来事からの間を比べる）。問いは問いごとの値の移り変わりの順だけ比べる |
| `buses` | `{バスの名前: [[秒, dB または null]]}` | バスの音量の変わり目（フェードの間は 1 フレームごと）。null は無音。**書き手への約束**: ミキサーのバスの音量を World か Res から読めない時は、欄ごと出さない（推した値や 0 dB で埋めない。埋めると前と後で同じ偽の値が並んで通る） | 音量を比べない |
| `frames` | `[{file, t, node, seq, kind, cmd?, step?, at?, seconds?, layer, backdrop3d?}]` | 書き出したコマ。`file` は tape.json からの相対パスの PNG。`kind` は `lineDone`（台詞を出し終えた所）か `mid`（時間を取る命令の途中）。`seq` は直前に出し終えた台詞の番号（まだなら -1）。mid は `cmd`（命令の名前）・`step`（その台詞の後で何番目の時間を取る命令か・0 から。秒の分からない命令も数える）・`at`（命令の秒に対する割合。0.25・0.5・0.75）・`seconds`（その命令が実際に取った秒）を持つ。**書き手への約束**: 秒は命令が実際に取った秒（位置の引数・`time=`・Doc の既定のどれで書いても、命令を当てて動いた長さ）にし、その版の命令の書き方で返す（`time=` だけを読むと、秒を位置の引数で書く版では mid が 1 枚も出ず、演出の途中の比べが黙って効かない）。秒の分からない命令は撮らないが step には数える（数えないと、片方の版だけ秒が分かる時に後ろの step が全部ずれる）。`layer` は `world`（文字の枠・HUD・UI を描かない）か `all`。`backdrop3d` は 3D の背景が休みの位置のコマ | コマを比べない |
| `ranLines` | `[{file, line}]`（行番号だけの `[行番号]` も読む。その時のファイルは `yarn`） | 実際に流れた台本の所（台詞と命令）。カバー率に使う。**書き手への約束**: インタープリタが実行した文を全部、実行した時に記録する（コマごとの台本の位置を写して作らない。同じフレームで流れる `bg`・`set`・`jump` は位置に残らず、偽の「通らない行」になる）。ロード・戻るの当て直し（Silent）で流し直した文は数えない（遊ぶ人が読んだ所ではない）。テンプレートは engine の `YarnRunner.ranSourcesSince` で読む | `lines` に出た行（通ったノードの行の全部）を通ったと見る。選ばなかった選択肢の中の行も通った扱いになる |
| `screen` | `{w, h}` | 画面の大きさ（px）。`objects` の割合の矩形を px に直す | `world` のコマの PNG の大きさ。それも無ければ矩形を比べない（数と区間だけ） |

前と後のコマは、鍵の土台 `layer|node#seq|kind`（mid は `|step@at` も）に「同じ土台が時刻の順で何回目か」を足した鍵で組にする。何回目かは書き手は書かず、読む側が両方の版で数える（同じノードへ入り直すと、台詞の無い場面転換のノードでも、`<<jump 自分>>` で続けて入り直しても、同じ土台が何度も出るため）。片方の版の中で同じ土台のコマが同じ時刻に 2 枚あれば、どれを組にするか決まらないので止める（承認できない）。時刻は版で揺れるので鍵に入れない。画素を比べるのは `layer: world` だけ。組になった途中のコマどうしは `seconds` も比べ、違えば迷った差にする（`at` は秒に対する割合なので、秒だけが替わると同じ割合のコマが同じ絵になり、画素では差が出ない。同じ命令の 3 枚は 1 件にまとめる）。片方の版にだけ `seconds` がある時は比べず、注意に出す。新しい版にだけある world のコマは比べず、数を注意に出す（新しい版で秒が分かるようになった命令の途中のコマなど）。前の版にあるコマが新しい版に無ければ止める（演出の後のコマは承認できない・途中のコマは intended で承認できる）。

音は時刻の順に、前の版の 1 つずつを新しい版の組になっていない最初の音と組にする。名前か kind が違えば、そこから 1 フレームの窓の中で同じ名前と kind の物を探す（同じフレームの中の順は比べない）。組になれない音が出た所で止め、組になった音の時刻のずれは迷った差にする。

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
| 絵のずれ | 2 px まで許す（相手の同じ所から 2 px 以内でいちばん近い色との差を、その画素の差にする。両向きに探して大きい方）。途中のコマ（`mid`）には使わない（なめらかな背景で overlay の濃さの差が隠れる） |
| 台詞を出し終えたコマ（`lineDone`）・古いセーブのコマ | 差が 2/255 以内の画素が 99.5% 以上 |
| 3D の背景の休みの位置（`backdrop3d`） | 差が 3/255 以内の画素が 99% 以上 |
| 途中のコマ（`mid`） | 画素の差（RGB）の平均が 3/255 以下 |
| 画面の物の矩形 | ±2 px（区間は ±1 フレーム） |
| 音の時刻 | ±1 フレーム（`1 / fps`） |
| 出来事の間（`--times`） | 前の出来事からの間の差が ±1 フレーム（`1 / fps`）+ 1 ミリ秒（t はミリ秒に丸めてある） |
| バスの音量 | 0.1 秒ごとに ±1 dB。両方を -60 dB で下に止めてから差を取る（null も -60）。続けて超えた所は 1 件にまとめる。片方の版にだけあるバスも迷った差。`duration` が無ければ記録の最後の時刻まで |
| 承認の時刻の範囲 | 1 件 3 秒まで |
| 承認の件数 | 1 本の flow で 20 件まで（同じ `why` はまとめて 1 件） |
| systematic で通せるコマ | 名指しの命令（`command`）が時間を取っている間の `mid` のコマで、差の平均が 6/255 以下。`flow` を省くか `"*"` にすると全部の flow に当てる |

## migrate-accept.json

```json
{
  "idMap":    { "lamp": "lair_lamp" },
  "rectFree": [ "fx_bubbles" ],
  "restore":  { "quick1": "refused" },
  "probeMap": { "mode": { "Nvl": "nvl", "Adv": "bottom" } },
  "entries": [
    { "id": "a1", "kind": "intended", "flow": "route_gem", "size": "design", "what": "frame",
      "node": "Lair", "seq": 3, "why": "背景の色を Doc の既定に合わせた",
      "images": ["baseline/flows/route_gem/design/frames/x.png", "new/flows/route_gem/design/frames/x.png"], "approved": true },
    { "id": "s1", "kind": "systematic", "what": "frame", "command": "overlay",
      "why": "overlay の ease の既定が古い曲線と 1 フレームずれる", "approved": true },
    { "id": "n1", "kind": "nobaseline", "flow": "full_story", "size": "short", "why": "前の版は短い画面で撮れない", "approved": true }
  ],
  "coverage": [ { "yarn": "assets/talk/kesshou.yarn", "line": 260, "why": "結末の後の stop は flow で届かない", "approved": true } ]
}
```

- `kind`: `intended`（わざと変えた物）・`systematic`（全体に出る系統の違い。コマだけ・`command` を名指し・件数の上限に数えない）・`nobaseline`（前の版の記録が無い大きさや flow）。
- 当てる所: `node` と `seq`（台詞の番号）か、`from` と `to`（秒の範囲・3 秒まで）のどちらか 1 つ。`size` を書かなければどの大きさにも当てる。
- `what`: `sound`・`bus`・`probe`・`object`・`frame`・`restore`・`eventTime`。
- `images` は承認のファイルのフォルダからの相対パス。頁でその承認の理由の下に並べる。無い絵は注意に出す。
- `approved: true` の無い件は「承認待ち」と出し、通さない。書き方の誤りと上限を超えた件は止まった理由に出し、その件は承認に使わない。
- `idMap` は前の版の objects の id → 新しい版の id、`rectFree` は矩形を比べず数と区間だけを見る id（粒・揺れ）、`restore` はセーブの名前 → `"refused"`（新しい版は読まずに知らせる。読み戻したら止める）、
  `probeMap` は問いの名前 → {前の版の値: 新しい版の値}（問いの値の言い方が替わった物。例: e2e の問い `mode` の `Nvl`・`Adv` → `nvl`・`bottom`。前の値を読み替えてから比べる。文字の値だけを読み替える）。
- `restore` と `probeMap` は人が書いた決めとして扱い、`approved` は要らない。その代わり頁の承認済みの節に必ず並べる。
