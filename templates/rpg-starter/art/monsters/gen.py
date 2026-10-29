import sys, json, math, random
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *
import boss as boss_rig

OUT = ROOT + '/debug/monsters'


def eye(g, x, y, w, h, glint, glint2=None):
    """Rounded ink eye with a glint at its upper left."""
    m = set()
    for yy in range(y, y + h):
        for xx in range(x, x + w):
            corner = (xx in (x, x + w - 1)) and (yy in (y, y + h - 1))
            if not corner or w <= 3 or h <= 3:
                m.add((xx, yy))
    for p in m:
        g.set(p[0], p[1], 'ink')
    g.set(x + (1 if w > 3 else 0), y + (1 if h > 3 else 0), glint)
    if w >= 3 and h >= 3 and w * h > 9:
        g.set(x + (2 if w > 3 else 1), y + (1 if h > 3 else 0), glint)
    if glint2 and w >= 4:
        g.set(x + w - 2, y + h - 2, glint2)


def clip(m, f):
    return {p for p in m if f(*p)}


# ------------------------------------------------------------------ koke
def koke(f):
    g = Grid(24, 24)
    cy = 14.0 + f * 0.6
    rx, ry = 10.6 + f * 0.4, 9.2 - f * 0.6
    body = clip(ellipse(12, cy, rx, ry), lambda x, y: y <= 22)
    paint(g, body, ball(body, ['fc0C', 'fc00', 'fc10']))
    top = min(y for _, y in body)
    e = [0, 15, 17, 18, 17, 16, 14, 13, 13, 12, 13, 13, 13, 13, 12, 13, 13, 14, 16, 17, 18, 17, 15, 0]
    moss = {(x, y) for (x, y) in body if y < e[x] + f}
    rnd = random.Random(3)
    shade = sph(['fc0A', 'fc1A', 'fc2A'], 10.5, cy - 2, rx, ry, [0.05, 0.62], 0.06)
    paint(g, moss, shade, line=False)
    # moss tufts: short curls of the darker step inside the lit areas
    for x, y in [(6, 8), (15, 7), (11, 11), (18, 11), (4, 13), (8, 10), (13, 8), (17, 15)]:
        y2 = y + f
        if (x, y2) in moss and (x + 1, y2) in moss:
            c = g.get(x, y2)
            d = {'fc2A': 'fc1A', 'fc1A': 'fc0A', 'fc0A': 'fc0A'}[c]
            g.set(x, y2, d)
            g.set(x + 1, y2 + 1 if (x + 1, y2 + 1) in moss else y2, d)
    # moss rim: ink under the fringe
    for x in range(24):
        y = e[x] + f
        if (x, y) in body and (x, y - 1) in moss:
            g.set(x, y, 'fc0C')
    # sprout
    st = top - 1
    sway = 0 if f == 0 else 1
    for y in range(st - 2, st + 1):
        g.set(12, y, 'fc1A')
    leafL = poly([(12, st - 2), (9 + sway, st - 5), (7 + sway, st - 3), (10, st - 1)])
    leafR = poly([(13, st - 2), (15 + sway, st - 6), (18, st - 5), (15, st - 2)])
    paint(g, leafL, lambda x, y: 'fc2A', line=False)
    paint(g, leafR, lambda x, y: 'fc1A' if y > st - 4 else 'fc2A', line=False)
    # face
    ey = 14 + f
    eye(g, 8, ey, 2, 3, 'fc10')
    eye(g, 14, ey, 2, 3, 'fc10')
    g.set(11, ey + 3, 'ink')
    g.set(12, ey + 3, 'ink')
    g.set(11, ey + 4, 'fc0C')
    g.set(12, ey + 4, 'fc0C')
    # crack on the shadow side of the stone
    for p in [(19, 18), (18, 19), (18, 20)]:
        if g.get(*p):
            g.set(p[0], p[1], 'ink')
    g.outline()
    return g


