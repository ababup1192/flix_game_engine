from pxlib import *
from ground import hsh
import math

CX, CY = 15.5, 13.0
def inE(x, y, cx, cy, rx, ry): return ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1.0

def spring(state, frame=0):
    c = Cv(32, 32)
    RX0, RY0, RX1, RY1, H = 15.4, 10.6, 11.6, 7.4, 4
    for y in range(32):
        for x in range(32):
            top = inE(x, y, CX, CY, RX0, RY0)
            side = (not top) and y > CY and any(inE(x, y - d, CX, CY, RX0, RY0) for d in range(1, H + 1))
            inner = inE(x, y, CX, CY, RX1, RY1)
            if side:
                # 外側の側面: 右ほど影（光は左上）
                ch = 'g' if x > 19 or (x > 15 and dith(x, y, 8)) else 'G'
                # 石積みの縦目地（2 段で半分ずらす）
                topy = min(yy for yy in range(32) if not inE(x, yy, CX, CY, RX0, RY0) and yy > CY)
                dy = y - topy
                if (x + (0 if dy < 2 else 3)) % 6 == 0: ch = 'k'
                if y == max(yy for yy in range(32) if any(inE(x, yy - d, CX, CY, RX0, RY0) for d in range(0, H + 1))): ch = 'k'
                c.set(x, y, ch)
            elif top and not inner:
                ang = math.atan2((y - CY) / RY0, (x - CX) / RX0)
                seg = int((ang + 3.3) * 2.6)
                seg2 = int((math.atan2((y - CY) / RY0, (x + 1 - CX) / RX0) + 3.3) * 2.6)
                ch = 'G'
                # 左上の縁に光
                if not inE(x - 1, y - 1, CX, CY, RX0, RY0) and (x < CX + 4) and y < CY + 3: ch = 'p'
                if inE(x + 1, y + 1, CX, CY, RX1, RY1) and not inE(x, y, CX, CY, RX1 + 0.6, RY1 + 0.6) and y > CY: ch = 'p'
                if seg != seg2 and not (y < CY - RY0 + 1): ch = 'k'
                c.set(x, y, ch)
            elif inner:
                c.set(x, y, 'n' if state == 'dry' else 'b')
    # 輪郭
    snap = c.copy()
    for y in range(32):
        for x in range(32):
            if snap.get(x, y) == '.' and any(snap.get(x + dx, y + dy) not in (None, '.') for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                c.set(x, y, 'k')
    # 縁の内側の線（墨）
    for y in range(32):
        for x in range(32):
            if inE(x, y, CX, CY, RX1, RY1) and not inE(x, y, CX, CY, RX1 - 1.1, RY1 - 1.1):
                c.set(x, y, 'k')
    if state == 'dry':
        # 奥の内壁（影）と、ひび割れた底
        for y in range(32):
            for x in range(32):
                if inE(x, y, CX, CY, RX1 - 1.1, RY1 - 1.1) and not inE(x, y - 3, CX, CY, RX1, RY1) and y < CY:
                    c.set(x, y, 'k')
        for (x, y, s) in [(7, 12, ["k..", ".kk", "...k"]), (19, 14, ["kk.", "..k", "..k"]), (11, 17, ["k.k", ".k."]),
                          (22, 11, [".k", "k."]), (8, 16, ["kk"])]:
            c.stamp(x, y, s, only_on='n')
        for (x, y) in [(9, 11), (14, 18), (21, 16), (17, 12)]:
            pass
        c.stamp(13, 8, [".kkkk.", "kpGGgk", "kkkkkk", ".kpgk.", ".kGgk.", "kkkkkk"])
    else:
        for y in range(32):
            for x in range(32):
                if inE(x, y, CX, CY, RX1 - 1.1, RY1 - 1.1) and not inE(x, y - 1, CX, CY, RX1 - 1.1, RY1 - 1.1):
                    c.set(x, y, 'k' if dith(x, y, 8) else 'b')
        # 波紋（コマごとに広がる）
        for rr in [[2.6, 5.2], [3.6, 6.2], [4.4, 1.8]][frame]:
            for x in range(32):
                for y in range(32):
                    if c.get(x, y) != 'b': continue
                    d = math.hypot(x - CX, (y - CY - 1) / 0.62)
                    if abs(d - rr * 1.3) < 0.55 and ((x < CX and y < CY + 1) or (x > CX and y > CY + 1)):
                        c.set(x, y, 'B')
        c.stamp(13, 9, [".kkkk.", "kGGGGk", "kkkkkk", ".kGGk."])
        spl = [["..W...", ".BWB..", "B....B"], ["...W..", "..BWB.", ".B..B."], [".W..W.", "..BB..", ".B..B."]][frame]
        c.stamp(13, 5, spl)
        for (x, y) in [[(9, 11), (21, 15)], [(20, 10), (11, 16)], [(8, 15), (19, 18)]][frame]:
            c.stamp(x - 1, y - 1, [".B.", "BWB", ".B."], only_on='bB')
    # 接地影（右下へ横長に）
    for y in range(32):
        for x in range(32):
            if c.get(x, y) == '.' and inE(x - 1.5, y - 2.5, CX, CY + 2, RX0, RY0) and y > CY + 5:
                c.set(x, y, 'k') if dith(x, y, 8) else None
    return c
