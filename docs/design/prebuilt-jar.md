# 窓なしのゲームの jar を先に作っておく（prebuilt-jar）

状態: **設計のみ・未実装**（2026-10-20）。実装は依頼主がこのメモを見てから。

ゲームの master に push されるたびに、Mac mini が `build/headless/headless.jar` を作って置いておく。Studio と `bin/headless-run` は、
指紋の合う jar があればそれを取ってきて使い、65 秒の組み立てを省く。合う物が無い・取れない時は、今どおり手元で作る。

前提: jar の指紋（`jar.manifest`）は jarfix（0.52.1 の見込み）の決まりに従う。

- 指紋は src・flix.toml・lib の中身から作る。lib は、flix.toml か packages.lock に名前のある版だけを入れる。
- jar を作る写しにだけある入口の束（`src/FgeHeadlessMain.flix`）は入れない。
- 作り終えた後に、作った写し（`build/headless/proj`）から取り直す。
- java と java の旗は混ぜない（0.52）。

## 0. 今かかっている時間（実測・2026-10-20・internet_dungeon・Mac mini）

| 物 | 値 |
|---|---|
| jar を作る時間 | 65 秒（`build/headless/last-build-seconds`）。版を上げた直後の 1 回目は、lib へ依存を落とす分で長くなる |
| jar の大きさ | 41.3 MB（lwjgl の native は macOS・Linux・Windows の arm64 / x64 が全部入っている） |
| jar の中身の形 | Java 21 の class（class の版 65）。Studio の jre（21.0.12）でも端末の java（21.0.8）でも動く |
| ゲームの master への push | 1 日 49 回・7 日 391 回（first-parent）。直近の 60 回のうち、src・flix.toml・packages.lock が変わったのは 39 回 |
| この Mac mini の作業場 | `id-x-*` が数十あり、同じ指紋の jar を作業場ごとに作り直している |

最後の行が大事です。いちばん効くのは「Mac mini の外へ配る」より先に、**同じ機械の作業場どうしで同じ指紋の jar を分け合う**所です
（1 節の段 1）。

## 1. 置き場

2 段に分ける。どちらも鍵（2.1 節）で引き、中身の SHA-256 を添える。

| 段 | 置き場 | 誰が引くか |
|---|---|---|
| 段 1: 機械の中 | `~/.cache/flix-headless-jar/<鍵>/`（`headless.jar`・`jar.manifest`・`FgeHeadlessMain.flix`・`sha256`） | 同じ機械の作業場すべて（Mac mini のエージェント・Studio） |
| 段 2: 機械の外 | 下の表のどれか 1 つ | ほかの Mac の Studio・新しく clone した作業場 |

段 1 は、`headless-run` が jar を作り終えた時に必ず写す（作った人が置く）。Mac mini の常駐の作り手（3 節）は段 1 に置いてから、段 2 へ上げる。

段 2 の比べ:

| | GitHub Release の資産 | Actions の artifact | Mac mini の HTTP（Tailscale の中） |
|---|---|---|---|
| 1 本の大きさ | 2 GiB まで。41 MB は問題ない | 問題ない | 問題ない |
| 保つ期間 | 消すまで（古い順に消す仕組みが要る） | 1〜90 日（期限で自動で消える） | 消すまで（ディスクの上限で古い順に消す） |
| 費用 | 資産は容量の計算に入らない。ゲームの repo（private）でも無料 | private の repo では Actions の容量の枠を使う。41 MB × 1 日 39 回で、すぐ枠に当たる | 電気代だけ。Mac mini のディスク（空き 500 GB 超） |
| 認証 | gh のトークン（ゲームの repo を読める人だけ）。Studio の利用者が gh に入っている前提 | gh のトークン。API で zip 包みを解く手間がある | Tailscale の ACL。tailnet の外からは見えない |
| 落とす速さ | インターネット越しで 41 MB（数秒〜十数秒） | 同じ | 家の中なら 1 秒前後・外からは回線次第 |
| Mac mini が止まっている時 | 前に上げた物は取れる | 同じ | 取れない（手元で作るに戻る） |
| 置き方 | 1 つの「中の版」（例 `headless-jar-cache`・prerelease）に資産を `<鍵>.jar` で足していく。資産は 1 つの Release に 1000 本まで | ワークフローごとに上げる | 小さな HTTP の口（`bin/fge jar serve`） |

