"""校舎の glb（建物 3 つ・小物 369 個）を、絵を重ねて持たない少数の glb（束）へまとめる。

小物の glb は 1 つずつ同じ絵（床板・椅子・貼り紙…）を抱えていて、合わせると絵だけで 11 MB ある。
中身の違う絵は 50 枚ほどなので、束の中では 1 枚を 1 回だけ持ち、材質・サンプラーも同じ物は 1 つにする。
束の中の根のノードは元の glb の名前のまま（prop_<名前>・school_floor<n>）。ゲームは根の名前で小物を引く（Bundles.flix）。

絵は PNG のまま画素を変えずに詰め直す（256 色以下ならパレットの PNG に・小さくなった時だけ）。
PS1 の決まり（64 色・ディザ・Nearest）を崩さないため、劣化のある形（WebP の lossy・色を減らす）にはしない。
詰め直した後に元と同じ画素へ戻るかを 1 枚ずつ確かめ、違えば止める。

形の圧縮（EXT_meshopt_compression・KHR_draco_mesh_compression・量子化）は使わない:
engine の Gltf は extensionsRequired を見ずに float と u8/u16/u32 の accessor だけを読むので、詰めた形は壊れて読まれる。

流し方: DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 tools/glb_bundle.py [--check]
  書く物: assets/school/bundle/<束>.glb と assets/school/bundle/bundles.json（束の名前・道・どの階が使うか）
  --check: 書かずに、今の束が layout.json と元の glb から作り直した物と同じかだけを見る（違えば 1 で終わる）
"""
import hashlib
import json
import pathlib
import struct
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHOOL = ROOT / "assets" / "school"
OUT = SCHOOL / "bundle"

# 束の分け方。起動で読むのは floor1 と entrance（ブラウザ版の後回しは project.json の web.deferred）。
#   floor1   = 1 階の建物（昇降口から見える面の全部）
#   entrance = 始まりの場所（layout の spawn）から ENTRANCE_REACH m の内に 1 つでも置く小物（押してすぐの場面に要る物）
#   props_1f = ほかの 1 階の小物（2・3 階と共通の物も入る）
#   upper    = 2・3 階の建物と、2・3 階にだけ置く小物（2・3 階の建物は同じ絵を使うので 1 つにまとめる）
# 小物は 1 つの束にだけ入る（2 階でも使う小物が entrance にあれば、2 階もその束を使う）。
# WhyNot: 2 階と 3 階を別の束にしない — 建物どうしで絵の 7 割が同じで、分けるとその分を 2 回配る。
#         階段を上る前に 1 回だけ解く方が、上の階へ着くたびに待つより短い。
# WhyNot: 1 階の小物を全部起動に入れない — gzip で 0.9 MB・4G で約 4.5 秒延び、起動の予算（16 秒）を超える。
#         遠くの小物は押した後の数秒で届いて足される（届くまでは建物だけ）。
ENTRANCE_REACH = 10.0


def bundle_plan(layout):
    on = {}
    for p in layout["props"]:
        on.setdefault(p["prop"], set()).add(p["floor"])
    sx, _, sz = layout["spawn"]["pos"]
    near = {p["prop"] for p in layout["props"]
            if p["floor"] == 1 and ((p["pos"][0] - sx) ** 2 + (p["pos"][2] - sz) ** 2) ** 0.5 < ENTRANCE_REACH}
    entrance = sorted(near)
    first = sorted(n for n, fl in on.items() if 1 in fl and n not in near)
    upper_only = sorted(n for n, fl in on.items() if 1 not in fl)
    floors = {f["index"]: f["glb"] for f in layout["floors"]}
    upper_floors = sorted(i for i in floors if i != 1)
    floors_of = lambda names: sorted({f for n in names for f in on[n]})
    return [
        {"key": "floor1", "floors": [1], "buildings": [1], "sources": [floors[1]]},
        {"key": "entrance", "floors": floors_of(entrance), "buildings": [], "sources": [f"prop_{n}.glb" for n in entrance]},
        {"key": "props_1f", "floors": floors_of(first), "buildings": [], "sources": [f"prop_{n}.glb" for n in first]},
        {"key": "upper", "floors": upper_floors, "buildings": upper_floors,
         "sources": [floors[i] for i in upper_floors] + [f"prop_{n}.glb" for n in upper_only]},
    ]


