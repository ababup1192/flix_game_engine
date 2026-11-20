// App.Internal.LoadWait — ブラウザ版で、届いていない後回しの素材と後から取るコードを App のループが待つ所の判断:
// 待ちの状態・押した所の控え・1 コマの判断。判断は純粋な関数で、Runner は答えを当てるだけ（テストはここを叩く）。
// ゲームからは呼ばない（App の中身。ゲームの src・test で App.Internal. を書くと lint が止める）。
pub mod App.Internal.LoadWait {
    import java.lang.RuntimeException

    /// 待ちの決まりの数。pressWindowSeconds = 押した所の控えを持つ秒（暗転の長さより長く取る）・giveUpSeconds = 素材を待つ上限の秒・
    /// cancelKeys = 押した時の待ちをやめるキー。
    pub type alias Settings = { pressWindowSeconds = Float64, giveUpSeconds = Float64, cancelKeys = Set[GameEngine.Key] }

    /// 既定の決まり: 控えは 1.5 秒・上限は 20 秒・やめるキーは Backspace とパッドの B（GamepadMap.table で B を当てたキー）。
    // WhyNot: Escape をやめるキーにしない — ブラウザの全画面を抜けるキーで、ゲームが確認の窓を開くキーにも使う。
    pub def defaultSettings(): Settings =
        let padB = GamepadMap.table() |> List.filter(entry -> snd(entry) == GamepadMap.PadInput.B) |> List.map(fst) |> List.toSet;
        { pressWindowSeconds = 1.5, giveUpSeconds = 20.0, cancelKeys = Set.insert(GameEngine.Key.Backspace, padB) }

    /// 押した所の控え。world = 押す前の World・stepState = その時の StepState・atSec = 控えた時刻・
    /// frames = 押したコマとその次のコマの入力の組を、控えてから押した順に並べた物（渡し直すコマ。組は 2 コマ）・stored = 控えてから積んだ store の記録・
    /// played = 控えてから鳴らした一発の音の名前ごとの数。
    pub type alias Snapshot[w] = { world = w, stepState = App.StepState, atSec = Float64, frames = List[App.Frame],
                                   stored = List[w -> w], played = Map[String, Int32] }

    /// 待っている所。code = 後から取るコードを待つか・names = 待つ名前・total = 待ち始めた時の名前の数・startedSec = 待ち始めた時刻・
    /// pressed = 押した所まで戻して待っているか（偽は前の World で止まっている）・frozen = 戻した World を進めずに描き直すか・
    /// chimed = 渡し直しで鳴らさない一発の音の名前ごとの数（待ちに入った時に鳴らした分と、控えから鳴らした分）。
    pub type alias Wait = { code = Bool, names = Set[String], total = Int32, startedSec = Float64, pressed = Bool, frozen = Bool,
                            chimed = Map[String, Int32] }

    /// 待ちの局面。Idle = 待っていない・Waiting = 待っている・Replaying(i) = 届いたので控えた入力の i コマ目を渡し直す。
    pub enum Mode {
        case Idle
        case Waiting(Wait)
        case Replaying(Int32)
    }

    /// ループが持ち回す待ちの状態。gaveUp = 諦めた名前（ゲームの間ずっと待たない）・owed = 渡し直しの音から引く数。
    pub type alias State[w] = { mode = Mode, snapshot = Option[Snapshot[w]], gaveUp = Set[String], owed = Map[String, Int32] }

    /// 起動の時の状態（待っていない・控えも無い）。
    pub def initial(): State[w] = { mode = Mode.Idle, snapshot = None, gaveUp = Set.empty(), owed = Map.empty() }

    /// 待っていなくて控えも無いか（ループが今までと同じ道を通れるか）。
    pub def isIdle(state: State[w]): Bool = match state#mode {
        case Mode.Idle => Option.isEmpty(state#snapshot)
        case _         => false
    }

