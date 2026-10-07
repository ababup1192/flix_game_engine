// Fx — たくさんの粒を、どこにも保存せず「今の時刻から計算」して並べる薄い仕組み。
// spawn も update も free も無く、同じ入力からは常に同じ絵が出る（巻き戻し・リプレイでも揺れない）。
// 注意: 各粒は番号と時刻 t だけから決まる純粋な写像。derive の piece の返り値は多相ゆえ、描画コマンドでも中間データでも好きな型を積める。

pub mod Fx {

    /// `count` 個の粒を作り、各粒 `i` に個性の蛇口 `rand`（`rand(k)` = 番号 i・チャンネル k の
    /// [0,1) 乱数）と時刻 `t` を渡して `piece` で写す。番号 `i` も併せて渡すので、丸め込みの
    /// 割り当てのような「乱数ではなく順番そのもの」が要る政策にも使える。
    pub def derive(count: Int32, t: Float64, piece: (Int32, Int32 -> Float64, Float64) -> a): List[a] =
        deriveSeeded({seed = 0, count = count}, t, piece)

    /// seed を変えると、同じ番号の粒でも別の個性を引く `derive`。着弾や爆発のような
    /// 「撃つたびに出る」群れが毎回そっくり同じ姿になるのを避けたいとき、発生ごとの
    /// 通し番号を seed に渡す。同じ seed なら同じ絵（巻き戻し・リプレイでも揺れない）。
    /// 注意: `deriveSeeded({seed = 0, ...}, ...)` は `derive` と同じ列。粒数が 8191 個
    /// までなら異なる seed 同士で個性が重ならない。
    pub def deriveSeeded(spec: {seed = Int32, count = Int32}, t: Float64,
                          piece: (Int32, Int32 -> Float64, Float64) -> a): List[a] =
        List.map(i -> piece(i, k -> Hash01.at(spec#seed * 8191 + i, k), t), List.range(0, spec#count))

    // ========================================================================
    // fx.json（FxDoc.Spec）の閉形式サンプリング
    // ========================================================================

    /// fx.json の Spec を、時刻 t 秒の絵（描き物の列）にする。粒はどこにも保存されず、
    /// 同じ (spec, seed, t) からは常に同じ絵が出る（巻き戻し・リプレイでも揺れない）。
    /// 発生点は原点 (0, 0) — 置きたい場所は呼び側が各 at に足す。
    /// seed は「撃つたびに変える通し番号」— 同じ爆発が毎回そっくり同じ姿になるのを避ける。
    /// t < 0 と t > duration は空リスト（消えた効果は呼ぶだけ無駄だが、呼んでも安全）。
    pub def sample(spec: FxDoc.Spec, seed: Int64, t: Float64): List[Render.PlacedItem] =
        if (t < 0.0 or t > spec#duration) Nil
        else spec#emitters |> List.flatMap(emitter -> sampleEmitter(emitter, seed, t))

    /// sample の絵（原点 (0, 0) 生まれ）を at へ平行移動して置く。
    /// 「爆発をこの座標で」の定型を呼び側に書かせない（drawAll の内部でも使う）。
    pub def sampleAt(spec: FxDoc.Spec, seed: Int64, t: Float64, at: Vec2.Vec2): List[Render.PlacedItem] =
        sample(spec, seed, t) |> Render.movedAll(at)

    // ========================================================================
    // burst 管理（「撃つたびに出る」効果の器）
    // ========================================================================

    /// 進行中の効果 1 つ。「どの spec を・どの種で・どこで」に加え、誕生時刻＋寿命を Lifetime で持つ。
    /// 粒の状態は持たない — 絵は drawAll が (spec, seed, 経過秒) から毎回計算する。
    /// spec は名前や参照でなく値で持つ: 複数の fx.json が混ざっても寿命の source of truth が burst 自身に宿り、
    /// どの spec の効果かを引く対応表が要らない。時刻管理は Lifetime に委ねる（得点ポップ等と同じ一族）。
    pub type alias Burst = { spec = FxDoc.Spec, seed = Int64, at = Vec2.Vec2, life = Lifetime.Lifetime }

    /// 時刻 bornAt に at で始まる効果を作る(普段は「今」を渡す。描き出しのように過去生まれを
    /// 作るときはその時刻を渡す)。seed は「撃つたびに変える通し番号」— 同じ爆発が
    /// 毎回そっくり同じ姿になるのを避ける。ゲームの連番は Int32 が普通なので口は Int32 にし、
    /// sample が食べる Int64 への変換はここが済ませる。寿命は spec の duration。
    pub def burst(spec: FxDoc.Spec, seed: Int32, at: Vec2.Vec2, bornAt: Float64): Burst =
        { spec = spec, seed = Int32.toInt64(seed), at = at,
          life = Lifetime.fire(bornAt, spec#duration) }

    /// 寿命内（経過が寿命まで）の burst だけ残す。毎フレーム呼んで、終わった効果でリストが
    /// 伸び続けるのを防ぐ。境界の「経過 = 寿命」は sample がまだ絵を出す側なので、器も残す（≤）。
    pub def expire(now: Float64, bursts: List[Burst]): List[Burst] =
        List.filter(b -> Lifetime.elapsedOf(now, b#life) <= b#life#dur, bursts)

    /// 進行中の burst 全部の、時刻 now の絵。各 burst の生まれた時刻からの経過で sampleAt を
    /// 呼ぶだけ — 寿命切れは sample が空を返すので、expire より先に呼んでも安全。
    pub def drawAll(now: Float64, bursts: List[Burst]): List[Render.PlacedItem] =
        List.flatMap(b -> sampleAt(b#spec, b#seed, Lifetime.elapsedOf(now, b#life), b#at), bursts)

    // ── sample の内部（emitter・粒の導出）──

    def sampleEmitter(emitter: FxDoc.Emitter, seed: Int64, t: Float64): List[Render.PlacedItem] =
        // emitter 名（と emitter#seed の上乗せ）を種に混ぜて、同じ seed でも emitter ごとに
        // 別の乱数系統を引く。seed = 0 の混ぜ込みは加算なので既存の絵を 1 ビットも変えない。
        let emitterSeed = mix64(Int64.bitwiseXor(seed, nameHash(emitter#name))
            + Int32.toInt64(emitter#seed));
        List.range(0, emitter#count) |> List.flatMap(i -> sampleParticle(emitter, emitterSeed, i, t))

    /// 粒 i の時刻 t の姿。寿命が尽きた粒は空リスト。burst は全粒 t=0 生まれ、loop は
    /// 各粒が寿命ごとに生まれ直す（位相 = 粒ごとの乱数で分散・生まれ直すたびに速度と方向を
    /// 引き直す — すべて t の純関数のまま）。
    /// circle / box / streak は 1 粒 = 1 枚、glow だけは縁の減衰を同心円の重ねで作るため 1 粒 = 複数枚。
    def sampleParticle(emitter: FxDoc.Emitter, emitterSeed: Int64, i: Int32,
                       t: Float64): List[Render.PlacedItem] =
        let rand = k -> rand01(emitterSeed, i, k);
        let life = varied(emitter#life#base, emitter#life#vary, rand(0));
        if (life <= 0.0) Nil
        else {
            // burst: 経過 = t そのもの・寿命切れは消える。loop: 位相をずらした t を寿命で
            // 折り返し（経過 = mod(t + 位相, 寿命)）、周回番号 cycle を乱数の種に混ぜて
            // 生まれ直すたびに別の個性を引く。burst は cycle = 0 なので randC = rand
            //（既存の burst 文書の絵はビット単位で不変）。
            let (age, cycle) = match emitter#mode {
                case FxDoc.Mode.Burst => (t, 0i64)
                case FxDoc.Mode.Loop  =>
                    let local = t + rand(3) * life;
                    let c = Float64.floor(local / life);
                    (local - c * life, Float64.tryToInt64(c) |> Option.getWithDefault(0i64))
            };
            if (age >= life or age < 0.0) Nil
            else sampleParticleAt(emitter, emitterSeed, i, life, age, cycle)
        }

    /// 生まれてから age 秒経った粒 i（周回 cycle）の姿。個性（速度・方向・発生位置）は
    /// (emitterSeed, cycle, i) から引く — 同じ入力からは常に同じ絵。
    def sampleParticleAt(emitter: FxDoc.Emitter, emitterSeed: Int64, i: Int32,
                         life: Float64, age: Float64, cycle: Int64): List[Render.PlacedItem] =
        // 周回ごとに別の乱数系統（cycle = 0 は emitterSeed そのもの = burst と同一）。
        let cycleSeed = emitterSeed + cycle * -7046029254386353131i64;
        let rand = k -> rand01(cycleSeed, i, k);
        {
            let u = age / life;
            // 位置 = 初速 × 速度カーブの積分（閉形式）+ 発生源のずれ + 重力/風（½at²）。
            // dir は度（0 = 真上・時計回り）。spawn/accel が既定（0）なら加算は恒等 —
            // 既存文書の絵はビット単位で不変。
            let speed = varied(emitter#speed#base, emitter#speed#vary, rand(1));
            // even は粒番号 i で扇を等分する（乱数と同じ ±spread/2 の幅に i/count を割り当てる）。
            let fan = match emitter#dir#mode {
                case FxDoc.DirMode.Random => rand(2) - 0.5
                case FxDoc.DirMode.Even   =>
                    Int32.toFloat64(i) / Int32.toFloat64(Int32.max(1, emitter#count)) - 0.5
            };
            let turn = (emitter#dir#base + emitter#dir#spread * fan) / 360.0;
            let dist = speed * life * curveIntegral(emitter#speed#over, u);
            let spawnOff = { x = (rand(4) - 0.5) * emitter#spawnArea#w,
                             y = (rand(5) - 0.5) * emitter#spawnArea#h };
            let accelOff = Vec2.mul(emitter#accel, 0.5 * age * age);
            let straight = Vec2.add(Vec2.add(Vec2.mul(Vec2.onEllipse({ x = 1.0, y = 1.0 }, turn), dist),
                spawnOff), accelOff);
            // wobble 既定（amp 0）は足し算ごと飛ばす — 既存文書の絵はビット単位で不変。
            let pos = if (emitter#wobble#amp#x == 0.0 and emitter#wobble#amp#y == 0.0) straight
                      else Vec2.add(straight, wobbleOffset(emitter#wobble, rand, age));
            let size = emitter#size * curveValue(emitter#sizeOver, i, u);
            let alpha = Num.clamp01(curveValue(emitter#alphaOver, i, u));
            if (size <= 0.0 or alpha <= 0.0) Nil
            else {
                let color = gradient(emitter#color, u);
                let decorate = placed -> {
                    let faded = placed#item |> Render.fade(alpha);
                    { item = Render.blended(emitter#blend, faded) | placed }
                };
                // 傾き = 初期の向き + 回る速さ × 経過（閉形式のまま）。
                let spun = emitter#turn#base + emitter#turn#spread * (rand(6) - 0.5)
                    + (emitter#turn#spin + emitter#turn#spinSpread * (rand(7) - 0.5)) * age;
                match emitter#shape {
                    case FxDoc.Shape.Circle =>
                        // 円とにじみは回しても同じ絵なので傾けない（粒ごとの回転を描画部へ
                        // 送るだけ無駄になる）。
                        decorate(RawDraw.circleAt(pos, size / 2.0, color, emitter#zIndex)) :: Nil
                    case FxDoc.Shape.Box    =>
                        decorate(RawDraw.boxAt(pos, { x = size, y = size }, color, emitter#zIndex)
                            |> (p -> if (Float64.abs(spun) < 1.0e-12) p
                                     else { item = Render.turned(spun, p#item) | p })) :: Nil
                    case FxDoc.Shape.Streak =>
                        // 尾の向きは速度から導く（turn は効かせない — 筋の向きと粒の傾きが
                        // 別々に回ると、雨・火花が「流れ」に見えなくなる）。wobble の揺れも
                        // 向きには混ぜない — 微分を持ち込むほどの絵の差が出ない。
                        let vel = Vec2.add(
                            Vec2.mul(Vec2.onEllipse({ x = 1.0, y = 1.0 }, turn),
                                     speed * curveValue(emitter#speed#over, i, u)),
                            Vec2.mul(emitter#accel, age));
                        let velLen = Vec2.length(vel);
                        // 止まった粒は射出方向を向く（尾は 0 = ただの size 角の箱）。
                        let velTurn = if (velLen < 1.0e-9) turn
                                      else Vec2.atan2(vel#y, vel#x) / Vec2.tau() + 0.25;
                        decorate(RawDraw.boxAt(pos, { x = size, y = size + velLen * emitter#stretch },
                                              color, emitter#zIndex)
                            |> (p -> if (Float64.abs(velTurn) < 1.0e-12) p
                                     else { item = Render.turned(velTurn, p#item) | p })) :: Nil
                    case FxDoc.Shape.Glow   =>
                        // 濃さとブレンドは glowAt が輪ごとに配るので decorate は通さない
                        //（後から fade を掛けると輪ごとの配分が上書きされて減衰が消える）。
                        Render.glowAt(pos, size / 2.0, color,
                                      { alpha = alpha, blend = emitter#blend }, emitter#zIndex)
                }
            }
        }

    // ── カーブ評価 ──

    /// カーブの u での値（倍率）。salt は flicker が粒ごとに別のチラつき方をするための番号。
    def curveValue(curve: FxDoc.CurveSpec, salt: Int32, u: Float64): Float64 =
        match curve {
            case FxDoc.CurveSpec.Constant   => 1.0
            case FxDoc.CurveSpec.Linear(l)  => l#fromV + (l#toV - l#fromV) * u
            case FxDoc.CurveSpec.EaseIn(e)  => Float64.pow(base = u, e#power)
            case FxDoc.CurveSpec.EaseOut(e) => Float64.pow(base = 1.0 - u, e#power)
            case FxDoc.CurveSpec.Peak(p)    =>
                if (p#at <= 0.0) 1.0 - u
                else if (p#at >= 1.0) u
                else if (u <= p#at) u / p#at
                else (1.0 - u) / (1.0 - p#at)
            case FxDoc.CurveSpec.Flicker(f) =>
                1.0 - f#amount * Hash01.at(salt, stepOf(u * f#rate))
            case FxDoc.CurveSpec.Pulse(p)   =>
                // u=0 で 1（生まれた瞬間に暗い粒を出さない）→ minV まで沈んで戻る cos 波。
                p#minV + (1.0 - p#minV) * (0.5 + 0.5 * Vec2.cos(Vec2.tau() * p#rate * u))
        }

    /// カーブの 0..u の積分（速度 → 移動距離）。flicker はパース（FxDoc）が速度カーブとして
    /// 弾くので、ここへ届くのは手組みの Spec だけ — 黙って別の動きにせず loud に落とす。
    def curveIntegral(curve: FxDoc.CurveSpec, u: Float64): Float64 =
        match curve {
            case FxDoc.CurveSpec.Constant   => u
            case FxDoc.CurveSpec.Linear(l)  => l#fromV * u + (l#toV - l#fromV) * u * u / 2.0
            case FxDoc.CurveSpec.EaseIn(e)  => Float64.pow(base = u, e#power + 1.0) / (e#power + 1.0)
            case FxDoc.CurveSpec.EaseOut(e) => (1.0 - Float64.pow(base = 1.0 - u, e#power + 1.0)) / (e#power + 1.0)
            case FxDoc.CurveSpec.Peak(p)    =>
                if (p#at <= 0.0) u - u * u / 2.0
                else if (p#at >= 1.0) u * u / 2.0
                else if (u <= p#at) u * u / (2.0 * p#at)
                else p#at / 2.0 + (1.0 - p#at) / 2.0 - (1.0 - u) * (1.0 - u) / (2.0 * (1.0 - p#at))
            case FxDoc.CurveSpec.Flicker(_) =>
                bug!("Fx.curveIntegral: flicker は速度カーブに使えない（FxDoc.parse が弾く）")
            case FxDoc.CurveSpec.Pulse(_)   =>
                bug!("Fx.curveIntegral: pulse は速度カーブに使えない（FxDoc.parse が弾く）")
        }

    /// u * rate の整数段（flicker のチラつきの区切り番号）。
    def stepOf(x: Float64): Int32 =
        Num.floorInt(x)

    /// 位置の正弦揺らぎ（閉形式）。位相は乱数 × vary — vary 0 で全粒がそろって揺れ、
    /// 1 で 1 周ぶん散る。x と y は別の位相を引くので、両軸に振るとリサージュ型の
    /// 有界運動（蛍・湯気の「その場でゆらゆら」）になる。
    def wobbleOffset(wobble: FxDoc.Wobble, rand: Int32 -> Float64, age: Float64): Vec2.Vec2 =
        { x = wobble#amp#x * Vec2.sin(Vec2.tau() * (wobble#freq#x * age + wobble#vary * rand(8))),
          y = wobble#amp#y * Vec2.sin(Vec2.tau() * (wobble#freq#y * age + wobble#vary * rand(9))) }

    // ── 粒ごとの導出 ──

    /// base × (1 ± vary)。r は [0,1) の乱数 — r=0.5 でちょうど base。
    def varied(base: Float64, vary: Float64, r: Float64): Float64 =
        base * (1.0 + vary * (2.0 * r - 1.0))

    /// 1〜N 色の並びを u（0..1）で線形に混ぜた色。1 色ならその色のまま。
    def gradient(colors: List[Color], u: Float64): Color =
        match colors {
            case Nil         => { r = 1.0, g = 1.0, b = 1.0 }
            case c :: Nil    => c
            case _ :: _ :: _ =>
                let n = List.length(colors);
                let pos = Num.clamp01(u) * Int32.toFloat64(n - 1);
                let idx = stepOf(pos) |> Int32.min(n - 2);
                let frac = pos - Int32.toFloat64(idx);
                let a = List.nth(idx, colors) |> Option.getWithDefault({ r = 1.0, g = 1.0, b = 1.0 });
                let b = List.nth(idx + 1, colors) |> Option.getWithDefault(a);
                { r = mixCh(a#r, b#r, frac), g = mixCh(a#g, b#g, frac), b = mixCh(a#b, b#b, frac) }
        }

    def mixCh(a: Float64, b: Float64, frac: Float64): Float64 =
        let av = Float32.toFloat64(RenderUtil.f32(a));
        let bv = Float32.toFloat64(RenderUtil.f32(b));
        Float32.toFloat64(RenderUtil.f32(av + (bv - av) * frac))

    // ── 決定論の乱数（splitmix64 系のハッシュ）──
    // flix-random は engine_world の依存に無いので、仕上げ混合だけ同じ式を private に持つ。
    // 列を進める PRNG ではなく (種, 粒番号, チャンネル) → [0,1) の純粋な写像として使う。

    /// splitmix64 の仕上げ混合。定数は 0xBF58476D1CE4E5B9 / 0x94D049BB133111EB を signed で表したもの。
    def mix64(z0: Int64): Int64 =
        let z1 = Int64.bitwiseXor(z0, Int64.logicalRightShift(dist = 30, z0)) * -4658895280553007687i64;
        let z2 = Int64.bitwiseXor(z1, Int64.logicalRightShift(dist = 27, z1)) * -7723592293110705685i64;
        Int64.bitwiseXor(z2, Int64.logicalRightShift(dist = 31, z2))

    /// (emitter の種, 粒番号 i, チャンネル k) → [0,1)。gamma 0x9E3779B97F4A7C15 と奇数定数で
    /// i と k を別々の歩幅にして混ぜ、上位 53bit を [0,1) の実数に写す。
    def rand01(emitterSeed: Int64, i: Int32, k: Int32): Float64 =
        let z = mix64(emitterSeed
            + Int32.toInt64(i) * -7046029254386353131i64
            + Int32.toInt64(k) * -4658895280553007687i64);
        Int64.toFloat64(Int64.logicalRightShift(dist = 11, z)) / 9007199254740992.0

    /// emitter 名 → Int64（31 進の文字畳み込み）。名前が違えば別の乱数系統になる。
    def nameHash(name: String): Int64 =
        String.toList(name) |> List.foldLeft((h, c) ->
            h * 31i64 + Int32.toInt64(Char.toBmpCodePoint(c)), 1125899906842597i64)
}
