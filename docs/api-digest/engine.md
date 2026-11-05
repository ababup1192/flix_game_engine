<!-- engine v0.87.0 / 生成: 2026-11-06 -->
<!-- 生成物: bin/fge api-digest が作る。手で編集しない（make api-digest で作り直す） -->

# API ダイジェスト — engine

`engine/src` 配下の `pub def` / `pub enum` / `pub type alias` の一覧。索引は [api-digest.md](../api-digest.md)。

## Anchor — `engine/src/core/Anchor.flix`
- 文字列から Anchor を parse する。scene.json の `"anchor": "FullRect"` 等のパース用。
  `pub def fromString(s: String): Option[Anchor]`
- anchor preset と親 rect (+ 子の natural size + margin) から子の rect を計算する。
  `pub def applyAnchor(anchor: Anchor, parentRect: Rect2.Rect2, childSize: Vec2.Vec2, margin: Float64): Rect2.Rect2`

## AnimationClip3d — `engine/src/scene3d/AnimationClip3d.flix`
- キーフレームの間のつなぎ方。Linear = 2 つの値の間をなめらかにつなぐ（回転は球面の上で）・Step = 次のキーフレームまで前の値のまま。
  `pub enum Interpolation with Eq { case Linear case Step }`
- どの欄を動かすか。値の幅は Translation・Scale が 3、Rotation が 4（x, y, z, w）。
  `pub enum Path with Eq { case Translation case Rotation case Scale }`
- 1 本の欄。joint = スキンの中の番号・times = キーフレームの秒（増える順）・values = 時刻ごとに幅の数だけ並べた値。
  `pub type alias Channel = { joint = Int32, path = Path, times = Vector[Float64], values = Vector[Float64], interpolation = Interpolation }`
- `pub type alias AnimationClip3d = ClipData`
- 欄の列から作る。times が増える順でない・values の数が times の数 × 幅でない・joint が負の欄は Err。
  `pub def make(name: String, channels: List[Channel]): Result[String, AnimationClip3d]`
- `pub def name(c: AnimationClip3d): String`
- 全部の欄の最後のキーフレームの時刻（欄が無ければ 0）。
  `pub def duration(c: AnimationClip3d): Float64`
- 時刻 t（秒）の局所の姿勢（ジョイントの数だけ）。loop が真なら t を duration で回し（duration が 0 なら 0）、偽なら最後のキーフレームで止める。
  `pub def sample(skin: Skin3d.Skin3d, clip: AnimationClip3d, t: Float64, loop: Bool): Vector[Skin3d.JointPose]`

## Arc — `engine/src/render2d/Arc.flix`
- 全周 = 2π（ラジアン）。全周リングの endAngle 既定や、比率→角度の換算に使う。
  `pub def tau(): Float64`
- 半径・太さ・開始/終了角を指定して円弧を生成する（alpha=1.0 不透明、segments 既定）。
  `pub def make(radius: Float64, width: Float64, startAngle: Float64, endAngle: Float64, color: Color): Arc`
- 全周リング（startAngle=0, endAngle=2π）を生成するショートカット。背景の輪などに使う。
  `pub def ring(radius: Float64, width: Float64, color: Color): Arc`
- 埋め込んだ Transform 部品を取り出す
  `pub def transform(arc: Arc): Transform`
- Transform 部品に関数を適用して差し替える
  `pub def mapTransform(f: Transform -> Transform \ ef, arc: Arc): Arc \ ef`
- 埋め込んだ Visual 部品を取り出す
  `pub def visual(arc: Arc): Visual`
- Visual 部品に関数を適用して差し替える
  `pub def mapVisual(f: Visual -> Visual \ ef, arc: Arc): Arc \ ef`
- `pub def getRadius(arc: Arc): Float64`
- `pub def setRadius(radius: Float64, arc: Arc): Arc`
- `pub def getWidth(arc: Arc): Float64`
- `pub def setWidth(width: Float64, arc: Arc): Arc`
- `pub def getEndAngle(arc: Arc): Float64`
- 円弧の終了角を更新する。クールダウンは `setEndAngle(start + 2π*ratio)` を毎フレーム呼ぶ。
  `pub def setEndAngle(endAngle: Float64, arc: Arc): Arc`
- `pub def getSegments(arc: Arc): Int32`
- 分割数を設定する。1 未満は 1 にクランプ（state と描画を一致させる）。
  `pub def setSegments(segments: Int32, arc: Arc): Arc`
- `pub def getAlpha(arc: Arc): Float64`
- `pub def setAlpha(alpha: Float64, arc: Arc): Arc`
- スクリーン px の塗り潰しコマンド列に変換する。`screenPos` は描画原点
  `pub def toRenderCmds(screenPos: Vec2.Vec2, scaleVec: Vec2.Vec2, arc: Arc): List[GameEngine.PolygonRenderCmd]`

## AudioStreamPlayer — `engine/src/render2d/AudioStreamPlayer.flix`
- デフォルト値で AudioStreamPlayer を生成する
  `pub def make(stream: String): AudioStreamPlayer`
- 指定した名前のオーディオを再生する（先頭から再生し直す）
  `pub def play(name: String): Unit \ GameEngine.Audio`
- 指定した名前のオーディオを停止する
  `pub def stop(name: String): Unit \ GameEngine.Audio`
- 指定した名前のオーディオの音量（gain）を 0.0〜1.0 で設定する。
  `pub def setVolume(name: String, volume: Float64): Unit \ GameEngine.Audio`
- 指定した名前のオーディオの高さ（再生速度）を変える。1.0 = 元のまま・
  `pub def setPitch(name: String, pitch: Float64): Unit \ GameEngine.Audio`
- 指定した名前のオーディオの loop フラグ (AL_LOOPING) を実行時に切り替える。
  `pub def setLooping(name: String, loop: Bool): Unit \ GameEngine.Audio`
- enum が保持する設定を一括反映する。volume → looping → (autoplay なら play) を順に適用する。
  `pub def applyAttach(player: AudioStreamPlayer): Unit \ GameEngine.Audio`

## AudioUtil — `engine/src/core/AudioUtil.flix`
- `pub def alFormatMono8(): Int32`
- `pub def alFormatMono16(): Int32`
- `pub def alFormatStereo8(): Int32`
- `pub def alFormatStereo16(): Int32`
- チャンネル数（1=モノラル/2=ステレオ）とビット数から、再生に使う音声形式を選ぶ。
  `pub def alFormat(channels: Int32, bitsPerSample: Int32): Int32`
- Find the byte offset of the "data" chunk in WAV byte data.
  `pub def findDataChunkOffset(getByte: Int32 -> Int8 \ ef, getInt32LE: Int32 -> Int32 \ ef, limit: Int32, offset: Int32): Option[Int32] \ ef`
- WAV の中の名前 a b c d（4 文字の ASCII。"smpl" なら 115 109 112 108）のチャンクの位置を探す。
  `pub def findChunkOffset(a: Int8, b: Int8, c: Int8, d: Int8, getByte: Int32 -> Int8 \ ef, getInt32LE: Int32 -> Int32 \ ef, limit: Int32, offset: Int32): Option[Int32] \ ef`
- WAV の形式（"fmt " チャンク）: (チャンネル数, サンプルレート, 1 サンプルのビット数)。
  `pub def formatOf(getByte: Int32 -> Int8 \ ef, getInt32LE: Int32 -> Int32 \ ef, limit: Int32): Option[(Int32, Int32, Int32)] \ ef`
- data の長さ（バイト）から、サンプルの組の数（1 組 = 全チャンネルの 1 サンプルずつ）を数える。
  `pub def framesOf(dataSize: Int32, channels: Int32, bitsPerSample: Int32): Int32`
- WAV のループ点（"smpl" チャンクの最初のループ）。返すのは (頭, 終わり) のサンプル番号で、
  `pub def loopPointsOf(getByte: Int32 -> Int8 \ ef, getInt32LE: Int32 -> Int32 \ ef, limit: Int32): Option[(Int32, Int32)] \ ef`

## BootFont — `engine/src/render2d/BootFont.flix`
- フォントの登録名。ゲームが project.json で付ける名前と衝突しない綴りにしてある。
  `pub def name(): String`
- テクスチャ名は "font_" で始めない。始めると描画側が SDF 距離場として塗ってしまうが、
  `pub def textureName(): String`
- `pub def logoTextureName(): String`
- ロゴの一辺（px）。
  `pub def logoSide(): Int32`
- この大きさで字を出すとドットが 1:1 で揃う。拡大するなら整数倍にする
  `pub def fontSize(): Float64`
- Text.make / Text.measure がそのまま使えるフォントアトラス。
  `pub def atlas(): FontAtlas`
- フォントアトラスの画素（ARGB・行優先）。字は白、地は透明。
  `pub def pixelsArgb(): Vector[Int32]`
- ロゴの画素（ARGB・行優先）。色票の番号を 4bit で 1 画素持っている。
  `pub def logoArgb(): Vector[Int32]`

## BootFontData — `engine/src/render2d/BootFontData.flix`
- 素材の出どころ（ライセンス表記のため実行時にも名乗れるようにしてある）。
  `pub def source(): String`
- アトラスの一辺。Text の表示サイズ計算がアトラスを正方と決め打つので正方。
  `pub def side(): Int32`
- 生成ピクセル高さ。この大きさで出すとドットが 1:1 で揃う。
  `pub def fontSize(): Float64`
- `pub def ascent(): Float64`
- `pub def descent(): Float64`
- `pub def lineGap(): Float64`
- 字の高さ（アトラス上の 1 マスの縦）。
  `pub def cellH(): Int32`
- 1 字 14 桁: 文字番号(4) 左(3) 上(3) 幅(2) 送り幅(2)。すべて 16 進。
  `pub def glyphsHex(): String`
- アトラスの 1bit 画素。行優先・上位ビットが左・16 進 2 桁 = 1 バイト。
  `pub def bitsHex(): List[String]`
- ロゴの一辺。
  `pub def logoSide(): Int32`
- ロゴの色票。1 色 8 桁 rrggbbaa。先頭は透明。
  `pub def logoPaletteHex(): String`
- ロゴの画素。色票の番号を 4bit で 1 画素、上位が左。
  `pub def logoHex(): List[String]`

## Camera — `engine/src/render2d/drawable/Camera.flix`
- 指定位置を画面中央に映すカメラを作る（zoom = (1, 1) 等倍）。
  `pub def make(position: Vec2.Vec2): Camera`
- 埋め込んだ Transform 部品を取り出す
  `pub def transform(camera: Camera): Transform`
- Transform 部品に関数を適用して差し替える
  `pub def mapTransform(f: Transform -> Transform \ ef, camera: Camera): Camera \ ef`
- ズーム倍率を取得する
  `pub def getZoom(camera: Camera): Vec2.Vec2`
- ズーム倍率を設定する
  `pub def setZoom(zoom: Vec2.Vec2, camera: Camera): Camera`
- カメラから ViewTransform（world → screen 変換）を作る。
  `pub def getViewTransform(camera: Camera, center: Vec2.Vec2, viewport: {viewportWidth = Float64, viewportHeight = Float64}): Projection.ViewTransform`

## Camera3d — `engine/src/scene3d/Camera3d.flix`
- eye = 目の位置・yaw / pitch = 向き（ラジアン。座標の約束はファイルの頭）・fovY = 縦の画角（ラジアン）・near / far = 写す奥行きの範囲。
  `pub type alias Camera3d = { eye = Vec3.Vec3, yaw = Float64, pitch = Float64, fovY = Float64, near = Float64, far = Float64 }`
- 見ている向き（長さ 1）。
  `pub def forward(c: Camera3d): Vec3.Vec3`
- 画面の右の向き（長さ 1）。
  `pub def right(c: Camera3d): Vec3.Vec3`
- 画面の上の向き（長さ 1）。
  `pub def up(c: Camera3d): Vec3.Vec3`
- world → GL の目の座標（右手系・−Z を見る）。左手系の前の向きを −Z へ写すので Z が反転する。
  `pub def viewMatrix(c: Camera3d): Mat4.Mat4`
- GL の透視の行列（右手系の目の座標 → clip。奥行きは near で −1・far で +1）。aspect = 幅 / 高さ。
  `pub def projectionMatrix(c: Camera3d, aspect: Float64): Mat4.Mat4`
- このカメラに写る範囲（視錐台）。aspect = 幅 / 高さ。光や羽虫をゲームの側で間引く・数える時に使う
  `pub def frustum(c: Camera3d, aspect: Float64): Frustum.Frustum`
- 目から見ている向きへ伸びるレイ（画面の真ん中・クロスヘアの先）。`Ray3d.pickNearest` で見ている物を引く。
  `pub def forwardRay(c: Camera3d): Ray3d.Ray3d`
- 描き物の中の点 p（左上が 0・y は下へ増える px。size = 描き物の大きさ）を通って目から伸びるレイ（worldToScreen の逆）。
  `pub def screenPointToRay(c: Camera3d, size: Vec2.Vec2, p: Vec2.Vec2): Ray3d.Ray3d`
- 3D の点が描き物の中のどこに写るか（左上が 0・y は下へ増える px）。near より手前と目の後ろは None。
  `pub def worldToScreen(c: Camera3d, size: Vec2.Vec2, p: Vec3.Vec3): Option[Vec2.Vec2]`

## CanvasLayer — `engine/src/render2d/CanvasLayer.flix`
- レイヤー間の z-index ストライド。
  `pub def layerStride(): Int32`

## CollisionShape2D — `engine/src/physics2d/CollisionShape2D.flix`
- 2 つの形状が重なっているか判定する。
  `pub def checkOverlap(posA: Vec2.Vec2, shapeA: CollisionShape2D, posB: Vec2.Vec2, shapeB: CollisionShape2D): Bool`
- AABB 矩形同士の重なり判定。
  `pub def checkRectRect(posA: Vec2.Vec2, sizeA: Vec2.Vec2, posB: Vec2.Vec2, sizeB: Vec2.Vec2): Bool`
- 円同士の重なり判定。
  `pub def checkCircleCircle(posA: Vec2.Vec2, radiusA: Float64, posB: Vec2.Vec2, radiusB: Float64): Bool`
- 円と矩形の重なり判定。
  `pub def checkCircleRect(circlePos: Vec2.Vec2, radius: Float64, rectPos: Vec2.Vec2, rectSize: Vec2.Vec2): Bool`
- カプセルの軸線分の両端点を返す。
  `pub def capsuleSegment(pos: Vec2.Vec2, radius: Float64, height: Float64, vertical: Bool): (Vec2.Vec2, Vec2.Vec2)`
- 点から線分への最短距離の二乗を返す。
  `pub def pointToSegmentDistSq(point: Vec2.Vec2, segA: Vec2.Vec2, segB: Vec2.Vec2): Float64`
- 二つの線分間の最短距離の二乗を返す。
  `pub def segmentToSegmentDistSq(a1: Vec2.Vec2, a2: Vec2.Vec2, b1: Vec2.Vec2, b2: Vec2.Vec2): Float64`
- カプセルと円の重なり判定。
  `pub def checkCapsuleCircle(capsulePos: Vec2.Vec2, capsuleRadius: Float64, capsuleHeight: Float64, capsuleVertical: Bool, circlePos: Vec2.Vec2, circleRadius: Float64): Bool`
- カプセルと矩形の重なり判定。
  `pub def checkCapsuleRect(capsulePos: Vec2.Vec2, capsuleRadius: Float64, capsuleHeight: Float64, capsuleVertical: Bool, rectPos: Vec2.Vec2, rectSize: Vec2.Vec2): Bool`
- カプセル同士の重なり判定。
  `pub def checkCapsuleCapsule(posA: Vec2.Vec2, radiusA: Float64, heightA: Float64, verticalA: Bool, posB: Vec2.Vec2, radiusB: Float64, heightB: Float64, verticalB: Bool): Bool`
- 坂の 3 頂点を返す（pos は外接箱の中心・y は下向き正）。
  `pub def slopeVertices(pos: Vec2.Vec2, size: Vec2.Vec2, riseRight: Bool): (Vec2.Vec2, Vec2.Vec2, Vec2.Vec2)`
- 線分上で点 p に最も近い点を返す。
  `pub def closestPointOnSegment(p: Vec2.Vec2, segA: Vec2.Vec2, segB: Vec2.Vec2): Vec2.Vec2`
- 円と坂の重なり判定。
  `pub def checkCircleSlope(circlePos: Vec2.Vec2, radius: Float64, slopePos: Vec2.Vec2, slopeSize: Vec2.Vec2, riseRight: Bool): Bool`
- カプセルと坂の重なり判定。
  `pub def checkCapsuleSlope(capsulePos: Vec2.Vec2, radius: Float64, height: Float64, vertical: Bool, slopePos: Vec2.Vec2, slopeSize: Vec2.Vec2, riseRight: Bool): Bool`
- 2 つの形状の重なりを解消する変位ベクトルを返す。
  `pub def resolveOverlap(posA: Vec2.Vec2, shapeA: CollisionShape2D, posB: Vec2.Vec2, shapeB: CollisionShape2D): Option[Vec2.Vec2]`
- AABB 矩形同士の MTV。重なる軸のうち侵入量が小さい方向に押し出す。
  `pub def resolveRectRect(posA: Vec2.Vec2, sizeA: Vec2.Vec2, posB: Vec2.Vec2, sizeB: Vec2.Vec2): Option[Vec2.Vec2]`
- 円同士の MTV。中心間ベクトル方向に sumR - distance だけ押し出す。
  `pub def resolveCircleCircle(posA: Vec2.Vec2, radiusA: Float64, posB: Vec2.Vec2, radiusB: Float64): Option[Vec2.Vec2]`
- 円と矩形の MTV。
  `pub def resolveCircleRect(circlePos: Vec2.Vec2, radius: Float64, rectPos: Vec2.Vec2, rectSize: Vec2.Vec2): Option[Vec2.Vec2]`
- カプセルと円の MTV。カプセルを円から離す変位を返す。
  `pub def resolveCapsuleCircle(capsulePos: Vec2.Vec2, capsuleRadius: Float64, capsuleHeight: Float64, capsuleVertical: Bool, circlePos: Vec2.Vec2, circleRadius: Float64): Option[Vec2.Vec2]`
- カプセルと矩形の MTV。カプセルを矩形から離す変位を返す。
  `pub def resolveCapsuleRect(capsulePos: Vec2.Vec2, radius: Float64, height: Float64, vertical: Bool, rectPos: Vec2.Vec2, rectSize: Vec2.Vec2): Option[Vec2.Vec2]`
- カプセル同士の MTV。A を B から離す変位を返す。
  `pub def resolveCapsuleCapsule(posA: Vec2.Vec2, radiusA: Float64, heightA: Float64, verticalA: Bool, posB: Vec2.Vec2, radiusB: Float64, heightB: Float64, verticalB: Bool): Option[Vec2.Vec2]`
- カプセルと坂の MTV。カプセルを坂から離す変位を返す。
  `pub def resolveCapsuleSlope(capsulePos: Vec2.Vec2, radius: Float64, height: Float64, vertical: Bool, slopePos: Vec2.Vec2, slopeSize: Vec2.Vec2, riseRight: Bool): Option[Vec2.Vec2]`
- 円と坂の MTV。円を坂から離す変位を返す。
  `pub def resolveCircleSlope(circlePos: Vec2.Vec2, radius: Float64, slopePos: Vec2.Vec2, slopeSize: Vec2.Vec2, riseRight: Bool): Option[Vec2.Vec2]`
- 点が多角形の内部にあるか。交差数の偶奇で判定するので凹んだ形でも正しい。
  `pub def pointInPolygon(p: Vec2.Vec2, polyPos: Vec2.Vec2, points: List[Vec2.Vec2]): Bool`
- ローカル頂点列の外接箱。外接箱近似のペアと事前の足切りに使う。
  `pub def polygonBounds(points: List[Vec2.Vec2]): Rect2.Rect2`
- 円と多角形の重なり判定（checkCircleSlope の n 辺版）。
  `pub def checkCirclePolygon(circlePos: Vec2.Vec2, radius: Float64, polyPos: Vec2.Vec2, points: List[Vec2.Vec2]): Bool`
- カプセルと多角形の重なり判定（checkCapsuleSlope の n 辺版）。
  `pub def checkCapsulePolygon(capsulePos: Vec2.Vec2, radius: Float64, height: Float64, vertical: Bool, polyPos: Vec2.Vec2, points: List[Vec2.Vec2]): Bool`
- 円と多角形の MTV。円を多角形から離す変位を返す。
  `pub def resolveCirclePolygon(circlePos: Vec2.Vec2, radius: Float64, polyPos: Vec2.Vec2, points: List[Vec2.Vec2]): Option[Vec2.Vec2]`
- カプセルと多角形の MTV。カプセルを多角形から離す変位を返す。
  `pub def resolveCapsulePolygon(capsulePos: Vec2.Vec2, radius: Float64, height: Float64, vertical: Bool, polyPos: Vec2.Vec2, points: List[Vec2.Vec2]): Option[Vec2.Vec2]`
- 頂点列が多角形として成立するか検証する。壊れていれば平易な日本語の理由を返す。
  `pub def validatePolygonPoints(points: List[Vec2.Vec2]): Result[String, Unit]`

## CollisionShape3d — `engine/src/scene3d/CollisionShape3d.flix`
- 向きのある箱。center = 真ん中・ax / ay / az = 3 本の向き（長さ 1・互いに直角）・half = 各向きの半分の長さ（0 以上）。
  `pub type alias Box3d = { center = Vec3.Vec3, ax = Vec3.Vec3, ay = Vec3.Vec3, az = Vec3.Vec3, half = Vec3.Vec3 }`
- 球。center = 真ん中・radius = 半径。
  `pub type alias Sphere3d = { center = Vec3.Vec3, radius = Float64 }`
