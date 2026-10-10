// AudioMixer — 音の通り道（ミキサー）。鳴らす音を「バス」（BGM・効果音・UI・声 のような束）に
// 振り分け、バスごとの音量・高い音を削る量（ローパス）・ダッキング・連打の間引き（クールダウン）・
// 場面ごとの聞こえ方（スナップショット）を決める。Godot の Audio Bus・Unity の AudioMixer
// （Group / Snapshot / Duck Volume）・FMOD の Cooldown と同じ考え方で、ここは計算だけを持つ
// （状態は State に入れて呼ぶ側が持ち回す。実機は App、WAV の書き出しは AudioMixdown が
// 同じ step を呼ぶので、実機と書き出しで聞こえ方の規則が同じになる）。
//
// 使い方（ゲーム側は mixer.json を用意して App に繋ぐだけ）:
//
//     App.make(initialWorld)
//         |> App.withAudio(Sfx.events)
//         |> App.withSustained(Sfx.hums)
//         |> App.withMixer(w -> w.mixer)   // AudioMixerDoc.load で読んだ Mixer。場面で差し替えてよい
//
// - 振り分け（routes）: バスごとに「名前の頭（prefixes）」を並べる。長く一致した方が勝ち。
//   どれにも当たらない音は defaultBus へ。
// - ダッキング（ducks）: by のバスで音が鳴っている間（一発の音は鳴り始めから音の長さ、
//   鳴り続ける音は宣言が続く間。どちらも + holdSeconds）、bus の音量を depth 倍まで
//   attackSeconds かけて下げ、鳴り終わったら releaseSeconds かけて戻す。
// - ローパス（Bus.lowpassGainHF）: 高い音の残り具合 0〜1（1 = 素通し）。OpenAL の EFX の
//   lowpass と同じ意味（5000Hz より上をこの倍率まで落とす）で、籠もった感じ・壁の向こうの音に使う。
// - クールダウン（cooldowns）: 同じ名前の音が seconds 以内にもう一度来たら鳴らさない。
//   1 つの音は同時に 1 本しか鳴らないので（鳴り直すと頭から）、細かい連打は頭だけの音になる。
// - スナップショット（snapshots）: 名前つきの上書きの束。withSnapshot で選ぶと、バスの音量と
//   ローパスは transitionSeconds かけて新しい値へなめらかに移る（値を 1 フレームで飛ばさない）。
pub mod AudioMixer {

    /// バス 1 本。volume は 0.0〜1.0（設定画面の「BGM の音量」のつまみ）、
    /// lowpassGainHF は高い音の残り具合 0.0〜1.0（1.0 = 素通し・0.1 前後で籠もる）。
    pub type alias Bus = { name = String, volume = Float64, lowpassGainHF = Float64 }

    /// 名前の頭が prefixes のどれかに当たる音を bus へ流す（"bgm" → music のように）。
    pub type alias Route = { bus = String, prefixes = List[String] }

    /// by のバスのどれかが鳴っている間、bus の音量を depth 倍へ下げる。
    /// holdSeconds は鳴り終わってから戻り始めるまでの間（短い音が続くときにばたつかせない）。
    pub type alias Duck = {
        bus = String, by = List[String], depth = Float64,
        attackSeconds = Float64, holdSeconds = Float64, releaseSeconds = Float64
    }

    /// 名前の頭が prefix の音は、同じ名前が seconds 以内に続いたら鳴らさない。
    pub type alias Cooldown = { prefix = String, seconds = Float64 }

    /// スナップショットの中のバス 1 本の上書き（None の欄は元のまま）。
    pub type alias BusOverride = { name = String, volume = Option[Float64], lowpassGainHF = Option[Float64] }

    /// 名前つきの「場面ごとの聞こえ方」。会話の間は曲を籠もらせる・ポーズ中は効果音を絞る、
    /// のような上書きの束を Doc に置き、コードは withSnapshot で名前を選ぶだけにする。
    pub type alias Snapshot = { name = String, buses = List[BusOverride] }

    /// ミキサー全体の宣言（AudioMixerDoc が JSON から作る）。transitionSeconds は
    /// バスの音量・ローパスが新しい値へ移り切るまでの秒（0 = 一気に）。
    pub type alias Mixer = {
        buses = List[Bus], routes = List[Route], defaultBus = String,
        ducks = List[Duck], cooldowns = List[Cooldown], snapshots = List[Snapshot],
        transitionSeconds = Float64
    }