# ------------------------------------------------------------------ bat
def bat(f):
    g = Grid(32, 24)
    bob = -1 if f == 1 else 0
    if f == 0:
        wing = poly([(11, 12), (6, 4), (1, 3), (1, 7), (3, 8), (3, 12), (6, 11), (7, 15), (10, 15)])
    else:
        wing = poly([(11, 11), (6, 12), (1, 15), (2, 19), (4, 17), (5, 21), (7, 18), (9, 20), (11, 16)])
    wing = {(x, y + bob) for x, y in wing}
    wingR = mirror_x(wing, 16)
    paint(g, wing, lambda x, y: 'fc07', line=False)
    paint(g, wingR, lambda x, y: 'fc07', line=False)
    # wing bones (lit side lighter)
    if f == 0:
        bones = [((10, 11), (5, 5)), ((5, 5), (2, 4)), ((6, 5), (3, 10)), ((7, 6), (7, 13))]
    else:
        bones = [((10, 11), (5, 13)), ((5, 13), (2, 16)), ((6, 13), (5, 19)), ((8, 13), (8, 18))]
    for (a, b) in bones:
        for x, y in line(a[0], a[1] + bob, b[0], b[1] + bob):
            if (x, y) in wing:
                g.set(x, y, 'fc17')
            q = (int(31 - x), y)
            if q in wingR:
                g.set(q[0], q[1], 'fc17')
    body = ellipse(16, 13 + bob, 7, 6.5)
    earL = poly([(10, 10 + bob), (9, 3 + bob), (11, 3 + bob), (14, 8 + bob)])
    earR = mirror_x(earL, 16)
    paint(g, earL | earR, ball((earL | earR), ['fc07', 'fc17', 'fc27']))
    for x, y in [(10, 5), (11, 6), (11, 7)]:
        g.set(x, y + bob, 'fc07')
        g.set(31 - x, y + bob, 'fc07')
    paint(g, body, ball(body, ['fc07', 'fc17', 'fc27']))
    # fluff on the belly line
    for x in (12, 14, 17, 19):
        g.set(x, 19 + bob, 'ink')
    crystal = poly([(16, 2 + bob), (18.5, 6 + bob), (16, 10 + bob), (13.5, 6 + bob)])
    paint(g, crystal, lambda x, y: 'fc23' if x < 16 else 'fc13')
    g.set(15, 4 + bob, 'fc30')
    eye(g, 11, 11 + bob, 3, 3, 'fc30')
    eye(g, 18, 11 + bob, 3, 3, 'fc30')
    g.set(15, 15 + bob, 'ink')
    g.set(16, 15 + bob, 'ink')
    g.set(16, 16 + bob, 'fc30')
    for x in (13, 18):
        g.set(x, 20 + bob, 'fc17')
    g.outline()
    return g


