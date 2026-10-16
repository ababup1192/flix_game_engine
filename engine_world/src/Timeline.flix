// Timeline — 演出の時刻表。動き・効果音・待ちを 1 本に書き、描く側と鳴らす側が同じ時刻を読む。
// 履歴・巻き戻し・リプレイは Worldline（別物）。進行の状態は持たない: 場面に入ってからの秒を渡せば
// 「どのクリップの何割か」「このフレームに鳴らす音」が式で決まる（render-from-World の View のまま）。
//
// 使う場面: 演出の拍（何が何秒・何拍目に起き、何が鳴るか）を 1 本の表に書く（build + withSound）。
// 使わない: 経過秒を if で比べて拍を決める（絵と音で別々に書くと拍がずれる）。履歴・巻き戻しは Worldline。
// 長さの目安（窓の出入り・待ち・溜め・音と絵のずれ）は docs/pacing.md。曲に乗る演出は拍へ読み替えて書く。
//
// 書き方（GSAP の timeline・DOTween の Sequence と同じ並べ方）:
//
//   let intro = Timeline.build(Timeline.tempo(175.0, 4), List#{
//       Timeline.append(Intro.Flash, Duration.Seconds(0.32)) |> Timeline.withSound("whoosh"),
//       Timeline.append(Intro.Wipe, Duration.Seconds(0.3)),
//       Timeline.append(Intro.Hold, Duration.ToNextBar)      |> Timeline.withSound("slam"),
//       Timeline.append(Intro.Turn1, Duration.Beats(1.0))
//   });
//   Timeline.progressOf(Intro.Hold, head, tl)                  // 描く側: 0..1
//   Timeline.soundsOn(Playback.Play, before, after, tl)        // 鳴らす側: このフレームの音
//   Timeline.soundsBetween(prevAge, age, tl)                  // 待ちの無い表なら秒 2 つで同じ物
//
//   - 長さは Seconds / Beats / Bars と、曲に合わせて伸び縮みする ToNextBar（次の小節の頭まで）・
//     ToBeat(n)（頭から n 拍目まで）・ToPickup(n)（次の小節の頭の n 拍前 = 弱起まで。余裕が n 拍未満なら
//     その次の小節）で書く。拍と小節は Tempo（譜面の bpm）から秒になる。
//     中では「拍の分 + 秒の分」の組で足し、秒へ直すのは最後の 1 回（拍を秒にしてから足す誤差を作らない）。
//   - 置き場所: append = 表の終わり（既定）・join = 直前の行の頭（GSAP の "<"）・atStartOf / atEndOf =
//     名前のクリップを基準・insert = 表の頭から決まった時刻（DOTween の Insert）・withDelay = そこから遅らせる
//     （負なら手前へ）。前を延ばすと後ろが付いてくる（insert で置いた物は動かない）。
//   - 効果音はクリップの属性（Unity の Timeline の Audio トラック・Godot の音のトラック・Bevy の
//     AnimationEvent）。描く側（stateOf）と鳴らす側（soundsOn）が同じ start を読むので、鳴らす時刻を
//     別の場所に書けない。音が鳴るフレームで stateOf はもう Active か After を返す。
//   - waitFor は長さの決まらない待ち（会話を読む・決定キー）。World は解けた時刻を resume で記録するだけ。
//     待ちの位置ちょうどでは、待ちの前に書いた物だけが済む（Playhead = 時刻と解いた待ちの数）。
//   - 書き間違い（同じ名前・まだ置いていない名前を基準・待ちに音・待ちより前へ置く・長さを合わせる音の
//     食い違い）は build が Err で返す。並びをコードが書く表は buildOrBug（組めなければ止める）で受け、
//     場面ごとにテストを 1 本置けば遊ぶ前に止まる。同じ物を何本も並べる所は tag に番号を持たせる（Tick(i)）。
//
// 時計の決まり: 渡す時刻は、場面に入ってから「dt × はやさ × TimeScale」を積み上げた場面の時計 1 本。
// resume にも同じ時計の値を渡す。時刻表は World にしまわず Doc から毎回組む（数十行なら µs。
// しまうと組み直し忘れで View と Sfx が別の表を読む）。曲に乗せる場面は、はやさを掛けない時計を渡す。
//
// 毎フレームの探索: stateOf = O(log タグ数)・soundsOn = 二分探索で O(log 音の数 + 鳴る数)・
// playheadOf = O(待ちの数)。
//
// 読む口が返すクリップ（Clip: tag・start・dur）は clipOf / clipsOf で引く。1 つのクリップの中の進みは progressOf。