**勧め**: 段 1 は必ず入れる。段 2 は GitHub Release の資産にする。

- 費用がかからず、Mac mini が止まっていても取れるので。
- 認証は gh の今の仕組みに乗れるので（engine の道具はもう gh を使っている）。
- 古い物は「最後に使われてから 14 日・全部で 2 GB」を超えた順に消す（作り手が上げるたびに掃除する）。
- Tailscale の HTTP は、家の外の Studio に届かない日があるので、勧めない。

## 2. 流れ

### 2.1 鍵

鍵は次の字の SHA-256（16 進 64 字）にする。

```
fge-headless-jar/1
manifest=<jar.manifest の 64 字>
dispatcher=<FgeHeadlessMain.flix の中身の SHA-256>   入口の束（src から拾った入口の一覧で決まる）
flix=<jar を作った flix.jar の SHA-256>              コンパイラ（engine の bin/flix が指す物。lib には入っていない）
headless-run=<bin/headless-run の Revision>          作り方の決まり（入口の拾い方・dispatcher の書き方）を変えたら 1 上げる
classfile=65                                         jar が求める java の版（Java 21）
```

- `manifest` は jarfix の指紋そのもの。ゲームの中身（src・flix.toml・使う版の lib）はここに入る。
- 指紋に入らないのに jar の中身を変える物を、残りの行で足している（3 節）。
- OS・CPU は鍵に入れない。jar は JVM の bytecode で、native は 3 つの OS と 2 つの CPU の分が全部入っている（0 節）。
  ただし、jar を使う側の java が `classfile` より古ければ使わない（2.3 節）。

### 2.2 headless-run（使う側）

```mermaid
flowchart TD
  a["headless-run Mod.fn"] --> m["指紋を作る（今と同じ）"]
  m --> s{"build/headless の jar.manifest と同じ？"}
  s -- 同じ --> run["今の jar で流す"]
  s -- 違う --> k["鍵を作る（2.1）"]
  k --> c1{"段 1 にある？（~/.cache/flix-headless-jar）"}
  c1 -- ある --> put["build/headless へ写す → 流す"]
  c1 -- 無い --> c2{"段 2 にある？（FGE_PREBUILT_JAR が off でなければ）"}
  c2 -- ある --> dl["落とす（30 秒で切る）→ SHA-256 を確かめる → 段 1 へ置く → 写す → 流す"]
  c2 -- 無い・取れない・違う --> build["今どおり手元で作る → 段 1 へ置く"]
```

- 写す物は 3 つ（`headless.jar`・`jar.manifest`・`proj/src/FgeHeadlessMain.flix`）。今の `is_stale` は、3 つがそろって指紋が同じなら作り直さない。
- 取ってきた時は、`[headless-run] 先に作った jar を使う（段 1 / 段 2・N 秒）` を 1 行出す。
- 取れない時の戻り方: 段 2 が無い・30 秒で落ちない・SHA-256 が違う・gh に入っていない時は、何も言わずに今どおり作る
  （`FGE_DEBUG=1` の時だけ訳を出す）。作れない時の止まり方（0.50 の「jar を作れない時は止める」）は今のまま。
- `FGE_PREBUILT_JAR=off` で段 2 を使わない。段 1 は止めない（同じ機械で作った物なので）。

### 2.3 落とした jar を使う前の確かめ

1. 落とした jar の SHA-256 が、置き場の `sha256` と同じ。
2. 使う側の java の版が `classfile`（65 = 21）以上。`java -version` を毎回は呼ばず、`headless-run` がもう決めている `java_cmd` の版を 1 回だけ見る。
3. jar の中の `FgeHeadlessMain` が、手元の src から拾った入口の一覧と同じ入口を持つ。これは鍵の `dispatcher` で決まっているが、
   写した `FgeHeadlessMain.flix` と手元の `build_dispatcher` の出力を字で比べて、もう一度確かめる。
