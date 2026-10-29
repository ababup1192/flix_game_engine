import json, math, zlib, struct, random

ROOT = '/Users/abab/Desktop/flix_game_engine/templates/rpg-starter'
PAL = json.load(open(ROOT + '/assets/rpg.palette.json'))


def rgb(k):
    return tuple(round(c * 255) for c in PAL[k]['rgb'])


L = (-0.5, -0.62, 0.62)
_n = math.sqrt(sum(c * c for c in L))
L = tuple(c / _n for c in L)

BAYER = [[0, 2], [3, 1]]


class Grid:
    def __init__(s, w, h):
        s.w, s.h = w, h
        s.p = [[None] * w for _ in range(h)]

    def get(s, x, y):
        return s.p[y][x] if 0 <= x < s.w and 0 <= y < s.h else None

    def set(s, x, y, c):
        if 0 <= x < s.w and 0 <= y < s.h:
            s.p[y][x] = c

    def rows(s, cmap):
        return [''.join(cmap[c] if c else '.' for c in r) for r in s.p]

    def outline(s, c='ink'):
        add = []
        for y in range(s.h):
            for x in range(s.w):
                if s.p[y][x] is None:
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        v = s.get(x + dx, y + dy)
                        if v is not None and v != c:
                            add.append((x, y))
                            break
        for x, y in add:
            s.set(x, y, c)


def ellipse(cx, cy, rx, ry):
    m = set()
    for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
        for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
            if ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1.0:
                m.add((x, y))
    return m


def poly(pts):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    m = set()
    for y in range(int(min(ys)) - 1, int(max(ys)) + 2):
        for x in range(int(min(xs)) - 1, int(max(xs)) + 2):
            px, py = x + 0.5, y + 0.5
            inside = False
            j = len(pts) - 1
            for i in range(len(pts)):
                xi, yi = pts[i]
                xj, yj = pts[j]
                if (yi > py) != (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi:
                    inside = not inside
                j = i
            if inside:
                m.add((x, y))
    return m


def line(x0, y0, x1, y1):
    pts = []
    dx, dy = abs(x1 - x0), -abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx + dy
    while True:
        pts.append((x0, y0))
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy
    return pts


def thick(pts, r=1):
    m = set()
    for x, y in pts:
        for dx in range(-r + 1, r):
            for dy in range(-r + 1, r):
                m.add((x + dx, y + dy))
    return m


def sphere_level(x, y, cx, cy, rx, ry, cuts, dith=0.05, light=L):
    nx = (x + 0.5 - cx) / rx
    ny = (y + 0.5 - cy) / ry
    r = math.hypot(nx, ny)
    if r > 0.97:
        nx, ny = nx / r * 0.97, ny / r * 0.97
    nz = math.sqrt(max(0.0, 1 - nx * nx - ny * ny))
    i = nx * light[0] + ny * light[1] + nz * light[2]
    lv = 0
    for k, t in enumerate(cuts):
        if i > t + dith:
            lv = k + 1
        elif i > t - dith:
            lv = k + 1 if (x + y) % 2 == 0 else k
    return lv


def paint(g, mask, fn, line_c='ink', line=True):
    """fn(x,y) -> color. Draw ink rim on existing pixels around the new part."""
    if line:
        for x, y in mask:
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                q = (x + dx, y + dy)
                if q not in mask and g.get(*q) is not None:
                    g.set(q[0], q[1], line_c)
    for x, y in mask:
        g.set(x, y, fn(x, y))


def sph(ramp, cx, cy, rx, ry, cuts, dith=0.05):
    return lambda x, y: ramp[sphere_level(x, y, cx, cy, rx, ry, cuts, dith)]


def mirror_x(pts, axis):
    return {(int(2 * axis - x - 1), y) for x, y in pts}


# ---------------- PNG ----------------

def write_png(path, w, h, pix):
    raw = b''.join(b'\x00' + bytes(sum((list(p) for p in pix[y * w:(y + 1) * w]), [])) for y in range(h))

    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    open(path, 'wb').write(png)


def compose(items, bg, pad=4, scale=1, bgfn=None):
    """items: list of Grid; laid out in a row on bottom baseline."""
    W = sum(g.w for g in items) + pad * (len(items) + 1)
    H = max(g.h for g in items) + pad * 2
    canvas = [[bgfn(x, y) if bgfn else bg for x in range(W)] for y in range(H)]
    x0 = pad
    for g in items:
        y0 = H - pad - g.h
        for y in range(g.h):
            for x in range(g.w):
                c = g.p[y][x]
                if c:
                    canvas[y0 + y][x0 + x] = rgb(c)
        x0 += g.w + pad
    return canvas


def save(path, canvas, scale=1):
    H = len(canvas)
    W = len(canvas[0])
    pix = []
    for y in range(H * scale):
        row = canvas[y // scale]
        for x in range(W * scale):
            pix.append(row[x // scale])
    write_png(path, W * scale, H * scale, pix)


def ball(mask, ramp, s=None, hl=0.42):
    """Shadow crescent on the lower right (follows the contour), highlight blob on the upper left."""
    xs = [p[0] for p in mask]
    ys = [p[1] for p in mask]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    cx, cy = (x0 + x1 + 1) / 2.0, (y0 + y1 + 1) / 2.0
    rx, ry = (x1 - x0 + 1) / 2.0, (y1 - y0 + 1) / 2.0
    if s is None:
        s = max(1, int(round(min(rx, ry) * 0.3)))
    hx, hy = cx - rx * 0.32, cy - ry * 0.38
    hrx, hry = rx * hl, ry * hl * 0.8

    def fn(x, y):
        if (x + s, y + s) not in mask or (x + s + 1, y + s - 1) not in mask and (x + y) % 2 == 0:
            return ramp[0]
        if len(ramp) > 2 and ((x + 0.5 - hx) / hrx) ** 2 + ((y + 0.5 - hy) / hry) ** 2 <= 1.0:
            return ramp[2]
        return ramp[1]
    return fn
