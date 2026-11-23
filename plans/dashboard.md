# ダッシュボード（engine 起点・ブラウザ）

状態: 設計 第 3 版（相談中）。実装は未着手。レビューは第 1 版 64 点・第 2 版 78 点。指摘への答えは 11 節。

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

1. **Go で書き、`bin/fge dashboard` として配る。** ゲームの `bin/fge` は engine の `fge-go` の写しを呼ぶだけなので、
   ゲームの engine の版とダッシュボードの版が自動でそろう（`make engine-upgrade` で一緒に上がる）。
   - WhyNot Flix で書かない: 起動に JVM と型検査の待ちが要る。HTML の頁を作る道具（tape・proposal・compare）は既に Go にある。
2. **今ある出力を読むだけにする（写さない）。** 新しく足す置き場は posts（3 節）の 1 つだけ。
3. **AI は CLI で書き、人はブラウザで読んで返す。** AI ごとの専用のエンドポイントは作らない（Claude も Codex もシェルが打てれば同じ）。
4. **状態はファイルがあるかどうかだけで決める。** 状態の欄を JSON に持たない（並んで動く AI どうしで食い違わない）。
5. **既存の Go を使う。** games.json は `go/internal/talk` の読み手、頁は `go/internal/proposal` の HTML、Tape は `go/internal/tape` の tape.json と published.jsonl。

## 3. 置き場: posts

### 3.1 場所（worktree をまたぐ）

```
<main の作業ツリー>/debug/dashboard/
  server.json              立っているサーバーの {pid, port, root, version}（4 節）
  posts/<id>/
    post.json              AI が書く（3.2）
    *.png *.mp4 …          post.json が指す素材（CLI が写す）
    reply.json             人の最新の返事（3.3）
    replies/<at>.json      出し直す前の返事（上書きで消さない。at は 20261123T120000 の形。`:` は Windows のファイル名に使えない）
    resolved               空のファイル。あれば片付いた post
```

- **置き場の根** = `git worktree list --porcelain` の先頭の作業ツリー + `git rev-parse --show-prefix`
  （engine のリポの `templates/x` のように、リポの下のフォルダがゲームの時にテンプレートどうしで混ざらない）。
  bare のリポと submodule では、今のフォルダの `debug/` に戻す。bin/strays.sh の根の決め方（common-dir の名前が `.git` の時だけ使う）と
  同じ関数（Go）にそろえ、strays.sh もそれを呼ぶ。worktree の中で `bin/fge dashboard post` を打っても、main 側の posts へ書く。WhyNot worktree ごとに持つ: AGENTS.md は worktree での作業を既定にしていて、
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
- 絵の上を囲むメモ（座標つきの注釈）はフェーズ 3（9 節）。

## 4. CLI（AI が打つ）

| コマンド | すること |
|---|---|
| `bin/fge dashboard start` | 裏で立て、URL を 1 行出してすぐ返る（4.1）。既に立っていて `GET /api/whoami` の root と version が同じなら URL だけ出す。version が違えば（engine-upgrade の後）立て直す |
| `bin/fge dashboard stop` / `status` | `POST /api/shutdown` で止める（pid へ直に kill しない。pid は別のプロセスに使い回されることがある）・立っているかを出す |
| `bin/fge dashboard post <post.json>` | 素材ごと posts へ写し、id と URL（`…/#post-<id>`）を出す |
| `bin/fge dashboard post --shots <png…> --title <題>` | post.json を書かずに、描き出した絵を並べるだけの post を作る |
| `bin/fge dashboard inbox [--json] [--all]` | reply.json があり resolved が無い post を、返事の中身ごと出す。既定は origin の worktree が今の物に合う post だけ（並んで動く AI が他の担当の返事を拾わない）。`--all` で全部。何も書き換えない |
| `bin/fge dashboard resolve <id>` | resolved を置く。WhyNot `close`: `bin/fge tickets close` と同じ語で別の物を指すことになる |

