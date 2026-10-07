// Daylight — 1 日の進み（0.0〜1.0）から「空気の色」を決め、画面全体に薄く掛ける。
// 節（Key）を並べるだけで朝夕昼夜の色を滑らかにつなぎ、一周するので日付境界でも色が飛ばない。
// 注意: 色だけを扱う（時計は Calendar、明かりの穴あけは Light の仕事）。掛け方は乗算（Multiply）
// — 自分より奥（小さい zIndex）だけが染まるので、染めたくない HUD 等は overlay の z より大きくする。
pub mod Daylight {

    /// 空気の色の節。at = 1 日のどこか（0.0〜1.0）、color = そのときの色、
    /// strength = どれだけ染めるか（0 = 素通し、1 = その色そのもの）。
    pub type alias Key = { at = Float64, color = Color, strength = Float64 }

    /// よくある一日（夜明け前の紺 → 朝の淡い青 → 昼は素通し → 夕方の橙 → 夜の紺）。
    pub def defaults(): List[Key] =
        { at = 0.00, color = { r = 0.24, g = 0.30, b = 0.60 }, strength = 0.90 }
     :: { at = 0.22, color = { r = 0.50, g = 0.56, b = 0.78 }, strength = 0.58 }
     :: { at = 0.30, color = { r = 0.94, g = 0.90, b = 0.86 }, strength = 0.18 }
     :: { at = 0.50, color = { r = 1.00, g = 1.00, b = 1.00 }, strength = 0.00 }
     :: { at = 0.72, color = { r = 1.00, g = 0.82, b = 0.62 }, strength = 0.34 }
     :: { at = 0.80, color = { r = 0.98, g = 0.60, b = 0.44 }, strength = 0.52 }
     :: { at = 0.88, color = { r = 0.36, g = 0.36, b = 0.68 }, strength = 0.80 }
     :: { at = 0.95, color = { r = 0.24, g = 0.30, b = 0.60 }, strength = 0.90 }
     :: Nil