# ------------------------------------------------------------------ goblin
def goblin(f):
    g = Grid(32, 40)
    d = f  # squash down by 1 in idle_1
    # pickaxe behind the arm
    tilt = 0 if f == 0 else 1
    lit = set(line(22, 35, 26 + tilt, 9 + d))
    dark = {(x + 1, y) for x, y in lit} - lit
    paint(g, lit | dark, lambda x, y: 'fc28' if (x, y) in lit else 'fc08', line=False)
    hx, hy = 26 + tilt, 8 + d
    head = poly([(hx - 7, hy + 4), (hx - 4, hy), (hx + 1, hy - 2), (hx + 5, hy), (hx + 6, hy + 4), (hx + 3, hy + 2), (hx - 1, hy + 1), (hx - 4, hy + 2)])
    paint(g, head, lambda x, y: 'fc38' if y <= hy - 1 or (x < hx - 3 and y <= hy + 1) else ('fc28' if y <= hy + 1 else 'fc08'))
    # legs and feet
    for lx in (10, 16):
        leg = ellipse(lx + 1.5, 35 + d * 0.5, 2.5, 3)
        paint(g, leg, ball(leg, ['fc0C', 'fc1C', 'fc2C']))
    for fx in (8.5, 18.5):
        foot = clip(ellipse(fx + 1, 38, 3.6, 2), lambda x, y: y <= 38)
        paint(g, foot, lambda x, y: 'fc1C' if y < 38 else 'fc0C')
    body = ellipse(14, 29 + d, 7, 6)
    paint(g, body, ball(body, ['fc0C', 'fc1C', 'fc2C']))
    belt = clip(body, lambda x, y: y >= 31 + d)
    paint(g, belt, lambda x, y: 'fc08' if y > 31 + d else 'fc28', line=False)
    g.set(14, 32 + d, 'fc38')
    # arms
    armL = ellipse(6.5, 29 + d, 2.5, 3.2)
    paint(g, armL, ball(armL, ['fc0C', 'fc1C', 'fc2C']))
    armR = thick(line(20, 28 + d, 23, 24 + d), 2)
    paint(g, armR, ball(armR, ['fc0C', 'fc1C', 'fc2C']))
    hand = ellipse(23.5, 23.5 + d, 2.2, 2.2)
    paint(g, hand, lambda x, y: 'fc2C' if x + y < 46 + d else 'fc1C')
    # ears
    earL = poly([(7, 14 + d), (0, 9 + d), (0, 12 + d), (2, 17 + d), (8, 20 + d)])
    earR = mirror_x(earL, 14)
    paint(g, earL | earR, ball((earL | earR), ['fc0C', 'fc1C', 'fc2C']))
    for x, y in [(2, 12), (3, 13), (4, 14), (5, 15)]:
        g.set(x, y + d, 'fc0C')
        g.set(27 - x, y + d, 'fc0C')
    # head
    headm = ellipse(14, 18 + d, 8.5, 6.5)
    paint(g, headm, ball(headm, ['fc0C', 'fc1C', 'fc2C']))
    # helmet
    helm = clip(ellipse(14, 13 + d, 8, 7.5), lambda x, y: y <= 13 + d)
    brim = {(x, y) for x in range(5, 23) for y in (13 + d, 14 + d)} - {(5, 14 + d), (22, 14 + d)}
    paint(g, helm | brim, ball((helm | brim), ['fc08', 'fc28', 'fc38']))
    for x in range(6, 22):
        g.set(x, 14 + d, 'fc08' if x > 8 else 'fc28')
    lamp = ellipse(14, 9 + d, 2.2, 2.2)
    paint(g, lamp, lambda x, y: 'fc38')
    g.set(13, 8 + d, 'fc30') if False else None
    # face
    for ex in (9, 16):
        m = {(x, y) for x in range(ex, ex + 3) for y in range(16 + d, 19 + d)} - {(ex, 16 + d), (ex + 2, 16 + d)}
        for p in m:
            g.set(p[0], p[1], 'fc38')
    g.set(11, 17 + d, 'ink'); g.set(11, 18 + d, 'ink')
    g.set(16, 17 + d, 'ink'); g.set(16, 18 + d, 'ink')
    nose = ellipse(14, 20 + d, 1.6, 1.4)
    paint(g, nose, lambda x, y: 'fc2C' if x < 14 else 'fc1C', line=False)
    for x in range(11, 18):
        g.set(x, 22 + d, 'ink')
    g.set(10, 21 + d, 'ink'); g.set(18, 21 + d, 'ink')
    g.set(12, 23 + d, 'fc38') if False else None
    g.set(15, 22 + d, 'fc38')
    g.outline()
    return g


# ------------------------------------------------------------------ boss
def crystal(g, bx, by, h, w, t, ramp, glint):
    ax, ay = math.sin(t), -math.cos(t)
    px_, py_ = -ay, ax
    hw = w / 2.0
    pts = [(bx - px_ * hw, by - py_ * hw),
           (bx - px_ * hw + ax * h * 0.72, by - py_ * hw + ay * h * 0.72),
           (bx + ax * h, by + ay * h),
           (bx + px_ * hw + ax * h * 0.72, by + py_ * hw + ay * h * 0.72),
           (bx + px_ * hw, by + py_ * hw)]
    m = poly(pts)

    def fn(x, y):
        s = ((x + 0.5 - bx) * px_ + (y + 0.5 - by) * py_) / hw
        if s < -0.25:
            return ramp[2]
        if s < 0.35:
            return ramp[1]
        return ramp[0]
    paint(g, m, fn)
    tip = (int(bx + ax * h * 0.8 - px_ * hw * 0.35), int(by + ay * h * 0.8 - py_ * hw * 0.35))
    if tip in m:
        g.set(tip[0], tip[1], glint)
    return m


