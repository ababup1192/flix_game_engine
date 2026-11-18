# 変更差分から流す門を絞る（test selection）の設計

状態: 設計だけ（実装はまだ）。2026-11-19・main v0.102.0。

人の依頼: git の変更差分から流すべきテストの範囲を狭めて作業の速さを上げたい。`bin/fge refactor` と flixlint を使う。
テストは flix test に限らない。今の形で狭めにくいなら全体の作りを直して問題を単純にしてよい。

人と合意済みの安全の確かめ方: **過去のコミットで、絞った範囲だけで、全部流した時に落ちたテストを拾えたかを答え合わせし、
拾い漏れが 0 になってから使う。** release の全量の門（`RELEASE_GATES`）は絞らない。絞るのは作業中の確かめだけ。

値打ちは 2 つある。(1) 安全側に全部流すより速い。(2) 今のやり方（AGENTS.md の「波及したパッケージだけ `make test-<name>`、他は flix check」）では
作業中に流していないテンプレートや門の退行を、作業中に拾える。(2) の方が大きい変更の種類もある（5 節の表）。

---

## 1. 今ある門と、その入力・時間

時間の出典は 3 つ。(a) 0.102.0 の release で test-par-all が書いた `.test-logs/*.log`（6 並列で混んだ中の実時間と flix の Elapsed）、
(b) `build/` の下の生成物の時刻（0.101.1 の時に手元で流した determinism・gl-capture など）、(c) この調べで測った物（2 節）。
測っていない物は「不明」。

### 1.1 flix test（パッケージごと）