- 出力は os.Stdout へ直に書く（`main.go` の Handler は文字列を溜めてから出す作りで、居座るサーバーには合わない。proposal と同じ扱い）。
- `make dashboard`（start してブラウザで開く）を game.mk に足し、`make help` の先頭のグループに載せる。
- `make status` に 1 行: 「ダッシュボードに返事 N 件 → bin/fge dashboard inbox」（N が 0 なら出さない）。
- `make strays`: 裏で立てたサーバーは「ppid 1 の fge-go で根の下にいる物」に当たり、今のままだと拾われる。strays.sh は server.json の pid を
  **除く物**として読み（whoami が答えるなら正規のサーバー）、拾うのは server.json があるのに whoami が答えない時だけにする。

### 4.1 裏で立てる作り

- 親は `os.Executable()` を `dashboard serve`（隠しサブコマンド）として起こし、`hooks.Detach`（go/internal/hooks/detach_*.go。Unix は
  Setsid・Windows は CREATE_NEW_PROCESS_GROUP）で切り離す。stdin は nil、stdout と stderr は `debug/dashboard/server.log`。
- 子は Listen してからポートを決める（8790 が塞がっていれば port 0）。server.json `{pid, port, root, version}` は tmp に書いてから rename。
- 親は whoami が答えるまで約 5 秒待つ。来なければ server.log の末尾を出して終了コード 1。

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
- 一覧の更新は 3 秒ごとの `GET /api/index`（posts と tape の更新時刻だけを返す。変わった時だけ取り直す）。
  WhyNot websocket: 1 人が手元で見る頁で、問い合わせで足りる。標準ライブラリだけで済む。
- **ゲームへは問い合わせない。** `view=shot` は主のスレッドで場面を組んで塗り、最大 60 秒待つ（RemoteDebug.flix:616-624）。
  定期的に叩くとゲームが詰まるので、ボタンを押した時だけ。返るのは PNG のパスなので、ダッシュボードはそのゲームの dir の下のパスだけを出す。
  `onShotRequest` を繋いでいないゲームには「このゲームは撮れない（App.onShotRequest を繋ぐ）」と出し、止める / 進めるだけ出す。
- 頁は `go:embed` で fge-go に入れる（tape の template.html と同じ）。外の CDN を読まない。

## 6. 安全

- `127.0.0.1` だけで待つ。
- 全部の要求で `Host` が `127.0.0.1:<port>` か `localhost:<port>` であることを見る（DNS rebinding で GET を読まれるのを防ぐ）。
- POST は `Origin` が自分の時だけ受ける。
- ファイルを出すのは決まった置き場の下だけ。`..` と、symlink を辿った先が置き場の外になる物を断る。
- RemoteDebug への中継は games.json にある port だけ。

## 7. Studio の凍結で engine 側が直す所

| 所 | 直し方 |
|---|---|
| gates.json の `studio-parity`（release の門・今は hold）と、テンプレート 7 つの gates にある `studio-parity` | どちらも外し、凍結中と note に書く |
| /add-template の手順 6・7（Studio への登録・swap-jar） | 「Studio は凍結中。飛ばす」と書く |
| `make new-game` の最後の案内の「Studio で開く」 | `make dashboard` に替える |
| README 冒頭の Studio の紹介 | ダッシュボードの紹介に替え、Studio は凍結中と 1 行 |
| `reference/title.png` を git に入れる例外 | **替えない**。凍結を解いた時に要る。1 ファイルずつで重くない |
| スキーマの sections の書き方を Studio に合わせる決まり（doc-conventions.md） | **替えない**。Doc の書き方として既に定着している |
| `~/.flix_ge_studio/games.json` の場所 | **替えない**。今の Studio の .app と bin/fge talk goto とダッシュボードが同じ所を読む |
| agents-pack/manifest.json のキー名を替えない約束 | そのまま（凍結を解く時のため） |

## 8. AI 側の配線（AGENTS.md の決まり）

- agents-pack/AGENTS.core.md の早見表に 2 行: 「人に絵・動画・案を見せて選んでもらう → `bin/fge dashboard post`」「人の返事を拾う → `bin/fge dashboard inbox`」。
  proposal の行は「静的な頁を作って渡すとき」に絞る。