# ------------------------------------------------------------------ shroom
def shroom(f):
    g = Grid(24, 32)
    d = f
    stem = clip(ellipse(12, 22 + d * 0.5, 7, 8.5 - d * 0.5), lambda x, y: y <= 30)
    for fx in (8, 15):
        foot = clip(ellipse(fx + 0.5, 30, 2.6, 1.8), lambda x, y: y <= 30)
        paint(g, foot, lambda x, y: 'fc27')
    paint(g, stem, ball(stem, ['fc27', 'fc37', 'fc37']))
    cap = clip(ellipse(12, 12 + d, 11.5, 9.5), lambda x, y: y <= 14 + d)
    paint(g, cap, ball(cap, ['fc06', 'fc16', 'fc26']))
    for x in range(1, 23):
        if (x, 14 + d) in cap:
            g.set(x, 14 + d, 'fc06')
    for (sx, sy, r) in [(6, 7, 2.2), (14, 4.5, 1.6), (17.5, 10, 1.8), (10.5, 11, 1.3)]:
        spot = clip(ellipse(sx, sy + d, r, r * 0.9), lambda x, y: (x, y) in cap)
        paint(g, spot, lambda x, y: 'fc37' if x + y < sx + sy + d + 0.5 else 'fc27', line=False)
    # sleepy eyes (closed arcs)
    for ex in (7, 14):
        for (x, y) in [(ex, 19), (ex + 1, 20), (ex + 2, 20), (ex + 3, 19)]:
            g.set(x, y + d, 'ink')
    g.set(11, 23 + d, 'ink'); g.set(12, 23 + d, 'ink'); g.set(11, 24 + d, 'ink'); g.set(12, 24 + d, 'ink')
    # sleep bubble
    if f == 0:
        bub = ellipse(20, 21, 1.6, 1.6)
        paint(g, bub, lambda x, y: 'fc30' if (x, y) == (19, 20) else 'fc37', line=False)
    g.outline()
    return g


# ------------------------------------------------------------------ mole
def mole(f):
    g = Grid(32, 28)
    d = f
    GR = ['fc0C', 'fc00', 'fc10']
    PK = ['fc15', 'fc25', 'fc35']
    for fx in (9, 19):
        foot = clip(ellipse(fx + 2, 26, 3.6, 2), lambda x, y: y <= 26)
        paint(g, foot, lambda x, y: 'fc25' if y < 26 else 'fc15')
    body = clip(ellipse(16, 16 + d * 0.5, 12.5, 10 - d * 0.5), lambda x, y: y <= 25)
    paint(g, body, ball(body, GR))
    muzzle = ellipse(16, 19 + d, 6.5, 4)
    paint(g, muzzle, lambda x, y: 'fc10' if y < 20 + d or x < 14 else 'fc00', line=False)
    for ex in (10, 19):
        g.set(ex, 14 + d, 'ink'); g.set(ex + 1, 13 + d, 'ink'); g.set(ex + 2, 13 + d, 'ink'); g.set(ex + 3, 14 + d, 'ink')
    nose = ellipse(16, 17.5 + d, 3.2, 2.3)
    paint(g, nose, lambda x, y: 'fc35' if (x, y) in [(14, 16 + d), (15, 16 + d)] else ('fc25' if y <= 17 + d else 'fc15'))
    g.set(14, 21 + d, 'ink'); g.set(15, 22 + d, 'ink'); g.set(16, 21 + d, 'ink'); g.set(17, 22 + d, 'ink')
    for (a, b) in [((8, 18), (4, 17)), ((8, 20), (4, 21))]:
        for x, y in line(a[0], a[1] + d, b[0], b[1] + d):
            g.set(x, y, 'ink')
            g.set(31 - x, y, 'ink')
    lift = -1 if f == 1 else 0
    for hx in (4.5, 27.5):
        paw = ellipse(hx, 22 + lift, 3.8, 3.4)
        paint(g, paw, ball(paw, PK))
        for k in (-1, 1):
            for y in (23 + lift, 24 + lift):
                g.set(int(hx) + k, y, 'fc15')
    g.outline()
    return g


