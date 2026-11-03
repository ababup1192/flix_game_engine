# engine のテストの資材 testdata/emissive_plates.glb を作る（Blender を使わない）。
#   python3 emissive_plates.py
# ノード 0 "sign"  = translation (−1.2, 0, 0)・板（uv つき）・材質 "sign": baseColorTexture = 2 × 2 の灰色・
#                    emissiveTexture = 2 × 2（上の行が橙・下の行が黒）・emissiveFactor (1, 1, 1)・emissiveStrength 2
# ノード 1 "flame" = translation (1.2, 0, 0)・板（uv なし）・材質 "flame": baseColorFactor 灰色・emissiveFactor (1, 0.62, 0.18)（絵なし）
# ノード 2 "tip"   = translation (1.2, 1.2, 0)・mesh なし（印の点）
# 板は glTF の XY の面の −0.5..0.5 の正方形で、表は +Z（+Z から見て反時計回り）。
import json, os, struct, zlib

HERE = os.path.dirname(os.path.abspath(__file__))

def png(rows):
    raw = b"".join(b"\x00" + bytes(c for px in row for c in px) for row in rows)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", len(rows[0]), len(rows), 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

def pad4(b, fill=b"\x00"):
    return b + fill * ((4 - len(b) % 4) % 4)

positions = [-0.5, -0.5, 0, 0.5, -0.5, 0, 0.5, 0.5, 0, -0.5, 0.5, 0]
normals = [0, 0, 1] * 4
uvs = [0, 1, 1, 1, 1, 0, 0, 0]
indices = [0, 1, 2, 0, 2, 3]
gray = (128, 128, 128)
orange, black = (255, 160, 32), (0, 0, 0)

blobs = [struct.pack("<12f", *positions), struct.pack("<12f", *normals), struct.pack("<8f", *uvs),
         struct.pack("<6H", *indices), png([[gray, gray], [gray, gray]]), png([[orange, orange], [black, black]])]
views, binary = [], b""
for blob in blobs:
    views.append({"buffer": 0, "byteOffset": len(binary), "byteLength": len(blob)})
    binary += pad4(blob)

doc = {
    "asset": {"version": "2.0"},
    "scene": 0, "scenes": [{"nodes": [0, 1, 2]}],
    "nodes": [{"name": "sign", "mesh": 0, "translation": [-1.2, 0, 0]},
              {"name": "flame", "mesh": 1, "translation": [1.2, 0, 0]},
              {"name": "tip", "translation": [1.2, 1.2, 0]}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "material": 0}]},
               {"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1}, "indices": 3, "material": 1}]}],
    "materials": [{"name": "sign", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}},
                   "emissiveTexture": {"index": 1}, "emissiveFactor": [1, 1, 1],
                   "extensions": {"KHR_materials_emissive_strength": {"emissiveStrength": 2}}},
                  {"name": "flame", "pbrMetallicRoughness": {"baseColorFactor": [0.3, 0.3, 0.3, 1]},
                   "emissiveFactor": [1, 0.62, 0.18]}],
    "extensionsUsed": ["KHR_materials_emissive_strength"],
    "samplers": [{"magFilter": 9728}],
    "textures": [{"source": 0, "sampler": 0}, {"source": 1, "sampler": 0}],
    "images": [{"bufferView": 4, "mimeType": "image/png"}, {"bufferView": 5, "mimeType": "image/png"}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [-0.5, -0.5, 0], "max": [0.5, 0.5, 0]},
                  {"bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3"},
                  {"bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC2"},
                  {"bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR"}],
    "bufferViews": views,
    "buffers": [{"byteLength": len(binary)}],
}
text = pad4(json.dumps(doc, separators=(",", ":")).encode(), b" ")
glb = (struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(text) + 8 + len(binary))
       + struct.pack("<II", len(text), 0x4E4F534A) + text + struct.pack("<II", len(binary), 0x004E4942) + binary)
open(os.path.join(HERE, "testdata", "emissive_plates.glb"), "wb").write(glb)
