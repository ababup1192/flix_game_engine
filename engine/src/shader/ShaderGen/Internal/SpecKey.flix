// ShaderGen.Internal.SpecKey — Spec と材質の構造比較（eqSpec・eqMaterial）と中身の鍵（hashMaterial）。
// 外から呼ぶ口は ShaderGen に残してある。

pub mod ShaderGen.Internal.SpecKey {
    import java.lang.{Object => JObject}
    import java.lang.ref.WeakReference
    import java.lang.Double

    /// Spec 2 つの構造比較（program キャッシュの正当性の中核）。真 ⇒ compile は純関数なので
    /// GLSL も等しい、が構成的に成り立つ。
    /// WhyNot: derive の Eq にしない — Field 等の payload はレコードで、Flix のレコードは
    /// Eq を持てず導出がそこで止まる。GLSL 全文を鍵にしない — 当たったフレームでも
    /// compile（GLSL 全文の組み立て）を毎回払うことになる。ハッシュにしない — 衝突しない
    /// ことを証明できない。1 フィールドでも比べ忘れると、違う Spec を同じと誤答して
    /// 古い program の絵が何も知らせずに出続けるため、全 case・全フィールドをテストで pin する
    /// （engine/test/TestShaderGenEqSpec.flix）。
    /// テクスチャの名前は比べず、texNames の正典順での番号を比べる（GLSL に出るのは番号だけで、
    /// どの名前を bind するかは描画依頼の texNames が運ぶ）。
    /// WhyNot: 名前のまま比べない — Pass の中で読みを別名（`x@history` / `@missing:c`）へ書き換えた Spec と
    /// 書き換えない Spec が同じ name で並ぶと、毎コマ偽になって GLSL を作り直し続ける。
    /// 同じ物（参照が同じ）なら木を辿らずに真を返す — 作り置きの Spec を毎コマ渡す面では、ここで抜ける。
    /// 番号がそろうかは、2 つの木をたどりながら作る名前の対応が 1 対 1 で崩れないかで見る（texNames の正典の順は
    /// 「どの位置の名前どうしが同じか」と位置の形だけで決まるので、対応が崩れなければ番号もそろい、その逆も成り立つ）。
    pub def eqSpec(a: ShaderDoc.Spec, b: ShaderDoc.Spec): Bool =
        isSameSpec(a, b) or eqSpecTree(a, b)

    // WhyNot: 先に texNames と名前 → 番号の Map を作らない — 毎コマ作り直した Spec は参照の一致で抜けられず、比べるたびに両方の木を 2 度たどる。
    def eqSpecTree(a: ShaderDoc.Spec, b: ShaderDoc.Spec): Bool =
        eqSpecWith(sameName, a, b) or region rc { eqSpecWith(namePairing(rc), a, b) }

    /// 2 つの材質（spec・自分で光る色 emission・metallic と roughness の場 metallicRoughness）が同じ GLSL を生むか（render_gl の材質の program キャッシュの鍵）。
    /// emission と metallicRoughness の uTexN の番号は spec・emission・metallicRoughness をつないだ並びで決まる（ShaderDoc.materialTexReads）ので、
    /// 名前の対応は 3 つを通して 1 本で取る。
    /// WhyNot: spec が同じ物というだけで抜けない — spec の名前が対応に入らないまま emission を比べると、spec と同じ名前を読む emission と
    ///   別の名前を読む emission を同じと答える。
    pub def eqMaterial(specA: ShaderDoc.Spec, emissionA: Option[ShaderDoc.Shade], metallicRoughnessA: Option[ShaderDoc.Shade],
                       specB: ShaderDoc.Spec, emissionB: Option[ShaderDoc.Shade], metallicRoughnessB: Option[ShaderDoc.Shade]): Bool =
        (isSameSpec(specA, specB) and isSameEmission(emissionA, emissionB) and isSameEmission(metallicRoughnessA, metallicRoughnessB))
            or eqMaterialWith(sameName, specA, emissionA, metallicRoughnessA, specB, emissionB, metallicRoughnessB)
            or region rc { eqMaterialWith(namePairing(rc), specA, emissionA, metallicRoughnessA, specB, emissionB, metallicRoughnessB) }

