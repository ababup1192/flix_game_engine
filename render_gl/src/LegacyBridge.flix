// RenderLegacyBridge — Platform の役割ごとの effect の op を、LwjglLayer と GlOffscreen の handler が
// まだ 1 つで受けている GameEngine.Game・ShaderEffect.Shader の op へそのまま回す。
// WhyNot engine（Platform）に置かない: 契約層が古い effect に寄りかかり、ゲームが呼べる口にもなる。

mod RenderLegacyBridge {

    /// forward が受け持つ effect の束（GlOffscreen.handle・GpuShot の型の差に使う）。
    pub type alias Bridged = Platform.Input + Platform.Window + Platform.FrameClock + Platform.Rendering
                             + Platform.Diagnostics + Platform.Annotation

    // WhyNot 並びを変えない: op は内側の handler から順にたどるので、sprite ごとに呼ぶ GpuResources と
    // 毎コマ読む Input を内側に置く。
    pub def forward(f: Unit -> a \ ef): a \ (ef - Bridged) + GameEngine.Game + ShaderEffect.Shader =
        run f() with handler Platform.GpuResources {
            def initTileBuffer(xs, k)        = k(GameEngine.Game.initTileBuffer(xs))
            def updateTileBuffer(v, xs, k)   = k(GameEngine.Game.updateTileBuffer(v, xs))
            def ensureTexture(n, key, w, h, argb, k) = k(GameEngine.Game.ensureTexture(n, key, w, h, argb))
            def ensureGlyphs(n, cps, k)      = k(GameEngine.Game.ensureGlyphs(n, cps))
            def getFontAtlas(n, k)           = k(GameEngine.Game.getFontAtlas(n))
            def getTextureInfo(n, k)         = k(GameEngine.Game.getTextureInfo(n))
            def buildProgram(spec, k)        = k(ShaderEffect.Shader.buildProgram(spec))
        } with handler Platform.Input {
            def isKeyPressed(key, k)         = k(GameEngine.Game.isKeyPressed(key))
            def getMousePosition(k)          = k(GameEngine.Game.getMousePosition())
            def isMouseButtonPressed(b, k)   = k(GameEngine.Game.isMouseButtonPressed(b))
            def isGamepadTouched(k)          = k(GameEngine.Game.isGamepadTouched())
            def gamepadKind(k)               = k(GameEngine.Game.gamepadKind())
            def consumeScrollDelta(k)        = k(GameEngine.Game.consumeScrollDelta())
            def consumeMouseDelta(k)         = k(GameEngine.Game.consumeMouseDelta())
            def isWindowFocused(k)           = k(GameEngine.Game.isWindowFocused())
        } with handler Platform.Draw2d {
            def renderCommands(s, t, p, l, k) = k(GameEngine.Game.renderCommands(s, t, p, l))
            def drawSurface(cmd, k)          = k(ShaderEffect.Shader.drawSurface(cmd))
        } with handler Platform.Window {
            def shouldClose(k)               = k(GameEngine.Game.shouldClose())
            def setShouldClose(c, k)         = k(GameEngine.Game.setShouldClose(c))
            def getViewportRect(k)           = k(GameEngine.Game.getViewportRect())
            def setCursor(c, k)              = k(GameEngine.Game.setCursor(c))
            def setCursorVisible(v, k)       = k(GameEngine.Game.setCursorVisible(v))
            def setMouseCaptured(c, k)       = k(GameEngine.Game.setMouseCaptured(c))
            def setFullscreen(on, k)         = k(GameEngine.Game.setFullscreen(on))
            def isFullscreen(k)              = k(GameEngine.Game.isFullscreen())
            def setDebugBadge(on, k)         = k(GameEngine.Game.setDebugBadge(on))
        } with handler Platform.FrameClock {
            def getDeltaTime(k)              = k(GameEngine.Game.getDeltaTime())
        } with handler Platform.Draw3d {
            def drawScene3d(cmd, k)          = k(ShaderEffect.Shader.drawScene3d(cmd))
        } with handler Platform.Diagnostics {
            def setDiagnosticsEnabled(on, k) = k(GameEngine.Game.setDiagnosticsEnabled(on))
            def consumeDiagnostics(k)        = k(GameEngine.Game.consumeDiagnostics())
        } with handler Platform.Annotation {
            def saveAnnotation(req, k)       = k(GameEngine.Game.saveAnnotation(req))
        }
}
