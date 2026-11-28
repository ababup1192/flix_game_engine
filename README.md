<p align="center">
  <img src="docs/brand/flix_ge_banner.png" alt="Flix_GE" width="680">
</p>

<p align="center">
  <a href="https://ababup1192.github.io/flix-ge-lp/"><img src="https://img.shields.io/badge/Landing_Page-Demos_%26_Benchmarks-ff6a3d?style=for-the-badge" alt="Landing Page"></a>
  <a href="https://github.com/ababup1192/flix_game_engine/releases/latest"><img src="https://img.shields.io/github/v/release/ababup1192/flix_game_engine?style=for-the-badge" alt="Latest release"></a>
  <a href="LICENSE.md"><img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="MIT License"></a>
</p>

<p align="center">
  <b>English</b> · <a href="#flix-game-engine-日本語">日本語</a>
</p>

# Flix Game Engine

**Turn AI speed into game quality.**

An AI-native **2D, HD-2D, and 3D game engine** written in [Flix](https://flix.dev/).
One codebase ships to **Desktop (macOS / Windows / Linux)** and **Web / mobile browsers (WebGPU + WebAssembly)**.

### 👉 [Visit the landing page](https://ababup1192.github.io/flix-ge-lp/) — playable showcase, the AI workflow in pictures, honest benchmarks, and a comparison with other engines.

This README covers installing, the starter templates, and working on the engine itself.

## Why it works so well with AI

- **Machine-verified changes** — game logic is pure functions over an immutable `World`. Flix's type & effect system, automated replays, 1px pixel-diff checks, and pre-publish browser checks catch what an AI breaks before you have to look.
- **Tape video review (`make tape`)** — an auto-play video you annotate on a timeline (phone or desktop); it becomes a structured fix prompt for the AI.
- **`F8` annotate & HitchDetector** — box anything in a running game and the screenshot, coordinates, and the state needed to reproduce it go to the AI. Frame hitches are recorded with repro steps.

Everything is built in — 3D PBR / HD-2D / retro 3D, 2D terrain & VFX, deterministic 2D physics, JSON-declared UI, Yarn dialogue, a sound synth & mixer, and `fge export-web`. See the [capabilities on the LP](https://ababup1192.github.io/flix-ge-lp/#capabilities) or the full [module index](docs/module-index.md).

## Play in your browser

| Title | Genre / Tech | Link |
|---|---|---|
| **Internet Saihate Dungeon** | 2D deck-building / combo battle | [▶ Play / LP](https://ababup1192.github.io/internet-saihate-dungeon-lp/) |
| **Night School** | First-person PS1-style 3D horror | [▶ Play](https://ababup1192.github.io/night-school/play/) |
| **Stepdown** | Vertical mobile roguelike (PWA) | [▶ Play](https://ababup1192.github.io/stepdown/) |
| **Haioku Live** | Vertical horror visual novel | [▶ Play](https://ababup1192.github.io/haioku-live/) |
| **Home Tape** | Vertical visual novel | [▶ Play](https://ababup1192.github.io/home-tape-live/) |
| **Collision & JSON Doc sample** | Physics2D colliders & live-reload Docs | [▶ Play](https://ababup1192.github.io/fge-collision-sample/) |
| **Bistro 3D Street** | 3D PBR, 2.83M triangles, WebGPU | [bistro-lab](https://github.com/ababup1192/bistro-lab) |

More, with screenshots: **[showcase on the LP](https://ababup1192.github.io/flix-ge-lp/#showcase)**.

## Getting started

You need [Claude Code](https://claude.com/claude-code) (or another AI coding agent) and `git`.

**macOS / Linux** — also `make` and `perl` (on macOS, `xcode-select --install` gives you all three):

```bash
curl -fsSL https://github.com/ababup1192/flix_game_engine/releases/latest/download/install.sh | sh
```

**Windows** (PowerShell) — needs [Git for Windows](https://gitforwindows.org/) (`winget install --id Git.Git -e`):

```powershell
irm https://github.com/ababup1192/flix_game_engine/releases/latest/download/install.ps1 | iex
```

Then open the dashboard:

```bash
fge dashboard        # opens http://127.0.0.1:8790/
```

On the "Make a new game" card, pick a name and a template and press **Open in Claude Code**.
Claude starts in your games folder (`~/flix-games`), creates the game with `fge new`, checks
that it runs, and tells you what to do next. The engine and the JDK are downloaded into
`~/.flix_ge` the first time.

Without the dashboard:

```bash
fge new --list                             # the templates
fge new my-game --template rpg-starter     # create ./my-game (its own git repository)
cd my-game && make run                     # play it (make test runs its tests)
```

## Starter games (templates)

Each template is a complete, playable game with its own art style, Docs, and tests.

| Template | Description |
|---|---|
| **game-starter** | The bare skeleton: move a pixel-art hero with the arrow keys. The default for `fge new` |
| **rpg-starter** | FC-style classic RPG: a village whose spring has run dry, a world map, a mine dungeon and command battles |
| **sound-novel-starter** | Sound novel in the countryside: blurred photos, Mincho prose with ruby, NVL/ADV, log, auto, skip, save/load — scripted in Yarn |
| **tidepool-starter** | Turn-based tide-pool puzzle: push rocks to reroute channels as the tide moves each turn; undo, retry and a look-ahead preview |
| **hd2d-starter** | HD-2D town walk: a 3D harbor town from a tile map with pixel-art billboards, a following party, sun shadows and depth of field |
| **retro3d-horror-starter** | First-person retro 3D horror in a wooden school at night: PS1-style look, baked vertex lighting, conversations, keys and locked rooms |

## Game data (Docs)

Numbers, looks, and layouts live outside the code in JSON **Docs** (`<name>.<kind>.json`,
e.g. `grass.theme.json`). Behavior — rules, collision, spawning — stays in code. Each kind has a
`<kind>.schema.json` that drives editor forms, startup validation, and AI-written data, and a game
watching its Docs with `App.watchFile` picks up a save while it runs.
See [docs/doc-conventions.md](docs/doc-conventions.md).

## Working on the engine itself

Everything above uses an engine downloaded by `fge`. To change the engine, clone this repository.
You need **devbox** (it fetches JDK 25, GNU make, and the Flix 0.80.0 compiler); macOS or Linux.

```bash
devbox shell         # toolchain + bin/ on PATH
make sync            # build all engine packages and link them into templates & bench (run once first)
make go-build        # build bin/fge from go/
make status          # one-screen summary of where things stand
make help            # every other target
```

Re-run `make sync` after editing an engine package. Run a template with
`cd templates/<name> && flix run` (`flix test` for its tests). To make a game from this clone:

```bash
make new-game GAME=/abs/path/to/mygame NAME=mygame TITLE="My Game" TEMPLATE=rpg-starter
```

```
engine/        contract layer, no native deps: Platform effects (Input, Window, Draw2d, ...), Audio, shared render types, math, color, text layout
render_gl/     desktop backend: LWJGL window/input/audio, WebGPU (Dawn) & OpenGL 3.3 renderers, shaders, SDF fonts
engine_web/    browser backend: TeaVM (WasmGC), WebGPU / WebGL2, Web Audio
engine_world/  game framework: Bevy-style App loop, ECS queries, physics, UI, camera rig, undo/replay, assets, save data
engine_tools/  dev & test tooling: headless rasterizer, filmstrips/GIFs, render lint, SFX synth
engine_full/   bundles the packages into the single `flix_game_engine` package games depend on
templates/     starter games (copied by fge new / make new-game)
go/            the fge CLI (dashboard, export-web, refactor, checkd, lints, ...)
bench/         benchmarks and test scenes
```

Contributor rules (naming, testing, art floor, release) are in [AGENTS.md](AGENTS.md).
The startup splash and on-demand glyph baking are described in [docs/startup-screen.md](docs/startup-screen.md).

> The companion editor **[flix_ge_studio](https://github.com/ababup1192/flix_ge_studio)** is frozen for now. If you have it, do not let its self-update move it to a newer engine: a frozen Studio cannot run newer engine releases.

## Tech stack

- **Flix 0.80.0** — functional language with static effect tracking
- **WebGPU** (Dawn on desktop / browser) by default, falling back to **OpenGL 3.3 Core** (desktop) or **WebGL2** (browser)
- **TeaVM** — WebAssembly (WasmGC) export for browsers & mobile PWA
- **LWJGL** — GLFW / OpenGL / STB / OpenAL / SDL3 gamepad
- **OpenAL / Web Audio** — sound

## License

[MIT License](LICENSE.md)

---

# Flix Game Engine (日本語)

**AIの速さを、ゲームの完成度へ。**

[Flix](https://flix.dev/) で書く **AI ネイティブな 2D / HD-2D / 3D ゲームエンジン**。
1 つのコードベースから **PC（macOS / Windows / Linux）** と **Web / スマホブラウザ（WebGPU + WebAssembly）** へ届けます。

### 👉 [紹介ページ（LP）を見る](https://ababup1192.github.io/flix-ge-lp/) — ブラウザで遊べる作品、AI 開発ループの図解、実測ベンチマーク、他エンジンとの比較はこちら。

この README は、インストール・スターターテンプレート・エンジン自体を直す人向けの手順をまとめています。

## なぜ AI と作りやすいのか

- **壊れたら機械が止める** — ゲームロジックは不変の `World` に対する純粋関数。Flix の型と副作用検査・自動リプレイ・1px 単位の画素差・Web 公開前の実ブラウザチェックが、AI の書いた変更を人が見る前に検算します。
- **Tape 動画レビュー（`make tape`）** — 自動プレイ動画をスマホや PC で観ながらタイムラインに注釈を付けると、AI 向けの修正プロンプトになります。
- **`F8` 画面囲み ＆ 処理落ちの自動記録** — 動いているゲームで気になる所を囲むだけで、スクショ・座標・再現に要る状態を AI へ渡せます。処理落ちも再現手順ごと記録します。

3D PBR・HD-2D・レトロ 3D、2D の地形とエフェクト、決定論的な 2D 物理、JSON で書く UI、Yarn の会話、効果音シンセとミキサー、`fge export-web` まで標準で入っています。
一覧は [LP の機能紹介](https://ababup1192.github.io/flix-ge-lp/#capabilities) か [docs/module-index.md](docs/module-index.md)。

## ブラウザで遊べる作品

| 作品 | ジャンル / 技術 | リンク |
|---|---|---|
| **インターネット・サイハテ・ダンジョン** | 2D デッキ構築・コンボバトル | [▶ Play / LP](https://ababup1192.github.io/internet-saihate-dungeon-lp/) |
| **夜の校舎** | 一人称 PS1 風 3D ホラー | [▶ 遊ぶ](https://ababup1192.github.io/night-school/play/) |
| **片手間迷宮** | 縦型スマホ向けローグライク（PWA） | [▶ 遊ぶ](https://ababup1192.github.io/stepdown/) |
| **廃屋配信** | 縦型ホラーノベル | [▶ 遊ぶ](https://ababup1192.github.io/haioku-live/) |
| **よその子** | 縦型ノベル | [▶ 遊ぶ](https://ababup1192.github.io/home-tape-live/) |
| **当たり判定 ＆ JSON Doc サンプル** | 2D 物理のコライダーと設定の即反映 | [▶ 遊ぶ](https://ababup1192.github.io/fge-collision-sample/) |
| **Bistro 3D 街並み** | 3D PBR・283 万三角形・WebGPU | [bistro-lab](https://github.com/ababup1192/bistro-lab) |

画面つきの一覧は **[LP のショーケース](https://ababup1192.github.io/flix-ge-lp/#showcase)** へ。

## 始め方

[Claude Code](https://claude.com/claude-code)（または他の AI エージェント）と `git` が要ります。

**macOS / Linux** — `make` と `perl` も要ります（macOS は `xcode-select --install` で 3 つとも入ります）:

```bash
curl -fsSL https://github.com/ababup1192/flix_game_engine/releases/latest/download/install.sh | sh
```

**Windows**（PowerShell）— [Git for Windows](https://gitforwindows.org/) が要ります（`winget install --id Git.Git -e`）:

```powershell
irm https://github.com/ababup1192/flix_game_engine/releases/latest/download/install.ps1 | iex
```

入ったらダッシュボードを開きます:

```bash
fge dashboard        # ブラウザで http://127.0.0.1:8790/ が開く
```

「新しいゲームを作ってみよう」のカードで名前とテンプレートを選び、**Claude Code で開く** を押します。
Claude がゲームを置くフォルダ（`~/flix-games`）で起動し、`fge new` でゲームを作り、動くか確かめて、
次にやることを教えてくれます。engine と JDK は初回に `~/.flix_ge` へ自動で取ってきます。

ダッシュボードを使わずに作ることもできます:

```bash
fge new --list                             # テンプレートの一覧
fge new my-game --template rpg-starter     # ./my-game を作る（独立した git リポジトリ）
cd my-game && make run                     # 遊ぶ（make test でテスト）
```

## スターターゲーム（templates）

どれも「そのまま遊べる 1 本のゲーム」で、画風・Doc・テストが一式そろっています。

| テンプレ | 内容 |
|---|---|
| **game-starter** | 骨組みだけ。主人公（ドット絵）を矢印キーで動かせる。`fge new` の既定 |
| **rpg-starter** | FC 風の王道 RPG。泉の枯れた村から、ワールドマップと坑道を抜け、コマンドバトルで進む |
| **sound-novel-starter** | 田舎のサウンドノベル。写真をぼかした背景・明朝とルビ・NVL/ADV・ログ・オート・スキップ・セーブとロード。台本は Yarn |
| **tidepool-starter** | 潮だまりのターン制パズル。1 手ごとに潮が満ち引きする磯で岩を押して水路を作り変える。取り消し・やり直し・先読みつき |
| **hd2d-starter** | HD-2D の町歩き。タイルの地図から組んだ 3D の港町にドット絵の板を立て、仲間と歩く。太陽の影と被写界深度 |
| **retro3d-horror-starter** | 夜の木造校舎を一人称で歩くレトロ 3D ホラー。PS1 風の描き方・頂点の色にベイクした明るさ・会話・鍵と閉じた部屋 |

## ゲームデータ（Doc）

数値・見た目・配置は、コードの外の JSON **Doc**（`<名前>.<種類>.json`。例 `grass.theme.json`）に置きます。
振る舞い（ルール・当たり判定・生成）はコードのまま。種類ごとの `<種類>.schema.json` が
エディタのフォーム・起動時の検証・AI がデータを書くときの仕様を兼ね、`App.watchFile` で監視すれば
保存した内容が走っているゲームに即反映されます。詳しくは [docs/doc-conventions.md](docs/doc-conventions.md)。

## engine を直す人向け

ここまでは `fge` が取ってきた engine を使います。engine そのものを直すときは、このリポジトリを clone します。
**devbox**（JDK 25・GNU make・Flix 0.80.0 コンパイラを取ってくる）が要ります。対応は macOS と Linux。

```bash
devbox shell         # 道具をそろえ、bin/ を PATH に足す
make sync            # 全エンジンパッケージを組み、templates・bench へ symlink で配る（初回に必ず 1 回）
make go-build        # go/ から bin/fge を組む
make status          # 今の状態を 1 画面で
make help            # 他の口の一覧
```

エンジンパッケージを直したら `make sync` で反映します。テンプレートは
`cd templates/<name> && flix run`（テストは `flix test`）。この clone からゲームを作るには:

```bash
make new-game GAME=/abs/path/to/mygame NAME=mygame TITLE=題名 TEMPLATE=rpg-starter
```

```
engine/        契約層（ネイティブ依存なし）: Platform の effect（Input・Window・Draw2d など）・Audio・共有の描画型・数学・色・テキストレイアウト
render_gl/     PC 用 backend: LWJGL の窓・入力・音、WebGPU（Dawn）と OpenGL 3.3 の描画、シェーダー、SDF フォント
engine_web/    ブラウザ用 backend: TeaVM（WasmGC）、WebGPU / WebGL2、Web Audio
engine_world/  ゲームフレームワーク: Bevy 風 App ループ・ECS クエリ・物理・UI・カメラリグ・undo とリプレイ・アセット・セーブ
engine_tools/  開発・テスト用: headless ラスタライザ・コマ撮り / GIF・描画 lint・効果音合成
engine_full/   上の束を、ゲームが依存する 1 つのパッケージ `flix_game_engine` にまとめる
templates/     スターターゲーム（fge new / make new-game の写し元）
go/            fge の CLI（dashboard・export-web・refactor・checkd・lint など）
bench/         ベンチマークと試験用の場面
```

開発の決まり（名前の付け方・テスト・絵の下限・リリース）は [AGENTS.md](AGENTS.md)。
起動画面と、字を初めて出るときに作る仕組みは [docs/startup-screen.md](docs/startup-screen.md)。

> 対になるエディタ **[flix_ge_studio](https://github.com/ababup1192/flix_ge_studio)** は凍結中です。手元にある方は、Studio の self-update で新しい版の engine に上げないでください（凍結した Studio は新しい版の engine を動かせません）。

## 技術スタック

- **Flix 0.80.0** — 静的な副作用検査を持つ関数型言語
- **WebGPU**（PC は Dawn・ブラウザ）が既定。PC は **OpenGL 3.3 Core**、ブラウザは **WebGL2** へ自動で切り替え
- **TeaVM** — ブラウザ・スマホ PWA 向けの WebAssembly（WasmGC）書き出し
- **LWJGL** — GLFW / OpenGL / STB / OpenAL / SDL3 ゲームパッド
- **OpenAL / Web Audio** — 音

## ライセンス

[MIT License](LICENSE.md)
