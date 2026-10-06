<!-- engine v0.33.5 / 生成: 2026-10-07 -->
<!-- 生成物: bin/fge api-digest が作る。手で編集しない（make api-digest で作り直す） -->

# API ダイジェスト — engine

`engine/src` 配下の `pub def` / `pub enum` / `pub type alias` の一覧。索引は [api-digest.md](../api-digest.md)。

## AllocMeter — `engine/src/core/AllocMeter.flix`
- この JVM でスレッドの割り当てバイト数を読めるか。false なら測っても 0 しか返らない。
  `pub def isThreadAllocatedMemoryEnabled(): Bool`
- `body` を 1 回動かす間に今のスレッドが割り当てたバイト数。
  `pub def measureBytes(warmups: Int32, body: Unit -> a): Int64`

## Anchor — `engine/src/core/Anchor.flix`
- 文字列から Anchor を parse する。scene.json の `"anchor": "FullRect"` 等のパース用。
  `pub def fromString(s: String): Option[Anchor]`
- anchor preset と親 rect (+ 子の natural size + margin) から子の rect を計算する。
  `pub def applyAnchor(anchor: Anchor, parentRect: Rect2.Rect2, childSize: Vec2.Vec2, margin: Float64): Rect2.Rect2`

## Arc — `engine/src/render/Arc.flix`
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

## AudioStreamPlayer — `engine/src/render/AudioStreamPlayer.flix`
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

## BootFont — `engine/src/render/BootFont.flix`
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

## BootFontData — `engine/src/render/BootFontData.flix`
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

## Camera — `engine/src/render/drawable/Camera.flix`
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

## CanvasLayer — `engine/src/render/CanvasLayer.flix`
- レイヤー間の z-index ストライド。
  `pub def layerStride(): Int32`

## CollisionShape2D — `engine/src/render/CollisionShape2D.flix`
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

## DrawCmd — `engine/src/core/DrawCmd.flix`
- ピクセルの重ね方（ブレンドモード）。
  `pub enum BlendMode with Eq, Order, ToString { case Normal case Add case Multiply }`
- 角丸＋枠線スタイル。`Drawable.style = Some(..)` かつ texture="" のとき、
  `pub enum BoxStyle { case BoxStyle( Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Int32, Float64, Float64, Float64, Float64, Float64 ) }`
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

## EngineSentinel.Marker — `engine/src/EngineSentinel/Marker.flix`
- `pub enum Marker { case M }`

## GameEngine — `engine/src/GameEngine.flix`
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
  `pub type alias EngineConfig = { rootDir = String, glyphs = String, designWidth = Int32, designHeight = Int32, windowWidth = Int32, windowHeight = Int32, title = String, textureManifest = List[TextureEntry], fontManifest = List[FontEntry], soundManifest = List[AudioEntry], clearColor = Color, maxDeltaTime = Float64 }`
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
  `pub type alias AnnotationRequest = { frame = Int64, rect = Rect2.Rect2, json = String, readmeBody = String, worldDump = String, sprites = List[Drawable], tileMaps = List[TileMapRenderCmd], polygons = List[PolygonRenderCmd] }`
- タイルマップ 1 タイル分のインスタンスデータ。共有型 `DrawCmd.TileInstance`。
  `pub type alias TileInstance = DrawCmd.TileInstance`
- `pub def toDrawables(item: n, globalPos: Vec2.Vec2): List[Drawable] \ Game } pub enum Key with Eq, Order, ToString { case A case B case C case D case E case F case G case H case I case J case K case L case M case N case O case P case Q case R case S case T case U case V case W case X case Y case Z case Digit0 case Digit1 case Digit2 case Digit3 case Digit4 case Digit5 case Digit6 case Digit7 case Digit8 case Digit9 case Up case Down case Left case Right case Enter case Space case Escape case Tab case Backspace case Insert case Delete case PageUp case PageDown`
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
- ゲームエフェクト: 描画・ウィンドウ制御・時間取得・キー入力・マウス入力・フォント・
  `pub eff Game`