4. どれかが違えば、段 1 からも消して、手元で作る。

### 2.4 Studio

Studio は今も `bin/headless-run E2e.serveHeadless` で窓なしのゲームを起こしていて、jar は `headless-run` が決める。
そのため、Studio に要る直しは 2 つだけ。

- `[headless-run] 先に作った jar を使う` の行を、起動の段の表示（`server/src/Headless.flix` の `BootStage`）に足す。今は「jar を作っています（65 秒）」と出る所が、「先に作った jar を使っています」になる。
- Studio がエンジンを入れ替えた直後（版を上げた直後）に、`bin/fge jar fetch` を裏で 1 回流しておく（2.5 節）。最初の 1 枚撮りまでに落としておく。

### 2.5 道具の口

| 口 | 中身 |
|---|---|
| `bin/fge jar key [dir]` | 鍵を出す（2.1） |
| `bin/fge jar fetch [dir]` | 鍵の jar を段 1・段 2 から引いて `build/headless` へ写す。無ければ 1 を返す（作らない） |
| `bin/fge jar publish [dir]` | `build/headless` の jar を段 1 と段 2 へ置く（作り手が使う） |
| `bin/fge jar prune` | 段 1・段 2 の古い物を消す（最後に使われてから 14 日・全部で 2 GB を超えた順） |
| `bin/headless-run --build-only` | 入口を流さずに jar だけ作る（作り手が使う） |

## 3. 指紋が同じでも中身が合わない危険と、その止め方

| 危険 | 止め方 |
|---|---|
| コンパイラ（flix）の版が違う。jar の bytecode が変わる。lib にもゲームの src にも出ない | 鍵の `flix=`（engine の `bin/flix` が使う flix.jar の SHA-256） |
| `headless-run` の入口の拾い方・dispatcher の書き方が違う | 鍵の `dispatcher=` と `headless-run=`。2.3 の 3 でもう一度比べる |
| 使う側の java が古い（class の版 65 を読めない） | 鍵の `classfile=` を、使う側で比べる（2.3 の 2）。合わなければ、java を替えるか手元で作るかを知らせて止める（今の手元の作り方でも同じ java で動かないので） |
| OS が違う | jar は bytecode だけで、native は全部の OS の分が入っている。鍵に入れない。<br>新しい依存が 1 つの OS の native だけを入れるようになった時に備えて、作り手は jar の中の native の OS の並びを `jar.manifest` の隣に書き、使う側で自分の OS があるかを見る |
| 途中まで落ちた・壊れた jar | `.tmp` に落としてから SHA-256 を確かめ、合った時だけ mv する |
| 他人が置いた jar（中身は手元で走るコード） | 段 2 は、ゲームの repo を読める gh のトークンでしか取れない（Release の資産）。<br>作り手だけが上げる（上げるトークンは Mac mini の作り手だけが持つ）。署名は付けない（勧め。7 節で決めてもらう） |
| 指紋の決まりが変わる（jarfix の後にまた直す） | 鍵の頭の `fge-headless-jar/1` を上げる。古い鍵の jar は、誰からも引かれなくなって消える |

## 4. 作り手（Mac mini）

- **引き金**: ゲームの repo の self-hosted runner（Mac mini・label `mac-mini`）で、master への push の時に流す。
  - 使える時間の枠は使わない（self-hosted は無料）。
  - 同じ鍵がもう段 2 にあれば、何もせずに終わる。直近 60 回の push のうち 21 回は src・flix.toml・packages.lock が変わらないので、そこで止まる。
  - 続けて push が来たら、前の流しは取り消して最後の物だけ作る（Actions の `concurrency: cancel-in-progress`）。
- **重い物の鍵**: 作るのは `bin/fge heavy --short`（65 秒）で包む。この機械のエージェントの測りや reference-check と取り合わないように。
- **作り場**: 作り手専用の作業場（`~/.flix_ge_studio/prebuilt/<repo>`）を 1 つ持ち、`git fetch && git checkout --detach <sha>` して作る。エージェントの作業場には触らない。
- **1 日の費用**: 鍵が変わる push が 1 日 30〜40 回、1 回 65 秒（重なりを取り消せば実際はもっと少ない）で、Mac mini の CPU を 1 日 30〜45 分使う。