def hermit(f):
    g = Grid(32, 28)
    d = f
    CR = ['fc03', 'fc13', 'fc23']
    RD = ['fc06', 'fc16', 'fc26']
    for (a, b) in [((11, 22), (7, 26)), ((15, 23), (13, 27)), ((20, 23), (21, 27)), ((24, 22), (27, 26))]:
        for x, y in line(*a, *b):
            g.set(x, y, 'fc16')
            g.set(x + 1, y, 'fc06')
    shell = ellipse(20, 15, 10.5, 8.5)
    paint(g, shell, ball(shell, CR))
    th = 0.0
    prev = None
    while th < 3.4 * math.pi:
        r = 0.95 * th
        x = int(round(21 + r * math.cos(th)))
        y = int(round(15 + 0.8 * r * math.sin(th)))
        if (x, y) in shell:
            g.set(x, y, 'fc03')
        th += 0.08
    tipc = 'fc23' if f == 1 else 'fc03'
    for (bx, by, h, w, t) in [(16, 9, 8, 5, -0.35), (23, 8, 10, 6, 0.15), (28, 12, 6, 4, 0.8)]:
        crystal(g, bx, by, h, w, t, CR, tipc)
    body = ellipse(12, 20, 8.5, 5)
    paint(g, body, ball(body, RD))
    for sx in (9, 14):
        for y in range(13 - d, 17):
            g.set(sx, y, 'fc26' if sx == 9 else 'fc16')
        eb = {(x, y) for x in (sx - 1, sx, sx + 1) for y in (9 - d, 10 - d, 11 - d)}
        paint(g, eb, lambda x, y: 'ink')
        g.set(sx - 1, 9 - d, 'fc23')
    open_ = f
    claw = ellipse(4, 18, 4, 3.6)
    paint(g, claw, ball(claw, RD))
    for x in range(0, 4):
        g.set(x, 18 - open_, 'ink')
    small = ellipse(22, 21, 2.6, 2.2)
    paint(g, small, ball(small, RD))
    g.set(11, 22, 'ink'); g.set(12, 23, 'ink'); g.set(13, 22, 'ink')
    g.outline()
    return g


def bunny(f):
    g = Grid(24, 32)
    d = f
    CM = ['fc27', 'fc37', 'fc37']
    LF = ['fc0A', 'fc1A', 'fc2A']
    tilt = f
    earL = ellipse(7.5, 9 + d, 2.6, 7.5)
    earR = {(x + (1 if y < 8 + d else 0) * tilt, y) for (x, y) in ellipse(16.5, 9 + d, 2.6, 7.5)}
    for e_, inner in ((earR, 16), (earL, 7)):
        paint(g, e_, ball(e_, CM))
        for y in range(5 + d, 14 + d):
            for x in (inner, inner + 1):
                if (x, y) in e_ and (x - 1, y) in e_ and (x + 1, y) in e_:
                    g.set(x, y, 'fc27')
    # leaf tufts on the ear tips and the head
    leaf = poly([(10, 12 + d), (10, 7 + d), (12, 5 + d), (13, 8 + d), (13, 12 + d)])
    for fx in (6, 15):
        foot = clip(ellipse(fx + 1.5, 30, 3.2, 1.8), lambda x, y: y <= 30)
        paint(g, foot, lambda x, y: 'fc37' if y < 30 else 'fc27')
    head = clip(ellipse(12, 21 + d * 0.5, 9.5, 8.5 - d * 0.5), lambda x, y: y <= 30)
    paint(g, head, ball(head, CM))
    paint(g, leaf, lambda x, y: 'fc2A' if x < 12 else ('fc1A' if y < 10 + d else 'fc0A'))
    eye(g, 7, 19 + d, 2, 3, 'fc30')
    eye(g, 15, 19 + d, 2, 3, 'fc30')
    g.set(11, 23 + d, 'ink'); g.set(12, 24 + d, 'ink'); g.set(13, 23 + d, 'ink')
    g.set(5, 23 + d, 'fc27'); g.set(18, 23 + d, 'fc27')
    g.outline()
    return g