- 縦に立てたカプセル。feet = 下の端の点・radius = 半径・height = 全体の高さ（両端の半球を含む。2 × radius より低い時は球 1 つ）。
  `pub type alias Capsule3d = { feet = Vec3.Vec3, radius = Float64, height = Float64 }`
- 軸にそろった箱（真ん中 center・各向きの半分の長さ half。負の値は正に直す）。
  `pub def box3d(center: Vec3.Vec3, half: Vec3.Vec3): Box3d`
- 形の座標の箱 bounds を world で写した向きのある箱。軸ごとの倍率は half に入れる。
  `pub def boxOfBounds(world: Mat4.Mat4, bounds: Mesh3d.Bounds): Box3d`
- glTF のノード 1 つの当たり判定の箱（node#localBounds を node#world で写す）。
  `pub def boxOfNode(node: Model3d.ModelNode): Option[Box3d]`
- ノードの列の箱（mesh の無いノードは飛ばす・並びはノードの順）。
  `pub def boxesOfNodes(nodes: List[Model3d.ModelNode]): List[Box3d]`
- 形 mesh（形の座標）の軸にそろった境界を world で写した箱。頂点の無い形と NaN・無限大は None。
  `pub def boxOfMesh(mesh: Mesh3d.Mesh3d, world: Mat4.Mat4): Option[Box3d]`
- 箱 b を行列 m で写した箱（蝶番のまわりに回す扉の板）。倍率とせん断の扱いは boxOfBounds と同じ。
  `pub def transformBox(m: Mat4.Mat4, b: Box3d): Box3d`
- 箱の全部の数が有限か。
  `pub def isFinite(b: Box3d): Bool`
- 箱の 8 つの角（world）。
  `pub def cornersOfBox(b: Box3d): List[Vec3.Vec3]`
- 箱 b の中で点 p に一番近い点（p が中なら p）。
  `pub def closestPoint(b: Box3d, p: Vec3.Vec3): Vec3.Vec3`
- 球（真ん中 center・半径 radius）が箱 b に食い込んでいる深さ（m。食い込んでいなければ 0）。
  `pub def sphereDepth(b: Box3d, center: Vec3.Vec3, radius: Float64): Float64`
- カプセルを近似する球の真ん中（下から上へ）。間は radius 以下で、両端は半球の真ん中。
  `pub def sphereCentersOf(c: Capsule3d): List[Vec3.Vec3]`
- カプセル capsule が箱 b に食い込んでいる深さ（m。0 なら触れていない）。
  `pub def penetration(b: Box3d, capsule: Capsule3d): Float64`
- 球（真ん中 center・半径 radius）を箱 b の外へ出す水平のずれ（y は 0）。重なっていなければ None。
  `pub def pushOutHorizontal(b: Box3d, center: Vec3.Vec3, radius: Float64): Option[Vec3.Vec3]`
- 箱の列の 12 本の辺を細い角柱にした線の形（場面に重ねても中が見える）。`Scene3d.meshInstance(m, Mat4.identity())` で置く。
  `pub def debugMesh(boxes: List[Box3d], color: Color): Mesh3d.Mesh3d`

## CollisionWorld3d — `engine/src/scene3d/CollisionWorld3d.flix`
- `pub type alias CollisionWorld3d = WorldData`
- cellSize が 0 以下・NaN・無限大の時に使う 1 マスの幅（m）。
  `pub def defaultCellSize(): Float64`
- 箱の無い集まり（扉など動く箱だけで歩かせる時）。
  `pub def empty(): CollisionWorld3d`
- 箱の列を xz の格子（1 マスの幅 cellSize m）に入れた集まり。並びはそのまま保つ（押し出しは並びの順に足すので答えが並びで決まる）。
  `pub def build(cellSize: Float64, boxes: List[CollisionShape3d.Box3d]): CollisionWorld3d`
- 集まりの全部の箱（build の並び）。
  `pub def boxes(w: CollisionWorld3d): List[CollisionShape3d.Box3d]`
- 点 point（y は使わない）から水平に reach m の四角の範囲に、水平の広がりが掛かる箱（build の並びの順・重複なし）。
  `pub def boxesNear(w: CollisionWorld3d, point: Vec3.Vec3, reach: Float64): List[CollisionShape3d.Box3d]`

## Color — `engine/src/core/Color.flix`
- 0〜1 の 3 つ組から色を作る。
  `pub def rgb(r: Float64, g: Float64, b: Float64): Color`
- 0〜255 の 3 つ組から色を作る。色見本（パレット表）は 255 段階で配られるので、
  `pub def rgb8(r: Int32, g: Int32, b: Int32): Color`
- "#rrggbb"（先頭の # は省略可）から色を作る。6 桁の 16 進でなければ None。
  `pub def hex(text: String): Option[Color]`
- 色を "#rrggbb" の文字列にする（hex の逆）。0〜1 の外へ出た値は端で止め、
  `pub def toHex(color: Color): String`
- 2 色の間を t（0〜1）で混ぜる。lighten（白へ）/ darken（黒へ）が「片方が決め打ち」
  `pub def mix(a: Color, b: Color, t: Float64): Color`
- 3 チャンネルを組にして取り出す。Color は record なので **そのままでは比べられない**
  `pub def channels(color: Color): (Float64, Float64, Float64)`
- 色を白へamountだけ近づける。通常は0から1を渡し、範囲外は補正しない。
  `pub def lighten(color: Color, amount: Float64): Color`
- 色を黒へamountだけ近づける。通常は0から1を渡し、範囲外は補正しない。
  `pub def darken(color: Color, amount: Float64): Color`
- 暖色（黄寄り）へ amount だけ近づける。lighten と対で使う。
  `pub def warm(color: Color, amount: Float64): Color`
- 寒色（青寄り）へ amount だけ近づける（warm の対）。影の側に使う。
  `pub def cool(color: Color, amount: Float64): Color`
- 目に映る明るさ（0〜1）。3 チャンネルの平均で採らないのは、人の目が緑にいちばん
  `pub def brightness(color: Color): Float64`
- HSV から色を作る。h は色相（1 周 = 1.0・0 = 赤・範囲外は折り返し）、s は鮮やかさ、
  `pub def hsv(spec: {h = Float64, s = Float64, v = Float64}): Color`

## ContentCache — `engine/src/core/ContentCache.flix`
- キャッシュの置き場。外からは fresh で作り、loadOrBuild に渡すだけ。
  `pub type alias Cache[a] = CacheData[a]`
- 空の置き場を作る。
  `pub def fresh(): Cache[a] \ IO`
- `pub def loadOrBuild(cache: Cache[a], params: String, extraFiles: List[String], build: Unit -> a \ ef): a \ (ef - Fs.FileRead) + Fs.FileRead + IO`
- loadOrBuild に加えて、build の中の Fs.FileTest（exists 系）と Fs.DirList（一覧）も記録する。
  `pub def loadOrBuildWithDirs(cache: Cache[a], params: String, extraFiles: List[String], build: Unit -> a \ ef): a \ (ef - Fs.FileRead - Fs.FileTest - Fs.DirList) + Fs.FileRead + Fs.FileTest + Fs.DirList + IO`

## Display — `engine/src/platform/Display.flix`
- 端末の区分。Ren'Py の screen variant（small / medium / large）に合わせた 3 つ
  `pub enum SizeClass with Eq, Order, ToString { case Small case Medium case Large }`
- pointer の種類（ブラウザの PointerEvent.pointerType と同じ分け方。ペンは Mouse に入れる）。
  `pub enum PointerKind with Eq, ToString { case Mouse case Touch }`
- `pub enum Orientation with Eq, ToString { case Landscape case Portrait }`
- design の大きさの形から向きを決める（高さが幅より大きい時だけ Portrait）。
  `pub def orientationOf(design: Vec2.Vec2): Orientation`
- size = 描き先（ウィンドウ・canvas）の大きさ（論理 px。ブラウザは CSS px・mac は point）。
  `pub type alias Display = { size = Vec2.Vec2, scaleFactor = Float64, designScale = Float64, pointer = PointerKind, sizeClass = SizeClass, orientation = Orientation }`
- 窓の無い所（ヘッドレスの描き出し・当たりを取る View の木・テスト）とデスクトップ版の既定:
  `pub def desktop(design: Vec2.Vec2): Display`
- 縦に持ったスマホの画面の大きさ（CSS px）の既定。デスクトップで縦を確かめる起動（FLIX_GE_PORTRAIT=1）と、
  `pub def defaultPortraitView(): Vec2.Vec2`
- 窓の無い所で「縦に持ったスマホ」を表す既定（縦の画面の描き出し・テスト）: Small・Touch・大きさは view（CSS px）・
  `pub def phonePortrait(view: Vec2.Vec2, design: Vec2.Vec2): Display`
- 区分の決め方。主な pointer が指でなければ Large。指なら、画面の短い辺（論理 px）が 600 未満で Small・それ以上で Medium
  `pub def sizeClassOf(coarsePointer: Bool, shortSide: Float64): SizeClass`

## DrawCmd — `engine/src/core/DrawCmd.flix`
- ピクセルの重ね方（ブレンドモード）。
  `pub enum BlendMode with Eq, Order, ToString { case Normal case Add case Multiply }`
- 角丸＋枠線スタイル。`Drawable.style = Some(..)` かつ texture="" のとき、
  `pub enum BoxStyle with Eq, ToString { case BoxStyle( Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Int32, Float64, Float64, Float64, Float64, Float64 ) }`
- BoxStyle の全フィールドを名前で持つレコード（`makeStyle` の入力・`styleToSpec` の出力）。
  `pub type alias BoxStyleSpec = { cornerRadius = Float64, borderWidth = Float64, borderColor = Color, borderAlpha = Float64, stripeColor = Color, stripeAlpha = Float64, stripeWidth = Float64, stripePeriod = Float64, stripeDir = Int32, checkerColor = Color, checkerAlpha = Float64, checkerCell = Float64 }`
- 名前付きで安全に組む入口（テスト・部分上書き・めったに呼ばれない構築用）。
  `pub def makeStyle(spec: BoxStyleSpec): BoxStyle`
- 毎フレーム大量に通る変換用の入口。Color は値のまま受けて中で r, g, b に展開する。
  `pub def styleFromParts(cornerRadius: Float64, borderWidth: Float64, borderColor: Color, borderAlpha: Float64, stripeColor: Color, stripeAlpha: Float64, stripeWidth: Float64, stripePeriod: Float64, stripeDir: Int32, checkerColor: Color, checkerAlpha: Float64, checkerCell: Float64): BoxStyle`
- 全フィールドを名前付きレコードへ展開する（部分更新と、めったに呼ばれない経路の
  `pub def styleToSpec(st: BoxStyle): BoxStyleSpec`
- 何も飾らない素の BoxStyle（枠・縞・市松すべて無効）。色系は塗りと同じ base を入れておく。
  `pub def defaultStyle(base: Color): BoxStyle`
- 枠線の太さ（px）だけ読む（バックエンドのはみ出し見積もり用）。
  `pub def borderWidthOf(st: BoxStyle): Float64`
- 角丸半径を差し替える。
  `pub def withCornerRadius(radius: Float64, st: BoxStyle): BoxStyle`
- 枠線（色・太さ・濃さ）を差し替える。
  `pub def withBorder(color: Color, width: Float64, alpha: Float64, st: BoxStyle): BoxStyle`
- 縞（色・濃さ・幅・周期・向き）を差し替える。
  `pub def withStripe(color: Color, alpha: Float64, width: Float64, period: Float64, dir: Int32, st: BoxStyle): BoxStyle`
- 市松（色・濃さ・セル一辺）を差し替える。
  `pub def withChecker(color: Color, alpha: Float64, cell: Float64, st: BoxStyle): BoxStyle`
- px の長さを持つフィールド（角丸・枠線幅・縞の幅と周期・市松のセル）を一括で factor 倍する。
  `pub def scalePx(factor: Float64, st: BoxStyle): BoxStyle`
- clip 矩形（design px・スクリーン空間）を出力ピクセルの整数矩形 (x0, y0, x1, y1) へ写す
  `pub def clipPixels(scale: {scaleX = Float64, scaleY = Float64}, clip: Rect2.Rect2): (Int32, Int32, Int32, Int32)`
- スプライト 1 つ分の描画命令（zIndex 順にソートして描画される）。
  `pub enum Drawable { case Drawable( String, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Bool, Float64, Float64, Float64, Float64, Int32, Option[BoxStyle], Option[Rect2.Rect2], BlendMode, List[List[Vec2.Vec2]] ) }`
- `pub def eq(a: Drawable, b: Drawable): Bool`
- `pub def toString(d: Drawable): String`
- Drawable の全フィールドを名前で持つレコード（`make` の入力・`toSpec` の出力）。
  `pub type alias DrawableSpec = { texture = String, position = Vec2.Vec2, scale = Vec2.Vec2, rotation = Float64, color = Color, alpha = Float64, centered = Bool, uvOffset = Vec2.Vec2, uvScale = Vec2.Vec2, zIndex = Int32, style = Option[BoxStyle], clip = Option[Rect2.Rect2], blend = BlendMode, mask = List[List[Vec2.Vec2]] }`
- 名前付きで安全に組む入口（テスト・部分上書き・めったに呼ばれない構築用）。
  `pub def make(spec: DrawableSpec): Drawable`
- 毎フレーム大量に通る変換用の入口。`make` の spec レコードを作らないのは、
  `pub def fromParts(texture: String, position: Vec2.Vec2, scale: Vec2.Vec2, rotation: Float64, color: Color, alpha: Float64, centered: Bool, uvOffset: Vec2.Vec2, uvScale: Vec2.Vec2, zIndex: Int32, style: Option[BoxStyle], clip: Option[Rect2.Rect2], blend: BlendMode, mask: List[List[Vec2.Vec2]]): Drawable`
- 全フィールドを名前付きレコードへ展開する（部分更新と、めったに呼ばれない経路の
  `pub def toSpec(d: Drawable): DrawableSpec`
- `pub def textureOf(d: Drawable): String`
- `pub def positionOf(d: Drawable): Vec2.Vec2`
- `pub def scaleOf(d: Drawable): Vec2.Vec2`
- `pub def rotationOf(d: Drawable): Float64`
- `pub def colorOf(d: Drawable): Color`
- `pub def alphaOf(d: Drawable): Float64`
- `pub def zIndexOf(d: Drawable): Int32`
- `pub def styleOf(d: Drawable): Option[BoxStyle]`
- `pub def clipOf(d: Drawable): Option[Rect2.Rect2]`
- `pub def blendOf(d: Drawable): BlendMode`
- `pub def maskOf(d: Drawable): List[List[Vec2.Vec2]]`
- clip 矩形を差し替える。
  `pub def withClip(clip: Option[Rect2.Rect2], d: Drawable): Drawable`
- alpha を差し替える（字を薄める Render.fade の Text 用）。
  `pub def withAlpha(alpha: Float64, d: Drawable): Drawable`
- color と zIndex を差し替える（テキストの文字色・重なり順の上書き用）。
  `pub def withTintAndZIndex(color: Color, zIndex: Int32, d: Drawable): Drawable`
- scale を差し替える。
  `pub def withScale(scale: Vec2.Vec2, d: Drawable): Drawable`
- scale と mask を一緒に差し替える（カメラの zoom は型抜きの形にも掛ける必要がある）。
  `pub def withScaleAndMask(scale: Vec2.Vec2, mask: List[List[Vec2.Vec2]], d: Drawable): Drawable`
- position と rotation を一緒に差し替える（グリフを文字列の置き場所のまわりに回す用）。
  `pub def withPositionAndRotation(position: Vec2.Vec2, rotation: Float64, d: Drawable): Drawable`
- uvOffset と uvScale を一緒に差し替える（レンダーターゲットの上下反転用）。
  `pub def withUv(uvOffset: Vec2.Vec2, uvScale: Vec2.Vec2, d: Drawable): Drawable`
- タイルマップ 1 タイル分のインスタンスデータ。tilemap loader が組み立て、
  `pub type alias TileInstance = { px = Vec2.Vec2, uvOff = Vec2.Vec2, uvSc = Vec2.Vec2, alpha = Float64, tint = Color }`
- タイルマップのインスタンス描画命令（1 draw call で全タイル）。
  `pub type alias TileMapRenderCmd = { textureName = String, tileSize = Float64, position = Vec2.Vec2, tileScale = Vec2.Vec2, color = Color, zIndex = Int32, tileVaoId = GpuHandle.TileVao, tileCount = Int32 }`
- 頂点 1 つぶんの色と濃さ。`PolygonRenderCmd#grad` が頂点列と同じ順で持つ。
  `pub type alias VertexTint = { color = Color, alpha = Float64 }`
- 展開済みの色つき頂点（位置＋色＋濃さ）。バックエンドが三角形の中で線形に混ぜる単位。
  `pub type alias GradVertex = { pos = Vec2.Vec2, color = Color, alpha = Float64 }`
- 凸多角形の塗り潰し命令。vertices はスクリーン px に変換済みの頂点列を渡す。
  `pub type alias PolygonRenderCmd = { vertices = List[Vec2.Vec2], color = Color, alpha = Float64, zIndex = Int32, clip = Option[Rect2.Rect2], blend = BlendMode, grad = Option[List[VertexTint]] }`
- 宣言シェーダーの面 1 枚ぶんの描画依頼（Platform.Draw2d.drawSurface に渡す）。
  `pub type alias SurfaceRenderCmd = { program = GpuHandle.ShaderProgram, texReads = List[(String, ShaderDoc.FilterMode)], rect = Rect2.Rect2, mask = List[List[Vec2.Vec2]], time = Float64, zIndex = Int32, blend = BlendMode, alpha = Float64, params = List[Float64] }`
- grad つき多角形を「色つき頂点の三角形列」に展開する。GL と SoftRaster が同じ
  `pub def gradTriangles(p: PolygonRenderCmd): List[(GradVertex, GradVertex, GradVertex)]`
- 静的多角形バッファのキャッシュキー。ゲームは「静的な中身を決める全入力」
  `pub type alias StaticKey = String`
- 1 フレームぶんの静的レイヤー描画依頼。`renderCommands` の第 4 チャンネルに載せる。
  `pub type alias StaticLayerCmd = { key = StaticKey, polys = Unit -> List[PolygonRenderCmd], viewOffset = Vec2.Vec2, viewScale = Vec2.Vec2, halfDesign = Vec2.Vec2 }`
- エンジン内部でキャッシュした 1 レンジの目次（バックエンドだけが使う）。
  `pub type alias StaticPolyMeta = { first = Int32, count = Int32, blend = BlendMode, clip = Option[Rect2.Rect2], zIndex = Int32 }`

## Duration — `engine/src/core/Duration.flix`
- 内部表現は秒。`Of` という単一コンストラクタでラップすることで
  `pub enum Duration with Eq, ToString { case Of(Float64) }`
- 0 秒。「まだ何も経過していない」「カウントダウン完了」などの基準値。
  `pub def zero(): Duration`
- 秒単位で生成。`1.5 |> Duration.seconds` のようにパイプで書ける。
  `pub def seconds(value: Float64): Duration`
- ミリ秒単位で生成。`500 |> Duration.millis` で 0.5 秒。
  `pub def millis(value: Int32): Duration`
- 「N フレーム分の時間」を fps 想定で生成。
  `pub def frames(c: {count = Int32}, f: {fps = Int32}): Duration`
- 秒単位の Float64 に戻す。Tween の lerp 計算など Float64 が必要な末端でだけ使う。
  `pub def toSeconds(duration: Duration): Float64`
- 2 つの時間を足す。`elapsed + delta` のように経過を伸ばす用途。
  `pub def add(a: Duration, b: Duration): Duration`
- `a - b` を返す。負になり得る（カウントダウン用）。
  `pub def sub(a: Duration, b: Duration): Duration`
- `a - b` を 0 でクランプして返す。Timer の timeLeft 減算など、
  `pub def subClampedToZero(a: Duration, b: Duration): Duration`
- Float64 倍する。`lifetime * speedScale` のような縮尺調整用。
  `pub def scale(duration: Duration, factor: Float64): Duration`
- `Duration / Float64` の除算。「lifetime / 個数 = 1 個あたりの間隔」のような計算用。
  `pub def divBy(duration: Duration, divisor: Float64): Duration`
- 経過時間 / 総時間 の進度を 0.0..1.0 に **クランプして** 返す。
  `pub def ratio(elapsed: Duration, total: Duration): Float64`
- 残り時間が尽きたか（<= 0）。Timer のカウントダウン終了判定に使う。
  `pub def isExpired(duration: Duration): Bool`
- 正の長さを持つか（> 0）。「まだ動いている tween か」等の判定に使う。
  `pub def isPositive(duration: Duration): Bool`

## EngineSentinel.Marker — `engine/src/core/EngineSentinel/Marker.flix`
- `pub enum Marker { case M }`

## FrameDiagnostics — `engine/src/core/FrameDiagnostics.flix`
- 1 コマの診断。時間はナノ秒。
  `pub type alias Diagnostics = { submitNs = Int64, swapNs = Int64, shaderBuilds = List[ShaderBuild], shaderDeletes = Int32, liveShaders = Int32, drawItems = Int32, glyphsAdded = Int32, textureUploads = List[String], gpuNs = Option[Int64], gpuPasses = List[(String, Int64)], scene3dCounts = Scene3dCounts }`
- 3D の場面の数（Diagnostics#scene3dCounts）。
  `pub type alias Scene3dCounts = { instances = Int32, drawn = Int32, drawCalls = Int32, droppedPointLights = Int32, droppedSpotLights = Int32, meshUploads = Int32, meshEvictions = Int32, texture3dUploads = Int32, mipCopies = Int32, materialBuilds = List[ShaderBuild], jointUploads = Int32, targetRebuilds = Int32, cpuPhases = List[(String, Int64)] }`
- 3D を描かないコマの数（全部 0）。
  `pub def emptyScene3dCounts(): Scene3dCounts`
