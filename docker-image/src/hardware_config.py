# hardware_config.py
import bpy
import sys
import os

def _configure_egl():
    """Configure EGL environment for headless GPU rendering"""
    env_vars = {
        'EGL_PLATFORM': 'device',
        'PYOPENGL_PLATFORM': 'egl',
        '__EGL_VENDOR_LIBRARY_DIRS': '/usr/share/glvnd/egl_vendor.d',
        '__GLX_VENDOR_LIBRARY_DIRS': '/usr/share/glvnd/egl_vendor.d',
        'LIBGL_ALWAYS_SOFTWARE': '0',
        'DISPLAY': '',
        'WAYLAND_DISPLAY': '',
        'XDG_RUNTIME_DIR': '',
        # Disable Wayland decorations to avoid libdecor dependency
        'WAYLAND_DEBUG': '0',
        'GDK_BACKEND': 'x11',
    }
    
    for key, value in env_vars.items():
        os.environ[key] = value

def _get_cycles_preferences():
    """Return Cycles preferences object or raise a clear error."""
    prefs = bpy.context.preferences
    if 'cycles' not in prefs.addons:
        raise RuntimeError("Cycles addon not available in this Blender build")
    return prefs.addons['cycles'].preferences

def _discover_devices(preferred_order):
    cycles_prefs = _get_cycles_preferences()
    for device_type in preferred_order:
        try:
            cycles_prefs.compute_device_type = device_type
            cycles_prefs.get_devices()
            # Enable any non-CPU device found when this compute type is set
            devices = [d for d in cycles_prefs.devices if d.type != 'CPU']
            if devices:
                _log(f"✅ {device_type} devices: " + ", ".join(f"{d.name} ({d.type})" for d in devices))
                return device_type, devices
            else:
                _log(f"⚠️ No {device_type} devices detected (found: {[d.type for d in cycles_prefs.devices]})")
        except Exception as e:
            _log(f"⚠️ {device_type} not supported: {e}")
    return None, []

def _enable_gpu_only(device_type):
    """Enable only GPU devices for the provided device_type; disable CPU."""
    cycles_prefs = _get_cycles_preferences()
    cycles = bpy.context.scene.cycles

    # Force GPU device usage in Cycles
    cycles.device = 'GPU'

    # Refresh to ensure we have an up-to-date device list
    cycles_prefs.compute_device_type = device_type
    cycles_prefs.get_devices()

    enabled_gpu = 0
    disabled_cpu = 0

    for device in cycles_prefs.devices:
        # Trust that if get_devices() returned it under this compute_device_type, it's compatible
        # Just exclude CPU explicitly
        if device.type != 'CPU':
            device.use = True
            enabled_gpu += 1
        else:
            device.use = False
            disabled_cpu += 1

    _log(f"🔧 Compute type: {cycles_prefs.compute_device_type}")
    _log(f"🔧 Cycles device: {cycles.device}")
    _log(f"✅ Enabled GPU devices: {enabled_gpu} | ❌ Disabled CPU devices: {disabled_cpu}")

def _enable_system_gpu():
    """Enable GPU devices in system preferences for EEVEE"""
    try:
        prefs = bpy.context.preferences
        
        # For EEVEE, we don't need to configure system.compute_device_type
        # Just ensure Cycles preferences are set up for GPU detection
        if 'cycles' in prefs.addons:
            cycles_prefs = prefs.addons['cycles'].preferences
            cycles_prefs.compute_device_type = 'CUDA'
            cycles_prefs.get_devices()
            
            gpu_count = 0
            for device in cycles_prefs.devices:
                if device.type in {'CUDA', 'OPTIX'}:
                    device.use = True
                    gpu_count += 1
            
            _log(f"✅ GPU devices configured for EEVEE: {gpu_count}")
        else:
            _log("ℹ️ Cycles addon not available, EEVEE will use available GPU automatically")
            
    except Exception as e:
        _log(f"⚠️ Could not configure GPU for EEVEE: {e}")

def _fallback_cpu_only():
    """Explicitly configure CPU-only if no GPU backends are available."""
    cycles_prefs = _get_cycles_preferences()
    cycles = bpy.context.scene.cycles
    cycles.device = 'CPU'
    cycles_prefs.get_devices()
    for device in cycles_prefs.devices:
        device.use = (device.type == 'CPU')
    _log("ℹ️ Falling back to CPU-only rendering (no CUDA/OptiX available)")

def _log(message):
    # Logged lines will appear in Blender stdout and be parsed by our service
    print(f"HWCFG: {message}")

def configure_render_hardware():
    scene = bpy.context.scene
    engine = scene.render.engine
    
    # Configure EGL for ALL engines (Cycles and EEVEE) to ensure headless stability
    _log(f"Configuring EGL for {engine}")
    _configure_egl()

    # Configure EGL for EEVEE
    if engine == 'BLENDER_EEVEE_NEXT':
        _enable_system_gpu()
        return True
    
    # Configure GPU for Cycles
    if engine != 'CYCLES':
        _log(f"Skipping hardware config: engine is {engine}")
        return True
    
    preferred_device = None
    # Check if arguments were passed to the script via '--'
    if '--' in sys.argv:
        args = sys.argv[sys.argv.index('--') + 1:]
        if args:
            preferred_device = args[0]
            _log(f"Received preferred device from job: {preferred_device}")

    # Determine the search order for devices
    if preferred_device:
        # If a device was passed, use it as priority but allow logical fallbacks
        if preferred_device == 'OPTIX':
            # Many cards support OptiX but might fail to init it in some envs - fall back to CUDA
            device_search_order = ['OPTIX', 'CUDA']
        else:
            device_search_order = [preferred_device]
    else:
        # Otherwise, fall back to the default automatic discovery
        _log("No preferred device specified, trying auto-discovery (OptiX -> CUDA)")
        device_search_order = ['OPTIX', 'CUDA']

    try:
        # Try discovery in preferred order for RTX cards
        device_type, devices = _discover_devices(device_search_order)
        if device_type and devices:
            _enable_gpu_only(device_type)
        else:
            _fallback_cpu_only()

        # Emit a concise status summary
        cycles_prefs = _get_cycles_preferences()
        enabled = [f"{d.name} ({d.type})" for d in cycles_prefs.devices if d.use]
        disabled = [f"{d.name} ({d.type})" for d in cycles_prefs.devices if not d.use]
        _log("Status → Enabled: " + ", ".join(enabled) if enabled else "Status → Enabled: none")
        _log("Status → Disabled: " + ", ".join(disabled) if disabled else "Status → Disabled: none")
        return True
    except Exception as exc:
        _log(f"❌ Configuration error: {exc}")
        return False

if __name__ == "__main__":
    configure_render_hardware()