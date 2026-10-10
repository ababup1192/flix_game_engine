// AudioMixer — 音の通り道（ミキサー）。鳴らす音を「バス」（BGM・効果音・UI・声 のような束）に
// 振り分け、バスごとの音量・高い音を削る量（ローパス）・ダッキング・連打の間引きを決める。
// Godot の Audio Bus・Unity の AudioMixer Group と同じ考え方で、ここは計算だけを持つ
// （状態は State に入れて呼ぶ側が持ち回す。実機は App、WAV の書き出しは AudioMixdown が同じ関数を呼ぶ）。
//
// 使い方（ゲーム側は Doc を用意して App に繋ぐだけ）:
//
//     App.make(initialWorld)
//         |> App.withAudio(Sfx.events)
//         |> App.withSustained(Sfx.hums)
//         |> App.withMixer(w -> w.mixer)      // AudioMixerDoc で読んだ Mixer。場面で差し替えてよい
//
// - 振り分け（routes）: 音の名前の頭（prefix）でバスを選ぶ。長く一致した方が勝ち。
//   どれにも当たらない音は defaultBus へ。
// - ダッキング（ducks）: by のバスで音が鳴っている間（鳴り始めから音の長さ + holdSeconds）、
//   bus の音量を depth 倍まで attackSeconds かけて下げ、鳴り終わったら releaseSeconds かけて戻す。
//   「効果音が鳴る間だけ BGM を少し下げる」はこれ 1 行で書ける。
// - ローパス（Bus.lowpass）: 高い音の残り具合 0〜1（1 = 素通し）。OpenAL の EFX の
//   lowpass（5000Hz より上をこの倍率まで落とす）と同じ意味で、夜の籠もった感じ・水の中・
//   壁の向こうの音に使う。
// - 連打の間引き（limits）: 同じ名前の音が cooldownSeconds 以内にもう一度来たら鳴らさない。
//   1 つの音は同時に 1 本しか鳴らないので（鳴り直すと頭から）、間引かないと細かい連打が
//   頭だけ繰り返す音になる。
pub mod AudioMixer {

    /// バス 1 本。volume は 0.0〜1.0（設定画面の「BGM の音量」のつまみ）、
    /// lowpass は高い音の残り具合 0.0〜1.0（1.0 = 素通し・0.1 で籠もる）。
    pub type alias Bus = { name = String, volume = Float64, lowpass = Float64 }

    /// 名前の頭が prefix の音を bus へ流す（"bgm" → music のように）。
    pub type alias Route = { prefix = String, bus = String }

    /// by のバスのどれかが鳴っている間、bus の音量を depth 倍へ下げる。
    /// holdSeconds は鳴り終わってから戻り始めるまでの間（短い音が続くときにばたつかせない）。
    pub type alias Duck = {
        bus = String, by = List[String], depth = Float64,
        attackSeconds = Float64, holdSeconds = Float64, releaseSeconds = Float64
    }

    /// 名前の頭が prefix の音は、同じ名前が cooldownSeconds 以内に続いたら鳴らさない。
    pub type alias Limit = { prefix = String, cooldownSeconds = Float64 }

    /// スナップショットの中のバス 1 本の上書き（None の欄は元のまま）。
    pub type alias BusOverride = { name = String, volume = Option[Float64], lowpass = Option[Float64] }

    /// 名前つきの「場面ごとの聞こえ方」（Unity の AudioMixer の Snapshot と同じ考え方）。
    /// 会話の間は曲を籠もらせる・ポーズ中は効果音を絞る、のような上書きの束を Doc に置き、
    /// コードは withSnapshot で名前を選ぶだけにする。
    pub type alias Snapshot = { name = String, buses = List[BusOverride] }

    /// ミキサー全体の宣言（AudioMixerDoc が JSON から作る）。
    pub type alias Mixer = {
        buses = List[Bus], routes = List[Route], defaultBus = String,
        ducks = List[Duck], limits = List[Limit], snapshots = List[Snapshot]
    }

