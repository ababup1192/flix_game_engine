// PropertyTest — 性質テスト（property-based testing）の道具。種（seed）で決まるでたらめなキーとマウスの
// 入力の列を作り、App.traceFrame で画面を開かずに 1 フレームずつ流して、決まりが崩れた最初のフレームを探す。
// 「この手順ならこうなる」を書く普通のテストと違い、「どう遊んでも崩れない事」（1 回押したら音は 1 回・
// 升の数は置いた数と消した数で決まる・残りが負にならない）を、人が思いつかない押し方で確かめる。
// 乱数は標準ライブラリの Math.Random を runWithSeed で回す（同じ種なら毎回同じ列 = テストの結果も同じ）。
//
// 使い方（読む順）:
//   1. ゲームの役の enum r（Confirm・Left など）と、役 → キーの keyOf を Setup に書く
//      （keyOf は World も受け取る。割り当てを Doc で変えるゲームは World の Doc から引く）
//   2. 押す役・マウスの位置の候補を Spec に書く（{ taps = … | PropertyTest.emptySpec() }）
//   3. 決まり rule を「1 フレームの前後（App.TraceStep）→ 崩れていれば説明」で書く
//   4. forAll(app, setup, { seeds, length, spec }, 始まりの World, rule) が None なら全部の種で通った
//   崩れた列を見たいときは generate で列を作り firstBroken で崩れた所を、traceOf で全フレームを引く。
//
// 利用例（tetris-starter の test/TestTrace.flix に全文）:
//   let rule = (step: App.TraceStep[World]) ->
//       if (cellsOf(step#after) == cellsOf(step#before) + 4 * locked(step) - 10 * cleared(step)) None
//       else Some("升の数が合わない");
//   Assert.assertEq(expected = None, PropertyTest.forAll(app, setup, cases, start, rule))
//
// フレームの作り方は実機と同じ App.frameOf（押した瞬間 = 前のフレームに無かったキー）。
// 前のフレームで押していたキーをもう一度 Tap する・押したまま Press するときは、間に離すフレームを
// 1 つ挟む（実機でも離さずに 2 回は押せない）。そのぶんフレームの数は入力の数より多くなることがある。
pub mod PropertyTest {

    use Math.Random
    use GameEngine.Key

    /// 1 回分の入力。r はゲームの役の enum。マウスは左ボタン 1 つ。
    pub enum Input[r] {
        case Idle(Float64)     // 何も触らずに dt 秒（0.0 なら Setup の dt）
        case Tap(r)            // このフレームで押し、次のフレームでは離している
        case Hold(r)           // 押し始める（Release まで押しっぱなし）
        case Release(r)
        case Move(Vec2.Vec2)   // ボタンを押さずにマウスをその位置へ
        case Press(Vec2.Vec2)  // その位置で左ボタンを押す（Up まで押しっぱなし）
        case Drag(Vec2.Vec2)   // 左ボタンを押したままその位置へ
        case Up                // 左ボタンを離す
        case Wheel(Float64)    // ホイールを回す（上が正）
    }

    /// 入力の列の作り方。どの候補も、空ならその種類の入力は出ない。
    /// 重みは idle = 何も触らないフレーム・Tap は 1・Hold と Release は 1 ずつ・マウスは
    /// Move・Press・Drag・Up が 1 ずつ・Wheel は 1。
    pub type alias Spec[r] = {
        taps = List[r],             // Tap する役
        holds = List[r],            // Hold / Release する役
        idle = Int32,               // 何も触らないフレームの重み
        dts = List[Float64],        // 何も触らないフレームの経過秒の候補（空なら Setup の dt）
        points = List[Vec2.Vec2],   // マウスを置く位置の候補（design 座標）
        wheels = List[Float64]      // ホイールの量の候補
    }

    /// 入力を Frame にする材料。keyOf = 役 → いまのキー・viewport = design 解像度・dt = 押すフレームの経過秒。
    pub type alias Setup[r, w] = { keyOf = (r, w) -> Key, viewport = Vec2.Vec2, dt = Float64 }

    /// forAll が試す範囲。種 1..seeds のそれぞれで length 個の入力を spec から作る。
    pub type alias Cases[r] = { seeds = Int32, length = Int32, spec = Spec[r] }

    /// 決まりが崩れた所。frame = 何フレーム目か（0 から。挟んだ離すフレームも数える）・
    /// why = 決まりが返した説明・inputs = 崩れた入力までの列（traceOf に渡せば同じ所で崩れる）。
    pub type alias Broken[r] = { frame = Int32, why = String, inputs = List[Input[r]] }

    /// 何もしない Spec（何も触らないフレームだけ）。{ taps = … | emptySpec() } で必要な欄だけ書く。
    pub def emptySpec(): Spec[r] =
        { taps = Nil, holds = Nil, idle = 1, dts = Nil, points = Nil, wheels = Nil }

    // ── 列を作る ──

    /// 種で決まる length 個の入力の列。
    pub def generate(seed: Int64, length: Int32, spec: Spec[r]): List[Input[r]] =
        Random.runWithSeed(seed, () -> List.range(0, length) |> List.map(_ -> nextInput(spec)))