# ------------------------------------------------------------------ mimic
def mimic(f):
    """A chest whose lid is the upper jaw. Rigid object: straight edges are kept on purpose."""
    g = Grid(32, 32)
    WOOD, GOLD, DARK = 'fc17', 'fc28', 'fc08'
    lid_bot = 17 if f == 0 else 12
    lid_top = lid_bot - 9
    base_top = 20
    # mouth interior between the jaws (drawn first, the jaws overlap its edges)
    if f == 1:
        for y in range(lid_bot + 1, base_top):
            for x in range(4, 28):
                g.set(x, y, 'ink')
        for x in range(9, 23):
            g.set(x, lid_bot + 2, 'fc06')
    else:
        for y in range(lid_bot + 1, base_top):
            for x in range(3, 29):
                g.set(x, y, 'ink')
    # base box
    for y in range(base_top, 31):
        for x in range(2, 30):
            c = WOOD
            if y == base_top:
                c = GOLD if x < 20 else DARK
            elif y == 30 or x == 29:
                c = DARK
            elif x == 2:
                c = GOLD
            elif (y - base_top) % 4 == 0:
                c = DARK
            g.set(x, y, c)
    for bx in (5, 25):
        for y in range(base_top, 31):
            g.set(bx, y, GOLD)
            g.set(bx + 1, y, DARK)
    # lid: rounded top, rim band at the bottom edge
    for y in range(lid_top, lid_bot + 1):
        k = y - lid_top
        x0, x1 = (5, 26) if k == 0 else ((3, 28) if k == 1 else (2, 29))
        for x in range(x0, x1 + 1):
            c = WOOD
            if k <= 1 or (k == 2 and x < 12):
                c = GOLD if x < 20 else WOOD
            if x == x1 or (k >= 7 and x > 22):
                c = DARK
            if y >= lid_bot - 1:
                c = GOLD if (x < 20 and y == lid_bot - 1) else DARK
            if k == 4 and 2 < x < 29:
                c = DARK
            g.set(x, y, c)
    for bx in (5, 25):
        for y in range(lid_top + 1, lid_bot - 1):
            g.set(bx, y, GOLD)
            g.set(bx + 1, y, DARK)
    # teeth: upper row hangs from the lid, lower row stands on the box
    if f == 0:
        for tx in (4, 8, 12, 17, 21, 25):
            g.set(tx, lid_bot + 1, 'fc30'); g.set(tx + 1, lid_bot + 1, 'fc30')
        for tx in (6, 10, 15, 19, 23):
            g.set(tx, base_top - 1, 'fc30'); g.set(tx + 1, base_top - 1, 'fc30')
    else:
        for tx in (4, 8, 20, 24):
            for x in range(tx, tx + 3):
                g.set(x, lid_bot + 1, 'fc30')
            g.set(tx + 1, lid_bot + 2, 'fc30')
            g.set(tx + 1, lid_bot + 3, 'fc30') if tx in (8, 20) else None
        for tx in (6, 22):
            for x in range(tx, tx + 3):
                g.set(x, base_top - 1, 'fc30')
            g.set(tx + 1, base_top - 2, 'fc30')
        # tongue lolls out over the front lip
        tongue = poly([(12.5, 15), (19.5, 15), (20, 21), (19, 24), (16, 25.5), (13, 24), (12, 21)])
        paint(g, tongue, lambda x, y: 'fc06' if (x == 16 and 18 < y < 23) or x >= 19 else ('fc26' if x > 13 or y < 21 else 'fc06'))
    # one big eye in the place of the lock plate
    ey = lid_top + 2
    plate = {(x, y) for x in range(12, 20) for y in range(ey, ey + 7)} - {(12, ey), (19, ey), (12, ey + 6), (19, ey + 6)}
    paint(g, plate, lambda x, y: GOLD if x + y < 12 + ey + 3 else DARK, line=True)
    eye_m = {(x, y) for x in range(13, 19) for y in range(ey + 1, ey + 6)} - {(13, ey + 1), (18, ey + 1), (13, ey + 5), (18, ey + 5)}
    for x, y in eye_m:
        g.set(x, y, 'ink')
    if f == 0:
        # half-lidded: pretending to be a plain chest
        for x in range(13, 19):
            g.set(x, ey + 1, GOLD); g.set(x, ey + 2, GOLD)
        g.set(14, ey + 3, 'fc28')
        g.set(15, ey + 4, 'fc30')
    else:
        for x, y in [(14, ey + 2), (15, ey + 2), (14, ey + 3)]:
            g.set(x, y, 'fc30')
        g.set(17, ey + 4, 'fc26')
    g.outline()
    return g