- 上げ直した物と捨てた物の数を 1 行に（どれも 0 なら "-"）。並びは Scene3dCounts の欄の順。
  `pub def uploadsText(c: Scene3dCounts): String`
- CPU の区間を 1 行に（ms は小数 2 桁・区間が無ければ "-"）。
  `pub def cpuPhasesText(c: Scene3dCounts): String`
- 2 コマぶんの数を足す（cpuPhases は同じ名前どうしを足し、初めて出た順に並べる）。
  `pub def addScene3dCounts(a: Scene3dCounts, b: Scene3dCounts): Scene3dCounts`
- 作ったシェーダー 1 つ。
  `pub type alias ShaderBuild = { name = String, reason = BuildReason }`
- 作った理由。Changed は同じ名前で中身が違った時で、違う所の抜き書きを持つ。
  `pub enum BuildReason with Eq, ToString { case First case Changed(String) }`
- 何も起きなかったコマ。
  `pub def empty(): Diagnostics`
- 画面の隅に出す数行（ms は小数 2 桁）。描くのはゲームの字の部品（出す所と見た目はゲームが決める）。
  `pub def summaryLines(d: Diagnostics): List[String]`

## Frustum — `engine/src/scene3d/Frustum.flix`
- `pub type alias Frustum = FrustumData`
- clip の行列（projectionMatrix × viewMatrix）の行から 6 つの面を取り出す（左・右・下・上・near・far）。
  `pub def ofClipMatrix(clip: Mat4.Mat4): Frustum`
- 形の座標の箱（min・max）を world で写した物が、視錐台に掛かりうるか。8 つの角が 1 つの面の外に全部あれば偽。
  `pub def intersectsBox(f: Frustum, min: Vec3.Vec3, max: Vec3.Vec3, world: Mat4.Mat4): Bool`
- 中心 center・半径 radius の球が、視錐台に掛かりうるか。
  `pub def intersectsSphere(f: Frustum, center: Vec3.Vec3, radius: Float64): Bool`
- 点 p が視錐台の中か（面の上は中）。
  `pub def containsPoint(f: Frustum, p: Vec3.Vec3): Bool`

## GameEngine — `engine/src/platform/GameEngine.flix`
- テクスチャアセットのマニフェストエントリ
  `pub type alias TextureEntry = { name = String, path = String, hasAlpha = Bool }`
- フォントアセットのマニフェストエントリ
  `pub type alias FontEntry = { name = String, path = String, fontSize = Float64 }`
- サウンドアセットのマニフェストエントリ
  `pub type alias AudioEntry = { name = String, path = String, looping = Bool }`
- サウンドの論理名 → OpenAL ソース ID
  `pub type alias AudioRegistry = Map[String, Int32]`
- テクスチャ情報: GPU ハンドル + 元画像サイズ
  `pub type alias TextureInfo = { id = GpuHandle.TextureId, width = Float64, height = Float64 }`
- テクスチャの論理名 → TextureInfo
  `pub type alias TextureRegistry = Map[String, TextureInfo]`
- エンジン初期化に必要な設定
  `pub type alias EngineConfig = { rootDir = String, glyphs = String, designWidth = Int32, designHeight = Int32, windowWidth = Int32, windowHeight = Int32, title = String, textureManifest = List[TextureEntry], fontManifest = List[FontEntry], soundManifest = List[AudioEntry], clearColor = Color, maxDeltaTime = Float64, scene3dTextureBudgetMB = Int32, scene3dTextureBudgetCount = Int32 }`
- 3D の場面の絵を GPU に持つ量の上限の既定（MB）。
  `pub def defaultScene3dTextureBudgetMB(): Int32`
- 3D の場面の絵を GPU に持つ枚数の上限の既定。
  `pub def defaultScene3dTextureBudgetCount(): Int32`
- 角丸＋枠線スタイル。共有の描画命令型 `DrawCmd.BoxStyle`。
  `pub type alias BoxStyle = DrawCmd.BoxStyle`
- スプライト 1 つ分の描画命令。renderCommands ハンドラに渡す共有型 `DrawCmd.Drawable`。
  `pub type alias Drawable = DrawCmd.Drawable`
- タイルマップのインスタンス描画命令。共有型 `DrawCmd.TileMapRenderCmd`。
  `pub type alias TileMapRenderCmd = DrawCmd.TileMapRenderCmd`
- 凸多角形の塗り潰し命令。共有型 `DrawCmd.PolygonRenderCmd`。
  `pub type alias PolygonRenderCmd = DrawCmd.PolygonRenderCmd`
- 静的多角形バッファのキャッシュキー。共有型 `DrawCmd.StaticKey`。
  `pub type alias StaticKey = DrawCmd.StaticKey`
- 静的レイヤー描画依頼。共有型 `DrawCmd.StaticLayerCmd`。
  `pub type alias StaticLayerCmd = DrawCmd.StaticLayerCmd`
- 注釈 1 件の書き出し依頼。ゲーム画面の気になる場所を矩形で囲んだとき、
  `pub type alias AnnotationRequest = { frame = Int64, rect = Rect2.Rect2, json = String, readmeBody = String, worldDump = String }`
- タイルマップ 1 タイル分のインスタンスデータ。共有型 `DrawCmd.TileInstance`。
  `pub type alias TileInstance = DrawCmd.TileInstance`
- `pub def toDrawables(item: n, globalPos: Vec2.Vec2): List[Drawable] \ Platform.GpuResources } pub enum Key with Eq, Order, ToString { case A case B case C case D case E case F case G case H case I case J case K case L case M case N case O case P case Q case R case S case T case U case V case W case X case Y case Z case Digit0 case Digit1 case Digit2 case Digit3 case Digit4 case Digit5 case Digit6 case Digit7 case Digit8 case Digit9 case Up case Down case Left case Right case Enter case Space case Escape case Tab case Backspace case Insert case Delete case PageUp case PageDown`
- キーボードキー。
  `pub enum Key with Eq, Order, ToString { case A case B case C case D case E case F case G case H case I case J case K case L case M case N case O case P case Q case R case S case T case U case V case W case X case Y case Z case Digit0 case Digit1 case Digit2 case Digit3 case Digit4 case Digit5 case Digit6 case Digit7 case Digit8 case Digit9 case Up case Down case Left case Right case Enter case Space case Escape case Tab case Backspace case Insert case Delete case PageUp case PageDown case Home case End case CapsLock case F1 case F2 case F3 case F4 case F5 case F6 case F7 case F8 case F9 case F10 case F11 case F12 case Apostrophe case Comma case Minus case Period case Slash case Semicolon case Equal case LeftBracket case Backslash case RightBracket case GraveAccent case LeftShift case LeftCtrl case LeftAlt case LeftSuper case RightShift case RightCtrl case RightAlt case RightSuper case Menu case Numpad0 case Numpad1 case Numpad2 case Numpad3 case Numpad4 case Numpad5 case Numpad6 case Numpad7 case Numpad8 case Numpad9 case NumpadDecimal case NumpadDivide case NumpadMultiply case NumpadSubtract case NumpadAdd case NumpadEnter case NumpadEqual }`
- Key の全バリアント。InputEvent などのイベント駆動入力で
  `pub def allKeys(): List[Key]`
- マウスボタン
  `pub enum MouseButton with Eq, Order, ToString { case Left case Right case Middle }`
- MouseButton の全バリアント。InputEvent でマウス押下/離脱の
  `pub def allMouseButtons(): List[MouseButton]`
- マウスカーソル形状（エディタのリサイズハンドルなどで切り替える）。
  `pub enum Cursor with Eq, ToString { case Default case Crosshair case HResize case VResize case AllResize case Rotate case NWResize case NEResize case SWResize case SEResize }`
- オーディオエフェクト: サウンドの再生・停止・音量・ループ
  `pub eff Audio`
- 指定した名前のサウンドを先頭から再生する
  `pub eff Audio { def playAudio(name: String): Unit }`
- 指定した名前のサウンドを停止する
  `pub eff Audio { def stopAudio(name: String): Unit }`
- 指定した名前のサウンドの音量（gain）を 0.0〜1.0 で設定する
  `pub eff Audio { def setVolume(name: String, volume: Float64): Unit }`
- 指定した名前のサウンドの高さ（再生速度）を実行時に変える。1.0 = 元のまま・
  `pub eff Audio { def setPitch(name: String, pitch: Float64): Unit }`
- 指定した名前のサウンドの AL_LOOPING を実行時に切り替える。
  `pub eff Audio { def setLooping(name: String, loop: Bool): Unit }`
- 全サウンド共通のマスター音量（全体つまみ）を 0.0〜1.0 で設定する。範囲外はクランプ。
  `pub eff Audio { def setMasterVolume(gain: Float64): Unit }`
- すでに登録してある名前の音を、path のファイルから読み直して差し替える。
  `pub eff Audio { def reloadAudio(name: String, path: String): Unit }`
- 指定した名前のサウンドの高い音を削る（ローパス）。gainHF は高い音の残り具合 0.0〜1.0
  `pub eff Audio { def setLowpass(name: String, gainHF: Float64): Unit }`
- 指定した名前のサウンドの長さ（秒）。知らない名前は 0.0。
  `pub eff Audio { def audioSeconds(name: String): Float64 }`

## GamepadMap — `engine/src/platform/GamepadMap.flix`
- パッドの入力 1 つ。ボタンは Xbox 配置の名前（Back は Select / View、Start は Menu の物）。
  `pub enum PadInput with Eq, Order, ToString { case DirUp case DirDown case DirLeft case DirRight case A case B case X case Y case LeftBumper case Back case Start }`
- つないだパッドの機種。案内に出すボタンの絵や、Steam Input を通っているかの判断に使う。
  `pub enum PadKind with Eq, ToString { case Generic case Steam case Unknown }`
- キーとパッドの入力の対応表。**1 ボタン = 1 キー**。
  `pub def table(): List[(Key, PadInput)]`
- table をキーで引く形。1 フレームに全キーを引くので Map にしておく。
  `pub def byKey(): Map[Key, PadInput]`
- GLFW の joystick の GUID（SDL の形の 32 字の 16 進）とパッドの名前から機種を決める。
  `pub def kindOf(guid: String, name: String): PadKind`
- USB のベンダー（数・0 は分からない）とパッドの名前から機種を決める。SDL3 で読む時の形。
  `pub def kindOfVendor(vendor: Int32, name: String): PadKind`

## Gltf — `engine/src/scene3d/Gltf.flix`
- path の .glb を読む（Fs.FileRead.readBytes）。読めない・壊れている時は Err（パスつき）。
  `pub def load(path: String): Result[String, Model3d.Model3d] \ Fs.FileRead`
- .glb のバイトから作る。壊れている・読まない物を含む時は Err。parts は primitive ごと（材質 None・gltfMaterial の絵の名前は None）・textures は空。
  `pub def fromGlb(bytes: Vector[Int8]): Result[String, Model3d.Model3d]`
- 材質の絵の長い辺の上限（px）。baseColor = baseColorTexture と emissiveTexture（同じ色の絵）・normal = normalTexture。
  `pub type alias TextureLimits = { baseColor = Int32, normal = Int32 }`
- 上限なし。ほかの値は { normal = 1024 | Gltf.noTextureLimits() } の形で替える。
  `pub def noTextureLimits(): TextureLimits`
- path の .glb を、絵と材質つきで読む。parts に材質（baseColorTexture → Scene3d.texturedMaterial・normalTexture → 法線マップ・
  `pub def loadTexturedUsing(decoder: ImageData.ImageDecoder, limits: TextureLimits, path: String): Result[String, Model3d.Model3d] \ Fs.FileRead + IO`
- loadTexturedUsing のバイトの版。
  `pub def fromGlbTexturedUsing(decoder: ImageData.ImageDecoder, limits: TextureLimits, bytes: Vector[Int8]): Result[String, Model3d.Model3d] \ IO`

## GpuHandle — `engine/src/core/GpuHandle.flix`
- タイルマップの GPU インスタンスバッファのハンドル（`initTileBuffer` が返す）。
  `pub enum TileVao { case TileVao(Int32) }`
- 永続化した静的多角形の GPU バッファのハンドル（`initStaticPolys` が返す）。
  `pub enum StaticVao { case StaticVao(Int32, Int32) }`
- テクスチャの GPU ハンドル。
  `pub enum TextureId { case TextureId(Int32) }`
- 宣言シェーダー面をコンパイルした GPU プログラムのハンドル（`buildProgram` が返す）。
  `pub enum ShaderProgram { case ShaderProgram(Int32) }`
- Int32 の実体をハンドルに包む（バックエンドが割り当て時に呼ぶ）。
  `pub def wrapTileVao(v: Int32): TileVao`
- ハンドルから Int32 の実体を取り出す（バックエンドが描画時に呼ぶ）。
  `pub def tileVaoInt(h: TileVao): Int32`
- 静的多角形の VAO/VBO の実体をハンドルに包む（バックエンドが割り当て時に呼ぶ）。
  `pub def wrapStaticVao(vao: Int32, vbo: Int32): StaticVao`
- ハンドルから VAO の実体を取り出す（描画時に使う）。
  `pub def staticVaoInt(h: StaticVao): Int32`
- ハンドルから VBO の実体を取り出す（解放時に使う）。
  `pub def staticVboInt(h: StaticVao): Int32`
- Int32 の実体をハンドルに包む。
  `pub def wrapTextureId(v: Int32): TextureId`
- ハンドルから Int32 の実体を取り出す。
  `pub def textureIdInt(h: TextureId): Int32`
- Int32 の実体をハンドルに包む（バックエンドがコンパイル成功時に呼ぶ）。
  `pub def wrapShaderProgram(v: Int32): ShaderProgram`
- ハンドルから Int32 の実体を取り出す（描画時に使う）。
  `pub def shaderProgramInt(h: ShaderProgram): Int32`

## ImageData — `engine/src/core/ImageData.flix`
- width × height・argb = ARGB（行優先・行 0 が絵の上）。数の食い違いは使う側（Texture3d.fromImage など）が確かめる。
  `pub type alias ImageData = { width = Int32, height = Int32, argb = Vector[Int32] }`
- PNG / JPEG のバイトを画素に戻す。読めないバイトは Err。スレッドをまたいで使える（並列の仕事の中から呼んでよい）。
  `pub type alias ImageDecoder = { decode = Vector[Int8] -> Result[String, ImageData] \ IO }`
- 何も解かず、いつも Err を返すデコーダー（絵を読まないテストの handler 用）。
  `pub def failingDecoder(reason: String): ImageDecoder`

## InputEvent — `engine/src/render2d/InputEvent.flix`
- 現在押されているキーのセットを取得する（GameEngine.allKeys() を全て走査）
  `pub def currentKeys(): Set[GameEngine.Key] \ Platform.Input`

## JoyoKanji — `engine/src/core/JoyoKanji.flix`
- アトラスにベイクする全コードポイントを 1 行の文字列として返す。
  `pub def text(): String`

## LightModel3d — `engine/src/scene3d/LightModel3d.flix`
- スカラーの値の式。
  `pub enum ScalarExpr with Eq { case Num(Float64) case In(ScalarInput) case LightField(ScalarLightField) case Add(ScalarExpr, ScalarExpr) case Sub(ScalarExpr, ScalarExpr) case Mul(ScalarExpr, ScalarExpr) case Div(ScalarExpr, ScalarExpr) case Max(ScalarExpr, ScalarExpr) case Min(ScalarExpr, ScalarExpr) case Pow(ScalarExpr, ScalarExpr) case Sqrt(ScalarExpr) case InverseSqrt(ScalarExpr) case Clamp01(ScalarExpr) case Smoothstep(ScalarExpr, ScalarExpr, ScalarExpr) case Dot(Vec3Expr, Vec3Expr) case Length(Vec3Expr) case X(Vec3Expr) case Y(Vec3Expr) case Z(Vec3Expr) case Select(Cond, ScalarExpr, ScalarExpr) case Let(String, ScalarExpr, ScalarExpr) case LetVec3(String, Vec3Expr, ScalarExpr) case Ref(String) }`
- vec3 の値の式（色・位置・向き）。成分ごとの計算は x・y・z を同じ式で回す。
  `pub enum Vec3Expr with Eq { case Make(ScalarExpr, ScalarExpr, ScalarExpr) case In(Vec3Input) case LightField(Vec3LightField) case Add(Vec3Expr, Vec3Expr) case Sub(Vec3Expr, Vec3Expr) case Mul(Vec3Expr, Vec3Expr) case Max(Vec3Expr, Vec3Expr) case Min(Vec3Expr, Vec3Expr) case Scale(Vec3Expr, ScalarExpr) case Mix(Vec3Expr, Vec3Expr, ScalarExpr) case SumPoints(Vec3Expr) case SumSpots(Vec3Expr) case Toon(Vec3Expr) case SrgbToLinear(Vec3Expr) case LinearToSrgb(Vec3Expr) case Select(Cond, Vec3Expr, Vec3Expr) case Let(String, Vec3Expr, Vec3Expr) case LetScalar(String, ScalarExpr, Vec3Expr) case Ref(String) }`
- Select の条件。
  `pub enum Cond with Eq { case Greater(ScalarExpr, ScalarExpr) case AtLeast(ScalarExpr, ScalarExpr) case And(Cond, Cond) }`
- 画素ごと・場面ごとのスカラーの入力。
  `pub enum ScalarInput with Eq, Order { case Hemisphere case ShadowLit case FogNear case FogFar case SkyCurve case LightmapSrgb case LightmapIntensity }`
- 画素ごと・場面ごとの vec3 の入力。
  `pub enum Vec3Input with Eq, Order { case Position case Normal case Eye case Ambient case LightmapColor case Color case FogColor case SkyDirection case SkyZenith case SkyHorizon case SkyGround }`
- 光のループの中で読めるスカラーの欄。
  `pub enum ScalarLightField with Eq { case RangeSquared case OuterCos case InnerCos }`
- 光のループの中で読める vec3 の欄。
  `pub enum Vec3LightField with Eq { case Position case Color case Direction }`
- lightmap の無い面に当たる光（ファイルの頭の light）。
  `pub def lightingModel(): Vec3Expr`
- lightmap のある面に当たる光（ambient と hemisphere の代わりにベイクした光を足す）。
  `pub def lightmapLightingModel(): Vec3Expr`
- 色 Color に距離のかすみを掛けた色。
  `pub def fogModel(): Vec3Expr`
- 向き SkyDirection の空の色。
  `pub def skyModel(): Vec3Expr`
- 点光源 1 本の欄の数（位置 3・color × intensity 3・range²）。
  `pub def pointStride(): Int32`
- スポット 1 本の欄の数（位置 3・向き 3・外の cos・内の cos・color × intensity 3・range²）。
  `pub def spotStride(): Int32`
- `pub def packPointLights(lights: List[Scene3d.PointLight]): Vector[Float64]`
- スポットを 1 本の Vector に並べた物（1 本 = spotStride() 個）。
  `pub def packSpotLights(lights: List[Scene3d.SpotLight]): Vector[Float64]`

## LightModel3d.Codegen — `engine/src/scene3d/LightModel3d/Codegen.flix`
- shadowFunction は (shadow, スポットの並びの欄の位置（スポットの番号 × LightModel3d.spotStride()）, px, py, pz) -> Float64 の関数の名前。
  `pub type alias CpuHooks = { shadowType = String, shadowFunction = String }`
- `pub def generateFlix(hooks: CpuHooks): String`
- `pub def generateFlixCases(hooks: CpuHooks): String`
- `pub def toGlsl(name: String, perPixel: List[Vec3Input], e: Vec3Expr): String`

## LoadProgress — `engine/src/platform/LoadProgress.flix`
- 起動の読み込みの進み具合（区切りごとに 1 回）と、読み込みの仕事を回す口。
  `pub eff LoadProgress`
- phase = 今やっていること（起動画面の字）・done / total = その中の何本目 / 全何本（total 0 以下は本数不明）。
  `pub eff LoadProgress { def report(phase: String, done: Int32, total: Int32): Unit }`
- tasks を全部回してから戻る（並列にするかは handler が決める・ゲームは parMapWithProgress から使う）。
  `pub eff LoadProgress { def runTasks(phase: String, tasks: List[Unit -> Unit \ IO]): Unit }`
- PNG / JPEG を画素に戻すデコーダー。読み込みの関数の頭（本体のスレッド）で受け取り、並列の仕事へ引数で渡す
  `pub eff LoadProgress { def imageDecoder(): ImageData.ImageDecoder }`
- `pub def runNoop(f: Unit -> a \ ef): a \ (ef - LoadProgress) + IO`
- tasks を 1 つずつ回し、最初に (phase, 0, n)・1 つ終わるたびに (phase, 終わった数, n) を report へ渡す（空なら何も渡さない）。
  `pub def runTasksInOrder(report: (String, Int32, Int32) -> Unit \ ef, phase: String, tasks: List[Unit -> Unit \ IO]): Unit \ ef + IO`
- xs を f で 1 つずつ作り、作るたびに (phase, 作った数, 全部の数) を知らせる（最初に (phase, 0, n)）。
  `pub def mapWithProgress(phase: String, f: a -> b \ ef, xs: List[a]): List[b] \ ef + LoadProgress`
- xs を f で作る（handler が並列に回す・結果の並びは xs のまま）。知らせと例外の決まりは runTasks のとおり
  `pub def parMapWithProgress(phase: String, f: a -> b \ IO, xs: List[a]): List[b] \ IO + LoadProgress`

## LoadProgress.Conformance — `engine/src/platform/LoadProgress/Conformance.flix`
- 確かめる handler と、テストの側が用意する道具。
  `pub type alias Harness = { handle = (Unit -> List[Int32] \ IO + LoadProgress) -> (List[Int32], List[(String, Int32, Int32)]) \ IO, sleepMs = Int64 -> Unit \ IO, fail = String -> Unit \ IO, nowMs = Unit -> Int64 \ IO, newFlag = Unit -> Flag \ IO }`
