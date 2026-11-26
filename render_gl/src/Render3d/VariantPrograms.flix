// Render3d.VariantPrograms — 3D の描き手（Render3d）の、場面のシェーダーの変種（Render3d.ProgramKey.ShaderVariant の +ps・+pu・+psx）の頂点の色とビルボードのプログラム。
// 既定の変種は Render3d.programsOf・skinnedProgramsOf の物を返し、ほかはその変種の場面を初めて描く時に組んで State の表に持つ。材質のプログラムの変種は ProgramKind の欄（Render3d.Material）。
mod Render3d.VariantPrograms {
    import fge.gl.GlContext
    use Render3d.{BillboardLocs, LightLocs, LitLocs, PointShadowLocs, State, billboardLocsOf, bindDataTextureUnits, compile, litLocsOf, loc, programsOf, skinnedProgramsOf}
    use Render3d.ProgramKey.{ShaderVariant, billboardVariantOf, variantKeyOf}
    use Render3dGlsl.{billboardFragmentSourceFor, billboardVertexSourceFor, litFragmentSourceFor, litVertexSourceFor}

    /// 変種 v の頂点の色の（skinned なら骨つきの版の）プログラム。
    pub def litLocsOfVariant(gl: GlContext, state: State, v: ShaderVariant, skinned: Bool): LitLocs \ IO =
        let key = variantKeyOf(v);
        if (key == "") (if (skinned) skinnedProgramsOf(gl, state)#lit else programsOf(gl, state)#lit)
        else match Map.get((key, skinned), Ref.get(state#variantLitRef)) {
            case Some(locs) => locs
            case None =>
                let program = compile(gl, litVertexSourceFor(skinned, v), litFragmentSourceFor(v), "scene3d:lit" + (if (skinned) ":skin" else "") + key);
                bindDataTextureUnits(gl, program);
                let base = litLocsOf(gl, program);
                let (light, point) = variantLocsOf(gl, program, v, base#light);
                let made = { light = light, pointShadow = point | base };
                Ref.put(Map.insert((key, skinned), made, Ref.get(state#variantLitRef)), state#variantLitRef);
                made
        }

    /// 変種 v の場面のビルボードのプログラム（billboardVariantOf の変種）。
    pub def billboardLocsFor(gl: GlContext, state: State, v: ShaderVariant): BillboardLocs \ IO =
        let key = variantKeyOf(billboardVariantOf(v));
        if (key == "") programsOf(gl, state)#billboard
        else match Map.get(key, Ref.get(state#variantBillboardRef)) {
            case Some(locs) => locs
            case None =>
                let program = compile(gl, billboardVertexSourceFor(billboardVariantOf(v)), billboardFragmentSourceFor(billboardVariantOf(v)), "scene3d:billboard" + key);
                let base = billboardLocsOf(gl, program);
                let (light, _) = variantLocsOf(gl, program, billboardVariantOf(v), base#light);
                let made = { light = light | base };
                Ref.put(Map.insert(key, made, Ref.get(state#variantBillboardRef)), state#variantBillboardRef);
                made
        }

    /// 変種 v のプログラムだけが持つ uniform の location（+ps の点光源の影・+pu の uInverseUnitsPerMeterSquared・+psx の uPsx・uPsxTarget・uVertexSnap・+sh の uSh・uSkyContribution）を light と pointShadow へ足す。
    // WhyNot: 既定のプログラムでも location を引かない — 既定の場面で GL への呼び出しが増え、変種を足す前と同じ GL の流れでなくなる。
    pub def variantLocsOf(gl: GlContext, program: Int32, v: ShaderVariant, light: LightLocs): (LightLocs, PointShadowLocs) \ IO =
        let physical = if (v#physicalUnits) { inverseUnitsPerMeterSquared = loc(gl, program, "uInverseUnitsPerMeterSquared") | light } else light;
        let units = if (v#psx) { psx = loc(gl, program, "uPsx"), psxTarget = loc(gl, program, "uPsxTarget"), vertexSnap = loc(gl, program, "uVertexSnap") | physical } else physical;
        let sky = if (v#skyIrradiance) { sh = loc(gl, program, "uSh"), skyContribution = loc(gl, program, "uSkyContribution") | units } else units;
        let point = if (v#pointShadows) Render3d.Shadow.pointShadowLocsOf(gl, program) else Render3d.Shadow.noPointShadowLocs();
        (sky, point)
}
