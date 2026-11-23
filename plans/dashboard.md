# ダッシュボード（engine 起点・ブラウザ）

状態: 設計（相談中）。実装は未着手。

## 0. 決まっていること（作者の判断）

- **Studio（flix_ge_studio）は凍結する。** 非エンジニアにゲームを作らせる道具は、要るようになったら再開する。
- **engine 起点のダッシュボードに寄せる。** 最初の相手は Flix を書くエンジニア。
- **最初の用途は、AI（Claude・Codex など）が人へ見せる物の置き場。** スクショの案を載せる・Tape を
  撮り直して載せる・内容を差し替えやすい置き場を整える。

## 1. 解きたい課題

| 課題 | 今 | 根拠 |
|---|---|---|
| 隠れた機能 | Tape・リモートデバッグ HTTP・F8 の囲みと巻き戻し・flow の自動記録・ヒッチの記録は、AI 向けの早見表（agents-pack/AGENTS.core.md）にしか載っていない | 調査（2026-11-23） |
| AI が作った物の見せ場が散らばる | proposal は `reports/<名前>/index.html`、Tape は `debug/tape/<名前>/index.html`、比較は `debug/compare/index.html`、チケットは `debug/annotations/`、描き出しは `debug/*.png` と `gallery/`。人は AI に「どこにある？」と聞くしかない | go/internal/proposal・mk/tape.mk・docs/modules/debug.md |
| 人 → AI の返事が会話に頼る | proposal の「決定をコピー」で返事を会話に貼る。Tape の注釈もプロンプトをコピーして貼る | go/internal/proposal/proposal.go の冒頭 |
| Studio の追従 | server が engine を 0.37 で固定（本体は 0.108）。決まりの写し（sync-agents・ジャンル表・make の口の名前）が 30 を超える | flix_ge_studio/server/flix.toml・docs/backlog.md |

## 2. 方針

1. **Go で書き、`bin/fge dashboard` として配る。** ゲームの `bin/fge` は engine の `fge-go` の写しを呼ぶだけなので、
   ゲームの engine の版とダッシュボードの版が自動でそろう（`make engine-upgrade` で一緒に上がる）。
   Studio のように別リポで engine の版を追いかける物を作らない。
   - WhyNot Flix で書かない: 起動に JVM と型検査の待ちが要り、ゲームの make の前に立ち上げたい道具として重い。
     HTML の頁を作る道具（tape・proposal・compare）は既に Go にある。
2. **今ある出力を読むだけにする（写さない）。** ダッシュボードは `debug/tape/*`・`reports/*/proposal.json`・
   `debug/annotations/*`・`debug/compare`・`debug/perf/hitches`・`gallery/`・`~/.flix_ge_studio/games.json` を
   その場で読み、一覧にする。新しく足す置き場は 1 つ（3 節の posts）だけ。
3. **AI は CLI で書き、人はブラウザで読んで返す。** AI ごとの専用の口は作らない（Claude も Codex もシェルが打てれば同じ）。
   人の返事はファイルに落ち、AI は CLI で拾う。会話へのコピペを要らなくする。
4. **ロジックを二重に持たない。** 頁の描き方は既存の Go（proposal の HTML・tape の index.html）を呼ぶ。
   ゲームを動かすのは RemoteDebug の HTTP をそのまま中継する。

## 3. 置き場: posts

AI が人に見せたい物を置く、新しい唯一の置き場。

```
<ゲーム>/debug/dashboard/posts/<id>/
  post.json      AI が書く（下の形）
  *.png *.mp4 …  post.json が指す素材（AI が描き出した物を写す）
  reply.json     人がダッシュボードで返すと書かれる（AI は書かない）
```

- `debug/` の下なので git に入らない（生成した絵は git に入れない決まりに合う）。人に残したい物は
  今までどおり docs/gallery へ選んで写すか、`bin/fge tape publish` で公開する。
- `<id>` は `YYYYMMDD-HHMMSS-<短い名前>`（並べるだけで新しい順になる）。

### post.json の形

**proposal.json（go/internal/proposal）の形をそのまま使い、欄を 3 つ足す。** 「スクショの案」は proposal の
「選べる節」そのものなので、新しい形を作らない。

```jsonc
{
  "version": 1,
  "kind": "proposal",            // 足す: proposal | shots | note。見た目の出し分けだけに使う
  "author": "claude",            // 足す: 書いた AI の名前（自由な文字列。codex など）
  "status": "open",              // 足す: open | answered | closed。reply.json が来たら answered と見なす
  "title": "…", "lead": "…",
  "sections": [ … proposal と同じ … ],
  "ask": ["…"]
}
```

`shots` は options の無い sections だけの post（「描き出したのでご覧ください」）、`note` は文だけの post。

### reply.json の形

```jsonc
{ "version": 1, "at": "2026-11-23T12:00:00+09:00",
  "picks": {"A": "A1"},           // 選べる節の選択（proposal の decision.picks と同じ形）
  "comment": "B はもう少し暗く",   // 自由文
  "notes": [ {"section": "B", "media": "b2.png", "rect": [x, y, w, h], "text": "…"} ] }  // 絵の上で囲んだ所（任意）
```

## 4. CLI（AI が打つ口）