- スレッドをまたいで立てて読むフラグ。
  `pub type alias Flag = { raise = Unit -> Unit \ IO, isRaised = Unit -> Bool \ IO }`
- 知らせの並びと結果の並び: 後ろほど早く終わる 5 つの仕事で、結果は xs の順・最初が (p, 0, 5)・最後が (p, 5, 5)・
  `pub def orderViolations(harness: Harness): List[String] \ IO`
- 50 ms ごとの知らせ: 300 ms 眠る 1 つの仕事の間に、done 0 の知らせが 3 回以上届く（並列で回す handler だけが守る）。
  `pub def pollingViolations(harness: Harness): List[String] \ IO`
- 例外で抜ける: 最初の仕事が 20 ms で投げ、残りは 3 秒眠る。同じ message の例外で、残りを待たずに（2 秒より前に）抜け、
  `pub def failureViolations(harness: Harness): List[String] \ IO`

## Log — `engine/src/core/Log.flix`
- stderr へ 1 行。効果は `unsafe IO` で隠す
  `pub def warn(line: String): Unit`
- 既定値へ替えた事実を定型文で 1 行知らせる。
  `pub def fellBack(domain: String, subject: String, fallback: String, reason: String): Unit`
- stderr へ 1 行知らせてから value を返す。純粋な関数の中で知らせるときはこれ。
  `pub def warnThen(line: String, value: a): a`
- fellBack の定型文で 1 行知らせてから value を返す。純粋な関数の中で知らせるときはこれ。
  `pub def fellBackThen(domain: String, subject: String, fallback: String, reason: String, value: a): a`
- lines を 1 行ずつ知らせてから value を返す（空なら何も出さない）。
  `pub def warnAllThen(lines: List[String], value: a): a`
- fellBack の定型文の 1 行（出さない）。行を集めて warnAllThen へ渡すときに使う。
  `pub def fellBackLine(domain: String, subject: String, fallback: String, reason: String): String`

## Mat4 — `engine/src/scene3d/Mat4.flix`
- `pub type alias Mat4 = Mat4Data`
- `pub def identity(): Mat4`
- `pub def mul(a: Mat4, b: Mat4): Mat4`
- 点を写す（w = 1 で掛け、w での割り算はしない。射影の行列には applyPerspective）。
  `pub def apply(m: Mat4, p: Vec3.Vec3): Vec3.Vec3`
- 向きを写す（w = 0。平行移動を受けない）。法線には normalMatrix を掛けた物を使う。
  `pub def applyDir(m: Mat4, d: Vec3.Vec3): Vec3.Vec3`
- 点を w = 1 で掛け、出た w で割る（projectionMatrix × viewMatrix の後の NDC）。w が 0 以下（目の後ろ）は None。
  `pub def applyPerspective(m: Mat4, p: Vec3.Vec3): Option[Vec3.Vec3]`
- `pub def normalMatrix(m: Mat4): Mat4`
- GL の uniform（glUniformMatrix4fv の transpose = false）に渡す列優先の 16 個。
  `pub def toColumns(m: Mat4): Vector[Float64]`
- 列優先の 16 個から作る（toColumns の逆・glTF の MAT4 と同じ並び）。長さが 16 でなければ Err。
  `pub def ofColumns(v: Vector[Float64]): Result[String, Mat4]`
- `pub def inverse(m: Mat4): Option[Mat4]`
- 平行移動。
  `pub def translate(v: Vec3.Vec3): Mat4`
- 軸ごとの倍率。
  `pub def scale(v: Vec3.Vec3): Mat4`
- 3 本の行で左上 3×3 を組む（平行移動なし）。目の座標の軸を並べる時に使う。
  `pub def ofLinearRows(row0: Vec3.Vec3, row1: Vec3.Vec3, row2: Vec3.Vec3): Mat4`
- GL の透視（右手系の目の座標 → clip。奥行きは near で −1・far で +1。w = −z）。
  `pub def perspective(lens: { xScale = Float64, yScale = Float64, near = Float64, far = Float64 }): Mat4`
- Y 軸まわり（ラジアン）。増えると +Z が +X へ回る（カメラの yaw と同じ向き）。
  `pub def rotateY(angle: Float64): Mat4`
- X 軸まわり（ラジアン）。増えると +Z が −Y へ倒れる（カメラの pitch と同じ「正で下を向く」）。
  `pub def rotateX(angle: Float64): Mat4`
- Z 軸まわり（ラジアン）。増えると +X が +Y へ回る。
  `pub def rotateZ(angle: Float64): Mat4`

## Mesh3d — `engine/src/scene3d/Mesh3d.flix`
- 多角形 1 つ: 頂点の列（3 つ以上・凸・外から見て時計回り）と色。
  `pub type alias Polygon = { points = List[Vec3.Vec3], color = Color }`
- 頂点ごとに 4 つのジョイントの番号（スキンの中の何番目か）と重み（頂点 i の値は [4i, 4i + 4)）。
  `pub type alias SkinWeights = { joints = Vector[Int32], weights = Vector[Float64] }`
- `pub type alias Mesh3d = Mesh3dData`
- 多角形の列から作る。各多角形は頂点 0 を要に扇に割り、巻き方は入力のまま保つ（外から見て時計回りが表）。
  `pub def fromPolygons(polys: List[Polygon]): Mesh3d`
- 頂点の並びから作る。positions・normals・colors は頂点ごとに 3 つ、indices は 3 つで三角 1 枚（表は外から見て時計回り）。
  `pub def fromArrays(arrays: { positions = Vector[Float64], normals = Vector[Float64], colors = Vector[Float64], indices = Vector[Int32], skin = Option[SkinWeights] }): Result[String, Mesh3d]`
- uv を付ける（頂点ごとに u・v の 2 つ）。タンジェントは三角形の辺と uv の差から求める（作る時に 1 回・GL と CPU は同じ値を読む）。
  `pub def withUvs(uvs: Vector[Float64], m: Mesh3d): Result[String, Mesh3d]`
- 外で求めたタンジェント（頂点ごとに x・y・z・w の 4 つ。glTF の TANGENT）で置き換える。xyz は長さ 1 にそろえる。
  `pub def withTangents(tangents: Vector[Float64], m: Mesh3d): Result[String, Mesh3d]`
- uv つきの多角形（uvs は points と同じ数・同じ並び）。
  `pub type alias TexturedPolygon = { points = List[Vec3.Vec3], uvs = List[Vec2.Vec2], color = Color }`
- uv つきの多角形の列から作る（割り方と法線は fromPolygons と同じ・3 点未満の多角形は捨てる）。
  `pub def fromTexturedPolygons(polys: List[TexturedPolygon]): Result[String, Mesh3d]`
- `pub def withBoxUvs(scale: Float64, m: Mesh3d): Mesh3d`
- 2 本目の uv（lightmap を読む UV。頂点ごとに u・v の 2 つ・(0, 0) が絵の左上）を付ける。Unity の uv2・Godot の UV2・
  `pub def withUvs2(uvs: Vector[Float64], m: Mesh3d): Result[String, Mesh3d]`
- `pub def fromObj(objText: String, mtlText: String): Result[String, Mesh3d]`
- 中身の鍵（位置・色・番号の SHA-256 の 16 進。uv つきは uv とタンジェントも）。同じ中身なら同じ字になる。GL はこれで頂点バッファを引く。
  `pub def contentHash(m: Mesh3d): String`
- 軸にそろった箱（AABB）の最小と最大の角。
  `pub type alias Bounds = { min = Vec3.Vec3, max = Vec3.Vec3 }`
- 頂点の最小と最大（形の座標）。頂点の無い形は 0。
  `pub def bounds(m: Mesh3d): Bounds`
- 点の列を囲む軸にそろった箱（点が無ければ原点の大きさ 0 の箱）。
  `pub def boundsOfPoints(points: List[Vec3.Vec3]): Bounds`
- 箱 b の 8 つの角。
  `pub def cornersOf(b: Bounds): List[Vec3.Vec3]`
- `pub def triangleCount(m: Mesh3d): Int32`
- `pub def vertexCount(m: Mesh3d): Int32`
- 頂点の位置（形の座標。頂点ごとに x・y・z の 3 つ）。
  `pub def positions(m: Mesh3d): Vector[Float64]`
- 頂点の法線（長さ 1。頂点ごとに 3 つ。面積 0 の面は 0）。
  `pub def normals(m: Mesh3d): Vector[Float64]`
- 頂点の色（頂点ごとに r・g・b の 3 つ）。
  `pub def colors(m: Mesh3d): Vector[Float64]`
- 頂点ごとに 4 つのジョイントの番号（スキンの中の何番目か）。ジョイントの無い形は None。
  `pub def skinJoints(m: Mesh3d): Option[Vector[Int32]]`
- 頂点ごとに 4 つの重み（足して 1）。ジョイントの無い形は None。
  `pub def skinWeights(m: Mesh3d): Option[Vector[Float64]]`
- `pub def maxSkinJoint(m: Mesh3d): Option[Int32]`
- 三角形の頂点の番号（3 つで 1 枚・外から見て時計回り）。
  `pub def indices(m: Mesh3d): Vector[Int32]`
- 頂点の uv（頂点ごとに u・v の 2 つ。(0, 0) が絵の左上）。uv の無い形は None。
  `pub def uvs(m: Mesh3d): Option[Vector[Float64]]`
- 頂点の 2 本目の uv（lightmap を読む UV。頂点ごとに u・v の 2 つ）。無い形は None。
  `pub def uvs2(m: Mesh3d): Option[Vector[Float64]]`
- 頂点のタンジェント（頂点ごとに x・y・z・w の 4 つ。cross(法線, xyz) × w が絵の上を向く）。uv の無い形は None。
  `pub def tangents(m: Mesh3d): Option[Vector[Float64]]`

## Mip — `engine/src/scene3d/Mip.flix`
- 段を作る時の、4 つのテクセルの色の平均の仕方。SrgbCurve = 8bit の値を sRGB の曲線の値と見て、線形の量へ戻して平均し、
  `pub enum Average with Eq, ToString { case SrgbCurve case Raw }`
- `pub def build(average: Average, tex: ShaderEval.TexData): List[ShaderEval.TexData]`
- `pub def shrinkTo(maxSide: Int32, tex: ShaderEval.TexData): ShaderEval.TexData`
- 絵を読む座標の、画面の右隣と下隣の画素との差（uv の単位）。
  `pub type alias Derivatives = { dudx = Float64, dvdx = Float64, dudy = Float64, dvdy = Float64 }`
- `pub def lodOf(d: Derivatives, width: Int32, height: Int32, levels: Int32): Float64`

## Model3d — `engine/src/scene3d/Model3d.flix`
- primitive 1 つ。mesh = 形（uv を持つ primitive だけ uv つき。ノードの world の行列は焼き込んである）・
  `pub type alias ModelPart = { mesh = Mesh3d.Mesh3d, material = Option[Scene3d.Material3d], node = Option[Int32], gltfMaterial = Option[GltfMaterial] }`
- `pub type alias Model3d = { mesh = Mesh3d.Mesh3d, skin = Option[Skin3d.Skin3d], clips = Map[String, AnimationClip3d.AnimationClip3d], parts = List[ModelPart], textures = List[Texture3d.Texture3d], nodes = List[ModelNode] }`
- glTF のノード 1 つ。座標は engine の座標（左手系。Gltf の頭の X の反転を済ませた物）。
  `pub type alias ModelNode = { name = String, parent = Option[Int32], local = Mat4.Mat4, world = Mat4.Mat4, localBounds = Option[Mesh3d.Bounds], parts = List[Int32] }`
- glTF の材質の alphaMode。Opaque = 不透明・Mask = alphaCutoff で抜く・Blend = 半透明。
  `pub enum AlphaMode with Eq, ToString { case Opaque case Mask case Blend }`
- glTF の材質の情報（読むだけ。描き方を決めるのは part#material）。
  `pub type alias GltfMaterial = { name = String, alphaMode = AlphaMode, alphaCutoff = Float64, doubleSided = Bool, baseColorTexture = Option[String], normalTexture = Option[String], emissiveTexture = Option[String], emissive = { r = Float64, g = Float64, b = Float64 } }`
- 名前が name のノード（同じ名前が複数あれば nodes の並びの前）。たくさん引く時は nodesByName を 1 回作って引く。
  `pub def findNode(name: String, model: Model3d): Option[ModelNode]`
- 名前 → ノード（同じ名前が複数あれば nodes の並びの前）。
  `pub def nodesByName(model: Model3d): Map[String, ModelNode]`
- 名前が prefix で始まるノード（nodes の並びの順）。Blender の書き出しの名前の決まり（"COL_" など）で集める。
  `pub def nodesWithPrefix(prefix: String, model: Model3d): List[ModelNode]`
- ノード node から出た parts（node#parts の順）。1 回ごとに parts を並べ直すので、たくさんのノードに回す時は partsByNode を 1 回作って引く。
  `pub def partsOfNode(node: ModelNode, model: Model3d): List[ModelPart]`
- ノードの番号（nodes の何番目か）→ そのノードから出た parts（parts の並びの順）。
  `pub def partsByNode(model: Model3d): Map[Int32, List[ModelPart]]`
- parts を 1 つずつ置いた物（parts の並びの順）。world = 模型全体を置く行列・材質は part の物・名前は part を持つノードの名前
  `pub def partInstances(world: Mat4.Mat4, model: Model3d): List[Scene3d.Instance3d]`
- ノードの world の原点（world の行列の平行移動の列）。
  `pub def nodeOrigin(node: ModelNode): Vec3.Vec3`
- `pub def partLocalToNode(node: ModelNode, model: Model3d): Option[Mat4.Mat4]`

## Num — `engine/src/core/Num.flix`
- 0 以上 1 以下に収める。濃さ・進み具合・混ぜ具合など「0〜1 のはずの値」を
  `pub def clamp01(x: Float64): Float64`
- lo 以上 hi 以下に収める。lo > hi のときは lo を返す（範囲が無いので下端に丸める）。
  `pub def clamp(lo: Float64, hi: Float64, x: Float64): Float64`
- 整数版の clamp。lo > hi のときは lo を返す（clamp と同じ）。
  `pub def clampInt(lo: Int32, hi: Int32, x: Int32): Int32`
- 小数部だけを残す（1.25 → 0.25）。負でも 0 以上 1 未満になる（-0.25 → 0.75）ので、
  `pub def fract(x: Float64): Float64`
- 0 以上 period 未満へ折り返す。画面の端から端へ回り込む物（流れる雲・スクロールする床・
  `pub def wrapTo(period: Float64, x: Float64): Float64`
- a と b の間を t（0〜1）で混ぜる。範囲外の t は伸ばしたまま（外挿）— 収めたいなら
  `pub def lerp(a: Float64, b: Float64, t: Float64): Float64`
- 床へ丸めて Int32 に落とす（-1.5 → -2）。ゼロ向き切り捨てではない — 負の座標でも
  `pub def floorInt(x: Float64): Int32`
- 最も近い整数へ丸めて Int32 に落とす（0.5 は上へ）。負でも床基準（-1.5 → -1）。
  `pub def roundInt(x: Float64): Int32`
- `pub def sqrt(x: Float64): Float64`
- sin（角はラジアン）。
  `pub def sin(x: Float64): Float64`
- cos（角はラジアン）。
  `pub def cos(x: Float64): Float64`
- 点 (x, y) の向きの角（ラジアン・−π〜π）。引数は y が先（Java の Math.atan2 と同じ）。
  `pub def atan2(y: Float64, x: Float64): Float64`
- asin（答えはラジアン・−π/2〜π/2。−1〜1 の外は NaN）。
  `pub def asin(x: Float64): Float64`
- 自然対数。0 は −∞・負の数は NaN（Java の Math.log と同じ）。
  `pub def log(x: Float64): Float64`
- 1 周ぶんの角（2π）。円周に点を置く計算の共通の源。
  `pub def tau(): Float64`
- 円周率（値の源は tau — 2 で割るのは倍精度で正確）。
  `pub def pi(): Float64`

## Platform — `engine/src/platform/Platform.flix`
- キー・マウス・ゲームパッドの今の状態を読む。
  `pub eff Input`
- `pub eff Input { def isKeyPressed(key: GameEngine.Key): Bool }`
- `pub eff Input { def getMousePosition(): Vec2.Vec2 }`
- `pub eff Input { def isMouseButtonPressed(button: GameEngine.MouseButton): Bool }`
- 1 台目のゲームパッドのボタン・十字キー・スティックのどれかがいま押されて（倒されて）いるか。
  `pub eff Input { def isGamepadTouched(): Bool }`
- 1 台目のゲームパッドの機種（Xbox 配置の一般・Steam Input を通した物・つないでいない）。
  `pub eff Input { def gamepadKind(): GamepadMap.PadKind }`
- 前回呼び出し以降に蓄積されたマウスホイールの y 方向 delta を返し、
  `pub eff Input { def consumeScrollDelta(): Float64 }`
- 前に呼んでからマウスが動いた量（design px・小数のまま。右と下が正）。キャプチャしている間（Window.setMouseCaptured(true)）も
  `pub eff Input { def consumeMouseDelta(): Vec2.Vec2 }`
- ウィンドウがキーとマウスの入力を受け取る状態（フォーカスがある）か。App が Frame#windowFocused に置く。
  `pub eff Input { def isWindowFocused(): Bool }`
- ウィンドウの状態と見た目（閉じるフラグ・大きさ・カーソル・全画面・タイトルの表示）。
  `pub eff Window`
- OS からのイベント（キー・マウス・ホイール・窓の大きさ・閉じるボタン）とゲームパッドの状態を取り込む。1 フレームに 1 回だけ呼ぶ
  `pub eff Window { def pollEvents(): Unit }`
- ウィンドウの閉じるフラグが立っているか（問うだけ。イベントは pollEvents が取り込む）。
  `pub eff Window { def shouldClose(): Bool }`
- ウィンドウの閉じるフラグを立てる・下ろす（GLFW の glfwSetWindowShouldClose）。false で閉じる要求を取り消す
  `pub eff Window { def setShouldClose(close: Bool): Unit }`
- design 座標の描き場の矩形。
  `pub eff Window { def getViewportRect(): Rect2.Rect2 }`
- 今の画面の情報（大きさ・画素の細かさ・最後の pointer の種類・端末の区分）。App が毎コマ読んで
  `pub eff Window { def getDisplay(): Display.Display }`
- マウスカーソル形状を切り替える。連続して同じ Cursor を渡しても問題ない（冪等）
  `pub eff Window { def setCursor(cursor: GameEngine.Cursor): Unit }`
- マウスカーソルの表示/非表示を切り替える。形状(setCursor)は「どんな絵か」、
  `pub eff Window { def setCursorVisible(visible: Bool): Unit }`
- マウスをウィンドウにキャプチャする（真）・放す（偽）。キャプチャしている間は矢印が消え、動きは Input.consumeMouseDelta だけに出る
  `pub eff Window { def setMouseCaptured(captured: Bool): Unit }`
- ウィンドウ⇄ボーダーレスフルスクリーンを切り替える。フルスクリーンはプライマリ
  `pub eff Window { def setFullscreen(on: Bool): Unit }`
- 直近の setFullscreen で今フルスクリーン中かを返す
  `pub eff Window { def isFullscreen(): Bool }`
- Draw2d.renderCommands で塗ったコマを画面へ出す（バッファの入れ替え）。1 フレームの終わりに 1 回だけ呼ぶ。
  `pub eff Window { def presentFrame(): Unit }`
- デバッグモード中であることをウィンドウタイトルで示す。
  `pub eff Window { def setDebugBadge(enabled: Bool): Unit }`
- 1 コマの経過時間。WhyNot Time と呼ばない: engine_world の Clock.Time と重なる。
  `pub eff FrameClock`
- 前フレームからの経過時間。EngineConfig#maxDeltaTime で上限クランプ済み。
  `pub eff FrameClock { def getDeltaTime(): Duration.Duration }`
- 2D の描き物の列を出す口。
  `pub eff Draw2d`
- zIndex 混合で sprites・tileMaps・polygons を 1 フレーム描画する（積んだ面と 3D の場面も z の位置で合流させる）。
  `pub eff Draw2d { def renderCommands(sprites: List[GameEngine.Drawable], tileMaps: List[GameEngine.TileMapRenderCmd], polygons: List[GameEngine.PolygonRenderCmd], staticLayer: Option[GameEngine.StaticLayerCmd]): Unit }`
- 宣言シェーダーの面 1 枚を、次の renderCommands の列へ積む。
  `pub eff Draw2d { def drawSurface(cmd: DrawCmd.SurfaceRenderCmd): Unit }`
- 3D の場面を出す口。
  `pub eff Draw3d`
- 3D の場面 1 つを、次の Draw2d.renderCommands の列へ積む（深度で前後を決め、2D の並びの中では cmd#scene#zIndex の 1 点に入る）。
  `pub eff Draw3d { def drawScene3d(cmd: Scene3d.RenderCmd): Unit }`
- 遊びの途中で初めて出る物を GPU へ先に上げる。前と同じ cmd#key なら何もしない。
  `pub eff Draw3d { def preload3d(cmd: Scene3d.PreloadCmd): Unit }`
- `pub eff Tasks`
- `pub eff Tasks { def startTask(task: Unit -> JObject \ IO): Unit }`
- `pub eff Tasks { def finishTask(): JObject }`
- 仕事を重ねない handler（ブラウザ版・窓の無い描き手）: 預けた仕事を finishTask の時にその場で走らせる。
  `pub def runTasksInPlace(f: Unit -> a \ ef): a \ (ef - Tasks) + IO`
- 3D を描かない handler の組（テストの偽物）が張る、3D の場面を捨てる handler。
  `pub def runNoopDraw3d(f: Unit -> a \ ef): a \ ef - Draw3d`
