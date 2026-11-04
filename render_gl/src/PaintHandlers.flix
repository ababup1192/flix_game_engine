// RenderPaintHandlers — 塗りのコア（RenderPaint）で受ける Platform の描く effect・GPU の資源・診断・RenderTarget.Target の handler。
// ウィンドウありの描き手（LwjglLayer）とウィンドウなしの描き手（GlOffscreen）が同じ物を重ねて使う（画面の大きさの読み方と、画面へ塗ったコマの始末を引数で渡す）。
//
// WhyNot Draw2d・Draw3d・GpuResources を 1 つの handler にまとめない: op を 1 つ足した時に止まる handler を、その effect の物だけにする。
// 代わりに、積む op（drawSurface・drawScene3d）と出す op（renderCommands）が分け合う状態はどれも同じ paint に置くので、
// 3 つには同じ paint を渡す（Platform の頭の「同じ handler の組から張る」）。

mod RenderPaintHandlers {
    import fge.gl.GlContext
    import java.lang.System

    /// GPU の資源（タイルのバッファ・テクスチャ・字・シェーダーのプログラム）を paint の登録簿で受ける。
    pub def handleGpuResources(gl: GlContext, paint: RenderPaint.Paint, fonts: RenderPaint.Fonts, f: Unit -> a \ ef): a \ (ef - Platform.GpuResources) + IO =
        run f() with handler Platform.GpuResources {
            def initTileBuffer(instances, k) = k(RenderPaint.initTileBuffer(gl, paint, instances))
            def updateTileBuffer(vaoId, instances, k) = k(RenderPaint.updateTileBuffer(gl, paint, vaoId, instances))
            def ensureTexture(name, key, width, height, argb, k) = {
                RenderPaint.ensureTexture(gl, paint, name, key, width, height, argb);
                k(())
            }
            def ensureGlyphs(textureName, codepoints, k) = {
                RenderPaint.ensureGlyphs(gl, fonts, textureName, codepoints);
                if (Set.isEmpty(codepoints)) ()
                else RenderPaint.noteDiagnostics(paint, d -> { glyphsAdded = d#glyphsAdded + Set.size(codepoints) | d });
                k(())
            }
            def getFontAtlas(name, k) = k(RenderPaint.fontAtlas(fonts, name))
            def getTextureInfo(name, k) = k(RenderPaint.textureInfo(paint, name))
            def buildProgram(spec, k) = k(RenderPaint.buildProgram(gl, paint, spec))
        }

    /// 2D の描き物の列を paint で塗る。framebufferSize = 今の描き先の画素の大きさ。
    /// onScreen = 画面（レンダーターゲットの外）へ塗った時に、塗りの始まりと終わりの時刻（System.nanoTime）を受け取る。
    pub def handleDraw2d(gl: GlContext, paint: RenderPaint.Paint, framebufferSize: Unit -> (Int32, Int32) \ fx,
                         onScreen: (Int64, Int64) -> Unit \ fx, f: Unit -> a \ ef): a \ (ef - Platform.Draw2d) + fx + IO =
        run f() with handler Platform.Draw2d {
            def renderCommands(sprites, tileMaps, polygons, staticLayer, k) = {
                let (fbW, fbH) = framebufferSize();
                let paintFrom = System.nanoTime();
                let toScreen = RenderPaint.submitFrame(gl, paint, fbW, fbH, sprites, tileMaps, polygons, staticLayer);
                let paintTo = System.nanoTime();
                RenderPaint.noteFrame(paint, paintTo - paintFrom, 0i64,
                    () -> List.length(sprites) + List.length(polygons) + List.length(tileMaps));
                if (toScreen) onScreen(paintFrom, paintTo) else ();
                k(())
            }
            def drawSurface(cmd, k) = {
                RenderPaint.queueSurface(paint, cmd);
                k(())
            }
        }

    /// 3D の場面を paint の列へ積む（出すのは同じ paint の Draw2d.renderCommands）。
    pub def handleDraw3d(paint: RenderPaint.Paint, f: Unit -> a \ ef): a \ (ef - Platform.Draw3d) + IO =
        run f() with handler Platform.Draw3d {
            def drawScene3d(cmd, k) = {
                RenderPaint.queueScene3d(paint, cmd);
                k(())
            }
        }

    /// 1 コマごとの描く側の診断を paint で集める。
    pub def handleDiagnostics(paint: RenderPaint.Paint, f: Unit -> a \ ef): a \ (ef - Platform.Diagnostics) + IO =
        run f() with handler Platform.Diagnostics {
            def setDiagnosticsEnabled(on, k) = {
                RenderPaint.setDiagnosticsEnabled(paint, on);
                k(())
            }
            def consumeDiagnostics(k) = k(RenderPaint.consumeDiagnostics(paint))
        }

    /// レンダーターゲットの切り替えを paint で受ける。framebufferSize は handleDraw2d と同じ（画素の倍率を出す元）。
    pub def handleTarget(gl: GlContext, paint: RenderPaint.Paint, framebufferSize: Unit -> (Int32, Int32) \ fx,
                         f: Unit -> a \ ef): a \ (ef - RenderTarget.Target) + fx + IO =
        run f() with handler RenderTarget.Target {
            def beginTarget(spec, k) = {
                RenderPaint.beginTarget(gl, paint, spec);
                k(())
            }
            def endTarget(k) = {
                RenderPaint.endTarget(gl, paint);
                k(())
            }
            def pixelScale(k) = {
                let (fbW, fbH) = framebufferSize();
                k(RenderPaint.pixelScaleOf(paint, fbW, fbH))
            }
        }
}
