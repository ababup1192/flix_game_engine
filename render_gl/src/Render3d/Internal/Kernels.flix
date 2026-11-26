// Render3d.Internal.Kernels — プリセットの kernel の WGSL の字と binding の表（群れ: count → 3 つの scan → scatter → 規則・総当たり・pack）。
// 式は engine の Simulation3d.Internal.Cpu と同じ（GPU と CPU は許し幅で合い、同じ GPU の中では格子と総当たりがバイトで合う）。

/// kernel の字と binding の並び・1 刻みの値の uniform の並び。ゲームからは呼ばない。
/// 1 刻み: count（セルへ数える）→ scanBlocks・scanSums・scanAdd（セルの始まり。scanAdd が cellCount を 0 に戻す）→
/// scatter（状態をセルの順へ写す）→ rulesGrid（規則・出口は要素の番号の位置）。出口の 1 体ごとの値は pack。
// WhyNot: ShaderAst の木で書かない — compute の入口・atomic・配列の型が ShaderAst の pub の enum に無く、足すと描き手の網羅の match に当たる。
// WhyNot: 刻みの頭で clearBuffer を使わない — 刻みごとに pass を閉じて開き直すことになり、1 コマ 4 刻み・作り直しの数百刻みが 1 つの pass に積めない。
pub mod Render3d.Internal.Kernels {
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use Render3d.Internal.Compute.{Access, Kernel}
    use Simulation3d.Internal.{FlockParams, PresetRules}

    /// セルの数の上限（32³）。buffer の大きさと scan の段の数はこの数で決める。
    pub def maxCells(): Int32 = 32768

    /// scan の 1 workgroup が受け持つセルの数（64 本 × 4 個）。
    pub def scanBlock(): Int32 = 256

    pub def scanBlocks(): Int32 = maxCells() / scanBlock()

    /// 1 刻みの値の uniform のバイト数（WGSL の Params）。
    pub def paramsBytes(): Int32 = 112

    /// 群れの kernel の種類。
    pub enum FlockKernel with Eq, Order, ToString {
        case Count
        case ScanBlocks
        case ScanSums
        case ScanAdd
        case Scatter
        case RulesGrid
        case RulesBrute
        case Pack
    }

    /// binding 1 つ: WGSL の名前・種類・型。
    type alias Binding = { name = String, access = Access, wgslType = String }

    def bindingOf(name: String, access: Access, wgslType: String): Binding = { name = name, access = access, wgslType = wgslType }