    def eqMaterialWith(names: (String, String) -> Bool \ ef, specA: ShaderDoc.Spec, emissionA: Option[ShaderDoc.Shade], metallicRoughnessA: Option[ShaderDoc.Shade],
                       specB: ShaderDoc.Spec, emissionB: Option[ShaderDoc.Shade], metallicRoughnessB: Option[ShaderDoc.Shade]): Bool \ ef =
        eqSpecWith(names, specA, specB) and eqOptionShade(names, emissionA, emissionB) and eqOptionShade(names, metallicRoughnessA, metallicRoughnessB)

    def eqOptionShade(names: (String, String) -> Bool \ ef, a: Option[ShaderDoc.Shade], b: Option[ShaderDoc.Shade]): Bool \ ef =
        match (a, b) {
            case (None, None)         => true
            case (Some(sa), Some(sb)) => eqShade(names, sa, sb)
            case _                    => false
        }

    /// names = テクスチャの名前 2 つ（a 側・b 側）を同じ番号と見なすかの比べ。
    def eqSpecWith(names: (String, String) -> Bool \ ef, a: ShaderDoc.Spec, b: ShaderDoc.Spec): Bool \ ef =
        a#name == b#name
            and a#cycleRate == b#cycleRate
            and eqBindings(names, a#bindings, b#bindings)
            and eqOut(names, a#out, b#out)

    /// 名前がそのまま同じ（対応が恒等なら 1 対 1 は崩れない。名前を書き換えない Spec は 1 回のたどりで済む）。
    def sameName(a: String, b: String): Bool = a == b

    /// 「a の名前 → b の名前」と「b → a」の対応を rc の中に持つ名前の比べ（2 つの木を 1 回たどる間だけ使う）。
    /// どちらの名前も初めてなら対応を足し、どちらかが既にあれば対応が合うかを見る。
    def namePairing(rc: Region[r]): ((String, String) -> Bool \ r) \ r =
        let pairs: Ref[(Map[String, String], Map[String, String]), r] = Ref.fresh(rc, (Map.empty(), Map.empty()));
        (na, nb) -> {
            let (forward, backward) = Ref.get(pairs);
            match (Map.get(na, forward), Map.get(nb, backward)) {
                case (None, None)         => Ref.put((Map.insert(na, nb, forward), Map.insert(nb, na, backward)), pairs); true
                case (Some(mb), Some(ma)) => mb == nb and ma == na
                case _                    => false
            }
        }

    /// a と b が同じ物か（中身ではなく参照）。
    /// WhyNot: Objects.equals で比べない — Flix の値が equals を中身の比べにした時に、木を辿る比べへ黙って戻る。
    pub def isSameSpec(a: ShaderDoc.Spec, b: ShaderDoc.Spec): Bool =
        unsafe IO {
            let held = new WeakReference(unchecked_cast(a as JObject));
            held.refersTo(unchecked_cast(b as JObject))
        }

    /// 2 つの色（emission か metallicRoughness）が同じ物か（両方無いか、参照が同じ）。
    pub def isSameEmission(a: Option[ShaderDoc.Shade], b: Option[ShaderDoc.Shade]): Bool =
        match (a, b) {
            case (None, None)         => true
            case (Some(sa), Some(sb)) => unsafe IO {
                let held = new WeakReference(unchecked_cast(sa as JObject));
                held.refersTo(unchecked_cast(sb as JObject))
            }
            case _                    => false
        }

    def eqBindings(ix: (String, String) -> Bool \ ef, a: List[(String, ShaderDoc.Field)], b: List[(String, ShaderDoc.Field)]): Bool \ ef =
        match (a, b) {
            case (Nil, Nil)                       => true
            case ((na, fa) :: ra, (nb, fb) :: rb) => na == nb and eqField(ix, fa, fb) and eqBindings(ix, ra, rb)
            case _                                => false
        }

    def eqOut(ix: (String, String) -> Bool \ ef, a: ShaderDoc.Out, b: ShaderDoc.Out): Bool \ ef =
        match (a, b) {
            case (ShaderDoc.Out.Fill(fa), ShaderDoc.Out.Fill(fb)) =>
                eqShade(ix, fa#shade, fb#shade) and eqField(ix, fa#alpha, fb#alpha)
        }

    def eqShade(ix: (String, String) -> Bool \ ef, a: ShaderDoc.Shade, b: ShaderDoc.Shade): Bool \ ef =
        use ShaderDoc.Shade;
        match (a, b) {
            case (Shade.Solid(ca), Shade.Solid(cb))       => eqColor(ca, cb)
            case (Shade.Ramp(ra), Shade.Ramp(rb))         =>
                eqColor(ra#lo, rb#lo) and eqColor(ra#hi, rb#hi) and eqField(ix, ra#field, rb#field)
            case (Shade.Gradient(ga), Shade.Gradient(gb)) =>
                eqStops(ga#stops, gb#stops) and eqField(ix, ga#field, gb#field)
            case (Shade.Cosine(ca), Shade.Cosine(cb))     =>
                eqColor(ca#a, cb#a) and eqColor(ca#b, cb#b) and eqColor(ca#c, cb#c)
                    and eqColor(ca#d, cb#d) and eqField(ix, ca#field, cb#field)
            case (Shade.Rgb(ra), Shade.Rgb(rb))           =>
                eqField(ix, ra#r, rb#r) and eqField(ix, ra#g, rb#g) and eqField(ix, ra#b, rb#b)
            case _                                        => false
        }

    def eqStops(a: List[(Float64, Color)], b: List[(Float64, Color)]): Bool =
        match (a, b) {
            case (Nil, Nil)                       => true
            case ((pa, ca) :: ra, (pb, cb) :: rb) => pa == pb and eqColor(ca, cb) and eqStops(ra, rb)
            case _                                => false
        }

    def eqColor(a: Color, b: Color): Bool =
        a#r == b#r and a#g == b#g and a#b == b#b

    def eqVec2(a: Vec2.Vec2, b: Vec2.Vec2): Bool =
        a#x == b#x and a#y == b#y

    def eqOptField(ix: (String, String) -> Bool \ ef, a: Option[ShaderDoc.Field], b: Option[ShaderDoc.Field]): Bool \ ef =
        match (a, b) {
            case (None, None)         => true
            case (Some(fa), Some(fb)) => eqField(ix, fa, fb)
            case _                    => false
        }

    // WhyNot: 呼ぶ所へインラインさせない — eqShade・eqOptField などへ展開されて 8,000 バイトを超え、JVM が JIT しない（材質 1 つにつき毎コマ通る）。
    @DontInline
    def eqField(ix: (String, String) -> Bool \ ef, a: ShaderDoc.Field, b: ShaderDoc.Field): Bool \ ef =
        use ShaderDoc.Field;
        match (a, b) {
            case (Field.Const(va), Field.Const(vb))               => va == vb
            case (Field.Uv(ra), Field.Uv(rb))                     => ra#axis == rb#axis
            case (Field.Worley(ra), Field.Worley(rb))             =>
                ra#scale == rb#scale and ra#seed == rb#seed and ra#out == rb#out
            case (Field.Fbm(ra), Field.Fbm(rb))                   =>
                ra#octaves == rb#octaves and ra#scale == rb#scale and ra#seed == rb#seed
            case (Field.FbmTile(ra), Field.FbmTile(rb))           =>
                ra#octaves == rb#octaves and ra#scale == rb#scale
                    and eqVec2(ra#period, rb#period) and ra#seed == rb#seed
            case (Field.Smoothstep(ra), Field.Smoothstep(rb))     =>
                ra#lo == rb#lo and ra#hi == rb#hi and eqField(ix, ra#of, rb#of)
            case (Field.Scaled(ra), Field.Scaled(rb))             =>
                ra#factor == rb#factor and eqVec2(ra#scroll, rb#scroll) and eqField(ix, ra#of, rb#of)
            case (Field.Warp(ra), Field.Warp(rb))                 =>
                ra#amount == rb#amount and ra#scale == rb#scale and ra#seed == rb#seed
                    and eqField(ix, ra#of, rb#of)
            case (Field.Mix(ra), Field.Mix(rb))                   =>
                eqField(ix, ra#a, rb#a) and eqField(ix, ra#b, rb#b) and ra#t == rb#t
            case (Field.Blend(ra), Field.Blend(rb))               =>
                eqField(ix, ra#a, rb#a) and eqField(ix, ra#b, rb#b) and eqField(ix, ra#by, rb#by)
            case (Field.Disk(ra), Field.Disk(rb))                 =>
                ra#cx == rb#cx and ra#cy == rb#cy
                    and ra#radius == rb#radius and ra#feather == rb#feather
            case (Field.Radial(ra), Field.Radial(rb))             =>
                ra#cx == rb#cx and ra#cy == rb#cy
            case (Field.RadialAspect(ra), Field.RadialAspect(rb)) =>
                ra#cx == rb#cx and ra#cy == rb#cy and ra#aspect == rb#aspect
            case (Field.Quantize(ra), Field.Quantize(rb))         =>
                eqField(ix, ra#of, rb#of) and ra#steps == rb#steps
            case (Field.Scales(ra), Field.Scales(rb))             =>
                ra#scale == rb#scale and ra#stagger == rb#stagger
            case (Field.Glints(ra), Field.Glints(rb))             =>
                ra#scale == rb#scale and ra#rate == rb#rate
                    and ra#density == rb#density and ra#seed == rb#seed
            case (Field.Ripples(ra), Field.Ripples(rb))           =>
                ra#freq == rb#freq and ra#amp == rb#amp
                    and ra#speed == rb#speed and ra#seed == rb#seed
            case (Field.Sparkle(ra), Field.Sparkle(rb))           =>
                ra#scale == rb#scale and ra#rate == rb#rate
                    and ra#density == rb#density and ra#seed == rb#seed
            case _                                                => eqFieldMore(ix, a, b)
        }

    // WhyNot: eqField を 1 つの match にしない — case が多く 8,000 バイトを超えて JVM が JIT しない。前半と後半の 2 つに分ける。
    // WhyNot: eqField の末尾の eqFieldMore の呼び出しを呼び出しでない式にしない — 13 節の形はラムダのループから呼ぶ時で、eqField は再帰（eqBindings・欄の中の欄）から呼ぶ。
    @DontInline
    def eqFieldMore(ix: (String, String) -> Bool \ ef, a: ShaderDoc.Field, b: ShaderDoc.Field): Bool \ ef =
        use ShaderDoc.Field;
        match (a, b) {
            case (Field.Bin(ra), Field.Bin(rb))                   =>
                ra#op == rb#op and eqField(ix, ra#a, rb#a) and eqField(ix, ra#b, rb#b)
            case (Field.Hash1(ra), Field.Hash1(rb))               =>
                ra#scale == rb#scale and ra#seed == rb#seed and eqOptField(ix, ra#bucket, rb#bucket)
            case (Field.Hash2(ra), Field.Hash2(rb))               =>
                ra#scale == rb#scale and ra#seed == rb#seed
                    and ra#comp == rb#comp and eqOptField(ix, ra#bucket, rb#bucket)
            case (Field.Un(ra), Field.Un(rb))                     =>
                ra#op == rb#op and eqField(ix, ra#of, rb#of)
            case (Field.Pow(ra), Field.Pow(rb))                   =>
                eqField(ix, ra#of, rb#of) and ra#p == rb#p
            case (Field.Time(ra), Field.Time(rb))                 =>
                ra#scale == rb#scale and eqField(ix, ra#offset, rb#offset)
            case (Field.Tiling(ra), Field.Tiling(rb))             =>
                eqVec2(ra#tiles, rb#tiles) and eqField(ix, ra#of, rb#of)
            case (Field.Snap(ra), Field.Snap(rb))                 =>
                eqVec2(ra#cells, rb#cells) and eqField(ix, ra#of, rb#of)
            case (Field.Swirl(ra), Field.Swirl(rb))               =>
                ra#cx == rb#cx and ra#cy == rb#cy and ra#strength == rb#strength
                    and ra#rate == rb#rate and eqField(ix, ra#of, rb#of)
            case (Field.Angle(ra), Field.Angle(rb))               =>
                ra#cx == rb#cx and ra#cy == rb#cy
            case (Field.Rotate(ra), Field.Rotate(rb))             =>
                ra#cx == rb#cx and ra#cy == rb#cy and ra#turns == rb#turns
                    and ra#rate == rb#rate and eqField(ix, ra#of, rb#of)
            case (Field.Ref(na), Field.Ref(nb))                   => na == nb
            case (Field.Tex(ra), Field.Tex(rb))                   =>
                ix(ra#name, rb#name) and ra#chan == rb#chan
            case (Field.Shift(ra), Field.Shift(rb))               =>
                eqField(ix, ra#dx, rb#dx) and eqField(ix, ra#dy, rb#dy) and eqField(ix, ra#of, rb#of)
            case (Field.Sampler(ra), Field.Sampler(rb))           =>
                ra#filter == rb#filter and eqField(ix, ra#of, rb#of)
            case (Field.Param(ra), Field.Param(rb))               => ra#name == rb#name
            case (Field.World(ra), Field.World(rb))               => ra#axis == rb#axis
            case (Field.Normal(ra), Field.Normal(rb))             => ra#axis == rb#axis
            case (Field.VertexColor(ra), Field.VertexColor(rb))   => ra#chan == rb#chan
            case (Field.TexBlur(ra), Field.TexBlur(rb))           =>
                ix(ra#name, rb#name) and ra#chan == rb#chan and eqVec2(ra#radius, rb#radius)
                    and ra#taps == rb#taps and eqField(ix, ra#amount, rb#amount)
            case (Field.TexSize(ra), Field.TexSize(rb))           =>
                ix(ra#name, rb#name) and ra#axis == rb#axis
            case _                                                => false
        }

    // ── 材質の中身の鍵（hashMaterial）──

    /// 材質（spec・emission・metallicRoughness）の中身の鍵。eqMaterial が真の 2 つは必ず同じ値になる。
    /// metallicRoughness が無い材質は、それを足す前と同じ値（無い時は何も入れない）。
    /// 違う中身が同じ値になることはありうるので、鍵で引き当てた後は eqMaterial で確かめる（render_gl の材質の program キャッシュ）。
    /// テクスチャの名前は字を入れず、spec → emission の順に木をたどって初めて出た順の番号を入れる（eqMaterial の名前の対応と同じ決まり）。
    /// spec の名前・bindings の名前・Param と Ref の名前は字のまま入れる（eqSpec が字のまま比べる）。
    /// 浮動小数は -0.0 を 0.0 にそろえてからビットを入れる（== で等しい 2 つを同じ値にする）。
    // WhyNot: SHA-256 の字にしない — 鍵を求めるのはコマごとに材質を作り直すゲームでは描くたびで、64 bit で足りる（衝突は eqMaterial が見つけて組み直すだけ）。
    // WhyNot: 木を JSON の字にして hash しない — 字を組む確保が木の大きさだけ乗り、テクスチャの名前を番号に替える手間も別に要る。
    pub def hashMaterial(spec: ShaderDoc.Spec, emission: Option[ShaderDoc.Shade], metallicRoughness: Option[ShaderDoc.Shade]): Int64 = region rc {
        let acc = Ref.fresh(rc, -3750763034362895579i64);
        let names: Ref[Map[String, Int32], rc] = Ref.fresh(rc, Map.empty());
        let tok = (t: Int64) -> Ref.put(hashStep(Ref.get(acc), t), acc);
        let tex = (n: String) -> {
            let seen = Ref.get(names);
            match Map.get(n, seen) {
                case Some(i) => tok(Int32.toInt64(i))
                case None    =>
                    let i = Map.size(seen);
                    Ref.put(Map.insert(n, i, seen), names);
                    tok(Int32.toInt64(i))
            }
        };
        hashSpec(tok, tex, spec);
        match emission {
            case None    => tok(0i64)
            case Some(s) => tok(1i64); hashShade(tok, tex, s)
        };
        match metallicRoughness {
            case None    => ()
            case Some(s) => tok(2i64); hashShade(tok, tex, s)
        };
        Ref.get(acc)
    }

    /// 鍵へ値 t を 1 つ混ぜる。
    def hashStep(acc: Int64, t: Int64): Int64 =
        let x0 = Int64.bitwiseXor(acc * 1099511628211i64, t);
        let x1 = Int64.bitwiseXor(x0, Int64.logicalRightShift(dist = 33, x0)) * -49064778989728563i64;
        let x2 = Int64.bitwiseXor(x1, Int64.logicalRightShift(dist = 33, x1)) * -4265267296055464877i64;
        Int64.bitwiseXor(x2, Int64.logicalRightShift(dist = 33, x2))

    def hashFloat(tok: Int64 -> Unit \ ef, x: Float64): Unit \ ef =
        tok(Double.doubleToLongBits(x + 0.0))

    def hashInt(tok: Int64 -> Unit \ ef, x: Int32): Unit \ ef = tok(Int32.toInt64(x))

    def hashString(tok: Int64 -> Unit \ ef, s: String): Unit \ ef =
        tok(Int32.toInt64(String.length(s)));
        tok(String.foldLeft((h, c) -> h * 31i64 + Int32.toInt64(Char.toBmpCodePoint(c)), 7i64, s))

    def hashColor(tok: Int64 -> Unit \ ef, c: Color): Unit \ ef =
        hashFloat(tok, c#r); hashFloat(tok, c#g); hashFloat(tok, c#b)

    /// 小さな enum（Axis・BinOp など）を、表に出す名前で入れる。
    def hashShown(tok: Int64 -> Unit \ ef, x: a): Unit \ ef with ToString[a] = hashString(tok, ToString.toString(x))

    def hashVec2(tok: Int64 -> Unit \ ef, v: Vec2.Vec2): Unit \ ef =
        hashFloat(tok, v#x); hashFloat(tok, v#y)

    /// Spec と Out の欄を閉じたパターンで開く（欄を足したら、ここでコンパイルが止まる）。
    // WhyNot: 呼ぶ所へインラインさせない — hashMaterial へ展開されて 8,000 バイトを超える。
    @DontInline
    def hashSpec(tok: Int64 -> Unit \ ef, tex: String -> Unit \ ef, s: ShaderDoc.Spec): Unit \ ef = match s {
        case { name = name, cycleRate = cycleRate, bindings = bindings, out = out } =>
            hashString(tok, name);
            hashFloat(tok, cycleRate);
            hashInt(tok, List.length(bindings));
            bindings |> List.forEach(nf -> { hashString(tok, fst(nf)); hashField(tok, tex, snd(nf)); () });
            match out {
                case ShaderDoc.Out.Fill({ shade = shade, alpha = alpha }) => hashShade(tok, tex, shade); hashField(tok, tex, alpha)
            }
    }

    // WhyNot: 呼ぶ所へインラインさせない — hashMaterial へ 2 か所（emission・metallicRoughness）展開されて 8,000 バイトを超える。
    @DontInline
    def hashShade(tok: Int64 -> Unit \ ef, tex: String -> Unit \ ef, s: ShaderDoc.Shade): Unit \ ef =
        use ShaderDoc.Shade;
        match s {
            case Shade.Solid(c)    => tok(1i64); hashColor(tok, c)
            case Shade.Ramp(r)     => tok(2i64); hashColor(tok, r#lo); hashColor(tok, r#hi); hashField(tok, tex, r#field)
            case Shade.Gradient(g) =>
                tok(3i64);
                hashInt(tok, List.length(g#stops));
                g#stops |> List.forEach(pc -> { hashFloat(tok, fst(pc)); hashColor(tok, snd(pc)); () });
                hashField(tok, tex, g#field)
            case Shade.Cosine(c)   =>
                tok(4i64); hashColor(tok, c#a); hashColor(tok, c#b); hashColor(tok, c#c); hashColor(tok, c#d); hashField(tok, tex, c#field)
            case Shade.Rgb(r)      => tok(5i64); hashField(tok, tex, r#r); hashField(tok, tex, r#g); hashField(tok, tex, r#b)
        }

    def hashOptField(tok: Int64 -> Unit \ ef, tex: String -> Unit \ ef, f: Option[ShaderDoc.Field]): Unit \ ef =
        match f {
            case None    => tok(0i64)
            case Some(x) => tok(1i64); hashField(tok, tex, x)
        }

    /// 種類ごとの番号。全部の case を書く（case を足したら、ここで網羅の不足としてコンパイルが止まる）。
    def fieldTag(f: ShaderDoc.Field): Int64 =
        use ShaderDoc.Field;
        match f {
            case Field.Const(_)        => 1i64
            case Field.Uv(_)           => 2i64
            case Field.Worley(_)       => 3i64
            case Field.Fbm(_)          => 4i64
            case Field.FbmTile(_)      => 5i64
            case Field.Smoothstep(_)   => 6i64
            case Field.Scaled(_)       => 7i64
            case Field.Warp(_)         => 8i64
            case Field.Mix(_)          => 9i64
            case Field.Blend(_)        => 10i64
            case Field.Disk(_)         => 11i64
            case Field.Radial(_)       => 12i64
            case Field.RadialAspect(_) => 13i64
            case Field.Quantize(_)     => 14i64
            case Field.Scales(_)       => 15i64
            case Field.Glints(_)       => 16i64
            case Field.Ripples(_)      => 17i64
            case Field.Sparkle(_)      => 18i64
            case Field.Bin(_)          => 19i64
            case Field.Hash1(_)        => 20i64
            case Field.Hash2(_)        => 21i64
            case Field.Un(_)           => 22i64
            case Field.Pow(_)          => 23i64
            case Field.Time(_)         => 24i64
            case Field.Tiling(_)       => 25i64
            case Field.Snap(_)         => 26i64
            case Field.Swirl(_)        => 27i64
            case Field.Angle(_)        => 28i64
            case Field.Rotate(_)       => 29i64
            case Field.Ref(_)          => 30i64
            case Field.Tex(_)          => 31i64
            case Field.Shift(_)        => 32i64
            case Field.TexBlur(_)      => 33i64
            case Field.TexSize(_)      => 34i64
            case Field.Sampler(_)      => 35i64
            case Field.Param(_)        => 36i64
            case Field.World(_)        => 37i64
            case Field.Normal(_)       => 38i64
            case Field.VertexColor(_)  => 39i64
        }

    // WhyNot: 呼ぶ所へインラインさせない — hashMaterial・hashShade へ展開されて 8,000 バイトを超え、JVM が JIT しない（毎コマ材質を組み直すゲームでは材質ごとに通る）。
    @DontInline
    def hashField(tok: Int64 -> Unit \ ef, tex: String -> Unit \ ef, f: ShaderDoc.Field): Unit \ ef =
        tok(fieldTag(f));
        hashFieldPayload(tok, tex, f);
        ()

    // WhyNot: 欄の中身を 1 つの match にしない — case が多く 8,000 バイトを超えて JVM が JIT しない。前半と後半の 2 つに分ける。
    // WhyNot: ここで網羅を求めない — 網羅は fieldTag が止める。中身を入れ忘れた case は鍵が当たりやすくなるだけで、eqMaterial が見つける。
    // WhyNot: 末尾の hashFieldPayloadMore の呼び出しを呼び出しでない式にしない — 13 節の形はラムダのループから呼ぶ時で、ここは hashField からしか呼ばない。
    @DontInline
    def hashFieldPayload(tok: Int64 -> Unit \ ef, tex: String -> Unit \ ef, f: ShaderDoc.Field): Unit \ ef =
        use ShaderDoc.Field;
        let fl = x -> hashFloat(tok, x);
        let i = x -> hashInt(tok, x);
        let sub = x -> hashField(tok, tex, x);
        match f {
            case Field.Const(v)        => fl(v)
            case Field.Uv(r)           => hashShown(tok, r#axis)
            case Field.Worley(r)       => fl(r#scale); i(r#seed); hashShown(tok, r#out)
            case Field.Fbm(r)          => i(r#octaves); fl(r#scale); i(r#seed)
            case Field.FbmTile(r)      => i(r#octaves); fl(r#scale); hashVec2(tok, r#period); i(r#seed)
            case Field.Smoothstep(r)   => fl(r#lo); fl(r#hi); sub(r#of)
            case Field.Scaled(r)       => fl(r#factor); hashVec2(tok, r#scroll); sub(r#of)
            case Field.Warp(r)         => fl(r#amount); fl(r#scale); i(r#seed); sub(r#of)
            case Field.Mix(r)          => sub(r#a); sub(r#b); fl(r#t)
            case Field.Blend(r)        => sub(r#a); sub(r#b); sub(r#by)
            case Field.Disk(r)         => fl(r#cx); fl(r#cy); fl(r#radius); fl(r#feather)
            case Field.Radial(r)       => fl(r#cx); fl(r#cy)
            case Field.RadialAspect(r) => fl(r#cx); fl(r#cy); fl(r#aspect)
            case Field.Quantize(r)     => sub(r#of); i(r#steps)
            case Field.Scales(r)       => fl(r#scale); fl(r#stagger)
            case Field.Glints(r)       => fl(r#scale); fl(r#rate); fl(r#density); i(r#seed)
            case Field.Ripples(r)      => fl(r#freq); fl(r#amp); fl(r#speed); i(r#seed)
            case Field.Sparkle(r)      => fl(r#scale); fl(r#rate); fl(r#density); i(r#seed)
            case _                     => hashFieldPayloadMore(tok, tex, f)
        }

    @DontInline
    def hashFieldPayloadMore(tok: Int64 -> Unit \ ef, tex: String -> Unit \ ef, f: ShaderDoc.Field): Unit \ ef =
        use ShaderDoc.Field;
        let fl = x -> hashFloat(tok, x);
        let i = x -> hashInt(tok, x);
        let sub = x -> hashField(tok, tex, x);
        match f {
            case Field.Bin(r)          => hashShown(tok, r#op); sub(r#a); sub(r#b)
            case Field.Hash1(r)        => fl(r#scale); i(r#seed); hashOptField(tok, tex, r#bucket)
            case Field.Hash2(r)        => fl(r#scale); i(r#seed); hashShown(tok, r#comp); hashOptField(tok, tex, r#bucket)
            case Field.Un(r)           => hashShown(tok, r#op); sub(r#of)
            case Field.Pow(r)          => sub(r#of); fl(r#p)
            case Field.Time(r)         => fl(r#scale); sub(r#offset)
            case Field.Tiling(r)       => hashVec2(tok, r#tiles); sub(r#of)
            case Field.Snap(r)         => hashVec2(tok, r#cells); sub(r#of)
            case Field.Swirl(r)        => fl(r#cx); fl(r#cy); fl(r#strength); fl(r#rate); sub(r#of)
            case Field.Angle(r)        => fl(r#cx); fl(r#cy)
            case Field.Rotate(r)       => fl(r#cx); fl(r#cy); fl(r#turns); fl(r#rate); sub(r#of)
            case Field.Ref(n)          => hashString(tok, n)
            case Field.Tex(r)          => tex(r#name); hashShown(tok, r#chan)
            case Field.Shift(r)        => sub(r#dx); sub(r#dy); sub(r#of)
            case Field.TexBlur(r)      => tex(r#name); hashShown(tok, r#chan); hashVec2(tok, r#radius); i(r#taps); sub(r#amount)
            case Field.TexSize(r)      => tex(r#name); hashShown(tok, r#axis)
            case Field.Sampler(r)      => hashShown(tok, r#filter); sub(r#of)
            case Field.Param(r)        => hashString(tok, r#name)
            case Field.World(r)        => hashShown(tok, r#axis)
            case Field.Normal(r)       => hashShown(tok, r#axis)
            case Field.VertexColor(r)  => hashShown(tok, r#chan)
            case _                     => ()
        }
}