- zIndex 混合で sprites・tileMaps・polygons を 1 フレーム描画する。
  `pub eff Game { def renderCommands(sprites: List[Drawable], tileMaps: List[TileMapRenderCmd], polygons: List[PolygonRenderCmd], staticLayer: Option[StaticLayerCmd]): Unit }`
- タイルインスタンスデータを GPU VBO にアップロードし (vaoハンドル, count) を返す
  `pub eff Game { def initTileBuffer(instances: List[TileInstance]): (GpuHandle.TileVao, Int32) }`
- 既存のタイル VAO のインスタンス VBO へ中身を入れ直す（VAO は増やさない）。
  `pub eff Game { def updateTileBuffer(vaoId: GpuHandle.TileVao, instances: List[TileInstance]): (GpuHandle.TileVao, Int32) }`
- `pub eff Game { def shouldClose(): Bool }`
- 前フレームからの経過時間。EngineConfig#maxDeltaTime で上限クランプ済み
  `pub eff Game { def getDeltaTime(): Duration.Duration }`
- `pub eff Game { def isKeyPressed(key: Key): Bool }`
- `pub eff Game { def getMousePosition(): Vec2.Vec2 }`
- `pub eff Game { def isMouseButtonPressed(button: MouseButton): Bool }`
- 前回呼び出し以降に蓄積されたマウスホイールの y 方向 delta を返し、
  `pub eff Game { def consumeScrollDelta(): Float64 }`
- `pub eff Game { def getFontAtlas(name: String): FontAtlas }`
- アトラスにまだ無い字を、いま生成してアトラスに足す。
  `pub eff Game { def ensureGlyphs(textureName: String, codepoints: Set[Int32]): Unit }`
- `pub eff Game { def getViewportRect(): Rect2.Rect2 }`
- 指定したテクスチャ名の元画像サイズ等を取得する。
  `pub eff Game { def getTextureInfo(name: String): Option[TextureInfo] }`
- 実行時に生成した画素を、名前付きテクスチャとして使えるようにする。
  `pub eff Game { def ensureTexture(name: String, key: String, width: Int32, height: Int32, argb: Vector[Int32]): Unit }`
- マウスカーソル形状を切り替える。連続して同じ Cursor を渡しても問題ない（冪等）
  `pub eff Game { def setCursor(cursor: Cursor): Unit }`
- マウスカーソルの表示/非表示を切り替える。形状(setCursor)は「どんな絵か」、
  `pub eff Game { def setCursorVisible(visible: Bool): Unit }`
- ウィンドウ⇄ボーダーレスフルスクリーンを切り替える。フルスクリーンはプライマリ
  `pub eff Game { def setFullscreen(on: Bool): Unit }`
- 直近の setFullscreen で今フルスクリーン中かを返す
  `pub eff Game { def isFullscreen(): Bool }`
- 注釈一式（screenshot.png / highlighted.png / annotation.json / README.md）を
  `pub eff Game { def saveAnnotation(req: AnnotationRequest): Option[String] }`
- デバッグモード中であることをウィンドウタイトルで示す。
  `pub eff Game { def setDebugBadge(enabled: Bool): Unit }`
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
- macOS では -XstartOnFirstThread 付きでプロセスを再起動する。
  `pub def ensureMainThread(): Bool \ IO`

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

## InputEvent — `engine/src/render/InputEvent.flix`
- 現在押されているキーのセットを取得する（GameEngine.allKeys() を全て走査）
  `pub def currentKeys(): Set[GameEngine.Key] \ GameEngine.Game`

## JoyoKanji — `engine/src/core/JoyoKanji.flix`
- アトラスにベイクする全コードポイントを 1 行の文字列として返す。
  `pub def text(): String`

## Log — `engine/src/core/Log.flix`
- stderr へ 1 行。効果は `unsafe IO` で隠す
  `pub def warn(line: String): Unit`
- 既定値へ替えた事実を定型文で 1 行知らせる。
  `pub def fellBack(domain: String, subject: String, fallback: String, reason: String): Unit`

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

## Polygon — `engine/src/render/Polygon.flix`
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

