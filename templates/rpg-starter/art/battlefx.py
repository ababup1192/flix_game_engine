# 戦闘の背景の帯・呪文と攻撃の効果・タイトルの背景を assets/rpg.battlefx.sprite.json へ書き出す台本。
# 使い方: DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 art/battlefx.py [--preview]
# --preview は debug/battlefx/ に確かめの PNG を書く。
import json, math, os, random, struct, sys, zlib, itertools

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAL = json.load(open(os.path.join(ROOT, "assets/rpg.palette.json")))
RGB = {k: tuple(round(c * 255) for c in v["rgb"]) for k, v in PAL.items() if isinstance(v, dict)}

BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


def bayer(x, y):
    return (BAYER[y & 3][x & 3] + 0.5) / 16.0


class Canvas:
    def __init__(self, w, h, fill=None):
        self.w, self.h = w, h
        self.p = [[fill] * w for _ in range(h)]

    def ok(self, x, y):
        return 0 <= x < self.w and 0 <= y < self.h

    def put(self, x, y, c):
        if self.ok(x, y):
            self.p[y][x] = c

    def get(self, x, y):
        return self.p[y][x] if self.ok(x, y) else None

    def rect(self, x, y, w, h, c):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                self.put(xx, yy, c)

    def line(self, x0, y0, x1, y1, c):
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
        err = dx + dy
        while True:
            self.put(x0, y0, c)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy

    def copy(self):
        c = Canvas(self.w, self.h)
        c.p = [row[:] for row in self.p]
        return c


def ramp_pick(ramp, v, x, y):
    """暗→明の色の列 ramp を、明るさ v(0..1) で Bayer に落とす。"""
    v = max(0.0, min(0.999, v))
    f = v * (len(ramp) - 1)
    i = int(f)
    frac = f - i
    if i + 1 < len(ramp) and frac > bayer(x, y):
        return ramp[i + 1]
    return ramp[i]


def lum(k):
    r, g, b = RGB[k]
    return 0.299 * r + 0.587 * g + 0.114 * b


def cdist(a, b):
    ra, ga, ba = RGB[a]
    rb, gb, bb = RGB[b]
    return (ra - rb) ** 2 * 2 + (ga - gb) ** 2 * 4 + (ba - bb) ** 2 * 3


PROTECT = {"fc38": 400, "fc30": 400, "fc27": 40, "fc28": 400}


def enforce_attr(cv, blk=16, maxc=4, report=None, name=""):
    """16x16 の升目ごとに色を maxc 色までに減らす（FC の背景属性）。減らした色は近い色へ寄せる。"""
    for by in range(0, cv.h, blk):
        for bx in range(0, cv.w, blk):
            cnt = {}
            for y in range(by, min(by + blk, cv.h)):
                for x in range(bx, min(bx + blk, cv.w)):
                    c = cv.p[y][x]
                    if c is not None:
                        cnt[c] = cnt.get(c, 0) + 1
            if len(cnt) <= maxc:
                continue
            cols = list(cnt)
            best = None
            for sub in itertools.combinations(cols, maxc):
                err = 0
                for c in cols:
                    if c not in sub:
                        err += cnt[c] * PROTECT.get(c, 1) * min(cdist(c, s) for s in sub)
                if best is None or err < best[0]:
                    best = (err, sub)
            sub = best[1]
            if report is not None:
                report.append("%s (%d,%d): %s -> %s" % (name, bx, by, sorted(cols), sorted(sub)))
            for y in range(by, min(by + blk, cv.h)):
                for x in range(bx, min(bx + blk, cv.w)):
                    c = cv.p[y][x]
                    if c is not None and c not in sub:
                        cv.p[y][x] = min(sub, key=lambda s: cdist(c, s))


# ---------------------------------------------------------------- 共通の部品

def ridge(w, base, amp, seed, octaves=((48, 1.0), (19, 0.45), (7, 0.18))):
    """山並みの上端の y（列ごと）。"""
    r = random.Random(seed)
    ph = [(r.random() * 6.28, p, a) for p, a in octaves]
    out = []
    for x in range(w):
        v = 0
        for p0, per, a in ph:
            v += math.sin(x / per * 6.28 + p0) * a
        out.append(int(round(base - v * amp)))
    return out


def peaks_of(h):
    pk = []
    for x in range(1, len(h) - 1):
        if h[x] <= h[x - 1] and h[x] < h[x + 1]:
            pk.append(x)
    if not pk:
        pk = [min(range(len(h)), key=lambda i: h[i])]
    return pk


def mountain(cv, h, lit, mid, dark, y_bottom, snow=None, snow_depth=0, lean=0.55, seed=1, bottom_fade=None):
    """2 面塗りの山並み: 峰から右下へ降りる稜線の左が受光、右が影。境は Bayer でつなぐ。"""
    pk = peaks_of(h)
    r = random.Random(seed)
    for x in range(cv.w):
        p = min(pk, key=lambda q: abs(q - x) * 1.0 + h[q] * 0.3)
        for y in range(max(0, h[x]), y_bottom):
            d = y - h[p]
            rx = p + d * lean + math.sin(y * 0.7 + p) * 1.5
            t = (rx - x) / 3.0  # 正なら稜線の左（受光）
            if t > 0.6:
                c = lit
            elif t > -0.6:
                c = lit if bayer(x, y) < (t + 0.6) / 1.2 else mid
            elif t > -6 - d * 0.15:
                c = mid
            else:
                c = dark if dark else mid
            if snow and y - h[x] < snow_depth and h[x] < h[p] + snow_depth * 1.3:
                c = snow if (c == lit or bayer(x, y) < 0.5) else c
            if bottom_fade and y >= y_bottom - bottom_fade[1]:
                k = (y - (y_bottom - bottom_fade[1])) / bottom_fade[1]
                if bayer(x, y) < k:
                    c = bottom_fade[0]
            cv.put(x, y, c)


