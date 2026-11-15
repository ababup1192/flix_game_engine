# 書き味の見本: GPU の物の寿命の持ち主（9.1 の表「GPU の物の寿命の持ち主」・親 5.3）

- 比べた物は 2D の描き先（Pass の render target・その history・開いている描き先・最後に画面へ描いたコマ）。R1b ⇄ P6 の最初の小分けの範囲。
  形・タイル・static layer・シェーダーの寿命は、それぞれの小分け（多角形とタイルと static layer・面・R2b）で同じ形に載せる。
- 候補 (a) は入れた形（`render_gl/src/RenderPaint/Internal/TargetTable.flix`）から写した。候補 (b) は入れる前の main（`efbd707d`）の形で、テストは実際に書いて通した（`render_gl` のテスト 337 本と一緒に緑。commit していない）。
- 速さは比べない: 表を引くのは Pass を開く時と描き先の名前を引く時だけで、1 体ごとに通る所（`emitSprite` など）は触らない。sprite_stress の前後は人の方針で計画の最後にまとめて測る。

## 数（行数は doc のコメントを含む・2026-11-15）

| 見る点 | (a) 表は前半・作る消すだけ backend | (b) 全部 backend（入れる前の形） |
|---|---|---|
| GL の backend | 46 行（`beginTarget` 3・`glTargets` 11・`destroyEntry` 7・`entryOf` 3・`prepareHistory` 14・`endTarget` 3 ほか） | 75 行（`beginTarget` 23・`sameShape` と `sameTexture` 8・`dropHistory` 11・`prepareHistory` 26・`endTarget` 7） |
| WebGPU の backend | 17 行（`beginTarget` 5・`webGpuTargets` 3・`createTargetSlot` 7）。history は表が持つので、写す所（`copyTextureToTexture`）を足すだけになる | 20 行（`beginTarget` 18・`TargetSlot` 2）。history は無く、足すと GL の `prepareHistory`・`dropHistory`・作り直しの鍵の 2 本目（約 45 行）が要る |
| 共有の前半 | `TargetTable` 119 行（作り直しの鍵・history の作り直しと捨て方・絵の表への載せ方・開いている描き先・最後のコマ） | 無し |
| 寿命のテスト | GPU を呼ばない `Targets` で 7 本・111 行（作る回数・捨てる順・標本の数・history の使い回しと捨て方・絵の表の大きさ）。GL と WebGPU の両方の振る舞いを 1 回で固定する | GL は偽の GL（`Proxy` で `createFramebuffer` を数える 20 行）と `RenderPaint.create` 一式で 1 本 42 行。WebGPU は Dawn の device を開くテスト（`TestWebGpuOffscreen` の形）が要る。history は GL の blit を数える偽物を足さないと見られない |
| 片方だけ直す事故 | 起きない（鍵と捨てる順は 1 か所） | 起きる（入れる前、GL は作り直しで history を捨て、WebGPU は history を持たなかった） |

## 候補 (a): 表は前半・作る消すだけ backend（入れた形）

```flix
// backend が渡すのは「作る・捨てる」の 2 つだけ。番号は名前で引く絵の番号と同じ（GL は色のテクスチャ・WebGPU は slots の番号）。
def webGpuTargets(paint: Paint): TargetTable.Targets =
    { create = spec -> createTargetSlot(paint, spec), destroy = id -> dropSlot(paint, id) }

def beginTarget(paint: Paint, spec: RenderTarget.TargetSpec): Unit \ IO =
    let PaintData.PaintData(p) = paint;
    discard TargetTable.begin(webGpuTargets(paint), textureTables(paint), p#targets, (p#designW, p#designH), spec)

// 描く時は表の行から自分の物を引く。
def paintTarget(paint: Paint, spec: RenderTarget.TargetSpec, sprites: List[RenderType.Drawable]): Unit \ IO =
    let PaintData.PaintData(p) = paint;
    TargetTable.rowByName(p#targets, spec#name)
        |> Option.flatMap(row -> Map.get(row#texture, Ref.get(p#slots)) |> Option.map(slot -> (row, slot)))
        |> Option.forEach(match (row, slot) -> paintInto(paint, slot#texture, passOf(row, spec), sprites))

// テスト: GPU を呼ばない Targets で、表の決まりを backend と別に固定する。
@Test
def testSizeChangeDestroysThenCreates(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = "create fx 64x64 s1" :: "destroy 101" :: "create fx 32x32 s1" :: Nil, callsOf(64 :: 32 :: Nil))
```

## 候補 (b): 全部 backend（入れる前の形）

```flix
// backend ごとに名前 → 自分の物の表を持ち、作り直しの鍵・history・絵の表への載せ方を 2 本書く。
def beginTarget(paint: Paint, spec: RenderTarget.TargetSpec): Unit \ IO =
    let PaintData.PaintData(p) = paint;
    let slot = match Map.get(spec#name, Ref.get(p#targetsRef)) {
        case Some(t) if t#width == spec#width and t#height == spec#height and t#format == spec#format => t
        case old =>
            Option.forEach(t -> dropSlot(paint, t#id), old);      // GL はここで history も捨てる。WebGPU は捨てない（history が無い）
            let texture = p#gpu.createTexture("fge pass ${spec#name}", spec#width, spec#height, textureFormatOf(spec#format), usage(), 1, 1);
            let fresh = { id = addSlot(paint, texture, p#nearestClamp, spec#width, spec#height), texture = texture, format = spec#format,
                          width = spec#width, height = spec#height };
            Ref.put(Map.insert(spec#name, fresh, Ref.get(p#targetsRef)), p#targetsRef);
            fresh
    };
    putTexture(spec#name, { id = GpuHandle.wrapTextureId(slot#id), width = p#designW, height = p#designH }, paint);  // GL にも同じ行
    Array.put(Some(spec), 0, p#activeTarget)

// テスト: 偽の GL（Proxy で createFramebuffer を数える 20 行）と RenderPaint.create 一式を組んでから
@Test
def testSameShapeCreatesOnceThenSizeChangeDeletes(): Unit \ {Assert, IO} =
    let log = Ref.fresh(Static, Nil);
    let gl = countingGl(log);
    let paint = RenderPaint.create(gl, { designWidth = 320, designHeight = 240, clearColor = black(), screenFramebuffer = 0,
                                         scene3d = Scene3dRenderer.none(), gpuTimer = RenderPaint.noFrameTimer() });
    Ref.put(Nil, log);
    List.forEach(w -> { RenderPaint.beginTarget(gl, paint, spec(w)); RenderPaint.endTarget(gl, paint) }, 64 :: 64 :: 32 :: Nil);
    Assert.assertEq(expected = "createFramebuffer" :: "deleteFramebuffer" :: "createFramebuffer" :: Nil, List.reverse(Ref.get(log)))
```

## 決めた事

**(a)**。backend の行は GL 75 → 46・WebGPU は history を足す時の約 45 行が要らなくなり、寿命の決まりを GPU 無しで 7 本のテストに固定できた。
(b) の良い所（backend が自分の物を 1 つの Map で直に引ける）は、(a) でも「表の番号 → 自分の物」の Map を 1 回引くだけで、差は 1 行。
予算・捨てる順・preload を持つ物（3D の形・シェーダー）も、同じ `Targets` の形（作る・捨てる）に「中身を書く」を足して載せる見込み（R2b の寿命の表）。
