# Flix 0.77 → 0.78.0 の手当て（ゲーム側）

engine 同梱の Flix コンパイラが 0.78.0 になった。出す版が決まったら `<版>.md` へ移す。

## なぜ変わったか

0.78.0 のパッケージ管理では、依存パッケージは必ず mount され、その名前は
`use <mount>::名前` からしか届かない。mount を書かない依存は repo 名で mount される
（engine なら `flix_game_engine`）。ワイルドカードの use は無く、use は mod ごとに効く
（ファイル直下の use は `mod View { }` の中へ届かない）。engine の pub でない mod は届かない。

## 直し方

1. `flix.toml` の `flix` を `"0.78.0"` に、engine の依存の版をこの engine の版にする
2. `devbox.json` の flix を `"github:ababup1192/flix_game_engine?dir=nix/flix#flix_0_78_0"` にして
   `devbox install`（Cj-bc/flix.nix に 0.78.0 が載ったらそちらへ戻してよい）
3. `make check` を 1 回回して engine の fpkg を lib/ に取る（ここでは名前の誤りで赤くてよい）
4. `bin/fge engine-uses` — mod ごとに `use flix_game_engine::{App, Color, ...}` を足す。
   既にある `use Color.darken` のような engine を指す use には `flix_game_engine::` を足す
5. `make check` → `make test` → `make reference-check`

`bin/fge engine-uses --check` は書き換えずに、足りない所があれば exit 1 を返す。

## 残りやすい誤り

- `Undefined name 'X.y'` が engine の名前で残る: 字句で拾えない書き方。その mod の use に X を足す
- `InaccessibleModule`: engine の pub でない mod を使っている。engine 側で pub にするか相談する
- `Missing repository`: 自分が依存される側のパッケージなら `[package]` に repository を書く
