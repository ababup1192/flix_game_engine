// PxShade — ドット絵の塗りに光の陰影（ふち光・接地影・ディザ・粒）を掛ける純粋な filter。
// *.sprite.json を読んだ直後に 1 度だけ掛ける（毎フレームには入らない）。
// Hash01 の channel は 1〜4 を使う。Material の範囲（83 以降）と重ねないこと。
pub mod PxShade {

    /// 仕上げの重み。0 にしたものは掛からない。
    /// lightX / lightY = 光の来る向き（-1 = 左 / 上、+1 = 右 / 下、0 = その軸は効かない）。
    pub type alias Spec = {
        rim = Float64,         // 光の側の縁を 1 段階明るく（立体の丸みが出る）
        contact = Float64,     // 光と反対側の縁を 1 段階暗く（地面や隣との境が締まる）
        dither = Float64,      // 明と中の境目を市松に散らして切り替わりを隠す
        grain = Float64,       // 面の内側に明暗の点を散らす（ベタ塗りののっぺり対策）
        grainScale = Int32,    // grain の升目の大きさ。上げると点が塊になり土の斑に見える
        lightX = Int32,
        lightY = Int32
    }

    /// よくある設定（左上からの光・ふち光と接地影は全部・ディザは半分）。
    pub def defaults(): Spec =
        { rim = 1.0, contact = 1.0, dither = 0.5, grain = 0.0, grainScale = 1,
          lightX = -1, lightY = -1 }

    /// 何も掛けない設定（絵をそのまま使いたいとき）。
    pub def none(): Spec =
        { rim = 0.0, contact = 0.0, dither = 0.0, grain = 0.0, grainScale = 1,
          lightX = -1, lightY = -1 }

    /// 材料の「中の色 → (明るい色, 暗い色)」の表。文字はその絵の legend に合わせ、
    /// 実際の色は描く側の resolver が決める（ここは文字を差し替えるだけ）。
    pub type alias Ramp = Map[Char, (Char, Char)]

    /// 1 コマ（文字格子）に仕上げを掛ける。
    pub def shade(spec: Spec, ramp: Ramp, rows: List[String]): List[String] =
        let height = List.length(rows);
        if (height == 0) rows
        else {
            let grid = rows |> List.map(row -> String.toList(row) |> List.toVector) |> List.toVector;
            let widthAt = y -> if (y < 0 or y >= height) 0 else Vector.length(Vector.get(y, grid));
            let src = (x, y) ->
                if (y < 0 or y >= height or x < 0) '.'
                else {
                    let row = Vector.get(y, grid);
                    if (x >= Vector.length(row)) '.' else Vector.get(x, row)
                };
            // 「地の続き」= 表に載っている色（中・明・暗のどれか）。それ以外（透明・輪郭）は外。
            let solid = ch -> Map.memberOf(ch, ramp)
                or Map.exists((_, tones) -> fst(tones) == ch or snd(tones) == ch, ramp);
            // 行の長さは元のまま保つ（そろえて詰めるとコマの形が変わる）。
            List.range(0, height) |> List.map(y ->
                region rc {
                    let sb = StringBuilder.empty(rc);
                    List.range(0, widthAt(y))
                        |> List.forEach(x -> StringBuilder.append(pixel(spec, ramp, src, solid, x, y), sb));
                    StringBuilder.toString(sb)
                })
        }

    /// 全コマ・全スプライトに同じ仕上げを掛けた Doc を返す（読み込み直後に 1 度だけ呼ぶ）。
    pub def shadeDoc(spec: Spec, ramp: Ramp, doc: PxSpriteDoc.Doc): PxSpriteDoc.Doc =
        shadeWith(_ -> spec, ramp, doc)

