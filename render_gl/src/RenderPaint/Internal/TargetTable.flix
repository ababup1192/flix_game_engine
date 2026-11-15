// RenderPaint.Internal.TargetTable — レンダーターゲット（Pass の描き先）と、その history・開いているターゲットの表を、
// GL（RenderPaint）と WebGPU（WebGpuPaint）が同じ関数で育てる。作り直すか・いつ捨てるか・テクスチャの registry へどう載せるかはここで決め、
// GPU の物を作る・捨てる所だけを backend ごとの関数の record（TargetAllocator）で受ける。backend は表の番号から自分の物（FBO・texture）を引く。
// WhyNot: 表を backend ごとに持たない — 作り直しの鍵・history の捨て方・registry への載せ方が 2 本に分かれ、片方だけ直す事になる。
//   GPU を呼ばずに表の振る舞いをテストできるのもこの形だけ。
pub mod RenderPaint.Internal.TargetTable {
    use RenderFrame.Internal.RenderList.PassHistory
    use RenderPaint.Internal.TextureTable

    /// ターゲット 1 枚の控え。texture = backend の表の番号（registry に載るテクスチャの番号と同じ）。width・height・format・samples = 頼まれた形（作り直しの鍵）。
    pub type alias Row = { texture = Int32, width = Int32, height = Int32, format = RenderTarget.Format, samples = Int32 }

    /// backend がターゲットを作る・捨てる関数の組。create(spec) = spec の大きさ・形式・標本の数で作り、表の番号を返す・destroy(番号) = 捨てる。
    pub type alias TargetAllocator = {
        create = RenderTarget.TargetSpec -> Int32 \ IO,
        destroy = Int32 -> Unit \ IO
    }

    /// 表。targetsRef = 名前 → ターゲット（history も historyName で載る）・historyRef = ターゲットの名前 → その history・
    /// active = 開いているターゲット（None = 画面）。
    pub type alias Table = {
        targetsRef = Ref[Map[String, Row], Static],
        historyRef = Ref[Map[String, Row], Static],
        active = Array[Option[RenderTarget.TargetSpec], Static]
    }

