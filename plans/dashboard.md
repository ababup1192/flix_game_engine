# ダッシュボード（engine 起点・ブラウザ）

状態: 設計 第 6 版（相談中）。実装は未着手。**始め方（plans/onboarding.md）の後に作る。**
レビュー: 第 1 版 64 点・第 2 版 78 点・第 3 版 84 点・12〜15 節を足した版 68 点・第 4 版 82 点・第 5 版 85 点。指摘への答えは 11 節。

## 0. 決まっていること（作者の判断）

- **Studio（flix_ge_studio）は凍結する。** 非エンジニアにゲームを作らせる道具は、要るようになったら再開する。
- **engine 起点のダッシュボードへ移す。** 最初の相手は Flix を書くエンジニア。
- **最初の用途は、AI（Claude・Codex など）が人へ見せる物の置き場。** スクショの案を載せる・Tape を
  撮り直して載せる・内容を差し替えやすい置き場を整える。

## 1. 解きたい課題

| 課題 | 今 | 根拠 |
|---|---|---|
| 隠れた機能 | Tape・リモートデバッグ HTTP・F8 の囲みと巻き戻し・flow の自動記録・ヒッチの記録は、AI 向けの早見表（agents-pack/AGENTS.core.md）にしか載っていない | 調査（2026-11-23） |
| AI が作った物の見せ場が散らばる | proposal は `reports/<名前>/index.html`、Tape は `debug/tape/<名前>/index.html`、比較は `debug/compare/index.html`、チケットは `debug/annotations/`。人は AI に「どこにある？」と聞くしかない | go/internal/proposal・mk/tape.mk・docs/modules/debug.md |
| 人 → AI の返事が会話のコピペに頼る | proposal の頁の JS は「決定をコピー」だけで、自由文の欄も無い | go/internal/proposal/proposal.go:611-614 |
| Studio の追従 | server が engine を 0.37 で固定（本体は 0.108）。engine の決まりの写しが 30 を超える | flix_ge_studio/server/flix.toml・docs/backlog.md |

## 2. 方針

1. **Go で書き、各ゲームの `bin/fge dashboard` として配る。** ゲームの `bin/fge` は engine の `fge-go` の写しを呼ぶだけなので、
   ゲームの engine の版とダッシュボードの版が自動でそろう（`make engine-upgrade` で一緒に上がる）。
   全体の fge（plans/onboarding.md・`~/.flix_ge/bin/fge`）はゲームの頁を描かない。13 節のワークスペースでも、各ゲームの頁は
   そのゲームの `bin/fge dashboard` が描き、全体の fge は中継するだけ。
   - WhyNot Flix で書かない: 起動に JVM と型検査の待ちが要る。HTML の頁を作る道具（tape・proposal・compare）は既に Go にある。
2. **今ある出力を読むだけにする（写さない）。** 新しく足す置き場は posts（3 節）の 1 つだけ。
3. **AI は CLI で書き、人はブラウザで読んで返す。** AI ごとの専用のエンドポイントは作らない（Claude も Codex もシェルが打てれば同じ）。
4. **状態はファイルがあるかどうかだけで決める。** 状態の欄を JSON に持たない（並んで動く AI どうしで食い違わない）。
5. **既存の Go を使う。** games.json は `go/internal/talk` の読み手、頁は `go/internal/proposal` の HTML、Tape は `go/internal/tape` の tape.json と published.jsonl。

## 3. 置き場: posts

### 3.1 場所（worktree をまたぐ）

```
<main の作業ツリー>/debug/dashboard/
  posts/<id>/
    post.json              AI が書く（3.2）
    *.png *.mp4 …          post.json が指す素材（CLI が写す）
    reply.json             人の最新の返事（3.3）
    replies/<at>.json      出し直す前の返事（上書きで消さない。at は 20261123T120000 の形。`:` は Windows のファイル名に使えない）
    resolved               空のファイル。あれば片付いた post
```

