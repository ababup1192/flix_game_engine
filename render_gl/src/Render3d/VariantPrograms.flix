// Render3d.VariantPrograms — 3D の描き手（Render3d）の、場面のシェーダーの変種（Render3d.ProgramKey.ShaderVariant の +ps・+pu・+psx）の頂点の色とビルボードのプログラム。
// 既定の変種は Render3d.programsOf・skinnedProgramsOf の物を返し、ほかはその変種の場面を初めて描く時に組んで State の表に持つ。材質のプログラムの変種は ProgramKind の欄（Render3d.Material）。
// 変種だけが持つ uniform（+ps の点光源の影・+pu の uInverseUnitsPerMeterSquared・+psx の uPsx など）の location は、その変種の GLSL の宣言から拾う（Render3d.Uniforms.locationsOf）。
mod Render3d.VariantPrograms {
    import fge.gl.GlContext
    use Render3d.{ProgramUniforms, State, bindDataTextureUnits, bindUnits, compileProgram, programsOf, skinnedProgramsOf}
    use Render3d.ProgramKey.{ShaderVariant, billboardVariantOf, variantKeyOf}
    use Render3d.Uniforms.{R3dUniform}
    use Render3dGlsl.{billboardFragmentSourceFor, billboardVertexSourceFor, litFragmentSourceFor, litVertexSourceFor}

    /// 変種 v の頂点の色の（skinned なら骨つきの版の）プログラム。
    pub def litProgramOfVariant(gl: GlContext, state: State, v: ShaderVariant, skinned: Bool): ProgramUniforms \ IO =
        let key = variantKeyOf(v);
        if (key == "") (if (skinned) skinnedProgramsOf(gl, state)#lit else programsOf(gl, state)#lit)
        else match Map.get((key, skinned), Ref.get(state#variantLitRef)) {
            case Some(p) => p
            case None =>
                let made = compileProgram(gl, litVertexSourceFor(skinned, v), litFragmentSourceFor(v), "scene3d:lit" + (if (skinned) ":skin" else "") + key);
                bindDataTextureUnits(gl, made);
                Ref.put(Map.insert((key, skinned), made, Ref.get(state#variantLitRef)), state#variantLitRef);
                made
        }

    /// 変種 v の場面のビルボードのプログラム（billboardVariantOf の変種）。
    pub def billboardProgramFor(gl: GlContext, state: State, v: ShaderVariant): ProgramUniforms \ IO =
        let bv = billboardVariantOf(v);
        let key = variantKeyOf(bv);
        if (key == "") programsOf(gl, state)#billboard
        else match Map.get(key, Ref.get(state#variantBillboardRef)) {
            case Some(p) => p
            case None =>
                let made = compileProgram(gl, billboardVertexSourceFor(bv), billboardFragmentSourceFor(bv), "scene3d:billboard" + key);
                bindUnits(gl, made, (R3dUniform.Image, 0) :: Nil);
                Ref.put(Map.insert(key, made, Ref.get(state#variantBillboardRef)), state#variantBillboardRef);
                made
        }
}
