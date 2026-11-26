/**
 * 群れ（Boids）の kernel の WGSL（C0 の測り用。engine の Render3d.Internal.Kernels の元）。デスクトップとブラウザの両方が使う。
 * 1 刻み = count → scanBlocks → scanSums → scanAdd → scatter → rules（格子）。総当たりは rulesBrute 1 本。出口は pack。
 * cellCount は scanAdd が 0 に戻す（次の刻みの count の前に clearBuffer を挟むと刻みごとに pass を切ることになる）。
 * cellStart は MAX_CELLS + 1 個（最後 = count）で、セルの終わりは次のセルの始まり。
 * binding は kernel ごとに 0 = params（uniform）・1 から storage。
 */
public final class FlockKernels {
    private FlockKernels() {}

    public static final int WORKGROUP = 64;
    public static final int MAX_CELLS = 32768;
    public static final int SCAN_BLOCK = 256;
    public static final int SCAN_BLOCKS = MAX_CELLS / SCAN_BLOCK;
    public static final int PARAMS_BYTES = 112;
    public static final int FLOATS_PER_INSTANCE = 32;

    static final String COMMON = """
        struct Params {
          count: u32, gx: u32, gy: u32, gz: u32,
          boundsMin: vec3f, dt: f32,
          boundsMax: vec3f, neighborRadius: f32,
          cellSize: vec3f, separationRadius: f32,
          attractor: vec3f, targetWeight: f32,
          cohesion: f32, alignment: f32, separation: f32, maxSpeed: f32,
          maxForce: f32, margin: f32, hasTarget: u32, emission: f32,
        };
        struct Boid { pos: vec4f, vel: vec4f };
        @group(0) @binding(0) var<uniform> params: Params;
        const FIXED_ONE: f32 = 1073741824.0;
        const SEP_LIMIT: f32 = 10.0;
        const MIN_SEP_FRACTION: f32 = 0.1;

        fn cellCoord(p: vec3f) -> vec3i {
          let top = vec3f(f32(params.gx) - 1.0, f32(params.gy) - 1.0, f32(params.gz) - 1.0);
          return vec3i(clamp(floor((p - params.boundsMin) / params.cellSize), vec3f(0.0), top));
        }
        fn cellIndex(c: vec3i) -> u32 {
          return u32(c.x) + params.gx * (u32(c.y) + params.gy * u32(c.z));
        }
        """;