# ── glb の読み書き ──

def read_glb(path):
    b = path.read_bytes()
    magic, version, _ = struct.unpack("<III", b[:12])
    if magic != 0x46546C67 or version != 2:
        raise SystemExit(f"[glb_bundle] {path} は glb 2.0 でない")
    at, js, bin_ = 12, None, b""
    while at < len(b):
        length, kind = struct.unpack("<II", b[at:at + 8])
        chunk = b[at + 8:at + 8 + length]
        if kind == 0x4E4F534A:
            js = json.loads(chunk)
        elif kind == 0x004E4942:
            bin_ = chunk
        at += 8 + length
    return js, bin_


def write_glb(js, bin_):
    j = json.dumps(js, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    j += b" " * ((4 - len(j) % 4) % 4)
    bin_ += b"\0" * ((4 - len(bin_) % 4) % 4)
    total = 12 + 8 + len(j) + 8 + len(bin_)
    return (struct.pack("<III", 0x46546C67, 2, total) + struct.pack("<II", len(j), 0x4E4F534A) + j
            + struct.pack("<II", len(bin_), 0x004E4942) + bin_)


def view_bytes(js, bin_, index):
    v = js["bufferViews"][index]
    off = v.get("byteOffset", 0)
    return bin_[off:off + v["byteLength"]]


# ── PNG の画素を変えずに詰め直す ──

def png_chunks(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("PNG でない")
    at, out = 8, []
    while at < len(data):
        (length,) = struct.unpack(">I", data[at:at + 4])
        out.append((data[at + 4:at + 8], data[at + 8:at + 8 + length]))
        at += 12 + length
    return out


def png_rgba(data):
    """8 bit・飛び越し無しの PNG（色の形 0・2・3・4・6）を RGBA の行の並びへ。"""
    chunks = png_chunks(data)
    ihdr = dict(chunks)[b"IHDR"]
    w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", ihdr)
    if depth != 8 or interlace != 0:
        raise ValueError(f"読まない PNG（深さ {depth}・飛び越し {interlace}）")
    plte = next((c for t, c in chunks if t == b"PLTE"), b"")
    trns = next((c for t, c in chunks if t == b"tRNS"), b"")
    raw = zlib.decompress(b"".join(c for t, c in chunks if t == b"IDAT"))
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    stride = w * ch
    rows, prev, at = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[at]
        line = bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        for i in range(stride):
            a = line[i - ch] if i >= ch else 0
            b = prev[i]
            c = prev[i - ch] if i >= ch else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        prev = line
    out = []
    for line in rows:
        px = []
        for x in range(w):
            if ctype == 6:
                px.append(tuple(line[x * 4:x * 4 + 4]))
            elif ctype == 2:
                rgb = tuple(line[x * 3:x * 3 + 3])
                key = len(trns) == 6 and rgb == (trns[1], trns[3], trns[5])
                px.append(rgb + (0 if key else 255,))
            elif ctype == 3:
                i = line[x]
                px.append(tuple(plte[i * 3:i * 3 + 3]) + (trns[i] if i < len(trns) else 255,))
            elif ctype == 0:
                g = line[x]
                px.append((g, g, g, 0 if len(trns) == 2 and g == trns[1] else 255))
            else:
                g = line[x * 2]
                px.append((g, g, g, line[x * 2 + 1]))
        out.append(px)
    return w, h, out


def png_chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)


def palette_png(w, h, rows):
    """256 色以下ならパレットの PNG（行のフィルタ無し・zlib 9）。超えれば None。"""
    colors = {}
    for row in rows:
        for p in row:
            if p not in colors:
                if len(colors) == 256:
                    return None
                colors[p] = len(colors)
    # 透明のある色を前に並べると tRNS が短くなる
    order = sorted(colors, key=lambda c: (c[3] == 255, colors[c]))
    index = {c: i for i, c in enumerate(order)}
    raw = b"".join(b"\0" + bytes(index[p] for p in row) for row in rows)
    alphas = [c[3] for c in order]
    while alphas and alphas[-1] == 255:
        alphas.pop()
    body = png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 3, 0, 0, 0))
    body += png_chunk(b"PLTE", b"".join(bytes(c[:3]) for c in order))
    if alphas:
        body += png_chunk(b"tRNS", bytes(alphas))
    body += png_chunk(b"IDAT", zlib.compress(raw, 9)) + png_chunk(b"IEND", b"")
    return b"\x89PNG\r\n\x1a\n" + body


