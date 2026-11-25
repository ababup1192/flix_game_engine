// First — 「初めての 1 回」の止まりを測る区間（つまみ first。Field の場面を動かない物の集まりで描く）。
//   first=1     … 物を置かずに回した後、集まりを初めて載せる（区間 first）→ しばらく同じ物（steady）→ 同じ名前の別の値の集まりへ替える（rebuild。形も新しい）
//   first=skin  … 集まりは頭から載せておき、途中で骨つきの人物を 1 体出す（区間 skin。人物の glb は つまみ person）
// 区間ごとに 1 行の JSON（BenchRun.summaryFields に、1 コマの時間と 3D の描き手の CPU の区間の最大を足した物）を出す。起動し直して何回か流し、最悪のコマを見る。
mod First {
    use fge::{AnimationClip3d, App, Mat4, Model3d, Pose3d, Render, Scene3d, Skin3d, Vec2, Vec3}

    pub enum Mode with Eq {
        case Group
        case Skin
    }

    /// つまみの表の first（無ければ None）。
    pub def modeOf(knobs: Map[String, String]): Option[Mode] = match Map.get("first", knobs) {
        case Some("1")    => Some(Mode.Group)
        case Some("skin") => Some(Mode.Skin)
        case _            => None
    }

    /// 場面の作り置き。first = 初めて載せる集まり・second = 後で替える集まり（同じ名前・別の形）・person = 後で出す骨つきの人物。
    pub type alias Kit = { mode = Mode, field = Field.Kit, first = Scene3d.StaticGroup, second = Scene3d.StaticGroup, person = Option[Model3d.Model3d] }

    /// 測る区間の名前と、始めるコマ・終えるコマ（終えるコマは含まない）。
    def segments(mode: Mode): List[(String, Int32, Int32)] =
        let late = if (mode == Mode.Group) "rebuild" else "skin";
        ("first", 28, 90) :: ("steady", 90, swapAt() - 2) :: (late, swapAt() - 2, endAt()) :: Nil

    /// 集まりを初めて載せるコマ（Skin では頭から載せる）。
    def showAt(mode: Mode): Int32 = if (mode == Mode.Group) 30 else 0

    /// 別の値の集まりへ替える・人物を出すコマ。
    def swapAt(): Int32 = 120

    def endAt(): Int32 = 300

    /// field の設定を、動く物なし・集まりあり にしたつまみの表から作る。person = 人物の glb（Skin の時だけ読む）。
    pub def kitOf(mode: Mode, knobs: Map[String, String], person: Option[Model3d.Model3d]): Kit =
        let config = { staticGroup = true, movingPercent = 0 | Field.configOf(knobs) };
        let field = Field.kitOf(config);
        let resting = Scene3d.groupInstancesOf(field#resting);
        // WhyNot: second に first と同じ形を使い回さない — 束が届いた後の階は新しい形を持ち、形を GPU に作る・中身の鍵を取る仕事が作り直しに入る。
        let reshaped = resting |> List.mapWithIndex((i, inst) -> {
            let f = Scene3d.instanceFieldsOf(inst);
            let moved = Scene3d.meshInstance(Field.shapeOf(config#faceGrid, i + 100000), f#world);
            (Int32.toString(i), f#material |> Option.map(m -> Scene3d.withMaterial(m, moved)) |> Option.getWithDefault(moved))
        });
        { mode = mode, field = field, first = field#resting, second = Scene3d.staticGroup("field", reshaped), person = person }

    /// 1 コマの記録。frame = 今のコマの番号・samples = 今の区間の値・done = 全部の区間を出し終えた。
    pub type alias Run = { frame = Int32, samples = List[BenchRun.Sample], done = Bool }

    pub def start(): Run = { frame = 0, samples = Nil, done = false }

    /// 1 コマ進める（区間の頭で `[bench] begin`・終わりで `[bench] result {…}`・全部の終わりで `[bench] done`）。
    pub def advance(kit: Kit, emit: String -> Unit \ ef, head: List[(String, String)], sample: BenchRun.Sample, r: Run): Run \ ef =
        if (r#done) r
        else {
            let f = r#frame;
            let segs = segments(kit#mode);
            segs |> List.find(s -> { let (_, b, _) = s; b == f }) |> Option.forEach(_ -> emit("[bench] begin"));
            let inside = segs |> List.find(s -> { let (_, b, e) = s; f >= b and f < e });
            let samples = if (Option.isEmpty(inside)) r#samples else sample :: r#samples;
            match inside {
                case Some((name, _, e)) if f + 1 == e =>
                    emit("[bench] result ${BenchRun.jsonObject(List.append(head, ("section", BenchRun.quoted(name)) :: List.append(maxFields(samples), BenchRun.summaryFields(samples))))}");
                    let done = f + 1 >= endAt();
                    if (done) emit("[bench] done") else ();
                    { frame = f + 1, samples = Nil, done = done }
                case _ => { frame = f + 1, samples = samples | r }
            }
        }

    /// 区間の最大（1 コマの時間と、3D の描き手の CPU の区間ごと）。
    def maxFields(samples: List[BenchRun.Sample]): List[(String, String)] =
        let phaseMax = (name: String) -> samples
            |> List.flatMap(s -> s#diagnostics |> Option.map(d -> d#scene3dCounts#cpuPhases) |> Option.getWithDefault(Nil))
            |> List.filter(p -> fst(p) == name)
            |> List.foldLeft((acc, p) -> Float64.max(acc, Int64.toFloat64(snd(p)) / 1.0e6), 0.0);
        let frameMax = samples |> List.foldLeft((acc, s) -> Float64.max(acc, s#frameMs), 0.0);
        ("frame_max", BenchRun.fmt3(frameMax)) :: ("split_max", BenchRun.fmt3(phaseMax("split"))) :: ("draw_max", BenchRun.fmt3(phaseMax("draw"))) ::
        ("preload_max", BenchRun.fmt3(phaseMax("preload"))) :: Nil

    /// コマ frame・t 秒の描き物。
    pub def items(kit: Kit, frame: Int32, t: Float64): List[Render.PlacedItem] =
        let base = Field.scene(kit#field, t);
        let groups = if (frame < showAt(kit#mode)) Nil
                     else if (frame >= swapAt() and kit#mode == Mode.Group) kit#second :: Nil
                     else kit#first :: Nil;
        let people = if (frame >= swapAt() and kit#mode == Mode.Skin) personInstances(kit, t) else Nil;
        Render.scene3d(Vec2.zero(), { groups = groups, instances = List.append(people, base#instances) | base }) :: Nil

    /// 人物を格子の手前の真ん中に、idle（無ければ休みの姿勢）で立たせた物。
    def personInstances(kit: Kit, t: Float64): List[Scene3d.Instance3d] = match kit#person {
        case None        => Nil
        case Some(model) =>
            let world = Mat4.mul(Mat4.translate(Vec3.v3(0.0, 0.0, 4.0)), Mat4.scale(Vec3.v3(16.0, 16.0, 16.0)));
            let parts = Model3d.partInstances(world, model);
            match model#skin {
                case None       => parts
                case Some(skin) =>
                    let local = Map.get("idle", model#clips) |> Option.map(c -> AnimationClip3d.sample(skin, c, t, true)) |> Option.getWithDefault(Skin3d.restPose(skin));
                    parts |> List.map(Scene3d.withPose(Pose3d.compute(skin, local)))
            }
    }

    /// 入口の App の step に渡す: 区間の値を集める。
    pub def sampleOf(frame: App.Frame): BenchRun.Sample = BenchRun.sampleOf(frame, 0.0)
}
