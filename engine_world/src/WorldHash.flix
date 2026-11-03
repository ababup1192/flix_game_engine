// WorldHash — 値（ふつうは World）の中身を丸ごと辿って作る SHA-256。遊んだ記録の最後の `expect world=` と、再生の終わりの比べに使う。2D と 3D で共通。
// ゲームは何も足さなくてよい（withFingerprint のように欄を選ばない）。
//
// 辿り方: record は欄の名前の順（組んだ順は見ない）・enum は case の番号と中身・配列は並びの順・文字と数は値。
// 穴: Map・Set・Chain は木の形ごと辿るので、== で同じ中身でも、入れた順が違えば違う字になりうる。
// WhyNot まだ木を並びの列へ直さない — 赤黒木の節は色の case（RedBlackTree の Case$Color$*）から見分けられるが、
//   実機と再生は同じコードを同じ順に通るのでこの門では当たらない。ギャラリーの World と実機の World を要約で比べる時に直す。
// WhyNot ToString を使わない — World の record には ToString が無く、ゲームごとに全部の欄を書き並べさせることになる。
// WhyNot 同じ物を共有しているかを見ない（中身の hash だけを重ねる）— 実機と再生で組む道が違うと、同じ中身でも共有の形が変わる。
// WhyNot Lazy の中身を辿らない — 実機は描く時に値を作り、画面なしの再生は作らないので、作ったかどうかで食い違う。
// WhyNot java.* の物の中を辿らない — JDK の中身（鍵・キャッシュ）は版と機械で変わり、World の値の一部ではない。
// クラスの名前から Flix が付ける番号（Case$Option$225350$None の 225350）を落とすので、組み直しても同じ World は同じ字になる
// （その代わり、同じ関数の中の 2 つの lambda は見分けない）。
pub mod WorldHash {
    import java.lang.{Object => JObject, Class}
    import java.lang.reflect.{Field, Modifier}
    import java.lang.reflect.{Array => JArray}
    import java.security.MessageDigest
    import java.util.IdentityHashMap
    import java.nio.ByteBuffer

    type alias Bytes = Array[Int8, Static]

    /// x の中身の SHA-256 の頭 16 字（16 進）。同じ中身なら、record の欄を組んだ順・共有の形・プロセスによらず同じ字（Map・Set の穴は頭のコメント）。
    /// 大きな World（描く元の Doc や画素の配列を抱える物）では数十 ms〜数百 ms かかるので、コマごとには呼ばない。
    // WhyNot: IO を型に出さない — 辿るのは変えられない値だけで、同じ値には同じ字を返す（JVM の反射を使うだけ）。
    //   IO を出すと、flow の expect（純粋）から引けない。
    pub def sha256Of(x: a): String = unsafe IO {
        let memo: IdentityHashMap[JObject, JObject] = new IdentityHashMap();
        let d = digestOf(memo, unchecked_cast(x as JObject));
        String.take(16, Util.Codec.encodeHex(Array.toVector(d)))
    }

    /// x の中を depth 段まで開いた部分ごとの要約（"欄の道 16 字" の行。record の欄は名前・enum と Flix の物は v0 などの欄の名前）。
    /// 再生の World 全体の要約が食い違った時に、記録の同じ行と並べてどこが違うかを見る（Flow.Record.finish がコメントで書く）。
    pub def partsOf(x: a, depth: Int32): List[String] = snd(summaryOf(x, depth))

    /// sha256Of と partsOf を、x を 1 回だけ辿って両方返す（大きな World を閉じる時に 2 回辿らない）。
    pub def summaryOf(x: a, depth: Int32): (String, List[String]) = unsafe IO {
        let memo: IdentityHashMap[JObject, JObject] = new IdentityHashMap();
        let root = unchecked_cast(x as JObject);
        let whole = String.take(16, Util.Codec.encodeHex(Array.toVector(digestOf(memo, root))));
        (whole, partLines(memo, "", root, depth))
    }

