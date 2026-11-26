// Render3d.Counts — 3D の描き手の 1 コマの数と CPU の区間の時間（FrameDiagnostics.Scene3dCounts の元）。約束は Render3d.flix の頭。
// 数える入れ物（Holders）は GL の Render3d.State と WebGPU の Render3d.WebGpuRenderer の状態が同じ名前の欄で持ち、ここの関数を両方が呼ぶ。
mod Render3d.Counts {
    import java.lang.System
    use Render3d.{State, warnSceneOnce}

    /// 数える入れ物の欄（record に足して持つ）。countsHolder = Counter と BatchBreak の数・phaseNsHolder = Phase の時間（ns）・
    /// materialBuildsRef = 組んだ材質のプログラム（新しい物が頭）。
    pub type alias Holders[r: RecordRow] = {
        countsHolder = Array[Int32, Static], phaseNsHolder = Array[Int64, Static], materialBuildsRef = Ref[List[FrameDiagnostics.ShaderBuild], Static] | r
    }

    /// 空の入れ物の欄。
    pub def freshHolders(): { countsHolder = Array[Int32, Static], phaseNsHolder = Array[Int64, Static], materialBuildsRef = Ref[List[FrameDiagnostics.ShaderBuild], Static] } \ IO =
        { countsHolder = Array.repeat(Static, counterSlots(), 0), phaseNsHolder = Array.repeat(Static, phaseSlots(), 0i64), materialBuildsRef = Ref.fresh(Static, Nil) }

    /// 数える物。並びは countsHolder の添え字（slotOf）。
    pub enum Counter {
        case Instances, Drawn, DrawCalls, DroppedPointLights, DroppedSpotLights,
             MeshUploads, MeshEvictions, Texture3dUploads, MipCopies, JointUploads, TargetRebuilds, BillboardRuns, BillboardImages,
             ShadowMapsReused, ShadowMapsRedrawn
    }

    /// draw call が分かれた理由（FrameDiagnostics.Scene3dBatchBreaks の欄）。並びは countsHolder の添え字（breakSlotOf）。
    pub enum BatchBreak {
        case ShadowPass, Billboard, Sky, Transparent, Lightmap, Skinned, Material, Mesh
    }

    /// b を数える countsHolder の添え字（Render3d.SceneList の行の分かれた理由の欄もこの番号）。
    pub def breakSlotOf(b: BatchBreak): Int32 = match b {
        case BatchBreak.ShadowPass  => 11
        case BatchBreak.Billboard   => 12
        case BatchBreak.Sky         => 13
        case BatchBreak.Transparent => 14
        case BatchBreak.Lightmap    => 15
        case BatchBreak.Skinned     => 16
        case BatchBreak.Material    => 17
        case BatchBreak.Mesh        => 18
    }

    /// CPU の区間。並びは phaseNsHolder の添え字（phaseSlotOf）。
    pub enum Phase {
        case Shadows, Split, Draw, EndFrame, Mip, Preload
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
        case Counter.BillboardRuns      => 19
        case Counter.BillboardImages    => 20
        case Counter.ShadowMapsReused   => 21
        case Counter.ShadowMapsRedrawn  => 22
    }

    /// countsHolder の長さ。
    pub def counterSlots(): Int32 = 23

    def phaseSlotOf(p: Phase): Int32 = match p {
        case Phase.Shadows  => 0
        case Phase.Split    => 1
        case Phase.Draw     => 2
        case Phase.EndFrame => 3
        case Phase.Mip      => 4
        case Phase.Preload  => 5
    }

    def phaseName(p: Phase): String = match p {
        case Phase.Shadows  => "shadows"
        case Phase.Split    => "split"
        case Phase.Draw     => "draw"
        case Phase.EndFrame => "endFrame"
        case Phase.Mip      => "mip"
        case Phase.Preload  => "preload"
    }

    def phases(): List[Phase] = Phase.Shadows :: Phase.Split :: Phase.Draw :: Phase.EndFrame :: Phase.Mip :: Phase.Preload :: Nil

    /// phaseNsHolder の長さ。
    pub def phaseSlots(): Int32 = 6

    /// c を n 足す。
    pub def count(state: { countsHolder = Array[Int32, Static] | r }, c: Counter, n: Int32): Unit \ IO =
        let h = state#countsHolder;
        let i = slotOf(c);
        Array.put(Array.get(i, h) + n, i, h)

