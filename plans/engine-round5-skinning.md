# engine round5 — 段 D: ジョイントのアニメーション（glTF・スキニング・アニメーションクリップの再生）

改訂 3（2026-11-02。レビュー 62 → 84 点。残り 8 項目を §11 で決めた）。worktree `fge-postfx`（feat/postfx-spike）で行い、main のエンジンには入れない。
前提は段 A〜C（`plans/engine-round4-3d.md`）。

用語: ジョイント（骨 1 本）・スキン（ジョイントの木と逆バインド行列）・レストポーズ・キーフレーム・ブレンド・インスタンス・シャドウマップ。
「鍵」はこの文書では DrawHash の鍵（描いた物の同じさを決めるハッシュ）だけを指す。

## 0. 目的と範囲

Blender でジョイント（アーマチュア）を入れて動きを付けたキャラを読み込み、再生し、動きを切り替える。
例: 部屋の番兵が立っていて、近づいて決定ボタンを押すと敬礼し、終わると立ちへ戻る。

| 入れる | 入れない（理由） |
|---|---|
| glTF 2.0 のバイナリ（.glb）: メッシュ・スキン・頂点のジョイントの重み・アニメーション | テクスチャ・PBR・morph・sparse accessor・外の uri・data URI（Err にする） |
| アニメーションクリップの再生（時刻 → ジョイントごとの行列）・ループ / 1 回 | IK・リターゲット・状態遷移のエディタ |
| 2 つのポーズのブレンド（クロスフェード） | 物理で揺れる髪や服 |
| GPU と CPU のスキニング・シャドウマップも曲がった形 | 1 体 64 本を超えるジョイント（読み込みで Err。GL と CPU に同じ物を見せる） |

## 1. 型（engine/src/scene3d/。閉じた型は AGENTS.md §4 の形）

閉じた型はどれも、外から作る pub の作る関数を持つ。作る関数は中身を確かめ、外から来た値なので Result を返す。