    /// 空の表。
    pub def fresh(): Table \ IO =
        { targetsRef = Ref.fresh(Static, Map.empty()), historyRef = Ref.fresh(Static, Map.empty()),
          active = Array#{(None: Option[RenderTarget.TargetSpec])} @ Static }

    /// RenderTarget.Target.beginTarget の表の側。表に無いか形が違えば作り直し（古い方とその history は捨てる）、
    /// テクスチャの registry へ design の大きさで載せ、開いているターゲットとして控える（開いていた物は閉じずに置き換わる）。
    /// design の大きさで載せるのは、sprite の大きさと region の uv が registry の大きさで決まり、縮んだターゲットも design 全面に貼れるように。
    pub def begin(allocator: TargetAllocator, textures: TextureTable.Tables, table: Table, design: (Float64, Float64),
                  spec: RenderTarget.TargetSpec): Row \ IO =
        let row = match Map.get(spec#name, Ref.get(table#targetsRef)) {
            case Some(r) if isSameShape(spec, r) => r
            case old =>
                Option.forEach(r -> allocator#destroy(r#texture), old);
                if (Option.isEmpty(old)) () else dropHistory(allocator, textures, table, spec#name);
                let fresh = rowOf(allocator#create(spec), spec);
                Ref.put(Map.insert(spec#name, fresh, Ref.get(table#targetsRef)), table#targetsRef);
                fresh
        };
        putDesignSized(textures, design, spec#name, row);
        Array.put(Some(spec), 0, table#active);
        row

    /// RenderTarget.Target.endTarget の表の側。閉じたターゲット（開いていなければ None）を返す。
    pub def end(table: Table): Option[Row] \ IO =
        let closed = Array.get(0, table#active) |> Option.flatMap(spec -> Map.get(spec#name, Ref.get(table#targetsRef)));
        Array.put(None, 0, table#active);
        closed

    /// 開いているターゲットの宣言（None = 画面）。
    pub def activeSpec(table: Table): Option[RenderTarget.TargetSpec] \ IO = Array.get(0, table#active)

    /// 名前のターゲット（history の名前も引ける）。
    pub def rowByName(table: Table, name: String): Option[Row] \ IO = Map.get(name, Ref.get(table#targetsRef))

    /// name がターゲットか（history を含む。中身を上下逆に格納する backend が、貼る時の uv を返すのに使う）。
    pub def isTarget(table: Table, name: String): Bool \ IO = Map.memberOf(name, Ref.get(table#targetsRef))

    /// 名前 → ターゲットの今の表（history を含む）。同じ描画の中で名前を何度も引く所が 1 回だけ読む。
    pub def rows(table: Table): Map[String, Row] \ IO = Ref.get(table#targetsRef)

    /// ターゲットの名前の全部（history を含む）。
    pub def names(table: Table): Set[String] \ IO = Map.keysOf(Ref.get(table#targetsRef))

    /// ターゲット spec の history を用意して返す。形（大きさ・形式）が同じなら前の物を使い、違えば古い history を捨てて作り直す。
    /// history は標本を持たない（作る spec の samples は 1）。中身を前のコマから写すか透明で塗るかは backend が決める。
    pub def ensureHistory(allocator: TargetAllocator, textures: TextureTable.Tables, table: Table, design: (Float64, Float64),
                          spec: RenderTarget.TargetSpec): Row \ IO =
        let historyName = RenderTarget.historyName(spec#name);
        let row = match Map.get(spec#name, Ref.get(table#historyRef)) {
            case Some(r) if isSameTexture(spec, r) => r
            case old =>
                Option.forEach(r -> allocator#destroy(r#texture), old);
                // WhyNot: create へ historyName を渡さない — backend の「形式を落とした」知らせは名前ごとに 1 回で、
                // history の名前で渡すとターゲット 1 枚の知らせが 2 行になる。
                let single = { samples = 1 | spec };
                let fresh = rowOf(allocator#create(single), single);
                Ref.put(Map.insert(spec#name, fresh, Ref.get(table#historyRef)), table#historyRef);
                fresh
        };
        Ref.put(Map.insert(historyName, row, Ref.get(table#targetsRef)), table#targetsRef);
        putDesignSized(textures, design, historyName, row);
        row

    /// 開いているターゲット spec へ 1 回の renderCommands を描く前の history の始末（pass を開く前に backend がする事）。
    /// reads = その描き物が spec の history を読むか・keep = 前のコマの絵を写すか（偽 = 透明で塗る。1 枚撮りと動画は前のコマを持たない）。
    /// 読まないコマは history を作らず触らない（作ってある history は捨てずに置き、次に読むコマで写し直す）。
    /// 読むコマが初めてなら history を作る。写すのは、その renderCommands を描く前の描き先の中身（1 コマに 1 回なら前のコマの最後）。
    // WhyNot: 2 枚を描き先と history で毎コマ入れ替えない — LoadOp.Keep の描き先は前のコマの絵から描き足すので写しが要り、
    //   入れ替えと写しの 2 つの道と、標本つきの描き先を名前の側に付け替える表が要る（plans/webgpu/samples/history-msaa.md）。
    pub def historyFor(allocator: TargetAllocator, textures: TextureTable.Tables, table: Table, design: (Float64, Float64),
                       spec: RenderTarget.TargetSpec, reads: Bool, keep: Bool): PassHistory \ IO =
        if (not reads) PassHistory.NoHistory
        else {
            let history = ensureHistory(allocator, textures, table, design, spec);
            if (keep) PassHistory.CopyTo(history#texture) else PassHistory.ClearTransparent(history#texture)
        }

    /// sprites と surfaces のどれかがターゲット name の history を読むか（GL は 3D の場面の読みも足して見る）。
    pub def isHistoryRead(name: String, sprites: List[RenderType.Drawable], surfaces: List[DrawCmd.SurfaceRenderCmd]): Bool =
        let history = RenderTarget.historyName(name);
        List.exists(d -> DrawCmd.textureOf(d) == history, sprites)
            or List.exists(cmd -> List.exists(read -> fst(read) == history, cmd#texReads), surfaces)

    /// 表を空にする（backend が自分の物を全部まとめて捨てた後。ここからは destroy を呼ばない）。
    pub def clear(table: Table): Unit \ IO =
        Ref.put(Map.empty(), table#targetsRef);
        Ref.put(Map.empty(), table#historyRef);
        Array.put(None, 0, table#active)

    /// 作ってある r が spec と同じ大きさ・形式・標本の数か（ターゲットの作り直しの鍵）。
    def isSameShape(spec: RenderTarget.TargetSpec, r: Row): Bool =
        isSameTexture(spec, r) and r#samples == spec#samples

    /// 作ってある r が spec と同じ大きさ・形式か（history の作り直しの鍵。history は標本を持たない）。
    def isSameTexture(spec: RenderTarget.TargetSpec, r: Row): Bool =
        r#width == spec#width and r#height == spec#height and r#format == spec#format

    def rowOf(texture: Int32, spec: RenderTarget.TargetSpec): Row =
        { texture = texture, width = spec#width, height = spec#height, format = spec#format, samples = spec#samples }

    def putDesignSized(textures: TextureTable.Tables, design: (Float64, Float64), name: String, row: Row): Unit \ IO =
        let (designW, designH) = design;
        TextureTable.putTexture(textures, name, { id = GpuHandle.wrapTextureId(row#texture), width = designW, height = designH })

    /// ターゲット name の history を捨てる（次に要る時に新しい形で作る）。
    def dropHistory(allocator: TargetAllocator, textures: TextureTable.Tables, table: Table, name: String): Unit \ IO =
        match Map.get(name, Ref.get(table#historyRef)) {
            case None    => ()
            case Some(r) =>
                allocator#destroy(r#texture);
                let historyName = RenderTarget.historyName(name);
                Ref.put(Map.remove(name, Ref.get(table#historyRef)), table#historyRef);
                Ref.put(Map.remove(historyName, Ref.get(table#targetsRef)), table#targetsRef);
                TextureTable.removeTexture(textures, historyName)
        }
}