    def partLines(memo: IdentityHashMap[JObject, JObject], path: String, o: JObject, depth: Int32): List[String] \ IO =
        let here = "${if (path == "") "." else path} ${String.take(16, Util.Codec.encodeHex(Array.toVector(digestOf(memo, o))))}";
        if (depth <= 0 or Object.isNull(o)) here :: Nil
        else here :: (childrenOf(o) |> List.flatMap(match (label, child) -> partLines(memo, "${path}.${label}", child, depth - 1)))

    /// 開ける物の中身（record は欄の名前の順・Flix の物は欄の名前の順）。値・配列・JDK の物・Lazy は開かない。
    def childrenOf(o: JObject): List[(String, JObject)] \ IO =
        let c = classOf(o);
        let name = c.getName();
        if (c.isArray() or name == "java.lang.String" or isValueClass(name) or isOpaque(name) or String.startsWith(prefix = "Lazy$", name)) Nil
        else if (String.startsWith(prefix = "RecordExtend$", name)) recordFields(o) |> Map.toList
        else instanceFields(c, Nil) |> List.sortBy(fst) |> List.map(match (key, f) -> {
            f.setAccessible(true);
            (String.splitOn({substr = "."}, key) |> List.last |> Option.getWithDefault(key), f.get(o))
        })

    def digestOf(memo: IdentityHashMap[JObject, JObject], o: JObject): Bytes \ IO =
        if (Object.isNull(o)) shaOfText("null")
        else {
            // 辿っている途中の物にもう一度来たら（Ref・配列の輪）、その場は印だけを重ねる。
            let hit = memo.get(o);
            if (not Object.isNull(hit)) unchecked_cast(hit as Bytes)
            else {
                discard memo.put(o, unchecked_cast(shaOfText("cycle") as JObject));
                let d = computeDigest(memo, o);
                discard memo.put(o, unchecked_cast(d as JObject));
                d
            }
        }

    def shaOfText(text: String): Bytes \ IO =
        MessageDigest.getInstance("SHA-256").digest(text.getBytes("UTF-8"))

    def stableName(name: String): String =
        String.splitOn({substr = "$"}, name) |> List.filter(part -> not (String.nonEmpty(part) and String.forAll(Char.isDigit, part)))
            |> String.intercalate("$")

    def classOf(o: JObject): Class[JObject] \ IO = unchecked_cast(o.getClass() as Class[JObject])

    def computeDigest(memo: IdentityHashMap[JObject, JObject], o: JObject): Bytes \ IO =
        let c = classOf(o);
        let name = c.getName();
        if (c.isArray()) arrayDigest(memo, o, c)
        else if (name == "java.lang.String") shaOfText("s:" + o.toString())
        else if (isValueClass(name)) shaOfText("v:${name}:" + o.toString())
        else if (isOpaque(name)) shaOfText("j:${name}")
        else if (String.startsWith(prefix = "Lazy$", name)) shaOfText("lazy")
        else if (String.startsWith(prefix = "RecordExtend$", name)) recordDigest(memo, o)
        else objectDigest(memo, o, c)

    def isValueClass(name: String): Bool =
        List.memberOf(name, "java.lang.Integer" :: "java.lang.Long" :: "java.lang.Short" :: "java.lang.Byte" ::
            "java.lang.Double" :: "java.lang.Float" :: "java.lang.Boolean" :: "java.lang.Character" ::
            "java.math.BigInteger" :: "java.math.BigDecimal" :: Nil)

    def isOpaque(name: String): Bool =
        String.startsWith(prefix = "java.", name) or String.startsWith(prefix = "javax.", name) or
        String.startsWith(prefix = "jdk.", name) or String.startsWith(prefix = "sun.", name)

    def combine(tag: String, parts: List[Bytes]): Bytes \ IO =
        let md = MessageDigest.getInstance("SHA-256");
        md.update(tag.getBytes("UTF-8"));
        List.forEach(p -> md.update(p), parts);
        md.digest()

    def arrayDigest(memo: IdentityHashMap[JObject, JObject], o: JObject, c: Class[JObject]): Bytes \ IO =
        let n = JArray.getLength(o);
        let component: Class[JObject] = unchecked_cast(c.getComponentType() as Class[JObject]);
        if (component.isPrimitive()) {
            let md = MessageDigest.getInstance("SHA-256");
            md.update("a:${component.getName()}".getBytes("UTF-8"));
            md.update(primitiveBytes(o, component.getName(), n));
            md.digest()
        } else combine("a:${Int32.toString(n)}", List.range(0, n) |> List.map(i -> digestOf(memo, JArray.get(o, i))))