    static final String ACC = """
        struct Acc {
          cx: vec2u, cy: vec2u, cz: vec2u,
          ax: vec2u, ay: vec2u, az: vec2u,
          sx: vec2u, sy: vec2u, sz: vec2u,
          n: u32,
        };
        fn add64(a: vec2u, t: i32) -> vec2u {
          let lo = a.x + bitcast<u32>(t);
          let carry = select(0u, 1u, lo < a.x);
          let ext = select(0u, 0xffffffffu, t < 0);
          return vec2u(lo, a.y + ext + carry);
        }
        fn wide(a: vec2u) -> f32 {
          return f32(bitcast<i32>(a.y)) * 4294967296.0 + f32(a.x);
        }
        fn quantize(x: vec3f, bound: f32) -> vec3i {
          return vec3i(round(clamp(x / bound, vec3f(-1.0), vec3f(1.0)) * FIXED_ONE));
        }
        fn velocityBound() -> f32 { return max(params.maxSpeed, 1e-6) * 2.0; }

        fn addTerm(acc: ptr<function, Acc>, i: u32, pi: vec3f, j: u32, pj: vec3f, vj: vec3f) {
          if (j == i) { return; }
          let d = pj - pi;
          let d2 = dot(d, d);
          let r = params.neighborRadius;
          if (d2 >= r * r) { return; }
          (*acc).n += 1u;
          let qc = quantize(d, r);
          (*acc).cx = add64((*acc).cx, qc.x); (*acc).cy = add64((*acc).cy, qc.y); (*acc).cz = add64((*acc).cz, qc.z);
          let qa = quantize(vj, velocityBound());
          (*acc).ax = add64((*acc).ax, qa.x); (*acc).ay = add64((*acc).ay, qa.y); (*acc).az = add64((*acc).az, qa.z);
          let s = params.separationRadius;
          if (d2 < s * s) {
            let dmin = s * MIN_SEP_FRACTION;
            let qs = quantize(-d * (s / max(d2, dmin * dmin)), SEP_LIMIT);
            (*acc).sx = add64((*acc).sx, qs.x); (*acc).sy = add64((*acc).sy, qs.y); (*acc).sz = add64((*acc).sz, qs.z);
          }
        }

        fn clampLength(v: vec3f, m: f32) -> vec3f {
          let l2 = dot(v, v);
          if (l2 > m * m) { return v * (m / sqrt(l2)); }
          return v;
        }
        fn edgeForce(p: vec3f) -> vec3f {
          let m = max(params.margin, 1e-6);
          let low = clamp((params.boundsMin + vec3f(m) - p) / m, vec3f(0.0), vec3f(1.0));
          let high = clamp((p - (params.boundsMax - vec3f(m))) / m, vec3f(0.0), vec3f(1.0));
          return (low - high) * params.maxForce;
        }
        fn integrate(p: vec3f, v: vec3f, acc: Acc) -> Boid {
          var steer = vec3f(0.0);
          if (acc.n > 0u) {
            let inv = 1.0 / f32(acc.n);
            let center = vec3f(wide(acc.cx), wide(acc.cy), wide(acc.cz)) * (params.neighborRadius / FIXED_ONE * inv);
            let mean = vec3f(wide(acc.ax), wide(acc.ay), wide(acc.az)) * (velocityBound() / FIXED_ONE * inv);
            let push = vec3f(wide(acc.sx), wide(acc.sy), wide(acc.sz)) * (SEP_LIMIT / FIXED_ONE);
            steer = center * params.cohesion + (mean - v) * params.alignment + push * params.separation;
          }
          if (params.hasTarget != 0u) {
            let toward = params.attractor - p;
            steer = steer + toward * (params.targetWeight / max(length(toward), 1.0));
          }
          steer = clampLength(steer, params.maxForce) + edgeForce(p);
          var nv = clampLength(v + steer * params.dt, params.maxSpeed);
          let np = p + nv * params.dt;
          nv = select(nv, abs(nv), np < params.boundsMin);
          nv = select(nv, -abs(nv), np > params.boundsMax);
          return Boid(vec4f(clamp(np, params.boundsMin, params.boundsMax), 1.0), vec4f(nv, 0.0));
        }
        """;

    public static final String COUNT = COMMON + """
        @group(0) @binding(1) var<storage, read> stateIn: array<Boid>;
        @group(0) @binding(2) var<storage, read_write> cellCount: array<atomic<u32>>;
        @group(0) @binding(3) var<storage, read_write> cellSlot: array<vec2u>;
        @compute @workgroup_size(64)
        fn cs_main(@builtin(global_invocation_id) gid: vec3u) {
          let i = gid.x;
          if (i >= params.count) { return; }
          let c = cellIndex(cellCoord(stateIn[i].pos.xyz));
          cellSlot[i] = vec2u(c, atomicAdd(&cellCount[c], 1u));
        }
        """;

    static final String SCAN64 = """
        var<workgroup> partial: array<u32, 64>;
        fn scan64(lid: u32, own: u32) -> u32 {
          partial[lid] = own;
          workgroupBarrier();
          for (var off = 1u; off < 64u; off = off * 2u) {
            var add = 0u;
            if (lid >= off) { add = partial[lid - off]; }
            workgroupBarrier();
            partial[lid] = partial[lid] + add;
            workgroupBarrier();
          }
          return partial[lid] - own;
        }
        """;