pub mod Timeline {

    /// 組み上がった時刻表。sounds は (時刻, 書いた順) の昇順。
    pub enum Timeline[a] {
        case Timeline({ clips = Map[a, Clip[a]], segments = Map[a, Int32], sounds = Vector[SoundAt], waits = List[Float64],
                        fitted = Map[String, Float64], duration = Float64 })
    }

    // ── クリップ ──

    /// クリップ: start 秒に始まり dur 秒続く。tag = 拍の名前か出来事（ゲームの enum。文字列にしないのは、
    /// match の網羅の検査で書き損じに気づけるようにするため）。組んだ表から clipOf / clipsOf で引く。
    pub type alias Clip[a] = { tag = a, start = Float64, dur = Float64 }

    /// クリップを値として作る（表に無い名前の既定値など。長さは負にしない）。
    pub def clip(tag: a, start: Float64, dur: Float64): Clip[a] =
        { tag = tag, start = start, dur = Float64.max(0.0, dur) }

    // ── 時刻表を書く口 ──

    /// 曲の速さ。拍と小節を秒へ直すのはここだけ（譜面の bpm をそのまま渡す）。
    /// hasBeat = false は noTempo（拍を書かない表）。拍で書いた行があれば build が Err にする。
    pub type alias Tempo = { bpm = Float64, beatsPerBar = Int32, hasBeat = Bool }

    /// テンポ。bpm は 1 未満にしない（0 で割らない）・1 小節の拍数は 1 未満にしない。
    /// 譜面を持つゲームは、譜面の bpm と拍子からここへ渡す（テンポを Doc に 2 か所書かない）。
    pub def tempo(bpm: Float64, beatsPerBar: Int32): Tempo =
        { bpm = Float64.max(1.0, bpm), beatsPerBar = Int32.max(1, beatsPerBar), hasBeat = true }

    /// 拍を書かない表（秒だけで並べる表）に渡すテンポ。拍・小節で書いた行（Beats・Bars・ToNextBar・
    /// ToBeat・ToPickup）があれば build が BeatsWithoutTempo で止める（黙って 1 拍 = 1 秒にしない）。
    pub def noTempo(): Tempo = { hasBeat = false | tempo(60.0, 4) }

    /// 長さの書き方。
    pub enum Duration with Eq {
        case Seconds(Float64)
        case Beats(Float64)
        case Bars(Float64)
        /// クリップの頭から、次の小節の頭まで（頭がちょうど小節の頭なら 0）
        case ToNextBar
        /// クリップの頭から、表の頭から数えて n 拍目まで（もう過ぎていれば 0）
        case ToBeat(Float64)
        /// クリップの頭から、次の小節の頭の n 拍前（弱起 = pickup）まで。小節の頭まで n 拍以上の余裕が
        /// 無ければ、その次の小節の n 拍前へ送る（ターン 1 を「本編の頭の 1 拍前」に置くような所）
        case ToPickup(Float64)
    }

    /// クリップを置く基準。
    pub enum Place[a] {
        /// 表の終わり（それまでのクリップで一番遅い終わり）
        case End
        /// 直前に書いた行の頭
        case WithPrevious
        case AtStartOf(a)
        case AtEndOf(a)
        /// 表の頭から決まった時刻（秒か拍）。前に何を置いたかに左右されない
        case At(Duration)
    }

    /// クリップの中で鳴らす効果音。fitted = 書き出す WAV の長さをこのクリップの長さに合わせる音。
    pub type alias Cue = { sound = String, offset = Duration, fitted = Bool }

    /// 書く人が並べる 1 行。place から delay だけ遅らせて置き、length だけ続く。
    pub type alias Step[a] = { tag = a, place = Place[a], delay = Duration, length = Duration,
                               cues = List[Cue], isWait = Bool }