```flix
pub mod Mat4 {   // 足す物
    pub def ofColumns(v: Vector[Float64]): Result[String, Mat4]    // 列優先の 16 個（glTF の MAT4 と同じ並び）
    pub def inverse(m: Mat4): Option[Mat4]                         // 行列式がほぼ 0 なら None
}

pub mod Quat {                              // 開いたレコード
    pub type alias Quat = { x = Float64, y = Float64, z = Float64, w = Float64 }
    pub def identity(): Quat
    pub def normalized(q: Quat): Quat
    pub def slerp(a: Quat, b: Quat, t: Float64): Quat     // 内積が負なら片方を反転して短い側の弧を通る
    pub def toMat4(q: Quat): Mat4.Mat4
}

pub mod Mesh3d {   // 足す物
    /// 頂点の並びから作る。positions / normals / colors は頂点ごとに 3 つ、indices は 3 つで三角 1 枚（表は外から時計回り）。
    /// skin = 頂点ごとに 4 つのジョイントの番号（スキンの中の何番目か）と重み（足して 1 に直す）。
    /// 確かめるのは 0 ≦ 番号 < Skin3d.maxJoints() だけ（スキンを受け取らないので、スキンの数とは描く時に照らす）。重みの合計が 0 の頂点は Err。
    pub def fromArrays(arrays: { positions = Vector[Float64], normals = Vector[Float64], colors = Vector[Float64], indices = Vector[Int32],
                                 skin = Option[{ joints = Vector[Int32], weights = Vector[Float64] }] }): Result[String, Mesh3d]
    pub def skinJoints(m: Mesh3d): Option[Vector[Int32]]
    pub def skinWeights(m: Mesh3d): Option[Vector[Float64]]
    // contentHash: fromArrays の物は法線とジョイントの重みも入れる（fromPolygons の物は今の字のまま）
}

/// ジョイントの木（閉じる）。並びは親が子より先（make が確かめる）。
pub mod Skin3d {
    pub type alias Skin3d = SkinData
    pub type alias JointPose = { translation = Vec3, rotation = Quat, scale = Vec3 }   // ジョイント 1 本の局所の姿勢
    /// names・parents（-1 が根。親の番号は自分より小さい）・レストポーズ・逆バインド行列。
    /// inverseBinds が None ならレストポーズから計算する（テストや手で組むスキンのための口）。Gltf は仕様どおり、無ければ Some(単位行列の並び) を渡す。
    /// rootTransform = 根のジョイントより上の、ジョイントでないノード（Blender のアーマチュアのノード）の world 行列。
    pub def make(spec: { names = Vector[String], parents = Vector[Int32], rest = Vector[JointPose],
                         inverseBinds = Option[Vector[Mat4.Mat4]], rootTransform = Mat4.Mat4 }): Result[String, Skin3d]
    pub def jointCount(s: Skin3d): Int32
    pub def jointIndex(s: Skin3d, name: String): Option[Int32]
    pub def restPose(s: Skin3d): Vector[JointPose]
    pub def maxJoints(): Int32 = 64
}

/// アニメーションクリップ（閉じる）。ジョイントごと・欄（translation / rotation / scale）ごとのキーフレームの列。
pub mod AnimationClip3d {
    pub type alias AnimationClip3d = ClipData
    pub enum Interpolation { case Linear; case Step }
    pub enum Path { case Translation; case Rotation; case Scale }
    /// 1 本の欄。values は時刻ごとに幅 3（Translation・Scale）か 4（Rotation の x, y, z, w）で並ぶ。
    pub type alias Channel = { joint = Int32, path = Path, times = Vector[Float64], values = Vector[Float64], interpolation = Interpolation }
    /// make が確かめる: times が増える順・values の長さ = times の数 × 幅・joint ≧ 0。Rotation の値は長さ 1 に直す。
    /// joint がスキンの数を超える欄は、make ではなく sample が捨てる（make はスキンを知らない）。
    pub def make(name: String, channels: List[Channel]): Result[String, AnimationClip3d]
    pub def name(c: AnimationClip3d): String
    pub def duration(c: AnimationClip3d): Float64        // 全部の欄の最後のキーフレームの時刻
    /// 時刻 t の局所の姿勢。loop が真なら t を duration で回し（duration が 0 なら 0）、偽なら最後のキーフレームで止める。
    /// 最初のキーフレームより前は最初の値。キーフレームが 1 つの欄はその値のまま。キーフレームの無い欄はレストポーズ。
    /// Linear の rotation は slerp（glTF の決まり）、translation と scale は 2 つの値の間をなめらかにつなぐ。
    pub def sample(skin: Skin3d.Skin3d, clip: AnimationClip3d, t: Float64, loop: Bool): Vector[Skin3d.JointPose]
}

/// 描く時のジョイントの行列（閉じる）。joint 行列 = rootTransform × ジョイントの world 行列 × 逆バインド行列。
pub mod Pose3d {
    pub type alias Pose3d = PoseData
    pub def compute(skin: Skin3d.Skin3d, local: Vector[Skin3d.JointPose]): Pose3d      // 親から順に重ねる（スキンを Pose3d に持たせる）
    pub def jointCount(p: Pose3d): Int32
    pub def blend(a: Vector[Skin3d.JointPose], b: Vector[Skin3d.JointPose], t: Float64): Vector[Skin3d.JointPose]  // t = 0 で a・1 で b
    pub def jointMatrices(p: Pose3d): Vector[Mat4.Mat4]
    /// ジョイントの変換（形の座標。インスタンスの world 行列はまだ掛かっていない）。手に物を持たせる時は world 行列 × これ。
    pub def jointTransform(p: Pose3d, joint: Int32): Mat4.Mat4
}

pub mod Model3d {   // 開いたレコード
    pub type alias Model3d = { mesh = Mesh3d.Mesh3d, skin = Option[Skin3d.Skin3d], clips = Map[String, AnimationClip3d.AnimationClip3d] }
}

pub mod Gltf {
    pub def fromGlb(bytes: Vector[Int8]): Result[String, Model3d.Model3d]
    pub def load(path: String): Result[String, Model3d.Model3d] \ Fs.FileRead      // Fs.FileRead.readBytes
}
```