def voronoi_rock(cv, x0, y0, x1, y1, cell, seed, shade, mask=None):
    """石積み・岩肌: 点を散らし、近い点ごとの石にする。shade(x, y, rel) -> 色。rel は石の中の位置（-1 左上〜 +1 右下）と縁かどうか。"""
    r = random.Random(seed)
    pts = []
    yy = y0 - cell
    row = 0
    while yy < y1 + cell:
        xx = x0 - cell + (cell // 2 if row % 2 else 0)
        while xx < x1 + cell:
            pts.append((xx + r.uniform(-cell * 0.35, cell * 0.35), yy + r.uniform(-cell * 0.3, cell * 0.3), r.uniform(0.75, 1.3)))
            xx += cell * r.uniform(0.85, 1.25)
        yy += cell * 0.8
        row += 1

    def owner(x, y):
        best, bi = 1e9, -1
        for i, (px, py, s) in enumerate(pts):
            if abs(px - x) > cell * 2 or abs(py - y) > cell * 2:
                continue
            d = ((px - x) ** 2 + ((py - y) * 1.25) ** 2) / s
            if d < best:
                best, bi = d, i
        return bi

    own = {}
    for y in range(y0, y1):
        for x in range(x0, x1):
            if mask and not mask(x, y):
                continue
            own[(x, y)] = owner(x, y)
    for (x, y), i in own.items():
        px, py, s = pts[i]
        edge = own.get((x + 1, y), i) != i or own.get((x, y + 1), i) != i
        top_edge = own.get((x - 1, y), i) != i or own.get((x, y - 1), i) != i
        rel = ((x - px) + (y - py)) / (cell * 0.9)
        c = shade(x, y, rel, edge, top_edge)
        if c is not None:
            cv.put(x, y, c)


# ---------------------------------------------------------------- 戦闘の背景の帯（256x64）
# どれも 16x16 の升目に「墨 + 3 色」で収まるように、材質の境を升目の線へ寄せて組む。

def banded(colors, bounds, y, x, width):
    """縦の帯: bounds[i] の y で colors[i] → colors[i+1]。境の前後 width 行は Bayer で渡す。"""
    i = 0
    for b in bounds:
        if y >= b + width / 2.0:
            i += 1
            continue
        if y > b - width / 2.0:
            t = (y - (b - width / 2.0)) / width
            return colors[i + 1] if bayer(x, y) < t else colors[i]
        break
    return colors[i]


def bg_plains():
    W, H = 256, 64
    cv = Canvas(W, H)
    # 空（0〜31 の升目は 空 2 色 + 山 2 色で 4 色）: 上の青 → 地平の淡い水色
    for y in range(0, 34):
        for x in range(W):
            cv.put(x, y, banded(["fc12", "fc21", "fc31"], [6, 20], y, x, 10))
    # 雲（上の升目だけ。白は芯の数画素）
    for cx, cy, rw in [(44, 7, 22), (150, 4, 30), (226, 9, 16)]:
        for y in range(cy - 6, cy + 3):
            for x in range(cx - rw - 4, cx + rw + 5):
                dx = (x - cx) / rw
                if abs(dx) > 1.1:
                    continue
                bumps = abs(math.sin((x - cx) * 0.33 + cx)) * 2.5
                top = cy - 1 - bumps * (1 - dx * dx) - (1 - dx * dx) * 2
                if top <= y <= cy + (1 if abs(dx) < 0.75 else 0):
                    k = (y - top) / max(1.0, cy + 1 - top)
                    cv.put(x, y, "fc30" if (k < 0.3 and abs(dx) < 0.6) else ("fc31" if k < 0.8 else "fc21"))
    # 奥: 遠い山（受光 fc21・影 fc11・雪 fc30）。空の色へ寄せ、裾は丘に隠れる
    far = [max(17, v) for v in ridge(W, 25, 5, seed=3, octaves=((52, 1.0), (21, 0.5), (9, 0.15)))]
    mountain(cv, far, "fc21", "fc11", None, 40, lean=0.75, seed=3)
    for y in range(29, 40):
        for x in range(W):
            if cv.get(x, y) == "fc21" and bayer(x, y) < (y - 28) / 4.0:
                cv.put(x, y, "fc11")
    # 雪は高い峰の先だけ（受光面は全部、影の面は端だけ）
    for p in peaks_of(far):
        if far[p] > 21:
            continue
        for y in range(far[p], far[p] + 4):
            for x in range(p - 4, p + 4):
                if y < far[x] or abs(x - p) > (y - far[p]) + 0.5:
                    continue
                if x <= p + (y - far[p]) * 0.5 or (y - far[p]) < 1:
                    cv.put(x, y, "fc30")
    # 中: 丘（上端は 28〜32 で山の裾を隠す）と森の帯
    mid = ridge(W, 40, 2.0, seed=8, octaves=((70, 1.0), (23, 0.5)))
    for x in range(W):
        for y in range(mid[x], H):
            d = y - mid[x]
            cv.put(x, y, ramp_pick(["fc0A", "fc1A", "fc2A"], 0.95 - d / 14.0, x, y))
    r = random.Random(11)
    x = -4
    forest = []
    while x < W + 4:
        s = r.choice([3, 3, 4, 4, 5])
        forest.append((x, s))
        x += r.randint(s + 1, s * 2 + 6)
    for tx, s in forest:
        ty = mid[max(0, min(tx, W - 1))] + 3
        for y in range(max(32, ty - s * 2 - 1), ty + 1):
            for xx in range(tx - s - 1, tx + s + 2):
                dy = (y - (ty - s)) / (s + 0.5)
                dx = (xx - tx) / (s + 0.5)
                if dx * dx + dy * dy * 0.55 > 1.0 or y > ty:
                    continue
                q = dx * 0.8 + dy * 0.6
                if q < -0.55:
                    c = "fc2A" if bayer(xx, y) < 0.5 else "fc1A"
                elif q < 0.25:
                    c = "fc1A"
                else:
                    c = "fc0A"
                if dx * dx + dy * dy * 0.55 > 0.8 and q > 0.1:
                    c = "fc0A"
                cv.put(xx, y, c)
    # 手前: 草原（奥が明るく、手前へ暗く）。下の端は墨へ落とす
    for x in range(W):
        gy = 45 + int(math.sin(x * 0.045) * 1.5 + math.sin(x * 0.13 + 1))
        cv.put(x, gy - 1, "fc0A")
        for y in range(gy, H):
            v = 0.95 - (y - gy) / 16.0
            c = ramp_pick(["fc0A", "fc1A", "fc2A"], v, x, y)
            if y >= H - 5 and bayer(x, y) < (y - (H - 6)) / 5.0:
                c = "ink"
            cv.put(x, y, c)
    # 草むら（2〜4px の塊。奥ほど小さく疎ら）
    for i in range(60):
        tx, ty = r.randint(0, W - 1), r.randint(48, H - 6)
        hgt = 2 if ty < 54 else r.choice([3, 4])
        for k in range(hgt):
            cv.put(tx + (k % 2) * (1 if i % 2 else -1), ty - k, "fc2A")
        cv.put(tx + 1, ty, "fc0A")
        cv.put(tx + 1, ty + 1, "fc0A")
    # 手前の茂み（左下と右下。大きさと高さを変える）
    for bx, by, rad in [(-2, 60, 13), (17, 64, 8), (240, 62, 12), (258, 56, 10)]:
        for y in range(by - rad, H):
            for x in range(bx - rad - 2, bx + rad + 3):
                dx = (x - bx) / (rad + 1.5)
                dy = (y - by) / rad
                wob = math.sin(x * 1.3 + y * 0.7) * 0.1
                rr2 = dx * dx + dy * dy
                if rr2 < 1.0 + wob:
                    q = dx + dy
                    if rr2 > 0.8 + wob and q < -0.2:
                        c = "fc2A"
                    elif q < -0.5:
                        c = "fc1A"
                    elif q < 0.5:
                        c = "fc0A"
                    else:
                        c = "ink"
                    cv.put(x, y, c)
    return cv


def bg_cave():
    W, H = 256, 64
    cv = Canvas(W, H, "ink")
    cx = 128

    def in_opening(x, y):
        # 奥の口: 上が丸いアーチ。縁は列ごとに揺らす
        half = 31 + math.sin(y * 0.6) * 1.2
        top = 17 + ((x - cx) / 31.0) ** 2 * 8 + math.sin(x * 0.9) * 0.8
        return abs(x - cx) < half and y >= top and y < 50

    def rock_shade(x, y, rel, edge, top_edge):
        outer = x < 32 or x >= 224
        dist = min(1.0, abs(x - cx) / 110.0)
        v = 0.22 + dist * 0.42 - rel * 0.3
        if edge:
            return "ink"
        if top_edge:
            v += 0.22
        return ramp_pick(["ink", "fc0C", "fc00", "fc10"] if outer else ["ink", "fc0C", "fc00"], v, x, y)

    voronoi_rock(cv, 0, 0, W, 50, 11, 21, rock_shade, mask=lambda x, y: not in_opening(x, y))
    # 奥: 坑道の先の闇（縁ほど岩の青が残る）・遠い支柱・遠いたいまつ
    for y in range(0, 50):
        for x in range(90, 167):
            if not in_opening(x, y):
                continue
            e = min(abs(abs(x - cx) - 31) / 9.0, (y - 17) / 12.0)
            cv.put(x, y, "fc0C" if bayer(x, y) > e + 0.3 else "ink")
    for y in range(29, 48):
        cv.put(115, y, "fc08")
        cv.put(140, y, "fc08")
    for x in range(113, 143):
        cv.put(x, 28, "fc08")
    cv.put(127, 36, "fc27")
    cv.put(127, 37, "fc08")
    # 遠いたいまつの照り返し（少しだけ）
    for x, y in [(125, 36), (129, 35), (126, 39), (128, 38)]:
        if cv.get(x, y) == "ink":
            cv.put(x, y, "fc0C")
    # 梁の下の影（梁が上の升目を占めるので、その下の岩は墨と暗い茶だけ）
    for y in range(0, 16):
        for x in range(W):
            c = cv.get(x, y)
            if c == "ink":
                continue
            k = (y - 9) / 7.0
            cv.put(x, y, "fc08" if bayer(x, y) < k * 0.9 and c in ("fc00", "fc10") else "ink")
    # 床（48〜63 の升目は 墨・暗い茶・黄土・レールの灰）
    for y in range(46, H):
        for x in range(W):
            if y < 50 and not in_opening(x, y) and bayer(x, y) > (y - 45) / 5.0:
                continue
            d = (y - 46) / 18.0
            v = 0.3 + d * 0.5 - abs(x - cx) / 300.0
            c = ramp_pick(["ink", "fc08", "fc18"], v, x, y)
            if y >= H - 6 and bayer(x, y) < (y - (H - 7)) / 6.0:
                c = "ink"
            cv.put(x, y, c)
    # 枕木とレール（口へ集まる）
    sy = 47
    gaps = []
    yy = 47.0
    step = 1.6
    while yy < H:
        gaps.append(int(yy))
        yy += step
        step *= 1.35
    for y in range(47, H):
        t = (y - 47) / (H - 47)
        lx = int(round(121 - t * 44))
        rx = int(round(134 + t * 44))
        if y in gaps:
            ext = 2 + int(t * 7)
            for x in range(lx - ext, rx + ext + 1):
                cv.put(x, y, "fc08")
                if t > 0.25:
                    cv.put(x, y + 1, "fc08")
                    cv.put(x, y - 1, "fc18") if x % 3 else None
        cv.put(lx, y, "fc10")
        cv.put(rx, y, "fc10")
        if t > 0.4:
            cv.put(lx - 1, y, "ink")
            cv.put(rx + 1, y, "ink")
    # 床の石ころ（壁ぎわ。大きさを変える）
    for bx, by, w, h in [(70, 54, 5, 3), (78, 58, 3, 2), (180, 55, 6, 3), (60, 60, 4, 2), (196, 59, 3, 2)]:
        for y in range(by - h, by + 1):
            for x in range(bx - w, bx + w + 1):
                if ((x - bx) / (w + 0.3)) ** 2 + ((y - by) / (h + 0.3)) ** 2 <= 1:
                    q = (x - bx) / w + (y - by) / h
                    cv.put(x, y, "fc18" if q < -0.6 else ("fc08" if q < 0.4 else "ink"))
        for x in range(bx - w + 1, bx + w + 2):
            cv.put(x, by + 1, "ink")

    # 手前: 板の支柱（左右 2 本と梁）。木目は横の短い筋、光は左上
    def timber(x0, y0, w, h, vertical=True):
        for y in range(y0, y0 + h):
            for x in range(x0, x0 + w):
                u = (x - x0) / max(1, w - 1) if vertical else (y - y0) / max(1, h - 1)
                c = "fc27" if u < 0.2 else ("fc17" if u < 0.72 else "fc08")
                cv.put(x, y, c)
        r = random.Random(x0 * 7 + y0)
        for i in range((w * h) // 14):
            gx, gy = r.randint(x0 + 1, x0 + w - 2), r.randint(y0 + 1, y0 + h - 2)
            L = r.randint(2, 5)
            for k in range(L):
                px_, py_ = (gx, gy + k) if vertical else (gx + k, gy)
                if cv.get(px_, py_) == "fc17":
                    cv.put(px_, py_, "fc08")
        for x in range(x0 - 1, x0 + w + 1):
            cv.put(x, y0 - 1, "ink")
            cv.put(x, y0 + h, "ink")
        for y in range(y0 - 1, y0 + h + 1):
            cv.put(x0 - 1, y, "ink")
            cv.put(x0 + w, y, "ink")

    timber(33, 9, 10, 39)
    timber(213, 9, 10, 39)
    timber(26, 2, 204, 6, vertical=False)
    # 梁の継ぎ目と鉄の鎹（かすがい）
    for x in (90, 166):
        for y in range(2, 8):
            cv.put(x, y, "ink")
    for x in (36, 216):
        cv.put(x, 4, "ink"); cv.put(x + 3, 4, "ink")
    # 支柱の足もとの接地の影
    for x0 in (33, 213):
        for x in range(x0 - 3, x0 + 13):
            cv.put(x, 48, "ink")
            if bayer(x, 49) < 0.5:
                cv.put(x, 49, "ink")

    # たいまつ: 支柱の内側。岩を暖色の段へ置き換え（近いほど明るい）
    def torch(tx, ty, side):
        for y in range(16, 48):
            for x in range(tx - 26, tx + 27):
                if not (32 <= x < 224):
                    continue
                g = 1 - math.hypot((x - tx) * 0.85, (y - ty) * 1.0) / 26.0
                if g <= 0:
                    continue
                c = cv.get(x, y)
                if c not in ("fc0C", "fc00"):
                    continue
                if g > 0.5:
                    nc = "fc17" if c == "fc00" else "fc08"
                    if c == "fc00" and g > 0.72 and bayer(x, y) < (g - 0.72) * 4:
                        nc = "fc27"
                else:
                    if bayer(x, y) < (g / 0.5) * 1.1:
                        nc = "fc08"
                    else:
                        nc = c if c == "fc0C" else "fc0C"
                cv.put(x, y, nc)
        # 金具（壁から出る腕と受け皿）
        for k in range(4):
            cv.put(tx - side * (4 - k), ty + 4, "ink")
        cv.put(tx - side * 4, ty + 3, "ink")
        cv.rect(tx - 1, ty + 1, 3, 4, "fc08")
        cv.put(tx - 1, ty + 1, "fc27")
        for x in range(tx - 2, tx + 3):
            cv.put(x, ty + 5, "ink")
        flame = [
            "...a...",
            "..aa...",
            "..aaa..",
            ".aaya..",
            ".ayya.a",
            "aayyyaa",
            "ayyyyya",
            "ayyyyya",
            ".ayyya.",
            "..aaa..",
        ]
        for j, row in enumerate(flame):
            for i, ch in enumerate(row):
                if ch == "a":
                    cv.put(tx - 3 + i, ty - 9 + j, "fc27")
                elif ch == "y":
                    cv.put(tx - 3 + i, ty - 9 + j, "fc38")

    torch(54, 24, 1)
    torch(201, 24, -1)
    return cv


def bg_lake():
    W, H = 256, 64
    cv = Canvas(W, H, "ink")
    shore = 31
    # 奥: 向こう岸の岩壁（墨と暗い紫だけ。明るさの差を詰めて奥へ退かせる）
    def far_shade(x, y, rel, edge, top_edge):
        if edge:
            return "ink"
        v = 0.42 - rel * 0.3 - y / 70.0
        if top_edge and bayer(x, y) < 0.5:
            v += 0.15
        return ramp_pick(["ink", "fc03", "fc13"], v * 0.7, x, y)

    voronoi_rock(cv, 0, 0, W, shore, 13, 5, far_shade)
    # 天井から下がる鍾乳石（手前の層。光の縁は左）
    r = random.Random(31)
    x = 3
    while x < W:
        w = r.randint(4, 9)
        L = r.randint(5, 13)
        for y in range(0, L):
            half = w / 2.0 * (1 - y / L) ** 0.9
            for xx in range(int(round(x - half)), int(round(x + half)) + 1):
                u = (xx - (x - half)) / (2 * half + 0.01)
                c = "fc13" if u < 0.3 else ("fc03" if u < 0.6 else "ink")
                cv.put(xx, y, c)
        x += r.randint(10, 26)

    # 中: 水晶の群れ。柱ごとに受光面・中・影の 3 面、芯に 1 点の光
    def prism(bx, base, hgt, wid, lean):
        tipx = bx + lean
        for y in range(base - hgt, base + 1):
            t = (y - (base - hgt)) / hgt  # 0 先 〜 1 根元
            cxl = tipx + (bx - tipx) * t
            half = wid * min(1.0, t * 2.4 + 0.15)
            for xx in range(int(math.floor(cxl - half)), int(math.ceil(cxl + half)) + 1):
                u = (xx - (cxl - half)) / (2 * half + 0.01)
                if u < 0 or u > 1:
                    continue
                if u < 0.1 or u > 0.9 or (t < 0.08):
                    c = "ink"
                elif u < 0.45:
                    c = "fc33"
                elif u < 0.68:
                    c = "fc23"
                else:
                    c = "fc13"
                cv.put(xx, y, c)

    def cluster(gx, s, flip=1, tall=18):
        # 岩肌に落ちる水晶の光（壁の紫を明るい段へ）
        for y in range(0, shore):
            for xx in range(gx - 18, gx + 34):
                d = math.hypot(xx - gx - 8, (y - shore + 8) * 1.1) / 20.0
                if d < 1 and cv.get(xx, y) == "fc03" and bayer(xx, y) < (1 - d) * 1.4:
                    cv.put(xx, y, "fc13")
                if d < 0.55 and cv.get(xx, y) == "ink" and bayer(xx, y) < (0.55 - d) * 1.2:
                    cv.put(xx, y, "fc03")
        m = gx + 8
        prism(m - 9 * flip, shore, 11 + s // 2, 3.0, -6 * flip)
        prism(m + 10 * flip, shore, 6 + s // 3, 2.6, 6 * flip)
        prism(m, shore + 1, tall, 4.8, -2 * flip)
        prism(m - 6 * flip, shore + 1, 7, 2.6, -3 * flip)
        if s > 2:
            prism(m + 5 * flip, shore + 1, 10, 3.0, 2 * flip)

    # 岸（中の層の地面。水晶の根元を受ける）
    for x in range(W):
        sy = shore + int(math.sin(x * 0.07) * 1.2)
        for y in range(sy - 2, sy + 1):
            cv.put(x, y, "fc03" if y == sy - 2 and (x // 2) % 3 else "ink")
    groups = [(14, 6), (70, 0), (168, 3), (222, 8)]
    for (gx, s), flip, tall in zip(groups, [1, -1, 1, -1], [19, 11, 15, 21]):
        cluster(gx, s, flip, tall)
    # 手前: 地底湖。奥ほど明るく、手前へ暗く
    for y in range(shore + 2, H):
        for x in range(W):
            d = (y - shore - 2) / (H - shore - 2)
            cv.put(x, y, banded(["fc12", "fc02", "ink"], [shore + 4, shore + 21], y, x, 10))
    # 水晶の光が縦に映る（横に裂けた短い線。奥ほど明るく）
    for gx, s in groups:
        for y in range(shore + 2, H - 5):
            k = (y - shore) / (H - shore)
            if (y * 7 + gx) % 5 in (0, 3):
                continue
            ww = 1 + int((1 - k) * 2.5)
            off = int(math.sin(y * 1.3 + gx) * 1.6)
            for xx in range(gx + 8 + off - ww, gx + 9 + off + ww):
                cv.put(xx, y, "fc23" if k < 0.35 else "fc13")
    # 波頭（横の短い線。奥ほど短く密に、手前は長く疎ら）
    for i in range(80):
        y = r.randint(shore + 3, H - 7)
        x = r.randint(0, W - 1)
        k = (y - shore) / (H - shore)
        if r.random() < k * 0.6:
            continue
        L = 2 + int(k * 6)
        for j in range(L):
            if cv.get(x + j, y) in ("fc02", "fc12", "ink"):
                cv.put(x + j, y, "fc21" if k < 0.3 else ("fc12" if k < 0.65 else "fc02"))
    # 手前の岩（左右の下。墨の塊に光の縁）
    for bx, by, rw, rh in [(6, 66, 24, 15), (52, 67, 10, 6), (250, 66, 22, 18), (204, 67, 9, 5)]:
        for y in range(by - rh, H):
            for x in range(bx - rw, bx + rw + 1):
                dx, dy = (x - bx) / rw, (y - by) / rh
                wob = math.sin(x * 0.9) * 0.05
                rr2 = dx * dx + dy * dy
                if rr2 <= 1 + wob:
                    q = dx + dy
                    if rr2 > 0.8 and q < -0.3:
                        c = "fc13" if q < -1.1 else "fc03"
                    elif q < -0.7 and bayer(x, y) < 0.5:
                        c = "fc03"
                    else:
                        c = "ink"
                    cv.put(x, y, c)
    for y in range(H - 5, H):
        for x in range(W):
            if bayer(x, y) < (y - (H - 6)) / 5.0:
                cv.put(x, y, "ink")
    return cv


# ---------------------------------------------------------------- タイトルの背景（256x240・2 コマ）

def title_bg(frame):
    W, H = 256, 240
    cv = Canvas(W, H)
    horizon = 152
    sunx = 112
    # 夜明けの空: 墨 → 紺 → 群青 → 菫 → 藤 → 薄紫 → 桃 → 黄。帯の間は Bayer の帯で渡す。
    # 日の出の真上だけ下の帯を持ち上げて、光のドームにする
    sky = ["ink", "fc02", "fc03", "fc13", "fc23", "fc33", "fc35", "fc37", "fc38"]
    bounds = [20, 44, 66, 88, 108, 124, 137, 146]
    for y in range(0, horizon):
        for x in range(W):
            lift = max(0.0, 1 - abs(x - sunx) / 90.0) ** 2
            bs = [b - lift * (6 + i * 2.2) if i >= 3 else b for i, b in enumerate(bounds)]
            cv.put(x, y, banded_var(sky, bs, y, x, [10, 10, 10, 10, 9, 8, 7, 6]))
    # 星（上の暗い所だけ・まばら。明るいのは数個）
    r = random.Random(77)
    for i in range(40):
        x, y = r.randint(0, W - 1), r.randint(2, 40)
        if cv.get(x, y) in ("ink", "fc02"):
            cv.put(x, y, "fc32" if r.random() < 0.8 else "fc30")
    for x, y in [(30, 12), (204, 22)]:
        cv.put(x, y, "fc30")
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            cv.put(x + dx, y + dy, "fc32")
    # 横にたなびく雲（下側が日に照らされる）
    def wisp(cx, cy, L, top, lit):
        for x in range(cx - L, cx + L + 1):
            u = abs(x - cx) / L
            th = 1 + (u < 0.65) + (u < 0.3)
            wav = int(round(math.sin(x * 0.11 + cx) * 0.8))
            for k in range(th):
                y = cy - k + wav
                cv.put(x, y, lit if k == 0 else top)
    wisp(52, 84, 30, "fc13", "fc23")
    wisp(84, 92, 16, "fc13", "fc23")
    wisp(206, 76, 34, "fc13", "fc23")
    wisp(170, 104, 22, "fc23", "fc35")
    wisp(30, 112, 18, "fc23", "fc35")
    wisp(236, 116, 14, "fc23", "fc35")
    # 奥: 遠い山並み（空へ寄せた 2 段）
    far = ridge(W, 124, 8, seed=41)
    mountain(cv, far, "fc33", "fc23", None, horizon, lean=0.8, seed=41)
    # 中: 2 枚目の山並み
    mid = ridge(W, 134, 8, seed=52, octaves=((64, 1.0), (23, 0.5), (8, 0.15)))
    mountain(cv, mid, "fc23", "fc13", None, horizon, lean=0.7, seed=52)

    # 北の山（主役の山。右寄り・中腹に坑道の口）
    def north(x):
        d = x - 184
        k = 0.66 if d < 0 else 0.74
        return int(round(90 + abs(d) * k + (d * d) / 300.0 + math.sin(x * 0.35) * 1.1 + (3 if 168 < x < 174 else 0)))
    nh = [north(x) for x in range(W)]
    mountain(cv, nh, "fc03", "fc02", None, horizon, lean=0.55, seed=9)
    # 稜線の受光（左の斜面の縁だけ 1〜2px）と、峰の雪
    for x in range(W):
        if x < 184:
            for k in range(8):
                y = nh[x] + k
                if cv.get(x, y) == "fc03" and (k == 0 or bayer(x, y) < 0.75 - k * 0.1):
                    cv.put(x, y, "fc13")
    for x in range(168, 198):
        for y in range(nh[x], nh[x] + 6):
            depth = y - nh[x]
            if depth < 4.5 - abs(x - 184) * 0.28:
                if x <= 184 + depth * 0.6:
                    cv.put(x, y, "fc32")
                elif bayer(x, y) < 0.5:
                    cv.put(x, y, "fc13")
    # 手前の山すそ（墨に近い 2 段）
    near = ridge(W, 145, 4, seed=63, octaves=((90, 1.0), (31, 0.4)))
    mountain(cv, near, "fc02", "ink", None, horizon, lean=0.5, seed=63)
    # 坑道の口: 板の枠（fc08）と中の灯り、口のまわりに暖かい光の 1 段
    mx, my = 176, 121
    for y in range(my - 5, my + 5):
        for x in range(mx - 7, mx + 8):
            d = math.hypot(x - mx, (y - my) * 1.4) / 7.0
            if d < 1 and cv.get(x, y) in ("fc03", "fc02") and bayer(x, y) < (1 - d) * 0.8:
                cv.put(x, y, "fc06")
    arch = [
        ".kkk.",
        "kaaak",
        "kayak",
        "kyyyk",
        "kyyyk",
    ]
    for j, row in enumerate(arch):
        for i, ch in enumerate(row):
            c = {"k": "fc08", "a": "fc27", "y": "fc38"}.get(ch)
            if c:
                cv.put(mx - 2 + i, my - 3 + j, c)
    for x in range(mx - 3, mx + 4):
        cv.put(x, my + 2, "ink")
    # 坑道へ登るつづら折りの道
    path = [(mx - 3, my + 3), (mx - 8, my + 7), (mx - 1, my + 12), (mx - 9, my + 17), (mx - 4, my + 23)]
    for a, b in zip(path, path[1:]):
        cv.line(a[0], a[1], b[0], b[1], "fc13")

    # 湖。水際の線 wl は左（村の側）が少し奥、右が手前
    wl = [int(round(203 + 4 * min(1.0, max(0.0, (x - 60) / 140.0)) + math.sin(x * 0.07) * 1.2)) for x in range(W)]
    lake_bottom = max(wl) + 1
    above = cv.copy()

    def sky_at(x, y):
        lift = max(0.0, 1 - abs(x - sunx) / 90.0) ** 2
        bs = [b - lift * (6 + i * 2.2) if i >= 3 else b for i, b in enumerate(bounds)]
        return banded_var(sky, bs, y, x, [10, 10, 10, 10, 9, 8, 7, 6])

    # 映り込みは本体より 1 段暗く、彩度の低い側へ寄せる
    refl = {"fc38": "fc37", "fc37": "fc35", "fc35": "fc23", "fc33": "fc23", "fc23": "fc13", "fc13": "fc03",
            "fc03": "fc02", "fc32": "fc13", "fc30": "fc13", "fc06": "fc02", "fc27": "fc02", "fc08": "fc02",
            "fc28": "fc02", "ink": "ink"}

    def refl_of(c, x, y):
        if c == "fc02":
            return "fc02" if bayer(x, y) < 0.5 else "ink"
        return refl.get(c, "fc02")

    for y in range(horizon + 1, lake_bottom):
        dist = y - horizon
        src_y = max(0, horizon - dist)
        # 横のゆれ: 岸から離れるほど大きく、コマで向きが変わる
        amp = 0.6 + dist / 16.0
        wob = int(round(math.sin(y * 0.85 + frame * 2.1) * amp))
        rr = random.Random(y * 31 + 7)
        for x in range(W):
            sx = min(W - 1, max(0, x + wob))
            cv.put(x, y, refl_of(above.get(sx, src_y), x, y))
        # 縦に崩す: 映り込みを横に裂いて、間から空を映した水面をのぞかせる（遠いほど裂け目が多い）
        n = int(1 + dist / 6.0)
        for i in range(n):
            x0 = rr.randint(-10, W - 1)
            L = rr.randint(4, 8 + dist // 3)
            shift = (frame * 2 - 1) * (1 + dist // 20) * (1 if y % 2 else -1)
            for j in range(L):
                xx = x0 + j + shift
                if 0 <= xx < W:
                    cv.put(xx, y, banded(["fc13", "fc03", "fc02"], [horizon + 14, horizon + 34], y, xx, 10))

    # 日の出の光の道（手前ほど広がる）と、坑道の灯りの映り込み
    def light_path(cx, colors, w0, w1, y0, y1, seed, skip):
        rr = random.Random(seed)
        for y in range(y0, y1):
            k = (y - y0) / max(1, (y1 - y0))
            on = rr.random()
            if on < skip:
                continue
            w = w0 + (w1 - w0) * k
            L = max(1, int(rr.uniform(0.4, 1.0) * w))
            sh = (frame * 2 - 1) * (1 if (y // 2) % 2 else -1) * (1 + int(k * 2))
            xs = cx + sh + rr.randint(-int(w / 3) - 1, int(w / 3) + 1) - L // 2
            c = colors[min(len(colors) - 1, int(k * len(colors)))]
            for j in range(L):
                cv.put(xs + j, y, c)

    light_path(sunx, ["fc38", "fc37", "fc35", "fc23"], 6, 26, horizon + 1, lake_bottom - 2, 5, 0.3)
    light_path(mx, ["fc27", "fc27", "fc06"], 2, 4, horizon + 3, horizon + 36, 6, 0.45)
    # 向こう岸の線
    for x in range(W):
        cv.put(x, horizon, "ink" if (x * 5) % 13 < 9 else "fc02")

    # 手前の岸: 水際から下は墨の地。水際に空を受けた草の縁
    for x in range(W):
        for y in range(wl[x], H):
            t = (y - wl[x]) / 22.0
            cv.put(x, y, "fc02" if bayer(x, y) < 0.8 - t else "ink")
        cv.put(x, wl[x], "fc13")
    # 桟橋（岸から湖へ突き出す。杭は水に立ち、水面に短く映る）
    py = 201
    for x in range(98, 126):
        cv.put(x, py, "fc03" if x < 124 else "ink")
        cv.put(x, py + 1, "ink")
    for x in (101, 109, 117, 123):
        for y in range(py + 2, wl[x] + 1):
            cv.put(x, y, "ink")
        cv.put(x, py + 4, "fc02") if py + 4 < wl[x] else None

    # 岸の草むら（墨のシルエット。上の縁に空の色を 1px）
    for i in range(30):
        x = r.randint(0, W - 1)
        y0 = wl[x] + r.randint(0, 24)
        hgt = r.randint(2, 4)
        for k in range(hgt):
            cv.put(x + (k % 2), y0 - k, "ink")
        cv.put(x + ((hgt - 1) % 2), y0 - hgt, "fc03")

    # 木: 奥（水際・小さい）と手前（低い位置・大きい）
    def tree(tx, base, s, rim):
        for y in range(base - s * 2 - 3, base + 1):
            for x in range(tx - s, tx + s + 1):
                dy = (y - (base - s - 2)) / (s + 2)
                dx = (x - tx) / (s * 0.78)
                rr2 = dx * dx + dy * dy
                if rr2 < 1 + math.sin(x * 1.7 + y) * 0.08:
                    edge = (dx + dy) < -0.8 and rr2 > 0.6
                    cv.put(x, y, rim if edge else "ink")
        cv.rect(tx - 1, base - 3, 2, 3, "ink")

    # 家: 壁・張り出した切妻の屋根・窓の灯り・扉。far は奥の列（体は霞んだ紺、小さい）
    def house(x0, base, w, hgt, roof, far, windows, door=None, chimney=None):
        # 奥の列ほど空の色へ寄せる（壁も屋根も 1 段明るい）
        body = "fc03"
        roofc = "fc02" if far else "ink"
        rim = "fc13"
        top = base - hgt
        cv.rect(x0, top, w, hgt, body)
        # 壁の右半分は影（光は左上）
        for y in range(top, base):
            for x in range(x0 + w * 2 // 3, x0 + w):
                if bayer(x, y) < 0.5 + (x - x0 - w * 2 // 3) * 0.15:
                    cv.put(x, y, roofc if far else "ink")
        for k in range(roof):
            y = top - 1 - k
            l, rgt = x0 - 2 + k, x0 + w + 1 - k
            for x in range(l, rgt + 1):
                cv.put(x, y, roofc)
            cv.put(l, y, rim)
            if k == roof - 1:
                for x in range(l, rgt + 1):
                    cv.put(x, y, rim)
        # 軒の影（屋根の下 1 行は墨）
        for x in range(x0, x0 + w):
            cv.put(x, top, "ink")
        for x in range(x0 - 1, x0 + w + 1):
            cv.put(x, base, "ink")
        if chimney is not None:
            cx_ = x0 + chimney
            cv.rect(cx_, top - roof - 2, 2, roof, roofc)
            cv.put(cx_, top - roof - 2, rim)
            # 煙（コマで横へ流れる）
            for k in range(5):
                sx_ = cx_ + (k + frame) // 2 + (1 if k > 2 else 0)
                cv.put(sx_, top - roof - 4 - k * 2, "fc03" if far else "fc13")
        for wx, wy, ww, wh in windows:
            for yy in range(wh):
                for xx in range(ww):
                    cv.put(x0 + wx + xx, top + wy + yy, "fc38")
            if ww >= 3 and not far:
                for yy in range(wh):
                    cv.put(x0 + wx + ww // 2, top + wy + yy, "ink")
        if door is not None:
            dx_, dw = door
            for yy in range(hgt - 6, hgt):
                for xx in range(dw):
                    cv.put(x0 + dx_ + xx, top + yy, "ink")
            cv.put(x0 + dx_, top + hgt - 6, rim)

    # 奥の列（水際に並ぶ。小さく、少しずつ大きさを変える）
    tree(8, wl[8] + 3, 6, "fc13")
    house(16, wl[20] + 4, 11, 6, 5, True, [(2, 2, 1, 2)], chimney=7)
    house(31, wl[34] + 5, 8, 5, 4, True, [])
    house(66, wl[70] + 3, 12, 6, 5, True, [(8, 2, 1, 2)])
    tree(88, wl[88] + 4, 5, "fc03")
    # 手前の列（低い位置に大きく。奥の列に重ねる）
    house(22, 228, 26, 15, 11, False, [(4, 4, 3, 3)], door=(16, 5), chimney=18)
    house(54, 222, 18, 12, 8, False, [(11, 3, 2, 2)], door=(3, 4))
    tree(84, 230, 10, "fc03")
    # 手前の柵（家の前を横切る。手前ほど杭が高い）
    for i, x in enumerate(range(2, 100, 5)):
        hh = 5 + i // 6
        base = 232 + i // 5
        for y in range(base - hh, base + 1):
            cv.put(x, y, "ink")
        cv.put(x, base - hh, "fc03")
    for x in range(2, 98):
        cv.put(x, 232 + (x - 2) // 25 - 3, "ink")
    # 右の岸: 手前の大きな木と、水際の葦
    tree(232, 238, 14, "fc03")
    tree(252, 228, 9, "fc03")
    tree(196, wl[196] + 3, 5, "fc13")
    for rx in [140, 143, 147, 151, 206, 209, 213]:
        base = wl[rx] + 1
        for k in range(r.randint(5, 10)):
            cv.put(rx + (1 if k > 6 else 0), base - k, "ink")
    return cv


def banded_var(colors, bounds, y, x, widths):
    i = 0
    for j, b in enumerate(bounds):
        w = widths[j]
        if y >= b + w / 2.0:
            i += 1
            continue
        if y > b - w / 2.0:
            t = (y - (b - w / 2.0)) / w
            return colors[i + 1] if bayer(x, y) < t else colors[i]
        break
    return colors[i]


# ---------------------------------------------------------------- 効果（vfx）

def vfx_slash():
    frames = []
    S = 32
    specs = [(0.0, 0.45, 1.0), (0.0, 1.0, 2.6), (0.45, 1.0, 1.2)]
    for fi, (a0, a1, thick) in enumerate(specs):
        cv = Canvas(S, S)
        # 右上から左下へ振り下ろす弧（中心は右下の外）
        cx, cy, R = 31, 31, 26
        for i in range(400):
            t = i / 399
            if not (a0 <= t <= a1):
                continue
            ang = math.radians(180 + t * 90)
            # 弧の厚みは真ん中が太い
            mid = (t - a0) / max(0.01, (a1 - a0))
            th = thick * math.sin(mid * math.pi) + 0.4
            for k in range(-3, 4):
                rr = R + k * 0.5
                if abs(k * 0.5) > th:
                    continue
                x = int(round(cx + math.cos(ang) * rr))
                y = int(round(cy + math.sin(ang) * rr))
                inner = abs(k * 0.5) < th * 0.45
                c = "fc30" if inner and fi == 1 else ("fc31" if inner else "fc21")
                if fi == 2 and (int(t * 40) % 3 == 0):
                    continue
                if cv.get(x, y) != "fc30":
                    cv.put(x, y, c)
        # 飛ぶ粒
        if fi >= 1:
            rr = random.Random(fi)
            for k in range(4 if fi == 1 else 6):
                t = rr.uniform(0.2, 0.9)
                ang = math.radians(180 + t * 90)
                d = R - 4 - rr.randint(0, 5) - (fi - 1) * 3
                x, y = int(cx + math.cos(ang) * d), int(cy + math.sin(ang) * d)
                cv.put(x, y, "fc31")
                cv.put(x + 1, y, "fc21")
        frames.append(cv)
    return frames


def vfx_fire():
    S = 32
    out = []
    rr = random.Random(5)
    # 炎の柱の高さ・幅（コマごと）: 小さい点火 → 立つ → 一番大きい → 崩れて火の粉
    specs = [(9, 6, 0.0), (20, 9, 0.0), (28, 12, 0.0), (17, 7, 1.0)]
    for fi, (hgt, wid, break_) in enumerate(specs):
        cv = Canvas(S, S)
        base = 30
        for y in range(base - hgt, base + 1):
            t = (base - y) / hgt  # 0 下 〜 1 上
            for x in range(S):
                cxl = 16 + math.sin(y * 0.45 + fi * 1.7) * 2.2 * t
                half = wid * (1 - t ** 1.4) * (0.75 + 0.25 * math.sin(y * 0.8 + fi))
                # 舌のように上へ割れる
                tongue = math.sin((x - cxl) * 0.9 + fi * 2) * 0.5 + 0.5
                if t > 0.55 and tongue < (t - 0.55) * 2.2:
                    continue
                dx = abs(x - cxl)
                if dx > half:
                    continue
                u = dx / max(0.5, half)
                if break_ and t > 0.35 and abs(math.sin((x - cxl) * 1.1)) > 0.55:
                    continue
                if u < 0.42 and t < 0.6:
                    c = "fc38"
                elif u < 0.78 and t < 0.85:
                    c = "fc27"
                else:
                    c = "fc06"
                cv.put(x, y, c)
        # 火の粉
        n = [2, 4, 6, 10][fi]
        for k in range(n):
            x = rr.randint(6, 25)
            y = rr.randint(1, base - hgt + 4) if fi else rr.randint(18, 24)
            cv.put(x, y, "fc27" if k % 2 else "fc38")
            if fi == 3 and k % 3 == 0:
                cv.put(x, y + 1, "fc06")
        out.append(cv)
    return out


def vfx_ice():
    S = 32
    out = []
    shards = [  # (根元 x, 根元 y, 角度, 長さ, 太さ)
        (16, 28, -90, 22, 3.2), (11, 28, -112, 15, 2.4), (21, 28, -68, 16, 2.4),
        (6, 29, -140, 8, 1.6), (26, 29, -40, 9, 1.6),
    ]
    rr = random.Random(9)
    for fi in range(4):
        cv = Canvas(S, S)
        if fi == 0:
            # 冷気が集まる: 外から寄る粒
            for k in range(10):
                ang = k / 10 * 6.28 + 0.3
                d = 12 + (k % 3) * 2
                x, y = int(16 + math.cos(ang) * d), int(20 + math.sin(ang) * d * 0.7)
                cv.put(x, y, "fc31")
                if k % 2 == 0:
                    cv.put(x + 1, y, "fc21")
            cv.rect(15, 26, 3, 2, "fc21")
            cv.put(16, 26, "fc31")
        else:
            grow = [0.5, 1.0, 1.0][fi - 1]
            for bx, by, ang, L, th in shards:
                L2 = L * grow
                a = math.radians(ang)
                ux, uy = math.cos(a), math.sin(a)
                nx, ny = -uy, ux
                for i in range(int(L2 * 4)):
                    s = i / 4
                    w = th * (1 - s / L2) + 0.3
                    for j in range(-6, 7):
                        o = j * 0.5
                        if abs(o) > w:
                            continue
                        x = int(round(bx + ux * s + nx * o))
                        y = int(round(by + uy * s + ny * o))
                        # 光は左上: 法線の左側が受光
                        lit = (o * (nx * -1 + ny * -1)) > 0
                        c = "fc31" if lit else "fc21"
                        if abs(o) > w - 0.6:
                            c = "fc12"
                        if fi == 3 and rr.random() < 0.3:
                            continue
                        cv.put(x, y, c)
            if fi == 3:
                # 砕けて散る
                for k in range(9):
                    x, y = rr.randint(3, 28), rr.randint(4, 26)
                    cv.put(x, y, "fc31")
                    cv.put(x + 1, y + 1, "fc12")
        out.append(cv)
    return out


def vfx_heal():
    S = 24
    out = []
    parts = [(5, 20, 0), (12, 22, 2), (18, 19, 1), (9, 15, 3), (15, 13, 0), (7, 9, 2), (17, 7, 1)]
    for fi in range(4):
        cv = Canvas(S, S)
        for i, (px, py, ph) in enumerate(parts):
            y = py - fi * 3 - (i % 2)
            if y < 1 or y > S - 2:
                y = (y - 1) % (S - 2) + 1
            stage = (fi + ph) % 4  # 0 点 1 小さい十字 2 大きい十字 3 小さい十字
            if stage == 0:
                cv.put(px, y, "fc3B")
            elif stage in (1, 3):
                cv.put(px, y, "fc30" if stage == 1 else "fc3B")
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    cv.put(px + dx, y + dy, "fc2B")
            else:
                cv.put(px, y, "fc30")
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    cv.put(px + dx, y + dy, "fc3B")
                for dx, dy in ((2, 0), (-2, 0), (0, 2), (0, -2)):
                    cv.put(px + dx, y + dy, "fc2B")
        out.append(cv)
    return out


def vfx_hit():
    out = []
    a = [
        "......y.........",
        ".y....y....y....",
        "..y...a...y.....",
        "...a..a..a......",
        "....aaYaa.......",
        "....aYwYa.......",
        "yyaaYwwwYaayy...",
        "....aYwYa.......",
        "....aaYaa.......",
        "...a..a..a......",
        "..y...a...y.....",
        ".y....y....y....",
        "......y.........",
        "................",
        "................",
        "................",
    ]
    b = [
        "................",
        "..y.......y.....",
        "................",
        "......a.........",
        "....a.Y.a.......",
        ".....YwY........",
        "y...aYwYa...y...",
        ".....YwY........",
        "....a.Y.a.......",
        "......a.........",
        "................",
        "..y.......y.....",
        "................",
        "................",
        "................",
        "................",
    ]
    cm = {"y": "fc27", "a": "fc28", "Y": "fc38", "w": "fc30"}
    res = []
    for g in (a, b):
        cv = Canvas(16, 16)
        for y, row in enumerate(g):
            for x, ch in enumerate(row):
                if ch in cm:
                    cv.put(x + 2, y + 2, cm[ch])
        res.append(cv)
    # 3 色に収める（fc27, fc28, fc38 と白 → 白を芯に、fc27 を外す）
    for cv in res:
        for y in range(16):
            for x in range(16):
                if cv.p[y][x] == "fc27":
                    cv.p[y][x] = "fc28"
    return res


# ---------------------------------------------------------------- 書き出し

def build():
    report = []
    bands = {"bg_cave": bg_cave(), "bg_lake": bg_lake(), "bg_plains": bg_plains()}
    for n, cv in bands.items():
        enforce_attr(cv, report=report, name=n)
    titles = [title_bg(0), title_bg(1)]
    for i, cv in enumerate(titles):
        enforce_attr(cv, report=report, name="title_bg/f%d" % i)
    sprites = {}
    for n, cv in bands.items():
        sprites[n] = ("background", {"idle": cv}, None, (0, 0))
    sprites["title_bg"] = ("background", {"f0": titles[0], "f1": titles[1]}, "forward", (0, 0))
    sl = vfx_slash()
    sprites["slash"] = ("vfx", {"f0": sl[0], "f1": sl[1], "f2": sl[2]}, "once", (16, 16))
    fi = vfx_fire()
    sprites["fire"] = ("vfx", {"f%d" % i: c for i, c in enumerate(fi)}, "once", (16, 30))
    ic = vfx_ice()
    sprites["ice"] = ("vfx", {"f%d" % i: c for i, c in enumerate(ic)}, "once", (16, 28))
    he = vfx_heal()
    sprites["heal"] = ("vfx", {"f%d" % i: c for i, c in enumerate(he)}, "forward", (12, 12))
    hi = vfx_hit()
    sprites["hit"] = ("vfx", {"f0": hi[0], "f1": hi[1]}, "once", (8, 8))
    return sprites, report


CHARS = "ABCDEFGHIJLMNOPQRSTUVWXYZabcdefghijlmnopqrstuvwxyz0123456789"


def to_json(sprites):
    used = set()
    for _, (_, frames, _, _) in sprites.items():
        for cv in frames.values():
            for row in cv.p:
                used.update(c for c in row if c is not None)
    keys = sorted(used, key=lambda k: (k != "ink", k))
    legend = {}
    rev = {}
    for i, k in enumerate(keys):
        ch = "k" if k == "ink" else CHARS[i]
        legend[ch] = k
        rev[k] = ch
    notes = {
        "bg_cave": "坑道の戦闘の背景の帯。奥 = 坑道の先の闇と遠い支柱・中 = 岩肌（外ほど明るく奥ほど闇へ）・手前 = 板の支柱と梁・たいまつと岩への照り返し・口へ集まるレール。下は墨の地へ落とす。",
        "bg_lake": "地底湖の戦闘の背景の帯。奥 = 向こう岸の紫の岩壁と鍾乳石・中 = 岸に立つ水晶の群れ（芯に光）・手前 = 水晶の光が縦に映る湖面と墨の岩。",
        "bg_plains": "草原の戦闘の背景の帯。奥 = 空の帯と雲・雪をかぶった遠い山・中 = 緑の丘と木立・手前 = 草原と左右の茂み。",
        "title_bg": "タイトルの背景。上の 1/3 はロゴ用に空を空けてある。夜明けの空・山並み 4 枚・北の山の坑道の灯り・上下を返して横にゆれ縦に裂けた山の映り込み・日の出の光の道・手前の岸に立つ村（奥の列は小さく霞み、手前の列は大きく重なる）。f0/f1 で湖面の光と煙がゆれる。",
        "slash": "剣の斬撃。右上から左下へ。f0 振り始め・f1 弧が一番太い・f2 切れて消える。",
        "fire": "炎の呪文。f0 点火・f1 立ち上がる・f2 一番大きい・f3 崩れて火の粉。anchor は炎の根元。",
        "ice": "氷の呪文。f0 冷気が寄る・f1 氷柱が伸びる・f2 一番大きい・f3 砕けて散る。anchor は氷柱の根元。",
        "heal": "回復の光の粒。上へ昇りながら瞬く。forward で回す。",
        "hit": "当たった火花。f0 大きく弾ける・f1 散って小さくなる。",
    }
    out = {
        "version": 1,
        "title": "戦闘の背景・効果・タイトルの背景",
        "note": "戦闘の背景の帯（256x64）・呪文と攻撃の効果・タイトルの背景（256x240）。art/battlefx.py が書き出す（手で直さず台本を直す）。背景は 16x16 ごとに墨を含めて 4 色まで（FC の背景属性）。",
        "paletteFile": "assets/rpg.palette.json",
        "entityId": "rpg.battlefx",
        "legend": legend,
        "sprites": {},
    }
    for n, (kind, frames, loop, anc) in sprites.items():
        s = {"note": notes[n], "kind": kind, "anchor": {"x": anc[0], "y": anc[1]}}
        if loop:
            s["loop"] = loop
        if kind == "vfx":
            s["lint-sprite"] = "対象外(orphan, connect) — 火の粉・光の粒・飛ぶ破片は本体から離れて浮く"
        s["frames"] = {fn: ["".join(rev[c] if c is not None else "." for c in row) for row in cv.p] for fn, cv in frames.items()}
        out["sprites"][n] = s
    return out


# ---------------------------------------------------------------- 確かめの PNG

def write_png(path, grid, scale=1):
    """grid: 行の列、各要素は (r,g,b) か None（透明 → 市松の灰）。"""
    h = len(grid)
    w = len(grid[0])
    raw = bytearray()
    for y in range(h * scale):
        raw.append(0)
        row = grid[y // scale]
        for x in range(w * scale):
            c = row[x // scale]
            if c is None:
                c = (60, 60, 70) if ((x // (4 * scale) + y // (4 * scale)) % 2) else (80, 80, 92)
            raw.extend(c)
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w * scale, h * scale, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "wb").write(png)


def rgbgrid(cv, bg=None):
    return [[RGB[c] if c else (RGB[bg] if bg else None) for c in row] for row in cv.p]


def stack(grids, gap=0, gapc=(40, 40, 40)):
    w = max(len(g[0]) for g in grids)
    out = []
    for i, g in enumerate(grids):
        for row in g:
            out.append(row + [gapc] * (w - len(row)))
        if i < len(grids) - 1:
            for _ in range(gap):
                out.append([gapc] * w)
    return out


def side(grids, gap=2, gapc=(40, 40, 40)):
    h = max(len(g) for g in grids)
    out = []
    for y in range(h):
        row = []
        for i, g in enumerate(grids):
            row += g[y] if y < len(g) else [gapc] * len(g[0])
            if i < len(grids) - 1:
                row += [gapc] * gap
        out.append(row)
    return out


def preview(sprites):
    d = os.path.join(ROOT, "debug/battlefx")
    ink = RGB["ink"]
    bands = []
    for n in ("bg_cave", "bg_lake", "bg_plains"):
        cv = sprites[n][1]["idle"]
        g = rgbgrid(cv) + [[ink] * 256 for _ in range(40)]
        bands.append(g)
    sheet = stack(bands, gap=4)
    write_png(os.path.join(d, "bands_1x.png"), sheet, 1)
    write_png(os.path.join(d, "bands_3x.png"), sheet, 3)
    t = sprites["title_bg"][1]
    write_png(os.path.join(d, "title_1x.png"), side([rgbgrid(t["f0"]), rgbgrid(t["f1"])], gap=4), 1)
    write_png(os.path.join(d, "title_3x.png"), rgbgrid(t["f0"]), 3)
    # 効果: 墨の地と洞窟の帯の上に並べる
    rows = []
    cave = sprites["bg_cave"][1]["idle"]
    for n in ("slash", "fire", "ice", "heal", "hit"):
        fr = list(sprites[n][1].values())
        on_ink = [rgbgrid(c, "ink") for c in fr]
        on_bg = []
        for c in fr:
            g = []
            for y in range(c.h):
                g.append([RGB[c.p[y][x]] if c.p[y][x] else RGB[cave.p[16 + y][96 + x * 1]] for x in range(c.w)])
            on_bg.append(g)
        on_clear = [rgbgrid(c) for c in fr]
        rows.append(side(on_clear + on_ink + on_bg, gap=2))
    write_png(os.path.join(d, "vfx_4x.png"), stack(rows, gap=3), 4)
    write_png(os.path.join(d, "vfx_1x.png"), stack(rows, gap=3), 1)


if __name__ == "__main__":
    sprites, report = build()
    data = to_json(sprites)
    path = os.path.join(ROOT, "assets/rpg.battlefx.sprite.json")
    with open(path, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("wrote", path, "legend", len(data["legend"]))
    print("属性で色を減らした升目:", len(report))
    for line in report[:60]:
        print("  ", line)
    if "--preview" in sys.argv:
        preview(sprites)
        print("preview -> debug/battlefx/")
