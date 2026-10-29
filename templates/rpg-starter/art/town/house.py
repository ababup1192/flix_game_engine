from pxlib import *

COURSE = [
    "SSsr",
    "Sssr",
    "sssr",
    "srrk",
]
COURSE_LOW = [
    "Sssr",
    "sssr",
    "ssrr",
    "rrrk",
]
def shingles(c, y0, y1, off=0, low_from=99):
    # 丸瓦の縦の列。段の継ぎ目は列の中だけに落とす。軒に近い段ほど光を減らす
    for y in range(y0, y1 + 1):
        r = (y - y0 + off) % 4
        pat = COURSE_LOW if y >= low_from else COURSE
        for x in range(16):
            c.set(x, y, pat[r][(x + 1) % 4])

def roof_row(kind):
    c = Cv(16, 16)
    shingles(c, 4, 15)
    for x in range(16):
        c.set(x, 0, 'k'); c.set(x, 1, 'S'); c.set(x, 2, 'S' if x % 4 else 's'); c.set(x, 3, 'k')
    if kind == 'l':
        for y in range(16): c.set(0, y, 'k'); c.set(1, y, 'S')
        c.set(1, 0, 'k'); c.set(1, 3, 'k')
    if kind == 'r':
        for y in range(16): c.set(15, y, 'k'); c.set(14, y, 'r')
        c.set(14, 0, 'k'); c.set(14, 3, 'k')
    return c

def eave_row(kind):
    c = Cv(16, 16)
    shingles(c, 0, 11, low_from=4)
    for x in range(16):
        c.set(x, 12, 'S' if x % 4 != 3 else 's'); c.set(x, 13, 's'); c.set(x, 14, 'r'); c.set(x, 15, 'k')
    if kind == 'l':
        for y in range(16): c.set(0, y, 'k'); c.set(1, y, 'S')
        c.set(1, 15, 'k')
    if kind == 'r':
        for y in range(16): c.set(15, y, 'k'); c.set(14, y, 'r')
        c.set(14, 15, 'k')
    return c

def chimney():
    c = roof_row('m')
    c.stamp(8, 0, [
        "kkkkkkk",
        "kSSSSrk",
        "kkkkkkk",
        ".kSrrk.",
        ".kkkkk.",
        ".krrSk.",
        ".kkkkk.",
        ".kSrrk.",
        ".kkkkk.",
        "..kkk..",
        "...k...",
    ])
    return c

def wall(kind):
    c = Cv(16, 16, 'p')
    for x in range(16):
        c.set(x, 0, 'g'); c.set(x, 1, 'g' if dith(x, 1, 10) else 'G'); c.set(x, 2, 'G' if dith(x, 2, 6) else 'p')
        c.set(x, 12, 'G'); c.set(x, 13, 'k' if x % 6 == 2 else 'g'); c.set(x, 14, 'g' if (x + 3) % 6 else 'k'); c.set(x, 15, 'k')
    # 漆喰のむら（塊で・まばらに）
    c.stamp(3, 5, ["GG", ".G"]); c.stamp(11, 8, ["G.", "GG"]); c.stamp(7, 10, ["GG"])
    if kind == 'l':
        for y in range(16): c.set(0, y, 'k')
        for y in range(1, 15): c.set(1, y, 'p'); c.set(2, y, 'G') if y > 2 else None
    if kind == 'r':
        for y in range(16): c.set(15, y, 'k')
        for y in range(1, 15): c.set(14, y, 'g'); c.set(13, y, 'G')
    return c

def wall_window():
    c = wall('m')
    c.rect(3, 5, 12, 10, 'p')
    c.stamp(3, 3, [
        "kkkkkkkkkk",
        "kgggggggGk",
        "kgkkkgkkGk",
        "kgkGkgkkGk",
        "kgGkkgkkGk",
        "kgggggggGk",
        "kgkkkgkkGk",
        "kgkkkgkkGk",
        "kkkkkkkkkk",
        "GppppppppG",
    ])
    return c

def door():
    return from_rows([
        "mmmmmmmmmmmmmmmm",
        "kkkkkkkkkkkkkkkk",
        "Ook....kkkk...kO",
        "Ook.kkkooOokk.kO",
        "Ookkooooo.Oook.O",
        "OokoOomoOomoOokO",
        "OokoOomoOomoOokO",
        "OokoOomoOomoOokO",
        "OokoOomoOomoOokO",
        "OokoOomoOkmoOokO",
        "OokoOomoOkmoOokO",
        "OokoOomoOomoOokO",
        "OokoOomoOomoOokO",
        "OokmmmmmmmmmmmkO",
        "OokkkkkkkkkkkkkO",
        "kkkkkkkkkkkkkkkk",
    ])

def sign(kind):
    c = wall('m')
    icon = {
        'inn': ["........",
                ".k......",
                ".kpp....",
                ".kkkkkk.",
                ".k....k."],
        'item': ["...kk...",
                 "...kk...",
                 "..kppk..",
                 ".kppppk.",
                 "..kkkk.."],
    }[kind]
    c.stamp(2, 2, ["k..........k", "k..........k"])
    c.stamp(2, 4, [
        "kkkkkkkkkkkk",
        "kOOOOOOOOOok",
        "kO........ok",
        "kO........ok",
        "kO........ok",
        "kO........ok",
        "kO........ok",
        "kooooooooook",
        "kkkkkkkkkkkk",
        ".GGGGGGGGGG.",
    ])
    c.rect(4, 6, 11, 10, 'O')
    c.stamp(4, 6, icon)
    return c

HOUSE = {
    'roof_l': lambda: roof_row('l'), 'roof_m': lambda: roof_row('m'), 'roof_r': lambda: roof_row('r'),
    'eave_l': lambda: eave_row('l'), 'eave_m': lambda: eave_row('m'), 'eave_r': lambda: eave_row('r'),
    'wall_l': lambda: wall('l'), 'wall_m': lambda: wall('m'), 'wall_r': lambda: wall('r'),
    'wall_window': wall_window, 'door': door, 'sign_inn': lambda: sign('inn'), 'sign_item': lambda: sign('item'),
    'chimney': chimney,
}
