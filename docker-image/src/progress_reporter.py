"""
Render progress reporter, run inside Blender via -P.

Prints one structured line per render event so render_executor.py can track
frames without parsing Blender's log text, whose layout changes between
versions ("Fra:1" in 4.x, "Fra: 1 | ..." in 5.x) and engines. Blender fires
these handlers once per frame in background mode for every engine and every
output type, image sequences and video alike.

Line format:  BANANAFARM_PROGRESS {"event": "...", "frame": N}
"""

import json

import bpy

MARKER = "BANANAFARM_PROGRESS"


def _emit(event, scene):
    print(f"{MARKER} " + json.dumps({"event": event, "frame": scene.frame_current}), flush=True)


def _on_render_pre(scene, *args):
    _emit("frame_start", scene)


def _on_render_post(scene, *args):
    _emit("frame_done", scene)


def _on_render_complete(scene, *args):
    _emit("complete", scene)


def _on_render_cancel(scene, *args):
    _emit("cancel", scene)


bpy.app.handlers.render_pre.append(_on_render_pre)
bpy.app.handlers.render_post.append(_on_render_post)
bpy.app.handlers.render_complete.append(_on_render_complete)
bpy.app.handlers.render_cancel.append(_on_render_cancel)

print(f"{MARKER} " + json.dumps({"event": "ready", "frame": bpy.context.scene.frame_current}), flush=True)
