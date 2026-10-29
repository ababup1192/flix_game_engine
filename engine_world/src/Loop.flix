// Loop — 鳴り続ける音を、ゲームが選んだ型 s で宣言する effect（多相 effect・Flix 0.77 の実験機能）。
//
// App.withSustained と同じ決まり: 宣言が続くフレームの間は鳴り続け、宣言が消えたフレームで止まる。
// 一発の音は別の effect の Sfx[s]。鳴り続ける音の enum（例: Hum）を一発の音の enum と分け、
// 宣言する関数を `\ Loop[Hum]` にすると、一発の音の値を渡した所で E6795 になる。
//
// 利用例:
//   def hums(w: World): Unit \ Loop[Hum] =
//       if (w#racing) Loop.hold(Hum.Engine, { volume = 0.8, pitch = 1.2 }) else ()
//   def humName(h: Hum): String = match h { case Hum.Engine => "engine" }
//   app |> App.withSustained(w -> Loop.collect(humName, () -> hums(w)))
//
// 制限は Sfx と同じ（1 つの関数で 2 つの型に使えない・trait の制約付きのハンドラは落ちる）。

/// 鳴り続ける音の effect。s はゲームが選ぶ音の型。
pub eff Loop[s] {
    /// このフレームで sound を鳴らし続ける。mix は音量 0.0〜1.0 と高さ（1.0 = 元のまま）。
    /// 同じ音を同じフレームに 2 回宣言したら先の 1 つが勝つ（App.sustainOps の決まり）。
    def hold(sound: s, mix: Loop.Mix): Unit
}

pub mod Loop {

    /// 鳴り続ける音の音量と高さ。volume は 0.0〜1.0、pitch は 1.0 = 元のまま・2.0 で 1 オクターブ上。
    pub type alias Mix = { volume = Float64, pitch = Float64 }

    /// 元の音量・元の高さ。
    pub def plain(): Mix = { volume = 1.0, pitch = 1.0 }

    /// f の中で宣言した音を、宣言した順の App.Sustain の列にする（App.withSustained に渡す形）。
    /// nameOf は音の型から project.json の sounds の名前を返す。
    pub def collect(nameOf: s -> String, f: Unit -> Unit \ ef): List[App.Sustain] \ (ef - Loop[s]) =
        run {
            f();
            Nil
        } with handler Loop {
            def hold(sound, mix, k) =
                { name = nameOf(sound), volume = mix#volume, pitch = mix#pitch } :: k(())
        }
}