    public static final String SCAN_BLOCKS_WGSL = COMMON + SCAN64 + """
        @group(0) @binding(1) var<storage, read> cellCount: array<u32>;
        @group(0) @binding(2) var<storage, read_write> cellStart: array<u32>;
        @group(0) @binding(3) var<storage, read_write> blockSums: array<u32>;
        @compute @workgroup_size(64)
        fn cs_main(@builtin(local_invocation_id) lid: vec3u, @builtin(workgroup_id) wid: vec3u) {
          let base = wid.x * 256u + lid.x * 4u;
          let a = cellCount[base]; let b = cellCount[base + 1u]; let c = cellCount[base + 2u]; let d = cellCount[base + 3u];
          let before = scan64(lid.x, a + b + c + d);
          cellStart[base] = before;
          cellStart[base + 1u] = before + a;
          cellStart[base + 2u] = before + a + b;
          cellStart[base + 3u] = before + a + b + c;
          if (lid.x == 63u) { blockSums[wid.x] = before + a + b + c + d; }
        }
        """;

    public static final String SCAN_SUMS = COMMON + SCAN64 + """
        @group(0) @binding(1) var<storage, read_write> blockSums: array<u32>;
        @compute @workgroup_size(64)
        fn cs_main(@builtin(local_invocation_id) lid: vec3u) {
          let a = blockSums[lid.x * 2u]; let b = blockSums[lid.x * 2u + 1u];
          let before = scan64(lid.x, a + b);
          blockSums[lid.x * 2u] = before;
          blockSums[lid.x * 2u + 1u] = before + a;
        }
        """;

    public static final String SCAN_ADD = COMMON + """
        @group(0) @binding(1) var<storage, read_write> cellStart: array<u32>;
        @group(0) @binding(2) var<storage, read> blockSums: array<u32>;
        @group(0) @binding(3) var<storage, read_write> cellCount: array<u32>;
        @compute @workgroup_size(64)
        fn cs_main(@builtin(global_invocation_id) gid: vec3u) {
          cellStart[gid.x] = cellStart[gid.x] + blockSums[gid.x / 256u];
          cellCount[gid.x] = 0u;
          if (gid.x == 0u) { cellStart[32768u] = params.count; }
        }
        """;

    public static final String SCATTER = COMMON + """
        @group(0) @binding(1) var<storage, read> stateIn: array<Boid>;
        @group(0) @binding(2) var<storage, read> cellSlot: array<vec2u>;
        @group(0) @binding(3) var<storage, read> cellStart: array<u32>;
        @group(0) @binding(4) var<storage, read_write> sortedState: array<Boid>;
        @group(0) @binding(5) var<storage, read_write> sortedId: array<u32>;
        @compute @workgroup_size(64)
        fn cs_main(@builtin(global_invocation_id) gid: vec3u) {
          let i = gid.x;
          if (i >= params.count) { return; }
          let cs = cellSlot[i];
          let at = cellStart[cs.x] + cs.y;
          sortedState[at] = stateIn[i];
          sortedId[at] = i;
        }
        """;

    public static final String RULES_GRID = COMMON + ACC + """
        @group(0) @binding(1) var<storage, read> sortedState: array<Boid>;
        @group(0) @binding(2) var<storage, read> sortedId: array<u32>;
        @group(0) @binding(3) var<storage, read> cellStart: array<u32>;
        @group(0) @binding(4) var<storage, read_write> stateOut: array<Boid>;
        @compute @workgroup_size(64)
        fn cs_main(@builtin(global_invocation_id) gid: vec3u) {
          let k = gid.x;
          if (k >= params.count) { return; }
          let me = sortedState[k];
          let p = me.pos.xyz;
          let c = cellCoord(p);
          let g = vec3i(i32(params.gx), i32(params.gy), i32(params.gz));
          var acc: Acc;
          for (var z = max(c.z - 1, 0); z <= min(c.z + 1, g.z - 1); z++) {
            for (var y = max(c.y - 1, 0); y <= min(c.y + 1, g.y - 1); y++) {
              for (var x = max(c.x - 1, 0); x <= min(c.x + 1, g.x - 1); x++) {
                let cell = cellIndex(vec3i(x, y, z));
                let end = cellStart[cell + 1u];
                for (var s = cellStart[cell]; s < end; s++) {
                  let o = sortedState[s];
                  addTerm(&acc, k, p, s, o.pos.xyz, o.vel.xyz);
                }
              }
            }
          }
          stateOut[sortedId[k]] = integrate(p, me.vel.xyz, acc);
        }
        """;

