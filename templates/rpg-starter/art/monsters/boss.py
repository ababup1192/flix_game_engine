"""ジェムイーター: skeleton first (spine, shoulder/hip, limb joints), flesh swept on the bones."""
import math
from lib import Grid, poly, ellipse, line
from rig import Part, draw, DARKER

BODY = ['fc07', 'fc17', 'fc27']
CUTS = [0.25, 0.68]

# ---- skeleton (x, y, flesh radius). Head turned toward the viewer on the left, body going back
# to the upper right, light from the upper left. Head is large (chibi) so the face stays friendly.
HEAD = [(11, 57, 5.0), (17, 54, 9.0), (25, 50, 12.0), (33, 45, 10.5)]
JAW = [(13, 62, 4.0), (20, 63.5, 6.0), (29, 61, 6.5), (35, 55, 5.0)]
SPINE = [(38, 50, 10.0), (48, 46, 14.5), (60, 44, 15.5), (72, 48, 13.5),
         (81, 55, 9.0), (87, 62, 7.0), (88, 69, 5.5), (83, 74, 4.2), (75, 76.5, 3.2), (67, 77.5, 2.2)]
LEG_NEAR_F = [(38, 62, 8.5), (27, 67, 6.8), (23, 72, 5.6), (22, 75, 5.2)]
LEG_FAR_F = [(56, 58, 7.0), (64, 64, 5.5), (62, 71, 4.6), (61, 75, 4.4)]
LEG_NEAR_H = [(72, 58, 10.0), (82, 64, 7.0), (80, 71, 5.2), (79, 75, 5.0)]

CRYSTALS_BACK = [(67, 34, 18, 8, 0.35), (50, 36, 14, 6, -0.35), (77, 41, 11, 5, 0.6)]
CRYSTALS_FRONT = [(58, 32, 31, 13, 0.04), (44, 39, 11, 6, -0.5), (71, 38, 9, 5, 0.75), (83, 50, 7, 4, 0.95), (88, 59, 5, 3, 1.2)]


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
    for x, y in m:
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            q = (x + dx, y + dy)
            if q not in m and g.get(*q) is not None:
                g.set(q[0], q[1], 'ink')
    for x, y in m:
        s = ((x + 0.5 - bx) * px_ + (y + 0.5 - by) * py_) / hw
        g.set(x, y, ramp[2] if s < -0.2 else (ramp[1] if s < 0.4 else ramp[0]))
    tip = (int(bx + ax * h * 0.78 - px_ * hw * 0.4), int(by + ay * h * 0.78 - py_ * hw * 0.4))
    if tip in m:
        g.set(tip[0], tip[1], glint)


def toes(g, hx, hy, spread, near, claw):
    for k, dx in enumerate(spread):
        r = 2.4 if near else 2.0
        m = {(x, y) for (x, y) in ellipse(hx + dx, 77 - abs(k - 1) * 0.3, r, 2.2) if y <= 78}
        for x, y in m:
            for ddx, ddy in ((1, 0), (-1, 0), (0, -1)):
                q = (x + ddx, y + ddy)
                if q not in m and g.get(*q) is not None:
                    g.set(q[0], q[1], DARKER.get(g.get(*q), 'ink'))
        for x, y in m:
            g.set(x, y, 'fc27' if (y < 77 and x < hx + dx + 0.5) else 'fc17')
        g.set(int(hx + dx - 1), 78, claw)