SPRITES = [
    ('koke', 'コケだま', koke, (0.5, 1.0), '苔をかぶった丸い石の魔物。苔のおかっぱの下から目がのぞく。idle_1 は息を吐いて 1px つぶれる。'),
    ('bat', '坑道コウモリ', bat, (0.5, 0.5), '額に水晶のかけらを付けた毛玉のコウモリ。idle_0 で羽を上げ、idle_1 で下ろす（体は 1px 上がる）。'),
    ('goblin', 'つるはしゴブリン', goblin, (0.5, 1.0), '鉱夫の帽子（灯り付き）とつるはしの小鬼。大きな耳と寄り目で間の抜けた顔。idle_1 は 1px 沈む。'),
    ('boss', 'ジェムイーター', boss_rig.boss, (0.5, 1.0), '背中から水晶が生えた大トカゲ。背骨・肩と腰・四肢の関節から肉を付けた、横に脚を張るトカゲ。ヤモリのような大きな丸い目と口角の上がった口で愛嬌、口の奥から水晶の光がもれる。idle_1 は水晶と口の光の色の段を 1 つ上げて明滅する（体は動かさない）。'),
    ('shroom', 'ねぼけダケ', shroom, (0.5, 1.0), '坑道の入口に生える居眠りきのこ。idle_0 は鼻ちょうちん、idle_1 でかさが 1px 下がる。'),
    ('mole', 'ほりモグ', mole, (0.5, 1.0), '坑道を掘るもぐら。桃色の大きな鼻と手。idle_1 で手を 1px 上げる。'),
    ('hermit', 'ショウヤドカリ', hermit, (0.5, 1.0), '水晶の晶洞を殻にしたヤドカリ。idle_1 で目が伸び、水晶の先が光る。'),
    ('bunny', 'くさウサ', bunny, (0.5, 1.0), '草原の魔物。耳が葉っぱのうさぎ。idle_1 で耳がゆれ、体が 1px つぶれる。'),
    ('mimic', 'ひとくいばこ', mimic, (0.5, 1.0), 'B3 の宝箱に化けた魔物。坑道の宝箱と同じ木と金具の色。錠前の所が大きな 1 つ目。idle_0 はふたを少し開けて目を半分閉じた「ただの宝箱」、idle_1 でふたが大きく開き、歯と舌を出して目を見開く。'),
]


def build():
    frames = {}
    used = set()
    for name, jp, fn, anc, note in SPRITES:
        fr = [fn(0), fn(1)]
        frames[name] = fr
        for gr in fr:
            for r in gr.p:
                used |= {c for c in r if c}
    keys = sorted(used, key=lambda k: (k != 'ink', k))
    chars = 'KabcdefghijmnopqrstuvwxyzABCDEFGHIJLMNOPQRSTUVWXYZ0123456789'
    cmap = {k: chars[i] for i, k in enumerate(keys)}
    out = {
        'version': 1,
        'title': '戦闘の敵（正面）',
        'note': 'FC 風の正面の戦闘に出る敵。1 体 = 墨 + 3 色を 2 組まで（材質で組を分ける）。光は左上から。輪郭は墨 ink。コマは idle_0 / idle_1 の 2 つ。anchor は足元の中央（コウモリだけ体の中心）。',
        'paletteFile': 'assets/rpg.palette.json',
        'legend': {cmap[k]: k for k in keys},
        'sprites': {},
    }
    for name, jp, fn, anc, note in SPRITES:
        out['sprites'][name] = {
            'note': jp + ' — ' + note,
            'kind': 'character',
            'anchor': {'x': anc[0], 'y': anc[1]},
            'frames': {'idle_0': frames[name][0].rows(cmap), 'idle_1': frames[name][1].rows(cmap)},
        }
    json.dump(out, open(ROOT + '/assets/rpg.monsters.sprite.json', 'w'), ensure_ascii=False, indent=2)
    return frames


def previews(frames):
    allf = [frames[n][0] for n, *_ in SPRITES]
    allf1 = [frames[n][1] for n, *_ in SPRITES]
    ink = rgb('ink')
    c8, c0, c2d = rgb('fc08'), rgb('fc00'), rgb('fc2D')
    rock = lambda x, y: c0 if ((x // 3 + y // 5) % 4 == 0 and (x + y) % 2 == 0) else (c2d if y % 7 else c0)
    rock2 = lambda x, y: c8 if (x * 7 + y * 3) % 11 else c0
    for tag, fl in (('idle0', allf), ('idle1', allf1)):
        a = compose(fl, ink, 6)
        b = compose(fl, None, 6, bgfn=rock)
        c = compose(fl, None, 6, bgfn=rock2)
        canvas = a + b + c
        save(OUT + '/lineup_%s_x1.png' % tag, canvas, 1)
        save(OUT + '/lineup_%s_x4.png' % tag, canvas, 4)
    # per-monster: both frames side by side, 6x
    for n, *_ in SPRITES:
        save(OUT + '/%s_x6.png' % n, compose(frames[n], ink, 2), 6)


if __name__ == '__main__':
    fr = build()
    previews(fr)
    print('ok')
