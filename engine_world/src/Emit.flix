// Emit — 規則の関数が「このフレームに起きた出来事」を、戻り値を変えずに外へ出す effect（多相 effect）。
//
// 列を消した・積み上がった・頁を送った、のような出来事は、規則の奥（固定・消去・涌き）で起きるが、
// 音や演出を決めるのは外側（App の audio）。戻り値に (World, 出来事の列) を通すと途中の関数が
// 全部その形に変わる。Emit.emit(出来事) と書き、外側で Emit.collect すれば、途中の関数は
// `\ Emit[Event]` を足すだけで済む。
//
// 利用例（World の events 欄を毎フレーム置き換え、audio は after#events を読む）:
//   def lock(w: World): World \ Emit[Event] = { Emit.emit(Event.Locked); ... }
//   def step(f: App.Frame, w: World): World =
//       let (next, events) = Emit.collect(() -> rules(f, w));
//       { events = events | next }
//   app |> App.withAudio(ws -> ws#after#events |> List.map(soundOf))
//
// 制限（Flix 0.78.0）: 1 つの関数の中で Emit を 2 つの型に使えない（E6795）。
// Emit は @DefaultHandler を持てない（多相 effect）ので、規則を直に呼ぶテストも collect で包む。

/// 出来事を 1 つ外へ出す effect。e はゲームが選ぶ出来事の型。
pub eff Emit[e] {
    /// このフレームに event が起きたと知らせる。同じ出来事が 2 回来れば 2 回とも残る。
    def emit(event: e): Unit
}

pub mod Emit {

    /// f を走らせ、戻り値と、その間に出た出来事の列（出た順）を返す。
    pub def collect(f: Unit -> a \ ef): (a, List[e]) \ (ef - Emit[e]) =
        run {
            (f(), Nil)
        } with handler Emit {
            def emit(event, k) = {
                let (value, rest) = k(());
                (value, event :: rest)
            }
        }
}