- agents-pack/agent-eval/engine.json にお題を 1 本（「描き出した 3 枚を人に見せて選んでもらって」で `dashboard post` を選ぶか）。
- engine のリポだけで打つ物は無い（ゲームで打つ）。

## 9. フェーズ

| フェーズ | 中身 | 終わりの基準 |
|---|---|---|
| 1 | start / stop / status / post / inbox / resolve、Inbox と Tape のタブ、proposal の頁の「送る」、`make dashboard`、status の 1 行、strays、早見表 2 行 + お題 1 本、Studio の凍結の直し（7 節） | game-starter から産んだゲームの worktree で AI が post → 人が main のダッシュボードで選んで返す → AI が inbox で拾う、が会話のコピペ無しで通る |
| 2 | Games・Images・Tickets・Capabilities のタブ | 起動中のゲームを頁から止めて撮れる |
| 3 | 絵の上を囲むメモ（reply.json に `notes`）。手元で開いた Tape の頁の注釈を reply へ送る | Tape の注釈が inbox に来る |
| 4（未定） | 頁から make のターゲットを流す（ログを流して見せる） | 要るか、フェーズ 3 の後に決める |

## 10. 決めていないこと（相談）

1. 既定のポート 8790 を固定でよいか（ブックマークできる。Studio は 8787）。
2. engine のリポの根でもダッシュボードを立てるか（テンプレート横断の gallery・門の結果）。フェーズ 1 ではゲームの根だけ。
3. チームで同じ post を見たくなった時は、tape publish の置き場（GitHub Pages）へ載せる道を足すか。

## 11. レビュー（第 1 版・64 点）への答え

| 指摘 | 答え |
|---|---|
| worktree の post が見えない | 3.1 で main の作業ツリーの 1 か所に置く |
| サーバーが手前で止まる | 4 節の start / stop / status・whoami・strays。出力は stdout へ直に |
| 今の画面は `/render` で取れない・問い合わせでゲームが詰まる | 5 節で `view=shot` を押した時だけ。撮れないゲームの表示も決めた |
| proposal の頁に返す手段が無い | 5 節で proposal.go に切り替え（send）を足す |
| 素材のパス・id の衝突 | 3.2 |
| DNS rebinding | 6 節で Host を見る |
| Studio の凍結の表が足りない | 7 節にテンプレートの gates・title.png・sections・games.json を足した |
| reference-check の結果が保存されていない | Images タブはフェーズ 2 へ移し、差は出さず PNG と compare だけにした |
| status・kind・seen は要らない | 消した（2 節の 4・3.2） |
| inbox にチケットとヒッチを混ぜない | 混ぜない（make status に既に出る） |
| features.json は要らない | 消した。Capabilities は AGENTS.md の早見表を読む |
| games.json の読み手が既にある | go/internal/talk を使う |
| フェーズ 1 が多すぎる | 囲むメモ・Images・Tickets・Capabilities を後へ回した |
| `close` が tickets とぶつかる | `resolve` にした |
| jargon の語 | 消した |
| （第 2 版）git-common-dir の親は bare・submodule・templates/x で誤る | 3.1 で worktree list の先頭 + show-prefix、strays.sh と同じ関数に |
| （第 2 版）Tape だけ worktree をまたがない | 3.1 で全部の worktree の debug/tape を読む |
| （第 2 版）inbox が他の worktree の返事を拾う | 4 節で既定を今の worktree に、`--all` で全部 |
| （第 2 版）strays が正規のサーバーを拾う・pid で kill は危ない | 4 節で server.json を除く物として読む・stop は /api/shutdown |
| （第 2 版）engine-upgrade の後に古いサーバーが残る | start が version を比べて立て直す |
| （第 2 版）start の作り | 4.1（serve・hooks.Detach・server.log・whoami を待つ） |
| （第 2 版）reply のファイル名の `:` | 3.1 で at の形を替えた |
| （第 2 版）proposal の bar と今の picks | 5 節で Page() と send・picks |