    /// 数の配列の中身をそのままの並びのバイトにする（大きな頂点・画素の配列を 1 回で SHA に流す）。
    // WhyNot: 要素ごとに字にしない — 数百万の頂点を持つ 3D の World では、閉じるのに秒単位かかる。
    // WhyNot: -0.0 と 0.0・NaN のビットをそろえない — 生のビットのまま流すので違う字になるが、実機と再生は同じ道で同じ値を作るので当たらない。
    def primitiveBytes(o: JObject, kind: String, n: Int32): Bytes \ IO = match kind {
        case "int" =>
            let a: Array[Int32, Static] = unchecked_cast(o as Array[Int32, Static]);
            let b = ByteBuffer.allocate(4 * n);
            discard b.asIntBuffer().put(a);
            b.array()
        case "long" =>
            let a: Array[Int64, Static] = unchecked_cast(o as Array[Int64, Static]);
            let b = ByteBuffer.allocate(8 * n);
            discard b.asLongBuffer().put(a);
            b.array()
        case "double" =>
            let a: Array[Float64, Static] = unchecked_cast(o as Array[Float64, Static]);
            let b = ByteBuffer.allocate(8 * n);
            discard b.asDoubleBuffer().put(a);
            b.array()
        case "float" =>
            let a: Array[Float32, Static] = unchecked_cast(o as Array[Float32, Static]);
            let b = ByteBuffer.allocate(4 * n);
            discard b.asFloatBuffer().put(a);
            b.array()
        case "byte" => unchecked_cast(o as Array[Int8, Static])
        case _ =>
            let parts = List.range(0, n) |> List.map(i -> JArray.get(o, i).toString()) |> String.intercalate(",");
            parts.getBytes("UTF-8")
    }

    def recordDigest(memo: IdentityHashMap[JObject, JObject], o: JObject): Bytes \ IO =
        combine("rec", recordFields(o) |> Map.toList |> List.flatMap(match (label, value) -> shaOfText(label) :: digestOf(memo, value) :: Nil))

    /// record の欄（名前 → 値）。同じ名前が重なっていれば外側の物。
    def recordFields(o: JObject): Map[String, JObject] \ IO =
        def walk(cur: JObject, acc: Map[String, JObject]): Map[String, JObject] \ IO = {
            let c = classOf(cur);
            if (Object.isNull(cur) or not String.startsWith(prefix = "RecordExtend$", c.getName())) acc
            else {
                let label = fieldValue(c, "label", cur).toString();
                let value = fieldValue(c, "value", cur);
                let rest = fieldValue(c, "rest", cur);
                walk(rest, if (Map.memberOf(label, acc)) acc else Map.insert(label, value, acc))
            }
        };
        walk(o, Map.empty())

    def fieldValue(c: Class[JObject], name: String, o: JObject): JObject \ IO =
        let f = c.getDeclaredField(name);
        f.setAccessible(true);
        f.get(o)

    def objectDigest(memo: IdentityHashMap[JObject, JObject], o: JObject, c: Class[JObject]): Bytes \ IO =
        let fields = instanceFields(c, Nil) |> List.sortBy(fst);
        combine("o:${stableName(c.getName())}", fields |> List.flatMap(match (key, f) -> {
            f.setAccessible(true);
            shaOfText(key) :: digestOf(memo, f.get(o)) :: Nil
        }))

    def instanceFields(c: Class[JObject], acc: List[(String, Field)]): List[(String, Field)] \ IO =
        if (Object.isNull(c) or c.getName() == "java.lang.Object") acc
        else {
            let owner = stableName(c.getName());
            let mine = Array.toList(c.getDeclaredFields()) |> List.filter(f -> not Modifier.isStatic(f.getModifiers()))
                |> List.map(f -> ("${owner}.${f.getName()}", f));
            instanceFields(unchecked_cast(c.getSuperclass() as Class[JObject]), List.append(mine, acc))
        }
}