## ProjectLoader — `engine/src/core/ProjectLoader.flix`
- project.json から組み立てた、engine 起動に渡すための設定。
  `pub type alias ProjectConfig = { rootDir = String, glyphs = String, designWidth = Int32, designHeight = Int32, windowWidth = Int32, windowHeight = Int32, title = String, textureManifest = List[{name = String, path = String, hasAlpha = Bool}], fontManifest = List[{name = String, path = String, fontSize = Float64}], soundManifest = List[{name = String, path = String, looping = Bool}], clearColor = Color, maxDeltaTime = Float64 }`
- 読み込み結果。シーンは別途 `findSceneFiles` で列挙する。
  `pub type alias Project = { rootDir = String, config = ProjectConfig }`
- project.json を読んで Project を組み立てる。
  `pub def loadProject(rootDir: String): Result[String, Project] \ {Fs.FileRead}`
- プロジェクトディレクトリを再帰的に走査して *.scene.json を列挙する。
  `pub def findSceneFiles(rootDir: String): Result[String, List[String]] \ Fs.Glob`

## Projection — `engine/src/render/drawable/Projection.flix`
- ビュー変換: screenPos = worldPos * scale - offset。
  `pub type alias ViewTransform = { offset = Vec2.Vec2, scale = Vec2.Vec2 }`
- world 座標を screen 座標に変換する: screen = world * scale - offset
  `pub def applyToWorldPos(transform: ViewTransform, worldPos: Vec2.Vec2): Vec2.Vec2`
- カメラ位置 `center` を画面中央に置く投影を作る。
  `pub def viewTransform(zoom: Vec2.Vec2, center: Vec2.Vec2, viewport: {viewportWidth = Float64, viewportHeight = Float64}): ViewTransform`

## RadialBuiltin — `engine/src/render/RadialBuiltin.flix`
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

## Rect — `engine/src/render/Rect.flix`
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

## RenderTarget — `engine/src/RenderTarget.flix`
- ターゲットを開くたびに前の中身をどう始末するかの 3 択（wgpu / Vulkan の LoadOp と同じ語彙）。
  `pub enum LoadOp { case Keep case Clear(Color) case ClearTransparent }`
- レンダーターゲットへの描画チャンネル。eff Game とは別に隔離した効果。
  `pub eff Target`
- ターゲットを開く。以降の renderCommands は画面でなくここに描かれる（swap もしない）。
  `pub eff Target { def beginTarget(name: String, width: Int32, height: Int32, clear: RenderTarget.LoadOp): Unit }`
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

## ShaderDoc — `engine/src/ShaderDoc.flix`
- 位置 (u,v) のどちらの軸を読むか。
  `pub enum Axis with Eq, ToString { case U case V }`
- Worley（セルノイズ）の出力の選び方。F2mF1 が網目（水面の目地）。
  `pub enum WorleyOut with Eq, ToString { case F1 case F2 case F2mF1 }`
- Tex がテクスチャのどのチャンネルを読むか。既定は R（明るさ・マスクの慣習）。
  `pub enum TexChan with Eq, ToString { case R case G case B case A }`
- 2 つの場を合わせる素の計算。混ぜる意図（0..1 の重み）は Blend を使い、これは生の値の合成。
  `pub enum BinOp with Eq, ToString { case Add case Sub case Mul case Min case Max case Step }`
- 1 つの場に掛ける素の関数。
  `pub enum UnOp with Eq, ToString { case Neg case Abs case Fract case Floor case Sin case Cos case Sat case OneMinus }`
