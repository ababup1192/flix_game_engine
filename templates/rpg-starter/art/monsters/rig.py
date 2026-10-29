"""Skeleton-first drawing: bones are point chains (x, y, radius); flesh is swept along them,
and each pixel keeps the direction from its bone so the shade follows the form."""
import math
from lib import Grid, L

DARKER = {'fc27': 'fc17', 'fc17': 'fc07', 'fc07': 'ink',
          'fc23': 'fc13', 'fc13': 'fc03', 'fc03': 'ink', 'fc33': 'fc23'}


def _cr(p0, p1, p2, p3, t):
    t2, t3 = t * t, t * t * t
    return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)


def spline(pts, step=0.35):
    """Catmull-Rom through the joints, so the flesh bends instead of kinking."""
    P = [pts[0]] + list(pts) + [pts[-1]]
    out = []
    for i in range(1, len(P) - 2):
        a, b, c, d = P[i - 1], P[i], P[i + 1], P[i + 2]
        n = max(2, int(math.hypot(c[0] - b[0], c[1] - b[1]) / step))
        for k in range(n):
            t = k / n
            out.append(tuple(_cr(a[j], b[j], c[j], d[j], t) for j in range(3)))
    out.append(tuple(pts[-1]))
    return out


class Part:
    def __init__(s, joints, depth=0):
        s.samples = spline(joints)
        s.depth = depth
        s.px = {}
        xs = [p[0] for p in s.samples]
        ys = [p[1] for p in s.samples]
        R = max(p[2] for p in s.samples) + 1
        for y in range(int(min(ys) - R), int(max(ys) + R) + 1):
            for x in range(int(min(xs) - R), int(max(xs) + R) + 1):
                cx, cy = x + 0.5, y + 0.5
                best, bs, bi = -1e9, None, 0
                for i, (sx, sy, r) in enumerate(s.samples):
                    v = r - math.hypot(cx - sx, cy - sy)
                    if v > best:
                        best, bs, bi = v, (sx, sy, r), i
                if best >= 0:
                    nx, ny = (cx - bs[0]) / bs[2], (cy - bs[1]) / bs[2]
                    s.px[(x, y)] = (nx, ny, bi / max(1, len(s.samples) - 1))

    def mask(s):
        return set(s.px)

    def level(s, x, y, cuts, light=L):
        nx, ny, _ = s.px[(x, y)]
        r = math.hypot(nx, ny)
        if r > 0.98:
            nx, ny = nx / r * 0.98, ny / r * 0.98
        nz = math.sqrt(max(0.0, 1 - nx * nx - ny * ny))
        i = nx * light[0] + ny * light[1] + nz * light[2]
        lv = 0
        for k, t in enumerate(cuts):
            if i > t:
                lv = k + 1
        return max(0, lv - s.depth)


def draw(g, part, ramp, cuts, line='color'):
    """line: 'ink' for a deep overlap, 'color' for a thin inner line one step darker, None for none."""
    m = part.mask()
    if line:
        for x, y in m:
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                q = (x + dx, y + dy)
                if q not in m and g.get(*q) is not None:
                    if line == 'ink':
                        g.set(q[0], q[1], 'ink')
                    else:
                        g.set(q[0], q[1], DARKER.get(g.get(*q), 'ink'))
    vals = {}
    for x, y in m:
        vals[(x, y)] = part.level(x, y, cuts)
    # merge 1px islands of a shade into the surrounding cluster
    for (x, y), v in list(vals.items()):
        nb = [vals.get((x + dx, y + dy)) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))]
        nb = [n for n in nb if n is not None]
        if nb and v not in nb:
            vals[(x, y)] = max(set(nb), key=nb.count)
    for (x, y), v in vals.items():
        g.set(x, y, ramp[v])
    return m
