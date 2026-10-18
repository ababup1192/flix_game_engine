// PropTrace — 性質テスト（property-based test）の入力の列。種（seed）で決まる乱数のキー操作の列を作り、
// App.trace で画面を開かずに流して、決まりが崩れた最初のフレームを探す。
// 乱数は標準ライブラリの Math.Random を runWithSeed で回す（同じ種なら毎回同じ列 = テストの結果も同じ）。
//
// 使い方（読む順）:
//   1. ゲームの役の enum r（Left・Confirm など）と、役 → キーの keyOf を Setup に書く
//   2. plan(種, 長さ, spec) で入力の列（Act[r] の列）を作る
//   3. firstBroken(app, setup, 列, 始まりの World, 決まり) で崩れた最初のフレームを探す
//   4. firstFailingSeed(種の数, 種 → 崩れ) で、何個目の種で落ちるかを探す
//
// キーは App.frameOf で Frame にするので、エッジ（justPressed）は実機と同じく「前のフレームに無かったキー」。
// 同じキーを続けて Tap すると 2 回目はエッジにならない（実機でも離さずに 2 回は押せない）。
pub mod PropTrace {

    use Math.Random

    /// 1 フレームの入力。r はゲームの役の enum。
    pub enum Act[r] with ToString {
        case Idle(Float64)  // 何も触らずに dt 秒
        case Tap(r)         // このフレームで押して、次のフレームでは離している
        case Hold(r)        // 押し始める（Release まで押しっぱなし）
        case Release(r)
    }

    /// 列の作り方。idle = 何も触らないフレームの重み（Tap と Hold/Release は 1 ずつ）・
    /// dts = 何も触らないフレームの経過秒の候補（空なら setup の dt）。
    pub type alias Spec[r] = { taps = List[r], holds = List[r], idle = Int32, dts = List[Float64] }

    /// 列を Frame にする材料。keyOf = 役 → 実際のキー・viewport = design 解像度・dt = 押すフレームの経過秒。
    pub type alias Setup[r] = { keyOf = r -> GameEngine.Key, viewport = Vec2.Vec2, dt = Float64 }

    /// 1 フレームの入力と、App.trace の前後（決まりはこれを見る）。
    pub type alias Step[w] = { frame = App.Frame, before = w, after = w, sounds = List[String], sustained = List[App.Sustain] }

    /// 種で決まる入力の列。
    pub def plan(seed: Int64, length: Int32, spec: Spec[r]): List[Act[r]] =
        Random.runWithSeed(seed, () -> List.range(0, length) |> List.map(_ -> nextAct(spec)))

    def nextAct(spec: Spec[r]): Act[r] \ Random =
        let kinds = List.flatten(
            List.repeat(spec#idle, 0) ::
            (if (List.isEmpty(spec#taps)) Nil else 1 :: Nil) ::
            (if (List.isEmpty(spec#holds)) Nil else 2 :: 3 :: Nil) :: Nil);
        let idle = () -> Act.Idle(pick(0.0, spec#dts));
        match pick(0, kinds) {
            case 1 => pick(None, spec#taps |> List.map(Some)) |> Option.map(Act.Tap) |> Option.getWithDefault(idle())
            case 2 => pick(None, spec#holds |> List.map(Some)) |> Option.map(Act.Hold) |> Option.getWithDefault(idle())
            case 3 => pick(None, spec#holds |> List.map(Some)) |> Option.map(Act.Release) |> Option.getWithDefault(idle())
            case _ => idle()
        }

    /// 列から 1 つを等しい確率で選ぶ（空なら fallback）。
    def pick(fallback: a, xs: List[a]): a \ Random =
        let n = List.length(xs);
        let index = Float64.tryToInt32(Float64.floor(Random.randomFloat64() * Int32.toFloat64(n)))
            |> Option.getWithDefault(0);
        List.nth(Int32.min(n - 1, index), xs) |> Option.getWithDefault(fallback)

    /// 入力の列を Frame の列にする。押しっぱなしのキーはフレームをまたいで持つ。
    /// Idle(0.0) は setup の dt を使う（spec の dts が空のとき）。
    pub def framesOf(setup: Setup[r], acts: List[Act[r]]): List[App.Frame] =
        let (_, _, newestFirst) = acts |> List.foldLeft((acc, act) -> {
            let (held, prevDown, out) = acc;
            let (down, nextHeld, dt) = match act {
                case Act.Idle(secs)    => (held, held, if (secs > 0.0) secs else setup#dt)
                case Act.Tap(role)     => (Set.insert(setup#keyOf(role), held), held, setup#dt)
                case Act.Hold(role)    => { let h = Set.insert(setup#keyOf(role), held); (h, h, setup#dt) }
                case Act.Release(role) => { let h = Set.remove(setup#keyOf(role), held); (h, h, setup#dt) }
            };
            let frame = App.frameOf({ prev = prevDown }, { current = down }, dt, setup#viewport,
                                    { prevCursor = None, cursor = { x = -100.0, y = -100.0 } },
                                    { prevDown = false, down = false, wheel = 0.0 });
            (nextHeld, down, frame :: out)
        }, (Set.empty(), Set.empty(), Nil));
        List.reverse(newestFirst)

    /// 列を流した全部のフレーム（先頭から）。
    pub def traceOf(app: App.App[w, ef], setup: Setup[r], acts: List[Act[r]], start: w): List[Step[w]] \ ef =
        let frames = framesOf(setup, acts);
        App.trace(app, frames, start)
            |> List.zip(frames)
            |> List.map(pair -> {
                let (frame, s) = pair;
                { frame = frame, before = s#before, after = s#after, sounds = s#sounds, sustained = s#sustained }
            })

    /// 列を流した後の World。
    pub def finalOf(app: App.App[w, ef], setup: Setup[r], acts: List[Act[r]], start: w): w \ ef =
        App.trace(app, framesOf(setup, acts), start)
            |> List.last |> Option.map(s -> s#after) |> Option.getWithDefault(start)

    /// 決まりが崩れた最初のフレーム（何フレーム目か・崩れの説明・そこまでの入力）。崩れなければ None。
    pub def firstBroken(app: App.App[w, ef], setup: Setup[r], acts: List[Act[r]], start: w,
                        rule: Step[w] -> Option[String]): Option[(Int32, String, List[Act[r]])] \ ef =
        traceOf(app, setup, acts, start)
            |> List.zipWithIndex
            |> List.findMap(pair -> {
                let (index, step) = pair;
                rule(step) |> Option.map(why -> (index, why, List.take(index + 1, acts)))
            })

    /// 種 1, 2, …, count のうち、最初に崩れた種の番号とその説明。全部通れば None。
    pub def firstFailingSeed(count: Int32, check: Int64 -> Option[String] \ ef): Option[(Int32, String)] \ ef =
        List.range(1, count + 1)
            |> List.findMap(seed -> check(Int32.toInt64(seed)) |> Option.map(why -> (seed, why)))
}