- GPU に置く資源（タイルのバッファ・テクスチャ・字・シェーダーのプログラム）を用意し、寸法を引く。
  `pub eff GpuResources`
- タイルインスタンスデータを GPU VBO にアップロードし (vaoハンドル, count) を返す
  `pub eff GpuResources { def initTileBuffer(instances: List[GameEngine.TileInstance]): (GpuHandle.TileVao, Int32) }`
- 既存のタイル VAO のインスタンス VBO へ中身を入れ直す（VAO は増やさない）。
  `pub eff GpuResources { def updateTileBuffer(vaoId: GpuHandle.TileVao, instances: List[GameEngine.TileInstance]): (GpuHandle.TileVao, Int32) }`
- 実行時に生成した画素を、名前付きテクスチャとして使えるようにする。
  `pub eff GpuResources { def ensureTexture(name: String, key: String, width: Int32, height: Int32, argb: Vector[Int32]): Unit }`
- アトラスにまだ無い字を、いま生成してアトラスに足す。
  `pub eff GpuResources { def ensureGlyphs(textureName: String, codepoints: Set[Int32]): Unit }`
- `pub eff GpuResources { def getFontAtlas(name: String): FontAtlas }`
- 指定したテクスチャ名の元画像サイズ等を取得する。
  `pub eff GpuResources { def getTextureInfo(name: String): Option[GameEngine.TextureInfo] }`
- Spec を GLSL プログラムへコンパイルしハンドルを返す（起動時/リロード時に 1 回）。
  `pub eff GpuResources { def buildProgram(spec: ShaderDoc.Spec): GpuHandle.ShaderProgram }`
- 1 コマごとの、描く側の診断（FrameDiagnostics）。
  `pub eff Diagnostics`
- 集めるかを切り替える。切っている間は数えない。入れるのは DEBUG の起動だけ（本番で数える負担を作らない）。
  `pub eff Diagnostics { def setDiagnosticsEnabled(on: Bool): Unit }`
- 前に取り出してから溜まった診断を返し、空に戻す（Input.consumeScrollDelta と同じ取り出し方）。
  `pub eff Diagnostics { def consumeDiagnostics(): FrameDiagnostics.Diagnostics }`
- F8 の注釈を書き出す開発の道具。WhyNot Services に入れない: 開発の道具の入口へ寄せて、持たない handler の組
  `pub eff Annotation`
- 注釈一式（screenshot.png / highlighted.png / annotation.json / README.md）を
  `pub eff Annotation { def saveAnnotation(req: GameEngine.AnnotationRequest): Option[String] }`
- 描く effect の束（同じ handler の組から張る 3 つ。上の「積む op と出す op」）。
  `pub type alias Rendering = Draw2d + Draw3d + GpuResources`
- App.launch が要る機種の effect の束。
  `pub type alias Services = Input + Window + FrameClock + Rendering + RenderTarget.Target + GameEngine.Audio + Diagnostics + Tasks`

## Polygon — `engine/src/render2d/Polygon.flix`
- 任意の頂点列から Polygon を生成する（alpha=1.0 不透明）。
  `pub def make(points: List[Vec2.Vec2], color: Color): Polygon`
- 半径 `radius`（px）の円を 12 角形として生成する。小さなマーカーには十分滑らか。
  `pub def circle(radius: Float64, color: Color): Polygon`
- 単位円上の 12 点（30°刻み）。engine に三角関数 FFI を持ち込まないための定数テーブル。
  `pub def unitCircle12(): List[Vec2.Vec2]`
- 埋め込んだ Transform 部品を取り出す
  `pub def transform(poly: Polygon): Transform`
- Transform 部品に関数を適用して差し替える
  `pub def mapTransform(f: Transform -> Transform \ ef, poly: Polygon): Polygon \ ef`
- 埋め込んだ Visual 部品を取り出す
  `pub def visual(poly: Polygon): Visual`
- Visual 部品に関数を適用して差し替える
  `pub def mapVisual(f: Visual -> Visual \ ef, poly: Polygon): Polygon \ ef`
- `pub def setAlpha(alpha: Float64, poly: Polygon): Polygon`
- スクリーン px の塗り潰しコマンドに変換する。`screenPos` は描画原点
  `pub def toRenderCmd(screenPos: Vec2.Vec2, scaleVec: Vec2.Vec2, poly: Polygon): GameEngine.PolygonRenderCmd`

## Pose3d — `engine/src/scene3d/Pose3d.flix`
- `pub type alias Pose3d = PoseData`
- `pub def compute(skin: Skin3d.Skin3d, local: Vector[Skin3d.JointPose]): Pose3d`
- `pub def jointCount(p: Pose3d): Int32`
- 2 つの局所の姿勢を混ぜる（t = 0 で a・1 で b）。平行移動と倍率は 2 つの値の間をなめらかにつなぎ、回転は球面の上で。
  `pub def blend(a: Vector[Skin3d.JointPose], b: Vector[Skin3d.JointPose], t: Float64): Vector[Skin3d.JointPose]`
- 姿勢の鍵: joint 行列の並びの全部の数のビットから作る 64 bit（初めて読んだ時に求める）。同じ並びは必ず同じ鍵になり、
  `pub def keyOf(p: Pose3d): Int64`
- ジョイントの番号の順の joint 行列（GL の joint texture・CPU のスキニングが読む）。
  `pub def jointMatrices(p: Pose3d): Vector[Mat4.Mat4]`
- ジョイントの変換（rootTransform × world。形の座標で、インスタンスの world 行列はまだ掛かっていない）。
  `pub def jointTransform(p: Pose3d, joint: Int32): Mat4.Mat4`

## PostProcess — `engine/src/shader/PostProcess.flix`
- トーンマップの曲線（Unity の Tonemapping Mode・Unreal の Filmic と同じ役目）。
  `pub enum Tonemap with Eq, ToString { case AcesFitted case Reinhard }`
- 既定の露出（stop の数。2^stops 倍してから曲線に掛ける）。曲線の正規化で落ちる白を持ち上げる値で、
  `pub def defaultExposure(): Float64`
- 既定の白の点（この明るさで 1 になる）。
  `pub def defaultWhitePoint(): Float64`
- ITU-R BT.709 の明るさ（0.2126 r + 0.7152 g + 0.0722 b）。
  `pub def luma709(r: Field, g: Field, b: Field): Field`
- spec の色を、露出 2^exposureStops を掛けてから op でトーンマップした色にした Spec（α はそのまま）。
  `pub def tonemapped(op: Tonemap, exposureStops: Float64, whitePoint: Float64, spec: ShaderDoc.Spec): ShaderDoc.Spec`
- tonemapped の、トーンマップの後の色に after を掛ける形（色調・かすみなど 0..1 を前提にした仕上げを同じ面の中で）。
  `pub def tonemappedWith(op: Tonemap, exposureStops: Float64, whitePoint: Float64, after: (Field, Field, Field) -> Shade, spec: ShaderDoc.Spec): ShaderDoc.Spec`
- source の Pass を FXAA 3.11（PC の簡単な版）でならした面。斜めの 4 点（NW・NE・SW・SE）と真ん中の明るさから縁の向きを出し、
  `pub def fxaaSpec(source: String): ShaderDoc.Spec`

## ProjectLoader — `engine/src/core/ProjectLoader.flix`
- project.json から組み立てた、engine 起動に渡すための設定。
  `pub type alias ProjectConfig = { rootDir = String, glyphs = String, designWidth = Int32, designHeight = Int32, windowWidth = Int32, windowHeight = Int32, title = String, textureManifest = List[{name = String, path = String, hasAlpha = Bool}], fontManifest = List[{name = String, path = String, fontSize = Float64}], soundManifest = List[{name = String, path = String, looping = Bool}], clearColor = Color, maxDeltaTime = Float64, scene3dTextureBudgetMB = Int32, scene3dTextureBudgetCount = Int32 }`
- 読み込み結果。シーンは別途 `findSceneFiles` で列挙する。
  `pub type alias Project = { rootDir = String, config = ProjectConfig, portraitDesign = Option[PortraitDesign] }`
- `pub type alias PortraitDesign = { width = Int32, minHeight = Int32, maxHeight = Int32 }`
- 縦の design の大きさ（幅, 高さ）。view = 描き先の大きさ（CSS px など。比だけを使う）。view が 0 以下なら高さは minHeight。
  `pub def portraitDesignOf(spec: PortraitDesign, view: Vec2.Vec2): (Int32, Int32)`
- 縦で起動する時の設定: design を portraitDesignOf に替え、窓の大きさを view にした config。縦の指定が無ければ None（横のまま起動する）。
  `pub def portraitConfigOf(proj: Project, view: Vec2.Vec2): Option[ProjectConfig]`
- project.json を読んで Project を組み立てる。
  `pub def loadProject(rootDir: String): Result[String, Project] \ {Fs.FileRead}`
- プロジェクトディレクトリを再帰的に走査して *.scene.json を列挙する。
  `pub def findSceneFiles(rootDir: String): Result[String, List[String]] \ Fs.Glob`
- flix.toml の依存の行 `"github:ababup1192/flix_game_engine" = { version = "x.y.z", … }` の版。
  `pub def engineVersionOf(toml: String): Option[String]`

## Projection — `engine/src/render2d/drawable/Projection.flix`
- ビュー変換: screenPos = worldPos * scale - offset。
  `pub type alias ViewTransform = { offset = Vec2.Vec2, scale = Vec2.Vec2 }`
- world 座標を screen 座標に変換する: screen = world * scale - offset
  `pub def applyToWorldPos(transform: ViewTransform, worldPos: Vec2.Vec2): Vec2.Vec2`
- カメラ位置 `center` を画面中央に置く投影を作る。
  `pub def viewTransform(zoom: Vec2.Vec2, center: Vec2.Vec2, viewport: {viewportWidth = Float64, viewportHeight = Float64}): ViewTransform`

## Quat — `engine/src/scene3d/Quat.flix`
- `pub type alias Quat = { x = Float64, y = Float64, z = Float64, w = Float64 }`
- 回さない向き。
  `pub def identity(): Quat`
- `pub def normalized(q: Quat): Quat`
- `pub def slerp(a: Quat, b: Quat, t: Float64): Quat`
- 回転の行列（平行移動なし）。q は長さ 1 として読む。
  `pub def toMat4(q: Quat): Mat4.Mat4`

## RadialBuiltin — `engine/src/render2d/RadialBuiltin.flix`
- テクスチャの 1 辺の px 数（正方形）。Render.lightAt / darkAt が
  `pub def size(): Int32`
- 明かり（Add 用）のテクスチャ名。`__` で始めるのはゲームのアセット名と
  `pub def lightName(): String`
- 翳り（Multiply 用）のテクスチャ名。
  `pub def darkName(): String`
- 明かりの画素列（ARGB・行優先）。中心が白・外へ滑らかに減衰。
  `pub def lightPixels(): Vector[Int32]`
- 翳りの画素列（ARGB・行優先）。中心が黒・縁で白、alpha は常に不透明。
  `pub def darkPixels(): Vector[Int32]`

## Ray3d — `engine/src/scene3d/Ray3d.flix`
- `pub type alias Ray3d = RayData`
- 当たった所。distance = 始まりからの距離（m）・point = 当たった点・normal = 当たった面の向き（長さ 1・レイの来た側を向く）。
  `pub type alias RayHit = { distance = Float64, point = Vec3.Vec3, normal = Vec3.Vec3 }`
- pickNearest の的。Shape = 当たり判定の形・Mesh = 形と、形の座標 → world の行列（三角形を全部見る）。
  `pub enum RayTarget { case Shape(CollisionShape3d) case Mesh(Mesh3d.Mesh3d, Mat4.Mat4) }`
- origin から toward の向きへ伸びるレイ。toward の長さが 0 か NaN・無限大を含む時は、何にも当たらないレイ。
  `pub def ray3d(origin: Vec3.Vec3, toward: Vec3.Vec3): Ray3d`
- 始まりの点。
  `pub def origin(r: Ray3d): Vec3.Vec3`
- 向き（長さ 1。何にも当たらないレイは 0）。
  `pub def direction(r: Ray3d): Vec3.Vec3`
- 始まりから distance だけ進んだ点。
  `pub def pointAt(r: Ray3d, distance: Float64): Vec3.Vec3`
- 箱 b に外から当たる所（maxDistance まで）。始まりが箱の中（面の上を含まない）なら None（Unity の Raycast・Godot の intersect_ray と同じ）。
  `pub def hitBox(r: Ray3d, maxDistance: Float64, b: CollisionShape3d.Box3d): Option[RayHit]`
- 球 s に外から当たる所（maxDistance まで）。始まりが球の中（面の上を含まない）・半径が 0 以下なら None。
  `pub def hitSphere(r: Ray3d, maxDistance: Float64, s: CollisionShape3d.Sphere3d): Option[RayHit]`
- 縦のカプセル c に外から当たる所（maxDistance まで）。始まりがカプセルの中（面の上を含まない）・半径が 0 以下なら None。
  `pub def hitCapsule(r: Ray3d, maxDistance: Float64, c: CollisionShape3d.Capsule3d): Option[RayHit]`
- 三角形 (a, b, c) に当たる所（表裏とも・縁を含む・maxDistance まで）。面積 0 の三角形とレイが面に平行な時は None。
  `pub def hitTriangle(r: Ray3d, maxDistance: Float64, a: Vec3.Vec3, b: Vec3.Vec3, c: Vec3.Vec3): Option[RayHit]`
- 形 mesh（形の座標）を world で置いた物に当たる所（三角形の表裏とも）。境界の箱に触れない時は三角形を見ない。
  `pub def hitMesh(r: Ray3d, maxDistance: Float64, mesh: Mesh3d.Mesh3d, world: Mat4.Mat4): Option[RayHit]`
- 置いた物の列のうち、レイが一番近くで当たる物とその所（当たらなければ None。同じ距離なら列の前）。
  `pub def nearestInstance(r: Ray3d, maxDistance: Float64, instances: List[Scene3d.Instance3d]): Option[(Scene3d.Instance3d, RayHit)]`
- 置いた物 i に当たる所。骨つきの物（Scene3d.skinningOf が Some）は形の境界の箱だけで見る
  `pub def hitInstance(r: Ray3d, maxDistance: Float64, i: Scene3d.Instance3d): Option[RayHit]`
- 形 1 つに当たる所。
  `pub def hitShape(r: Ray3d, maxDistance: Float64, shape: CollisionShape3d): Option[RayHit]`
- 的の列のうち、レイが最初に当たる物と当たった所（maxDistance まで。同じ距離なら並びの前）。
  `pub def pickNearest(r: Ray3d, maxDistance: Float64, targets: List[(a, RayTarget)]): Option[(a, RayHit)]`
- glTF のノードの列から、当たり判定の箱の的の列を作る（mesh の無いノードは飛ばす）。鍵は keyOf がノードから決める。
  `pub def boxTargetsOf(keyOf: Model3d.ModelNode -> a, nodes: List[Model3d.ModelNode]): List[(a, RayTarget)]`

## Rect — `engine/src/render2d/Rect.flix`
- デフォルト値で Rect を生成する（alpha は 1.0 = 不透明）
  `pub def make(size: Vec2.Vec2, color: Color): Rect`
- 埋め込んだ Transform 部品を取り出す
  `pub def transform(rect: Rect): Transform`
- Transform 部品に関数を適用して差し替える
  `pub def mapTransform(f: Transform -> Transform \ ef, rect: Rect): Rect \ ef`
- 埋め込んだ Visual 部品を取り出す
  `pub def visual(rect: Rect): Visual`
- Visual 部品に関数を適用して差し替える
  `pub def mapVisual(f: Visual -> Visual \ ef, rect: Rect): Rect \ ef`
- alpha を設定する
  `pub def setAlpha(alpha: Float64, rect: Rect): Rect`
- 角丸半径（px）を設定する。0 で矩形、>0 で角丸（BoxStyle 経由）。
  `pub def setCornerRadius(radius: Float64, rect: Rect): Rect`
- 枠線の色を設定する。
  `pub def setBorderColor(color: Color, rect: Rect): Rect`
- 枠線の不透明度を設定する（0 で枠なし）。
  `pub def setBorderAlpha(alpha: Float64, rect: Rect): Rect`
- 枠線の太さ（design px）を設定する。0 以下で枠なし。小数も可。
  `pub def setBorderWidth(width: Float64, rect: Rect): Rect`
- 枠線の太さ（design px）を取得する。
  `pub def getBorderWidth(rect: Rect): Float64`
- 45° 斜線ハッチを設定する。width<=0 または alpha<=0 で無効。
  `pub def setStripe(color: Color, alpha: Float64, width: Float64, period: Float64, rect: Rect): Rect`
- 表示サイズ（描画矩形の幅・高さ）を取得する
  `pub def getSize(rect: Rect): Vec2.Vec2`
- 表示サイズを設定する。リサイズ編集の主たる更新先で、`scale` ではなく
  `pub def setSize(size: Vec2.Vec2, rect: Rect): Rect`
- Drawable に変換する（texture="" でテクスチャなしを示す）
  `pub def toDrawable(rect: Rect, globalPos: Vec2.Vec2): GameEngine.Drawable`

## Rect2 — `engine/src/core/Rect2.flix`
- 矩形: position = 左上座標、size = 幅と高さ
  `pub type alias Rect2 = {position = Vec2.Vec2, size = Vec2.Vec2}`
- 原点 (0, 0) から指定サイズの矩形を作成する
  `pub def fromSize(size: Vec2.Vec2): Rect2`
- 矩形の終端（右下）座標を返す
  `pub def end(rect: Rect2): Vec2.Vec2`
- 矩形の面積を返す
  `pub def area(rect: Rect2): Float64`
- 矩形の中心座標を返す
  `pub def center(rect: Rect2): Vec2.Vec2`
- 指定した点が矩形に含まれるか判定する
  `pub def hasPoint(point: Vec2.Vec2, rect: Rect2): Bool`
- 2 つの矩形の交差（重なっている部分）。重なりが無ければ size が 0 以下の矩形を返す —
  `pub def intersect(a: Rect2, b: Rect2): Rect2`
- 全方向に amount 分だけ広げた矩形を返す。負の値なら縮む（内側の余白）。
  `pub def grow(amount: Float64, rect: Rect2): Rect2`

## RenderTarget — `engine/src/platform/RenderTarget.flix`
- ターゲットを開くたびに前の中身をどう始末するかの 3 択（wgpu / Vulkan の LoadOp と同じ語彙）。
  `pub enum LoadOp { case Keep case Clear(Color) case ClearTransparent }`
- ターゲットの寸法の基準。Design = design 解像度（ドット絵の画素の大きさにそろえる）・
  `pub enum Basis with Eq, ToString { case Design case Window }`
- ターゲットの画素の形式（wgpu の TextureFormat と同じ名前）。
  `pub enum Format with Eq, ToString { case Rgba8Unorm case Rgba16Float }`
- ターゲットの作り方（毎コマの中身 = Render.Pass とは別に、名前ごとに 1 つ）。wgpu / Unity の
  `pub type alias Descriptor = { scale = Float64, basis = Basis, format = Format, samples = Int32 }`
- 既定（design 解像度そのまま・Rgba8Unorm・MSAA なし）。
  `pub def defaultDescriptor(): Descriptor`
- 描き先の画素そのまま（窓が 1920 × 1080 なら 1920 × 1080 で描く）・Rgba8Unorm・MSAA なし。
  `pub def windowDescriptor(): Descriptor`
- d の形式を Rgba16Float にした作り方（1 を超える明るさを持つ Pass。`RenderTarget.withHdr(RenderTarget.windowDescriptor())`）。
  `pub def withHdr(d: Descriptor): Descriptor`
- d の 1 画素の標本の数を samples にした作り方（MSAA: 3D の手すり・金網・電線のような細い物の欠けとちらつきを抑える。
  `pub def withMsaa(samples: Int32, d: Descriptor): Descriptor`
- 描く時の標本の数（1・2・4・8 のどれか。samples を超えない一番大きい物・1 未満は 1）。GPU の上限は描き手が掛ける。
  `pub def samplesOf(d: Descriptor): Int32`
- n を超えない 1・2・4・8 の一番大きい物（1 未満は 1）。
  `pub def samplesAtMost(n: Int32): Int32`
- scale が範囲（0 より大きく 1 以下・有限）の中か。外なら scaleOf が 1.0 に直す（Render.resolvePassReads が知らせる）。
  `pub def isScaleInRange(d: Descriptor): Bool`
- 範囲に収めた倍率。0 以下・1 より大きい・非有限は 1.0（既定値で続ける。知らせるのは呼び手）。
  `pub def scaleOf(d: Descriptor): Float64`
- ターゲットのテクセル寸法。どの経路もこの 1 本で決める（GL・描き出し・App が別々に丸めると 1px 割れる）。
  `pub def texelSizeOf(design: Vec2.Vec2, pixelScale: Float64, d: Descriptor): (Int32, Int32)`
- 自分の名前を読む Pass が、前のコマの中身（history）を読むための別名。Render.resolvePassReads が書き換え、
  `pub def historyName(name: String): String`
- ターゲットを開く時の宣言（Target.beginTarget に渡す 1 つ）。
  `pub type alias TargetSpec = { name = String, width = Int32, height = Int32, format = Format, clear = LoadOp, samples = Int32 }`
- レンダーターゲットへの描き込み先の切り替え。
  `pub eff Target`
- ターゲットを開く。以降の Platform.Draw2d.renderCommands は画面でなくここに描かれる（Platform.Window.presentFrame で画面へ出る物にもならない）。
  `pub eff Target { def beginTarget(spec: RenderTarget.TargetSpec): Unit }`
- 描き手の design px → 描き先の画素の倍率（窓なら窓の実際の大きさに収めた倍率・動画やスクリーンショットはその書き出しの倍率）。
  `pub eff Target { def pixelScale(): Float64 }`