def repack_png(data):
    """画素の同じ、より小さい PNG（作れなければ元のまま）。戻した画素が元と違えば止める。"""
    w, h, rows = png_rgba(data)
    packed = palette_png(w, h, rows)
    if packed is None or len(packed) >= len(data):
        return data
    if png_rgba(packed) != (w, h, rows):
        raise SystemExit("[glb_bundle] パレットへ詰め直した PNG の画素が元と違う（道具の誤り）")
    return packed


# ── 束を組む ──

class Builder:
    def __init__(self):
        self.js = {"asset": {"version": "2.0", "generator": "night_school tools/glb_bundle.py"},
                   "scene": 0, "scenes": [{"name": "Scene", "nodes": []}],
                   "nodes": [], "meshes": [], "materials": [], "textures": [], "images": [], "samplers": [],
                   "accessors": [], "bufferViews": [], "buffers": [{"byteLength": 0}]}
        self.bin = bytearray()
        self.images = {}   # 元の PNG の sha1 → 束の images の番号
        self.png = {}      # 元の PNG の sha1 → 詰め直した PNG（束をまたいで 1 回だけ詰める）
        self.keyed = {"samplers": {}, "textures": {}, "materials": {}}

    def add_view(self, data, target=None):
        while len(self.bin) % 4:
            self.bin.append(0)
        view = {"buffer": 0, "byteOffset": len(self.bin), "byteLength": len(data)}
        if target is not None:
            view["target"] = target
        self.bin += data
        self.js["bufferViews"].append(view)
        return len(self.js["bufferViews"]) - 1

    def dedup(self, kind, obj):
        key = json.dumps(obj, sort_keys=True)
        table = self.keyed[kind]
        if key not in table:
            self.js[kind].append(obj)
            table[key] = len(self.js[kind]) - 1
        return table[key]

    def add_image(self, src_js, src_bin, index, cache):
        im = src_js["images"][index]
        data = view_bytes(src_js, src_bin, im["bufferView"])
        h = hashlib.sha1(data).hexdigest()
        if h not in self.images:
            if h not in cache:
                cache[h] = repack_png(data)
            view = self.add_view(cache[h])
            self.js["images"].append({"bufferView": view, "mimeType": "image/png", "name": im.get("name", "")})
            self.images[h] = len(self.js["images"]) - 1
        return self.images[h]

    def add_source(self, name, src_js, src_bin, cache):
        for unread in ("skins", "animations", "cameras", "extensionsRequired"):
            if src_js.get(unread):
                raise SystemExit(f"[glb_bundle] {name} に {unread} がある（束にまとめるのは形と絵だけの glb）")
        tex_map = {}
        for i, t in enumerate(src_js.get("textures", [])):
            sampler = self.dedup("samplers", src_js["samplers"][t["sampler"]]) if "sampler" in t else None
            obj = {"source": self.add_image(src_js, src_bin, t["source"], cache)}
            if sampler is not None:
                obj["sampler"] = sampler
            tex_map[i] = self.dedup("textures", obj)
        mat_map = {i: self.dedup("materials", remap_textures(m, tex_map)) for i, m in enumerate(src_js.get("materials", []))}
        acc_map = {}

        def accessor(i):
            if i not in acc_map:
                a = dict(src_js["accessors"][i])
                v = src_js["bufferViews"][a["bufferView"]]
                if "byteStride" in v:
                    raise SystemExit(f"[glb_bundle] {name} の accessor が byteStride 付きの bufferView を指す（読まない形）")
                size = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}[a["componentType"]]
                width = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[a["type"]]
                start = v.get("byteOffset", 0) + a.get("byteOffset", 0)
                a["bufferView"] = self.add_view(src_bin[start:start + size * width * a["count"]], v.get("target"))
                a.pop("byteOffset", None)
                self.js["accessors"].append(a)
                acc_map[i] = len(self.js["accessors"]) - 1
            return acc_map[i]

        mesh_map = {}
        for i, m in enumerate(src_js.get("meshes", [])):
            prims = []
            for p in m["primitives"]:
                q = dict(p)
                q["attributes"] = {k: accessor(v) for k, v in p["attributes"].items()}
                if "indices" in p:
                    q["indices"] = accessor(p["indices"])
                if "material" in p:
                    q["material"] = mat_map[p["material"]]
                prims.append(q)
            self.js["meshes"].append({**m, "primitives": prims})
            mesh_map[i] = len(self.js["meshes"]) - 1
        base = len(self.js["nodes"])
        for n in src_js["nodes"]:
            q = dict(n)
            if "mesh" in q:
                q["mesh"] = mesh_map[q["mesh"]]
            if "children" in q:
                q["children"] = [base + c for c in q["children"]]
            self.js["nodes"].append(q)
        roots = src_js["scenes"][src_js.get("scene", 0)]["nodes"]
        if len(roots) != 1 or src_js["nodes"][roots[0]].get("name") != name:
            raise SystemExit(f"[glb_bundle] {name}.glb の根が 1 つで名前が {name} でない（ゲームは根の名前で引く）")
        self.js["scenes"][0]["nodes"].append(base + roots[0])

    def finish(self):
        self.js["buffers"][0]["byteLength"] = len(self.bin)
        for kind in ("samplers", "textures", "images", "materials"):
            if not self.js[kind]:
                del self.js[kind]
        return write_glb(self.js, bytes(self.bin))


