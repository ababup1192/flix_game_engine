# engine のテストの資材 two_joints.glb を作る（ジョイント 2 本・三角 2 枚・クリップ 1 つ "bend"）。
#   blender -b --factory-startup --python two_joints.py
# 板（縦 1 m）の下半分を根のジョイント、上半分を子のジョイントに重み 1 で付け、bend で子を 90 度倒す。
# side.R は Blender の −X（キャラの右）に置いたジョイント（頂点は付けない。engine で右が +X に来るかを確かめる）。
import bpy, os, math
from mathutils import Euler
HERE = os.path.dirname(os.path.abspath(__file__))
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete()
bpy.ops.object.armature_add(enter_editmode=True)
arm = bpy.context.active_object
eb = arm.data.edit_bones
eb.remove(eb[0])
root = eb.new("root"); root.head = (0, 0, 0); root.tail = (0, 0, 0.5)
tip = eb.new("tip"); tip.head = (0, 0, 0.5); tip.tail = (0, 0, 1.0); tip.parent = root
side = eb.new("side.R"); side.head = (-0.3, 0, 0.2); side.tail = (-0.3, 0, 0.4); side.parent = root
bpy.ops.object.mode_set(mode="OBJECT")
mesh = bpy.data.meshes.new("plate")
verts = [(-0.1, 0, 0), (0.1, 0, 0), (0.1, 0, 1.0), (-0.1, 0, 1.0)]
mesh.from_pydata(verts, [], [(0, 1, 2), (0, 2, 3)])
obj = bpy.data.objects.new("plate", mesh)
bpy.context.collection.objects.link(obj)
g0 = obj.vertex_groups.new(name="root"); g0.add([0, 1], 1.0, "REPLACE")
g1 = obj.vertex_groups.new(name="tip"); g1.add([2, 3], 1.0, "REPLACE")
obj.modifiers.new("Armature", "ARMATURE").object = arm
obj.parent = arm
act = bpy.data.actions.new("bend")
arm.animation_data_create(); arm.animation_data.action = act
pb = arm.pose.bones["tip"]; pb.rotation_mode = "QUATERNION"
for frame, deg in ((1, 0), (25, 90)):
    pb.rotation_quaternion = Euler((math.radians(deg), 0, 0), "XYZ").to_quaternion()
    pb.keyframe_insert("rotation_quaternion", frame=frame)
track = arm.animation_data.nla_tracks.new(); track.name = "bend"
track.strips.new("bend", 1, act); arm.animation_data.action = None
bpy.context.scene.render.fps = 24
bpy.ops.object.select_all(action="SELECT")
bpy.ops.export_scene.gltf(filepath=os.path.join(HERE, "two_joints.glb"), export_format="GLB", export_animations=True,
                          export_animation_mode="NLA_TRACKS", export_skins=True, export_materials="NONE", export_yup=True)
print("ok")
