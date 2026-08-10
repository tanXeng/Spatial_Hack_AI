"""Merge Tripo's per-clip FBX exports into USDZ assets RealityKit can load.

Tripo exported one FBX per animation, with the skinned mesh embedded only in the jab file.
All five share an identical 65-bone Mixamo skeleton rooted at a single `mixamorig10:Hips`,
so the actions are interchangeable across them.

Output:
  coach.usdz            mesh + skeleton + guard_idle
  coach_<clip>.usdz     skeleton + that one action, no mesh (small)
"""
import bpy
import os
import math

ART = "/Users/event/Documents/Spatial_Hack_AI/Art"
OUT = os.path.join(ART, "usdz")

# source file -> clip name exposed to RealityKit
CLIPS = [
    ("Idle_stance.fbx",        "guard_idle"),
    ("Left_hand_jab.fbx",      "jab_left"),
    ("right hand cross.fbx",   "cross_right"),
    ("back hand hook.fbx",     "hook_right"),
    ("back hand uppercut.fbx", "uppercut_right"),
]
BASE_FBX = "Left_hand_jab.fbx"   # the only one carrying the skinned mesh


def clean():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def import_fbx(name):
    bpy.ops.import_scene.fbx(filepath=os.path.join(ART, name))


def only_action():
    acts = list(bpy.data.actions)
    return acts[0] if len(acts) == 1 else None


def armature():
    for o in bpy.data.objects:
        if o.type == 'ARMATURE':
            return o
    return None


def meshes():
    return [o for o in bpy.data.objects if o.type == 'MESH']


def set_range_from(action):
    fs, fe = action.frame_range
    bpy.context.scene.frame_start = int(fs)
    bpy.context.scene.frame_end = int(fe)
    bpy.context.scene.frame_set(int(fs))


def assign(arm, action):
    if arm.animation_data is None:
        arm.animation_data_create()
    arm.animation_data.action = action
    # Blender 4.4+ slotted actions: bind the first slot so the action actually evaluates.
    try:
        slots = list(action.slots)
        if slots:
            arm.animation_data.action_slot = slots[0]
    except AttributeError:
        pass


def export(path, downscale=True, materials=True):
    kwargs = dict(
        filepath=path,
        export_animation=True,
        export_materials=materials,
        export_meshes=True,
        triangulate_meshes=True,
        root_prim_path="/Root",
    )
    if downscale:
        kwargs["usdz_downscale_size"] = 'CUSTOM'
        kwargs["usdz_downscale_custom_size"] = 2048
    bpy.ops.wm.usd_export(**kwargs)
    print(f"  wrote {path} ({os.path.getsize(path)/1e6:.1f} MB)")


os.makedirs(OUT, exist_ok=True)

# ---- base asset: mesh + skeleton + idle -------------------------------------------------
print("=== base: mesh + guard_idle ===")
clean()
import_fbx(BASE_FBX)
arm = armature()
ms = meshes()
h = max((o.dimensions.z for o in ms), default=0)
print(f"  armature={arm.name} meshes={len(ms)} height={h:.3f} m scale={tuple(round(v,3) for v in arm.scale)}")

# Drop the jab action that shipped with the mesh; the base asset idles.
for a in list(bpy.data.actions):
    bpy.data.actions.remove(a)

import_fbx("Idle_stance.fbx")
idle = only_action()
idle.name = "guard_idle"
# The idle FBX brings its own armature; keep the skinned one and delete the spare.
for o in [o for o in bpy.data.objects if o.type == 'ARMATURE' and o is not arm]:
    bpy.data.objects.remove(o, do_unlink=True)
assign(arm, idle)
set_range_from(idle)
export(os.path.join(OUT, "coach.usdz"))

# ---- one animation-only asset per punch --------------------------------------------------
for src, clip in CLIPS:
    if clip == "guard_idle":
        continue
    # RealityKit only surfaces `availableAnimations` for a skeleton that actually drives skinned
    # geometry. A skeleton-plus-SkelAnimation file loads without error and exposes nothing, so each
    # clip has to carry the mesh. Materials are dropped instead — the geometry alone is what makes
    # the animation bindable, and these entities exist only to hand their animation to the base
    # model, never to be rendered.
    print(f"=== {clip} (from {src}) ===")
    clean()

    # Start from the skinned mesh, then drop its jab action so only this clip's remains.
    import_fbx(BASE_FBX)
    arm = armature()
    for a in list(bpy.data.actions):
        bpy.data.actions.remove(a)

    import_fbx(src)
    act = only_action()
    act.name = clip
    for spare in [o for o in bpy.data.objects if o.type == 'ARMATURE' and o is not arm]:
        bpy.data.objects.remove(spare, do_unlink=True)

    assign(arm, act)
    set_range_from(act)
    export(os.path.join(OUT, f"coach_{clip}.usdz"), downscale=False, materials=False)

print("\nDONE")