    /// t（1 日の進み）のときの空気の色と濃さ。節が 1 つも無ければ素通し。
    pub def sample(keys: List[Key], t: Float64): Key =
        let sorted = List.sortBy(k -> k#at, keys);
        match sorted {
            case Nil       => { at = t, color = { r = 1.0, g = 1.0, b = 1.0 }, strength = 0.0 }
            case one :: Nil => { at = t | one }
            case first :: _ =>
                let u = wrap01(t);
                // u の手前にある最後の節と、その次の節（無ければ一周して先頭）で混ぜる。
                let before = List.filter(k -> k#at <= u, sorted) |> List.last;
                let after  = List.filter(k -> k#at > u, sorted) |> List.head;
                let lo = Option.getWithDefault(shifted(-1.0, lastOf(sorted, first)), before);
                let hi = Option.getWithDefault(shifted(1.0, first), after);
                let span = hi#at - lo#at;
                let f = if (Float64.abs(span) < 0.000001) 0.0 else Num.clamp01((u - lo#at) / span);
                { at = u,
                  color = mixColor(lo#color, hi#color, f),
                  strength = lo#strength + (hi#strength - lo#strength) * f }
        }

    /// いまの空気を 1 枚の幕で掛ける。at / size = 覆う矩形、z = 掛かる境目。
    /// 濃さは色を白へ薄めることで表すので、重ね方は素直な乗算 1 回で済む。
    ///
    /// HUD の面に置くなら at = 原点・size = design 解像度。カメラが掛かる面に置くなら
    /// 見えている矩形（ViewCtx#visible）をそのまま渡す — 世界いっぱいに広げると、
    /// 盤が広くなるほど無駄に大きな面になる。
    pub def overlay(spec: { keys = List[Key], at = Vec2.Vec2, size = Vec2.Vec2, z = Int32 },
                    t: Float64): List[Render.PlacedItem] =
        let air = sample(spec#keys, t);
        if (air#strength <= 0.001) Nil
        else
            let white = { r = 1.0, g = 1.0, b = 1.0 };
            { at = spec#at,
              item = RawDraw.box(spec#size, mixColor(white, air#color, Num.clamp01(air#strength)), spec#z)
                  |> Render.blended(DrawCmd.BlendMode.Multiply) } :: Nil

    /// 空気の色を 1 つの色に掛ける。空そのものや遠景など、乗算の幕より手前に置きたい物を
    /// 手で染めるときに使う。
    pub def tint(keys: List[Key], t: Float64, base: Color): Color =
        let air = sample(keys, t);
        let mixed = mixColor({ r = 1.0, g = 1.0, b = 1.0 }, air#color, Num.clamp01(air#strength));
        let f32 = RenderUtil.f32;
        let wide = Float32.toFloat64;
        { r = wide(f32(base#r) * f32(mixed#r)),
          g = wide(f32(base#g) * f32(mixed#g)),
          b = wide(f32(base#b) * f32(mixed#b)) }

    // ── 太陽の位置から導く物 ──

    /// 地面に落ちる影の落ち方。dir = 伸びる向き（単位ベクトル）、
    /// scale = 伸び具合（1.0 = 真下の丸のまま）、alpha = 濃さ。
    pub type alias Shadow = { dir = Vec2.Vec2, scale = Float64, alpha = Float64 }

    /// 影の落ち方の決まり。
    /// longest / shortest = 日の出入りと正午の伸び具合、
    /// alphaLow / alphaHigh = 同じく濃さ、tilt = 手前へ倒す量（見下ろしの絵では影は
    /// 真横でなく少し手前へ落ちる方が地面に接して見える）。
    pub type alias ShadowSpec = {
        longest = Float64, shortest = Float64,
        alphaLow = Float64, alphaHigh = Float64,
        tilt = Float64
    }

    pub def shadowDefaults(): ShadowSpec =
        { longest = 2.4, shortest = 1.0, alphaLow = 0.12, alphaHigh = 0.3, tilt = 0.55 }

    /// 時刻（1 日の進み 0..1）から影の落ち方を導く。
    /// 日の出は太陽が東（画面の右）にあるので影は左へ長く伸び、正午は真下で短く濃く、
    /// 日の入りは右へ長く伸びる。夜は太陽が無いので、短くごく薄い影に落ち着く。
    ///
    /// 絵そのものは塗り替えない — 影の向きだけが動くので、ドット絵の色数は保たれる。
    pub def shadowAt(spec: ShadowSpec, t: Float64): Shadow =
        let sun = sunAt(t);
        // 昼の度合い。日の出・日の入りをまたぐ所でなめらかに立ち上げる —
        // 0/1 で切り替えると、影の長さがその瞬間だけパチンと飛ぶ。
        let dayness = Num.clamp01(sun#height * 6.0);
        let up = Num.clamp01(sun#height);
        let dirX = 0.0 - sun#east;                         // 影は太陽の反対側へ
        let len = Vec2.sqrt(dirX * dirX + spec#tilt * spec#tilt);
        { dir = if (len < 0.0001) { x = 0.0, y = 1.0 }
                else { x = dirX / len, y = spec#tilt / len },
          scale = spec#shortest + (spec#longest - spec#shortest) * (1.0 - up) * dayness,
          // 濃さは alphaLow を下回らない — 物は夜でも地面に触っているので、
          // 接地の暗がりまで太陽と一緒に消すと、その物が浮いて見える。
          alpha = spec#alphaLow + (spec#alphaHigh - spec#alphaLow) * up * dayness }

    /// 見下ろしの落ち影を 2 枚で置く（接地の暗がり + 太陽の日影）。
    ///
    /// 1 枚目 = 接地。足元にぴったり付く濃い小判。物が地面に触っている合図で、これが無いと
    /// 物が浮いて見える。2 枚目 = 日影。太陽の反対へ伸びる薄い影で、時刻で向きと長さが変わる。
    ///
    /// 伸びは物の大きさまでに抑える — 小さな石に長い影が付くと影の方が主役になり、
    /// かえって浮いて見える。升目に載せるのは、なめらかな楕円だけ画素の階段が無いと
    /// ドット絵の画面から浮くため（pixelStep = 0 で切る）。
    pub def groundShadow(spec: { sun = Shadow, at = Vec2.Vec2, radius = Float64,
                                 ink = Color, pixelStep = Float64,
                                 z = Int32 }): List[Render.PlacedItem] =
        let sun = spec#sun;
        let r = spec#radius;
        let stretch = 1.0 + Float64.min(1.0, sun#scale - 1.0);
        let reach = r * (stretch - 1.0) * 0.7;
        let cast = RawDraw.ellipseAt(
            { x = spec#at#x + sun#dir#x * reach, y = spec#at#y + sun#dir#y * reach * 0.4 },
            { x = r * stretch, y = r * 0.34 * stretch }, spec#ink, spec#z);
        let contact = RawDraw.ellipseAt(spec#at, { x = r * 0.7, y = r * 0.26 },
                                       spec#ink, spec#z + 1);
        ({ item = Render.fade(sun#alpha * 0.7, cast#item) | cast }
         :: { item = Render.fade(sun#alpha * 1.4, contact#item)
                | contact } :: Nil)
            |> Render.snappedAll(spec#pixelStep)

    /// 横から見た絵の落ち影を 2 枚で置く（接地の暗がり + 太陽の日影）。
    ///
    /// groundShadow との違いは、伸びる向きが横だけになること。見下ろしの絵では地面が画面と
    /// ほぼ平行で、影は上下にも伸びる。横視点では地面が画面の下側に細い帯として見えるので、
    /// 影は足元から左右どちらかへ伸び、縦には厚みぶんしか要らない。半径 1 つ（円）では
    /// この形を表せないので、radii で横半径と縦半径を別々に受ける。
    ///
    /// radii = 影 1 枚ぶんの半径。x = 足元の幅の半分、y = 地面の帯の厚みの半分。
    /// 太陽が高いほど短く濃く、低いほど横へ長く薄く伸びる（sun は shadowAt の出力）。
    /// pixelStep はドット絵の升目（0 で切る）。
    pub def sideShadow(spec: { sun = Shadow, at = Vec2.Vec2, radii = Vec2.Vec2,
                               ink = Color, pixelStep = Float64,
                               z = Int32 }): List[Render.PlacedItem] =
        let sun = spec#sun;
        let rx = spec#radii#x;
        let ry = spec#radii#y;
        // 伸びは足元の幅までに抑える（groundShadow と同じ理由 — 影の方が主役になる）。
        let stretch = 1.0 + Float64.min(1.0, sun#scale - 1.0);
        // 横向きの符号だけを使う。dir#y は見下ろしの「手前へ倒す」ぶんで、横視点では
        // 影が地面から浮いて見えるので捨てる。
        let side = if (sun#dir#x < 0.0) -1.0 else 1.0;
        let half = rx * stretch;
        let cast = RawDraw.ellipseAt(
            { x = spec#at#x + side * (half - rx), y = spec#at#y },
            { x = half, y = ry }, spec#ink, spec#z);
        let contact = RawDraw.ellipseAt(spec#at, { x = rx * 0.7, y = ry * 0.8 },
                                        spec#ink, spec#z + 1);
        ({ item = Render.fade(sun#alpha * 0.7, cast#item) | cast }
         :: { item = Render.fade(sun#alpha * 1.4, contact#item) | contact } :: Nil)
            |> Render.snappedAll(spec#pixelStep)

    /// 太陽の位置。height = 高さ（+1 が真上・0 が地平線・負は夜）、
    /// east = 東西（+1 が東＝画面の右・-1 が西）。
    /// どちらも 1 日を通してなめらかで、日付が変わる所でも飛ばない。
    pub def sunAt(t: Float64): { height = Float64, east = Float64 } =
        // 6 時を 0、18 時を 1 とした昼の進み（外＝夜は負にも正にも伸びる）。
        let u = (wrap01(t) - 0.25) / 0.5;
        { height = Vec2.sin(Vec2.pi() * u), east = Vec2.cos(Vec2.pi() * u) }

    /// 太陽の向きを、ドット絵の塗りが使う 8 方向のうち 1 つに丸める（-1 / 0 / +1）。
    /// 絵は作り直したときだけ塗りが変わるので、とびとびにしか動かないのが正しい
    /// （なめらかに回すと中間色が要り、ドット絵でなくなる）。
    ///
    /// 向きは影と必ず逆になる: 太陽が東（右）にあれば、光は右から差し、影は左へ伸びる。
    /// ここを取り違えると「影は左・ふち光も左」というありえない絵になる。
    pub def lightStepAt(t: Float64): (Int32, Int32) =
        let east = sunAt(t)#east;
        let x = if (east > 0.35) 1 else if (east < -0.35) -1 else 0;
        // 見下ろしの絵では太陽は常に上にある（真上から見ているので）。
        (x, -1)

    /// その時刻の「暗さ」（0 = 素通し、1 = 真っ暗）。空気の色の濃さと同じ 1 つの値。
    /// 明かりを点ける・沈む物を暗くするといった判断は、これを読めば空気の色とずれない
    /// （別に昼夜の曲線を作ると、ランプの点灯と空の色が食い違う）。
    pub def darkness(keys: List[Key], t: Float64): Float64 =
        Num.clamp01(sample(keys, t)#strength)

    // ── 内部 ──

    /// 一周ぶん at をずらした節（0 の手前・1 の先へ節を延長して、日またぎを継ぎ目なくする）。
    def shifted(delta: Float64, k: Key): Key = { at = k#at + delta | k }

    def lastOf(sorted: List[Key], fallback: Key): Key =
        List.last(sorted) |> Option.getWithDefault(fallback)

    def mixColor(a: Color, b: Color, f: Float64): Color =
        let t = Float64.truncateToFloat32(Num.clamp01(f));
        let f32 = RenderUtil.f32;
        let wide = Float32.toFloat64;
        { r = wide(f32(a#r) + (f32(b#r) - f32(a#r)) * t),
          g = wide(f32(a#g) + (f32(b#g) - f32(a#g)) * t),
          b = wide(f32(a#b) + (f32(b#b) - f32(a#b)) * t) }

    def wrap01(v: Float64): Float64 =
        let f = v - Float64.floor(v);
        if (f < 0.0) f + 1.0 else f
}