## 5. 効く場面と効かない場面（見込み）

| 場面 | 今 | 後 | 理由 |
|---|---|---|---|
| master を pull した直後の 1 枚撮り・render（Studio・端末） | 65 秒作ってから | 段 2 から 1〜15 秒 | 鍵が master の push と同じ |
| Studio がエンジンを入れ替えた直後（版を上げた直後） | 65 秒＋lib へ依存を落とす分 | 段 2 から（作り手が adopt の push で作っていれば） | 版を上げる push も master に来るので |
| この Mac mini で、新しく作業場を作った直後（`git worktree add`） | 65 秒 | 段 1 から 1 秒未満 | 同じ機械の誰かが同じ鍵を作っていれば |
| 同じ機械の別の作業場で、同じ src のまま render | 65 秒 | 段 1 から | 今は作業場ごとに作り直している |
| src を直した後 | 65 秒 | 65 秒（変わらない） | 指紋が変わるので、どこにも無い。手元で作るしかない |
| use-engine で作業中のエンジンへ向けた後 | 65 秒 | 65 秒 | lib の fpkg が手元の物で、誰も作っていない |
| 雛形（templates/*）・engine の中の bench | 65 秒 | 段 1 なら効く・段 2 は入れない | 作り手はゲームの master だけを見る |

エージェントの作業は src を直す事が多いので、段 2 が効くのは主に Studio（人）の側。この Mac mini のエージェントには段 1 が効く。
この機械では同じ作業場を何度も作り直しているので、新しい作業場を作るたびの 65 秒が消える。

## 6. 入れる順と完了条件

| 段 | 中身 | 完了条件（数は同じ機械で 5 回の中央値） |
|---|---|---|
| A | jarfix（別の担当）が入った後に、鍵（`bin/fge jar key`）と段 1（`headless-run` が作った後に置く・作る前に引く） | 新しい作業場を作った直後の `make render SHOT=title` が、jar の組み立てなし（ログに「先に作った jar を使う（段 1）」）。前は約 70 秒、後は 5 秒以下。鍵を変える変更（flix.jar・dispatcher）で段 1 を使わないことを、テストで確かめる |
| B | 段 2（Release の資産）と `fetch` / `publish` / `prune`・作り手の self-hosted runner | master に push してから、作り手が上げ終わるまでが 3 分以内。別の Mac の Studio で、pull した直後の会話の 1 枚撮りが jar の組み立てなし。gh に入っていない時と、30 秒で落ちない時に、手元で作るに戻る |
| C | Studio の起動の段の表示・エンジンを入れ替えた直後の `fetch` | Studio でエンジンを入れ替えた直後の最初の 1 枚撮りが、組み立てなし（作り手が作り終えていれば） |

各段で `agents-pack/AGENTS.core.md` の早見表に 1 行、`agents-pack/agent-eval/engine.json` にお題を 1 本足す（AGENTS.md の決まり）。

## 7. 依頼主に決めてほしい事

1. **段 2 の置き場**: GitHub Release の資産（勧め）・Actions の artifact・Mac mini の HTTP（Tailscale）のどれにするか。
2. **作り手の引き金**: ゲームの repo に self-hosted runner を置く（勧め）か、Mac mini の launchd で 5 分ごとに `git fetch` して見に行くか。runner を置くと、ゲームの repo の設定を触る。
3. **段 1 を先に入れるか**: 段 1 だけで、この機械のエージェントの「新しい作業場で 65 秒」が消える。段 2 より先に入れてよいか（勧め: 先に入れる）。
4. **署名**: 段 2 の jar に署名を付けるか。勧めは付けない。gh のトークンで守り、上げられるのは作り手だけにする。付けるなら minisign の鍵を作り手に持たせる。
5. **残す量**: 段 1・段 2 とも「最後に使われてから 14 日・全部で 2 GB」でよいか。
6. **対象のゲーム**: まず internet_dungeon だけにするか。新しいゲームは、作り手の作業場を足すだけで増やせる形にする。