- ターゲットを閉じて描画先を画面へ戻す。
  `pub eff Target { def endTarget(): Unit }`
- レンダーターゲットを使わないゲーム・GL の無い環境（テスト等）向けの何もしないハンドラ。
  `pub def runNoop(f: Unit -> a \ ef + Target): a \ ef`

## RenderUtil — `engine/src/core/RenderUtil.flix`
- Float64 → Float32 (GL uniform 用)
  `pub def f32(v: Float64): Float32`
- Float64 → Int32 (四捨五入)
  `pub def floatToInt32(v: Float64): Int32`
- `pub def sinF(x: Float64): Float64`
- `pub def cosF(x: Float64): Float64`
- `pub def sqrtF(x: Float64): Float64`

## Scene3d — `engine/src/scene3d/Scene3d.flix`
- 点光源。range より遠い所には届かない（落ち方は (1 − d² / range²)²）。
  `pub type alias PointLight = { position = Vec3.Vec3, color = Color, intensity = Float64, range = Float64 }`
- 影の地図（段 C）。mapSize = 一辺の画素数・bias = 自分の面に影を落とさないための奥行きのずらし・
  `pub type alias ShadowMap = { mapSize = Int32, bias = Float64, pcfRadius = Int32, strength = Float64 }`
- スポットライト。position から target を向き、fovY（ラジアン・円錐の全体の角）の円錐の中だけを照らす。shadow が Some なら影を落とす（段 C）。
  `pub type alias SpotLight = { position = Vec3.Vec3, target = Vec3.Vec3, fovY = Float64, innerFovY = Option[Float64], color = Color, intensity = Float64, range = Float64, shadow = Option[ShadowMap] }`
- 白・intensity 1・range 10・影なし・innerFovY = None のスポットライト。
  `pub def spotLight(position: Vec3.Vec3, target: Vec3.Vec3, fovY: Float64): SpotLight`
- innerFovY が None の時の、縁で暗くなり始める角の割合（fovY に対する）。
  `pub def spotInnerRatio(): Float64`
- スポットの円錐の縁の cos（GL と CPU が同じ物を使う）。cone = smoothstep(outerCos, innerCos, dot(−l, スポットの向き))。
  `pub def spotConeOf(spot: SpotLight): { outerCos = Float64, innerCos = Float64 }`
- 距離のかすみ。目からの距離が near から far へ向かって color に寄る。
  `pub type alias DistanceFog = { color = Color, near = Float64, far = Float64 }`
- 場面全体の光。ambient = どこにでも当たる光の色・hemisphere = 上を向く面ほど明るくする量（0 で無し）・
  `pub type alias Environment3d = { ambient = Color, hemisphere = Float64, toonSteps = Int32, fog = Option[DistanceFog], background = Option[Color] }`
- 描く解像度。Native = 窓の画素で描く・Design = 設計の解像度で描いてから拡げる（ドット絵と画素の大きさをそろえる）。
  `pub enum Resolution with Eq { case Native case Design }`
- `pub enum Output { case Color case Depth({ near = Float64, range = Float64 }) }`
- uv が 0..1 の外へ出た時の読み方。Repeat = 繰り返す・Clamp = 端の色を伸ばす。
  `pub enum Wrap with Eq { case Repeat case Clamp }`
- 法線マップ。texture = 絵の名前（タンジェント空間・緑が絵の上）・strength = でこぼこの強さ（1 で絵のまま）。
  `pub type alias NormalMap = { texture = String, strength = Float64 }`
- 材質の中身。spec の Out の色 = 光を当てる前の色・params = spec の Param・
  `pub type alias MaterialFields = { spec = ShaderDoc.Spec, params = Map[String, Float64], cutout = Bool, emission = Option[ShaderDoc.Shade], normalMap = Option[NormalMap], wrap = Wrap, blend = Bool, doubleSided = Bool, emissionIntensity = Float64, shaderHash = Lazy[Int64] }`
- 材質（閉じた型 — 欄を後から足しても、ゲームの書いた値が壊れない）。material から作り、with… で足す。
  `pub type alias Material3d = MaterialData`
- spec だけの材質（params 空・cutout なし・emission なし・法線マップなし・Repeat・不透明・表の面だけ）。
  `pub def material(spec: ShaderDoc.Spec): Material3d`
- spec の Param に渡す値（Unity のマテリアルの float の値を渡すのと同じ。渡さない名前は 0）。
  `pub def withParams(p: Map[String, Float64], m: Material3d): Material3d`
- on が真なら α が 0.5 未満の画素を捨てる（深度も書かない）。
  `pub def withCutout(on: Bool, m: Material3d): Material3d`
- on が真なら半透明（窓ガラス・網・水面）: 色 = spec の色 × α + 下の色 × (1 − α)。深度は読むが書かない（奥の半透明も透けて見える）。
  `pub def withAlphaBlend(on: Bool, m: Material3d): Material3d`
- on が真なら裏の面も描く（ガラスの板・網・葉など、裏から見ても見える物）。裏の面は光の計算の法線を裏返す
  `pub def withDoubleSided(on: Bool, m: Material3d): Material3d`
- 光の計算の後に足す、自分で光る色（かすみに沈まない）。名前は替えなくてよい（GL は spec と emission の中身の鍵でプログラムを引く）。
  `pub def withEmission(s: ShaderDoc.Shade, m: Material3d): Material3d`
- emission を外す（glb の emissive で光らせたくない時）。emissionIntensity も 1 に戻す。
  `pub def withoutEmission(m: Material3d): Material3d`
- emission を線形の量に戻した後に掛ける倍率 k（既定 1。Godot の emission_energy_multiplier・Unity の Emission Intensity と同じ分け方）。
  `pub def withEmissionIntensity(k: Float64, m: Material3d): Material3d`
- spec の名前だけを替える（知らせの文面・GL のプログラムの名前に出る）。木の違う材質に別の名前を付けなくてよい
  `pub def withSpecName(name: String, m: Material3d): Material3d`
- `pub def withNormalMap(n: NormalMap, m: Material3d): Material3d`
- `pub def withWrap(w: Wrap, m: Material3d): Material3d`
- 材質の中身を読む（GL・CPU・鍵が使う）。
  `pub def materialFieldsOf(m: Material3d): MaterialFields`
- 絵 1 枚 × 頂点の色の材質（絵の r・g・b に VertexColor の r・g・b を掛け、α は絵の α）。filter = 絵の読み方（ドット絵なら Nearest）。
  `pub def texturedMaterial(texture: String, filter: ShaderDoc.FilterMode): Material3d`
- 1 つの材質が読める (テクスチャ名, 補間) の組の上限（ShaderDoc.materialTexReads の並びの前から。法線マップは別枠）。
  `pub def maxMaterialTextures(): Int32`
- 置いた物の中身。mesh = 形・world = 形の座標 → world の行列・tint = 頂点の色に掛ける色・material = 材質（None なら頂点の色）・
  `pub type alias InstanceFields = { mesh = Mesh3d.Mesh3d, world = Mat4.Mat4, tint = Color, material = Option[Material3d], pose = Option[Pose3d.Pose3d], lightmap = Option[Lightmap], name = String }`
- 3D のベイクした光（Blender などで前もって計算した光の絵。2D の Light.lightMapPass とは別）。
  `pub type alias Lightmap = { texture = String, colorSpace = Texture3d.ColorSpace, intensity = Float64, maxLevels = Int32 }`
- 置いた物（閉じた型 — 欄を後から足しても、ゲームの書いた値が壊れない）。
  `pub type alias Instance3d = InstanceData`
- 形を world の行列で置く（tint 白・材質なし）。
  `pub def meshInstance(mesh: Mesh3d.Mesh3d, world: Mat4.Mat4): Instance3d`
- `pub def withTint(c: Color, i: Instance3d): Instance3d`
- `pub def withMaterial(m: Material3d, i: Instance3d): Instance3d`
- 置いた物に名前を付ける（F8 で 3D の場面の中を囲むと、注釈のチケットにこの名前が出る。絵は変わらない）。
  `pub def withName(name: String, i: Instance3d): Instance3d`
- 置いた物の名前（付けていなければ空）。
  `pub def nameOf(i: Instance3d): String`
- ジョイントの行列で曲げる（mesh にジョイントの重みが無ければ描く時に無視される）。
  `pub def withPose(p: Pose3d.Pose3d, i: Instance3d): Instance3d`
- 描く時に曲げる Pose（GL と CPU が同じ判定に使う）。None ならバインドポーズのまま描く:
  `pub def skinningOf(i: Instance3d): Option[Pose3d.Pose3d]`
- `pub def skinningWarning(i: Instance3d): Option[String]`
- 置いた物の中身を読む（GL・CPU・鍵が使う）。
  `pub def instanceFieldsOf(i: Instance3d): InstanceFields`
- 置いた物の world の境界（形の境界の 8 つの角を world で写した物を囲む AABB）。
  `pub def worldBoundsOf(i: Instance3d): Option[Mesh3d.Bounds]`
- 置いた物の、描く順を決める点（world の境界の真ん中。骨つきと頂点の無い形は world の原点）。
  `pub def drawCenterOf(r: InstanceFields): Vec3.Vec3`
- `pub def blendOrderOf(eye: Vec3.Vec3, fieldsOf: a -> InstanceFields, xs: List[a]): List[a]`
- 半透明の材質（withAlphaBlend）が付いた置いた物か。
  `pub def isBlendedFields(r: InstanceFields): Bool`
- 描き手が視錐台 f の外として描かなくてよい物か（迷ったら偽 = 描く）。GL と CPU と影の地図が同じ判定を使う。
  `pub def isOutsideFrustum(f: Frustum.Frustum, i: Instance3d): Bool`
- isOutsideFrustum の本体（置いた物の中身から。CPU の描き手が使う）。
  `pub def isOutsideFrustumFields(f: Frustum.Frustum, r: InstanceFields): Bool`
- ビルボードが視錐台 f の外か（外接球で見る。半径 = (size.x × max(|anchor.x|, |1 − anchor.x|), size.y × 同じ y) の長さ）。
  `pub def isBillboardOutsideFrustum(f: Frustum.Frustum, b: Billboard3d): Bool`
- 場面の縦横の比（幅 / 高さ。高さは 1e-6 未満にしない）。GL と CPU の射影の行列と視錐台が同じ値を使う。
  `pub def aspectOf(scene: Scene3dCmd): Float64`
- 場面のカメラで見る視錐台（縦横の比は aspectOf。GL と CPU が同じ物を使う）。
  `pub def frustumOf(scene: Scene3dCmd): Frustum.Frustum`
- スポットの影の地図を描く目の視錐台（縦横の比は 1）。目に見えない物も影は落とすので、影の地図はこちらで間引く。
  `pub def shadowFrustumOf(spot: SpotLight): Frustum.Frustum`
- `pub def lightmapMaxLevels(): Int32`
- UV の島の間の px（読み込んだ lightmap の絵の上で）から、読む mip のレベルの数の上限を決める（1 以上）。
  `pub def lightmapLevelsForGap(gapPx: Int32): Int32`
- colorSpace = Srgb・intensity = 1・maxLevels = lightmapMaxLevels() の lightmap。ほかの値は { intensity = 2.0 | Scene3d.lightmap(name) } の形で替える。
  `pub def lightmap(texture: String): Lightmap`
- 置いた物にベイクした光を付ける（2 本目の uv で読む）。付けた物は環境光と hemisphere を足さず、動く光（点光源・スポット）は足す。
  `pub def withLightmap(lm: Lightmap, i: Instance3d): Instance3d`
- 描く時に使う lightmap（使える時だけ Some。intensity の負・NaN・無限は 0 に・maxLevels は 1 以上に直す）。GL・CPU・描き出しの鍵はこれだけを読む。
  `pub def lightmapOf(i: Instance3d): Option[Lightmap]`
- lightmapOf の本体（置いた物の中身から。描き出しの鍵が使う）。
  `pub def lightmapOfFields(f: InstanceFields): Option[Lightmap]`
- 付けたのに使わない理由（1 行）。理由が重なる時は 1 行だけ（材質が無い → 骨つき → 2 本目の uv が無い → tex3d: でない の順）。
  `pub def lightmapWarning(i: Instance3d): Option[String]`
- 置いた物が読む絵の名前（材質の tex 場と emission・法線マップ・使える lightmap）。材質の絵の上限（maxMaterialTextures）で切らずに全部。
  `pub def textureNamesOf(i: Instance3d): List[String]`
- ビルボードの中身。texture と regionRect = 貼る絵（テクスチャの px）・position = 立てる world の点・
  `pub type alias BillboardFields = { texture = String, regionRect = Rect2.Rect2, position = Vec3.Vec3, size = Vec2.Vec2, anchor = Vec2.Vec2, tint = Color, lit = Bool }`
- 深度つきのビルボード（ドット絵を 3D に立てる。閉じた型 — 欄を後から足してもゲームの値が壊れない）。
  `pub type alias Billboard3d = BillboardData`
- anchor 足元の真ん中・tint 白・光を当てる。
  `pub def billboard(texture: String, regionRect: Rect2.Rect2, position: Vec3.Vec3, size: Vec2.Vec2): Billboard3d`
- `pub def withAnchor(a: Vec2.Vec2, b: Billboard3d): Billboard3d`
- `pub def withBillboardTint(c: Color, b: Billboard3d): Billboard3d`
- 光とかすみを当てない（炎・光る目）。
  `pub def unlit(b: Billboard3d): Billboard3d`
- ビルボードの中身を読む（GL・CPU・鍵が使う）。
  `pub def billboardFieldsOf(b: Billboard3d): BillboardFields`
- 場面 1 つ。size = 描き物の大きさ（位置は PlacedItem の at。Shader 面と同じ決まり）・zIndex = 2D の並びの中の重なり順・
  `pub type alias Scene3dCmd = { size = Vec2.Vec2, camera = Camera3d.Camera3d, instances = List[Instance3d], billboards = List[Billboard3d], pointLights = List[PointLight], spotLights = List[SpotLight], environment = Environment3d, resolution = Resolution, output = Output, zIndex = Int32, time = Float64, textures = List[Texture3d.Texture3d], sky = Option[Sky3d] }`
- `pub def scene(camera: Camera3d.Camera3d, size: Vec2.Vec2): Scene3dCmd`
- 空の中身。zenith = 真上の色・horizon = 地平の色・ground = 真下の色・curve = 地平から真上（真下）へ向かう色の寄り方
  `pub type alias SkyFields = { zenith = Color, horizon = Color, ground = Color, curve = Float64 }`
- 3D の場面の空（閉じた型 — 欄を後から足しても、ゲームの書いた値が壊れない）。gradientSky から作り、with… で替える。
  `pub type alias Sky3d = SkyData`
- 上下のグラデーションの空（曲がり 1）。目から見た向き d の色は、d.y ≥ 0 なら horizon と zenith の間を d.y^curve で、
  `pub def gradientSky(zenith: Color, horizon: Color, ground: Color): Sky3d`
- 地平から真上・真下へ向かう色の寄り方を替える。0 以下・NaN・無限は 1 として描く（skyCurveOf）。
  `pub def withSkyCurve(curve: Float64, s: Sky3d): Sky3d`
- 空の中身を読む（GL・CPU・鍵が使う）。
  `pub def skyFieldsOf(s: Sky3d): SkyFields`
- 描く時に使う曲がり（0 以下・NaN・無限は 1）。GL と CPU が同じ値を使う。
  `pub def skyCurveOf(s: Sky3d): Float64`
- 画素の向きを組む材料（場面のカメラから 1 回だけ作る）。forward = 見ている向き・right = 画面の右の向き × tan(fovY / 2) × 縦横の比・
  `pub type alias SkyBasis = { forward = Vec3.Vec3, right = Vec3.Vec3, up = Vec3.Vec3 }`
- 場面 scene のカメラと縦横の比（aspectOf）で、空の画素の向きを組む材料を作る。GL と CPU が同じ物を使う。
  `pub def skyBasisOf(scene: Scene3dCmd): SkyBasis`
- NDC の点 ndc（−1..1・y は上へ）を通って目から伸びる向き（長さ 1）。
  `pub def skyDirectionOf(b: SkyBasis, ndc: Vec2.Vec2): Vec3.Vec3`
- sky と environment の background が両方 Some の時の、知らせる 1 行（background は使わない）。毎コマ通るので呼ぶ側が初回 1 回だけ出す。
  `pub def skyWarning(scene: Scene3dCmd): Option[String]`
- 1 つの場面で計算する点光源の上限。
  `pub def maxPointLights(): Int32`
- 1 つの場面で計算するスポットライトの上限。
  `pub def maxSpotLights(): Int32`
- 影の地図の縦横の上限（GL 3.3 が約束する大きさより大きいが、今の GPU なら作れる）。GL と CPU が同じ値で頭打ちにする。
  `pub def maxShadowMapSize(): Int32`
- pcfRadius の上限（(2r+1)² 回の読みを画素ごとに行うので、大きすぎる値で GPU を止めない）。GL と CPU が同じ値で頭打ちにする。
  `pub def maxShadowPcfRadius(): Int32`
- スポットライトから見たカメラ（影の地図を描く目）。位置から target を向き、fovY の角で見る。near は 1・far は range。
  `pub def shadowCamera(spot: SpotLight): Camera3d.Camera3d`
- 影の地図の行列（world → 光の clip 空間。縦横の比は 1）。GL と CPU が同じ物を使う。
  `pub def shadowMatrix(spot: SpotLight): Mat4.Mat4`
- 上限を超えた光を、目に近い物から選んで残す（同じ距離なら並びの前の物）。残った物は元の並びの順のまま。
  `pub def pickLights(eye: Vec3.Vec3, cmd: Scene3dCmd): Scene3dCmd`
- pickLights が上限を超えて落とす光の数（points = 点光源・spots = スポット）。落とす物が無ければ 0。
  `pub def droppedLightsOf(cmd: Scene3dCmd): { points = Int32, spots = Int32 }`
- 1 コマに描く 3D の場面の列で pickLights が落とす光の数の合計（points = 点光源・spots = スポット）。
  `pub def droppedLightsOfScenes(scenes: List[RenderCmd]): { points = Int32, spots = Int32 }`
- 落とす光があれば、種類ごとに (鍵, 知らせる 1 行)。毎コマ通るので、呼ぶ側が鍵ごとに初回 1 回だけ出す（GL と CPU で同じ文面）。
  `pub def droppedLightsWarnings(cmd: Scene3dCmd): List[(String, String)]`
- `pub type alias RenderCmd = { at = Vec2.Vec2, clip = Option[Rect2.Rect2], scene = Scene3dCmd }`
- 描き手へ渡す、先に GPU へ上げる物の宣言（App.withPreload3d）。key = 中身を決める全入力をまとめた字・
  `pub type alias PreloadCmd = { key = DrawCmd.StaticKey, instances = Unit -> List[Instance3d], textures = Unit -> List[Texture3d.Texture3d] }`

## ShaderDoc — `engine/src/shader/ShaderDoc.flix`
- 位置 (u,v) のどちらの軸を読むか。
  `pub enum Axis with Eq, ToString { case U case V }`
- 3D の world の軸（左手系。X = 東・Y = 上・Z = 北。Scene3d と同じ約束）。World / Normal の成分。
  `pub enum Axis3 with Eq, ToString { case X case Y case Z }`
- Worley（セルノイズ）の出力の選び方。F2mF1 が網目（水面の目地）。
  `pub enum WorleyOut with Eq, ToString { case F1 case F2 case F2mF1 }`
- Tex がテクスチャのどのチャンネルを読むか。既定は R（明るさ・マスクの慣習）。
  `pub enum TexChan with Eq, ToString { case R case G case B case A }`
- tex / blur がテクスチャを読むときの補間（wgpu の FilterMode・Unity の Point/Linear と同じ 2 択）。
  `pub enum FilterMode with Eq, ToString { case Nearest case Linear }`
- 2 つの場を合わせる素の計算。混ぜる意図（0..1 の重み）は Blend を使い、これは生の値の合成。
  `pub enum BinOp with Eq, ToString { case Add case Sub case Mul case Min case Max case Step case Div }`
- 1 つの場に掛ける素の関数。
  `pub enum UnOp with Eq, ToString { case Neg case Abs case Fract case Floor case Sin case Cos case Sat case OneMinus case Sqrt }`
- 値の場（スカラー・0..1 目安）。GPU では 1 個の float、CPU では Float64 になる。
  `pub enum Field { case Const(Float64) case Uv({ axis = Axis }) case Worley({ scale = Float64, seed = Int32, out = WorleyOut }) case Fbm({ octaves = Int32, scale = Float64, seed = Int32 }) case FbmTile({ octaves = Int32, scale = Float64, period = Vec2.Vec2, seed = Int32 }) case Smoothstep({ lo = Float64, hi = Float64, of = Field }) case Scaled({ factor = Float64, scroll = Vec2.Vec2, of = Field }) case Warp({ amount = Float64, scale = Float64, seed = Int32, of = Field }) case Mix({ a = Field, b = Field, t = Float64 }) case Blend({ a = Field, b = Field, by = Field }) case Disk({ cx = Float64, cy = Float64, radius = Float64, feather = Float64 }) case Radial({ cx = Float64, cy = Float64 }) case RadialAspect({ cx = Float64, cy = Float64, aspect = Float64 }) case Quantize({ of = Field, steps = Int32 }) case Scales({ scale = Float64, stagger = Float64 }) case Glints({ scale = Float64, rate = Float64, density = Float64, seed = Int32 }) case Ripples({ freq = Float64, amp = Float64, speed = Float64, seed = Int32 }) case Sparkle({ scale = Float64, rate = Float64, density = Float64, seed = Int32 }) case Bin({ op = BinOp, a = Field, b = Field }) case Hash1({ scale = Float64, seed = Int32, bucket = Option[Field] }) case Hash2({ scale = Float64, seed = Int32, comp = Axis, bucket = Option[Field] }) case Un({ op = UnOp, of = Field }) case Pow({ of = Field, p = Float64 }) case Time({ scale = Float64, offset = Field }) case Tiling({ tiles = Vec2.Vec2, of = Field }) case Snap({ cells = Vec2.Vec2, of = Field }) case Swirl({ cx = Float64, cy = Float64, strength = Float64, rate = Float64, of = Field }) case Angle({ cx = Float64, cy = Float64 }) case Rotate({ cx = Float64, cy = Float64, turns = Float64, rate = Float64, of = Field }) case Ref(String) case Tex({ name = String, chan = TexChan }) case Shift({ dx = Field, dy = Field, of = Field }) case TexBlur({ name = String, chan = TexChan, radius = Vec2.Vec2, taps = Int32, amount = Field }) case TexSize({ name = String, axis = Axis }) case Sampler({ filter = FilterMode, of = Field }) case Param({ name = String }) case World({ axis = Axis3 }) case Normal({ axis = Axis3 }) case VertexColor({ chan = TexChan }) }`