    /// 持ち回す状態。now は経過秒、lastPlay は名前ごとの最後の鳴り始め、
    /// busyUntil はバスごとの「いつまで鳴っているか」、ducks はダッキングごとの今の倍率、
    /// voices は鳴っている一発の音の名前と鳴り終わる時刻（ダッキング中に音量を流し直すため）。
    pub type alias State = {
        now = Float64,
        lastPlay = Map[String, Float64],
        busyUntil = Map[String, Float64],
        ducks = Map[Int32, Float64],
        voices = Map[String, Float64]
    }

    /// 何もしないミキサー（全部の音が音量 1・素通し・間引きなし）。
    pub def passthrough(): Mixer =
        { buses = Nil, routes = Nil, defaultBus = "sfx", ducks = Nil, limits = Nil, snapshots = Nil }

    /// 鳴らし始める前の状態。
    pub def initial(): State =
        { now = 0.0, lastPlay = Map.empty(), busyUntil = Map.empty(), ducks = Map.empty(), voices = Map.empty() }

    // ========================================================================
    // 振り分けと値の読み出し
    // ========================================================================

    /// 音の名前が流れるバスの名前（routes の prefix の一番長い一致。無ければ defaultBus）。
    pub def busOf(mixer: Mixer, name: String): String =
        mixer#routes
            |> List.filter(r -> String.startsWith(prefix = r#prefix, name))
            |> List.maximumBy((a, b) -> String.length(a#prefix) <=> String.length(b#prefix))
            |> Option.map(r -> r#bus)
            |> Option.getWithDefault(mixer#defaultBus)

    /// バスの宣言（Doc に無いバスは音量 1・素通し）。
    pub def getBus(mixer: Mixer, bus: String): Bus =
        mixer#buses
            |> List.find(b -> b#name == bus)
            |> Option.getWithDefault({ name = bus, volume = 1.0, lowpass = 1.0 })

    /// 音 1 本に掛ける音量の倍率 = バスの音量 × そのバスに掛かっているダッキング。
    pub def gainOf(mixer: Mixer, state: State, name: String): Float64 =
        let bus = busOf(mixer, name);
        getBus(mixer, bus)#volume * duckGainOf(mixer, state, bus)

    /// 音 1 本の高い音の残り具合（そのバスの lowpass）。
    pub def lowpassOf(mixer: Mixer, name: String): Float64 =
        clamp01(getBus(mixer, busOf(mixer, name))#lowpass)

    /// バスに掛かっているダッキングの倍率（同じバスへ何本掛かっていても掛け算）。
    pub def duckGainOf(mixer: Mixer, state: State, bus: String): Float64 =
        List.zip(List.range(0, List.length(mixer#ducks)), mixer#ducks)
            |> List.filter(p -> snd(p)#bus == bus)
            |> List.foldLeft((acc, p) -> acc * (Map.get(fst(p), state#ducks) |> Option.getWithDefault(1.0)), 1.0)

    /// 名前に掛かる連打の間引きの秒（limits の prefix の一番長い一致。無ければ 0 = 間引かない）。
    pub def cooldownOf(mixer: Mixer, name: String): Float64 =
        mixer#limits
            |> List.filter(l -> String.startsWith(prefix = l#prefix, name))
            |> List.maximumBy((a, b) -> String.length(a#prefix) <=> String.length(b#prefix))
            |> Option.map(l -> l#cooldownSeconds)
            |> Option.getWithDefault(0.0)

    // ========================================================================
    // 場面ごとの差し替え（Doc の値の上に、その場面だけ上書きする）
    // ========================================================================

    /// bus の音量を差し替えた新しいミキサー（Doc に無いバスなら足す）。
    pub def withBusVolume(bus: String, volume: Float64, mixer: Mixer): Mixer =
        updateBus(bus, b -> { volume = clamp01(volume) | b }, mixer)

    /// bus の高い音の残り具合を差し替えた新しいミキサー（夜の場面だけ籠もらせる、など）。
    pub def withLowpass(bus: String, lowpass: Float64, mixer: Mixer): Mixer =
        updateBus(bus, b -> { lowpass = clamp01(lowpass) | b }, mixer)

    /// 名前のスナップショットを重ねた新しいミキサー（無い名前なら元のまま）。
    pub def withSnapshot(name: String, mixer: Mixer): Mixer =
        match List.find(snap -> snap#name == name, mixer#snapshots) {
            case None       => mixer
            case Some(snap) => snap#buses |> List.foldLeft((m, o) -> {
                let withVolume = match o#volume {
                    case Some(v) => withBusVolume(o#name, v, m)
                    case None    => m
                };
                match o#lowpass {
                    case Some(v) => withLowpass(o#name, v, withVolume)
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

    /// 1 フレームぶんを決まった順で進める: 時計とダッキングを進め（advance）→ 一発の音を間引きに通し
    /// （admit）→ 鳴り続けている音のバスを「鳴っている」に数える（holdSustained）。
    /// 実機（App）と WAV の書き出し（AudioMixdown）はどちらもこれを呼ぶので、聞こえ方が同じになる。
    pub def step(mixer: Mixer, lengthOf: String -> Float64 \ ef, dt: Float64,
                 plays: List[String], sustained: List[String], state: State): (List[String], State) \ ef =
        let (allowed, admitted) = admit(mixer, lengthOf, plays, advance(mixer, dt, state));
        (allowed, holdSustained(mixer, sustained, admitted))

    /// 時計を dt 秒進め、ダッキングの倍率を目標へ近づけ、鳴り終わった一発の音を voices から外す。
    pub def advance(mixer: Mixer, dt: Float64, state: State): State =
        let now = state#now + Float64.max(0.0, dt);
        let ducks = List.zip(List.range(0, List.length(mixer#ducks)), mixer#ducks)
            |> List.foldLeft((acc, p) -> {
                let (i, d) = p;
                let current = Map.get(i, state#ducks) |> Option.getWithDefault(1.0);
                Map.insert(i, stepDuck(d, isBusy(d, now, state), dt, current), acc)
            }, Map.empty());
        { now = now, ducks = ducks,
          voices = Map.filter(endsAt -> endsAt > now, state#voices) | state }

    /// このフレームに鳴らしたい一発の音を間引きに通す。返すのは「実際に鳴らす名前」と、
    /// 鳴り始めを刻んだ状態。lengthOf は音の長さ（秒）—— ダッキングが「鳴っている間」を知るのに使う。
    pub def admit(mixer: Mixer, lengthOf: String -> Float64 \ ef, names: List[String], state: State):
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

    /// 鳴り続けている音（withSustained の宣言）も、そのバスを「鳴っている」に数える
    /// （by に入ったバスの続く音 —— 声のループや足音 —— でも BGM が下がる）。
    pub def holdSustained(mixer: Mixer, names: List[String], state: State): State =
        names |> List.foldLeft((s, name) -> markBusy(busOf(mixer, name), s#now, s), state)

    def markBusy(bus: String, until: Float64, state: State): State =
        let was = Map.get(bus, state#busyUntil) |> Option.getWithDefault(-1.0);
        { busyUntil = Map.insert(bus, Float64.max(was, until), state#busyUntil) | state }

    def isBusy(d: Duck, now: Float64, state: State): Bool =
        d#by |> List.exists(bus -> match Map.get(bus, state#busyUntil) {
            case Some(until) => now < until + d#holdSeconds
            case None        => false
        })

    /// 倍率を目標（鳴っている間は depth・それ以外は 1）へ一定の速さで寄せる。
    /// 速さは「下げ幅を attack / release 秒で渡り切る」速さ（0 秒なら一気に）。
    def stepDuck(d: Duck, busy: Bool, dt: Float64, current: Float64): Float64 =
        let depth = clamp01(d#depth);
        let span = 1.0 - depth;
        let (target, seconds) = if (busy) (depth, d#attackSeconds) else (1.0, d#releaseSeconds);
        if (seconds <= 0.0 or span <= 0.0) target
        else {
            let stepSize = span * dt / seconds;
            if (current > target) Float64.max(target, current - stepSize)
            else Float64.min(target, current + stepSize)
        }

    def clamp01(x: Float64): Float64 = Float64.max(0.0, Float64.min(1.0, x))
}