    /// f を走らせ、かかった時間から中で測った別の区間の時間を引いた残りを p に足す。
    pub def timed(state: { phaseNsHolder = Array[Int64, Static] | r }, p: Phase, f: Unit -> a \ ef): a \ ef + IO =
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
    pub def takeCounts(state: Holders[r]): FrameDiagnostics.Scene3dCounts \ IO =
        let h = state#countsHolder;
        let at = (c: Counter) -> Array.get(slotOf(c), h);
        let breakAt = (b: BatchBreak) -> Array.get(breakSlotOf(b), h);
        let ns = state#phaseNsHolder;
        let counts = {
            instances = at(Counter.Instances), drawn = at(Counter.Drawn), drawCalls = at(Counter.DrawCalls),
            droppedPointLights = at(Counter.DroppedPointLights), droppedSpotLights = at(Counter.DroppedSpotLights),
            meshUploads = at(Counter.MeshUploads), meshEvictions = at(Counter.MeshEvictions), texture3dUploads = at(Counter.Texture3dUploads),
            mipCopies = at(Counter.MipCopies), materialBuilds = List.reverse(Ref.get(state#materialBuildsRef)), jointUploads = at(Counter.JointUploads),
            targetRebuilds = at(Counter.TargetRebuilds),
            cpuPhases = phases() |> List.filterMap(p -> { let v = Array.get(phaseSlotOf(p), ns); if (v == 0i64) None else Some((phaseName(p), v)) }),
            batchBreaks = { shadowPass = breakAt(BatchBreak.ShadowPass), billboard = breakAt(BatchBreak.Billboard), sky = breakAt(BatchBreak.Sky),
                            transparent = breakAt(BatchBreak.Transparent), lightmap = breakAt(BatchBreak.Lightmap), skinned = breakAt(BatchBreak.Skinned),
                            material = breakAt(BatchBreak.Material), mesh = breakAt(BatchBreak.Mesh) },
            billboardRuns = at(Counter.BillboardRuns), billboardImages = at(Counter.BillboardImages),
            shadowMapsReused = at(Counter.ShadowMapsReused), shadowMapsRedrawn = at(Counter.ShadowMapsRedrawn)
        };
        Ref.put(Nil, state#materialBuildsRef);
        List.range(0, Array.length(h)) |> List.forEach(i -> Array.put(0, i, h));
        List.range(0, Array.length(ns)) |> List.forEach(i -> Array.put(0i64, i, ns));
        counts

    /// 影の地図（atlas は面）の動かない物の控えを使い回したか（made が偽）、描き直したか（made が真）を 1 つ数える。
    pub def noteShadowCache(state: { countsHolder = Array[Int32, Static] | r }, made: Bool): Unit \ IO =
        count(state, if (made) Counter.ShadowMapsRedrawn else Counter.ShadowMapsReused, 1)

    /// 場面の置いた物 placed 個と、そのうち視錐台の外で間引かずに描いた drawn 個を数える。
    pub def countInstances(state: { countsHolder = Array[Int32, Static] | r }, placed: Int32, drawn: Int32): Unit \ IO =
        count(state, Counter.Instances, placed);
        count(state, Counter.Drawn, drawn)

    /// 場面の pass の行の列 list のビルボードの行（絵のある行）の数と、その行が貼る絵の種類の数を足す。
    pub def countBillboardRuns(state: { countsHolder = Array[Int32, Static] | r }, list: Render3d.SceneList.SceneList): Unit \ IO =
        let textures = Render3d.SceneList.billboardTexturesOf(list);
        count(state, Counter.BillboardRuns, List.length(textures));
        count(state, Counter.BillboardImages, Set.size(List.toSet(textures)))

    /// 場面 1 つで上限を超えて落とした光を数え、種類ごとに初めての時だけ知らせる（景色の拡散の光の知らせも同じ口で出す）。
    pub def noteDroppedLights(state: State, scene: Scene3d.Scene3dCmd): Unit \ IO =
        countDroppedLights(state, scene);
        (Scene3d.droppedLightsWarnings(scene) ::: Scene3d.Internal.SkyIrradiance.warningsOf(scene)) |> List.forEach(kl -> warnSceneOnce(state, fst(kl), snd(kl)))

    /// 場面 1 つで上限を超えて落とした光を種類ごとに数える（知らせない）。
    pub def countDroppedLights(state: { countsHolder = Array[Int32, Static] | r }, scene: Scene3d.Scene3dCmd): Unit \ IO =
        let d = Scene3d.droppedLightsOf(scene);
        count(state, Counter.DroppedPointLights, d#points);
        count(state, Counter.DroppedSpotLights, d#spots)

    /// 組んだ材質のプログラムを 1 つ控える（name = プログラムの名前）。
    pub def noteMaterialBuild(state: { materialBuildsRef = Ref[List[FrameDiagnostics.ShaderBuild], Static] | r }, name: String,
                              reason: FrameDiagnostics.BuildReason): Unit \ IO =
        Ref.put({ name = name, reason = reason } :: Ref.get(state#materialBuildsRef), state#materialBuildsRef)

    /// 今までに数えた draw call の数と、そのうち形の違い（BatchBreak.Mesh）で分かれた数（takeCounts で 0 に戻るまでの合計。場面の前後の差で場面 1 つの数にする）。
    pub def drawCallsSoFar(state: { countsHolder = Array[Int32, Static] | r }): (Int32, Int32) \ IO =
        (Array.get(slotOf(Counter.DrawCalls), state#countsHolder), Array.get(breakSlotOf(BatchBreak.Mesh), state#countsHolder))

    /// 3D の draw call を 1 つ数え、それが 1 つの draw call に分かれた理由 why も 1 つ数える。
    pub def countDrawCall(state: { countsHolder = Array[Int32, Static] | r }, why: BatchBreak): Unit \ IO = countDrawCallAt(state, breakSlotOf(why))

    /// countDrawCall の、理由を breakSlotOf の番号で受ける形。
    pub def countDrawCallAt(state: { countsHolder = Array[Int32, Static] | r }, slot: Int32): Unit \ IO =
        count(state, Counter.DrawCalls, 1);
        let h = state#countsHolder;
        Array.put(Array.get(slot, h) + 1, slot, h)
}