- 面の色（rgb）。
  `pub enum Shade { case Solid(Color) case Ramp({ lo = Color, hi = Color, field = Field }) case Gradient({ stops = List[(Float64, Color)], field = Field }) case Cosine({ a = Color, b = Color, c = Color, d = Color, field = Field }) case Rgb({ r = Field, g = Field, b = Field }) }`
- 面の出力（このピクセルの最終色とアルファ）。
  `pub enum Out { case Fill({ shade = Shade, alpha = Field }) }`
- シェーダー面 1 枚ぶんの宣言（theme.json の materials[i].surface に対応する予定）。
  `pub type alias Spec = { name = String, cycleRate = Float64, bindings = List[(String, Field)], out = Out }`
- 動作確認用の最小 Spec: 時間で lo↔hi を行き来する横グラデ（Uv U + 位相回し）。
  `pub def demoSurface(): Spec`
- 水のリアル版: Worley F2−F1 の網目（目地）を、ドメインワープでうねらせ、
  `pub def waterVeins(): Spec`
- マグマの正典 Spec（水と同じ骨格を熱いパレットで組み替えた対の素材）。
  `pub def lavaVeins(): Spec`
- この Spec を塗ったときの「代表色」（F8 注釈・SoftRaster など GLSL を走らせられない
  `pub def representativeColor(spec: Spec): Color`
- 場の木を前置順（親 → 子）で 1 本ずつ f に渡して畳み込む汎用の走査。
  `pub def foldField(f: (a, Field) -> a, acc: a, field: Field): a`
- foldField の、各節に「その節の tex / blur の補間」（Sampler の内側なら その filter）も渡す形。
  `pub def foldFieldScoped(f: (a, FilterMode, Field) -> a, filter: FilterMode, acc: a, field: Field): a`
- Spec の tex / blur が読むテクスチャ名を f で書き換える（形は変えない）。
  `pub def renameTex(f: String -> String, spec: Spec): Spec`
- Spec の場を「bindings（前から）→ 色 → alpha」の順に並べる。texNames と、場を全部見る走査はこの並びを使う。
  `pub def fieldsOf(spec: Spec): List[Field]`
- Spec が読むテクスチャ名を texReads の並びから重複なしで列挙する（寸法だけを引く TexSize の名前も入る）。
  `pub def texNames(spec: Spec): List[String]`
- Spec が読む (テクスチャ名, 補間) の組を「bindings（前から）→ 色 → alpha」の初出順・重複なしで列挙する。
  `pub def texReads(spec: Spec): List[(String, FilterMode)]`
- Spec が読む Param の名前を「bindings（前から）→ 色 → alpha」の初出順・重複なしで列挙する。
  `pub def paramNames(spec: Spec): List[String]`
- Param の名前に使える字か（英数字と '_'・1 字以上）。JSON の読みが確かめる。
  `pub def paramNameOk(name: String): Bool`
- 面に渡された値の表から、Spec の Param の値を正典順に並べる（表に無い名前は 0）。
  `pub def paramValues(spec: Spec, params: Map[String, Float64]): List[Float64]`
- Spec の Param を、値の表の値の Const に置き換える（表に無い名前は 0）。
  `pub def bindParams(params: Map[String, Float64], spec: Spec): Spec`
- 面に渡された値の表に無い Param の名前（知らせる物）。
  `pub def missingParams(spec: Spec, params: Map[String, Float64]): List[String]`
- この節が、子の場を自分の uv と違う uv で読むなら、その子（shift の dx・dy は今の uv で読むので入らない）。
  `pub def remappedChild(field: Field): Option[Field]`
- 負の指数の pow の底の下限（GLSL と CPU が同じ値を読む）。
  `pub def negPowFloor(): Float64`
- 負の指数の pow の答えの上限。
  `pub def negPowCeil(): Float64`
- taps を 1..64 に丸める（GLSL のループの上限と CPU の評価で同じ数を読む）。
  `pub def blurTaps(taps: Int32): Int32`
- Spec がぼかし（TexBlur）を使うか（GLSL の sg_blur を宣言するか）。
  `pub def usesBlur(spec: Spec): Bool`
- Spec が割り算（BinOp.Div）を使うか（GLSL の sg_div を宣言するか）。
  `pub def usesDiv(spec: Spec): Bool`
- ベクトルの長さ。成分を並べて渡す（2 つなら xy、3 つなら xyz）。空なら 0。
  `pub def lengthOf(parts: List[Field]): Field`
- 長さ 1 にそろえた成分。長さ 0 のベクトルは 0 のまま（Div の 0 割りの決まり）。
  `pub def normalized(parts: List[Field]): List[Field]`
- field を、world の 2 軸 plane = (u に写す軸, v に写す軸) を uv として読ませる（Fbm・Worley など uv を読む場を
  `pub def atWorld(plane: (Axis3, Axis3), field: Field): Field`
- Spec が World か Normal を読むか（2D の面に置くと 0 になるので知らせる物）。
  `pub def usesWorld3d(spec: Spec): Bool`
- 材質（Spec と自分で光る色 emission）の中の Param の名前。Spec の paramNames の後ろに、emission にだけ出てくる名前を
  `pub def materialParamNames(spec: Spec, emission: Option[Shade]): List[String]`
- 材質に渡された値の表から、materialParamNames の順に値を並べる（表に無い名前は 0）。
  `pub def materialParamValues(spec: Spec, emission: Option[Shade], params: Map[String, Float64]): List[Float64]`
- 色の Param を値の表の値の Const に置き換える（bindParams の色の版。emission を CPU で評価する前に通す）。
  `pub def bindShadeParams(params: Map[String, Float64], shade: Shade): Shade`
- 材質（Spec と emission）の中の (テクスチャ名, 補間) の組。Spec の texReads の後ろに、emission にだけ出てくる組を
  `pub def materialTexReads(spec: Spec, emission: Option[Shade]): List[(String, FilterMode)]`
- 材質の tex / blur のうち、materialTexReads の limit 組目より後ろの組を読む物を 0 の Const に置き換える
  `pub def limitMaterialTexReads(limit: Int32, spec: Spec, emission: Option[Shade]): (Spec, Option[Shade])`

## ShaderEval — `engine/src/shader/ShaderEval.flix`
- テクスチャ 1 枚ぶんの画素（ARGB・正立・行優先）。Tex ノードが CPU 側で標本する素材。
  `pub type alias TexData = { width = Int32, height = Int32, pixels = Vector[Int32] }`
- Rgba16Float の Pass の画素（wgpu の TextureFormat::Rgba16Float の絵を CPU で持つ形）。
  `pub type alias HdrTexture = HdrTextureData`
- x を half（16bit の浮動小数）の精度に丸めた値（GPU の Rgba16Float の描き先が書く値。65504 を超えると無限大）。
  `pub def roundToHalf(x: Float64): Float64`
- width × height の画素（rgba = 1 画素に r, g, b, α の 4 つ・行優先）を half に丸めて凍らせる。足りない分は 0。
  `pub def hdrTextureOf(width: Int32, height: Int32, rgba: Vector[Float64]): HdrTexture`
- 幅（テクセルの数）。
  `pub def hdrWidthOf(tex: HdrTexture): Int32`
- 高さ（テクセルの数）。
  `pub def hdrHeightOf(tex: HdrTexture): Int32`
- index 番目の値（index = (y × 幅 + x) × 4 + 成分。成分は r = 0・g = 1・b = 2・α = 3）。外なら 0。
  `pub def hdrChannelOf(tex: HdrTexture, index: Int32): Float64`
- 面の tex / blur の読み先の 1 枚（case の名前は RenderTarget.Format と同じ）。Rgba8Unorm = 8bit の絵（ファイル・Rgba8Unorm の Pass）・
  `pub enum TexImage { case Rgba8Unorm(TexData) case Rgba16Float(HdrTexture) }`
- 代表点 uv（0..1 目安）と時刻 t の最終色（Color の rgb。ここでは 0..1 に切らない — 1 を超える色の場や Rgba16Float の Pass を読む面は 1 を超え得る。切るのは書き込む側）。
  `pub def evalPixel(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64): Color`
- 代表点のアルファ（Fill#alpha の場を評価）。
  `pub def evalAlpha(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64): Float64`
- evalPixel のテクスチャつき版。texEnv は名前 → 画素（pass の生成結果など）。
  `pub def evalPixelTex(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64, texEnv: Map[String, TexData]): Color`
- evalAlpha のテクスチャつき版。
  `pub def evalAlphaTex(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64, texEnv: Map[String, TexData]): Float64`
- 色とアルファを一度に返す版（bindings の先行評価を色と α で共有する）。
  `pub def evalPixelAlphaTex(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64, texEnv: Map[String, TexData]): (Color, Float64)`
- 場を Float64 へ（shared も tex も無い所で 1 点だけ）。
  `pub def evalField(field: ShaderDoc.Field, uv: Vec2.Vec2, t: Float64): Float64`
- 組み直した面。compile で作り、evalCompiled に画素ごとに渡す。
  `pub type alias CompiledSpec = Compiled`
- Spec を面 1 枚ぶん組み直す。texEnv の名前もここで引いておく（画素ごとに Map を引かない）。
  `pub def compile(spec: ShaderDoc.Spec, texEnv: Map[String, TexImage]): CompiledSpec`
- 3D の材質を組み直す材料。textures = tex / blur の読み先の絵の段の列（名前 → Mip.build の段。段 0 が元の絵。
  `pub type alias MaterialInput = { spec = ShaderDoc.Spec, emission = Option[ShaderDoc.Shade], params = Map[String, Float64], textures = Map[String, Vector[TexData]], repeat = Bool }`
- 3D の材質（Scene3d.Material3d の spec・emission・params）を組み直す。Param は params の値の Const に置き換える
  `pub def compileMaterial(input: MaterialInput): CompiledSpec`
- 画素 1 つ（uv = (u, v)・時刻 t）の (r, g, b, α)。値は evalPixelAlphaTex と同じ。
  `pub def evalCompiled(compiled: CompiledSpec, u: Float64, v: Float64, t: Float64): (Float64, Float64, Float64, Float64)`
- 3D のメッシュの画素 1 つの入力。world = 画素の world の点・normal = 外向きの法線（長さは問わない）・
  `pub type alias SurfacePoint = { world = Vec3.Vec3, normal = Vec3.Vec3, uv = Vec2.Vec2, color = Color }`
- 3D のメッシュの画素 1 つ（時刻 t）の (r, g, b, α)。色は光を当てる前の色（albedo）。
  `pub def evalCompiled3(compiled: CompiledSpec, point: SurfacePoint, t: Float64): (Float64, Float64, Float64, Float64)`
- 3D の材質の画素 1 つ: 光を当てる前の色（albedo）・α・自分で光る色（emission。無ければ黒）。
  `pub type alias MaterialSample = { albedo = Color, alpha = Float64, emission = Color }`
- evalCompiled3 に emission を足した版（bindings の評価を色・α・emission で共有する）。
  `pub def evalMaterial3(compiled: CompiledSpec, point: SurfacePoint, t: Float64): MaterialSample`
- `pub def evalMaterial3Mip(compiled: CompiledSpec, center: SurfacePoint, nextX: SurfacePoint, nextY: SurfacePoint, t: Float64): MaterialSample`
- 段の列 chain の uv (u, v) の r・g・b を lod で読む（sampleMip と同じ読み方。3D の法線マップが読む）。
  `pub def sampleMipRgb(chain: Vector[TexData], sampling: { linear = Bool, repeat = Bool }, lod: Float64, u: Float64, v: Float64): (Float64, Float64, Float64)`

## ShaderGen — `engine/src/shader/ShaderGen.flix`
- vertex シェーダー（面 quad 1 枚・uv を渡すだけ）。Spec に依存しない固定ソース。
  `pub def vertexSource(): String`
- ノイズ関数の固定テンプレ（hash2 / worley / fbm）。Spec に依存しないので 1 度だけ pin し、
  `pub def preludeSource(): String`
- Spec 2 つの構造比較（program キャッシュの正当性の中核）。真 ⇒ compile は純関数なので
  `pub def eqSpec(a: ShaderDoc.Spec, b: ShaderDoc.Spec): Bool`
- 2 つの材質（spec と自分で光る色 emission）が同じ GLSL を生むか（render_gl の材質の program キャッシュの鍵）。
  `pub def eqMaterial(specA: ShaderDoc.Spec, emissionA: Option[ShaderDoc.Shade], specB: ShaderDoc.Spec, emissionB: Option[ShaderDoc.Shade]): Bool`
- a と b が同じ物か（中身ではなく参照）。
  `pub def isSameSpec(a: ShaderDoc.Spec, b: ShaderDoc.Spec): Bool`
- 2 つの emission が同じ物か（両方無いか、参照が同じ）。
  `pub def isSameEmission(a: Option[ShaderDoc.Shade], b: Option[ShaderDoc.Shade]): Bool`
- `pub def hashMaterial(spec: ShaderDoc.Spec, emission: Option[ShaderDoc.Shade]): Int64`
- Spec → fragment シェーダー全体（prelude + main）。uTime uniform を前提に持つ。
  `pub def compile(spec: ShaderDoc.Spec): String`
- 3D の材質を GLSL にした部品。render_gl の 3D の frag が、自分の光の計算の前に差し込む。
  `pub type alias MaterialGlsl = { uniforms = String, functions = String, paramNames = List[String], texReads = List[(String, ShaderDoc.FilterMode)], cutoutAlpha = String }`
- 3D の材質（spec と自分で光る色 emission）の GLSL の部品。World / Normal / VertexColor は varying の vWorld / vNormal / vColor を、
  `pub def compile3d(spec: ShaderDoc.Spec, emission: Option[ShaderDoc.Shade]): MaterialGlsl`
- `pub def texMipSource(): String`
- `pub def compileBody(spec: ShaderDoc.Spec): String`

## ShaderJson — `engine/src/shader/ShaderJson.flix`
- JSON をトップレベルの Spec へ読み取る。壊れていれば Err（パス付きの説明）。
  `pub def parse(json: Json): Result[JsonError, ShaderDoc.Spec]`
- parse の「色を名前で書ける」版。palette は色票の名前 → 実色で、JSON 側は
  `pub def parseWith(palette: Map[String, Color], json: Json): Result[JsonError, ShaderDoc.Spec]`
- `pub def toJson(spec: ShaderDoc.Spec): Json`
- path を読んで Spec にする（読めない・崩れているときは Err）。フォールバックは呼び側が
  `pub def load(path: String): Result[JsonError, ShaderDoc.Spec] \ Fs.FileRead`
- load の「色を名前で書ける」版（parseWith を通す）。theme から作った色票を渡す。
  `pub def loadWith(palette: Map[String, Color], path: String): Result[JsonError, ShaderDoc.Spec] \ Fs.FileRead`
- path を読み、読めない・語彙が違うときは fallback の面へ落とす（fail-open）。
  `pub def loadOr(fallback: ShaderDoc.Spec, path: String): ShaderDoc.Spec \ Fs.FileRead`
- loadOr の「色を名前で書ける」版。
  `pub def loadOrWith(palette: Map[String, Color], fallback: ShaderDoc.Spec, path: String): ShaderDoc.Spec \ Fs.FileRead`

## Skin3d — `engine/src/scene3d/Skin3d.flix`
- ジョイント 1 本の局所の姿勢（親のジョイントの座標で。根は rootTransform の座標で）。
  `pub type alias JointPose = { translation = Vec3.Vec3, rotation = Quat.Quat, scale = Vec3.Vec3 }`
- `pub type alias Skin3d = SkinData`
- 1 体のジョイントの上限。GL の joint texture の 1 行（64 × mat4）と CPU が同じ値を使う。
  `pub def maxJoints(): Int32`
- names・parents（-1 が根。親の番号は自分より小さい）・レストポーズ・逆バインド行列から作る。
  `pub def make(spec: { names = Vector[String], parents = Vector[Int32], rest = Vector[JointPose], inverseBinds = Option[Vector[Mat4.Mat4]], rootTransform = Mat4.Mat4 }): Result[String, Skin3d]`
- ジョイントごとの「根からの行列」（rootTransform は掛けない）。parents は親が子より先の並び。
  `pub def jointWorlds(parents: Vector[Int32], local: Vector[JointPose]): Vector[Mat4.Mat4]`
- 局所の姿勢の行列（平行移動 × 回転 × 倍率）。
  `pub def jointPoseToMat4(p: JointPose): Mat4.Mat4`
- `pub def jointCount(s: Skin3d): Int32`
- 名前からジョイントの番号（同じ名前が 2 つあれば前の物）。
  `pub def jointIndex(s: Skin3d, name: String): Option[Int32]`
- ジョイントの名前（番号の順）。
  `pub def names(s: Skin3d): Vector[String]`
- 親の番号（根は -1）。
  `pub def parents(s: Skin3d): Vector[Int32]`
- `pub def restPose(s: Skin3d): Vector[JointPose]`
- 逆バインド行列（番号の順）。
  `pub def inverseBinds(s: Skin3d): Vector[Mat4.Mat4]`
- `pub def rootTransform(s: Skin3d): Mat4.Mat4`

## Splash — `engine/src/render2d/Splash.flix`
- 起動画面 1 枚の見え方。
  `pub type alias View = { design = Vec2.Vec2, atlas = FontAtlas, logoSize = Vec2.Vec2, phase = String, ratio = Option[Float64], turns = Float64 }`
- 組み込みの素材で埋めた見え方。フォントもロゴも決まっているので、
  `pub def bootView(design: Vec2.Vec2, phase: String, ratio: Option[Float64], turns: Float64): View`
- 起動画面 1 枚を描画命令にする。
  `pub def drawables(v: View): List[GameEngine.Drawable]`
- 0..1 に収めた進み具合。本数が 0 以下なら None（＝まだ何本あるか分からない）。
  `pub def clampRatio(done: Int32, total: Int32): Option[Float64]`
- 流れるバーの位置。1 秒で 1 周する。
  `pub def turnsOf(elapsedSec: Float64): Float64`

## Sprite — `engine/src/render2d/drawable/Sprite.flix`
- デフォルト値で Sprite を生成する（テクスチャ全体を表示）
  `pub def make(texture: String, position: Vec2.Vec2, scale: Vec2.Vec2): Sprite`
- 埋め込んだ Transform 部品を取り出す
  `pub def transform(sprite: Sprite): Transform`
- Transform 部品に関数を適用して差し替える
  `pub def mapTransform(f: Transform -> Transform \ ef, sprite: Sprite): Sprite \ ef`
- 埋め込んだ Visual 部品を取り出す
  `pub def visual(sprite: Sprite): Visual`
- Visual 部品に関数を適用して差し替える
  `pub def mapVisual(f: Visual -> Visual \ ef, sprite: Sprite): Sprite \ ef`
- 不透明度を設定する（0.0 = 完全透明、1.0 = 不透明）
  `pub def setAlpha(alpha: Float64, sprite: Sprite): Sprite`
- 水平反転を設定する
  `pub def setFlipH(h: Bool, sprite: Sprite): Sprite`
- テクスチャ内の切り出し矩形を設定する。None ならテクスチャ全体を使う
  `pub def setRegionRect(rect: Option[Rect2.Rect2], sprite: Sprite): Sprite`
- 格子分割の列数を設定する（スプライトシート用）
  `pub def setHframes(hframes: Int32, sprite: Sprite): Sprite`
- 格子分割の行数を設定する（スプライトシート用）
  `pub def setVframes(vframes: Int32, sprite: Sprite): Sprite`
- 表示セル index を設定する。frame = row * hframes + col
  `pub def setFrame(frame: Int32, sprite: Sprite): Sprite`
- 描画オフセット (centered 基準点からのずれ) を設定する
  `pub def setOffset(offset: Vec2.Vec2, sprite: Sprite): Sprite`
- Sprite を Drawable に変換する。
  `pub def toDrawable(sprite: Sprite, globalPos: Vec2.Vec2): GameEngine.Drawable \ Platform.GpuResources`
- regionRect / hframes / vframes / frame と元テクスチャサイズから
  `pub def computeUv(sprite: Sprite, textureSize: Vec2.Vec2): {uvOffset = Vec2.Vec2, uvScale = Vec2.Vec2}`

## SpriteFrames — `engine/src/render2d/drawable/SpriteFrames.flix`
- 1 フレームの定義
  `pub type alias Frame = { texture = String, regionRect = Option[Rect2.Rect2], duration = Float64 }`
- 1 アニメーションの定義
  `pub type alias Animation = { loop = Bool, speed = Float64, frames = List[Frame] }`
- 空の SpriteFrames を生成する
  `pub def empty(): SpriteFrames`
- アニメーションを追加する（同名なら上書き）
  `pub def addAnimation(name: String, animation: Animation, spriteFrames: SpriteFrames): SpriteFrames`