    public static final String RULES_BRUTE = COMMON + ACC + """
        @group(0) @binding(1) var<storage, read> stateIn: array<Boid>;
        @group(0) @binding(2) var<storage, read_write> stateOut: array<Boid>;
        var<workgroup> tilePos: array<vec4f, 64>;
        var<workgroup> tileVel: array<vec4f, 64>;
        @compute @workgroup_size(64)
        fn cs_main(@builtin(global_invocation_id) gid: vec3u, @builtin(local_invocation_id) lid: vec3u) {
          let i = gid.x;
          let me = stateIn[min(i, params.count - 1u)];
          let p = me.pos.xyz;
          var acc: Acc;
          let tiles = (params.count + 63u) / 64u;
          for (var t = 0u; t < tiles; t++) {
            let j0 = t * 64u + lid.x;
            if (j0 < params.count) { let o = stateIn[j0]; tilePos[lid.x] = o.pos; tileVel[lid.x] = o.vel; }
            workgroupBarrier();
            let n = min(64u, params.count - t * 64u);
            for (var k = 0u; k < n; k++) {
              addTerm(&acc, i, p, t * 64u + k, tilePos[k].xyz, tileVel[k].xyz);
            }
            workgroupBarrier();
          }
          if (i < params.count) { stateOut[i] = integrate(p, me.vel.xyz, acc); }
        }
        """;

    public static final String PACK = COMMON + """
        @group(0) @binding(1) var<storage, read> stateIn: array<Boid>;
        @group(0) @binding(2) var<storage, read_write> instances: array<f32>;
        fn srgbToLinear(s: f32) -> f32 {
          if (s <= 0.04045) { return s / 12.92; }
          return pow((s + 0.055) / 1.055, 2.4);
        }
        @compute @workgroup_size(64)
        fn cs_main(@builtin(global_invocation_id) gid: vec3u) {
          let i = gid.x;
          if (i >= params.count) { return; }
          let b = stateIn[i];
          let v = b.vel.xyz;
          let speed2 = dot(v, v);
          var fwd = vec3f(0.0, 0.0, 1.0);
          if (speed2 > 1e-12) { fwd = v / sqrt(speed2); }
          var hint = vec3f(0.0, 1.0, 0.0);
          if (abs(fwd.y) > 0.999) { hint = vec3f(1.0, 0.0, 0.0); }
          let right = normalize(cross(hint, fwd));
          let up = cross(fwd, right);
          let shade = srgbToLinear(0.75 + 0.25 * clamp(sqrt(speed2) / max(params.maxSpeed, 1e-6), 0.0, 1.0));
          let o = i * 32u;
          instances[o + 0u] = right.x; instances[o + 1u] = right.y; instances[o + 2u] = right.z; instances[o + 3u] = 0.0;
          instances[o + 4u] = up.x; instances[o + 5u] = up.y; instances[o + 6u] = up.z; instances[o + 7u] = 0.0;
          instances[o + 8u] = fwd.x; instances[o + 9u] = fwd.y; instances[o + 10u] = fwd.z; instances[o + 11u] = 0.0;
          instances[o + 12u] = b.pos.x; instances[o + 13u] = b.pos.y; instances[o + 14u] = b.pos.z; instances[o + 15u] = 1.0;
          instances[o + 16u] = right.x; instances[o + 17u] = right.y; instances[o + 18u] = right.z; instances[o + 19u] = params.emission;
          instances[o + 20u] = up.x; instances[o + 21u] = up.y; instances[o + 22u] = up.z; instances[o + 23u] = 0.0;
          instances[o + 24u] = fwd.x; instances[o + 25u] = fwd.y; instances[o + 26u] = fwd.z; instances[o + 27u] = 0.0;
          instances[o + 28u] = shade; instances[o + 29u] = shade; instances[o + 30u] = shade; instances[o + 31u] = 0.0;
        }
        """;
}