    /// 持ち回す状態。now は経過秒、lastPlay は名前ごとの最後の鳴り始め、
    /// busyUntil はバスごとの「いつまで鳴っているか」、ducks はダッキングごとの今の倍率
    /// （キーは duckKeyOf）、voices は鳴っている一発の音の名前と鳴り終わる時刻
    /// （ダッキング中に音量を流し直すため）、levels はバスごとの今の (音量, lowpassGainHF)。
    pub type alias State = {
        now = Float64,
        lastPlay = Map[String, Float64],
        busyUntil = Map[String, Float64],
        ducks = Map[String, Float64],
        voices = Map[String, Float64],
        levels = Map[String, (Float64, Float64)]
    }

    /// 何もしないミキサー（全部の音が音量 1・素通し・間引きなし）。Doc が無いときの既定。
    pub def defaults(): Mixer =
        { buses = Nil, routes = Nil, defaultBus = "sfx", ducks = Nil, cooldowns = Nil,
          snapshots = Nil, transitionSeconds = 0.0 }

    /// 鳴らし始める前の状態。
    pub def initial(): State =
        { now = 0.0, lastPlay = Map.empty(), busyUntil = Map.empty(), ducks = Map.empty(),
          voices = Map.empty(), levels = Map.empty() }

    // ========================================================================
    // 振り分けと値の読み出し
    // ========================================================================

