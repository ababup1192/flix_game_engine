# engine のテストの資材 textured_two_materials.glb を作る（材質スロット 2 つの板 2 枚・絵・法線マップ・TANGENT）。
#   blender -b --factory-startup --python textured_two_materials.py
# 板 A（Blender の x −1.5..−0.5）は材質 A: baseColorTexture = 4 × 4 の絵（左上が赤・右上が緑・左下が青・右下が白・Closest = NEAREST）と
#   normalTexture = 全部 (128, 255, 128) の 4 × 4（scale 0.5）。
# 板 B（x 0.5..1.5）は材質 B: baseColorFactor だけ（絵なし）。
# 板は XZ の面に立ち、表は Blender の −Y（正面の図から見える側）。uv は板の左上の角が Blender の (0, 1) = glTF の (0, 0)。
import bpy, os
HERE = os.path.dirname(os.path.abspath(__file__))
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete()

def image(name, rows, non_color):
    # rows は上の行から。Blender の pixels は下の行から並ぶので逆にして入れる。
    img = bpy.data.images.new(name, 4, 4, alpha=False)
    if non_color:
        img.colorspace_settings.name = "Non-Color"
    flat = []
    for row in reversed(rows):
        for (r, g, b) in row:
            flat += [r / 255.0, g / 255.0, b / 255.0, 1.0]
    img.pixels = flat
    img.file_format = "PNG"
    img.pack()
    return img

R, G, B, W = (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)
base = image("base", [[R, R, G, G], [R, R, G, G], [B, B, W, W], [B, B, W, W]], False)
flat_normal = image("normal", [[(128, 255, 128)] * 4] * 4, True)

mat_a = bpy.data.materials.new("A")
mat_a.use_nodes = True
nodes, links = mat_a.node_tree.nodes, mat_a.node_tree.links
bsdf = nodes["Principled BSDF"]
tex = nodes.new("ShaderNodeTexImage"); tex.image = base; tex.interpolation = "Closest"
links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
ntex = nodes.new("ShaderNodeTexImage"); ntex.image = flat_normal; ntex.interpolation = "Linear"
nmap = nodes.new("ShaderNodeNormalMap"); nmap.inputs["Strength"].default_value = 0.5
links.new(ntex.outputs["Color"], nmap.inputs["Color"])
links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])

mat_b = bpy.data.materials.new("B")
mat_b.use_nodes = True
mat_b.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.2, 0.6, 0.9, 1.0)

mesh = bpy.data.meshes.new("plates")
verts = [(-1.5, 0, 0), (-0.5, 0, 0), (-0.5, 0, 1), (-1.5, 0, 1), (0.5, 0, 0), (1.5, 0, 0), (1.5, 0, 1), (0.5, 0, 1)]
mesh.from_pydata(verts, [], [(0, 1, 2, 3), (4, 5, 6, 7)])
uv = mesh.uv_layers.new(name="UVMap")
corner_uvs = [(0, 0), (1, 0), (1, 1), (0, 1)]
for poly in mesh.polygons:
    for k, loop in enumerate(poly.loop_indices):
        uv.data[loop].uv = corner_uvs[k]
mesh.materials.append(mat_a)
mesh.materials.append(mat_b)
mesh.polygons[0].material_index = 0
mesh.polygons[1].material_index = 1
obj = bpy.data.objects.new("plates", mesh)
bpy.context.collection.objects.link(obj)
bpy.ops.export_scene.gltf(filepath=os.path.join(HERE, "textured_two_materials.glb"), export_format="GLB",
                          export_materials="EXPORT", export_tangents=True, export_texcoords=True, export_normals=True,
                          export_yup=True, export_animations=False, export_skins=False)
print("ok")