def remap_textures(obj, tex_map):
    if isinstance(obj, dict):
        return {k: (tex_map[v] if k == "index" and isinstance(v, int) else remap_textures(v, tex_map)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [remap_textures(v, tex_map) for v in obj]
    return obj


def build_all():
    layout = json.loads((SCHOOL / "layout.json").read_text())
    cache, out, manifest = {}, {}, []
    for b in bundle_plan(layout):
        builder = Builder()
        for src in b["sources"]:
            js, bin_ = read_glb(SCHOOL / src)
            builder.add_source(src[:-4], js, bin_, cache)
        rel = f"assets/school/bundle/{b['key']}.glb"
        out[rel] = builder.finish()
        manifest.append({"key": b["key"], "path": rel, "floors": b["floors"], "buildings": b["buildings"]})
    doc = {"version": 1,
           "note": "tools/glb_bundle.py の生成物（手で直さない）。key = 束の名前・path = 束の glb・floors = その束の物を置く階・buildings = その束に建物が入っている階（ブラウザ版はその階へ入る前に届くのを待つ）。",
           "bundles": manifest}
    out["assets/school/bundle/bundles.json"] = (json.dumps(doc, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    return out


def main():
    check = "--check" in sys.argv[1:]
    out = build_all()
    stale = [rel for rel, data in out.items() if not (ROOT / rel).exists() or (ROOT / rel).read_bytes() != data]
    if check:
        if stale:
            print("[glb_bundle] 束が元の glb・layout.json と合わない（make bundles で作り直す）: " + ", ".join(stale))
            sys.exit(1)
        print("[glb_bundle] 束は元の glb と合っている")
        return
    OUT.mkdir(parents=True, exist_ok=True)
    keep = set(out)
    for old in OUT.glob("*"):
        if f"assets/school/bundle/{old.name}" not in keep:
            old.unlink()
    for rel, data in out.items():
        (ROOT / rel).write_bytes(data)
    srcs = sum((SCHOOL / s).stat().st_size for b in bundle_plan(json.loads((SCHOOL / "layout.json").read_text())) for s in b["sources"])
    total = sum(len(d) for d in out.values())
    for rel, data in out.items():
        print(f"[glb_bundle] {rel}  {len(data) / 1e6:.2f} MB  gzip {len(zlib.compress(data, 9)) / 1e6:.2f} MB")
    print(f"[glb_bundle] 元 {srcs / 1e6:.1f} MB → 束 {total / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