    /// 音の名前が流れるバスの名前（routes の prefixes の一番長い一致。無ければ defaultBus）。
    pub def busOf(mixer: Mixer, name: String): String =
        mixer#routes
            |> List.flatMap(r -> List.map(p -> (p, r#bus), r#prefixes))
            |> List.filter(pair -> String.startsWith(prefix = fst(pair), name))
            |> List.maximumBy((a, b) -> String.length(fst(a)) <=> String.length(fst(b)))
            |> Option.map(snd)
            |> Option.getWithDefault(mixer#defaultBus)

    /// バスの宣言（Doc に無いバスは音量 1・素通し）。
    pub def getBus(mixer: Mixer, bus: String): Bus =
        mixer#buses
            |> List.find(b -> b#name == bus)
            |> Option.getWithDefault({ name = bus, volume = 1.0, lowpassGainHF = 1.0 })

    /// 音 1 本に掛ける音量の倍率 = 流れるバスの busGainOf。
    pub def gainOf(mixer: Mixer, state: State, name: String): Float64 =
        busGainOf(mixer, state, busOf(mixer, name))

    /// 音 1 本の高い音の残り具合（流れるバスの今の lowpassGainHF）。
    pub def lowpassGainHFOf(mixer: Mixer, state: State, name: String): Float64 =
        busLowpassGainHFOf(mixer, state, busOf(mixer, name))

    /// バスの音量の倍率 = バスの今の音量 × そのバスに掛かっているダッキング。
    pub def busGainOf(mixer: Mixer, state: State, bus: String): Float64 =
        fst(levelOf(mixer, state, bus)) * duckGainOf(mixer, state, bus)

    /// バスの今の高い音の残り具合（スナップショットへ移る途中なら途中の値）。
    pub def busLowpassGainHFOf(mixer: Mixer, state: State, bus: String): Float64 =
        snd(levelOf(mixer, state, bus))

    /// バスの今の (音量, lowpassGainHF)。移っている途中ならその途中の値、まだ鳴らしていないバスは Doc の値。
    def levelOf(mixer: Mixer, state: State, bus: String): (Float64, Float64) =
        match Map.get(bus, state#levels) {
            case Some(level) => level
            case None        => targetOf(mixer, bus)
        }

    def targetOf(mixer: Mixer, bus: String): (Float64, Float64) =
        let b = getBus(mixer, bus);
        (clamp01(b#volume), clamp01(b#lowpassGainHF))

    /// バスに掛かっているダッキングの倍率（同じバスへ何本掛かっていても掛け算）。
    pub def duckGainOf(mixer: Mixer, state: State, bus: String): Float64 =
        mixer#ducks
            |> List.filter(d -> d#bus == bus)
            |> List.foldLeft((acc, d) -> acc * (Map.get(duckKeyOf(d), state#ducks) |> Option.getWithDefault(1.0)), 1.0)

    /// ダッキングの状態のキー（下げるバスと、下げさせるバスの組）。並びを入れ替えても引き継がれる。
    def duckKeyOf(d: Duck): String = "${d#bus}<-${String.intercalate(",", d#by)}"

    /// 名前に掛かるクールダウンの秒（cooldowns の prefix の一番長い一致。無ければ 0 = 間引かない）。
    pub def cooldownOf(mixer: Mixer, name: String): Float64 =
        mixer#cooldowns
            |> List.filter(c -> String.startsWith(prefix = c#prefix, name))
            |> List.maximumBy((a, b) -> String.length(a#prefix) <=> String.length(b#prefix))
            |> Option.map(c -> c#seconds)
            |> Option.getWithDefault(0.0)

    // ========================================================================
    // 場面ごとの差し替え（Doc の値の上に、その場面だけ上書きする）
    // ========================================================================

    /// bus の音量を差し替えた新しいミキサー（Doc に無いバスなら足す）。
    pub def withBusVolume(bus: String, volume: Float64, mixer: Mixer): Mixer =
        updateBus(bus, b -> { volume = clamp01(volume) | b }, mixer)

    /// bus の高い音の残り具合を差し替えた新しいミキサー（夜の場面だけ籠もらせる、など）。
    pub def withLowpassGainHF(bus: String, gainHF: Float64, mixer: Mixer): Mixer =
        updateBus(bus, b -> { lowpassGainHF = clamp01(gainHF) | b }, mixer)

    /// 名前のスナップショットを重ねた新しいミキサー（無い名前なら元のまま）。
    /// 実際の音は transitionSeconds かけて新しい値へ移る（step が State の levels を寄せる）。
    pub def withSnapshot(name: String, mixer: Mixer): Mixer =
        match List.find(snap -> snap#name == name, mixer#snapshots) {
            case None       => mixer
            case Some(snap) => snap#buses |> List.foldLeft((m, o) -> {
                let withVolume = match o#volume {
                    case Some(v) => withBusVolume(o#name, v, m)
                    case None    => m
                };
                match o#lowpassGainHF {
                    case Some(v) => withLowpassGainHF(o#name, v, withVolume)
                    case None    => withVolume
                }
            }, mixer)
        }

    def updateBus(bus: String, f: Bus -> Bus, mixer: Mixer): Mixer =
        let current = getBus(mixer, bus);
        { buses = f(current) :: List.filter(b -> b#name != bus, mixer#buses) | mixer }

    // ========================================================================
    // 1 フレームの進め方（App と AudioMixdown が同じ順で呼ぶ）
    // ========================================================================

    /// 1 フレームぶんを決まった順で進める: 時計・ダッキング・バスの値を進め（advance）→
    /// 一発の音をクールダウンに通し（applyCooldowns）→ 鳴り続けている音のバスを
    /// 「次のフレームまで鳴っている」と記す（markSustainedBusy）。返すのは実際に鳴らす一発の音の名前。
    /// lengthOf は音の長さ（秒）—— ダッキングが「鳴っている間」を知るのに使う。
    pub def step(mixer: Mixer, lengthOf: String -> Float64 \ ef, dt: Float64,
                 plays: List[String], sustained: List[String], state: State): (List[String], State) \ ef =
        let (allowed, played) = applyCooldowns(mixer, lengthOf, plays, advance(mixer, dt, state));
        (allowed, markSustainedBusy(mixer, dt, sustained, played))

    /// 時計を dt 秒進め、ダッキングの倍率とバスの値を目標へ寄せ、鳴り終わった一発の音を voices から外す。
    pub def advance(mixer: Mixer, dt: Float64, state: State): State =
        let elapsed = Float64.max(0.0, dt);
        let now = state#now + elapsed;
        let ducks = mixer#ducks |> List.foldLeft((acc, d) -> {
            let key = duckKeyOf(d);
            let current = Map.get(key, state#ducks) |> Option.getWithDefault(1.0);
            Map.insert(key, stepDuck(d, isBusy(d, now, state), elapsed, current), acc)
        }, Map.empty());
        // routes・ducks・defaultBus に出てくるバスも最初から値を追う（スナップショットで初めて
        // buses に載ったバスが、その拍に新しい値へ飛ばないように）。
        let buses = List.flatten(
                List.map(b -> b#name, mixer#buses) :: List.map(r -> r#bus, mixer#routes) ::
                List.map(d -> d#bus, mixer#ducks) :: (mixer#defaultBus :: Nil) ::
                (Map.keysOf(state#levels) |> Set.toList) :: Nil)
            |> List.distinct;
        let levels = buses |> List.foldLeft((acc, bus) -> {
            let (tv, tl) = targetOf(mixer, bus);
            let (cv, cl) = Map.get(bus, state#levels) |> Option.getWithDefault((tv, tl));
            Map.insert(bus, (approach(cv, tv, elapsed, mixer#transitionSeconds),
                             approach(cl, tl, elapsed, mixer#transitionSeconds)), acc)
        }, Map.empty());
        { now = now, ducks = ducks, levels = levels,
          voices = Map.filter(endsAt -> endsAt > now, state#voices) | state }

    /// このフレームに鳴らしたい一発の音をクールダウンに通す。返すのは「実際に鳴らす名前」と、
    /// 鳴り始め（lastPlay）と鳴り終わり（busyUntil・voices）を刻んだ状態。
    pub def applyCooldowns(mixer: Mixer, lengthOf: String -> Float64 \ ef, names: List[String], state: State):
            (List[String], State) \ ef =
        let (rev, next) = List.distinct(names) |> List.foldLeft((acc, name) -> {
            let (kept, s) = acc;
            let cooldown = cooldownOf(mixer, name);
            let tooSoon = match Map.get(name, s#lastPlay) {
                case Some(at) => cooldown > 0.0 and s#now - at < cooldown
                case None     => false
            };
            if (tooSoon) acc
            else {
                let endsAt = s#now + Float64.max(0.0, lengthOf(name));
                (name :: kept, markBusy(busOf(mixer, name), endsAt,
                    { lastPlay = Map.insert(name, s#now, s#lastPlay),
                      voices = Map.insert(name, endsAt, s#voices) | s }))
            }
        }, (Nil, state));
        (List.reverse(rev), next)

    /// 鳴り続けている音（withSustained の宣言）のバスを「次のフレームまで鳴っている」と記す
    /// （by に入ったバスの続く音 —— 声のループや足音 —— でも BGM が下がる）。
    pub def markSustainedBusy(mixer: Mixer, dt: Float64, names: List[String], state: State): State =
        names |> List.foldLeft((s, name) -> markBusy(busOf(mixer, name), s#now + Float64.max(0.0, dt), s), state)

    def markBusy(bus: String, until: Float64, state: State): State =
        let was = Map.get(bus, state#busyUntil) |> Option.getWithDefault(-1.0);
        { busyUntil = Map.insert(bus, Float64.max(was, until), state#busyUntil) | state }

    /// 鳴り終わりの時刻 + holdSeconds までを「鳴っている」に数える（ちょうどの拍も含める）。
    def isBusy(d: Duck, now: Float64, state: State): Bool =
        d#by |> List.exists(bus -> match Map.get(bus, state#busyUntil) {
            case Some(until) => now <= until + d#holdSeconds
            case None        => false
        })

    /// 倍率を目標（鳴っている間は depth・それ以外は 1）へ一定の速さで寄せる。
    /// 速さは「下げ幅を attack / release 秒で渡り切る」速さ（0 秒なら一気に）。
    def stepDuck(d: Duck, busy: Bool, dt: Float64, current: Float64): Float64 =
        let depth = clamp01(d#depth);
        let span = 1.0 - depth;
        let (target, seconds) = if (busy) (depth, d#attackSeconds) else (1.0, d#releaseSeconds);
        if (seconds <= 0.0 or span <= 0.0) target
        else approachBy(current, target, span * dt / seconds)

    /// 0〜1 の値を target へ「全幅を seconds 秒で渡る」速さで寄せる（0 秒なら一気に）。
    def approach(current: Float64, target: Float64, dt: Float64, seconds: Float64): Float64 =
        if (seconds <= 0.0) target else approachBy(current, target, dt / seconds)

    def approachBy(current: Float64, target: Float64, stepSize: Float64): Float64 =
        if (current > target) Float64.max(target, current - stepSize)
        else Float64.min(target, current + stepSize)

    def clamp01(x: Float64): Float64 = Float64.max(0.0, Float64.min(1.0, x))
}
