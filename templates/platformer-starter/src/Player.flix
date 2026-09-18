// Player — 主役の身体と「ゆるし」の状態機械。すべて純粋。
//
// プラットフォーマーの気持ちよさはほぼ全部が入力と当たりのゆるしで
// できている。ここが面倒を見るのは 3 つ:
//   コヨーテ  — 足場を離れて coyoteTime 秒はまだ跳べる(崖ぎわのジャンプがミスらない)。
//   先行入力  — 着地の jumpBufferTime 秒前までのジャンプ入力をバッファし、着地の瞬間に発火。
//   可変ジャンプ — 離した瞬間に上昇速度を cutFactor 倍へ削る(タップの頂点 = jumpTapTiles)。
// 数値は全部 MotionDoc のノブ。角の許しと落下強化は Physics 側にある。
mod Player {

    /// 主役 1 体の状態。jumping = いま可変ジャンプの上昇中(離すと 1 回だけ削る)。
    pub type alias State = {
        body = Physics.Body,
        coyote = Float64,     // 残りコヨーテ秒(接地で満タン・空中で減る)
        buffer = Float64,     // 取り置いたジャンプ入力の残り秒
        facing = Float64,     // 向き(+1 右 / -1 左)。カメラの先読みと絵の反転が読む
        jumping = Bool,
        wall = Float64        // 前 tick に押していた向きの壁に触れていたか(壁ジャンプの足場)
    }

    /// このフレームの入力(World.Input から必要な分だけ)。
    /// dash = B ダッシュ(押しっぱなしで最高速が上がる)。`run` は Flix の予約語なので使えない。
    pub type alias Input = { dir = Float64, jumpHeld = Bool, jumpPressed = Bool,
                             drop = Bool, dash = Bool }

    pub def initial(pos: Vec2.Vec2): State =
        { body = { pos = pos, vel = Vec2.zero(), onGround = false },
          coyote = 0.0, buffer = 0.0, facing = 1.0, jumping = false, wall = 0.0 }

    /// 1 tick 進める。地形 t は呼び手(World)が組む — 消える床も動く床の乗り心地も
    /// ここからは同じ「地形」に見える。
    pub def step(t: Physics.Terrain, md: MotionDoc.Doc, dt: Float64,
                 input: Input, p: State): State =
        let m = MotionDoc.rec(md);
        let buffer = if (input#jumpPressed) m#jumpBufferTime
                     else Float64.max(0.0, p#buffer - dt);
        let coyote = if (p#body#onGround) m#coyoteTime
                     else Float64.max(0.0, p#coyote - dt);
        let canJump = p#body#onGround or coyote > 0.0;
        // 壁ジャンプ(motion.json の wallJump で開放): 空中で壁に押し当てている間だけ、
        // 反対向きへ蹴りながら跳ぶ。地上のジャンプが優先。
        let onWall = m#wallJump and not canJump and p#wall != 0.0
                     and input#dir * p#wall > 0.0;
        let (vy0, buffer1, coyote1, jumping1) =
            if (buffer > 0.0 and (canJump or onWall))
                (Physics.jumpVelocity(md), 0.0, 0.0, true)
            else (p#body#vel#y, buffer, coyote, p#jumping);
        let kick = if (buffer > 0.0 and onWall and not canJump)
                   Some(-p#wall * Physics.topSpeed(md, input#dash)) else None;
        // 可変ジャンプ: 上昇中に離したら 1 回だけ削る。
        let (vy1, jumping2) =
            if (jumping1 and not input#jumpHeld and vy0 < 0.0)
                (vy0 * Physics.cutFactor(md), false)
            else if (vy0 >= 0.0) (vy0, false)
            else (vy0, jumping1);
        let vx0 = Option.getWithDefault(p#body#vel#x, kick);
        let body0 = { vel = { x = vx0, y = vy1 } | p#body };
        // 壁を蹴った tick は入力方向を無視する — 壁へ押しっぱなしのまま
        // 蹴っても離れられるように(これが無いと壁に貼り付いて落ちるだけになる)。
        let moveDir = if (Option.isEmpty(kick)) input#dir else -p#wall;
        let stepped = Physics.stepBody(t, md, dt, moveDir, input#drop, input#dash, body0);
        { body = stepped#body,
          coyote = coyote1,
          buffer = buffer1,
          facing = if (input#dir > 0.0) 1.0 else if (input#dir < 0.0) -1.0 else p#facing,
          jumping = jumping2,
          wall = stepped#wall }

    /// 上向きの初速を直接与える(バネ・踏みつけバウンド)。コヨーテとバッファは消費する。
    pub def launch(vy: Float64, p: State): State =
        { body = { vel = { y = vy | p#body#vel } | p#body },
          coyote = 0.0, buffer = 0.0, facing = p#facing, jumping = false, wall = 0.0 }

    /// 当たり箱(px 矩形)。
    pub def rectOf(p: State): Rect2.Rect2 =
        let half = Vec2.mul(Physics.playerSize(), 0.5);
        { position = Vec2.sub(p#body#pos, half), size = Physics.playerSize() }
}
