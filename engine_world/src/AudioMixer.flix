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
    /// （ダッキング中に音量を流し直すため）、levels はバスごとの今の値と移る先（Level）、
    /// sustainedBuses はこのフレームに鳴り続ける音の宣言があったバス（宣言が続く間は dt によらず「鳴っている」）、
    /// busDucks はバスごとのダッキングの倍率の積（音量を読むたびに掛け直さないよう、寄せたときに 1 度だけ作る）。
    pub type alias State = {
        now = Float64,
        lastPlay = Map[String, Float64],
        busyUntil = Map[String, Float64],
        ducks = Map[String, Float64],
        voices = Map[String, Float64],
        levels = Map[String, Level],
        sustainedBuses = Set[String],
        busDucks = Map[String, Float64]
    }

    /// バス 1 本の今の値と、移っている先。移り始めに「1 秒あたりの速さ」を決めて覚えるので、
    /// 値の距離によらず transitionSeconds でちょうど移り切る。
    pub type alias Level = {
        volume = Float64, gainHF = Float64,
        targetVolume = Float64, targetGainHF = Float64,
        volumeSpeed = Float64, gainHFSpeed = Float64
    }

    /// 何もしないミキサー（全部の音が音量 1・素通し・間引きなし）。Doc が無いときの既定。
    pub def defaults(): Mixer =
        { buses = Nil, routes = Nil, defaultBus = "sfx", ducks = Nil, cooldowns = Nil,
          snapshots = Nil, transitionSeconds = 0.0 }

    /// 鳴らし始める前の状態。
    pub def initial(): State =
        { now = 0.0, lastPlay = Map.empty(), busyUntil = Map.empty(), ducks = Map.empty(),
          voices = Map.empty(), levels = Map.empty(), sustainedBuses = Set.empty(), busDucks = Map.empty() }

    // ========================================================================
    // 振り分けと値の読み出し
    // ========================================================================

    /// 音の名前が流れるバスの名前（routes の prefixes の一番長い一致。無ければ defaultBus）。
    pub def busOf(mixer: Mixer, name: String): String =
        // 毎フレーム音の数だけ呼ばれるので、途中のリストを作らずに一番長い一致を数える。
        let (_, bus) = mixer#routes |> List.foldLeft((best, r) ->
            r#prefixes |> List.foldLeft((acc, p) -> {
                let (len, _) = acc;
                let n = String.length(p);
                if (n > len and String.startsWith(prefix = p, name)) (n, r#bus) else acc
            }, best), (-1, mixer#defaultBus));
        bus

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
        fst(levelOf(mixer, state, bus)) * duckGainOf(state, bus)

    /// バスの今の高い音の残り具合（スナップショットへ移る途中なら途中の値）。
    pub def busLowpassGainHFOf(mixer: Mixer, state: State, bus: String): Float64 =
        snd(levelOf(mixer, state, bus))

    /// バスの今の (音量, lowpassGainHF)。移っている途中ならその途中の値、まだ鳴らしていないバスは Doc の値。
    def levelOf(mixer: Mixer, state: State, bus: String): (Float64, Float64) =
        match Map.get(bus, state#levels) {
            case Some(level) => (level#volume, level#gainHF)
            case None        => targetOf(mixer, bus)
        }

    def targetOf(mixer: Mixer, bus: String): (Float64, Float64) =
        let b = getBus(mixer, bus);
        (clamp01(b#volume), clamp01(b#lowpassGainHF))

    /// バスに掛かっているダッキングの倍率（同じバスへ何本掛かっていても掛け算）。
    pub def duckGainOf(state: State, bus: String): Float64 =
        Map.get(bus, state#busDucks) |> Option.getWithDefault(1.0)

    /// ダッキングの状態のキー（下げるバスと、下げさせるバスの組）。Doc の ducks の行の並びを
    /// 入れ替えても、by の中の並びを入れ替えても、同じダッキングの倍率が引き継がれる。
    def duckKeyOf(d: Duck): String = "${d#bus}<-${String.intercalate(",", List.sort(d#by))}"

    /// 名前に掛かるクールダウンの秒（cooldowns の prefix の一番長い一致。無ければ 0 = 間引かない）。
    pub def cooldownOf(mixer: Mixer, name: String): Float64 =
        let (_, seconds) = mixer#cooldowns |> List.foldLeft((acc, c) -> {
            let (len, _) = acc;
            let n = String.length(c#prefix);
            if (n > len and String.startsWith(prefix = c#prefix, name)) (n, c#seconds) else acc
        }, (-1, 0.0));
        seconds

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

    /// 1 フレームぶんを決まった順で進める: 時計とバスの値を進め（advance）→ 一発の音をクールダウンに
    /// 通し（applyCooldowns）→ 鳴り続けている音のバスを「このフレームに鳴っている」と記し
    /// （markSustainedBusy）→ ダッキングを寄せる（stepDucks）。鳴り始めを記してから寄せるので、
    /// 効果音が鳴ったそのフレームから曲が下がり始める。返すのは実際に鳴らす一発の音の名前。
    /// lengthOf は音の長さ（秒）—— ダッキングが「鳴っている間」を知るのに使う。
    pub def step(mixer: Mixer, lengthOf: String -> Float64 \ ef, dt: Float64,
                 plays: List[String], sustained: List[String], state: State): (List[String], State) \ ef =
        let (allowed, played) = applyCooldowns(mixer, lengthOf, plays, advance(mixer, dt, state));
        (allowed, stepDucks(mixer, dt, markSustainedBusy(mixer, sustained, played)))

    /// ダッキングの倍率を目標へ寄せる（鳴っているかは、このフレームの鳴り始めと続く音の宣言まで含めて見る）。
    def stepDucks(mixer: Mixer, dt: Float64, state: State): State =
        let elapsed = Float64.max(0.0, dt);
        let (ducks, busDucks) = mixer#ducks |> List.foldLeft((acc, d) -> {
            let (byKey, byBus) = acc;
            let key = duckKeyOf(d);
            let current = Map.get(key, state#ducks) |> Option.getWithDefault(1.0);
            let next = stepDuck(d, isBusy(d, state#now, state), elapsed, current);
            (Map.insert(key, next, byKey), Map.insertWith((a, b) -> a * b, d#bus, next, byBus))
        }, (Map.empty(), Map.empty()));
        { ducks = ducks, busDucks = busDucks | state }

    /// 時計を dt 秒進め、バスの値を移る先へ寄せ、鳴り終わった一発の音を voices から外す。
    def advance(mixer: Mixer, dt: Float64, state: State): State =
        let elapsed = Float64.max(0.0, dt);
        let now = state#now + elapsed;
        // routes・ducks・defaultBus に出てくるバスも最初から値を追う（スナップショットで初めて
        // buses に載ったバスが、その拍に新しい値へ飛ばないように）。
        let named = Map.keysOf(state#levels)
            |> Set.insert(mixer#defaultBus)
            |> (s -> List.foldLeft((acc, b) -> Set.insert(b#name, acc), s, mixer#buses))
            |> (s -> List.foldLeft((acc, r) -> Set.insert(r#bus, acc), s, mixer#routes))
            |> (s -> List.foldLeft((acc, d) -> Set.insert(d#bus, acc), s, mixer#ducks));
        let levels = named |> Set.foldLeft((acc, bus) ->
            Map.insert(bus, stepLevel(targetOf(mixer, bus), mixer#transitionSeconds, elapsed, Map.get(bus, state#levels)), acc),
            Map.empty());
        { now = now, levels = levels,
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

    /// 鳴り続けている音（withSustained の宣言）のバスを「このフレームに鳴っている」と記す
    /// （by に入ったバスの続く音 —— 声のループや足音 —— でも BGM が下がる）。宣言が続く間は
    /// フレームの長さ（dt）によらず鳴っている扱いで、宣言が消えたら最後に宣言した時刻から holdSeconds を数える。
    def markSustainedBusy(mixer: Mixer, names: List[String], state: State): State =
        let buses = names |> List.map(name -> busOf(mixer, name)) |> List.toSet;
        buses |> Set.foldLeft((s, bus) -> markBusy(bus, s#now, s), { sustainedBuses = buses | state })

    def markBusy(bus: String, until: Float64, state: State): State =
        let was = Map.get(bus, state#busyUntil) |> Option.getWithDefault(-1.0);
        { busyUntil = Map.insert(bus, Float64.max(was, until), state#busyUntil) | state }

    /// 鳴り終わりの時刻 + holdSeconds までを「鳴っている」に数える（ちょうどの拍も含める）。
    def isBusy(d: Duck, now: Float64, state: State): Bool =
        d#by |> List.exists(bus -> Set.memberOf(bus, state#sustainedBuses) or (match Map.get(bus, state#busyUntil) {
            case Some(until) => now <= until + d#holdSeconds
            case None        => false
        }))

    /// 倍率を目標（鳴っている間は depth・それ以外は 1）へ一定の速さで寄せる。
    /// 速さは「下げ幅を attack / release 秒で渡り切る」速さ（0 秒なら一気に）。
    def stepDuck(d: Duck, busy: Bool, dt: Float64, current: Float64): Float64 =
        let depth = clamp01(d#depth);
        let span = 1.0 - depth;
        let (target, seconds) = if (busy) (depth, d#attackSeconds) else (1.0, d#releaseSeconds);
        if (seconds <= 0.0 or span <= 0.0) target
        else approachBy(current, target, span * dt / seconds)

    /// バスの値を移る先へ寄せる。移る先が変わった拍に「残りの距離 ÷ seconds」を速さとして覚え、
    /// 以後はその速さで進む（距離によらず seconds でちょうど移り切る。0 秒なら一気に）。
    def stepLevel(target: (Float64, Float64), seconds: Float64, dt: Float64, prev: Option[Level]): Level =
        let (tv, tl) = target;
        match prev {
            case None    => { volume = tv, gainHF = tl, targetVolume = tv, targetGainHF = tl, volumeSpeed = 0.0, gainHFSpeed = 0.0 }
            // 着いていて移る先も変わらなければ、作り直さずにそのまま返す（毎フレームの割り当てを減らす）。
            case Some(p) if p#volume == tv and p#gainHF == tl and p#targetVolume == tv and p#targetGainHF == tl => p
            case Some(p) =>
                let speedOf = (current, newTarget, oldTarget, oldSpeed) ->
                    if (newTarget != oldTarget) (if (seconds <= 0.0) 1000000.0 else Float64.abs(newTarget - current) / seconds)
                    else oldSpeed;
                let vs = speedOf(p#volume, tv, p#targetVolume, p#volumeSpeed);
                let ls = speedOf(p#gainHF, tl, p#targetGainHF, p#gainHFSpeed);
                { volume = approachBy(p#volume, tv, vs * dt), gainHF = approachBy(p#gainHF, tl, ls * dt),
                  targetVolume = tv, targetGainHF = tl, volumeSpeed = vs, gainHFSpeed = ls }
        }

    def approachBy(current: Float64, target: Float64, stepSize: Float64): Float64 =
        if (current > target) Float64.max(target, current - stepSize)
        else Float64.min(target, current + stepSize)

    def clamp01(x: Float64): Float64 = Float64.max(0.0, Float64.min(1.0, x))
}
