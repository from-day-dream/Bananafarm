# gpu_monitor.py - Add this to your Blender script
import bpy
import subprocess
import threading
import time

def monitor_gpu():
    """Monitor GPU usage during render."""
    print("🔍 Starting GPU monitoring...")
    try:
        # Run nvidia-smi every 2 seconds during render
        for i in range(10):  # Monitor for 20 seconds
            result = subprocess.run(['nvidia-smi', '--query-gpu=utilization.gpu,memory.used,memory.total,power.draw', '--format=csv,noheader,nounits'], 
                                  capture_output=True, text=True)
            if result.returncode == 0:
                gpu_util, mem_used, mem_total, power = result.stdout.strip().split(', ')
                print(f"GPU: {gpu_util}% util | Memory: {mem_used}/{mem_total}MB | Power: {power}W")
            time.sleep(2)
    except Exception as e:
        print(f"GPU monitoring error: {e}")

# Start monitoring in background before render
monitor_thread = threading.Thread(target=monitor_gpu)
monitor_thread.daemon = True
monitor_thread.start()

# Your existing hardware config
scene = bpy.context.scene
print(f"Final check - Render engine: {scene.render.engine}")
print(f"Final check - Cycles device: {scene.cycles.device}")

# Let monitoring run for a bit
time.sleep(1)