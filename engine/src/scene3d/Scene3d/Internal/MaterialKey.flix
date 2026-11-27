// Scene3d.Internal.MaterialKey — 材質の値から作る字の鍵（Material3d は Eq を持たない閉じた型なので、同じ材質かを字で比べる）。

/// 材質の鍵の中身。ゲームは呼ばない。
pub mod Scene3d.Internal.MaterialKey {

    /// 形のつなぎ（staticGroup）が見る材質の鍵（描き手の batch の鍵と、絵の名前と、emissionIntensity）。
    // WhyNot: 木を比べて同じ材質か確かめない — 描き手の batch も shaderHash で同じ木と見なしていて、つないだ形はその batch の頭の木で描かれる。
    pub def materialKeyOf(m: Scene3d.MaterialFields): String =
        let wrap = if (m#wrap == Scene3d.Wrap.Clamp) "clamp" else "repeat";
        let reads = Scene3d.materialTexReadsOf(m) |> List.map(match (name, filter) -> "${name}:${filter}") |> String.intercalate(",");
        let params = Map.toList(m#params) |> List.map(match (k, v) -> "${k}=${v}") |> String.intercalate(",");
        "${force m#shaderHash}|${wrap}|${m#cutout}|${m#doubleSided}|${m#emissionIntensity}|${m#maxMipLevels}|${reads}|${params}"

    /// materialKeyOf に、つながない材質（半透明・法線マップ・metallicRoughness・screenAoOnBlend）の欄も足した鍵。
    /// 欄の違う材質の物を 1 つの形につないで、頭の材質で描いてしまわない所（デカールのつなぎ）が使う。
    // WhyNot: materialKeyOf そのものに欄を足さない — staticGroup は半透明と法線マップの物をつながないので、足すと既存の鍵の字だけが変わる。
    pub def fullMaterialKeyOf(m: Scene3d.MaterialFields): String =
        let normal = m#normalMap |> Option.map(n -> "${n#texture}*${n#strength}") |> Option.getWithDefault("-");
        let pbr = m#metallicRoughness |> Option.map(r -> "${r#metallic},${r#roughness},${r#texture}") |> Option.getWithDefault("-");
        "${materialKeyOf(m)}|blend=${m#blend}|normal=${normal}|pbr=${pbr}|ab=${m#screenAoOnBlend}"
}
