// Render3d.TextureTable3d — 3D の材質の絵の置き場の表（Render3d.TextureSlot → 番号・段の数・大きさ・最後に使ったコマ）を、GL（Render3d.Material）と
// WebGPU（Render3d.WebGpuRenderer）が同じ関数で育てる。番号を振る・作り直すか・上げられなかった絵をいつ試し直すか・上限で捨てる物を選ぶのはここ。
// GPU の絵を作る（make）・捨てる（destroy）所だけを backend の関数で受け、backend は番号から自分の物を引く。
// 番号は計画の行の絵の組（Render3d.SceneList の reads）に載り、行を流す時に backend が作る（numberOf で振ってから ensure で作る）。
// WhyNot: 表を backend ごとに持たない — 上限の数え方・先に上げた物の守り方・試し直しの間が 2 本に分かれ、片方だけ直す事になる（Render3d.MeshTable と同じ）。
mod Render3d.TextureTable3d {
    use Render3d.{TextureSlot, TextureSource}
    use Render3d.Material.{Budget, budgetEvictions, isOverBudget}

    /// 作った絵の中身。levels = 段の数・bytes = 段を合わせた置き場の大きさ・stamp = 作り直しの鍵（段つきの写しは元の絵の番号と版・場面の絵は ""）。
    pub type alias Created = { levels = Int32, bytes = Int64, stamp = String }

    /// 絵 1 枚の控え。handle = 番号・created = 作った物（まだなら None）・lastUsed = 最後に使ったコマの世代（要素 1 つ）。
    pub type alias Entry = { handle = Int32, created = Option[Created], lastUsed = Array[Int64, Static] }

    /// 表。entries = 鍵 → 控え・free = 捨てた後に使い回す番号・next = まだ使っていない一番小さい番号（要素 1 つ）・
    /// retry = 作れなかった鍵 → 最後に試したコマの世代（retryFrames の間は試さない）。
    pub type alias Table = {
        entries = Ref[Map[TextureSlot, Entry], Static], free = Ref[List[Int32], Static], next = Array[Int32, Static], retry = Ref[Map[TextureSlot, Int64], Static]
    }

    /// 名前で引いた絵。Own = 場面の textures の絵・Registered = 全体の登録の絵。
    pub enum TextureHit {
        case Own(Texture3d.Texture3d)
        case Registered(Scene3dRenderer.RegisteredTexture)
    }