    /// 入力の種類。重みの表から 1 つ選んでから、候補を選ぶ。
    enum Kind {
        case Rest, TapKey, HoldKey, ReleaseKey, MoveMouse, PressMouse, DragMouse, UpMouse, TurnWheel
    }

    def kindsOf(spec: Spec[r]): List[Kind] =
        List.flatten(
            List.repeat(spec#idle, Kind.Rest) ::
            unlessEmpty(spec#taps, Kind.TapKey :: Nil) ::
            unlessEmpty(spec#holds, Kind.HoldKey :: Kind.ReleaseKey :: Nil) ::
            unlessEmpty(spec#points, Kind.MoveMouse :: Kind.PressMouse :: Kind.DragMouse :: Kind.UpMouse :: Nil) ::
            unlessEmpty(spec#wheels, Kind.TurnWheel :: Nil) :: Nil)

    /// 候補 xs が空なら Nil、あれば kinds。
    def unlessEmpty(xs: List[a], kinds: List[Kind]): List[Kind] =
        if (List.isEmpty(xs)) Nil else kinds

    def nextInput(spec: Spec[r]): Input[r] \ Random =
        let rest = () -> Input.Idle(pick(0.0, spec#dts));
        let at = make -> pickSome(spec#points) |> Option.map(make) |> Option.getWithDefault(rest());
        let role = (roles, make) -> pickSome(roles) |> Option.map(make) |> Option.getWithDefault(rest());
        match pick(Kind.Rest, kindsOf(spec)) {
            case Kind.Rest       => rest()
            case Kind.TapKey     => role(spec#taps, Input.Tap)
            case Kind.HoldKey    => role(spec#holds, Input.Hold)
            case Kind.ReleaseKey => role(spec#holds, Input.Release)
            case Kind.MoveMouse  => at(Input.Move)
            case Kind.PressMouse => at(Input.Press)
            case Kind.DragMouse  => at(Input.Drag)
            case Kind.UpMouse    => Input.Up
            case Kind.TurnWheel  => Input.Wheel(pick(0.0, spec#wheels))
        }

    /// 列から 1 つを等しい確率で選ぶ（空なら fallback）。
    def pick(fallback: a, xs: List[a]): a \ Random =
        pickSome(xs) |> Option.getWithDefault(fallback)

    def pickSome(xs: List[a]): Option[a] \ Random =
        let n = List.length(xs);
        let index = Float64.tryToInt32(Float64.floor(Random.randomFloat64() * Int32.toFloat64(n)))
            |> Option.getWithDefault(0);
        List.nth(Int32.min(n - 1, index), xs)

    // ── 列を流す ──

    /// フレームをまたいで持つ入力の状態。
    type alias Pad[r] = {
        held = List[(r, Key)],            // Hold した役と、押した時のキー
        prevKeys = Set[Key],              // 前のフレームで押されていたキー
        cursor = Vec2.Vec2,
        prevCursor = Option[Vec2.Vec2],   // 前のフレームのマウスの位置（最初のフレームは None）
        button = Bool,                    // 左ボタンを押しっぱなしか
        prevButton = Bool                 // 前のフレームで左ボタンが押されていたか
    }

    /// 1 フレームの入力の中身（Frame になる前）。
    type alias Sample = { keys = Set[Key], cursor = Vec2.Vec2, button = Bool, wheel = Float64, dt = Float64 }

    def freshPad(): Pad[r] =
        { held = Nil, prevKeys = Set.empty(), cursor = { x = -100.0, y = -100.0 }, prevCursor = None,
          button = false, prevButton = false }

    def heldKeys(held: List[(r, Key)]): Set[Key] = held |> List.map(snd) |> List.toSet

    /// 入力 1 つを 1〜2 個の Sample にする（前に離すフレームを挟むときは 2 個）。
    /// 返すのは Sample の列と、入力の後の押しっぱなしの役と左ボタン。
    def samplesOf(setup: Setup[r, w], input: Input[r], world: w, pad: Pad[r]):
            (List[Sample], List[(r, Key)], Bool) with Eq[r] =
        let base = (keys, button) ->
            { keys = keys, cursor = pad#cursor, button = button, wheel = 0.0, dt = setup#dt };
        let keyOf = setup#keyOf;
        let held = heldKeys(pad#held);
        let gapIf = (pressedBefore, gap) -> if (pressedBefore) gap :: Nil else Nil;
        match input {
            case Input.Idle(secs) =>
                ({ dt = if (secs > 0.0) secs else setup#dt | base(held, pad#button) } :: Nil, pad#held, pad#button)
            case Input.Tap(role) =>
                let key = keyOf(role, world);
                let gap = gapIf(Set.memberOf(key, pad#prevKeys), base(Set.remove(key, held), pad#button));
                (List.append(gap, base(Set.insert(key, held), pad#button) :: Nil), pad#held, pad#button)
            case Input.Hold(role) =>
                let key = keyOf(role, world);
                let already = List.exists(entry -> fst(entry) == role, pad#held);
                let nextHeld = if (already) pad#held else (role, key) :: pad#held;
                let gap = gapIf(not already and Set.memberOf(key, pad#prevKeys), base(held, pad#button));
                (List.append(gap, base(heldKeys(nextHeld), pad#button) :: Nil), nextHeld, pad#button)
            case Input.Release(role) =>
                let nextHeld = pad#held |> List.filter(entry -> fst(entry) != role);
                (base(heldKeys(nextHeld), pad#button) :: Nil, nextHeld, pad#button)
            case Input.Move(point) =>
                ({ cursor = point | base(held, pad#button) } :: Nil, pad#held, pad#button)
            case Input.Press(point) =>
                let gap = gapIf(pad#prevButton, { cursor = point | base(held, false) });
                (List.append(gap, { cursor = point | base(held, true) } :: Nil), pad#held, true)
            case Input.Drag(point) =>
                ({ cursor = point | base(held, true) } :: Nil, pad#held, true)
            case Input.Up =>
                (base(held, false) :: Nil, pad#held, false)
            case Input.Wheel(amount) =>
                ({ wheel = amount | base(held, pad#button) } :: Nil, pad#held, pad#button)
        }

    def frameOf(setup: Setup[r, w], pad: Pad[r], sample: Sample): App.Frame =
        App.frameOf({ prev = pad#prevKeys }, { current = sample#keys }, sample#dt, setup#viewport,
                    { prevCursor = pad#prevCursor, cursor = sample#cursor },
                    { prevDown = pad#prevButton, down = sample#button, wheel = sample#wheel })

    /// 列を流した全部のフレームと、それぞれを作った入力の番号（先頭から）。
    def stepsOf(app: App.App[w, ef], setup: Setup[r, w], inputs: List[Input[r]], start: w):
            List[(Int32, App.TraceStep[w])] \ ef with Eq[r] =
        let (_, _, _, newestFirst) = inputs |> List.zipWithIndex |> List.foldLeft((acc, entry) -> {
            let (state, world, pad, out) = acc;
            let (index, input) = entry;
            let (samples, nextHeld, nextButton) = samplesOf(setup, input, world, pad);
            let (state1, world1, pad1, out1) = samples |> List.foldLeft((inner, sample) -> {
                let (s, w, p, o) = inner;
                let (step, nextState) = App.traceFrame(app, frameOf(setup, p, sample), s, w);
                let nextPad = { prevKeys = sample#keys, cursor = sample#cursor, prevCursor = Some(sample#cursor),
                                prevButton = sample#button | p };
                (nextState, step#after, nextPad, (index, step) :: o)
            }, (state, world, pad, out));
            (state1, world1, { held = nextHeld, button = nextButton | pad1 }, out1)
        }, (App.freshStepState(), start, freshPad(), Nil));
        List.reverse(newestFirst)

    /// 列を流した全部のフレーム（先頭から）。
    pub def traceOf(app: App.App[w, ef], setup: Setup[r, w], inputs: List[Input[r]], start: w):
            List[App.TraceStep[w]] \ ef with Eq[r] =
        stepsOf(app, setup, inputs, start) |> List.map(snd)

    /// 列を流した後の World。
    pub def finalOf(app: App.App[w, ef], setup: Setup[r, w], inputs: List[Input[r]], start: w): w \ ef with Eq[r] =
        traceOf(app, setup, inputs, start) |> List.last |> Option.map(step -> step#after) |> Option.getWithDefault(start)

    /// 決まり rule が崩れた最初のフレーム。崩れなければ None。
    pub def firstBroken(app: App.App[w, ef], setup: Setup[r, w], inputs: List[Input[r]], start: w,
                        rule: App.TraceStep[w] -> Option[String]): Option[Broken[r]] \ ef with Eq[r] =
        stepsOf(app, setup, inputs, start)
            |> List.zipWithIndex
            |> List.findMap(entry -> {
                let (frame, (index, step)) = entry;
                rule(step) |> Option.map(why -> { frame = frame, why = why, inputs = List.take(index + 1, inputs) })
            })

    /// 種 1, 2, …, count のうち、check が最初に崩れを返した種とその中身。全部通れば None。
    pub def firstFailingSeed(count: Int32, check: Int64 -> Option[a] \ ef): Option[(Int64, a)] \ ef =
        List.range(1, count + 1)
            |> List.map(Int32.toInt64)
            |> List.findMap(seed -> check(seed) |> Option.map(found -> (seed, found)))

    /// cases の全部の種で列を作って流し、rule が崩れた最初の所の説明（種・フレーム・入力の数・rule の説明）。
    /// 全部通れば None（テストは assertEq(expected = None, …) で書く）。
    pub def forAll(app: App.App[w, ef], setup: Setup[r, w], cases: Cases[r], start: w,
                   rule: App.TraceStep[w] -> Option[String]): Option[String] \ ef with Eq[r] =
        firstFailingSeed(cases#seeds, seed ->
            firstBroken(app, setup, generate(seed, cases#length, cases#spec), start, rule))
            |> Option.map(found -> {
                let (seed, broken) = found;
                "seed ${seed}・${broken#frame} フレーム目（入力 ${List.length(broken#inputs)} 個目）: ${broken#why}"
            })
}