- `Scene3d.withPose(p, i)` を足し、`instanceFieldsOf` に `pose: Option[Pose3d]` を足す（閉じた型なので外の書いた値は壊れない）。

## 2. 座標の写し方（右手系の glTF → 左手系の engine）

- **X を反転する**（S = diag(−1, 1, 1)）。glTF の正面 +Z は engine でも +Z（yaw 0 の向き）のまま、キャラの右手（Blender の .R・glTF の −X）は engine の +X（東）に来る。
- 位置と法線は x を反転、三角形の巡りは逆にする（表の面は外から時計回りの約束を保つ）。
- 回転の四元数は (x, −y, −z, w) に写す。TRS の倍率はそのまま（対角なので S と入れ替えられる）。逆バインド行列は M' = S·M·S。
- **OBJ の読み込み（`Mesh3d.fromObj`）は反転せずに読む（鏡写し）ので、2 つの読み込みで左右が食い違う**。OBJ は今まで左右対称の家具だけに使ってきた。左右の決まった物は glTF で持ってくる、と docs に書く。

## 3. glTF の読み方（Gltf）

| 所 | 読み方 |
|---|---|
| チャンク | magic `glTF`・version 2・全体の長さを確かめる。JSON（0x4E4F534A。後ろの空白の詰め物は捨てる）と BIN（0x004E4942）。リトルエンディアン。`Vector[Int8]` は `& 0xFF` で符号を外す |
| buffers | uri の無い `buffers[0]` だけが BIN を指す。外の uri と data URI は Err |
| accessor | 位置 = bufferView.byteOffset + accessor.byteOffset。byteStride（無ければ詰めた大きさ）で頂点を飛ぶ。sparse は Err |
| componentType | FLOAT・UNSIGNED_BYTE・UNSIGNED_SHORT・UNSIGNED_INT・BYTE・SHORT。normalized なら仕様の式で 0..1 / −1..1 に直す（WEIGHTS_0 と回転の出力で使う） |
| JOINTS_0 / WEIGHTS_0 | JOINTS_0 は UNSIGNED_BYTE か UNSIGNED_SHORT の VEC4 で、中身は skin.joints の何番目か。JOINTS_1 / WEIGHTS_1 は捨てて 1 回知らせる |
| skins | joints は node の番号。親が子より先になるよう並べ替え、JOINTS_0 の番号も付け替える。inverseBindMatrices が無ければ単位行列（列優先の MAT4） |
| ノードの木 | TRS と `matrix` の両方を読む。ジョイントでない祖先（アーマチュアのノード）の world 行列を `rootTransform` に入れる。skin のあるメッシュのノードの変換は無視する（仕様の MUST） |
| メッシュ | skin のあるメッシュのノードが複数あっても、同じ skin ならつなぐ（違えば Err）。primitive が複数ならつなぐ。mode が 4（三角形）以外は Err。indices が無ければ 0,1,2… |
| ジョイントの子のメッシュ | skin の無いメッシュがジョイントの子なら、そのジョイントに重み 1 で焼き込む（兜など） |
| 色 | primitive の材質の baseColorFactor を頂点の色にする（無ければ白）。baseColorFactor の値をそのまま使う（engine の光は色の値をそのまま掛け、OBJ の Kd も Blender の値をそのまま使うので、そろえる） |
| animations | target.path の translation / rotation / scale を読み、weights は捨てる。target.node がジョイントでない物は捨てて 1 回知らせる。CUBICSPLINE は (入り, 値, 出) の 3 つ組の真ん中を取って Linear にし、1 回知らせる |

## 4. 再生の決まり（World と View の分担）

- **読み込み**: ゲームの Res が起動時と Doc の読み直しで `Gltf.load` を呼び、Model3d を持つ（今の OBJ と同じ置き場）。World は Model3d を持たない。
- **World**: 「どのクリップを何秒目まで」と、ブレンド中なら「前のクリップと、その何秒目か・ブレンドの進み」だけを持つ。
  時刻は遊びの時計（docs/clock.md）で進める（ポーズやヒットストップで止まる）。ブレンド中は前のクリップの時刻も進める。
  1 回きりのクリップが終わったか（`duration` を超えたか）は、World の規則が Res の Model3d の `duration` を見て決める。
