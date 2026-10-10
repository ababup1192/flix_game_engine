<!-- engine v0.34.0 / 生成: 2026-10-11 -->
<!-- 生成物: bin/fge api-digest が作る。手で編集しない（make api-digest で作り直す） -->

# API ダイジェスト

engine / engine_world / engine_tools が公開している `pub def` / `pub enum` /
`pub type alias` の一覧。**API の型・引数を調べる時は、ソースを grep する前に
まずここを読む。** 実装や WhyNot コメントまでは載っていないので、シグネチャだけで
足りないときにだけ元ファイルを開く。

パッケージごとに分けている（1 ファイルが大きくなりすぎると、それ自体を読むのが
grep 代わりの重い作業になってしまうため）。調べたいモジュールがどのパッケージに
あるか分からないときは [engine-module-index.md](engine-module-index.md) /
[module-index.md](module-index.md) を先に引く。
| パッケージ | モジュール数 | 宣言数 | ファイル |
|---|---|---|---|
| engine | 1 | 1 | [api-digest/engine.md](api-digest/engine.md) |
| engine_world | 2 | 8 | [api-digest/engine_world.md](api-digest/engine_world.md) |
| engine_tools | 0 | 0 | [api-digest/engine_tools.md](api-digest/engine_tools.md) |
