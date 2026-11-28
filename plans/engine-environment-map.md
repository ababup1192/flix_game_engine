# 周りの景色を映す（環境マップと箱の補正）— 計画

## なぜ

PBR（`feat/pbr`・コミット `49362dd3`）の映り込みは、空の 3 色のグラデーションしか映さない。鏡のような金属（クロム）は周りの景色をそのまま映すので、
景色の絵が無いと「白くのっぺりした球」になる。見本の部屋 `~/Documents/flix_ge_workspace/pbr_room` の Blender の手本（`debug/pbr/blender/`）では、
クロムの球に部屋の壁・天井の光る板・隣の球が映っている。

Unity の Skybox（Panoramic）と Reflection Probe の Box Projection、Godot の PanoramaSkyMaterial と ReflectionProbe（box_projection）に当たる。
人の判断（2026-11-11）: 案 A（パノラマの 1 枚絵を映す）＋ 案 B（室内の箱の補正）で進める。エンジン自身で景色を撮る仕組み（反射プローブ）は今回やらない。

## ゲームから見た形

```flix
let env = Scene3d.environmentMap(texture3d)                 // 正距円筒（2:1）のパノラマの絵。tex3d: の絵
            |> Scene3d.withEnvironmentIntensity(1.0)
            |> Scene3d.withEnvironmentBox({ min = Vec3.v3(-4.0, 0.0, -4.0), max = Vec3.v3(4.0, 4.0, 4.0), center = Vec3.v3(0.0, 1.5, 0.0) })  // 室内だけ
{ environmentMap = Some(env) | Scene3d.scene(camera, size) }
```

- 欄は `Scene3dCmd` に `environmentMap = Option[EnvironmentMap]`（既定 None）。`Environment3d` には足さない（ゲームが丸ごと書いているため）。
- 絵は正距円筒（横 2：縦 1）。`tex3d:` の絵として場面の `textures` に載せる（今の場面の絵の仕組みのまま）。sRGB の絵として読む。
- **None の場面は、今の PBR の絵と 1 bit も違わない**（空のグラデーションを映す今の道のまま）。
- 背景に空として描くかは選べる口を 1 つ（`Scene3d.withEnvironmentAsBackground(true)` など）。今回の見本の部屋では使わない（室内なので）。屋外の HDRI の空の時に使う。

## 中でする事

1. **映り込みを絵から読む**: PBR の映り込み（`LightModel3d.skyReflection` の辺り）で、`environmentMap` が Some の時は、跳ね返りの向きでパノラマの絵を読む。
   - 向き → 絵の座標: `u = 0.5 + atan2(d.x, −d.z) / (2π)`・`v = 0.5 − asin(d.y) / π`（向きの約束は Scene3d の座標の約束に合わせ、doc に書く）。
   - 粗さ: 絵の縮小版の段（mip）を `roughness × 最大の段` くらいで選ぶ。段は今の絵の縮小版の仕組み（`Mip`・場面の絵の段）を使う。横の継ぎ目（u = 0 と 1）で段がにじむ所は、継ぎ目を 1 画素ずつ写して持つか、段を選ぶ時に向きの差から求める（どちらにしたか報告）。
   - 拡散の光（環境光）は今のまま（環境マップから拡散の光までは作らない。やらない事）。
2. **箱の補正（室内）**: `withEnvironmentBox` がある時、跳ね返りの線を点から伸ばして箱の内側の面と交わる点を求め、`その点 − center` の向きで絵を読む（Unity の Box Projection と同じ式）。
3. **GL と CPU**: 絵を読む所は木の外か中か、今の PBR の作りに合わせて決める。CPU の描き手は、今の絵を読む仕組み（`SoftRaster/Internal/Texture`）で同じ段・同じ補間で読む。
4. **描き出しの鍵**: `engine_tools/src/DrawHash.flix` の場面の鍵に環境マップ（絵の名前・強さ・箱）を入れる。

## 見本の部屋（ゲームの側）

- Blender で部屋の真ん中（球の台の上あたり）から、正距円筒のパノラマを Cycles で描き出す（球と銃は隠す・ライトマップのベイクと同じ部屋の光）。2048×1024 程度。
- pbr_room で読み、箱は部屋の大きさ（8 m × 4 m × 8 m）、center はパノラマを撮った点。

## 決まりと門

- 環境マップの無い場面の絵は今と同じ: `make gl-parity` の既存の全場面（PBR の場面も含む）が今の `feat/pbr` と同じ値・テンプレの reference が一致。
- `bench/gl_parity` に場面を足す: 環境マップ（箱なし）・箱つき・粗さを並べた球。GL と CPU が門の範囲で一致。式の行があれば ExprRows にも。
- テスト: 向き → 絵の座標（6 方向と継ぎ目）・箱の補正（中心から真っすぐの線は補正しても同じ向き・壁に近い点）・None で今と同じ鍵と絵・強さ 0 で映り込み無し。
- 重さ: 環境マップの無い場面の 1 コマが変わらない（箱庭 約 5 ms）。見本の部屋の 1 コマを報告。
- 文書: `docs/scene3d.md` に節を 1 つ（絵の作り方・向きの約束・箱の補正の使い所）・逆引き 1 行・`make api-digest`・早見表 1 行・お題 1 本。
- pub の既存の型と関数の形は変えない（`Scene3dCmd` への欄の追加は追随メモに 1 行）。
- コメントは WhyNot。機械的な置き換えは `bin/fge refactor rewrite`／宣言の移動は `bin/fge refactor move`。Python や perl での .flix の置換はしない。`git stash` は使わない。コミット・push はしない。

## やらない事

- エンジン自身で景色を撮る（反射プローブ・キューブマップ）
- 環境マップから拡散の光を作る（放射照度の前計算）
- 複数の環境マップを場所で切り替える・混ぜる

## 報告に書く事

- 足した pub・触ったファイル・式（向きの約束・段の選び方・箱の補正）・継ぎ目の扱い
- テストと gl-parity と reference の結果・`make sync-engine-full`
- 見本の部屋のパノラマの作り方と、before（`after4`）・after・手本の 4 分割の比べ（3 構図）
- 箱庭と見本の部屋の 1 コマ