    /// 名前 name の絵を引く。"tex3d:" は source#own・ほかは全体の登録から。無ければ None。
    pub def findTexture(source: TextureSource, name: String): Option[TextureHit] \ IO =
        if (String.startsWith(prefix = Texture3d.namePrefix(), name)) Map.get(name, source#own) |> Option.map(TextureHit.Own)
        else (source#textureOf)(name) |> Option.map(TextureHit.Registered)

    /// 置き場の鍵の、段の作り方の部分。gpuMip = backend が段を GPU に作らせる（GL の prefersGpuMipmap）。
    // WhyNot: GPU が段を作る機種で平均の仕方を鍵に入れない — generateMipmap は平均の仕方を選べないので、色と法線に貼った同じ絵が同じ段の 2 枚になる。
    /// 字は Mip.Average の ToString と同じ。
    // WhyNot: ToString.toString(average) を呼ばない — 絵 1 枚を引くたびに同じ字を作り直す（毎コマ、行の数 × 絵の数）。
    pub def mipKeyOf(gpuMip: Bool, average: Mip.Average): String =
        if (gpuMip) "gpu" else match average {
            case Mip.Average.SrgbCurve => "SrgbCurve"
            case Mip.Average.Raw       => "Raw"
        }

    /// width × height の絵の段の数（段 0 から 1 × 1 まで・次の段の辺は floor(n / 2)。Mip.build と同じ数え方）。
    pub def levelsOf(width: Int32, height: Int32): Int32 =
        if (width <= 1 and height <= 1) 1 else 1 + levelsOf(Int32.max(1, width / 2), Int32.max(1, height / 2))

    /// 材質の絵の名前 name を使い方 textureUse で貼る時の、表の鍵と段の数（計画が行の reads と values に書く）。
    /// gpuMip は mipKeyOf と同じ。上下を返して読む全体の登録の絵（レンダーターゲット）と、どこにも無い名前は None（表に載せない）。
    pub def readOf(gpuMip: Bool, source: TextureSource, name: String, textureUse: Texture3d.TextureUse): Option[(TextureSlot, Int32)] \ IO =
        findTexture(source, name) |> Option.flatMap(readOfHit(gpuMip, name, textureUse))

    /// readOf の、名前 name を引いた絵 hit が既にある形。
    pub def readOfHit(gpuMip: Bool, name: String, textureUse: Texture3d.TextureUse, hit: TextureHit): Option[(TextureSlot, Int32)] =
        let mipKey = mipKeyOf(gpuMip, Texture3d.mipAverageOf(Texture3d.mipSpaceOf(textureUse)));
        match hit {
            case TextureHit.Own(t)        => Some((TextureSlot.Scene(Texture3d.contentHash(t) + ":" + mipKey), levelsOf(Texture3d.width(t), Texture3d.height(t))))
            case TextureHit.Registered(t) =>
                if (t#flipped) None
                else Some((TextureSlot.Copy(name + ":" + mipKey), levelsOf(roundSide(t#width), roundSide(t#height))))
        }

    def roundSide(v: Float64): Int32 = Float64.tryToInt32(Float64.round(v)) |> Option.getWithDefault(1)

    /// 作れなかった絵を試し直すまでのコマの数。
    // WhyNot: 毎コマ試し直さない — 機種が絵を持つまでの間、毎コマ GPU のテクスチャを作っては捨てる。
    pub def retryFrames(): Int64 = 60i64

    /// 空の表。
    pub def fresh(): Table \ IO =
        { entries = Ref.fresh(Static, Map.empty()), free = Ref.fresh(Static, Nil), next = Array#{0} @ Static, retry = Ref.fresh(Static, Map.empty()) }

    /// 鍵 slot の番号（無ければ振る。GPU には作らない）。どちらでも lastUsed を gen にする。
    pub def numberOf(table: Table, gen: Int64, slot: TextureSlot): Int32 \ IO = touch(table, gen, slot)#handle

    // WhyNot: 使った世代を書くのに Map.insert しない — 木の道を作り直し、毎コマ 行の数 × 絵の数だけ割り当てる。
    def touch(table: Table, gen: Int64, slot: TextureSlot): Entry \ IO =
        let entries = Ref.get(table#entries);
        match Map.get(slot, entries) {
            case Some(found) => Array.put(gen, 0, found#lastUsed); found
            case None        => putEntry(table, entries, slot, { handle = takeHandle(table), created = None, lastUsed = Array#{gen} @ Static })
        }

    def putEntry(table: Table, entries: Map[TextureSlot, Entry], slot: TextureSlot, entry: Entry): Entry \ IO =
        Ref.put(Map.insert(slot, entry, entries), table#entries);
        entry

    def takeHandle(table: Table): Int32 \ IO = match Ref.get(table#free) {
        case h :: rest =>
            Ref.put(rest, table#free);
            h
        case Nil =>
            let h = Array.get(0, table#next);
            Array.put(h + 1, 0, table#next);
            h
    }

    /// 鍵 slot の絵の番号と作った物（lastUsed を gen にする）。作っていないか stamp が違えば、前の物を destroy で捨ててから make(番号) で作る。
    /// make が None（作れない）なら控えずに None を返し、retryFrames の間は make を呼ばずに None を返す。
    // WhyNot: 作れなかった絵を作った物として控えない — 控えると機種が後から絵を持っても、置き場から落ちるまで黒いまま。
    pub def ensure(table: Table, destroy: Int32 -> Unit \ IO, gen: Int64, slot: TextureSlot, stamp: String,
                   make: Int32 -> Option[{ levels = Int32, bytes = Int64 }] \ IO): Option[(Int32, Created)] \ IO =
        let entry = touch(table, gen, slot);
        match entry#created {
            case Some(c) if c#stamp == stamp => Some((entry#handle, c))
            case old =>
                if (Option.nonEmpty(old)) destroy(entry#handle) else ();
                let waiting = Map.get(slot, Ref.get(table#retry)) |> Option.exists(tried -> gen - tried < retryFrames());
                let made = if (waiting) None else make(entry#handle);
                match made {
                    case Some(m) =>
                        let created = { levels = m#levels, bytes = m#bytes, stamp = stamp };
                        Ref.put(Map.insert(slot, { created = Some(created) | entry }, Ref.get(table#entries)), table#entries);
                        Ref.put(Map.remove(slot, Ref.get(table#retry)), table#retry);
                        Some((entry#handle, created))
                    case None =>
                        Ref.put(Map.insert(slot, { created = None | entry }, Ref.get(table#entries)), table#entries);
                        if (waiting) () else Ref.put(Map.insert(slot, gen, Ref.get(table#retry)), table#retry);
                        None
                }
        }

    /// 作った絵の鍵 → 控え。
    pub def createdOf(table: Table): Map[TextureSlot, (Int32, Created, Int64)] \ IO =
        Ref.get(table#entries) |> Map.filterMap(e -> e#created |> Option.map(c -> (e#handle, c, Array.get(0, e#lastUsed))))

    /// 置き場の上限 budget を超えた時だけ、今と前のコマで使っていない古い物から（先に上げた preloaded は後へ）destroy で捨て、捨てた鍵と、
    /// 捨てた後も上限を超えているかを返す（Pass の場面は画面のコマの 1 つ前の世代で描かれる）。作っていない番号で gen − 1 より前の物も外す。
    /// 場面の絵（TextureSlot.Scene）は枚数に数え、段つきの写しは大きさにだけ数える。画面のコマの終わりに 1 回呼ぶ。
    pub def sweep(table: Table, destroy: Int32 -> Unit \ IO, gen: Int64, budget: Budget, preloaded: Set[TextureSlot]): (List[TextureSlot], Bool) \ IO =
        if (hasNothingToSweep(Ref.get(table#entries), gen, budget)) (Nil, false)
        else sweepOver(table, destroy, gen, budget, preloaded)

    /// 上限の内で、外す古い番号（作っていない物）も無いか（数え方は Render3d.Material.budgetTotals と同じ）。
    // WhyNot: 毎コマ createdOf と budgetEntries の list を作ってから上限を比べない — 上限の内のコマ（ほとんど全部）で絵の数だけ割り当てる。
    def hasNothingToSweep(entries: Map[TextureSlot, Entry], gen: Int64, budget: Budget): Bool \ IO =
        let (n, size, stale) = Map.foldLeftWithKey((acc, slot, e) -> {
            let (count, bytes, anyStale) = acc;
            match e#created {
                case Some(c) => (if (isCounted(slot)) count + 1 else count, bytes + c#bytes, anyStale)
                case None    => (count, bytes, anyStale or Array.get(0, e#lastUsed) < gen - 1i64)
            }
        }, (0, 0i64, false), entries);
        not stale and n <= budget#count and size <= budget#size

    def sweepOver(table: Table, destroy: Int32 -> Unit \ IO, gen: Int64, budget: Budget, preloaded: Set[TextureSlot]): (List[TextureSlot], Bool) \ IO =
        let entries = Ref.get(table#entries);
        let budgetEntries = createdOf(table) |> Map.toList |> List.map(ke -> {
            let (slot, (_, c, lastUsed)) = ke;
            (slot, { lastUsed = lastUsed, size = c#bytes, counted = isCounted(slot), preloaded = Set.memberOf(slot, preloaded) })
        });
        let victims = budgetEvictions(budget, gen - 1i64, budgetEntries);
        let stale = entries |> Map.filter(e -> Option.isEmpty(e#created) and Array.get(0, e#lastUsed) < gen - 1i64) |> Map.keysOf;
        let dropped = List.foldLeft((acc, slot) -> Set.insert(slot, acc), stale, victims);
        dropped |> Set.forEach(slot -> Map.get(slot, entries) |> Option.forEach(e -> drop(table, destroy, e)));
        Ref.put(Set.foldLeft((acc, slot) -> Map.remove(slot, acc), entries, dropped), table#entries);
        let victimSet = List.toSet(victims);
        (victims, isOverBudget(budget, List.filter(ke -> not Set.memberOf(fst(ke), victimSet), budgetEntries)))

    def isCounted(slot: TextureSlot): Bool = match slot {
        case TextureSlot.Scene(_) => true
        case TextureSlot.Copy(_)  => false
    }

    def drop(table: Table, destroy: Int32 -> Unit \ IO, e: Entry): Unit \ IO =
        if (Option.isEmpty(e#created)) () else destroy(e#handle);
        Ref.put(e#handle :: Ref.get(table#free), table#free)

    /// 表の絵を全部捨てる。
    pub def release(table: Table, destroy: Int32 -> Unit \ IO): Unit \ IO =
        Ref.get(table#entries) |> Map.forEach((_, e) -> if (Option.isEmpty(e#created)) () else destroy(e#handle));
        Ref.put(Map.empty(), table#entries);
        Ref.put(Nil, table#free);
        Array.put(0, 0, table#next);
        Ref.put(Map.empty(), table#retry)
}
