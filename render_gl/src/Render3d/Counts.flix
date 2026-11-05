// Render3d.Counts — 3D の描き手（Render3d）の 1 コマの数と CPU の区間の時間（FrameDiagnostics.Scene3dCounts の元）。約束は Render3d.flix の頭。
mod Render3d.Counts {
    import java.lang.System
    use Render3d.{State, warnSceneOnce}

    /// 数える物。並びは countsHolder の添え字（slotOf）。
    pub enum Counter {
        case Instances, Drawn, DrawCalls, DroppedPointLights, DroppedSpotLights,
             MeshUploads, MeshEvictions, Texture3dUploads, MipCopies, JointUploads, TargetRebuilds
    }

    /// CPU の区間。並びは phaseNsHolder の添え字（phaseSlotOf）。
    pub enum Phase {
        case Shadows, Split, Draw, EndFrame
    }

    def slotOf(c: Counter): Int32 = match c {
        case Counter.Instances          => 0
        case Counter.Drawn              => 1
        case Counter.DrawCalls          => 2
        case Counter.DroppedPointLights => 3
        case Counter.DroppedSpotLights  => 4
        case Counter.MeshUploads        => 5
        case Counter.MeshEvictions      => 6
        case Counter.Texture3dUploads   => 7
        case Counter.MipCopies          => 8
        case Counter.JointUploads       => 9
        case Counter.TargetRebuilds     => 10
    }

    /// countsHolder の長さ。
    pub def counterSlots(): Int32 = 11

    def phaseSlotOf(p: Phase): Int32 = match p {
        case Phase.Shadows  => 0
        case Phase.Split    => 1
        case Phase.Draw     => 2
        case Phase.EndFrame => 3
    }

    def phaseName(p: Phase): String = match p {
        case Phase.Shadows  => "shadows"
        case Phase.Split    => "split"
        case Phase.Draw     => "draw"
        case Phase.EndFrame => "endFrame"
    }

    def phases(): List[Phase] = Phase.Shadows :: Phase.Split :: Phase.Draw :: Phase.EndFrame :: Nil

    /// phaseNsHolder の長さ。
    pub def phaseSlots(): Int32 = 4

    /// c を n 足す。
    pub def count(state: State, c: Counter, n: Int32): Unit \ IO =
        let h = state#countsHolder;
        let i = slotOf(c);
        Array.put(Array.get(i, h) + n, i, h)

    /// f を走らせ、かかった時間から中で測った別の区間の時間を引いた残りを p に足す。
    pub def timed(state: State, p: Phase, f: Unit -> a \ ef): a \ ef + IO =
        let h = state#phaseNsHolder;
        let nestedBefore = Array.foldLeft((acc, ns) -> acc + ns, 0i64, h);
        let start = System.nanoTime();
        let result = f();
        let elapsed = System.nanoTime() - start;
        let nested = Array.foldLeft((acc, ns) -> acc + ns, 0i64, h) - nestedBefore;
        let i = phaseSlotOf(p);
        Array.put(Array.get(i, h) + elapsed - nested, i, h);
        result

    /// 前に呼んでからの数と区間の時間を返し、0 に戻す。区間は一度も測らなかった物を除く。
    pub def takeCounts(state: State): FrameDiagnostics.Scene3dCounts \ IO =
        let h = state#countsHolder;
        let at = (c: Counter) -> Array.get(slotOf(c), h);
        let ns = state#phaseNsHolder;
        let counts = {
            instances = at(Counter.Instances), drawn = at(Counter.Drawn), drawCalls = at(Counter.DrawCalls),
            droppedPointLights = at(Counter.DroppedPointLights), droppedSpotLights = at(Counter.DroppedSpotLights),
            meshUploads = at(Counter.MeshUploads), meshEvictions = at(Counter.MeshEvictions), texture3dUploads = at(Counter.Texture3dUploads),
            mipCopies = at(Counter.MipCopies), materialBuilds = List.reverse(Ref.get(state#materialBuildsRef)), jointUploads = at(Counter.JointUploads),
            targetRebuilds = at(Counter.TargetRebuilds),
            cpuPhases = phases() |> List.filterMap(p -> { let v = Array.get(phaseSlotOf(p), ns); if (v == 0i64) None else Some((phaseName(p), v)) })
        };
        Ref.put(Nil, state#materialBuildsRef);
        List.range(0, Array.length(h)) |> List.forEach(i -> Array.put(0, i, h));
        List.range(0, Array.length(ns)) |> List.forEach(i -> Array.put(0i64, i, ns));
        counts

    /// 場面の置いた物 placed 個と、そのうち視錐台の外で間引かずに描いた drawn 個を数える。
    pub def countInstances(state: State, placed: Int32, drawn: Int32): Unit \ IO =
        count(state, Counter.Instances, placed);
        count(state, Counter.Drawn, drawn)

    /// 場面 1 つで上限を超えて落とした光を数え、種類ごとに初めての時だけ知らせる。
    pub def noteDroppedLights(state: State, scene: Scene3d.Scene3dCmd): Unit \ IO =
        let d = Scene3d.droppedLightsOf(scene);
        count(state, Counter.DroppedPointLights, d#points);
        count(state, Counter.DroppedSpotLights, d#spots);
        Scene3d.droppedLightsWarnings(scene) |> List.forEach(kl -> warnSceneOnce(state, fst(kl), snd(kl)))

    /// 組んだ材質のプログラムを 1 つ控える（name = プログラムの名前）。
    pub def noteMaterialBuild(state: State, name: String, reason: FrameDiagnostics.BuildReason): Unit \ IO =
        Ref.put({ name = name, reason = reason } :: Ref.get(state#materialBuildsRef), state#materialBuildsRef)

    /// 3D の draw call を 1 つ数える。
    pub def countDrawCall(state: State): Unit \ IO = count(state, Counter.DrawCalls, 1)
}