- **置き場の根** = main の作業ツリー + ゲームの根の prefix。
  - main の作業ツリー: `git worktree list --porcelain` の先頭。bare のリポと submodule では今のゲームの根に戻す。
    bin/strays.sh の根の決め方（common-dir の名前が `.git` の時だけ使う）と同じ結果になる関数（Go）にする。共有するのはここまで。
  - ゲームの根の prefix: 今のフォルダから上へたどって最初に flix.toml のあるフォルダを、そのリポの根からの相対パスにした物
    （engine のリポの `templates/x` では `templates/x`、ふつうのゲームでは空）。WhyNot `git rev-parse --show-prefix`: 今いるフォルダの値なので、
    ゲームの `src/` で打つと置き場がずれる。WhyNot strays と prefix まで共有する: engine の根で strays を流すと根が `templates/x` に縮む。worktree の中で `bin/fge dashboard post` を打っても、main 側の posts へ書く。WhyNot worktree ごとに持つ: AGENTS.md は worktree での作業を既定にしていて、
  人が開くダッシュボードは 1 つ。worktree ごとだと、人は今どの worktree の物を見ているか分からない。
- post.json には CLI が `origin`（`{branch, worktree}`）を書き足す。頁はこれを見出しの横に出す。
- **Tape は worktree をまたいで読む。** テープは撮った worktree の `debug/tape` にできるので、Tape タブは `git worktree list` の
  全部の作業ツリーの `debug/tape` を読み、どの枝で撮ったかを出す（写さない）。
- git の外（`debug/` の下）。生成した絵は git に入れない決まりに合う。git でないフォルダでは今のフォルダの `debug/` を使う。

### 3.2 post.json

**proposal.json（go/internal/proposal）の形に `author` だけを足す。** 「スクショの案」は proposal の「選べる節」そのもの。

```jsonc
{
  "version": 1,
  "author": "claude",              // 書いた AI の名前（自由な文字列）
  "title": "…", "lead": "…",
  "sections": [ … proposal と同じ … ],
  "ask": ["…"]
}
```

- 種類の欄は持たない。options を持つ節があれば「選ぶ post」、無ければ「見る post」。
- 素材を写す決まり: media のパスは post.json の置き場からの相対か、リポの根の下の絶対パス。リポの根の外と
  存在しない素材は止める。写した先の名前は元の名前、ぶつかったら `-2` `-3` を付け、post.json の写しのパスを書き換える。
- id は `YYYYMMDD-HHMMSS-<題から作る短い名前>`。フォルダは `os.Mkdir` で作り、既にあれば `-2` を付けて作り直す（同じ秒の 2 つの post がぶつからない）。

### 3.3 reply.json

```jsonc
{ "version": 1, "at": "2026-11-23T12:00:00+09:00",
  "picks": {"A": "A1"},            // proposal の decision.picks と同じ形
  "comment": "B はもう少し暗く" }
```

- サーバーは tmp に書いてから rename で差し替える。返事を出し直したら、前の reply.json を `replies/<at>.json` へ移してから書く。
- 絵の上を囲むメモ（座標つきの注釈）はフェーズ 4（9 節）。

## 4. CLI（AI と人が打つ）

| コマンド | すること |
|---|---|
| `fge dashboard`（どこで打っても同じ） | **前面で**ワークスペースのサーバーを 1 つ立てる（人が別の端末で打つ・Ctrl-C で止める）。既に 8790 で立っていれば立てず、ブラウザだけ開く。ゲームのフォルダで打った時は、そのゲームを一覧に足して `/<ゲーム名>/` を開く（2026-11-23 の作者の判断） |
| `bin/fge dashboard post <post.json>` | 素材ごと posts へ写し、id と URL（`…/#post-<id>`）を出す。サーバーは要らない（ファイルを書くだけ） |
| `bin/fge dashboard inbox [--json] [--all]` | reply.json があり resolved が無い post を、返事の中身ごと出す。既定は origin の worktree が今の物に合う post だけ（並んで動く AI が他の担当の返事を拾わない）。`--all` で全部。何も書き換えない |
| `bin/fge dashboard resolve <id>` | resolved を置く。WhyNot `close`: `bin/fge tickets close` と同じ語で別の物を指すことになる |

- **AI が打つ post・inbox・resolve はファイルを読み書きするだけで、サーバーを要らない。** サーバーは人がブラウザで見る時だけ。
  WhyNot 裏で立てる: 裏で立てると、pid とポートの書き置き・立っているかの問い合わせ・engine を上げた後の立て直し・
  取り残しの片付け（strays.sh の改修）が全部要る。前面なら端末を閉じれば終わる。