| 口 | すること |
|---|---|
| `bin/fge dashboard` | ゲームの根で立てる。`127.0.0.1:<DASHBOARD_PORT>`（既定 8790・塞がっていれば空いた番号）。URL を 1 行出す。既に立っていれば URL だけ出して終わる |
| `bin/fge dashboard post <post.json>` | 素材ごと `debug/dashboard/posts/<id>/` へ写す。形を検査し、指す素材が無ければ止める。id を 1 行出す |
| `bin/fge dashboard post --shots <png…> --title <題>` | post.json を書かずに、描き出した絵を並べるだけの post を作る近道 |
| `bin/fge dashboard inbox [--json]` | まだ AI が読んでいない返事（reply.json）・新しいチケット（F8）・新しいヒッチを並べる。読んだ印は `debug/dashboard/inbox-seen.json` |
| `bin/fge dashboard close <id>` | post を closed にする |

- `make dashboard` を game.mk に足す（`make help` の「はじめに」の段に載せる）。
- `make status` に 1 行足す: 「ダッシュボードの返事 N 件 → bin/fge dashboard inbox」。会話の始めに AI が気づく。

## 5. 画面（1 枚の頁・タブ）

| タブ | 中身 | 読む物 |
|---|---|---|
| 受信 | AI からの post（新しい順）。proposal は選んで返す・shots は絵の上を囲んでコメント | posts |
| ゲーム | 起動中のゲーム（games.json）。各ゲームの今の画面（RemoteDebug `/render`）・止める / 進める / 場面から始める（`/starts` `/start`） | games.json・RemoteDebug |
| Tape | 撮ったテープの一覧（題・撮った日・撮った版・公開 URL）。開くと既存の index.html | debug/tape/*/tape.json・published.jsonl |
| 絵 | gallery と debug の PNG、リファレンスとの差（reference-check の結果）、compare | gallery・debug・reference |
| チケット | F8 で囲んだ物とヒッチ（README の頭を出す） | debug/annotations・debug/perf/hitches |
| 機能 | 何ができるかの一覧（6 節）。コマンドのコピーと「AI に頼む文」のコピー | 機能の一覧 JSON |

- 更新は 2 秒ごとの問い合わせ（`/api/index` が置き場の更新時刻を返し、変わった時だけ取り直す）。
  WhyNot websocket: 1 人が手元で見る頁で、問い合わせで足りる。Go の標準ライブラリだけで済む。
- 頁は `go:embed` で fge-go に入れる（tape の template.html と同じ）。外の CDN を読まない。

## 6. 機能の一覧（隠れた機能を無くす）

`bin/lint-rules/features.json` を 1 つ置く（bin/lint-rules はゲームへ配られる）。

```jsonc
{ "id": "tape", "title": "Tape（flow を動画にして注釈してもらう）",
  "about": "…", "run": "make tape FLOW=e2e/tape.flow", "needs": ["mk/tape.mk を include"],
  "ask": "e2e/tape.flow でテープを撮り直してダッシュボードに載せて", "audience": "human" }
```

- ダッシュボードの「機能」タブはこれを読む。
- **段階 2 で**、`make help` の「はじめに」の段と AGENTS.core.md の早見表の一部をここから作り、
  食い違いを `make check-docs-sync` に足す。段階 1 では手書きで始め、項目を育てる。

## 7. 安全

- `127.0.0.1` だけで待つ。POST は `Origin` が自分（`http://127.0.0.1:<port>`）の時だけ受ける
  （手元の別の頁からの書き込みを防ぐ）。
- ファイルを出すのはゲームの根の下の決まった置き場だけ。`..` と symlink の外への抜けを断る。
- RemoteDebug の中継は games.json にある port だけ。

## 8. Studio の凍結で engine 側が直す所

| 所 | 直し方 |
|---|---|
| gates.json の `studio-parity`（release の門・今は hold） | release の門から外す。凍結中と note に書く |
| /add-template の手順 6・7（Studio への登録・swap-jar） | 「Studio は凍結中。飛ばす」と書く |
| `make new-game` の最後の案内の「Studio で開く」 | `make dashboard` に替える |
| README 冒頭の Studio の紹介 | ダッシュボードの紹介に替え、Studio は凍結中と 1 行 |
| `~/.flix_ge_studio/games.json` の場所 | **替えない**。WhyNot: 凍結を解いた時と、今の Studio の .app を使っている人の両方が同じ所を読む |
| agents-pack/manifest.json の note の「Studio 版（NewGame.flix）」 | そのまま（キー名を替えない約束は凍結を解く時のため残す） |

## 9. 段階

| 段階 | 中身 | 終わりの印 |
|---|---|---|
| 1 | `bin/fge dashboard`（受信・Tape・絵・チケット・機能（手書き）タブ）、post / inbox / close、`make dashboard`、status の 1 行、Studio の凍結の直し、早見表 + agent-eval のお題 | game-starter から産んだゲームで、AI が post → 人が選んで返す → AI が inbox で拾う、が会話へのコピペ無しで通る |
| 2 | ゲームタブ（games.json と RemoteDebug の中継）、features.json から make help と早見表を作る | 起動中のゲームを頁から止めて撮れる・機能の食い違いを検査が止める |
| 3 | Tape の頁（index.html）の注釈を、手元で開いた時はダッシュボードの reply に書く（コピーも残す） | Tape の注釈が inbox に来る |
| 4（未定） | 頁から make の口を流す（ログを流して見せる） | 要るか、段階 3 の後に決める |

## 10. 決めていないこと（相談）

1. posts を `debug/` に置く（git の外・機械ごと）でよいか。チームで同じ post を見たくなったら、公開の道（tape publish の置き場）に載せる案。
2. 既定のポート 8790 を固定でよいか（ブックマークできる利点。Studio は 8787）。
3. engine の根でもダッシュボードを立てるか（テンプレート横断の gallery・門の結果）。段階 1 ではゲームの根だけ。
