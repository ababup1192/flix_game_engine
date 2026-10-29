// BattleScenes — 正面の戦闘の場面（コマンド選択・呪文・ボス）を描き出し用に組む。
// 上に仲間の HP / MP のウィンドウ、その下に背景の帯と敵、下にコマンドと敵の一覧（か会話）のウィンドウ。
mod BattleScenes {
    use fge::{Rect2, Render, Vec2}
    use Sheet.SheetId

    type alias Env = WindowView.Env

    def zBack(): Int32 = 0
    def zFoe(): Int32 = 2
    def zWindow(): Int32 = 10

    /// 背景の帯の上端と、敵の足元をそろえる線（px）。
    def bandTop(): Float64 = 72.0
    def footY(): Float64 = 132.0

    /// 敵 1 体: rpg.monsters.sprite.json の絵の名前・仮の四角の色と大きさ・横の真ん中・足元からの浮き。
    type alias Foe = { sprite = String, placeholder = String, size = Vec2.Vec2, centerX = Float64, lift = Float64 }

    def boss(): Foe = { sprite = "boss", placeholder = "fc13", size = { x = 96.0, y = 96.0 }, centerX = 128.0, lift = -28.0 }

    def foePart(foe: Foe): Sheet.Part =
        Sheet.cycling(SheetId.Monsters, foe#sprite, 2.0, foe#placeholder, foe#size)

    /// 敵の左上（足元を footY に、横を centerX にそろえる）。
    def foeAt(env: Env, foe: Foe): Vec2.Vec2 =
        let size = Sheet.sizeOf(env#res#sheets, foePart(foe));
        { x = Float64.floor(foe#centerX - size#x / 2.0), y = footY() - foe#lift - size#y }

    def foeDrawn(env: Env, foe: Foe): List[Render.PlacedItem] =
        Sheet.draw(env#res#sheets, env#res#palette, env#t, { part = foePart(foe), at = foeAt(env, foe), z = zFoe() })

    /// 背景の帯（256 × 64）。
    def band(env: Env, sprite: String, placeholder: String): List[Render.PlacedItem] =
        Sheet.draw(env#res#sheets, env#res#palette, env#t,
            { part = Sheet.cycling(SheetId.BattleFx, sprite, 2.0, placeholder, { x = 256.0, y = 64.0 }),
              at = { x = 0.0, y = bandTop() }, z = zBack() })

    /// 仲間 3 人の HP / MP のウィンドウ（画面の上）。
    def partyStatus(env: Env): List[Render.PlacedItem] =
        let rect = WindowView.grid({ col = 1, row = 1, cols = 30, rows = 7 });
        let members = ("ルカ", "32", "10") :: ("ミナ", "41", "0") :: ("トト", "22", "18") :: Nil;
        let columns = members |> List.zipWithIndex |> List.flatMap(entry -> {
            let (i, (name, hp, mp)) = entry;
            let x = rect#position#x + 16.0 + Int32.toFloat64(i) * 78.0;
            let y = i2 -> WindowView.lineAt(rect, i2)#y;
            WindowView.label(env, name, { x = x, y = y(0) }, zWindow()) ::
            WindowView.labelIn(env, "fc31", "HP", { x = x, y = y(1) }, zWindow()) ::
            WindowView.label(env, hp, { x = x + 22.0, y = y(1) }, zWindow()) ::
            WindowView.labelIn(env, "fc31", "MP", { x = x, y = y(2) }, zWindow()) ::
            WindowView.label(env, mp, { x = x + 22.0, y = y(2) }, zWindow()) :: Nil
        });
        List.append(WindowView.frame(env, rect, zWindow()), columns)

    /// ボス戦: 地底湖の帯・大きな水晶喰らいの大トカゲ・「ジェムイーターが あらわれた！」。
    pub def bossFight(env: Env): List[Render.PlacedItem] =
        let rect = WindowView.grid({ col = 1, row = 20, cols = 30, rows = 8 });
        List.flatten(
            band(env, "bg_lake", "fc02") ::
            foeDrawn(env, boss()) ::
            partyStatus(env) ::
            WindowView.message(env, rect, "ジェムイーターが あらわれた！" :: Nil, true, zWindow()) ::
            Nil)
}