    /// 書き間違い。tag はコードの enum なので、黙って既定の位置へ置かずに止める。
    pub enum BuildError[a] with Eq, ToString {
        /// 同じ名前の行が 2 つある（後の行が前の絵を消し、音だけ 2 つ残る形になる）
        case DuplicateTag(a)
        /// まだ置いていない名前を基準にした
        case UnknownAnchor(a)
        /// 待ちに音を付けた（待ちが解けた後に鳴ってしまう）
        case SoundOnWait(a)
        /// 長さを合わせる音が、長さの違う 2 つのクリップに付いている（WAV は 1 本）
        case FittedLengthConflict(String)
        /// 待ちの後に書いた行を、待ちより前の時刻へ置いた（待ちを解く前に始まってしまう）
        case PlacedBeforeWait(a)
        /// noTempo の表に拍・小節で書いた行がある（曲のテンポを Timeline.tempo で渡す）
        case BeatsWithoutTempo(a)
    }

    /// 拍・小節で書いた長さか（秒だけの表に混ざると、テンポが無いので秒へ直せない）。
    def isBeatDuration(d: Duration): Bool = match d {
        case Duration.Seconds(_) => false
        case _                   => true
    }

    /// 行のどこか（置き場所・遅らせ・長さ・音の遅れ）に拍で書いた所があるか。
    def usesBeats(s: Step[a]): Bool =
        let placedAt = match s#place {
            case Place.At(d) => isBeatDuration(d)
            case _           => false
        };
        placedAt or isBeatDuration(s#delay) or isBeatDuration(s#length) or
            List.exists(cue -> isBeatDuration(cue#offset), s#cues)

    def step(tag: a, place: Place[a], length: Duration): Step[a] =
        { tag = tag, place = place, delay = Duration.Seconds(0.0), length = length, cues = Nil, isWait = false }

    /// 表の終わりに並べる。
    pub def append(tag: a, length: Duration): Step[a] = step(tag, Place.End, length)

    /// 直前に書いた行と同時に始める。
    pub def join(tag: a, length: Duration): Step[a] = step(tag, Place.WithPrevious, length)

    /// anchor のクリップの頭に置く。
    pub def atStartOf(anchor: a, tag: a, length: Duration): Step[a] = step(tag, Place.AtStartOf(anchor), length)

    /// anchor のクリップの終わりに置く。
    pub def atEndOf(anchor: a, tag: a, length: Duration): Step[a] = step(tag, Place.AtEndOf(anchor), length)

    /// 表の頭から at の時刻に置く（DOTween の Insert・GSAP の時刻を書いた置き方）。重ねて置くクリップに使う。
    pub def insert(at: Duration, tag: a, length: Duration): Step[a] = step(tag, Place.At(at), length)

    /// 表の終わりで待つ。後ろの行はここから数える。
    pub def waitFor(tag: a): Step[a] = { isWait = true | step(tag, Place.End, Duration.Seconds(0.0)) }

    /// 置き場所から遅らせる（GSAP の "+=0.5"）。
    pub def withDelay(delay: Duration, s: Step[a]): Step[a] = { delay = delay | s }

    /// クリップの頭で鳴らす。
    pub def withSound(name: String, s: Step[a]): Step[a] = withSoundAt(name, Duration.Seconds(0.0), s)

    /// クリップの頭から offset 遅れて鳴らす。
    pub def withSoundAt(name: String, offset: Duration, s: Step[a]): Step[a] =
        { cues = List.append(s#cues, { sound = name, offset = offset, fitted = false } :: Nil) | s }

    /// クリップの頭で鳴らし、書き出す WAV の長さをクリップの長さに合わせる（soundLengthOf で引く）。
    pub def withFittedSound(name: String, s: Step[a]): Step[a] =
        { cues = List.append(s#cues, { sound = name, offset = Duration.Seconds(0.0), fitted = true } :: Nil) | s }

    // ── 組み立て ──

    /// 時刻表の上の位置。拍の分と秒の分を別々に足し、秒へ直すのは最後の 1 回だけ
    /// （拍を秒にしてから足すと 14 拍が 4.800000000000001 秒のようにずれる）。
    /// 秒だけの表は秒を書いた順に足すので、Doc の秒を手で足し並べた時刻とビットまで一致する。
    pub type alias Pos = { beats = Float64, seconds = Float64 }

    def zero(): Pos = { beats = 0.0, seconds = 0.0 }

    def plus(x: Pos, y: Pos): Pos = { beats = x#beats + y#beats, seconds = x#seconds + y#seconds }

    def beatSeconds(tempo: Tempo): Float64 = 60.0 / tempo#bpm

    def toSeconds(tempo: Tempo, p: Pos): Float64 = p#beats * beatSeconds(tempo) + p#seconds

    /// origin から長さ d だけ進んだ位置。
    def advanceBy(tempo: Tempo, origin: Pos, d: Duration): Pos = match d {
        case Duration.Seconds(s) => plus(origin, { beats = 0.0, seconds = s })
        case Duration.Beats(b)   => plus(origin, { beats = b, seconds = 0.0 })
        case Duration.Bars(n)    => plus(origin, { beats = n * Int32.toFloat64(tempo#beatsPerBar), seconds = 0.0 })
        case Duration.ToBeat(b)  => latest(tempo, origin, { beats = b, seconds = 0.0 })
        case Duration.ToNextBar  =>
            let perBar = Int32.toFloat64(tempo#beatsPerBar);
            let barsSoFar = toSeconds(tempo, origin) / (perBar * beatSeconds(tempo));
            // 小節の頭ちょうどを、丸めの誤差で次の小節へ送らない
            let bars = Float64.ceil(barsSoFar - 1.0e-9);
            latest(tempo, origin, { beats = bars * perBar, seconds = 0.0 })
        case Duration.ToPickup(n) =>
            // n 拍先から次の小節の頭を探し、そこから n 拍戻す（余裕が n 拍未満の小節は飛ばす）。
            let barHead = advanceBy(tempo, plus(origin, { beats = n, seconds = 0.0 }), Duration.ToNextBar);
            plus(barHead, { beats = 0.0 - n, seconds = 0.0 })
    }

    def latest(tempo: Tempo, x: Pos, y: Pos): Pos = if (toSeconds(tempo, y) > toSeconds(tempo, x)) y else x

    /// 長さを秒へ直す（表の頭から測る ToNextBar / ToBeat は頭から数えた長さ）。
    /// noTempo に拍・小節の長さを渡すと 1 拍 = 1 秒で数える（拍を秒へ直すときは Timeline.tempo を渡す）。
    pub def secondsOf(tempo: Tempo, d: Duration): Float64 = toSeconds(tempo, advanceBy(tempo, zero(), d))

    /// 並べた行を秒の時刻表にする。前の行にしか頼らないので 1 回の走査で決まる。
    /// 書き間違いは全部集めて Err で返す（場面ごとのテスト 1 本で止める）。
    pub def build(tempo: Tempo, steps: List[Step[a]]): Result[List[BuildError[a]], Timeline[a]] with Order[a] =
        let init = { spans = (Map.empty(): Map[a, (Pos, Pos)]), cues = (Nil: List[(Float64, Int32, Int32, String)]),
                     waits = (Nil: List[Float64]), fitted = (Map.empty(): Map[String, Float64]),
                     errors = (Nil: List[BuildError[a]]), prevStart = zero(), end = zero(), order = 0,
                     segments = (Map.empty(): Map[a, Int32]), lengths = (Map.empty(): Map[a, Pos]),
                     passed = 0, lastWait = -1.0 };
        let built = List.foldLeft((acc, s) -> {
            let anchor = match s#place {
                case Place.End          => Ok(acc#end)
                case Place.WithPrevious => Ok(acc#prevStart)
                case Place.AtStartOf(o) => Map.get(o, acc#spans) |> Option.map(fst) |> Option.toOk(BuildError.UnknownAnchor(o))
                case Place.AtEndOf(o)   => Map.get(o, acc#spans) |> Option.map(snd) |> Option.toOk(BuildError.UnknownAnchor(o))
                case Place.At(d)        => Ok(advanceBy(tempo, zero(), d))
            };
            match anchor {
                case Err(e) => { errors = e :: acc#errors | acc }
                case Ok(_) if Map.memberOf(s#tag, acc#spans) => { errors = BuildError.DuplicateTag(s#tag) :: acc#errors | acc }
                case Ok(_) if s#isWait and not List.isEmpty(s#cues) => { errors = BuildError.SoundOnWait(s#tag) :: acc#errors | acc }
                case Ok(_) if not tempo#hasBeat and usesBeats(s) => { errors = BuildError.BeatsWithoutTempo(s#tag) :: acc#errors | acc }
                case Ok(base) if not s#isWait and toSeconds(tempo, advanceBy(tempo, base, s#delay)) < acc#lastWait =>
                    { errors = BuildError.PlacedBeforeWait(s#tag) :: acc#errors | acc }
                case Ok(base) =>
                    let start = advanceBy(tempo, base, s#delay);
                    let finish = advanceBy(tempo, start, s#length);
                    let startSeconds = toSeconds(tempo, start);
                    // 長さは長さのまま秒へ直す（終わりから頭を引くと 0.3 が 0.2999999999999998 になる）
                    let length = match s#length {
                        case Duration.ToNextBar => { beats = finish#beats - start#beats, seconds = finish#seconds - start#seconds }
                        case Duration.ToBeat(_) => { beats = finish#beats - start#beats, seconds = finish#seconds - start#seconds }
                        case Duration.ToPickup(_) => { beats = finish#beats - start#beats, seconds = finish#seconds - start#seconds }
                        case other              => advanceBy(tempo, zero(), other)
                    };
                    let clipSeconds = Float64.max(0.0, toSeconds(tempo, length));
                    let segment = acc#passed;
                    let placed = s#cues |> List.zipWithIndex |> List.map(pair -> {
                        let (i, cue) = pair;
                        (toSeconds(tempo, advanceBy(tempo, start, cue#offset)), segment, acc#order + i, cue#sound)
                    });
                    let (fitted, conflicts) = s#cues |> List.filter(cue -> cue#fitted) |> List.foldLeft((fc, cue) -> {
                        let (m, errs) = fc;
                        match Map.get(cue#sound, m) {
                            case Some(known) if Float64.abs(known - clipSeconds) > 1.0e-9 =>
                                (m, BuildError.FittedLengthConflict(cue#sound) :: errs)
                            case _ => (Map.insert(cue#sound, clipSeconds, m), errs)
                        }
                    }, (acc#fitted, acc#errors));
                    { spans = Map.insert(s#tag, (start, finish), acc#spans),
                      cues = List.reverse(placed) ::: acc#cues,
                      waits = if (s#isWait) startSeconds :: acc#waits else acc#waits,
                      segments = Map.insert(s#tag, segment, acc#segments),
                      lengths = Map.insert(s#tag, length, acc#lengths),
                      passed = if (s#isWait) acc#passed + 1 else acc#passed,
                      lastWait = if (s#isWait) startSeconds else acc#lastWait,
                      fitted = fitted,
                      errors = conflicts,
                      prevStart = start,
                      end = latest(tempo, acc#end, finish),
                      order = acc#order + List.length(s#cues) }
            }
        }, init, steps);
        if (not List.isEmpty(built#errors)) Err(List.reverse(built#errors))
        else {
            let clips = built#spans |> Map.mapWithKey((tag, span) -> {
                let (start, _) = span;
                let length = Map.get(tag, built#lengths) |> Option.getWithDefault(zero());
                { tag = tag, start = toSeconds(tempo, start), dur = Float64.max(0.0, toSeconds(tempo, length)) }
            });
            let sounds = built#cues
                |> List.sortWith((x, y) -> {
                    let (ax, sx, ox, _) = x;
                    let (ay, sy, oy, _) = y;
                    let byTime = ax <=> ay;
                    let bySegment = sx <=> sy;
                    if (byTime != Comparison.EqualTo) byTime
                    else if (bySegment != Comparison.EqualTo) bySegment
                    else ox <=> oy
                })
                |> List.map(c -> { let (at, segment, _, name) = c; { at = at, segment = segment, sound = name } })
                |> List.toVector;
            let lastSound = Vector.foldLeft((m, s) -> Float64.max(m, s#at), 0.0, sounds);
            Ok(Timeline.Timeline({
                clips = clips, segments = built#segments, sounds = sounds,
                waits = built#waits |> List.sortWith((x, y) -> x <=> y),
                fitted = built#fitted,
                duration = Float64.max(toSeconds(tempo, built#end), lastSound) }))
        }

    /// build の、書き間違いで止める包み。並びをゲームのコードが書く表（Doc は長さしか持たない）では、Err は
    /// プログラムの書き間違いなので、組めなければ name と書き間違いの一覧を出して止める。場面ごとのテストで
    /// 1 回組めば、遊ぶ前に止まる。並びを Doc やプレイヤーの入力から作る表は build を使い、Err を捌く。
    pub def buildOrBug(name: String, tempo: Tempo, steps: List[Step[a]]): Timeline[a] with Order[a], ToString[a] =
        match build(tempo, steps) {
            case Ok(tl)      => tl
            case Err(errors) => bug!("Timeline ${name} の書き間違い: ${errors |> List.map(e -> ToString.toString(e)) |> String.intercalate(", ")}")
        }

    // ── 読む口（毎フレーム） ──

    /// 鳴らす予定の効果音（秒）。
    /// segment = その音より前に書いた待ちの数。
    pub type alias SoundAt = { at = Float64, segment = Int32, sound = String }

    /// 再生位置: 時刻表の上の時刻 t と、解いた待ちの数 passed。待ちの位置ちょうどでは、
    /// 待ちの前に書いた物は済み・待ちの後に書いた物はまだ（(t, passed) の組で比べる）。
    pub type alias Playhead = { t = Float64, passed = Int32 }

    /// 待ちの無い表の再生位置。
    pub def playheadAt(t: Float64): Playhead = { t = t, passed = 0 }

    /// head が (at, segment) より前か。
    def isBefore(head: Playhead, at: Float64, segment: Int32): Bool =
        head#t < at or (head#t == at and head#passed < segment)

    /// クリップの中のどこにいるか。
    pub enum ClipState with Eq, ToString {
        case Before
        case Active(Float64)
        case After
    }

    /// フレームの進め方。Enter = 場面の最初のフレーム（頭ちょうどの音も鳴らす）・Play = ふつうに進む・
    /// Seek = 飛ばす（Bevy の set_seek_time と同じく、飛ばした区間の音は鳴らさない）。
    pub enum Playback with Eq {
        case Enter
        case Play
        case Seek
    }

    /// 時刻表が終わる時刻（秒）。クリップより後ろの音も含む。
    pub def endOf(tl: Timeline[a]): Float64 = match tl {
        case Timeline.Timeline(r) => r#duration
    }

    /// タグのクリップ（秒）。
    pub def clipOf(tag: a, tl: Timeline[a]): Option[Clip[a]] with Order[a] = match tl {
        case Timeline.Timeline(r) => Map.get(tag, r#clips)
    }

    /// クリップの列（開始の順。同じ時刻は tag の順）。全部のクリップを順に見る所（索引・ログ）に。
    pub def clipsOf(tl: Timeline[a]): List[Clip[a]] = match tl {
        case Timeline.Timeline(r) => Map.valuesOf(r#clips) |> List.sortWith((x, y) -> x#start <=> y#start)
    }

    /// 時刻 t にタグのクリップのどこにいるか。境目は soundsOn と同じ (start で Active・長さ 0 なら After)。
    pub def stateOf(tag: a, head: Playhead, tl: Timeline[a]): ClipState with Order[a] = match tl {
        case Timeline.Timeline(r) =>
            let segment = Map.get(tag, r#segments) |> Option.getWithDefault(0);
            match Map.get(tag, r#clips) {
                case None    => ClipState.After
                case Some(c) =>
                    if (isBefore(head, c#start, segment)) ClipState.Before
                    else if (head#t >= c#start + c#dur) ClipState.After
                    else ClipState.Active((head#t - c#start) / c#dur)
            }
    }

    /// 進み 0..1（前は 0・後は 1）。
    pub def progressOf(tag: a, head: Playhead, tl: Timeline[a]): Float64 with Order[a] =
        match stateOf(tag, head, tl) {
            case ClipState.Before    => 0.0
            case ClipState.Active(u) => u
            case ClipState.After     => 1.0
        }

    /// 前のフレームの時刻 prev から今の now までに鳴らす効果音。区間は
    /// (prev, now]（Enter だけ [prev, now]）。音が鳴るフレームで stateOf はもう Active か After を返す。
    /// 同じ時刻の音は書いた順。巻き戻し（now < prev）では鳴らさない。
    pub def soundsOn(playback: Playback, prev: Playhead, now: Playhead, tl: Timeline[a]): List[String] = match tl {
        case Timeline.Timeline(r) =>
            let skipBelow = match playback {
                case Playback.Enter => Some(s -> isBefore({ t = s#at, passed = s#segment }, prev#t, prev#passed))
                case Playback.Play  => Some(s -> not isBefore(prev, s#at, s#segment))
                case Playback.Seek  => None
            };
            match skipBelow {
                case None    => Nil
                case Some(_) if isBefore(now, prev#t, prev#passed) => Nil
                case Some(skip) => takeUntil(r#sounds, firstNot(r#sounds, skip), now, Nil)
            }
    }

    /// 待ちの無い表で、前のフレームの秒 prev から今の now までに鳴らす効果音（soundsOn の Play と同じ (prev, now]）。
    /// 場面の頭の音も鳴らすなら最初のフレームは
    /// prev を負にするか、soundsOn の Enter を使う。
    pub def soundsBetween(prev: Float64, now: Float64, tl: Timeline[a]): List[String] =
        soundsOn(Playback.Play, playheadAt(prev), playheadAt(now), tl)

    /// 長さを合わせる音（withFittedSound）を書き出すときの長さ（秒）。
    pub def soundLengthOf(name: String, tl: Timeline[a]): Option[Float64] = match tl {
        case Timeline.Timeline(r) => Map.get(name, r#fitted)
    }

    // ── 待ち ──

    /// 場面の時計 wall と、待ちが解けた時刻の列から、時刻表の上の時刻を出す。解けていない待ちでは
    /// そこで止まる。View もこの値を受け取るだけ（時刻の純関数のまま）。O(待ちの数)。
    pub def playheadOf(wall: Float64, resumes: List[Float64], tl: Timeline[a]): Playhead = match tl {
        case Timeline.Timeline(r) =>
            let walked = walkWaits(wall, r#waits, resumes, 0.0, 0);
            { t = walked#local, passed = walked#passed }
    }

    /// いま解けていない待ちで止まっているか。
    pub def isWaiting(wall: Float64, resumes: List[Float64], tl: Timeline[a]): Bool = match tl {
        case Timeline.Timeline(r) => walkWaits(wall, r#waits, resumes, 0.0, 0)#waiting
    }

    /// 決定キーを押した。待ちで止まっている間だけ解いた時刻を記録する（待ちに着く前の早押しは数えない）。
    pub def resume(wall: Float64, resumes: List[Float64], tl: Timeline[a]): List[Float64] =
        if (isWaiting(wall, resumes, tl)) List.append(resumes, wall :: Nil) else resumes

    def walkWaits(wall: Float64, waits: List[Float64], resumes: List[Float64], waited: Float64, passed: Int32):
        { local = Float64, waiting = Bool, passed = Int32 } =
        match waits {
            case Nil       => { local = wall - waited, waiting = false, passed = passed }
            case w :: rest =>
                let reached = w + waited;
                if (wall < reached) { local = wall - waited, waiting = false, passed = passed }
                else match resumes {
                    case Nil => { local = w, waiting = true, passed = passed }
                    case resumedAt :: more =>
                        let waitedHere = Float64.max(0.0, resumedAt - reached);
                        if (wall < reached + waitedHere) { local = w, waiting = true, passed = passed }
                        else walkWaits(wall, rest, more, waited + waitedHere, passed + 1)
                }
        }

    // ── 二分探索 ──

    /// skip が真になる並びの、最初の偽の位置（sounds は時刻順なので skip は頭の側だけ真）。
    def firstNot(sounds: Vector[SoundAt], skip: SoundAt -> Bool): Int32 =
        def go(lo, hi) =
            if (lo >= hi) lo
            else {
                let mid = lo + (hi - lo) / 2;
                if (skip(Vector.get(mid, sounds))) go(mid + 1, hi) else go(lo, mid)
            };
        go(0, Vector.length(sounds))

    def takeUntil(sounds: Vector[SoundAt], i: Int32, now: Playhead, acc: List[String]): List[String] =
        if (i >= Vector.length(sounds)) List.reverse(acc)
        else {
            let s = Vector.get(i, sounds);
            if (not isBefore(now, s#at, s#segment)) takeUntil(sounds, i + 1, now, s#sound :: acc) else List.reverse(acc)
        }
}