    /// 進める時に渡す入力。Live = このコマの入力・Idle = 何も押していない入力・Replay = 控えた入力。
    pub enum Input {
        case Live
        case Idle
        case Replay(App.Frame)
    }

    /// 進める前に引く手。Splash = 頁がロゴを出している（進めず・音を当てず・描くだけ）・Hold = 進めずに今の World を描き直す・
    /// Advance = 入力を渡して 1 コマ進め、候補を decide で照らす。
    pub enum Step {
        case Splash
        case Hold
        case Advance(Input)
    }

    /// 進める前に見る機種の様子。missing = まだ届いていない名前・failed = 待つ名前のうち取れずに終わった物・codeReady = 後から取るコードがそろったか・
    /// splash = 頁がロゴを出しているか・nowSec = 今の時刻（秒）。
    pub type alias Watch = { missing = Set[String], failed = Set[String], codeReady = Bool, splash = Bool, nowSec = Float64 }

    /// このコマの入力が押した瞬間を持つか（キー・マウスのボタン、または固定の刻みが持ち越した押した瞬間）。
    pub def isPressFrame(frame: App.Frame, stepState: App.StepState): Bool =
        not Set.isEmpty(frame#justPressed) or not Set.isEmpty(frame#mouseClickedButtons) or frame#mouseClicked
            or not Set.isEmpty(stepState#pending#justPressed) or stepState#pending#mouseClicked or not Set.isEmpty(stepState#pending#mouseClickedButtons)

    /// 何も押していない入力（押しっぱなしも離す・動きも 0。カーソルの位置と dt はこのコマのまま）。
    pub def idleFrameOf(live: App.Frame): App.Frame =
        { down = Set.empty(), justPressed = Set.empty(), mouseDown = false, mouseClicked = false, mouseButtons = Set.empty(),
          mouseClickedButtons = Set.empty(), mouseMoved = false, wheel = 0.0, mouseDelta = Vec2.zero(),
          leftStick = Vec2.zero(), rightStick = Vec2.zero() | live }

    /// 控えた入力を今のコマで渡す形（押したキー・ボタン・カーソルは控えた物、dt と実時間と診断は今の物）。
    pub def replayFrameOf(live: App.Frame, held: App.Frame): App.Frame =
        { dt = live#dt, realNow = live#realNow, diagnostics = live#diagnostics, windowFocused = live#windowFocused | held }

    /// 進める前の手: ロゴの間・待ちの最中（届いたか・諦めたか・やめたか）・渡し直しの何コマ目か・控えの秒が過ぎたかを見て、
    /// このコマの手と次の状態を返す。world と stepState は今の物（届いて渡し直す時に、控えをここへ移す）。
    pub def plan(settings: Settings, live: App.Frame, watch: Watch, world: w, stepState: App.StepState, state0: State[w]): (Step, State[w]) =
        let state = captureNext(live, state0);
        if (watch#splash) (Step.Splash, state)
        else match state#mode {
            case Mode.Idle         => (Step.Advance(Input.Live), expire(settings, watch#nowSec, state))
            case Mode.Replaying(i) => replayStep(i, state)
            case Mode.Waiting(wt)  => waitingStep(settings, live, watch, world, stepState, wt, state)
        }

    /// 控えの最後の組が押したコマの入力しか持っていなければ、このコマの入力を組の 2 コマ目として足す（渡し直しの最中は足さない）。
    def captureNext(live: App.Frame, state: State[w]): State[w] = match (state#mode, state#snapshot) {
        case (Mode.Replaying(_), _) => state
        case (_, Some(s)) if Int32.modulo(List.length(s#frames), 2) == 1 => { snapshot = Some({ frames = List.append(s#frames, live :: Nil) | s }) | state }
        case _ => state
    }

    /// 待っていない時: 控えの秒が過ぎていれば控えを捨てる。
    def expire(settings: Settings, nowSec: Float64, state: State[w]): State[w] = match state#snapshot {
        case Some(s) if nowSec - s#atSec > settings#pressWindowSeconds => { snapshot = None, owed = Map.empty() | state }
        case _                                                         => state
    }

    /// 渡し直しの i コマ目。控えた入力を渡し切っていれば待っていない時へ戻す。
    def replayStep(i: Int32, state: State[w]): (Step, State[w]) =
        match state#snapshot |> Option.flatMap(s -> List.nth(i, s#frames)) {
            case Some(held) => (Step.Advance(Input.Replay(held)), state)
            case None       => (Step.Advance(Input.Live), { mode = Mode.Idle | state })
        }

    /// 待ちの最中の手。やめるキー → 戻した場面のまま待ちをやめる・全部届いた（か諦めた）→ 押した時の待ちは渡し直し、控えの外の待ちは進める・
    /// まだ → 押した時の待ちで止めないなら入力なしで進め、ほかは描き直す。
    def waitingStep(settings: Settings, live: App.Frame, watch: Watch, world: w, stepState: App.StepState, wt: Wait, state: State[w]): (Step, State[w]) =
        let remaining = Set.intersection(wt#names, watch#missing) |> Set.filter(name -> not Set.memberOf(name, state#gaveUp));
        let timedOut = watch#nowSec - wt#startedSec >= settings#giveUpSeconds;
        let allFailed = not Set.isEmpty(remaining) and Set.forAll(name -> Set.memberOf(name, watch#failed), remaining);
        let assetsDone = Set.isEmpty(remaining) or timedOut or allFailed;
        let codeDone = not wt#code or watch#codeReady;
        let cancelled = wt#pressed and not Set.isEmpty(Set.intersection(live#justPressed, settings#cancelKeys));
        if (cancelled) (Step.Advance(Input.Idle), { mode = Mode.Idle, snapshot = None, owed = Map.empty() | state })
        else if (assetsDone and codeDone) resume(watch#nowSec, world, stepState, wt, { gaveUp = Set.union(state#gaveUp, remaining) | state })
        else if (wt#pressed and not wt#frozen) (Step.Advance(Input.Idle), state)
        else (Step.Hold, state)

    /// 待ちが明けた時: 押した時の待ちは控えを今の World へ移して 1 コマ目を渡し直し、控えの外の待ちはこのコマの入力で進める。
    def resume(nowSec: Float64, world: w, stepState: App.StepState, wt: Wait, state: State[w]): (Step, State[w]) =
        match (wt#pressed, state#snapshot) {
            case (true, Some(s)) =>
                let moved = { world = world, stepState = stepState, atSec = nowSec, stored = Nil, played = Map.empty() | s };
                replayStep(0, { mode = Mode.Replaying(0), snapshot = Some(moved), owed = wt#chimed | state })
            case _ => (Step.Advance(Input.Live), { mode = Mode.Idle | state })
        }

    /// 進めた候補 1 つ。names = 描く物が名前で引く絵とフォント（と withLoadGate の名前）・sounds = 一発の音・loops = 鳴り続けていてほしい音・
    /// failed = 作る途中で後から取るコードがそろっていなかった・pressed = 押した瞬間を持つ入力で進めた・outputsChanged = 外への出力の鍵が変わる。
    pub type alias Candidate = { names = Set[String], sounds = List[String], loops = List[String], failed = Bool, pressed = Bool, outputsChanged = Bool }

    /// 照らす時に要る物。missing = まだ届いていない名前・policies = 届いていない名前の扱い（無い名前は種類の既定）・nowSec = 今の時刻・
    /// frame = 候補へ渡した入力・loaded = 進める前の World・stepState = 進める前の StepState・real = このコマで進めた実時間の時計・
    /// stored = このコマの store の記録・styleOf = 戻した World を進め続けるか。
    pub type alias Context[w] = { missing = Set[String], policies = Map[String, LoadProgress.MissingPolicy], nowSec = Float64,
                                  frame = App.Frame, loaded = w, stepState = App.StepState, real = Clock.Clock[Clock.Real],
                                  stored = List[w -> w], styleOf = w -> App.LoadWaitStyle }

    /// 照らした答え（どの World を出し、どの一発の音を鳴らすか）。Candidate = 候補を出す・Loaded = 候補を捨てて進める前の World を描き直す・
    /// Restored = 候補を捨てて押した所の控えへ戻す（戻した World と、実時間だけ進めた StepState）。
    pub enum Show[w] {
        case Candidate(List[String])
        case Loaded(List[String])
        case Restored(w, App.StepState, List[String])
    }

    /// 候補を照らす: 待つ名前に当たらなければ出し（控えを取る・積む・捨てる）、当たれば控えへ戻して押した時の待ちに入るか、
    /// 控えが無ければ進める前の World で止まる（控えの外の待ち）。
    pub def decide(candidate: Candidate, ctx: Context[w], state: State[w]): (Show[w], State[w]) =
        let hits = hitsOf(candidate, ctx, state#gaveUp);
        if (not candidate#failed and Set.isEmpty(hits)) emit(candidate, ctx, state)
        else match state#mode {
            case Mode.Waiting(wt) =>
                let more = { code = wt#code or candidate#failed, names = Set.union(wt#names, hits), frozen = true | wt };
                (Show.Loaded(Nil), { mode = Mode.Waiting(more) | state })
            case _ => enterWait(candidate, ctx, hits, state)
        }

    /// 候補を出す時: 渡し直しの音から引く数を引き、渡し直しを 1 コマ進め、控えを取る・積む・捨てる。
    def emit(candidate: Candidate, ctx: Context[w], state: State[w]): (Show[w], State[w]) =
        let (sounds, owed) = withoutOwed(candidate#sounds, state#owed);
        let frameCount = state#snapshot |> Option.map(s -> List.length(s#frames)) |> Option.getWithDefault(0);
        let mode = match state#mode {
            case Mode.Replaying(i) => if (i + 1 >= frameCount) Mode.Idle else Mode.Replaying(i + 1)
            case other             => other
        };
        let waiting = match state#mode {
            case Mode.Waiting(_) => true
            case _               => false
        };
        let snapshot = if (waiting) state#snapshot
                       else if (candidate#outputsChanged) None
                       else match state#snapshot {
                           case Some(s) => Some(withPress(candidate, ctx, state#mode, { stored = List.append(s#stored, ctx#stored), played = addCounts(s#played, sounds) | s }))
                           case None    => if (candidate#pressed and isIdleMode(state#mode)) Some(snapshotOf(ctx, sounds)) else None
                       };
        (Show.Candidate(sounds), { mode = mode, snapshot = snapshot, owed = if (Option.isEmpty(snapshot)) Map.empty() else owed | state })

    /// 控えが生きている間に押したコマ: 控えは取り直さず（押す前の World のまま）、その入力を渡し直すコマの末尾へ足す（次のコマを plan が足す）。
    /// 足すのは 16 コマまで。前の組の 2 コマ目を足したコマ（数が偶数でない時）は、そのコマが既に並んでいるので足さない。
    // WhyNot: 控えを最初の押した所に留めたまま、その後の押した入力を捨てない — 下を押してすぐ決定を押すと、決定が消えて押し直しになる。
    // WhyNot: 控えを後の押した所へ取り直さない — 暗転の途中で押し直すと、半分暗い所へ戻る。
    def withPress(candidate: Candidate, ctx: Context[w], mode: Mode, s: Snapshot[w]): Snapshot[w] =
        let count = List.length(s#frames);
        if (candidate#pressed and isIdleMode(mode) and Int32.modulo(count, 2) == 0 and count < 16)
            { frames = List.append(s#frames, ctx#frame :: Nil) | s }
        else s

    /// 待つ名前に当たった時（待っていない時か渡し直しの最中）: 控えがあるか、今のコマが押したコマなら控えへ戻して押した時の待ちに入る。
    /// 待つ名前は当たった名前・一緒に待つループの音・同じ group の残り。捨てた候補の届いている一発の音は、押した時に鳴らす。
    def enterWait(candidate: Candidate, ctx: Context[w], hits: Set[String], state: State[w]): (Show[w], State[w]) =
        let fresh = if (candidate#pressed and isIdleMode(state#mode)) Some(snapshotOf(ctx, Nil)) else None;
        let kept = state#snapshot |> Option.map(withPress(candidate, ctx, state#mode));
        match Option.withDefault(default = fresh, kept) {
            case Some(s) =>
                let restored = List.foldLeft((acc, replay) -> replay(acc), s#world, List.append(s#stored, ctx#stored));
                let chime = if (isIdleMode(state#mode)) candidate#sounds |> List.filter(name -> not Set.memberOf(name, ctx#missing)) else Nil;
                let names = Set.union(hits, joinedOf(candidate, ctx, hits, state#gaveUp));
                let wt = { code = candidate#failed, names = names, total = Set.size(names), startedSec = ctx#nowSec, pressed = true,
                           frozen = ctx#styleOf(restored) == App.LoadWaitStyle.Freeze,
                           chimed = addCounts(Map.unionWith((x, y) -> x + y, state#owed, s#played), chime) };
                (Show.Restored(restored, { real = ctx#real | s#stepState }, chime),
                 { mode = Mode.Waiting(wt), snapshot = Some({ world = restored, stored = Nil, played = Map.empty() | s }), owed = Map.empty() | state })
            case None =>
                let wt = { code = candidate#failed, names = hits, total = Set.size(hits), startedSec = ctx#nowSec, pressed = false,
                           frozen = true, chimed = Map.empty() };
                (Show.Loaded(Nil), { mode = Mode.Waiting(wt) | state })
        }

    /// 今のコマで取る控え（押す前の World と StepState・このコマの入力・このコマで鳴らした一発の音）。
    def snapshotOf(ctx: Context[w], sounds: List[String]): Snapshot[w] =
        { world = ctx#loaded, stepState = ctx#stepState, atSec = ctx#nowSec, frames = ctx#frame :: Nil, stored = Nil, played = addCounts(Map.empty(), sounds) }

    def isIdleMode(mode: Mode): Bool = match mode {
        case Mode.Idle => true
        case _         => false
    }

    /// 候補が待つ名前: 届いていない絵とフォントのうち placeholder でない物、届いていない音のうち onMissing が wait の物（諦めた名前は除く）。
    def hitsOf(candidate: Candidate, ctx: Context[w], gaveUp: Set[String]): Set[String] =
        let missingNow = name -> Set.memberOf(name, ctx#missing) and not Set.memberOf(name, gaveUp);
        let pictures = candidate#names |> Set.filter(name -> missingNow(name) and not isNoWait(onMissingOf(ctx#policies, name)));
        let sounds = List.append(candidate#sounds, candidate#loops)
            |> List.filter(name -> missingNow(name) and onMissingOf(ctx#policies, name) == Some(LoadProgress.OnMissing.Wait));
        List.foldLeft((acc, name) -> Set.insert(name, acc), pictures, sounds)

    /// 押した時の待ちで一緒に待つ名前: 候補の届いていないループの音（skip でない物）と、当たった名前と同じ group の届いていない名前。
    def joinedOf(candidate: Candidate, ctx: Context[w], hits: Set[String], gaveUp: Set[String]): Set[String] =
        let missingNow = name -> Set.memberOf(name, ctx#missing) and not Set.memberOf(name, gaveUp);
        let loops = candidate#loops |> List.filter(name -> missingNow(name) and not isNoWait(onMissingOf(ctx#policies, name))) |> List.toSet;
        let groups = hits |> Set.toList |> List.filterMap(name -> Map.get(name, ctx#policies) |> Option.flatMap(p -> p#group)) |> List.toSet;
        let members = if (Set.isEmpty(groups)) Set.empty()
                      else ctx#policies |> Map.filterWithKey((name, p) -> missingNow(name) and Option.exists(g -> Set.memberOf(g, groups), p#group)) |> Map.keysOf;
        Set.union(loops, members)

    def onMissingOf(policies: Map[String, LoadProgress.MissingPolicy], name: String): Option[LoadProgress.OnMissing] =
        Map.get(name, policies) |> Option.flatMap(p -> p#onMissing)

    def isNoWait(onMissing: Option[LoadProgress.OnMissing]): Bool =
        onMissing == Some(LoadProgress.OnMissing.Placeholder) or onMissing == Some(LoadProgress.OnMissing.Skip)

    /// 名前ごとの数に sounds を 1 つずつ足す。
    def addCounts(counts: Map[String, Int32], sounds: List[String]): Map[String, Int32] =
        List.foldLeft((acc, name) -> Map.insertWith((a, b) -> a + b, name, 1, acc), counts, sounds)

    /// sounds から owed の数だけ同じ名前を抜く（名前ごとに、引く数より多くは抜かない）。返すのは残った音と残った数。
    pub def withoutOwed(sounds: List[String], owed: Map[String, Int32]): (List[String], Map[String, Int32]) =
        let (kept, left) = List.foldLeft((acc, name) -> {
            let (out, counts) = acc;
            match Map.get(name, counts) {
                case Some(n) if n > 0 => (out, Map.insert(name, n - 1, counts))
                case _                => (name :: out, counts)
            }
        }, (Nil, owed), sounds);
        (List.reverse(kept), Map.filter(n -> n > 0, left))

    /// 機種と World へ知らせる今の待ち（待っていなければ None）。names はまだ届いていない名前（字の順）。
    pub def published(state: State[w], missing: Set[String], nowSec: Float64): Option[LoadProgress.LoadWait] = match state#mode {
        case Mode.Waiting(wt) =>
            let remaining = Set.intersection(wt#names, missing) |> Set.filter(name -> not Set.memberOf(name, state#gaveUp));
            let left = Set.size(remaining);
            Some({ reason = if (wt#code) LoadProgress.LoadWaitReason.Code else LoadProgress.LoadWaitReason.Assets,
                   names = Set.toList(remaining), waited = nowSec - wt#startedSec,
                   progress = if (wt#total <= 0) 0.0 else Int32.toFloat64(wt#total - left) / Int32.toFloat64(wt#total),
                   pressed = wt#pressed })
        case _ => None
    }

    /// 待つ名前の字（Runner が機種へ取れずに終わったかを問い合わせる名前）。待っていなければ空。
    pub def waitingNames(state: State[w]): Set[String] = match state#mode {
        case Mode.Waiting(wt) => wt#names
        case _                => Set.empty()
    }

    /// 後から取るコードがそろう前に呼ばれた時の、頁の置き場の関数が投げる例外の目印（message に含む ASCII の字）。
    pub def codeNotReadyMark(): String = "fge-code-not-ready"

    /// f を走らせ、後から取るコードがそろう前に呼ばれた例外（message に codeNotReadyMark を含む RuntimeException）だけを None で受ける。
    /// ほかの例外（bug! と Java の本物の誤り）は飲み込まずにそのまま投げ直す。
    pub def catchCodeNotReady(f: Unit -> a \ ef): Option[a] \ ef + IO =
        try { Some(f()) } catch {
            case e: RuntimeException =>
                let message = e.getMessage();
                if (not Object.isNull(message) and String.contains(substr = codeNotReadyMark(), message)) None
                else throw e
        }
}