- 値の場（スカラー・0..1 目安）。GPU では 1 個の float、CPU では Float64 になる。
  `pub enum Field { case Const(Float64) case Uv({ axis = Axis }) case Worley({ scale = Float64, seed = Int32, out = WorleyOut }) case Fbm({ octaves = Int32, scale = Float64, seed = Int32 }) case FbmTile({ octaves = Int32, scale = Float64, period = Vec2.Vec2, seed = Int32 }) case Smoothstep({ lo = Float64, hi = Float64, of = Field }) case Scaled({ factor = Float64, scroll = Vec2.Vec2, of = Field }) case Warp({ amount = Float64, scale = Float64, seed = Int32, of = Field }) case Mix({ a = Field, b = Field, t = Float64 }) case Blend({ a = Field, b = Field, by = Field }) case Disk({ cx = Float64, cy = Float64, radius = Float64, feather = Float64 }) case Radial({ cx = Float64, cy = Float64 }) case RadialAspect({ cx = Float64, cy = Float64, aspect = Float64 }) case Quantize({ of = Field, steps = Int32 }) case Scales({ scale = Float64, stagger = Float64 }) case Glints({ scale = Float64, rate = Float64, density = Float64, seed = Int32 }) case Ripples({ freq = Float64, amp = Float64, speed = Float64, seed = Int32 }) case Sparkle({ scale = Float64, rate = Float64, density = Float64, seed = Int32 }) case Bin({ op = BinOp, a = Field, b = Field }) case Hash1({ scale = Float64, seed = Int32, bucket = Option[Field] }) case Hash2({ scale = Float64, seed = Int32, comp = Axis, bucket = Option[Field] }) case Un({ op = UnOp, of = Field }) case Pow({ of = Field, p = Float64 }) case Time({ scale = Float64, offset = Field }) case Tiling({ tiles = Vec2.Vec2, of = Field }) case Snap({ cells = Vec2.Vec2, of = Field }) case Swirl({ cx = Float64, cy = Float64, strength = Float64, rate = Float64, of = Field }) case Angle({ cx = Float64, cy = Float64 }) case Rotate({ cx = Float64, cy = Float64, turns = Float64, rate = Float64, of = Field }) case Ref(String) case Tex({ name = String, chan = TexChan }) case Shift({ dx = Field, dy = Field, of = Field }) }`
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
- Spec が読むテクスチャ名を「bindings（前から）→ 色 → alpha」の初出順・重複なしで列挙する。
  `pub def texNames(spec: Spec): List[String]`

## ShaderEffect — `engine/src/ShaderEffect.flix`
- シェーダー面 1 枚ぶんの描画依頼。
  `pub type alias ShaderRenderCmd = { program = GpuHandle.ShaderProgram, texNames = List[String], rect = Rect2.Rect2, mask = List[List[Vec2.Vec2]], time = Float64, zIndex = Int32, blend = DrawCmd.BlendMode }`
- シェーダー面の描画チャンネル。eff Game とは別に隔離した効果。
  `pub eff Shader`
- Spec を GLSL プログラムへコンパイルしハンドルを返す（起動時/リロード時に 1 回）。
  `pub eff Shader { def buildProgram(spec: ShaderDoc.Spec): GpuHandle.ShaderProgram }`
- シェーダー面 1 枚を描く。骨格では「床タイルと壁の間の固定 z-index の範囲」へそろえて
  `pub eff Shader { def drawSurface(cmd: ShaderRenderCmd): Unit }`
- シェーダーを使わないゲーム・GL の無い環境（テスト等）向けの何もしないハンドラ。
  `pub def runNoop(f: Unit -> a \ ef + Shader): a \ ef`

## ShaderEval — `engine/src/ShaderEval.flix`
- テクスチャ 1 枚ぶんの画素（ARGB・正立・行優先）。Tex ノードが CPU 側で標本する素材。
  `pub type alias TexData = { width = Int32, height = Int32, pixels = Vector[Int32] }`
- 代表点 uv（0..1 目安）と時刻 t の最終色（Color = 0..1 の rgb）。
  `pub def evalPixel(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64): Color`
- 代表点のアルファ（Fill#alpha の場を評価）。
  `pub def evalAlpha(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64): Float64`
- evalPixel のテクスチャつき版。texEnv は名前 → 画素（pass の生成結果など）。
  `pub def evalPixelTex(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64, texEnv: Map[String, TexData]): Color`
- evalAlpha のテクスチャつき版。
  `pub def evalAlphaTex(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64, texEnv: Map[String, TexData]): Float64`
