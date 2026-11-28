// Render3d.ShaderSourceKey — 3D の描き手が求めるシェーダーの字の種類（Render3d.ShaderSourceKey の enum）の関数。
// PC の描き手は Render3dShaders.makeRuntimeProvider がその場で木から作り、ブラウザの描き手は書き出しの時に作った表（Render3d.ShaderLibrary）を引く。
mod Render3d.ShaderSourceKey {
    use Render3d.ShaderSourceKey
    use Render3d.ProgramKey.variantKeyOf

    /// 鍵の字（書き出しの表の鍵。同じ鍵は同じ字・違う鍵は違う字）。
    pub def toKeyString(key: ShaderSourceKey): String = match key {
        case ShaderSourceKey.LitVertex(skinned, psx)        => "lit.vs" + flag(skinned, "+skin") + flag(psx, "+psx")
        case ShaderSourceKey.LitFragment(v)                 => "lit.fs" + variantKeyOf(v)
        case ShaderSourceKey.BillboardVertex(v, right)      => "billboard.vs." + rightName(right) + variantKeyOf(v)
        case ShaderSourceKey.BillboardFragment(v)           => "billboard.fs" + variantKeyOf(v)
        case ShaderSourceKey.BillboardShadowFragment        => "billboard-shadow.fs"
        case ShaderSourceKey.SkyVertex                      => "sky.vs"
        case ShaderSourceKey.SkyFragment                    => "sky.fs"
        case ShaderSourceKey.DepthFragment                  => "depth.fs"
        case ShaderSourceKey.BlitVertex                     => "blit.vs"
        case ShaderSourceKey.BlitFragment                   => "blit.fs"
        case ShaderSourceKey.MeshVertex(skinned)            => "mesh.vs" + flag(skinned, "+skin")
        case ShaderSourceKey.MaterialVertex(k)              =>
            "material.vs" + flag(k#skinned, "+skin") + flag(k#uv, "+uv") + flag(k#lightmap, "+lm") + flag(k#psx, "+psx")
        case ShaderSourceKey.MaterialFragmentTemplate(kind, readsTextures) =>
            "material.fs" + flag(kind#skinned, "+skin") + flag(kind#uv, "+uv") + flag(kind#normalMap, "+nm") + flag(kind#lightmap, "+lm")
                + flag(kind#blend, "+bl") + flag(kind#doubleSided, "+ds") + flag(kind#coverage, "+cov") + flag(kind#metallicRoughness, "+mr") + flag(kind#screenAoOnBlend, "+ab")
                + flag(kind#materialOcclusion, "+occ") + flag(readsTextures, "+tex") + "/" + variantKeyOf(kind#variant)
        case ShaderSourceKey.ScreenPassFragment(kind)       => "screen.fs." + screenPassName(kind)
    }

    def screenPassName(kind: Render3d.ScreenPasses.ScreenPassKind): String = match kind {
        case Render3d.ScreenPasses.ScreenPassKind.AoMask  => "ao-mask"
        case Render3d.ScreenPasses.ScreenPassKind.AoBlurH => "ao-blur-h"
        case Render3d.ScreenPasses.ScreenPassKind.AoBlurV => "ao-blur-v"
        case Render3d.ScreenPasses.ScreenPassKind.ShowAo  => "show-ao"
    }

    def flag(on: Bool, text: String): String = if (on) text else ""

    def rightName(right: Render3dShaders.BillboardRight): String = match right {
        case Render3dShaders.BillboardRight.Camera       => "camera"
        case Render3dShaders.BillboardRight.PerBillboard => "per-billboard"
        case Render3dShaders.BillboardRight.ByUniform    => "by-uniform"
    }
}