| 門 | 入力 | いつ | 実時間（並列の中） | Elapsed（実行だけ） | テスト数 / ファイル数 |
|---|---|---|---|---|---|
| `make test-engine` | engine/src・engine/test（test/data の .glb を含む） | 手動・release | 29s（1 本だけなら 11.6s を測った） | 8.0s | 1054 / 66 |
| `make test-engine_tools`（.layers） | engine/src + engine_tools/src・test、templates の font | 手動・release | 27s | 8.6s | 331 / 35 |
| `make test-engine_world`（.layers） | engine/src + engine_world/src・test（test/assets の .ui.json）、testdata/lint/flow-check・go/internal/yarn/testdata | 手動・release | 48s | 18.0s | 1656 / 132 |
| `make test-render_gl`（.layers） | engine/src + render_gl/src・test、fge-gl jar、templates/*/assets/*.shader.json（TestWgslDawn）、engine/test/data の .glb（TestDrawHash） | 手動・release | 47s | 19.1s | 682 / 53 |
| `make test-hd2d-starter` | テンプレートの src・test・sample-test・assets・project.json、置き場の engine_full の fpkg | release | 45s | 6.8s | 95 / 4 |
| `make test-rpg-starter` | 同上 | release | **1分52s** | **76.2s** | 210 / 13 |
| `make test-sound-novel-starter` | 同上 | release | 35s | 8.7s | 642 / 22 |
| `make test-tidepool-starter` | 同上 | release | 24s | 1.8s | 61 / 9 |
| `make test-par-all`（上の 8 本を 6 並列） | 全部 | release | 1分52s（rpg-starter 1 本で決まる） | - | 4831 |
| game-starter（test 4 本） | `make new-game` の写しの後の check → test → render-all | new-game の時だけ（TEMPLATE_DIRS から外れている） | 不明 | - | - |

実時間と Elapsed の差は大半がコンパイル。テンプレートで実行が重いのは rpg-starter だけ（TestWorldMap 15.2s・TestBattle 11.9s・TestMine 10.7s・
TestSounds 7.9s・TestBoss 7.6s。1 本 0.3 秒ほどのテストが並ぶ）。sound-novel は Elapsed 8.7s で、35s の大半はコンパイル。
層では render_gl の Render3d 8.6s・TestWgslDawn 7.5s、engine_world の TestCharacterBody3d 5.8s・TestWorldlineBench 4.2s。

### 1.2 flix test 以外の門

| 門 | 確かめる事 | 入力 | いつ | 時間 |
|---|---|---|---|---|
| hook-flix-work（Stop の checkd） | 触ったパッケージの型検査 | 触った .flix のパッケージ | 会話の区切り | 1 回 0.3〜1s（中央値）・最大 13〜23s |
| `make check`（根の 4 パッケージを 1 本の木で） | 型検査 | 4 パッケージの src | 手動 | 常駐の 2 回目 1.05s・1 回目 10.1s |
| `sync-engine-full`（中の flix check + build-pkg） | engine_full の fpkg を作り置き場へ | 4 パッケージの src | sync・release・テンプレートのテストの前 | 約 14s |
| `release-guard` | 配る物が未コミットでないか・flix.toml・同梱の flix.jar の版・migration-notes・gl-jar-pin | 配る物の一覧 | release | 不明 |
| `studio-parity` | 外の Studio の clone で check-agents-parity | agents-pack・sync-agents の出力 | release | 不明 |
| precommit の lint 21 本・images・referenceDrift | 書き方・画像の置き場・絵の基準のずれ | 規約ごとの拡張子・場所（`bin/lint-rules/precommit.json`） | コミット時 | 合わせて 0.01〜0.05s |
| precommit の docsSync → `make check-docs-sync` | 配線・api-digest・check-refs ほか | Makefile・.claude・agents-pack・templates・**どの .md と .flix も** | コミット時 | 不明（数秒と見る） |
| `gl-jar-pin-check` | 3 つの flix.toml の jar の行と render_gl/java のハッシュ | render_gl/java・flix.toml | 毎コミット | 1 秒未満 |
| `make render-all` / `render-changed` | テンプレートの gallery を描き直す（生成） | テンプレート（assets の Doc を含む）・engine 側 | 手動 | 全量 約 150s・1 本 16〜30s |
| `make -C templates/<名前> reference-check` | gallery を reference/SHA256SUMS.txt とバイトで比べる | テンプレート全部と fpkg | 手動 | テンプレートでは不明 |
| `make gl-parity` | GL と SoftRaster の絵の一致・式の差の上限 | bench/gl_parity と fpkg（render_gl・SoftRaster・ShaderEval・ShaderGen） | release の最後 | 約 18s |
| `make determinism` | rpg・sound-novel・tidepool を隠しウィンドウでシナリオどおり流し、記録の再生と World の指紋が同じか | testdata/determinism/*.flow・3 テンプレート（assets を含む） | release の前に手元で | 3分32秒（1 本 約 70s） |
| `make gl-capture-check` | 既定の場面を WebGPU で 2 回撮り SHA を比べ、機械の基準とも比べる | テンプレート 3 本・bench/scene3d・render_gl（Dawn）・基準の sha256 | release の前に手元で | 約 12 分 |
| `make webgpu-v1-check` / `-web` | WebGPU と GL の比べ・ブラウザで撮る | bench/webgpu_v1・v2（engine_full/src を束ねる）、engine_full_web | 手動 | 約 64s / 約 23s |
| `make smoke-devtools` | DEBUG 起動の開発の道具 | rpg-starter と App | release の前に手元で | 不明 |
| `make baseline-check`・`check-external`・`refactor-smoke` | 基準の版との比べ・外のゲームの型検査・refactor の道具 | bench/baseline・置き場の fpkg・testdata/refactor-smoke | 手動 | 不明 |
| `make go-test` | go/ の 83 パッケージ | go/・go/internal/*/testdata・docs/check-codes.md・bin/lint-rules/*.json・engine の .flix（一部のテストが読む） | 手動だけ | 全量は不明（高負荷で internal/tape が 600s で切れた記録）。internal/precommit 1 本は 2.3s を測った |
| `make lint`（ONLY=） | 規約の全量 | 規約ごと | 手動 | 0.05s |
| `make agent-eval-release` | 道具の選び方（知らせるだけ） | agents-pack・docs | release の後 | 約 20 分 |
| CI: Release / GL jar / Release Gate | 配る物の組み立て・jar・全パッケージのコンパイル | きれいな checkout | 手で・push・タグ | 3.5〜5.3 分 / 0.2〜0.5 分 / 約 2 分 |
| ゲーム側のテープ（tape）・compare | 記録とハッシュで前の版と比べる | 外のゲームのリポ | ゲームで手動 | このリポの外（対象外） |

release の全量の門は `release-guard → studio-parity → sync → test-par-all → gl-parity`。0.102.0 では sync の途中から release/verified.txt を書くまで約 2分34秒。
release の外で手元で流す重い門（determinism → gl-capture-check → webgpu-v1-check-web）は 0.101.1 の時に約 21 分。

### 1.3 パッケージの依存の向き

- engine（依存ゼロ）← render_gl・engine_world・engine_tools（3 つの層。`.layers/<層>` に engine/src と層の src・test をファイル単位の symlink で並べて組む。**層どうしは互いを見ない**）
- engine_full（4 パッケージの src への symlink + src/full）→ fpkg → 置き場 → templates/* と bench/* の lib（symlink）
- テンプレートは engine の写しを持たない（lib の fpkg 経由）。`make test-<テンプレート>` は fpkg が古くても気づかない（sync を先に流す要がある）
- 写しで持つ物: bench/common の 2 ファイル（`make bench-common` の cp）、LwjglLoad と HeadlessLoad の同じ部分、gen-light3d の生成物（engine の LightModel3d → engine_tools/src/gen/SoftRaster3dLight.flix）
- テストが読むファイル（パッケージをまたぐ物）: engine_tools → templates の font、render_gl → templates/*/assets/*.shader.json と engine/test/data の .glb、
  engine_world → testdata/lint/flow-check・go/internal/yarn/testdata。ほかに、あるテストが build/ の下へ書いた物を別のテストが読む形がある（build/flow-test・build/test）。
  一覧は facts の `str_lit.tsv` から作れる（手書きしない。文字列を組み立てて作るパスだけを表の規則にする）
- go/ の道具は門そのもの（checkd・precommit・forbid・flow・headlessrun・rendercache・fontbake・px・sprite）。go の変更は bin/fge-go を作り直すまで門に効かない

---

## 2. flix test は何で絞れるか（測った事）

1. **flix 0.80.0 の `flix test` には名前で絞る旗が無い**（`bin/flix --help` の test は旗なし）。絞れるのは「どのパッケージを流すか」と「どのファイルを木に入れるか」だけ。
2. 木はもう作れる形がある。`.layers/<層>` と同じく、src を全部と、選んだテストのファイルだけを symlink で並べた木を作れば、flix test はその木のテストだけを組んで流す。
3. 測った（他の担当が動いていて load 4〜23 の中）:

| 木 | 実時間 | Elapsed | テスト数 |
|---|---|---|---|
| engine 全部（engine/ で素の flix test） | 11.6s | 4.3s | 1054 |
| engine の src 全部 + TestGltf の 5 ファイル + TestDecoder | **5.2s** | 0.3s | 82 |
| rpg-starter 全部（release の記録） | 1分52s | 76.2s | 210 |
| rpg-starter の src 全部 + TestBattle + Fixtures（assets などは根ごと symlink） | **17.8s** | 4.0s | 20 |

1 パッケージの時間は「src のコンパイル（engine で約 4s・rpg-starter で約 14s）」+「選んだテストのコンパイルと実行」。
ファイル単位の木で大きく縮むのは実行が重い rpg-starter と、層の重いファイル（Render3d・TestWgslDawn・TestCharacterBody3d）だけ。

4. 木を作る時に踏んだ事（作りの決まりにつながる）:
   - **テストのファイルは別のテストのファイルの helper を呼ぶ**（TestGltf → TestDecoder.pixelsOf）。選んだファイルから calls をたどった helper のファイルも入れる。
   - **mod の親子は非 pub の def を共有する**（TestGltfEmissive.flix は mod TestGltf.Emissive で、親の TestGltf の非 pub の `onePixelPng` を使う）。
     子を外して親だけ入れると、親の def が「使われていない」（E7956 Redundancy）で組めない。同じ頭の mod のファイルはまとめて入れる。
   - テストは cwd から見た相対パスで test/data・test/assets・assets/・project.json・`templates`（.layers が張る symlink）を読む。木には src と選んだ .flix だけでなく、パッケージの根の物を全部張る。
   - `bin/with-sample-tests` は `pwd -P` が `templates/` の下の時だけ sample-test を貼る。別の場所の木では何も知らせずに貼らないので、道具が自分で入れる。
5. テストのファイルどうしの呼び合いを facts から数えた（向きを無視したまとまり）: engine は 66 ファイルが 56 のまとまり（最大 11）、engine_world は 132 が 129（最大 3）、
   render_gl は 53 が 35（最大 15）、engine_tools は 35 が 28。テンプレートは Fixtures / TestKit が真ん中にいて 1 つにまとまる。
   向きを無視すると絞れないので、**向きつき（選んだテスト → helper）でたどり、mod の親子だけ両向き**にする。

---

## 3. refactor と flixlint の facts で、変わった宣言から呼び手を逆にたどれるか

### できる事（試した）

- `bin/fge refactor usages <Mod.f> --callers --depth N --json` は呼び手の木を返し、**テストの def まで届く**（`Gltf.gltfMaterialOf` → `Gltf.fromGlb` → `Gltf.fromGlbKeyed` → `TestGltf.testFromGlbKeyed…`）。1 回 0.2〜0.3 秒。
- **`--depth` を付けないと 1 階層しか出ない。** `Color.rgb` で届いたファイルの数は depth 2 で 83・3 で 98・6 で 125・50 で 138（うちテスト 87）。道具は depth を大きく取り、増えなくなるまで引く。
  `--max` `--limit` で途中が切られないかは実装の時に確かめる（今は確かめていない）。
- engine の根の索引は 4 パッケージの src と各パッケージの test、それに bench/* と engine_web を別の木として持つ。
- **テンプレートの中では、そのテンプレートの索引で engine の名前を引ける**（`templates/sound-novel-starter` で `Timeline.atStartOf` の呼び手が src 4 ファイル・test 11 ファイル（22 のうち）に届いた。1 回 0.13 秒・初回だけ索引を作り 5.7 秒）。
  engine の根からはテンプレートを引かない。テンプレートの索引は engine を lib の fpkg として見るので、**engine の中のたどりは根の索引で最後まで済ませ、届いた engine の def を 1 つずつテンプレートの索引で引く**（変えた def 1 つだけを引くと、engine の中を通って届く呼び手を落とす）。
- flixlint の facts（`build/refactor/flixlint/facts/*.tsv`）に `def.tsv`（名前・ファイル・頭の行）・`calls.tsv`（呼ぶ側・呼ばれる側・行）・`handles.tsv`（effect を扱う def）・
  `effect_of.tsv`・`str_lit.tsv`（文字列リテラル）がある。テストのファイルの helper のたどり（2 節の 4）は calls.tsv から引けた。

### できない所（索引の外・静的な呼び出しの外）

| 届かない所 | なぜ | どう扱うか |
|---|---|---|
| Java（render_gl/java・engine_web/java・js） | .flix の索引の外 | render_gl/java → render_gl と下流を全部（テンプレート・bench・GL の門）。engine_web → web の門 |
| trait の instance の本文・trait の既定の本文・`eff` の宣言・derive（`with Eq, ToString`） | facts は instance の def を持たず、呼び出しは `ToString.toString` のように trait へ向く | 変わった行が def・enum・alias のどれにも入らない → そのパッケージと下流を全部 |
| enum に case を足す | 足した case は誰も使っていない。変わるのは `case _` を持つ match の振る舞い | enum の変更は、全部の case の使われ所（match を含む）を合わせて呼び手として数える |
| 関数を値で渡す所（`List.map(Foo.bar, xs)`）・handler を値で渡す所 | calls.tsv に出ない事がある | facts でなく refactor usages（ref・call 両方）でたどる |
| Doc の JSON（templates/*/assets/*.json）・project.json | コードからは `Res.loadDocs()` などでまとめて読む。project.json の textures 漏れは実行時にだけ落ちる | テンプレートの assets・project.json の変更 → そのテンプレートのテスト全部・描き出し・determinism |
| テストが読むファイル | 文字列のパス | str_lit から作った表で「ファイル → テストのファイル」。組み立てたパスだけ手書き |
| シェーダーの字 | def の中の文字列なので、def の変更としては拾える | 拾える。GPU の門は flix test でないので、届いた def で門を選ぶ（5 節） |
| 生成物（gen-light3d）・写し（bench-common・LwjglLoad と HeadlessLoad） | 生成元と生成物、写しどうしは呼び合わない | 表の規則（組を 1 行ずつ） |
| ゲームの main からしか届かない物（隠しウィンドウで動く determinism・gl-capture） | テストの def には届かない | 届いた def がテンプレートの main に届くかで門を選ぶ。実際はテンプレートの src のほとんどが main に届く |
| パッケージを持たないファイル（bin/lint-rules・docs/check-codes.md・agents-pack・testdata・e2e/*.flow・lint/rules.flix など） | どのパッケージの物か決まっていない | 表にパスごとの持ち主を書く。書いていない物は全部の門 |
| Makefile・mk/・bin/*.sh・.github・lib/・flix.toml | 配線 | 全部流す。flix.toml はパッケージの `version =` の行だけの差なら sync だけ。`flix =`（コンパイラ）と依存の版の行は全部 |
| go/ | go の test cache は go のテストしか見ず、テストが exec した子プロセスが読むファイル（約 20 本のテストが exec を使う）は追わない | go のパッケージ → 門の表（4 節）。go の変更の後は bin/fge-go を作り直す |
| 索引を作れない木 | 今 bench/gl_parity・hd2d_town・shader_cache_soak・texture_upload・engine_web は「索引を作れません」で飛ばされている。hd2d-starter は facts がまだ無い。**この事は stderr の文にだけ出て `--json` に入らない** | 道具が `build/refactor/trees-skip.json` とテンプレートごとの索引の有無を自分で見て、見えない木の門を全部流す |
| 消した・名前を変えた・型を変えた宣言 | 今の索引に名前が無い。下流がまだ使っていても、下流のファイルは差分に出ない | **sync の後に下流を全部型検査する**（3 層・テンプレート 4 本・bench。engine の pub 面が変わった時は game-starter の写しも） |

---

## 4. 今の作りで絞りにくい所と、作りの直しの案

| 絞りにくい所 | 直しの案 | 効果 | 手間（実時間） | engine に触るか |
|---|---|---|---|---|
| 索引を作れない木（bench 4 本・engine_web）と facts の無い hd2d-starter | 索引の失敗を直す（多くは lib か束ね方）。refactor の `--json` に「引かなかった木」を足す | **案 B が engine の変更で gl-parity・hd2d・web の門を外せるかはこれに頼る** | 2〜4 時間（原因による） | go と bench（engine ではない） |
| rpg-starter の実行が重い（1 本 0.3 秒のテストが並ぶ） | Fixtures の起動・Doc の読み込みを毎回しているかを測り、共有できるなら共有する | release の門の 1分52s もそのまま縮む（絞りとは別に縮む） | 測るのに 1 時間・直しは結果しだい | テンプレートだけ |
| テストの helper が別のテストのファイルにあり、mod の親子で非 pub を共有する | 決まり: 共有の helper は `Test*Kit.flix` / `Fixtures.flix` に pub で置く。テストのファイルは他のテストのファイルの非 pub を使わない（lint で止める） | ファイル単位の木のたどりが「選んだファイル + Kit」で済む | 2〜3 時間（engine/test と層の test の該当の数による） | **engine/test を触る → 相談** |
| 門ごとの入力が Makefile のレシピと precommit.json とコメントに散らばる | **済（plans/gates-tidy.md）**: 根の `gates.json` に門ごとの入力（precommit.json の `when` と同じ書き方）を持たせた。precommit.json はゲームへ配られてゲームのコミットでも走る表なので広げず、`bin/fge gates` が読み込んで混ぜる | 「表に当てはまらない変更は全部流す」の判定を 1 か所で書ける | 3 時間 | go と json だけ |
| go のパッケージと門の関係 | 同じ表に go のパッケージ → 門（yarn の testdata → engine_world のテスト、flow・headlessrun・rendercache → 描き出しと determinism、checkd・precommit・forbid → 型検査と precommit の素振り、fontbake・px・sprite → 生成した素材） | go を直した時の門が表から引ける | 1 時間 | go と json |
| 生成物と写し | 表に「生成元 → 生成物」「写しの組」を書く。bench-common の cp は symlink にする | 規則を表から引ける | 1 時間 | Makefile |
| テンプレートのテストの前に fpkg が新しいか分からない | 選ぶ道具が engine 側の差を見たら先に `sync-engine-full` を流す | 古い fpkg で緑になる誤りが無くなる | 30 分 | Makefile |
| GPU の門は場面ごとに絞れない | gl-capture-check の SKIP= を、届いたテンプレートの場面だけにする | テンプレートの中の変更なら 12 分 → 4 分前後 | 1 時間 | Makefile |

テストが読むファイルを 1 つの入口（`TestData.path` のような物）へそろえる案は採らない。str_lit から引けるので、engine の pub 面をテストのためだけに増やさなくてよい。

---

## 5. 案（最小・中・大）

3 案とも共通の決まり:

- 入口は `bin/fge test-select [--base <ref>] [--files …] [--explain] [--json]`（go の道具。engine/ ではない）と、それを流す `make verify SUITE=affected`（受け口は gates.json の suite にある。今は test に倒す）。
  base の既定は `HEAD`（作業ツリーの差分 + 未追跡）。
- 出す物は「流す門の一覧」と「なぜ選んだか（どの変更 → どの宣言 → どのパッケージ・テスト・門）」。`--explain` で人が読める形にする。
- **順番**: (1) engine 側（4 パッケージの src）に差があれば `sync-engine-full`（約 14s）→ (2) 下流を全部型検査 → (3) 索引を作り直す（古ければ）→ (4) 呼び手をたどる → (5) 門を流す。
- **必ず流す物**: precommit の素振り（`bin/fge precommit --files …`）と、触ったパッケージと下流の型検査（checkd・テストを含む。常駐が起きていれば 1 本 1 秒前後、起きていなければ 10〜20 秒）。
  木に入れなかったテストや下流が組めなくなる誤りは、ここで拾う。
- **安全側の決まり（どれか 1 つでも当たれば、そのパッケージと下流を全部流す）**:
  1. 表のどの行にも当たらない変更（パッケージを持たないファイルを含む）
  2. Makefile・mk/・bin/ の sh・.github・lib/・flix.toml（パッケージの `version =` の行だけの差は除く）
  3. 変わった行が def・enum・型 alias のどれの範囲にも入らない（instance・trait・`eff`・mod の頭の use など）。**ただしコメントと空行だけの差は型検査だけ**
  4. その木の索引を作れない・索引が作業ツリーより古いのに作り直せない・道具が途中で落ちた
  5. （案 C）選んだテストのファイルの実行時間が、そのパッケージの `.test-logs` の 6 割を超える
  6. （案 C）テストの helper のファイル（Kit・Fixtures）の変更 → そのパッケージのテスト全部
- release の全量の門は今のまま（絞らない）。

### 案 A（最小）: パッケージ単位の表

仕組み:
- 差分のファイル → 表（根の gates.json の input）の glob → パッケージ → 依存の向きで下流のパッケージ（engine → 3 層 → engine_full → テンプレート・game-starter・bench）
- 流す物: 当たったパッケージの flix test 全部と、表に書いた門（テンプレートなら render-changed・determinism のそのテンプレート、render_gl なら gl-parity、engine の pub 面なら new-game の確かめ、go/ なら表の go の行）
- engine の pub 面が変わったかは、変わった宣言が pub か（`def.tsv` の pub の欄）と、`bin/fge api-digest --check` に差が出たかの両方で見る。どちらかが当たれば new-game の確かめ（game-starter を作業場へ写して check → test。時間は不明・測ってから表に入れる。5 種の表では T3・T4・T6 の engine の pub の def を変えた時だけ足す）
- 文書だけの変更はテストを流さない（precommit と check-docs-sync だけ）

効果: 層どうしが互いを見ないので「engine_world を直したら render_gl と engine_tools は流さない」が取れる。テンプレートだけの変更で engine のテストを流さない。
engine 側の変更ではテンプレートが全部残るので、時間は rpg-starter の 1分52s で決まる。

手間: 3〜4 時間（表・go の道具・make の入口）。engine の拡張ではない。

### 案 B（中・推す案）: 宣言の呼び手をたどって、パッケージ・テンプレート・門の単位で外す

仕組み（A の上に足す。テストのファイル単位の木は作らない。流すパッケージのテストは全部）:
1. 差分の hunk → 変わった行を含む宣言（def・enum・型 alias）。範囲は refactor の宣言の索引（`show` の file:始め-終わり）から引く。入らない行は安全側の 3。
2. 宣言 → 根の索引で呼び手を最後までたどる（`usages --callers` の ref と call 両方・depth は増えなくなるまで）。enum は全部の case の使われ所も数える。消した・名前を変えた・型を変えた宣言は、下流がまだ使っていれば sync の後の下流の型検査で組めなくなるので、base の索引は引かない（base の木を別に checkout して索引を作る手間に見合わない）。
3. 届いた engine の def の集まりを、各テンプレート（と索引の作れる bench）の facts（`calls.tsv`・`def.tsv`）と一度に突き合わせる（def ごとに refactor を引くと、Color.rgb のような広い変更で 138 ファイル分 × テンプレート 4 本 × 0.13s になるため）。1 つも届かないテンプレートは外す。索引の無い木は外さない（安全側の 4）。届いた engine の def が 200 を超えたらテンプレートは外さない（突き合わせの誤りで大きく漏れるのを避ける）。道具の時間は数秒と見て、5 種の表の B・C に含めた。
4. 届いたパッケージ（根の 4 つ・テンプレート・bench）のテストを全部流す（test-par と同じ並べ方）。
5. flix test 以外の門は、届いた所で選ぶ:
   - bench/gl_parity の木の def に届いた → gl-parity（今は索引を作れないので、engine 側の変更ではいつも流す）
   - テンプレートの src・assets に届いた → そのテンプレートの render-changed・determinism（main に届いた時。実際はほぼ毎回）
   - render_gl の WebGPU の def に届いた → webgpu-v1-check・gl-capture-check（場面は届いたテンプレートだけ）
   - 表の規則（3 節の表）は A と同じ

効果: engine 側の変更で、届かないテンプレート（特に rpg-starter の 1分52s）を外せる。下の表。

最初に確かめる事: `usages --callers --json` が `--max` `--limit` の既定で途中を切らないか（切るなら道具が旗で外す）。ここを外すと何も知らせずに漏れる。

手間: A の後に 5〜7 時間（宣言の範囲・呼び手を最後までたどる・テンプレートの索引で引き直す・trees-skip.json を見る・base の索引）。
索引を作れない木を直す仕事（4 節の 1 行目・2〜4 時間）を入れないと、engine の変更で gl-parity・hd2d・web の門が外れない。
engine の拡張ではない（go の道具と make の入口）。新しい仕組みなので agents-pack の早見表に 1 行と agent-eval のお題を 1 本足す。

### 案 C（大）: B + テストのファイル単位の木 + 作りの直し

B に足す物:
- 届いたテストの def → そのファイル → helper のたどり（calls.tsv の向きつき）と mod の親子のまとめ → `build/test-select/<パッケージ>/` に、パッケージの根の物を全部と src 全部、選んだテストのファイルを張った木を作り flix test。
  - 木は毎回作り直す（前の build/ を残さない）。sample-test は道具が自分で入れる
  - **張る先を realpath で見て、repo の中（src・test）に入る時は止める**（9 節の事故を防ぐ）
- テストの helper の決まり（Kit・Fixtures に pub・他のテストのファイルの非 pub を使わない）を lint で止め、engine/test と層の test を直す → mod の親子のまとめが要らなくなる
- rpg-starter の Fixtures の起動を測って共有する（絞りと別に release の門も縮む）
- 結果のキャッシュ: テストのファイルごとに「届く宣言の中身のハッシュが前の緑と同じなら流さない」（go test の cache と同じ考え方）

効果: 実行が重い rpg-starter と層の重いファイルで縮む（rpg-starter の 1 ファイル分は 1分52s → 18s 前後）。それ以外のパッケージはコンパイルが大半なので縮みは小さい。

手間: B の後に 1.5〜2 日分（実時間 10〜14 時間）。**engine/test・層の test を広く触るので相談事**（7 節）。

### 典型的な変更 5 種の時間

列の意味:
- 「今のやり方」: AGENTS.md のとおり、触ったパッケージだけ `make test-<name>`（他は型検査）。速いが、下流の退行は release まで見ない
- 「全部」: その変更で影響しうる門を安全側に全部（sync + テスト + 描き出し + determinism + gl-parity）。GPU の門（gl-capture 12 分・webgpu-v1 64s）は別に書く
- 数字は 1・2 節の記録から足した見込み。並べて流せる物は長い方。型検査（10〜30s）と索引の作り直し（テンプレート 1 本 初回 5.7s・根は測っていない）は A〜C に含めた

| 変更 | 今のやり方 | 全部 | 案 A | 案 B | 案 C |
|---|---|---|---|---|---|
| T1 文書だけ（docs/・plans/ の .md） | precommit だけ（数秒） | 約 2分34秒 | precommit + check-docs-sync（数秒） | 同 A | 同 A |
| T2 rpg-starter の src の def 1 つ（例: Battle） | test-rpg 1分52s（1 本だけならもう少し短い） | test 1分52s + render 16s + determinism 約 70s = 約 3分20秒 | 同「全部」 | 同 A（テンプレートの中の変更は、そのテンプレートが丸ごと残る。描き出しと determinism も main に届くのでほぼ毎回） | テスト 18s 前後 + render 16s + determinism 70s = 約 1分50秒 |
| T3 engine_world の def 1 つ（例: Timeline.atStartOf） | test-engine_world 48s。テンプレートは流さない | sync 14s + test-par-all 1分52s + render-all 150s + determinism 3分32s + gl-parity 18s = 約 8分30秒 | engine と他の 2 層を外すだけ = 約 8分 | sync 14s + 型検査 20s + テスト（engine_world 48s・sound-novel 35s・hd2d 45s（facts が無く外せない）を並べて）48s + render（novel 29s・hd2d）+ determinism（novel）70s + gl-parity 18s（索引が無く外せない）= 約 3分30秒〜4分。索引を直せば hd2d と gl-parity が外れて約 3分 | B とほぼ同じ（engine_world を 6s に縮めても hd2d の 45s が残る） |
| T4 render_gl の WGSL 1 本（例: sprite の shader） | test-render_gl 47s | 約 8分30秒 + GPU の門 約 13分 | 同「全部」 | sync 14s + 型検査 20s + test-render_gl 47s + gl-parity 18s + determinism 3分32s（隠しウィンドウで描くので main から届く）= 約 5分10秒 + GPU の門 約 13分（sprite はどの場面も使うので場面で絞れない） | render_gl を 20s 前後に = 約 4分40秒 + GPU の門 |
| T5 go/ の 1 パッケージ（例: internal/precommit） | 流さない事が多い | `go test ./...` 全量（不明・数分）+ go-build | go の表: そのパッケージと頼る側の go test（go の cache で 2s〜数十秒）+ go-build + precommit の素振り。yarn なら engine_world のテスト 48s も | 同 A | 同 A |
| 参考 T6 engine/src の広く使う def（例: Color.rgb。根のテスト 87 ファイルに届く） | test-engine 29s | 約 8分30秒 | 約 8分30秒 | 届くテンプレートがほぼ全部 = 約 8分 | 安全側の 5 で全部 = 約 8分 |

見立て:
- B で一番縮むのは T3（engine 側の局所的な変更）で、「全部」の約 8 分半 → 3〜4 分。今のやり方（48s）より遅いが、今は見ていないテンプレートの退行を作業中に拾える。
- T2 は B では縮まない。縮めるには C（rpg-starter をファイル単位に）か、rpg-starter の Fixtures の起動を直す（4 節）。
- T4 は GPU の門と determinism が支配的で、テストの絞りでは縮まない。
- T1・T5 は A で足りる。

---

## 6. 答え合わせ（使い始める前に）

### 6.1 使う過去のコミットと、落ちるテストの作り方

全部緑のコミットでは答え合わせにならないので、落ちる物を次の順で集める。

1. **本当の赤（最初に・一番の証拠）**: v0.95.0 以後で件名に「落ち」「赤」「直す」を含む 120 本を候補に、親で全部流して赤、そのコミットで緑になった物を探す。
   赤を持ち込んだコミット（緑 → 赤の境目）を二分探索で見つけ、その差分に選ぶ道具をかける。まず件数を確かめる（少なければ下の 2・3 で補う）。
2. **src を戻す**: v0.95.0 以後で .flix を触った 313 本のうち、src とテストを同じコミットで直した 209 本。コミット C の、テストでない .flix の hunk だけを C^ に戻し、テストは C のまま残した木 X を作る。
   差分 D = C → X に選ぶ道具をかけ、X で全部流した結果と比べる。
   - 偏りがある: 落ちるのは C で直したテスト、つまり変えた def を直接呼ぶテストにほぼ限られる。C で足したテストは消えた def を呼んで組めなくなり、これは型検査が拾う
3. **わざと作る例**: 3 節の表の行ごとに最低 1 本。JSON の値・test/data の中身・instance の本文・enum の case と `case _` の match・gen-light3d の元・bench-common の写し・shader.json・
   go の yarn の testdata・project.json の textures。呼び手を 6 階層以上たどる def の例も 1 本入れる。さらに、呼び手が複数のパッケージや木にまたがる def で、数のリテラル 1 つ・if の向き 1 つ・比べる記号 1 つを書き換える。

版を上げるだけのコミット（bump）と、40 ファイルを超える大きなコミット（9 本）は別に数える。

### 6.2 拾い漏れの定義と数え方

- テストの単位は「テストの def の名前」。X で全部流して落ちたテスト t が、選んだ範囲（案 B ならパッケージ、案 C ならファイル）で流れず、かつ必ず流す型検査（下流まで）でも赤にならなかったら**拾い漏れ**。
- 拾えた物は 2 つに分けて数える: **型検査で拾った**（組めない）と**選んで拾った**（流して落ちた）。使い始める条件は後の方だけで数える。
- flix test 以外: 描き出しは、X と C で gallery の SHA が違うテンプレートの集まり G を作り、G を描き出しに選んでいなければ拾い漏れ（render の作り置き（FGE_RENDER_CACHE）は止めて描く）。
  gl-parity は X と C の両方で流し、結果が違うのに選んでいなければ拾い漏れ。determinism・gl-capture は重いので 10 コミットだけ抜き取る。
- go: v0.95.0 以後で go/ を触った 83 本も、src を戻すのと同じ形で台に入れる。全部の `go test ./...` で落ちた go のテストのパッケージを選んでいなければ拾い漏れ。go の表で選んだ flix の門（yarn の testdata → engine_world など）も同じ。
- new-game: X と C で new-game の確かめの結果が違うのに選んでいなければ拾い漏れ。webgpu-v1-check は GPU の要る 10 コミットの抜き取りに入れる。
- 不安定なテスト: 「全部」は 2 回流し、両方で落ちた物だけを数える。
- 安全側に倒れて全部流したコミットは拾い漏れ 0 が当たり前に出る。**倒れた割合**と**選んだ時間 ÷ 全部の時間**を出し、条件は絞れたコミットだけで数える
  （昔のコミットほど今の道具で索引を作れず、倒れる割合が高いはず）。
- 「落ちるテストが 1 本も出なかったコミット」は証拠に数えない（別に数を出す）。

### 6.3 流し方

- worktree を立て `make worktree-seed`。`bin/fge test-select-replay --range v0.95.0..HEAD [--sample N] [--mode red|revert|inject]` が各コミットで X を作り、
  sync → 全部（2 回）→ 選んだ物、の順に流して JSON に残す。
- **全部の結果は規則に依らないので残しておく。** 規則を直した後の流し直しは、選ぶ道具と「選んだ物を実際に流す」だけでよい
  （選んだ物を実際に流すのは、木の作り・cwd・build/ の残りで結果が変わらないかを見るため）。
- `bin/fge heavy --long` の枠で夜に流す（他の担当と CPU を食い合わない）。1 本 約 9 分（全部 2 回 5 分 + 描き出し 2.5 分 + 索引の作り直し + 選んだ物 1 分）× 60 本で約 9 時間。
- 出す物: コミットごとの「落ちたテスト・型検査で拾った・選んで拾った・拾い漏れ・倒れたか・全部の時間・選んだ時間」の表。

### 6.4 使い始める条件と、0 件が示す事

- 絞れたコミットのうち、**選んで拾った**テストが出たコミットが 40 本以上・その合計が 100 本以上で、拾い漏れ 0。かつ、6.1 の 3（わざと作る例）が全部拾えている。
- 門ごとに「確かめた / まだ」を分けて持つ。まだの門は、使い始めた後も表で選ばず、当たりうる変更では全部流す。
- 0 件が示すのは「漏れの割合がおよそ 3/N 未満（95%）」まで（rule of three）。落ちるテストはコミットごとにまとまって出るので N はコミットの数で、40 本なら 7.5% 未満。
  表の珍しい行は 1 回も試されないまま通りうるので、6.1 の 3 で行ごとに 1 本ずつ当てる。
- 拾い漏れが出たら、規則を直し（多くは 3 節の表に 1 行）、残しておいた全部の結果に対して選び直す。
- 使い始めた後も release の全量の門はそのまま。release で赤が出て、その原因の変更を選ぶ道具が拾っていなかったら、その例を答え合わせの台に足す。

### 6.5 答え合わせの手間

- test-select-replay（X を作る・全部を 2 回流す・gallery の SHA を比べる・JSON を書く）を作るのに 4〜6 時間。
- 機械の時間は 1 晩（60 本）〜3 晩（209 本と本当の赤の二分探索）。

---

## 7. 推す案と相談事

**推す案は B（A を先に入れてから B を足す）。** 理由:
- engine 側の局所的な変更（T3）で「全部」の約 8 分半 → 3〜4 分。今のやり方では release まで見ていないテンプレートの退行を、作業中に拾えるようになる。
- 呼び手のたどりは refactor の索引でもう動く（1 回 0.2〜0.3 秒）。新しく作るのは go の道具と make の入口だけで、engine/ を触らない。
- テストのファイル単位の木（C）が持つ危険（cwd・sample-test・build/ の残り・mod の親子・張る先の事故）を持たない。B は今の `make test-<name>` と同じ形でパッケージを流すだけ。
- 安全側の決まりが多い分、拾い漏れの多くは「全部流す」に倒れる。答え合わせで漏れが出ても、直す所は表の 1 行か呼び手のたどりに限られる。
- C は、B の答え合わせで「rpg-starter が残る変更」が多いと分かってから入れる。それより先に、rpg-starter の Fixtures の起動を測る方が安い（release の門も縮む）。

進め方と実時間:
1. A（3〜4 時間）
2. 索引を作れない木を直す・`--json` に引かなかった木を出す（2〜4 時間）
3. B（5〜7 時間）
4. test-select-replay（4〜6 時間）と答え合わせ（夜 1〜3 回）
5. 漏れ 0 で `make verify SUITE=affected` を作業中の既定の確かめにし、AGENTS.md の検証の節と testdata/agent-eval/engine-repo.json のお題を足す（engine のリポだけの口なので agents-pack には入れない）

相談事（人に決めてほしい事）:
1. 案 C の「テストの helper の決まり」を engine/test・層の test に入れるか（engine の層の作りの決まりを増やす。lint が 1 本増える）。B の答え合わせの後に決めればよい。
2. ~~門の入力の表を precommit.json を広げて持たせるか、別のファイルにするか~~ → 根の gates.json に決めた（plans/gates-tidy.md・配る物の都合）。
3. 答え合わせの機械の時間（夜 1〜3 回）を使ってよいか。

---

## 8. 図に描ける形（ノードと矢印）

### 8.1 門と依存

ノード（パッケージ・入力）:
- P.engine・P.render_gl・P.engine_world・P.engine_tools・P.engine_full（fpkg）・P.templates（hd2d・rpg・sound-novel・tidepool）・P.game-starter・P.bench（gl_parity・scene3d・webgpu_v1/v2・webgpu_check）・P.go
- I.java（render_gl/java）・I.web（engine_web）・I.shaderjson（templates/*/assets/*.shader.json）・I.docjson（templates/*/assets/*.json・project.json）・I.engine-testdata（engine/test/data）・I.testdata（testdata/・go/internal/yarn/testdata）・I.font・I.reference（reference/SHA256SUMS.txt）・I.baseline（bench/baseline）・I.make（Makefile・mk・bin・flix.toml・lib）・I.rules（bin/lint-rules・docs/check-codes.md・agents-pack）

矢印（A → B は「A が変わると B が影響を受ける」）:
- P.engine → P.render_gl・P.engine_world・P.engine_tools・P.engine_full
- P.render_gl・P.engine_world・P.engine_tools → P.engine_full
- P.engine_full → P.templates・P.game-starter・P.bench
- P.engine（LightModel3d）→ P.engine_tools（gen-light3d の生成物）
- bench/common → bench/sprite_stress・crowd2d・scene3d（写し）
- I.java → P.render_gl・P.engine_full
- I.shaderjson → G.test-render_gl（TestWgslDawn）・P.templates
- I.engine-testdata → G.test-engine・G.test-render_gl（TestDrawHash）
- I.font → G.test-engine_tools
- I.testdata → G.test-engine_world・G.determinism
- I.docjson → P.templates
- P.go → G.go-test・道具を使う門（G.precommit・型検査・G.render・G.determinism）・I.testdata（yarn）
- I.rules → G.precommit・G.go-test
- I.make → すべての門

ノード（門）と、門が頼るパッケージ:
- G.test-engine ← P.engine + I.engine-testdata
- G.test-render_gl ← P.engine + P.render_gl + I.shaderjson + I.engine-testdata
- G.test-engine_world ← P.engine + P.engine_world + I.testdata
- G.test-engine_tools ← P.engine + P.engine_tools + I.font
- G.test-<テンプレート> ← P.engine_full + そのテンプレート + I.docjson
- G.new-game ← P.engine_full + P.game-starter
- G.render / G.reference-check ← P.engine_full（engine_tools の SoftRaster）+ テンプレート + I.docjson + I.reference
- G.determinism ← P.engine_full + rpg・sound-novel・tidepool + I.docjson + testdata/determinism
- G.gl-parity ← P.engine_full + bench/gl_parity
- G.gl-capture ← P.engine_full + テンプレート 3 本 + bench/scene3d + I.baseline
- G.webgpu-v1 ← engine_full/src + bench/webgpu_v1・v2 + I.web
- G.go-test ← P.go + I.rules
- G.precommit・G.check-docs-sync ← すべての変更（引き金は拡張子と場所）

### 8.2 差分から門を選ぶ流れ（案 B）

1. S.diff（git の差分 + 未追跡）→ S.classify（表で持ち主を引く）
2. S.classify → S.fallback（表に無い・持ち主の無いファイル・Makefile・flix.toml・lib・索引が無い/古い）→ R.all（そのパッケージと下流を全部）
3. S.classify → S.docs（.md だけ）→ R.precommit-only
4. S.classify → S.go（go/）→ R.go-table（go のパッケージ → 門）+ R.go-build
5. S.classify → S.java（render_gl/java）→ R.all（render_gl と下流）
6. S.classify → S.flix（.flix）→ S.comment-only（コメントと空行だけ）→ R.checkd だけ
7. S.flix → S.hunk-to-decl（宣言の範囲）→ S.fallback（宣言の外の行）
8. engine 側の差 → R.sync（sync-engine-full）→ R.checkd-downstream（下流を全部型検査）
9. S.hunk-to-decl → S.callers-root（根の索引で最後まで・base の索引も）
10. S.callers-root → S.callers-tree（届いた engine の def を各テンプレート・bench の索引で引く）
11. S.classify → S.asset（Doc の JSON・shader.json・test/data・font・testdata）→ S.rules（str_lit から作った表 + 手書きの規則）
12. S.callers-root・S.callers-tree・S.rules → S.packages（届いたパッケージ）→ R.package-test（パッケージのテスト全部を並べて）
13. S.callers-tree・S.rules → S.entries（bench の木・テンプレートの main・WebGPU の def に届いたか）→ R.gates（gl-parity・render・determinism・gl-capture の場面・new-game）
14. いつも: S.diff → R.precommit（素振り）

### 8.3 案ごとの違い

- 案 A: S.diff → S.classify → S.package（glob → パッケージ）→ S.downstream（依存の向き）→ R.package-test + R.gates（表）
- 案 B: 案 A の S.downstream の代わりに S.hunk-to-decl → S.callers-root → S.callers-tree → S.packages。門は S.entries で選ぶ。流す単位はパッケージのまま
- 案 C: 案 B の R.package-test の代わりに S.tests（届いたテストの def）→ S.files（ファイル + helper + mod の親子）→ R.subset-tree（build/test-select/<パッケージ>）→ R.flix-test。
  加えて X.helper-rule（helper の決まり）・X.fixtures（rpg-starter の起動の共有）・X.result-cache（届く宣言のハッシュが前の緑と同じなら流さない）

---

## 9. この調べでの注意（事実）

- 調べの途中、rpg-starter のテストだけの木を作る時に、先の `src` がまだ `templates/rpg-starter/src` を指すフォルダの symlink のまま link-tree を流し、
  `templates/rpg-starter/src` の 70 ファイルを自分を指す symlink に書き換えてしまった。すぐ `git checkout -- templates/rpg-starter/src` で戻し、
  `git status` で差が無い事と、git の上では 100644 の普通のファイルである事を確かめた（調べ始めの時点で rpg-starter に未コミットの差は無かった）。
  案 C の木の作りでは、張る先を realpath で見て repo の中に入る時は止める（5 節の C）。link-tree.sh 自身に同じ守りを足すのも候補。
- .claude/skills/release/SKILL.md の一部（`make -C templates/* bench`・`make sync-<name>`・`make test-par`）が今の Makefile と合わない。この設計の外だが直す候補。

---

## 10. レビュー

1 回目（別のサブエージェント）: **72 点**。主な必須の指摘と直した所:
- テンプレートの src を symlink と書いた事実の誤り（9 節の事故の後の状態を見ていた）→ 消して 9 節とつないだ
- 6 割の決まりと T3 の数（sound-novel は 22 ファイル・Elapsed 8.7s）が合わない → 6 割は実行時間で数える・T3 を直した
- 索引を作れない木（bench 4 本・engine_web・hd2d の facts 無し）を T3・T4 に入れていない・その事が `--json` に出ない → 表に入れ、道具が trees-skip.json を見る・直す仕事を手順に入れた
- 「今」の列が今のやり方（触ったパッケージだけ test）ではない → 「今のやり方」と「全部」の 2 列にした
- テストが読むファイルの洗い出し不足 → str_lit から作る・パッケージをまたぐ物を足した
- ファイル単位の木の穴（cwd のデータ・sample-test・build/ の残り・張る先の事故）→ 案 C に移し、決まりとして書いた
- 消した宣言・木をまたぐたどり・`--depth` の既定 → 下流の型検査・base の索引・根で最後までたどってからテンプレートの索引で引く・depth の実測を書いた
- go/ の扱いの矛盾・game-starter（new-game）の抜け・パッケージを持たないファイル・flix.toml の版の行 → 表と決まりに足した
- 答え合わせが拾い漏れ 0 を示せない → 本当の赤を先に・わざと作る例を表の行ごとに・型検査で拾った物と選んで拾った物を分ける・倒れた割合・2 回流す・rule of three を書いた
- 任意の指摘から: 案の組み替え（B はパッケージ単位で木を作らない）・`TestData.path` を採らない・precommit.json を広げる・全部の結果を残して選び直しを軽くする・コメントだけの差は型検査だけ

2 回目: **87 点**。残った必須 3 つと直した所:
- 答え合わせが go の表・new-game・webgpu-v1-check の選び方を確かめていない → go/ の 83 本を台に入れ、拾い漏れの定義に go と new-game を足し、門ごとに「確かめた / まだ」を分けた
- B の道具の時間と作り方の穴（def ごとにテンプレートの索引を引くと遅い・base の索引の作り方・`--max` `--limit`）→ facts と一度に突き合わせる・200 を超えたら外さない・base の索引はやめて下流の型検査に任せる・切られないかを B の最初に確かめる
- engine の pub 面の判定が無い → 宣言の pub の欄と api-digest の差で見る・new-game の確かめの時間は測ってから入れる