    def declOf(index: Int32, x: Binding): String =
        let space = match x#access {
            case Access.Uniform   => "uniform"
            case Access.ReadOnly  => "storage, read"
            case Access.ReadWrite => "storage, read_write"
        };
        "@group(0) @binding(${index}) var<${space}> ${x#name}: ${x#wgslType};"

    def kernelOf(name: String, bindings: List[Binding], parts: List[List[String]]): Kernel =
        let all = bindingOf("params", Access.Uniform, "Params") :: bindings;
        { name = name, bindings = List.map(x -> x#access, all),
          source = lazy String.unlines(List.flatten(common() :: (List.zipWithIndex(all) |> List.map(p -> declOf(fst(p), snd(p)))) :: parts)) }

    def boids(name: String, access: Access): Binding = bindingOf(name, access, "array<Boid>")

    def words(name: String, access: Access): Binding = bindingOf(name, access, "array<u32>")

    /// 群れの kernel 1 本。
    pub def flockKernelOf(kind: FlockKernel): Kernel = match kind {
        case FlockKernel.Count => kernelOf("fge flock count",
            boids("stateIn", Access.ReadOnly) :: bindingOf("cellCount", Access.ReadWrite, "array<atomic<u32>>") ::
            bindingOf("cellSlot", Access.ReadWrite, "array<vec2u>") :: Nil,
            countBody() :: Nil)
        case FlockKernel.ScanBlocks => kernelOf("fge flock scan blocks",
            words("cellCount", Access.ReadOnly) :: words("cellStart", Access.ReadWrite) :: words("blockSums", Access.ReadWrite) :: Nil,
            scan64() :: scanBlocksBody() :: Nil)
        case FlockKernel.ScanSums => kernelOf("fge flock scan sums",
            words("blockSums", Access.ReadWrite) :: Nil,
            scan64() :: scanSumsBody() :: Nil)
        case FlockKernel.ScanAdd => kernelOf("fge flock scan add",
            words("cellStart", Access.ReadWrite) :: words("blockSums", Access.ReadOnly) :: words("cellCount", Access.ReadWrite) :: Nil,
            scanAddBody() :: Nil)
        case FlockKernel.Scatter => kernelOf("fge flock scatter",
            boids("stateIn", Access.ReadOnly) :: bindingOf("cellSlot", Access.ReadOnly, "array<vec2u>") :: words("cellStart", Access.ReadOnly) ::
            boids("sortedState", Access.ReadWrite) :: words("sortedId", Access.ReadWrite) :: Nil,
            scatterBody() :: Nil)
        case FlockKernel.RulesGrid => kernelOf("fge flock rules grid",
            boids("sortedState", Access.ReadOnly) :: words("sortedId", Access.ReadOnly) :: words("cellStart", Access.ReadOnly) ::
            boids("stateOut", Access.ReadWrite) :: Nil,
            pairTerms() :: rulesGridBody() :: Nil)
        case FlockKernel.RulesBrute => kernelOf("fge flock rules brute",
            boids("stateIn", Access.ReadOnly) :: boids("stateOut", Access.ReadWrite) :: Nil,
            pairTerms() :: rulesBruteBody() :: Nil)
        case FlockKernel.Pack => kernelOf("fge flock pack",
            boids("stateIn", Access.ReadOnly) :: bindingOf("instances", Access.ReadWrite, "array<f32>") :: Nil,
            packBody() :: Nil)
    }

    /// プリセットが使う kernel の全部（描き手を作る時に先に作る物）。
    pub def kernelsOf(rules: PresetRules): List[Kernel] = match rules {
        case PresetRules.Flock(_) =>
            (FlockKernel.Count :: FlockKernel.ScanBlocks :: FlockKernel.ScanSums :: FlockKernel.ScanAdd :: FlockKernel.Scatter ::
             FlockKernel.RulesGrid :: FlockKernel.Pack :: Nil) |> List.map(flockKernelOf)
    }

    /// 1 刻みの値 p と、出口に書く emissionIntensity を、WGSL の Params の並びのバイトにする。
    pub def flockParamsBytes(p: FlockParams, emission: Float64): ByteBuffer \ IO =
        let buf = ByteBuffer.allocateDirect(paramsBytes()).order(ByteOrder.LITTLE_ENDIAN);
        let f = (at: Int32, v: Float32) -> discard buf.putFloat(at, v);
        let i = (at: Int32, v: Int32) -> discard buf.putInt(at, v);
        i(0, p#count); i(4, p#gx); i(8, p#gy); i(12, p#gz);
        f(16, p#lo#x); f(20, p#lo#y); f(24, p#lo#z); f(28, p#dt);
        f(32, p#hi#x); f(36, p#hi#y); f(40, p#hi#z); f(44, p#neighborRadius);
        f(48, p#cellSize#x); f(52, p#cellSize#y); f(56, p#cellSize#z); f(60, p#separationRadius);
        let target = p#target |> Option.getWithDefault({ x = 0.0f32, y = 0.0f32, z = 0.0f32 });
        f(64, target#x); f(68, target#y); f(72, target#z); f(76, p#targetWeight);
        f(80, p#cohesion); f(84, p#alignment); f(88, p#separation); f(92, p#maxSpeed);
        f(96, p#maxForce); f(100, p#margin); i(104, if (Option.nonEmpty(p#target)) 1 else 0); f(108, Float64.truncateToFloat32(emission));
        buf

    // ── 出口の 1 体ごとの値 ──

    /// 1 体ごとの値の欄（Render3d.InstanceValues の 32 float の並びの意味）。
    pub enum InstanceField with Eq, ToString {
        case WorldColumn(Int32)
        case NormalColumn(Int32)
        case Emission
        case PoseRow
        case Tint
    }

    /// 欄の頭の float の番号（Render3d.InstanceValues の頭の約束: 0〜3 組 = world の列・4〜6 組 = 法線の行列の列・4 組の w = emission・5 組の w = 姿勢の行・7 組 = tint）。
    pub def instanceOffsetOf(f: InstanceField): Int32 = match f {
        case InstanceField.WorldColumn(c)  => c * 4
        case InstanceField.NormalColumn(c) => 16 + c * 4
        case InstanceField.Emission        => 19
        case InstanceField.PoseRow         => 23
        case InstanceField.Tint            => 28
    }

    /// 欄 f の頭から、WGSL の式 components を 1 つずつ書く文。
    def store(f: InstanceField, components: List[String]): List[String] =
        List.zipWithIndex(components) |> List.map(p -> "  instances[o + ${instanceOffsetOf(f) + fst(p)}u] = ${snd(p)};")

    def xyz(v: String): List[String] = "${v}.x" :: "${v}.y" :: "${v}.z" :: Nil

    /// 欄に入らない float（3・7・11 組の w と 6・7 組の w）を 0 にする文。
    def zeroes(): List[String] =
        (3 :: 7 :: 11 :: 27 :: 31 :: Nil) |> List.map(at -> "  instances[o + ${at}u] = 0.0;")

    def packBody(): List[String] =
        let head =
            "fn srgbToLinear(s: f32) -> f32 {" ::
            "  if (s <= 0.04045) { return s / 12.92; }" ::
            "  return pow((s + 0.055) / 1.055, 2.4);" ::
            "}" ::
            "@compute @workgroup_size(64)" ::
            "fn cs_main(@builtin(global_invocation_id) gid: vec3u) {" ::
            "  let i = gid.x;" ::
            "  if (i >= params.count) { return; }" ::
            "  let b = stateIn[i];" ::
            "  let v = b.vel.xyz;" ::
            "  let speed2 = dot(v, v);" ::
            "  var fwd = vec3f(0.0, 0.0, 1.0);" ::
            "  if (speed2 > 1e-12) { fwd = v / sqrt(speed2); }" ::
            "  var hint = vec3f(0.0, 1.0, 0.0);" ::
            "  if (abs(fwd.y) > 0.999) { hint = vec3f(1.0, 0.0, 0.0); }" ::
            "  let right = normalize(cross(hint, fwd));" ::
            "  let up = cross(fwd, right);" ::
            "  let shade = srgbToLinear(0.75 + 0.25 * clamp(sqrt(speed2) / max(params.maxSpeed, 1e-6), 0.0, 1.0));" ::
            "  let o = i * 32u;" :: Nil;
        let stores = List.flatten(
            store(InstanceField.WorldColumn(0), xyz("right")) :: store(InstanceField.WorldColumn(1), xyz("up")) ::
            store(InstanceField.WorldColumn(2), xyz("fwd")) :: store(InstanceField.WorldColumn(3), "b.pos.x" :: "b.pos.y" :: "b.pos.z" :: "1.0" :: Nil) ::
            store(InstanceField.NormalColumn(0), xyz("right")) :: store(InstanceField.NormalColumn(1), xyz("up")) ::
            store(InstanceField.NormalColumn(2), xyz("fwd")) :: store(InstanceField.Emission, "params.emission" :: Nil) ::
            store(InstanceField.PoseRow, "0.0" :: Nil) :: store(InstanceField.Tint, "shade" :: "shade" :: "shade" :: Nil) :: zeroes() :: Nil);
        head ::: stores ::: "}" :: Nil

    // ── 字 ──

    def common(): List[String] =
        "struct Params {" ::
        "  count: u32, gx: u32, gy: u32, gz: u32," ::
        "  boundsMin: vec3f, dt: f32," ::
        "  boundsMax: vec3f, neighborRadius: f32," ::
        "  cellSize: vec3f, separationRadius: f32," ::
        "  attractor: vec3f, targetWeight: f32," ::
        "  cohesion: f32, alignment: f32, separation: f32, maxSpeed: f32," ::
        "  maxForce: f32, margin: f32, hasTarget: u32, emission: f32," ::
        "};" ::
        "struct Boid { pos: vec4f, vel: vec4f };" ::
        "const FIXED_ONE: f32 = 1073741824.0;" ::
        "const SEP_LIMIT: f32 = 10.0;" ::
        "const MIN_SEP_FRACTION: f32 = 0.1;" ::
        "" ::
        "fn cellCoord(p: vec3f) -> vec3i {" ::
        "  let top = vec3f(f32(params.gx) - 1.0, f32(params.gy) - 1.0, f32(params.gz) - 1.0);" ::
        "  return vec3i(clamp(floor((p - params.boundsMin) / params.cellSize), vec3f(0.0), top));" ::
        "}" ::
        "fn cellIndex(c: vec3i) -> u32 {" ::
        "  return u32(c.x) + params.gx * (u32(c.y) + params.gy * u32(c.z));" ::
        "}" ::
        Nil

    def pairTerms(): List[String] =
        "struct Acc {" ::
        "  cx: vec2u, cy: vec2u, cz: vec2u," ::
        "  ax: vec2u, ay: vec2u, az: vec2u," ::
        "  sx: vec2u, sy: vec2u, sz: vec2u," ::
        "  n: u32," ::
        "};" ::
        "fn add64(a: vec2u, t: i32) -> vec2u {" ::
        "  let lo = a.x + bitcast<u32>(t);" ::
        "  let carry = select(0u, 1u, lo < a.x);" ::
        "  let ext = select(0u, 0xffffffffu, t < 0);" ::
        "  return vec2u(lo, a.y + ext + carry);" ::
        "}" ::
        "fn wide(a: vec2u) -> f32 {" ::
        "  return f32(bitcast<i32>(a.y)) * 4294967296.0 + f32(a.x);" ::
        "}" ::
        "fn quantize(x: vec3f, bound: f32) -> vec3i {" ::
        "  return vec3i(round(clamp(x / bound, vec3f(-1.0), vec3f(1.0)) * FIXED_ONE));" ::
        "}" ::
        "fn velocityBound() -> f32 { return max(params.maxSpeed, 1e-6) * 2.0; }" ::
        "" ::
        "fn addTerm(acc: ptr<function, Acc>, i: u32, pi: vec3f, j: u32, pj: vec3f, vj: vec3f) {" ::
        "  if (j == i) { return; }" ::
        "  let d = pj - pi;" ::
        "  let d2 = dot(d, d);" ::
        "  let r = params.neighborRadius;" ::
        "  if (d2 >= r * r) { return; }" ::
        "  (*acc).n += 1u;" ::
        "  let qc = quantize(d, r);" ::
        "  (*acc).cx = add64((*acc).cx, qc.x); (*acc).cy = add64((*acc).cy, qc.y); (*acc).cz = add64((*acc).cz, qc.z);" ::
        "  let qa = quantize(vj, velocityBound());" ::
        "  (*acc).ax = add64((*acc).ax, qa.x); (*acc).ay = add64((*acc).ay, qa.y); (*acc).az = add64((*acc).az, qa.z);" ::
        "  let s = params.separationRadius;" ::
        "  if (d2 < s * s) {" ::
        "    let dmin = s * MIN_SEP_FRACTION;" ::
        "    let qs = quantize(-d * (s / max(d2, dmin * dmin)), SEP_LIMIT);" ::
        "    (*acc).sx = add64((*acc).sx, qs.x); (*acc).sy = add64((*acc).sy, qs.y); (*acc).sz = add64((*acc).sz, qs.z);" ::
        "  }" ::
        "}" ::
        "" ::
        "fn clampLength(v: vec3f, m: f32) -> vec3f {" ::
        "  let l2 = dot(v, v);" ::
        "  if (l2 > m * m) { return v * (m / sqrt(l2)); }" ::
        "  return v;" ::
        "}" ::
        "fn edgeForce(p: vec3f) -> vec3f {" ::
        "  let m = max(params.margin, 1e-6);" ::
        "  let low = clamp((params.boundsMin + vec3f(m) - p) / m, vec3f(0.0), vec3f(1.0));" ::
        "  let high = clamp((p - (params.boundsMax - vec3f(m))) / m, vec3f(0.0), vec3f(1.0));" ::
        "  return (low - high) * params.maxForce;" ::
        "}" ::
        "fn integrate(p: vec3f, v: vec3f, acc: Acc) -> Boid {" ::
        "  var steer = vec3f(0.0);" ::
        "  if (acc.n > 0u) {" ::
        "    let inv = 1.0 / f32(acc.n);" ::
        "    let center = vec3f(wide(acc.cx), wide(acc.cy), wide(acc.cz)) * (params.neighborRadius / FIXED_ONE * inv);" ::
        "    let mean = vec3f(wide(acc.ax), wide(acc.ay), wide(acc.az)) * (velocityBound() / FIXED_ONE * inv);" ::
        "    let push = vec3f(wide(acc.sx), wide(acc.sy), wide(acc.sz)) * (SEP_LIMIT / FIXED_ONE);" ::
        "    steer = center * params.cohesion + (mean - v) * params.alignment + push * params.separation;" ::
        "  }" ::
        "  if (params.hasTarget != 0u) {" ::
        "    let toward = params.attractor - p;" ::
        "    steer = steer + toward * (params.targetWeight / max(length(toward), 1.0));" ::
        "  }" ::
        "  steer = clampLength(steer, params.maxForce) + edgeForce(p);" ::
        "  var nv = clampLength(v + steer * params.dt, params.maxSpeed);" ::
        "  let np = p + nv * params.dt;" ::
        "  nv = select(nv, abs(nv), np < params.boundsMin);" ::
        "  nv = select(nv, -abs(nv), np > params.boundsMax);" ::
        "  return Boid(vec4f(clamp(np, params.boundsMin, params.boundsMax), 1.0), vec4f(nv, 0.0));" ::
        "}" ::
        Nil

    def scan64(): List[String] =
        "var<workgroup> partial: array<u32, 64>;" ::
        "fn scan64(lid: u32, own: u32) -> u32 {" ::
        "  partial[lid] = own;" ::
        "  workgroupBarrier();" ::
        "  for (var off = 1u; off < 64u; off = off * 2u) {" ::
        "    var add = 0u;" ::
        "    if (lid >= off) { add = partial[lid - off]; }" ::
        "    workgroupBarrier();" ::
        "    partial[lid] = partial[lid] + add;" ::
        "    workgroupBarrier();" ::
        "  }" ::
        "  return partial[lid] - own;" ::
        "}" ::
        Nil

    def countBody(): List[String] =
        "@compute @workgroup_size(64)" ::
        "fn cs_main(@builtin(global_invocation_id) gid: vec3u) {" ::
        "  let i = gid.x;" ::
        "  if (i >= params.count) { return; }" ::
        "  let c = cellIndex(cellCoord(stateIn[i].pos.xyz));" ::
        "  cellSlot[i] = vec2u(c, atomicAdd(&cellCount[c], 1u));" ::
        "}" ::
        Nil

    def scanBlocksBody(): List[String] =
        "@compute @workgroup_size(64)" ::
        "fn cs_main(@builtin(local_invocation_id) lid: vec3u, @builtin(workgroup_id) wid: vec3u) {" ::
        "  let base = wid.x * 256u + lid.x * 4u;" ::
        "  let a = cellCount[base]; let b = cellCount[base + 1u]; let c = cellCount[base + 2u]; let d = cellCount[base + 3u];" ::
        "  let before = scan64(lid.x, a + b + c + d);" ::
        "  cellStart[base] = before;" ::
        "  cellStart[base + 1u] = before + a;" ::
        "  cellStart[base + 2u] = before + a + b;" ::
        "  cellStart[base + 3u] = before + a + b + c;" ::
        "  if (lid.x == 63u) { blockSums[wid.x] = before + a + b + c + d; }" ::
        "}" ::
        Nil

    def scanSumsBody(): List[String] =
        "@compute @workgroup_size(64)" ::
        "fn cs_main(@builtin(local_invocation_id) lid: vec3u) {" ::
        "  let a = blockSums[lid.x * 2u]; let b = blockSums[lid.x * 2u + 1u];" ::
        "  let before = scan64(lid.x, a + b);" ::
        "  blockSums[lid.x * 2u] = before;" ::
        "  blockSums[lid.x * 2u + 1u] = before + a;" ::
        "}" ::
        Nil

    def scanAddBody(): List[String] =
        "@compute @workgroup_size(64)" ::
        "fn cs_main(@builtin(global_invocation_id) gid: vec3u) {" ::
        "  cellStart[gid.x] = cellStart[gid.x] + blockSums[gid.x / 256u];" ::
        "  cellCount[gid.x] = 0u;" ::
        "  if (gid.x == 0u) { cellStart[32768u] = params.count; }" ::
        "}" ::
        Nil

    def scatterBody(): List[String] =
        "@compute @workgroup_size(64)" ::
        "fn cs_main(@builtin(global_invocation_id) gid: vec3u) {" ::
        "  let i = gid.x;" ::
        "  if (i >= params.count) { return; }" ::
        "  let cs = cellSlot[i];" ::
        "  let at = cellStart[cs.x] + cs.y;" ::
        "  sortedState[at] = stateIn[i];" ::
        "  sortedId[at] = i;" ::
        "}" ::
        Nil

    // WhyNot: 近所を見る数に上限を置かない — 「最初の K 個だけ」はセルの中の並び（count の atomicAdd の順）に答えが左右され、回ごとに群れが別の動きになる。
    def rulesGridBody(): List[String] =
        "@compute @workgroup_size(64)" ::
        "fn cs_main(@builtin(global_invocation_id) gid: vec3u) {" ::
        "  let k = gid.x;" ::
        "  if (k >= params.count) { return; }" ::
        "  let me = sortedState[k];" ::
        "  let p = me.pos.xyz;" ::
        "  let c = cellCoord(p);" ::
        "  let g = vec3i(i32(params.gx), i32(params.gy), i32(params.gz));" ::
        "  var acc: Acc;" ::
        "  for (var z = max(c.z - 1, 0); z <= min(c.z + 1, g.z - 1); z++) {" ::
        "    for (var y = max(c.y - 1, 0); y <= min(c.y + 1, g.y - 1); y++) {" ::
        "      for (var x = max(c.x - 1, 0); x <= min(c.x + 1, g.x - 1); x++) {" ::
        "        let cell = cellIndex(vec3i(x, y, z));" ::
        "        let end = cellStart[cell + 1u];" ::
        "        for (var s = cellStart[cell]; s < end; s++) {" ::
        "          let o = sortedState[s];" ::
        "          addTerm(&acc, k, p, s, o.pos.xyz, o.vel.xyz);" ::
        "        }" ::
        "      }" ::
        "    }" ::
        "  }" ::
        "  stateOut[sortedId[k]] = integrate(p, me.vel.xyz, acc);" ::
        "}" ::
        Nil

    def rulesBruteBody(): List[String] =
        "var<workgroup> tilePos: array<vec4f, 64>;" ::
        "var<workgroup> tileVel: array<vec4f, 64>;" ::
        "@compute @workgroup_size(64)" ::
        "fn cs_main(@builtin(global_invocation_id) gid: vec3u, @builtin(local_invocation_id) lid: vec3u) {" ::
        "  let i = gid.x;" ::
        "  let me = stateIn[min(i, params.count - 1u)];" ::
        "  let p = me.pos.xyz;" ::
        "  var acc: Acc;" ::
        "  let tiles = (params.count + 63u) / 64u;" ::
        "  for (var t = 0u; t < tiles; t++) {" ::
        "    let j0 = t * 64u + lid.x;" ::
        "    if (j0 < params.count) { let o = stateIn[j0]; tilePos[lid.x] = o.pos; tileVel[lid.x] = o.vel; }" ::
        "    workgroupBarrier();" ::
        "    let n = min(64u, params.count - t * 64u);" ::
        "    for (var k = 0u; k < n; k++) {" ::
        "      addTerm(&acc, i, p, t * 64u + k, tilePos[k].xyz, tileVel[k].xyz);" ::
        "    }" ::
        "    workgroupBarrier();" ::
        "  }" ::
        "  if (i < params.count) { stateOut[i] = integrate(p, me.vel.xyz, acc); }" ::
        "}" ::
        Nil
}