- 色とアルファを一度に返す版。bindings の先行評価（画素ごとに 1 回）を色と α で共有する —
  `pub def evalPixelAlphaTex(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64, texEnv: Map[String, TexData]): (Color, Float64)`
- 場を Float64 へ。uv は「今読むべき座標」（Scaled/Warp が差し替える）。
  `pub def evalField(field: ShaderDoc.Field, uv: Vec2.Vec2, t: Float64): Float64`

## ShaderGen — `engine/src/ShaderGen.flix`
- vertex シェーダー（面 quad 1 枚・uv を渡すだけ）。Spec に依存しない固定ソース。
  `pub def vertexSource(): String`
- ノイズ関数の固定テンプレ（hash2 / worley / fbm）。Spec に依存しないので 1 度だけ pin し、
  `pub def preludeSource(): String`
- Spec 2 つの構造比較（program キャッシュの正当性の中核）。真 ⇒ compile は純関数なので
  `pub def eqSpec(a: ShaderDoc.Spec, b: ShaderDoc.Spec): Bool`
- Spec → fragment シェーダー全体（prelude + main）。uTime uniform を前提に持つ。
  `pub def compile(spec: ShaderDoc.Spec): String`
- `pub def compileBody(spec: ShaderDoc.Spec): String`

## ShaderJson — `engine/src/ShaderJson.flix`
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

## Splash — `engine/src/render/Splash.flix`
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

## Sprite — `engine/src/render/drawable/Sprite.flix`
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
  `pub def toDrawable(sprite: Sprite, globalPos: Vec2.Vec2): GameEngine.Drawable \ GameEngine.Game`
- regionRect / hframes / vframes / frame と元テクスチャサイズから
  `pub def computeUv(sprite: Sprite, textureSize: Vec2.Vec2): {uvOffset = Vec2.Vec2, uvScale = Vec2.Vec2}`

## SpriteFrames — `engine/src/render/drawable/SpriteFrames.flix`
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

## Text — `engine/src/render/Text.flix`
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

## TileLayer — `engine/src/render/TileLayer.flix`
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

## TileSetAtlasSource — `engine/src/render/Tileset.flix`
- margin/spacing のデフォルトを 0 として生成する。
  `pub def make(config: { textureName = String, marginX = Float64, marginY = Float64, spacingX = Float64, spacingY = Float64 }): TileSetAtlasSource`

## Tileset — `engine/src/render/Tileset.flix`
- `pub def make(source: TileSetAtlasSource): Tileset`
- タイル 1 マスの一辺（ピクセル）。本プロジェクトはタイル正方形なので Float64 単一値
  `pub def tileSize(tileSet: Tileset): Float64`

## Transform — `engine/src/render/Transform.flix`
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

## Triangulate — `engine/src/core/Triangulate.flix`
- 多角形を三角形に分割する。3頂点未満は空。凸なら n−2 枚（ファンと同じ枚数）。
  `pub def triangles(points: List[Vec2.Vec2]): List[(Vec2.Vec2, Vec2.Vec2, Vec2.Vec2)]`
- 符号付き面積（靴ひも公式）。正なら run が使う向き。
  `pub def signedArea(points: List[Vec2.Vec2]): Float64`

## Vec2 — `engine/src/core/Vec2.flix`
- `pub type alias Vec2 = {x = Float64, y = Float64}`
- 平方根（pure キャスト）
  `pub def sqrt(v: Float64): Float64`
- 円周率（値の源は tau に一本化 — 2 で割るのは倍精度で正確）。
  `pub def pi(): Float64`
- 1 周ぶんの角（2π）。円周に点を置く計算の共通の源（リテラルの散在を防ぐ）。
  `pub def tau(): Float64`
- sin（pure キャスト）
  `pub def sin(x: Float64): Float64`
- cos（pure キャスト）
  `pub def cos(x: Float64): Float64`
- atan2（pure キャスト）
  `pub def atan2(y: Float64, x: Float64): Float64`
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

## Visual — `engine/src/render/Visual.flix`
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