- 指定したアニメーションを取得する
  `pub def getAnimation(name: String, spriteFrames: SpriteFrames): Option[Animation]`
- アニメーション名の一覧を返す
  `pub def animationNames(spriteFrames: SpriteFrames): List[String]`
- 指定アニメ・フレーム index のテクスチャ名を返す（範囲外なら None）
  `pub def frameTexture(name: String, frame: Int32, spriteFrames: SpriteFrames): Option[String]`
- 指定アニメ・フレーム index の regionRect（切り出し矩形）を返す。
  `pub def frameRegion(name: String, frame: Int32, spriteFrames: SpriteFrames): Option[Rect2.Rect2]`

## Text — `engine/src/render2d/Text.flix`
- テキストとフォントアトラスから Text を生成する。
  `pub def make(text: String, fontAtlas: FontAtlas, fontSize: Float64): Text`
- 折り返し幅（表示 px）を設定する。この幅を超える字は次の行へ送られる。
  `pub def setWrapWidth(wrapWidth: Option[Float64], label: Text): Text`
- 埋め込んだ Transform 部品を取り出す
  `pub def transform(label: Text): Transform`
- Transform 部品に関数を適用して差し替える
  `pub def mapTransform(f: Transform -> Transform \ ef, label: Text): Text \ ef`
- 埋め込んだ Visual 部品を取り出す
  `pub def visual(label: Text): Visual`
- Visual 部品に関数を適用して差し替える
  `pub def mapVisual(f: Visual -> Visual \ ef, label: Text): Text \ ef`
- テキストを設定する
  `pub def setText(text: String, label: Text): Text`
- 横方向アライメントを設定する
  `pub def setHorizontalAlignment(alignment: HorizontalAlignment, label: Text): Text`
- 縦方向アライメントを設定する
  `pub def setVerticalAlignment(alignment: VerticalAlignment, label: Text): Text`
- テキストを描画したときに占める表示サイズを返す。
  `pub def measure(label: Text): Vec2.Vec2`
- 行内テキスト幅 (lineWidth) と horizontalAlignment から、グリフ列に適用する
  `pub def horizontalOffsetFor(alignment: HorizontalAlignment, lineWidth: Float64): Float64`
- 全行の合計高さ (totalHeight) と verticalAlignment から、テキストブロック全体に
  `pub def verticalOffsetFor(alignment: VerticalAlignment, totalHeight: Float64): Float64`
- テキストから Drawable のリストを生成する。
  `pub def toDrawables(label: Text, globalPos: Vec2.Vec2): List[GameEngine.Drawable]`

## TextLayout — `engine/src/core/TextLayout.flix`
- 文字を 0 以上の Unicode 番号に直す。
  `pub def charToCodePoint(ch: Char): Int32`
- 行の高さ（文字サイズの 1.2 倍。詰め気味の標準的な行間）。
  `pub def lineHeightMultiplier(): Float64`
- 1 行のテキストを中央に置くための、横方向のずらし量。
  `pub def centerOffset(totalAdvance: Float64, scale: Float64): Float64`
- 各文字の送り幅の合計（＝テキスト全体の幅。ベイク基準の単位）。
  `pub def totalAdvance(advances: List[Float64]): Float64`
- 改行文字でテキストを行に分ける。
  `pub def splitLines(text: String): List[List[Char]]`
- 各文字を置くペン位置。折り返し幅を超えたら次の行へ送る。
  `pub def layoutPositions(advances: List[Float64], wrapWidth: Float64, scale: Float64, lineHeight: Float64): List[(Float64, Float64)]`
- 1 文字ぶんの寸法と、アトラス上の切り出し位置。
  `pub type alias GlyphMetrics = { xOff = Float64, yOff = Float64, glyphW = Float64, glyphH = Float64, advance = Float64, s0 = Float64, t0 = Float64, s1 = Float64, t1 = Float64 }`
- 1 文字を画面上で囲む四角の範囲（左上と右下）。
  `pub type alias QuadBounds = { x0 = Float64, y0 = Float64, x1 = Float64, y1 = Float64 }`
- ペン位置に置いた 1 文字が、画面上で占める四角の範囲を求める。
  `pub def glyphQuadBounds(penPos: (Float64, Float64), glyph: GlyphMetrics, scale: Float64, basePos: Vec2.Vec2, offsetX: Float64): QuadBounds`
- 折り返した結果、何行になるかを数える。
  `pub def lineCount(advances: List[Float64], wrapWidth: Float64, scale: Float64, lineHeight: Float64): Int32`

## Texture3d — `engine/src/scene3d/Texture3d.flix`
- `pub type alias Texture3d = Texture3dData`
- 辺の上限（GL 3.3 が約束する大きさより大きいが、今の GPU なら作れる）。
  `pub def maxSide(): Int32`
- ARGB（行優先・行 0 が絵の上）から作る。数の食い違い・辺が 0 以下・辺が maxSide() を超える、は Err。
  `pub def fromArgb(width: Int32, height: Int32, argb: Vector[Int32]): Result[String, Texture3d]`
- 解いた絵から作る（決まりは fromArgb と同じ）。
  `pub def fromImage(image: ImageData.ImageData): Result[String, Texture3d]`
- PNG / JPEG のバイトを decoder で画素に戻して作る（decoder は LoadProgress.imageDecoder() で受け取る）。
  `pub def decodeUsing(decoder: ImageData.ImageDecoder, bytes: Vector[Int8]): Result[String, Texture3d] \ IO`
- `pub def width(t: Texture3d): Int32`
- `pub def height(t: Texture3d): Int32`
- ARGB（行優先・行 0 が絵の上）。
  `pub def argb(t: Texture3d): Vector[Int32]`
- 中身の鍵（寸法と画素の SHA-256 の 16 進）。同じ画素なら同じ字になる。
  `pub def contentHash(t: Texture3d): String`
- 材質の Tex の読み先の名前（"tex3d:" + contentHash の頭 16 字）。場面の textures に入れた絵はこの名前で引く。
  `pub def name(t: Texture3d): String`
- 場面の textures から引く名前の頭（GL と CPU が名前の引き分けに使う）。
  `pub def namePrefix(): String`
- 長い辺が maxSide 以下になるまで半分にした絵（mip の段を作るのと同じ縮め方。もう収まっていれば t のまま）。
  `pub def limitSize(maxSide: Int32, t: Texture3d): Texture3d`
- 8bit の絵の値の意味。Srgb = sRGB の曲線で書いた値（Blender の PNG・色の絵）・Linear = 値がそのまま量（法線マップ・数値の絵）。
  `pub enum ColorSpace with Eq, Order, Hash, ToString { case Srgb case Linear }`
- `pub enum TextureUse with Eq, Order, Hash, ToString { case MaterialTexture case NormalMap case Lightmap(ColorSpace) }`
- 3D の色を線形の量で計算する描き手が、使い方 textureUse の絵の段を平均する時の色空間（GL と CPU が同じ判定を使う）。
  `pub def mipSpaceOf(textureUse: TextureUse): ColorSpace`
- 色空間 space の絵の段の平均の仕方（Mip.build に渡す）。
  `pub def mipAverageOf(space: ColorSpace): Mip.Average`
- sRGB の曲線で書いた値 s（0〜1）を線形の量へ戻す（区分の式: s ≦ 0.04045 は s / 12.92、ほかは ((s + 0.055) / 1.055)^2.4）。
  `pub def srgbToLinear(s: Float64): Float64`
- 線形の量 l を sRGB の曲線の値へ（l ≦ 0.0031308 は 12.92 l、ほかは 1.055 l^(1/2.4) − 0.055）。1 を超えても同じ式で返し、負は 0。
  `pub def linearToSrgb(l: Float64): Float64`
- 色の 3 成分をそれぞれ srgbToLinear で線形の量へ戻した色（1 を超える成分も同じ式で伸ばす）。
  `pub def srgbToLinearColor(c: Color): Color`
- `pub type alias ColorLut = ColorLutData`
- 表の段の数（表の点は 0 から 1 まで lutSteps() + 1 個）。
  `pub def lutSteps(): Int32`
- srgbToLinear と linearToSrgb の表を作る（場面を描く前に 1 回）。
  `pub def colorLut(): ColorLut`
- srgbToLinear の表の版（0〜1 の外は式のまま）。
  `pub def srgbToLinearLut(lut: ColorLut, s: Float64): Float64`
- linearToSrgb の表の版（0〜1 の外は式のまま。負は 0・1 を超えても切らない）。
  `pub def linearToSrgbLut(lut: ColorLut, l: Float64): Float64`
- `pub def srgbToLinearGlsl(name: String): String`
- linearToSrgb と同じ式の GLSL の関数（float → float。負は 0・1 を超えても切らない）。
  `pub def linearToSrgbGlsl(name: String): String`

## TileLayer — `engine/src/render2d/TileLayer.flix`
- 色変調なし（白 = テクスチャの色のまま）。tint の既定値として使う。
  `pub def noTint(): Color`
- TileLayer を TileMapRenderCmd に変換する（GameEngine.render 内で使用）。
  `pub def toRenderCmd(layerScreenPos: Vec2.Vec2, tileScale: Vec2.Vec2, tileMap: TileLayer): GameEngine.TileMapRenderCmd`
- デフォルト値で TileLayer を構築するビルドヘルパー
  `pub def make(config: { tileSet = Tileset, tiles = List[TileData], collisionCells = List[Vec2.Vec2], gridSize = {x = Int32, y = Int32} }): TileLayer`
- 埋め込んだ Transform 部品を取り出す
  `pub def transform(tileMap: TileLayer): Transform`
- Transform 部品に関数を適用して差し替える
  `pub def mapTransform(f: Transform -> Transform \ ef, tileMap: TileLayer): TileLayer \ ef`
- 埋め込んだ Visual 部品を取り出す
  `pub def visual(tileMap: TileLayer): Visual`
- Visual 部品に関数を適用して差し替える
  `pub def mapVisual(f: Visual -> Visual \ ef, tileMap: TileLayer): TileLayer \ ef`
- タイル 1 マスの一辺（ピクセル）のショートカット（タイル正方形）
  `pub def tileSize(tileMap: TileLayer): Float64`
- 使用中のマス範囲を矩形で返す。position は (0,0) 固定、size は gridSize。
  `pub def usedRect(tileMap: TileLayer): { position = {x = Int32, y = Int32}, size = {x = Int32, y = Int32} }`
- マス座標 → セル中心のローカルピクセル座標（Grid.cellCenterOf と同じ決まり）。
  `pub def cellCenterOf(coords: {x = Int32, y = Int32}, tileMap: TileLayer): Vec2.Vec2`
- 指定マスのソース ID を返す。空セル（範囲外含む）: -1、壁セル: 0
  `pub def sourceIdAt(coords: {x = Int32, y = Int32}, tileMap: TileLayer): Int32`
- 範囲チェック: usedRect 内に収まるか
  `pub def isInBounds(coords: {x = Int32, y = Int32}, tileMap: TileLayer): Bool`
- 衝突セルか（sourceIdAt(coords, layer) != -1 の薄いラッパ）
  `pub def isWall(coords: {x = Int32, y = Int32}, tileMap: TileLayer): Bool`
- 範囲内 かつ 壁でない ⇒ 床
  `pub def isFloor(coords: {x = Int32, y = Int32}, tileMap: TileLayer): Bool`
- GPU リソースハンドルを設定する（tilemap loader が initTileBuffer の結果を書き込む）
  `pub def withGpuResources(tileVaoId: GpuHandle.TileVao, tileCount: Int32, tileMap: TileLayer): TileLayer`
- TileData のリストを GPU インスタンス (TileInstance) のリストに変換する。
  `pub def buildInstances(tiles: List[TileData], tileSet: Tileset, tileSize: Float64): List[GameEngine.TileInstance]`

## TileSetAtlasSource — `engine/src/render2d/Tileset.flix`
- margin/spacing のデフォルトを 0 として生成する。
  `pub def make(config: { textureName = String, marginX = Float64, marginY = Float64, spacingX = Float64, spacingY = Float64 }): TileSetAtlasSource`

## Tileset — `engine/src/render2d/Tileset.flix`
- `pub def make(source: TileSetAtlasSource): Tileset`
- タイル 1 マスの一辺（ピクセル）。本プロジェクトはタイル正方形なので Float64 単一値
  `pub def tileSize(tileSet: Tileset): Float64`

## Transform — `engine/src/render2d/Transform.flix`
- 変換なしの初期値（原点・無回転・等倍・せん断なし）。
  `pub def identity(): Transform`
- 位置を取得する
  `pub def getPosition(t: Transform): Vec2.Vec2`
- 位置を設定する
  `pub def setPosition(position: Vec2.Vec2, t: Transform): Transform`
- 回転（ラジアン）を取得する
  `pub def getRotation(t: Transform): Float64`
- 回転（ラジアン）を設定する
  `pub def setRotation(rotation: Float64, t: Transform): Transform`
- スケールを取得する
  `pub def getScale(t: Transform): Vec2.Vec2`
- スケールを設定する
  `pub def setScale(scale: Vec2.Vec2, t: Transform): Transform`
- ローカル座標系でオフセット分だけ移動する
  `pub def translate(offset: Vec2.Vec2, t: Transform): Transform`
- 現在の回転に加算する（ラジアン）
  `pub def rotate(radians: Float64, t: Transform): Transform`
- 現在のスケールにベクトルを乗算する
  `pub def applyScale(ratio: Vec2.Vec2, t: Transform): Transform`
- 指定した点への角度（ラジアン）を返す
  `pub def getAngleTo(point: Vec2.Vec2, t: Transform): Float64`
- 指定した点の方を向くように回転する
  `pub def lookAt(point: Vec2.Vec2, t: Transform): Transform`

## Transform3d — `engine/src/scene3d/Transform3d.flix`
- at = 形の原点を置く world の点・yaw / pitch / roll = 回す角（ラジアン）・pivot = 回す中心（形の座標）・scale = 軸ごとの倍率。
  `pub type alias Transform3d = { at = Vec3.Vec3, yaw = Float64, pitch = Float64, roll = Float64, pivot = Vec3.Vec3, scale = Vec3.Vec3 }`
- 回さず・等倍で at に置く。
  `pub def of(at: Vec3.Vec3): Transform3d`
- 形の座標 → world の行列。
  `pub def toMat4(t: Transform3d): Mat4.Mat4`
- 親の行列の下に子を置いた行列（親 × 子）。鎖 → 枠 → 蝋燭のように何段でも重ねられる。
  `pub def toWorld(parent: Mat4.Mat4, child: Transform3d): Mat4.Mat4`

## Triangulate — `engine/src/core/Triangulate.flix`
- 多角形を三角形に分割する。3頂点未満は空。凸なら n−2 枚（ファンと同じ枚数）。
  `pub def triangles(points: List[Vec2.Vec2]): List[(Vec2.Vec2, Vec2.Vec2, Vec2.Vec2)]`
- 符号付き面積（靴ひも公式）。正なら run が使う向き。
  `pub def signedArea(points: List[Vec2.Vec2]): Float64`

## Vec2 — `engine/src/core/Vec2.flix`
- `pub type alias Vec2 = {x = Float64, y = Float64}`
- (x, y) から Vec2 を作るリテラル短縮。`{x = …, y = …}` と同じ値だが、リスト内などで
  `pub def v2(x: Float64, y: Float64): Vec2`
- `pub def zero(): Vec2`
- `pub def one(): Vec2`
- `pub def up(): Vec2`
- `pub def down(): Vec2`
- `pub def left(): Vec2`
- `pub def right(): Vec2`
- `pub def add(a: Vec2, b: Vec2): Vec2`
- `pub def sub(a: Vec2, b: Vec2): Vec2`
- `pub def mul(v: Vec2, s: Float64): Vec2`
- `pub def div(v: Vec2, s: Float64): Vec2`
- `pub def neg(v: Vec2): Vec2`
- `pub def lengthSquared(v: Vec2): Float64`
- `pub def length(v: Vec2): Float64`
- `pub def distanceSquaredTo(a: Vec2, b: Vec2): Float64`
- `pub def distanceTo(a: Vec2, b: Vec2): Float64`
- `pub def normalized(v: Vec2): Vec2`
- `pub def dot(a: Vec2, b: Vec2): Float64`
- `pub def cross(a: Vec2, b: Vec2): Float64`
- 向き `n` の壁に `v` を映した向き（鏡写し。壁に沿う成分はそのまま、垂直成分だけ反転）。
  `pub def reflect(v: Vec2, n: Vec2): Vec2`
- 向き `n` の壁で `v` を跳ね返した向き（reflect の逆向き）。
  `pub def bounce(v: Vec2, n: Vec2): Vec2`
- `pub def angle(v: Vec2): Float64`
- `pub def angleTo(a: Vec2, b: Vec2): Float64`
- `pub def rotated(v: Vec2, phi: Float64): Vec2`
- `pub def directionTo(a: Vec2, b: Vec2): Vec2`
- `pub def clamp(v: Vec2, minV: Vec2, maxV: Vec2): Vec2`
- `pub def clampSymmetric(v: Vec2, halfExtents: Vec2): Vec2`
- `pub def moveToward(origin: Vec2, target: Vec2, delta: Float64): Vec2`
- `pub def lerp(a: Vec2, b: Vec2, t: Float64): Vec2`
- `pub def abs(v: Vec2): Vec2`
- `pub def sign(v: Vec2): Vec2`
- `pub def min(a: Vec2, b: Vec2): Vec2`
- `pub def max(a: Vec2, b: Vec2): Vec2`
- `pub def floor(v: Vec2): Vec2`
- `pub def ceil(v: Vec2): Vec2`
- `pub def round(v: Vec2): Vec2`
- `pub def isNormalized(v: Vec2): Bool`
- `pub def isZeroApprox(v: Vec2): Bool`
- `pub def limitLength(v: Vec2, maxLen: Float64): Vec2`
- `pub def projected(v: Vec2, onto: Vec2): Vec2`
- `pub def slide(v: Vec2, n: Vec2): Vec2`
- 楕円周上の点（radii は x/y の半径。t は 1 周 = 1.0・t = 0 が真上・時計回り =
  `pub def onEllipse(radii: Vec2, t: Float64): Vec2`

## Vec2i — `engine/src/core/Vec2i.flix`
- `pub def make(x: Int32, y: Int32): {x = Int32, y = Int32}`
- `pub def zero(): {x = Int32, y = Int32}`
- `pub def one(): {x = Int32, y = Int32}`
- `pub def up(): {x = Int32, y = Int32}`
- `pub def down(): {x = Int32, y = Int32}`
- `pub def left(): {x = Int32, y = Int32}`
- `pub def right(): {x = Int32, y = Int32}`
- `pub def add(a: {x = Int32, y = Int32}, b: {x = Int32, y = Int32}): {x = Int32, y = Int32}`
- `pub def sub(a: {x = Int32, y = Int32}, b: {x = Int32, y = Int32}): {x = Int32, y = Int32}`
- record の structural 同値比較
  `pub def eq(a: {x = Int32, y = Int32}, b: {x = Int32, y = Int32}): Bool`
- Int 座標 → Float64 座標
  `pub def toVec2(v: {x = Int32, y = Int32}): Vec2.Vec2`
- Float64 座標 → Int 座標 (floor 切り捨て)
  `pub def fromVec2Floor(v: Vec2.Vec2): {x = Int32, y = Int32}`

## Vec3 — `engine/src/scene3d/Vec3.flix`
- x = 東・y = 上・z = 北。
  `pub type alias Vec3 = { x = Float64, y = Float64, z = Float64 }`
- (x, y, z) から作る。リストの中などでレコードの型が決まらない所の注釈を消す。
  `pub def v3(x: Float64, y: Float64, z: Float64): Vec3`
- `pub def zero(): Vec3`
- `pub def one(): Vec3`
- `pub def add(a: Vec3, b: Vec3): Vec3`
- `pub def sub(a: Vec3, b: Vec3): Vec3`
- 長さを s 倍する。
  `pub def mul(v: Vec3, s: Float64): Vec3`
- `pub def dot(a: Vec3, b: Vec3): Float64`
- 外積。左手系では、外から見て時計回りの a → b → c について cross(b − a, c − a) が外を向く。
  `pub def cross(a: Vec3, b: Vec3): Vec3`
- `pub def length(v: Vec3): Float64`
- `pub def distanceSquared(a: Vec3, b: Vec3): Float64`
- `pub def normalized(v: Vec3): Vec3`

## Visual — `engine/src/render2d/Visual.flix`
- 既定の見た目（白で色変調なし・表示・重なり順 0）。
  `pub def default(): Visual`
- 色変調を取得する
  `pub def getColor(v: Visual): Color`
- 色変調を設定する
  `pub def setColor(color: Color, v: Visual): Visual`
- 可視性を取得する
  `pub def getVisible(v: Visual): Bool`
- 可視性を設定する
  `pub def setVisible(visible: Bool, v: Visual): Visual`
- 重なり順を取得する
  `pub def getZIndex(v: Visual): Int32`
- 重なり順を設定する
  `pub def setZIndex(zIndex: Int32, v: Visual): Visual`

## ZBand — `engine/src/core/ZBand.flix`
- 範囲 1 本の幅。範囲の中で使える z は 0..innerMax（幅 - 1）まで。
  `pub def width(): Int32`
- 範囲の中で使える z の上限。はみ出した z は clamp する（wrap しない —
  `pub def innerMax(): Int32`
- HUD の範囲の底。withHudView の絵は composeScene がここへ持ち上げる。
  `pub def hudBase(): Int32`
- エンジンデバッグの範囲の底（fps・矩形注釈・トースト・スクラブ表示）。
  `pub def debugBase(): Int32`
- hud の z を HUD の範囲へ持ち上げる（範囲内は 0..innerMax に clamp）。
  `pub def liftHud(z: Int32): Int32`
