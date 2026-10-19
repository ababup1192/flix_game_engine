// Emit — 規則の関数が「起きた出来事」（列を消した・頁を送った・敵が倒れた）を、戻り値を変えずに外へ出す
// effect（多相 effect）。音や演出を決めるのは外側（App の audio）だが、出来事は規則の奥で起きる。
// 戻り値に (World, 出来事の列) を通すと途中の関数が全部その形に変わるので、規則は
// `Emit.emit(出来事)` と書いて型に `\ Emit[Event]` を足すだけにし、系（addSystem）で集める。
//
// 集めた出来事は World の欄 Emit.Events に溜め、audio は前後の World の差（Emit.since）だけを読む
// （Bevy の Events と同じ考え: 出来事に通し番号を振り、読む側が前に読んだ所を覚えている）。
// こうすると withFixedStep でも 1 実フレームの出来事がちょうど 1 回ずつ読まれる —
// 刻みが 0 回のフレームは World が変わらないので空・2 回以上のフレームは全部の刻みの分が足される。
// 「毎フレーム events 欄を置き換える」形は、刻みが 0 回のフレームに前の出来事が残ってもう一度鳴り、
// 2 回以上のフレームは前の刻みの出来事が消える。
//
// 利用例（World に events = Emit.Events[Event] の欄。系は collectInto の戻りで events を毎回上書きする
// ので、規則が World を作り直しても溜めは続く）:
//   def lock(w: World): World \ Emit[Event] = { Emit.emit(Event.Locked); ... }
//   def update(f: App.Frame, w: World): World =
//       let (next, events) = Emit.collectInto(() -> rules(f, w), w#events);
//       { events = events | next }
//   app |> App.addSystem(update)
//       |> App.withAudio(ws -> Emit.since(ws#before#events, ws#after#events) |> List.map(soundName))
// 規則を直に呼ぶテストは Emit.collect で包む（出来事の列が戻り値の隣に出る）。
//
// 制限（Flix 0.78.0）: 1 つの関数の中で Emit を 2 つの型に使えない（E6795）。
// 多相 effect は @DefaultHandler を持てないので、規則を直に呼ぶテストも collect で包む。

/// 出来事を 1 つ外へ出す effect。e はゲームが選ぶ出来事の型。
pub eff Emit[e] {
    /// event が起きたと知らせる。同じ出来事が 2 回来れば 2 回とも残る。
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

    /// World に持たせる出来事の溜め。collectInto だけが足す —— 中の通し番号を外で書き換えると
    /// since が読み落とす・読み直すので、中身の enum は外へ出さない。
    /// 持つのは (何回目の collectInto か, これまでに出た出来事の総数, その回の出来事の出た順の列)。
    enum EventLog[e] with Eq, ToString {
        case EventLog(Int64, Int64, List[(Int64, e)])
    }

    pub type alias Events[e] = EventLog[e]

    /// 出来事がまだ 1 つも無い溜め（World の初期値）。
    pub def empty(): Events[e] = EventLog.EventLog(0i64, 0i64, Nil)

    /// これまでに溜めへ出た出来事の総数（捨てた古い出来事も数える。増えるだけ）。
    /// flow の返事の通し番号（Flow.Table#replies）に使える: 押した後に増えなければ、その入力に応えていない。
    pub def countOf(events: Events[e]): Int64 = match events {
        case EventLog.EventLog(_, total, _) => total
    }

    /// f を走らせ、その間に出た出来事を溜めの末尾に足す（1 回の collectInto = 通し番号 1 つ）。
    /// 古い出来事は keptCalls 回分だけ残して捨てる。
    pub def collectInto(f: Unit -> a \ ef, events: Events[e]): (a, Events[e]) \ (ef - Emit[e]) =
        let (value, fresh) = collect(f);
        match events {
            case EventLog.EventLog(count, total, entries) =>
                let next = count + 1i64;
                let kept = entries |> List.filter(entry -> fst(entry) > next - keptCalls());
                (value, EventLog.EventLog(next, total + Int32.toInt64(List.length(fresh)),
                                          List.append(kept, fresh |> List.map(event -> (next, event)))))
        }

    /// before の後に after へ足された出来事（出た順）。audio に ws#before#events と ws#after#events を渡す。
    /// after が before より古い番号なら（World を empty から作り直した）、after に残る出来事を全部返す。
    pub def since(before: Events[e], after: Events[e]): List[e] =
        match (before, after) {
            case (EventLog.EventLog(seen, _, _), EventLog.EventLog(count, _, entries)) =>
                let readUpTo = if (count < seen) 0i64 else seen;
                entries |> List.filter(entry -> fst(entry) > readUpTo) |> List.map(snd)
        }

    /// 溜めに残す collectInto の回数。audio は 1 実フレームに 1 回しか読まないので、
    /// 1 実フレームの間に呼ばれる回数（固定刻みの上限 5 回 × 出来事を集める系の本数）より多ければ読み落とさない。
    def keptCalls(): Int64 = 64i64
}
