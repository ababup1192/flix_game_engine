// RenderPaint.Internal.TargetTable — 描き先（Pass の render target）と、その history・開いている描き先・最後に画面へ描いたコマの表を、
// GL（RenderPaint）と WebGPU（WebGpuPaint）が同じ関数で育てる。作り直すか・いつ捨てるか・名前で引く絵の表へどう載せるかはここで決め、
// GPU の物を作る・捨てる所だけを backend ごとの関数の record（Targets）で受ける。backend は表の番号から自分の物（FBO・texture）を引く。
// WhyNot: 表を backend ごとに持たない — 作り直しの鍵・history の捨て方・絵の表への載せ方が 2 本に分かれ、片方だけ直す事になる。
//   GPU を呼ばずに表の振る舞いをテストできるのもこの形だけ。
pub mod RenderPaint.Internal.TargetTable {
    use RenderPaint.Internal.TextureTable

    /// 描き先 1 枚の控え。texture = backend の表の番号（名前で引く絵の番号と同じ）。width・height・format・samples = 頼まれた形（作り直しの鍵）。
    pub type alias Row = { texture = Int32, width = Int32, height = Int32, format = RenderTarget.Format, samples = Int32 }

    /// backend が描き先を作る・捨てる関数の組。create(spec) = spec の大きさ・形式・標本の数で作り、表の番号を返す・destroy(番号) = 捨てる。
    pub type alias Targets = {
        create = RenderTarget.TargetSpec -> Int32 \ IO,
        destroy = Int32 -> Unit \ IO
    }

    /// 表。targetsRef = 名前 → 描き先（history も historyName で載る）・historyRef = 描き先の名前 → その history・
    /// active = 開いている描き先（None = 画面）・lastFrame = 最後に画面へ描いたコマ（大きさが変わった時の描き直し・注釈のスクショ）。
    pub type alias Table = {
        targetsRef = Ref[Map[String, Row], Static],
        historyRef = Ref[Map[String, Row], Static],
        active = Array[Option[RenderTarget.TargetSpec], Static],
        lastFrame = Array[RenderPaint.Frame, Static]
    }

    /// 空の表。
    pub def fresh(): Table \ IO =
        { targetsRef = Ref.fresh(Static, Map.empty()), historyRef = Ref.fresh(Static, Map.empty()),
          active = Array#{(None: Option[RenderTarget.TargetSpec])} @ Static,
          lastFrame = Array#{RenderPaint.emptyFrame()} @ Static }

    /// RenderTarget.Target.beginTarget の表の側。表に無いか形が違えば作り直し（古い方とその history は捨てる）、
    /// 名前で引く絵の表へ design の大きさで載せ、開いている描き先として控える。
    /// design の大きさで載せるのは、sprite の大きさと region の uv が絵の表の大きさで決まり、縮んだ描き先も design 全面に貼れるように。
    pub def begin(targets: Targets, textures: TextureTable.Tables, table: Table, design: (Float64, Float64),
                  spec: RenderTarget.TargetSpec): Row \ IO =
        let row = match Map.get(spec#name, Ref.get(table#targetsRef)) {
            case Some(r) if isSameShape(spec, r) => r
            case old =>
                Option.forEach(r -> targets#destroy(r#texture), old);
                if (Option.isEmpty(old)) () else dropHistory(targets, textures, table, spec#name);
                let fresh = rowOf(targets#create(spec), spec);
                Ref.put(Map.insert(spec#name, fresh, Ref.get(table#targetsRef)), table#targetsRef);
                fresh
        };
        putDesignSized(textures, design, spec#name, row);
        Array.put(Some(spec), 0, table#active);
        row

    /// RenderTarget.Target.endTarget の表の側。閉じた描き先（開いていなければ None）を返す。
    pub def end(table: Table): Option[Row] \ IO =
        let closed = Array.get(0, table#active) |> Option.flatMap(spec -> Map.get(spec#name, Ref.get(table#targetsRef)));
        Array.put(None, 0, table#active);
        closed

    /// 開いている描き先の宣言（None = 画面）。
    pub def activeSpec(table: Table): Option[RenderTarget.TargetSpec] \ IO = Array.get(0, table#active)

    /// 名前の描き先（history の名前も引ける）。
    pub def rowByName(table: Table, name: String): Option[Row] \ IO = Map.get(name, Ref.get(table#targetsRef))

    /// name が描き先か（history を含む。描き先の中身を上下逆に格納する backend が、貼る時の uv を返すのに使う）。
    pub def isTarget(table: Table, name: String): Bool \ IO = Map.memberOf(name, Ref.get(table#targetsRef))

    /// 描き先の名前の全部（history を含む）。
    pub def names(table: Table): Set[String] \ IO = Map.keysOf(Ref.get(table#targetsRef))

    /// 描き先 spec の history を用意して返す。形（大きさ・形式）が同じなら前の物を使う。
    /// history は標本を持たない（作る spec の samples は 1）。中身を前のコマから写すか透明で塗るかは backend が決める。
    pub def ensureHistory(targets: Targets, textures: TextureTable.Tables, table: Table, design: (Float64, Float64),
                          spec: RenderTarget.TargetSpec): Row \ IO =
        let historyName = RenderTarget.historyName(spec#name);
        let row = match Map.get(spec#name, Ref.get(table#historyRef)) {
            case Some(r) if isSameTexture(spec, r) => r
            case old =>
                Option.forEach(r -> targets#destroy(r#texture), old);
                let single = { name = historyName, samples = 1 | spec };
                let fresh = rowOf(targets#create(single), single);
                Ref.put(Map.insert(spec#name, fresh, Ref.get(table#historyRef)), table#historyRef);
                fresh
        };
        Ref.put(Map.insert(historyName, row, Ref.get(table#targetsRef)), table#targetsRef);
        putDesignSized(textures, design, historyName, row);
        row

    /// 最後に画面へ描いたコマ。
    pub def lastFrame(table: Table): RenderPaint.Frame \ IO = Array.get(0, table#lastFrame)

    /// 画面のコマを控える（submitFrame を通らず描く起動画面も、大きさが変わった時に描き直せるように）。
    pub def rememberFrame(table: Table, frame: RenderPaint.Frame): Unit \ IO = Array.put(frame, 0, table#lastFrame)

    /// 作ってある r が spec と同じ大きさ・形式・標本の数か（描き先の作り直しの鍵）。
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

    /// 描き先 name の history を捨てる（次に要る時に新しい形で作る）。
    def dropHistory(targets: Targets, textures: TextureTable.Tables, table: Table, name: String): Unit \ IO =
        match Map.get(name, Ref.get(table#historyRef)) {
            case None    => ()
            case Some(r) =>
                targets#destroy(r#texture);
                let historyName = RenderTarget.historyName(name);
                Ref.put(Map.remove(name, Ref.get(table#historyRef)), table#historyRef);
                Ref.put(Map.remove(historyName, Ref.get(table#targetsRef)), table#targetsRef);
                Ref.put(Map.remove(historyName, Ref.get(textures#registryRef)), textures#registryRef)
        }
}
