// Sfx — 一発で鳴り切る効果音を、ゲームが選んだ型 s で鳴らす effect（多相 effect・Flix 0.77 の実験機能）。
//
// 音の名前を文字列で書くと、綴りの誤りも「鳴り続ける音を一発で鳴らす」取り違えもコンパイルを通る。
// ゲームが一発の音の enum（例: Shot）を作り、出来事の関数を `\ Sfx[Shot]` にすると、
// 別の型の値（鳴り続ける音の enum など）を渡した所で E6795 になる。
// 鳴り続ける音は別の effect の Loop[s]。一発の音と鳴り続ける音は別の enum にする
// （同じ enum を両方に使うと、型では区別が付かない）。
//
// 利用例（流れは今の App.withAudio のまま。名前へ写す関数は project.json の sounds の名前を返す）:
//   def events(ws: { before = World, after = World }): Unit \ Sfx[Shot] =
//       if (crashed(ws)) Sfx.play(Shot.Crash) else ()
//   def shotName(s: Shot): String = match s { case Shot.Crash => "crash" }
//   app |> App.withAudio(ws -> Sfx.collect(shotName, () -> events(ws)))
//
// 制限（Flix 0.78.0）: 1 つの関数の中で Sfx を 2 つの型に使えない（E6795）。
// 型引数に trait の制約を付けたハンドラ（`with ToString[s]`）はコンパイラが落ちるので、
// collect は名前へ写す関数を引数で受ける。

/// 一発で鳴り切る効果音の effect。s はゲームが選ぶ音の型。
pub eff Sfx[s] {
    /// このフレームで sound を 1 回鳴らす。同じ音が同じフレームに 2 回来ても 1 回だけ鳴る。
    def play(sound: s): Unit
}

pub mod Sfx {

    /// f の中で鳴らした音を、鳴らした順の名前の列にする（App.withAudio に渡す形）。
    /// nameOf は音の型から project.json の sounds の名前を返す。同じ名前は先の 1 つだけ残す。
    pub def collect(nameOf: s -> String, f: Unit -> Unit \ ef): List[String] \ (ef - Sfx[s]) =
        let played = run {
            f();
            Nil
        } with handler Sfx {
            def play(sound, k) = nameOf(sound) :: k(())
        };
        List.distinct(played)
}