    /// スプライトごとに仕上げを変えて掛ける。
    ///
    /// 地面のように「敷き詰めて 1 つの面になる」絵は、縁の仕上げ（ふち光・接地影）を
    /// 外さないと 1 枚ずつが縁取られて升目の格子が見えてしまう。そういう絵には
    /// 粒だけの仕上げを与える — 何を縁と見なすかは絵ごとに違う、という話。
    pub def shadeWith(specOf: String -> Spec, ramp: Ramp,
                      doc: PxSpriteDoc.Doc): PxSpriteDoc.Doc =
        { sprites = doc#sprites |> Map.mapWithKey(name -> sp -> {
              let spec = specOf(name);
              if (spec#rim <= 0.0 and spec#contact <= 0.0 and spec#dither <= 0.0
                      and spec#grain <= 0.0) sp
              else { frames = sp#frames |> Map.map(rows -> shade(spec, ramp, rows)) | sp }
          }) | doc }

    // ── 1 画素ぶんの判定 ──

    def pixel(spec: Spec, ramp: Ramp, src: (Int32, Int32) -> Char,
              solid: Char -> Bool, x: Int32, y: Int32): Char =
        let ch = src(x, y);
        // 縁かどうかは縦・横を別々に見る（斜めだけを見ると、まっすぐな辺が縁と見なされない）。
        let openTowards = (dx, dy) ->
            (dx != 0 and not solid(src(x + dx, y))) or (dy != 0 and not solid(src(x, y + dy)));
        match Map.get(ch, ramp) {
            case Some((light, dark)) =>
                // 光の側が空いている画素は、ふち光が外れても暗くはしない —
                // 密度で外れたぶんが影に回ると、光の側の角が暗くなってしまう。
                if (openTowards(spec#lightX, spec#lightY))
                    if (roll(spec#rim, x, y, 1)) light
                    else grainOf(spec, ch, light, dark, x, y)
                else if (openTowards(0 - spec#lightX, 0 - spec#lightY)
                             and roll(spec#contact, x, y, 2)) dark
                // 面の内側の粒。1 画素ずつばらばらに振ると「ごま塩」になるので、
                // grainScale の升目ごとに振って塊にする（土や草の斑に見える）。
                // 明るい塊と暗い塊が同じくらい出るよう、1 つの値の両端で振り分ける。
                else grainOf(spec, ch, light, dark, x, y)
            case None =>
                // 明るい色の「影の側の隣」が中の色なら、そこは明↔中の境目。
                // 市松に中を混ぜて切り替わりをぼかす（ディザ）。
                match Map.findLeft((_, tones) -> fst(tones) == ch, ramp) {
                    case Some((m, _)) =>
                        let below = src(x - spec#lightX, y - spec#lightY);
                        if (below == m and Int32.modulo(x + y, 2) == 1
                                and roll(spec#dither, x, y, 3)) m
                        else ch
                    case None => ch
                }
        }

    /// 面の内側の 1 画素。grainScale の升目ごとに 1 つの値を引き、その両端だけを
    /// 明・暗に振る（真ん中は中の色のまま）。同じ升目は同じ色になるので点が塊になる。
    def grainOf(spec: Spec, mid: Char, light: Char, dark: Char, x: Int32, y: Int32): Char =
        if (spec#grain <= 0.0) mid
        else {
            let step = Int32.max(1, spec#grainScale);
            let v = Hash01.at((x / step) * 31337 + (y / step) * 6151, 4);
            // 1.0 を超えると明暗の縞が全域を覆い、面が丸ごと明るくなってしまう。
            let half = Float64.min(1.0, Float64.max(0.0, spec#grain)) / 2.0;
            if (v < half) light else if (v > 1.0 - half) dark else mid
        }

    /// その画素に効かせるか。weight は 0..1 の密度（1.0 で全部・0.5 で半分）。
    /// 座標から決まるので、何度掛けても同じ絵になる。
    def roll(weight: Float64, x: Int32, y: Int32, salt: Int32): Bool =
        if (weight >= 1.0) true
        else if (weight <= 0.0) false
        else Hash01.at(x * 7919 + y * 104729, salt) < weight
}