- **View**: 毎コマ `sample` →（ブレンド中なら `blend`）→ `Pose3d.compute` → `Scene3d.withPose`。engine は純粋な関数だけを引き受ける。
- ブレンドの秒・近づく距離などの調整する値は、ゲームの Doc に出す。

## 5. GL（render_gl/src/Render3d.flix）

- ジョイントの番号と重みは、今の頂点バッファ（stride 36 の交互の並び）とは別の VBO に入れる（ジョイントの無いメッシュは今のまま）。番号は `glVertexAttribIPointer` の整数。
- ジョイントの行列は UBO（std140・64 × mat4 = 4096 バイト）で渡す（`uJoints[64]` の uniform は GL 3.3 が約束する頂点の uniform の数 1024 を、uModel などと合わせると超えるため）。
- 骨つきの版が要るのは lit・depth（シャドウマップと共用）・材質（spec ごと）。材質のプログラムのキャッシュの鍵に、ジョイントの有無を足す（`materialKey`）。
- 頂点シェーダー: `skin = Σ w_i × uJoints[j_i]`、位置と法線を skin で曲げてから `uModel` を掛ける。

## 6. CPU（engine_tools/src/SoftRaster3d.flix）

- `instanceTris` で、頂点の位置と法線を同じ式で曲げてから写す。シャドウマップもこの道を通るので、曲がった形で落ちる。

## 7. DrawHash

- `putInstance` はレコードの欄を全部書いて照合しているので、pose の欄を足すとコンパイルが止まる。ここに joint 行列（16 個 × ジョイントの数）を足す。

## 8. 試作と資材

- **engine のテストの資材**:
  - (a) テストの中に小さな GLB を組み立てる関数を置き、byteStride・normalized・UNSIGNED_SHORT・CUBICSPLINE・途中で切れたバイトを決まった形で作る。
  - (b) Blender で書き出した数 KB の .glb（ジョイント 2 本・三角 2 枚・クリップ 1 つ）を `engine/test/data/` に置いて git に入れる。横に、作った .py と Blender の版を書いた README を置く。
- **fps3d_lab**: `modeling/character.py` で番兵（ジョイント 14 本・idle 2 秒・salute 1.2 秒・walk 1 秒）を書き出してある（`assets/models/guard.glb`）。
  部屋に番兵を 1 体立て、普段は idle。目が近く（Doc の距離）で Enter を押すと salute へブレンドし、終わったら idle へ戻す。動画の手順にこの場面を足す。

## 9. 合格条件

| どこ | 確かめること |
|---|---|
| engine | Quat: slerp(a, b, 0) = a・(…, 1) = b・反対の向きでも短い側を通る |
| engine | Mat4.inverse: m × inverse(m) = 単位行列・ofColumns の長さが 16 でなければ Err |
| engine | AnimationClip3d.sample: キーフレームの時刻ちょうど・2 つの真ん中・loop の回し方・止め方・最初より前・キーフレーム 1 つ・duration 0 |
| engine | Pose3d: レストポーズの joint 行列は単位行列・親を回すと子の world も回る・blend の 0 と 1 |
| engine | Gltf（組み立てた GLB）: byteStride・normalized の重み・UNSIGNED_SHORT の JOINTS・CUBICSPLINE の真ん中・切れたバイトは Err・mode 4 以外は Err・外の uri は Err |
| engine | Gltf（Blender の .glb）: ジョイントの数・クリップの名前と長さ・頂点の数 |
| engine | 座標: glTF の −X の頂点が engine の +X・表の面が表のまま・two_joints.glb の `side.R`（Blender の −X に置いたジョイント）の変換の x が正（右が右） |
| fps3d_lab | 番兵の salute の途中で `hand.R` のジョイントの x が正（右手が右） |
| engine_tools | ジョイントを 90 度回すと、重み 1 の頂点の画素が動く・シャドウマップも動く |
| gl_parity | 骨つきの板の場面が GL と CPU で一致 |