def scales(g, part, mask, every=9, offs=(0.35, 0.65)):
    """Short scale arcs on the lit top of a part, aligned with the bone."""
    S = part.samples
    for i in range(every // 2, len(S) - 2, every):
        x0, y0, r = S[i]
        x1, y1, _ = S[i + 2]
        tx, ty = x1 - x0, y1 - y0
        n = math.hypot(tx, ty) or 1
        tx, ty = tx / n, ty / n
        ux, uy = ty, -tx
        if uy > 0:
            ux, uy = -ux, -uy
        for k, o in enumerate(offs):
            cx, cy = x0 + ux * r * o + tx * (3 if k else 0), y0 + uy * r * o + ty * (3 if k else 0)
            for j in (-1, 0, 1):
                p = (int(cx + tx * j), int(cy + ty * j + (0 if j == 0 else 0.6)))
                c = g.get(*p)
                if p in mask and c in ('fc27', 'fc17'):
                    g.set(p[0], p[1], DARKER[c])


def eye_dome(g, cx, cy, r, pr, glint, shine, big):
    """Gecko eye: a lid dome over the skull line, the ink eye inside, glints at the upper left."""
    dome = ellipse(cx, cy, r, r * 1.04)
    for x, y in dome:
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            q = (x + dx, y + dy)
            if q not in dome and g.get(*q) not in (None, 'ink'):
                g.set(q[0], q[1], DARKER[g.get(*q)])
    for x, y in dome:
        g.set(x, y, 'fc27' if (x + 0.5 - cx) + (y + 0.5 - cy) < -r * 0.5 else 'fc17')
    for x, y in ellipse(cx + 0.4, cy + 0.6, pr, pr * 1.1):
        g.set(x, y, 'ink')
    gx, gy = int(cx - pr * 0.45), int(cy - pr * 0.4)
    pts = [(gx, gy), (gx + 1, gy), (gx, gy + 1), (gx + 1, gy + 1)] if big else [(gx, gy)]
    for p in pts:
        g.set(p[0], p[1], glint)
    if big:
        g.set(int(cx + pr * 0.5), int(cy + pr * 0.7), shine)


def boss(f):
    g = Grid(96, 80)
    CR = ['fc03', 'fc13', 'fc23'] if f == 0 else ['fc13', 'fc23', 'fc33']
    glint = 'fc23' if f == 0 else 'fc33'
    claw = 'fc23'

    # far front leg (behind the body, one shade darker)
    farf = Part(LEG_FAR_F, depth=1)
    draw(g, farf, BODY, CUTS)
    toes(g, 61, 76, (-3, 0.5, 4), False, claw)
    # spine: neck, shoulders, back, hips, tail
    spine = Part(SPINE)
    sm = draw(g, spine, BODY, CUTS, line='ink')
    # belly: the downward side of the trunk is a paler plated belly
    for (x, y), (nx, ny, t) in spine.px.items():
        if ny > 0.6 and 0.05 < t < 0.4 and g.get(x, y) != 'ink':
            g.set(x, y, 'fc17' if y % 3 == 0 else 'fc27')
    scales(g, spine, sm)
    for c in CRYSTALS_BACK:
        crystal(g, *c, CR, glint)
    for c in CRYSTALS_FRONT:
        crystal(g, *c, CR, glint)
    # near hind leg: thigh over the hip, knee pushed out to the side
    nh = Part(LEG_NEAR_H)
    draw(g, nh, BODY, CUTS)
    toes(g, 79, 76, (-4, 0, 4), True, claw)
    # near front leg (under the chin; the head overlaps its shoulder): elbow out to the side, deep overlap gets ink
    nf = Part(LEG_NEAR_F)
    draw(g, nf, BODY, CUTS, line='ink')
    toes(g, 22, 76, (-4.5, 0, 4.5), True, claw)
    # far eye sits behind the skull line (smaller: farther away)
    eye_dome(g, 37, 39, 5.0, 3.0, glint, CR[1], False)
    # lower jaw, then the head over it
    jaw = Part(JAW)
    draw(g, jaw, BODY, CUTS)
    head = Part(HEAD)
    hm = draw(g, head, BODY, CUTS, line='color')
    for (x, y), (nx, ny, t) in jaw.px.items():
        if ny > 0.25 and (x, y) not in hm and g.get(x, y) != 'ink':
            g.set(x, y, 'fc17' if x % 4 == 1 else 'fc27')
    # mouth: wide grin, corner turned up at the back, lit from the throat by crystal light
    x0, x1 = 10, 37
    for x in range(x0, x1):
        u = 58.0 + 0.05 * (x - x0) - max(0.0, (x - 29) * 0.6)
        gap = min(5.0, (x - x0) * 0.5) if x < 30 else max(0.0, 5.0 - (x - 30) * 0.9)
        for y in range(int(round(u)), int(round(u + gap))):
            d = math.hypot((x - 23) / 6.5, (y - (u + gap - 1.2)) / 2.2)
            c = CR[2] if d < 0.5 else (CR[1] if d < 1.0 else 'ink')
            g.set(x, y, c)
        if x in (14, 19, 25) and gap >= 2:
            g.set(x, int(round(u)), 'fc27')
            g.set(x + 1, int(round(u)), 'fc27')
            g.set(x, int(round(u)) + 1, 'fc27')
    # near eye: the big one, bulging over the skull
    eye_dome(g, 23, 43, 7.2, 4.8, glint, CR[1], True)
    # nostrils
    g.set(10, 54, 'ink'); g.set(14, 53, 'ink')
    # small horn crystal on the skull
    crystal(g, 31, 38, 7, 4, 0.35, CR, glint)
    g.outline()
    return g