- 出力は os.Stdout へ直に書く（`main.go` の Handler は文字列を溜めてから出す作りで、居座るサーバーには合わない。proposal と同じ扱い）。
- `make dashboard`（`bin/fge dashboard` を呼ぶだけ）を game.mk に足し、`make help` の先頭のグループに載せる。
- `make status` に 1 行: 「ダッシュボードに返事 N 件 → bin/fge dashboard inbox」（N が 0 なら出さない）。
- engine の `templates/*` には `bin/fge` が無い。テンプレートでは `../../bin/fge dashboard`（AGENTS.md の refactor の節と同じ）。

## 5. 画面（1 枚の頁・タブ）

| タブ | フェーズ | 中身 | 読む物 |
|---|---|---|---|
| Inbox | 1 | AI からの post（新しい順・未返事 / 返事済み / 片付いた で絞る）。選ぶ post は選択と自由文を送る | posts |
| Tape | 1 | 撮ったテープの一覧（題・撮った日・公開 URL）。開くと既存の index.html | debug/tape/*/tape.json・published.jsonl |
| Games | 2 | 起動中のゲーム。押した時だけ今の画面を撮る（`GET /state?view=shot`）・止める / 進める / 場面から始める | games.json・RemoteDebug |
| Images | 2 | gallery と debug の PNG、compare の頁 | gallery・debug |
| Tickets | 2 | F8 で囲んだ物とヒッチ（README の頭） | debug/annotations・debug/perf/hitches |
| Capabilities | 2 | 何ができるか。ゲームの AGENTS.md の早見表の表を読んで出す。コマンドのコピーと「AI に頼む文」のコピー | AGENTS.md |

- proposal の頁: `proposal.go` の Build から書き出しを外した `Page(m, root, opts)` を出し、builder（今は `{root, missing}`）に
  `send bool` と `picks map` を足す。send の時は (1) 頁の下のバー（今は選べる節がある時だけ出る・proposal.go:588-614）を常に出し、自由文の欄と
  「送る」を置く、(2) 今の reply.json の picks を入れて、選んだ状態で開く。WhyNot picks を decision へ入れて出す: decision は「採用」の
  表示と「消すつまみ」を出す別の意味の欄。静的な index.html（`fge proposal build`）は今のまま「コピー」だけ。
- 一覧の更新は 3 秒ごとの `GET /_api/index`（posts と tape の更新時刻だけを返す。変わった時だけ取り直す）。
  WhyNot websocket: 1 人が手元で見る頁で、問い合わせで足りる。標準ライブラリだけで済む。
- **ゲームへは問い合わせない。** `view=shot` は主のスレッドで場面を組んで塗り、最大 60 秒待つ（RemoteDebug.flix:616-624）。
  定期的に叩くとゲームが詰まるので、ボタンを押した時だけ。返るのは PNG のパスなので、ダッシュボードはそのゲームの dir の下のパスだけを出す。
  `onShotRequest` を繋いでいないゲームには「このゲームは撮れない（App.onShotRequest を繋ぐ）」と出し、止める / 進めるだけ出す。
- 頁は `go:embed` で fge-go に入れる（tape の template.html と同じ）。外の CDN を読まない。

## 6. 安全

- `127.0.0.1` だけで待つ。
- 全部の要求で `Host` が `127.0.0.1:<port>` か `localhost:<port>` であることを見る（DNS rebinding で GET を読まれるのを防ぐ）。
- POST は `Origin` が自分の時だけ受ける（POST はブラウザの頁からしか来ない。CLI はファイルを書くのでサーバーへ POST しない）。
- ファイルを出すのは決まった置き場の下だけ。`..` と、symlink を辿った先が置き場の外になる物を断る。
- API のパスはどれも `/_api/` で始める（13 節でゲーム名の `/<名前>/` とぶつからない）。

## 7. Studio の凍結で engine 側が直す所

| 所 | 直し方 |
|---|---|
| gates.json の `studio-parity`（release の門・今は hold）・テンプレート 7 つの gates の `studio-parity`・Makefile の `RELEASE_GATES`（:1082） | 3 か所とも外し、凍結中と note に書く。**sync-agents の出力を変える前に外す**（外す前にリリースすると Studio との食い違いで止まる・Makefile:1079-1080） |
| /add-template の手順 6・7（Studio への登録・swap-jar） | 「Studio は凍結中。飛ばす」と書く |
| `make new-game` の最後の案内の「Studio で開く」 | 消す（plans/onboarding.md の 2.4 の 6）。ダッシュボードができたら `make dashboard` を足す |
| README 冒頭の Studio の紹介 | 始め方（install.sh）に替え、Studio は凍結中と 1 行 |
| `reference/title.png` を git に入れる例外 | **替えない**。凍結を解いた時に要る。1 ファイルずつで重くない |
| スキーマの sections の書き方を Studio に合わせる決まり（doc-conventions.md） | **替えない**。Doc の書き方として既に定着している |
| `~/.flix_ge_studio/games.json` の場所 | **替えない**。今の Studio の .app と bin/fge talk goto とダッシュボードが同じ所を読む |
| agents-pack/manifest.json のキー名を替えない約束・今の `SHA256SUMS.txt` の形 | そのまま（今の Studio の .app の self-update が読む） |

## 8. AI 側の配線（AGENTS.md の決まり）

- agents-pack/AGENTS.core.md の早見表に 2 行: 「人に絵・動画・案を見せて選んでもらう → `bin/fge dashboard post`」「人の返事を拾う → `bin/fge dashboard inbox`」。
  proposal の行は「静的な頁を作って渡すとき」に絞る。
- agents-pack/agent-eval/engine.json にお題を 1 本（「描き出した 3 枚を人に見せて選んでもらって」で `dashboard post` を選ぶか）。

## 9. フェーズ

| フェーズ | 中身 | 終わりの基準 |
|---|---|---|
| 0 | 始め方（plans/onboarding.md）。**ワークスペースの頁（`/`）のうち、ゲームの一覧と「新しいゲームを作ってみよう」のカードだけ**を含む | 空の HOME で install.sh → `fge dashboard` → カードから開いた Claude がゲームを作る → `make run` が macOS と Linux で通る |
| 1 | ゲームの頁と、ワークスペースのサーバーからの中継（13 節。フェーズ 3 から移した）・post / inbox / resolve・Inbox と Tape のタブ・proposal の頁の「送る」・固定の「はじめに」カード 1 枚（15 節）・`make dashboard`・status の 1 行・早見表 2 行 + お題 1 本・Studio の凍結の直し（7 節） | game-starter から産んだゲームの worktree で AI が post → 人が main のダッシュボードで選んで返す → AI が inbox で拾う、が会話のコピペ無しで通る |
| 2 | **版上げのお知らせのカードと、clone 無しの `make engine-upgrade`（14 節）**・Capabilities（早見表を読む）・Games・Images・Tickets のタブ・post を Pages へ載せる（10 節の 3） | Inbox のカードから Claude を開くだけで、版上げ → 直す → post → 人が取り込む、が通る |
| 3 | 状態から選ぶカード（15.2）・Desktop のボタン | 1 つの URL から全部のゲームへ行ける |
| 4 | 絵の上を囲むメモ・Tape の注釈を reply へ・頁から make のターゲットを流す（要るか未定） | フェーズ 3 の後に決める |

## 10. 決めたこと・決めていないこと

1. **ポートは 8790 に固定（決定 2026-11-23）。** 塞がっている時だけ空いた番号を使い、URL を出す。
2. engine のリポの根で立てるか: **立てない。** ワークスペース（13 節）で engine のリポを `fge add` すれば済む。
3. **post を GitHub Pages へ載せる道を足す（決定 2026-11-23）。** `bin/fge dashboard publish <id>` が post の頁（proposal の静的な index.html と素材）を
   tape publish と同じ置き場・同じ作り（go/internal/tape/publish.go の dry run 既定・`--yes`・`--wait`・95 MB を超える動画を縮める）で置く。
   公開した頁は「コピー」だけの静的な頁（返事は Pages から手元へ届かない）。フェーズ 2。
4. **最初は小さく（決定 2026-11-23）。** 始め方を先に作り、ダッシュボードのフェーズ 1 は 9 節の範囲に絞る。

## 11. レビューへの答え

| 指摘 | 答え |
|---|---|
| worktree の post が見えない | 3.1 で main の作業ツリーの 1 か所に置く |
| 今の画面は `/render` で取れない・問い合わせでゲームが詰まる | 5 節で `view=shot` を押した時だけ。撮れないゲームの表示も決めた |
| proposal の頁に返す方法が無い | 5 節で proposal.go に切り替え（send）を足す |
| 素材のパス・id の衝突 | 3.2 |
| DNS rebinding | 6 節で Host を見る |
| reference-check の結果が保存されていない | Images タブはフェーズ 2 へ移し、差は出さず PNG と compare だけにした |
| status・kind・seen は要らない | 消した（2 節の 4・3.2） |
| inbox にチケットとヒッチを混ぜない | 混ぜない（make status に既に出る） |
| features.json は要らない | 消した。Capabilities は AGENTS.md の早見表を読む |
| games.json の読み手が既にある | go/internal/talk を使う |
| `close` が tickets とぶつかる | `resolve` にした |
| bare・submodule・templates/x で置き場の根を誤る | 3.1 で worktree list の先頭 + flix.toml のあるフォルダの prefix |
| Tape だけ worktree をまたがない・inbox が他の worktree の返事を拾う | 3.1・4 節 |
| reply のファイル名の `:`・proposal の bar と今の picks | 3.1・5 節 |
| 裏で立てる作り・strays・pid の kill・engine を上げた後の古いサーバー・stop が Origin で弾かれる | **前面で立てる形にして、まとめて要らなくした**（4 節） |
| （12〜15 節）全体の fge がダッシュボードを持つと 2 節 1 の「版が自動でそろう」が崩れる | 2 節 1・13 節で、各ゲームの頁はそのゲームの `bin/fge dashboard` が描き、全体の fge は中継だけにした |
| server.json の置き場が 2 つ・`make dashboard` と全体のサーバーがぶつかる | server.json を無くした（4 節）。ワークスペースはフェーズ 3 で、全体の fge は 8790、子のゲームは空いた番号（13 節） |
| API のパスが `/api` と `/_api` でそろっていない | `/_api` にそろえた（6 節） |
| templates/* に bin/fge が無い | 4 節で `../../bin/fge`・13 節も同じ |
| `fge upgrade` が local.mk を書き換えない・版ズレの検知・赤の間の道具が古い | 14 節に足した |
| （第 4 版）6 節が 2 つ | 古い方を消した |
| （第 4 版）local.mk は git の外で、枝を替えると ENGINE が戻らない | 14 節で ENGINE を flix.toml の版から決める形に |
| （第 4 版）中継の Host・Origin・版をまたぐフラグ | 13 節 |
| （第 4 版）engine の根で立てないのはフェーズ 1・2 の間 | 10 節の 2 |
| （第 5 版）版上げで post が 2 つ届く | 14.0 で Claude の 1 つだけ |
| （第 5 版）お知らせのカードのフェーズ・zip を毎回取るか | 14.0（フェーズ 2・zip は取らない） |
| （第 5 版）clone して使う人の make engine-upgrade が変わる | 14.0 で ENGINE の下に go/ があるかで分ける |
| JDK を取ると絵が崩れる・Windows の new-game | plans/onboarding.md の 2.4（版を固定し local.mk の JAVA で渡す）・Windows は対象外 |
| 14 と 15.1 でプロセスを起こす方針が食い違う | 15.1 に 1 つにまとめた |
| RELEASE_GATES の漏れ | 7 節 |
| フェーズ 1 が膨らんだ | 9 節で絞った |
| 始め方を先に | 9 節のフェーズ 0・10 節の 4 |

## 12. 始め方

plans/onboarding.md へ移した。

## 13. ワークスペース（`/` の頁はフェーズ 0・ゲームの頁への中継はフェーズ 1・2026-11-23 の作者の提案から）

**ダッシュボードのサーバーは 1 台に 1 つ。** `fge dashboard` はどこで打ってもワークスペースのサーバー（8790）を使う。ゲームの頁を別のサーバーとして人に立てさせない（2026-11-23 の作者の判断）。

`/` の頁（ゲームの一覧・新しいゲームを作るカード）は plans/onboarding.md 2.6 で先に作る。ここは中継の決まり。

全体の fge（`~/.flix_ge/bin/fge dashboard`）を 1 台に 1 つ前面で立て、`/` をワークスペース、`/<ゲーム名>/` を各ゲームにする。

```
http://127.0.0.1:8790/            ワークスペース: ゲームの一覧・テンプレートから作る・engine の版と更新
http://127.0.0.1:8790/mygame/     ゲーム: そのゲームの bin/fge dashboard が描く頁を中継する
http://127.0.0.1:8790/_api/…      ワークスペースの API
```

- **各ゲームの頁は中継する。** `/<ゲーム名>/` を初めて開いた時、全体の fge がそのゲームの `bin/fge dashboard --port 0 --no-open --base /<ゲーム名>/` を
  子のプロセスとして起こし、そのポートへ中継する（Go の httputil.ReverseProxy）。全体の fge を Ctrl-C で止めると子も止まる。
  WhyNot 全体の fge が頁を描く: ゲームごとに engine の版が違う。版の違うゲームの post や tape を新しい道具 1 本で読むと、Studio の追従の失敗が戻る。
- ダッシュボードより前の版のゲーム（`bin/fge dashboard` を持たない）は一覧に「版を上げると開ける」と出し、中継しない。
  見分けは子の `bin/fge dashboard --version`（ダッシュボードの約束の版を 1 行で出す）。`--port`・`--no-open`・`--base` はフェーズ 3 で
  4 節に足す。全体の fge と子の間の約束は、この 4 つのフラグと `--version` だけに保つ（版をまたぐ約束を増やさない）。
- **中継の Host と Origin。** 子は 6 節のとおり Host と Origin を自分のポートで見るので、ReverseProxy の既定のままだと 8790 から来た要求を断る。
  全体の fge は Director で Host を子の `127.0.0.1:<子のポート>` に書き換え、子は `--base` を受けた時だけ Origin に `http://127.0.0.1:8790` も許す
  （全体の fge が自分の Host と Origin を 6 節と同じ決まりで先に見る）。
- **ゲームの一覧はフォルダの親子ではなく一覧のファイルで持つ。** `~/.flix_ge/workspace.json` に `{name, dir}` を並べる。
  `fge new` は作ったゲームを一覧に足す。既にあるゲームは `fge add <dir>` で足す。
  WhyNot 1 つの親フォルダの下に置かせる: 既にある git のリポを動かさせることになる。
- engine のリポを `fge add` すると、`templates/*` が子として並ぶ。templates には `bin/fge` が無いので、engine の `bin/fge` を使って中継する。
- テンプレートから作る画面は、カードから Claude を開いて `fge new` を打ってもらうだけ（plans/onboarding.md 2.6）（Studio の Genesis のような写しを持たない。テンプレートの一覧は engine の zip の templates/ を読む）。

## 14. engine の版上げ（フェーズ 2）

### 14.0 人から見た流れ（2026-11-23 の作者の判断）

**人は版上げのコマンドを打たない。** Inbox に「新しい版があります」のカードが出て、ボタンで Claude を開くと、下書きの指示で
Claude がコマンドを打ち、版の注意書き（docs/migrations）をもとに直し、結果を post で返す。人は post を見て返事をするだけ。

```
Inbox の先頭  ┌ engine 0.109.0 が出ています（いまは 0.108.0）
              │ 変わる所: Release の説明の頭（何件の非互換が当たるかは、上げてみるまで出さない）
              └ [Claude Code で開く] [コピー]
                    ↓ 下書き: 「engine を最新版に上げて。make engine-upgrade を流し、UPDATE_PLAN.md と docs/migrations の注意に沿って直し、
                    ↓          check と test を緑にして、変わった絵と直した所を dashboard post で見せて」
Claude        make engine-upgrade → （赤なら）UPDATE_PLAN.md を読んで直す → check・test → render-all → dashboard post
                    ↓
Inbox         「engine 0.109.0 に上げました」の post（直した所・リファレンスとの画素の差・上げた枝）→ 人が「取り込む / 直して」を返す
                    ↓
Claude        inbox で返事を拾う → 取り込む（人の返事が「取り込む」の時だけ）か、直してもう一度 post
```

- **お知らせのカードはファイルの post ではなく、ダッシュボードがその場で作る。** 状態（新しい版があるか）から作る物で、AI の post と違い返事を持たない。
  上げ終わると消える。作者は `fge`（AI の名前の代わり）。
- **AI が打つのは今ある `make engine-upgrade`。** 早見表（AGENTS.core.md）が「status の engine 版ズレを見たらこれ」と既に配っている名前を変えない。
  ENGINE が配った engine（`~/.flix_ge/engines/` の下）の時だけ、中身を 14.1 の形（新しい版を取ってから上げる）に替える。
  ENGINE が clone した engine の時は今のまま（その clone の版へ上げる）。分け方は ENGINE の下に `go/` があるか（Makefile:53 の IS_BUNDLE と同じ見方）。
- **カードは Release の説明（GitHub の API で取れる body）だけを出し、engine の zip は取らない。** 当たる非互換の数は zip（約 100 MB）を
  取ってゲームと突き合わせないと出ないので、Claude が上げた後の post に出す。
- **post は Claude の 1 つだけ。** `make engine-upgrade` は post しない（UPDATE_PLAN.md を書き、端末に出すだけ）。
- このカードはフェーズ 2（状態から選ぶカードの中で、これだけ先に作る。ほかは 15.2 のとおりフェーズ 3）。
- `make status` にも同じ 1 行（「engine 0.109.0 が出ています → make engine-upgrade」）を出す。ダッシュボードを開かずに Claude を使っている時も気づける。
- カードの下書きは 15 節の deep link と同じ作り（送るのは人が Enter を押した時）。

### 14.1 コマンドの中身（AI が打つ）


今ある物: `upgrade-game`（版の書き換え・fpkg の差し替え・check・非互換があれば終了コード 3）、`update-plan`（そのゲームで当たる非互換だけの
指示書 UPDATE_PLAN.md）、`docs/migrations/<版>.md`（手書きの手当て）と `<版>.auto.md`（リリースで作る型の差と追随例）。
足りないのは「engine の clone 無しで上げるコマンド」と「AI に直させて人が確かめる往復」。

```
make engine-upgrade    # 中身は fge upgrade。作業ツリーがきれいか確かめる → 新しい版があるか見る → engine の zip を ~/.flix_ge/engines/<版>/ に取る
                       # → 枝 engine-upgrade/<版> を切る
                       # → その版の engine で upgrade-game → 非互換が無ければ check・test を流して終わり
                       # → 非互換があれば UPDATE_PLAN.md を書いて端末に出す（post は Claude が直した後に 1 つ・14.0）
```

- **赤の間も道具を新しい版にそろえる。** upgrade-game は check が緑になるまで sync-agents を走らせない（upgradegame.go:246-251）ので、
  AI は古い AGENTS.md・skills・bin/fge のまま新しい API を直すことになる。`fge upgrade` は終了コード 3 の時に sync-agents だけ流す
  （巻き戻しの範囲は upgrade-game の 4 ファイルのまま。sync-agents は枝ごと捨てれば戻る）。
- **版ズレの検知を移す。** 今の status の「engine 版ズレ」は ENGINE の Makefile の VERSION と比べている（go/internal/status/engine.go:81）。
  ENGINE が版ごとのフォルダを指す形では出なくなるので、`~/.flix_ge/engines/` の最新（無ければ Release の最新）と比べる形に替える。
  Release の問い合わせは 1 日 1 回まで（結果を `~/.flix_ge/latest.json` に置く。認証なしの GitHub API は 1 時間 60 回まで）。
- 版は 1 つずつ上げる（0.104 → 0.105 → …）。1 版ごとに指示書が短く、どの版で壊れたかが分かる。`--to <版>` で飛ばすこともできる。
- engine の版は `~/.flix_ge/engines/` に並べて置く（古い版のゲームも動いたまま）。
- **local.mk の ENGINE を書き換えない。flix.toml の版から決める。** local.mk は git の外なので、枝 `engine-upgrade/<版>` で書き換えると、
  main へ戻っても ENGINE は新しい版のまま（古い flix.toml と新しい game.mk が混ざる）。worktree には local.mk 自体が無い。
  `fge new` が書く local.mk は `ENGINE ?= $(HOME)/.flix_ge/engines/$(shell <flix.toml の flix_game_engine の版を読む 1 行>)/engine` にする。
  枝を替えても worktree でも、その時の flix.toml の版の engine を指す。上の「local.mk の ENGINE（と JAVA）を書き換える」はこれで要らなくなる
  （JAVA は engine の jdk.json から同じように決める）。clone した engine を使う人（`make new-game` で作った人）は今までどおり絶対パス。
- **AI を非対話で起こす `--fix` は作らない。** 14.0 のとおり、人がカードから対話の Claude を開く。料金・権限・時間切れを決める要が無く、人が途中を見られる。
  WhyNot fge が自分で直す: update-plan の WhyNot と同じ（読み違えた時に知らせずに壊す）。直すのは AI、fge は材料と確かめの場を渡す。
- engine 側の仕事: リリースのたびに `<版>.md`（手書きの手当て）を書く今の決まりを続ける。AI が直せなかった所は post に残るので、次の版の手当てに足す。

## 15. Claude を開くボタンと、最初の指示の誘導

各ゲームの頁の上にカードを置き、カードごとに Claude を開くボタンを置く。**フェーズ 1 は固定の「はじめに」カード 1 枚だけ**（状態から選ぶのはフェーズ 3）。

### 15.1 開き方（公式に書かれた方法だけを使う・2026-11-23 に code.claude.com で確認）

| ボタン | 中身 | 指示 | フェーズ |
|---|---|---|---|
| **Claude Code（端末）で開く**（既定） | ただのリンク `claude-cli://open?cwd=<ゲームの絶対パス>&q=<指示>`（docs: deep-links）。新しい端末でそのフォルダの `claude` が起動する | 入力欄に入る。送るのは人が Enter を押した時 | 1 |
| **コマンドをコピー** | `cd <dir> && claude -n <ゲーム名> "<指示>"`（Codex なら `codex "<指示>"`） | 打てばそのまま送られる | 1 |
| **Claude Desktop で開く** | サーバーが `claude --desktop` をゲームのフォルダで起動する（docs: desktop の「Coming from the CLI?」）。Desktop の Code タブをローカルのフォルダとプロンプトで開くリンクは公式に無い | 渡せないので、カードの「コピー」で貼ってもらう | 3 |

- **プロセスを起こす決まり:** サーバーがプロセスを起こすのは、人が頁のボタンを押した時だけ（フェーズ 3 の Desktop）。
  claude はいつも人の端末で対話で動かす（deep link）。ダッシュボードも fge も claude を非対話で起こさない。
- deep link は、その機械で 1 回でも対話で何か送った後でないと開けない（ハンドラの登録がその時）。頁は開けたかを知れないので、
  リンクの横にいつも「開かない時: 一度 `claude` を起動して何か送る」と 1 行出し、コピーも並べる。
- `q` は 5,000 字まで・`cwd` は絶対パスだけ。
- ゲームの CLAUDE.md は `@AGENTS.md` の 1 行なので、Claude は起動時に AGENTS.md・skills を読む。Codex は AGENTS.md を直に読む。追加の設定は要らない。
- WhyNot `claude "<指示>"` を既定にする: 指示がすぐ送られ、人が読んで直す間が無い。下書きで入る deep link を既定にする。
- WhyNot VS Code（`vscode://anthropic.claude-code/open?prompt=`）を並べる: フォルダを指定できず、開いている VS Code の別のフォルダで始まりうる。

### 15.2 「はじめに」カード（フェーズ 1）と、状態から選ぶカード（フェーズ 3）

- フェーズ 1 の固定カード: 「このゲームで何ができるか教えて。make status を見て、次にやることを 3 つ挙げて」と、自由に書ける入力欄。
- フェーズ 3 で、ゲームの状態から上へ 3 枚まで選ぶ。

| 出す時 | カード | 指示（下書き） |
|---|---|---|
| 作ったばかり（AGENTS.local.md の画風の節が仮置きのまま） | 画風を決める | 「このゲームの画風を決めたい。/style-interview で質問して」 |
| Inbox に返事がある | 返事を受けて直す | 「bin/fge dashboard inbox の返事を読んで直し、直した絵を dashboard post で見せて」 |
| F8 のチケットがある | チケットを直す | 「debug/annotations の新しいチケットを読んで直して」 |

- 指示の文は engine から配る `agents-pack/starters.json`（sync-agents がゲームへ写す）に置き、ゲームの engine の版にそろえる。
  カードの文はゲームの AGENTS.md の早見表にある名前だけを使い、消えた名前を使っていたら `make check-docs-sync` で止める。
