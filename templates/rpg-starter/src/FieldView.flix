// FieldView — 見下ろしの画面の共通部: マスを px にする・人を立たせる。
mod FieldView {
    use fge::{Dir4, Grid, Render, Vec2}
    use Sheet.SheetId

    /// タイル 1 枚の大きさ（px）。人も同じ 16×16。
    pub def tile(): Float64 = Autotile.tile()

    /// 人の向き。コマ名の頭（down_0 の down）になる。
    pub enum Facing with Eq { case Down case Up case Left case Right }

    /// 規則の向きから絵の向きへ。
    pub def facingOf(d: Dir4.Dir4): Facing = match d {
        case Dir4.Dir4.Down  => Facing.Down
        case Dir4.Dir4.Up    => Facing.Up
        case Dir4.Dir4.Left  => Facing.Left
        case Dir4.Dir4.Right => Facing.Right
    }

    def facingName(facing: Facing): String = match facing {
        case Facing.Down  => "down"
        case Facing.Up    => "up"
        case Facing.Left  => "left"
        case Facing.Right => "right"
    }

    /// 升目の位置（列・行。半升も書ける）→ px。
    def cellAt(col: Float64, row: Float64): Vec2.Vec2 = { x = col * tile(), y = row * tile() }

    /// マス → そのマスの左上の px。規則のマス（Grid.Cell）を画面の px にするのはここだけ。
    pub def cellPx(cell: Grid.Cell): Vec2.Vec2 = cellAt(Int32.toFloat64(cell#x), Int32.toFloat64(cell#y))

    /// 人（rpg.chars.sprite.json の 1 人）を、マスの左上が cell（歩きの途中のずれを含む）の所に立たせる。
    /// 人の anchor は足元の中央なので、マスの下端の中央に合わせる。歩きの 2 コマは時刻 t で選ぶ。
    /// placeholder は絵が無い時の仮の四角の色（人ごとに変えて、誰がどこにいるか見分ける）。
    pub def personAt(env: WindowView.Env, spec: { who = String, facing = Facing, placeholder = String },
                     cell: Vec2.Vec2, z: Int32): List[Render.PlacedItem] =
        let step = Float64.floor(env#t * 2.0) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let frame = "${facingName(spec#facing)}_${Int32.modulo(step, 2)}";
        Sheet.drawAnchored(env#res#sheets, env#res#palette, env#t,
            { part = Sheet.part(SheetId.Chars, spec#who, frame, spec#placeholder, { x = tile(), y = tile() }),
              at = { x = cell#x + tile() / 2.0, y = cell#y + tile() - 1.0 }, z = z })
}