合格:
- テンプレート 4 本と段 A〜C の絵が変わらない（ジョイントを使わない物は 1 画素も変わらない）
- bench/scene3d に番兵を 4 体足した 1 コマ p50 が、足す前の値 + 0.5 ms 以内（今の値を作業の前に測って記録する）
- fps3d_lab の部屋で、番兵に近づいて Enter で敬礼する動画
- 新しい API の手続き: `agents-pack/AGENTS.core.md` の早見表に 1 行・`agents-pack/agent-eval/engine.json` にお題 1 本（`make agent-eval ONLY=` は回せる時に）・`make api-digest`

## 10. レビュー（62 点）への対応

| 指摘 | 対応した所 |
|---|---|
| 1 作る口 | §1（Mesh3d.fromArrays・Skin3d.make・AnimationClip3d.make・Mat4.ofColumns / inverse。contentHash に法線と重み） |
| 2 glTF の読み方 | §3 の表 |
| 3 座標 | §2（X の反転・四元数 (x, −y, −z, w)・OBJ との違い） |
| 4 GL | §5（UBO・別の VBO・プログラムの組・64 本は読み込みで Err） |
| 5 資材 | §8・§9（組み立てた GLB と Blender の .glb・右手のテスト・重さは差で） |
| 6 World と View | §4（Res が読む・遊びの時計・ブレンド中の前の時刻・Doc） |
| 7 名前 | 用語の行・AnimationClip3d・Pose3d.compute |
| 8 鍵 | §7 |

## 11. 再レビュー（84 点）への対応（改訂 3）

1. **ジョイントの数が合わない時**: `Scene3d.skinningOf(instance): Option[Pose3d]` を GL と CPU の共用の関数として置く。
   - pose が None → バインドポーズ（曲げずに描く）
   - 骨の無いメッシュ → pose を無視
   - メッシュのジョイントの番号の最大 ≧ Pose のジョイントの数 → バインドポーズで描いて 1 回知らせる
2. **inverseBindMatrices**: §1 に書き分けた（Gltf は Some(単位行列)・None は手で組む口）。
3. **右手のテスト**: two_joints.py に `side.R`（Blender の −X に置いたジョイント）を足し、engine のテストで確かめる。番兵の右手は fps3d_lab のテストへ（§9）。
4. **Skin3d / Gltf の漏れ**:
   - 根のジョイントが複数あり、それぞれ別のジョイントでない祖先を持つ時は Err
   - ジョイントの間にジョイントでないノードが挟まる時も Err
   - S·M·S の写し方は、逆バインド行列・`matrix` のノード・`rootTransform` の全部に掛ける
   - 並べ替えた後は、JOINTS_0・逆バインド行列の並び・アニメーションの target.node → 番号の対応を全部付け替える
   - ジョイントの子のメッシュは、バインドの時のそのジョイントの world 行列（= 逆バインド行列の逆）× ノードの局所の鎖で、スキンのバインドの空間へ写してから重み 1 で焼き込む
   - skin の無い glb は、メッシュのノードの world 行列を頂点に焼き込む。ジョイントの下にも無く skin も無いメッシュのノードは、同じく world 行列を焼き込んでつなぐ
5. **Channel の型**: §1 に書いた。
6. **jointTransform**: §1 に書いた（Mat4・形の座標・スキンは compute で Pose3d に持たせる）。
7. **API の手続き**: §9 の合格に入れた。
8. **小さい物**:
   - View: View は Res を引数で受け取る（fps3d_lab の View.inputOf(res, w) は今もそうしている）。
   - 法線の曲げ: skin の左上 3×3 で法線を曲げるので、ジョイントの倍率が軸ごとに違うと少しずれる。GL と CPU は同じ式なので一致する。この差は許し、WhyNot に書く。
   - §5 の「1024」は頂点の uniform の成分の数。
