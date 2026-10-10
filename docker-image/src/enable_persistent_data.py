"""
Force enable persistent data for Cycles rendering
This keeps render data in memory between frames, significantly speeding up animation renders
"""
import bpy

# Force enable persistent data for all view layers
for scene in bpy.data.scenes:
    if hasattr(scene, 'render'):
        # Enable persistent data in render settings
        if hasattr(scene.render, 'use_persistent_data'):
            scene.render.use_persistent_data = True
            print(f"✅ Enabled persistent data for scene: {scene.name}")

# Also ensure it's enabled in Cycles settings if available
if hasattr(bpy.context.scene, 'cycles'):
    if hasattr(bpy.context.scene.cycles, 'use_persistent_data'):
        bpy.context.scene.cycles.use_persistent_data = True
        print("✅ Enabled persistent data for Cycles engine")

print("✅ Persistent data configuration complete")

