# ###########################################################################
#
#                              ADDON METADATA
#
# ###########################################################################

bl_info = {
    "name": "BananaFarm",
    "author": "day-dream",
    "version": (0, 2, 0),
    "blender": (4, 0, 0),
    "location": "3D View > Sidebar (N) > BananaFarm",
    "description": "Use community cloud GPUs to speed up your renders at 10x cheaper rates than render farms.",
    "warning": "",
    "doc_url": "",
    "category": "Render",
}

# ###########################################################################
#
#                                 IMPORTS
#
# ###########################################################################

import bpy
import json
import os
import threading
import time
import urllib.request
import urllib.error
import uuid
import shutil
import subprocess
import traceback
from bpy.props import (
    StringProperty,
    CollectionProperty,
    IntProperty,
    FloatProperty,
    PointerProperty,
    BoolProperty,
    EnumProperty,
)
from bpy.types import (
    Operator,
    Panel,
    PropertyGroup,
)

# ###########################################################################
#
#                        GLOBALS & THREADING UTILITIES
#
# ###########################################################################

thread_results = {}
thread_lock = threading.Lock()

APP_UNREACHABLE_MESSAGE = 'API Renderer is unavailable, please ensure app is running'


def fetch_temp_root(port):
    """Ask the app where to stage this job's files.

    The app owns the temp tree, so we never guess a path — if it can't answer,
    the submit is aborted before anything is written to disk.
    """
    url = f"http://localhost:{port}/temp-root"
    with urllib.request.urlopen(url, timeout=5) as response:
        payload = json.loads(response.read().decode())

    temp_root = payload.get('temp_root')
    if not temp_root:
        raise RuntimeError('App did not return a temp directory')

    os.makedirs(temp_root, exist_ok=True)
    return temp_root

# ---------------------------------------------------------------------------
# Presence heartbeat.
#
# The addon normally only talks to the app during a submit, so the app has no
# way to tell whether Blender is running. This daemon thread pings the app's
# /addon-ping endpoint at a slow interval so the dashboard "Active" badge
# reflects real addon presence. It sleeps between pings — no busy loop — and
# never touches bpy data from the background thread; the port it uses is
# synced from the panel's draw() (main thread) into _heartbeat_port.
# ---------------------------------------------------------------------------

HEARTBEAT_INTERVAL = 15.0  # seconds between pings

_heartbeat_stop = threading.Event()
_heartbeat_port = 47288


def _heartbeat_loop():
    while not _heartbeat_stop.wait(HEARTBEAT_INTERVAL):
        try:
            with urllib.request.urlopen(
                f"http://localhost:{_heartbeat_port}/addon-ping", timeout=3
            ) as response:
                response.read()
        except Exception:
            # App not running, wrong port, whatever — stay silent and retry
            # on the next tick. Heartbeats must never surface as errors.
            pass


def _start_heartbeat():
    """(Re)start the heartbeat thread, stopping any thread from a previous
    registration so reloading the addon never leaks a second loop."""
    global _heartbeat_stop
    _heartbeat_stop.set()
    _heartbeat_stop = threading.Event()
    threading.Thread(
        target=_heartbeat_loop, daemon=True, name="banana-farm-heartbeat"
    ).start()

# ###########################################################################
#
#                         PROPERTY GROUP DEFINITIONS
#
# ###########################################################################

class SceneProperties(PropertyGroup):
    """Stores all addon properties within the current Blender scene."""
    server_port: IntProperty(
        name="Server Port",
        description="Port number of the testing server/API (default: 47288)",
        default=47288,
        min=1024,
        max=65535
    )

    flutter_app_port: IntProperty(
        name="Flutter App Port",
        description="Port number of the Flutter desktop application (default: 47288)",
        default=47288,
        min=1024,
        max=65535
    )

    # User-selectable Cycles device
    cycles_device_override: EnumProperty(
        name="Cycles Device",
        description="Select the compute device for Cycles rendering on the server",
        items=[
            ('OPTIX', "OptiX", "NVIDIA OptiX ray-tracing backend (RTX cards recommended)"),
            ('CUDA', "CUDA", "NVIDIA CUDA computing platform"),
        ],
        default='OPTIX'
    )


class SubmitProgress(PropertyGroup):
    """Live state of the in-flight submit.

    The panel can't see operator instance state, so the running submit
    publishes its phase here and the panel reads it back out. Registered on
    the WindowManager, not the Scene: scene properties are saved into the
    .blend, and the submit saves the file mid-flight — a file closed after
    that would reopen stuck on "Saving project..." with Submit greyed out.
    """
    job_running: BoolProperty(
        name="Job Running",
        description="True while a submit is in flight",
        default=False
    )

    job_progress: FloatProperty(
        name="Job Progress",
        description="Progress of the current submit, 0..1",
        default=0.0,
        min=0.0,
        max=1.0
    )

    job_status: StringProperty(
        name="Job Status",
        description="Human-readable phase of the current submit",
        default=""
    )

# ###########################################################################
#
#                             HELPER FUNCTIONS
#
# ###########################################################################

def show_message_box(message, title, icon):
    """Show a message box to the user."""
    def draw(self, context):
        layout = self.layout
        for line in message.split("\n"):
            layout.label(text=line)

    bpy.context.window_manager.popup_menu(draw, title=title, icon=icon)


def is_video_output(render):
    """True when the scene's output is a movie file rather than images."""
    return getattr(render, "is_movie_format", False) or \
        render.image_settings.file_format == 'FFMPEG'


# Submit phases. Fixed weights — the packer subprocess doesn't report back, so
# the bar advances per phase rather than continuously.
PHASE_SAVING = ("Saving project...", 0.05)
PHASE_PACKING = ("Packing assets...", 0.55)
PHASE_TRANSFERRING = ("Transferring to app...", 0.90)
PHASE_DONE = ("Done", 1.0)


def set_progress(context, phase):
    """Publish a phase to the panel and force the sidebar to repaint.

    Without the tag_redraw the property changes but the panel keeps showing
    whatever it drew last, so the bar would look frozen.
    """
    label, factor = phase
    props = context.window_manager.bar_progress
    props.job_running = True
    props.job_status = label
    props.job_progress = factor

    screen = getattr(context, 'screen', None)
    if screen:
        for area in screen.areas:
            if area.type == 'VIEW_3D':
                area.tag_redraw()


def clear_progress(context):
    """Hide the progress bar once a submit ends, successfully or not."""
    try:
        props = context.window_manager.bar_progress
    except (AttributeError, KeyError):
        return
    props.job_running = False
    props.job_progress = 0.0
    props.job_status = ""

    screen = getattr(context, 'screen', None)
    if screen:
        for area in screen.areas:
            if area.type == 'VIEW_3D':
                area.tag_redraw()


def find_unpacked_assets():
    """Split external assets into what packing can fix and what it can't.

    Returns (fixable, auto_handled), both lists of human-readable strings.

    Only `fixable` decides whether to prompt. The `auto_handled` set —
    sequences, caches, movie clips — can *never* be packed by Blender, so
    prompting about them would nag on every submit with no button able to
    resolve it. Those are copied beside the .blend by the packer instead, and
    are listed in the dialog only for context.
    """
    fixable = []
    auto_handled = []

    def _unpacked(collection):
        out = []
        for block in collection:
            if getattr(block, 'packed_file', None) is not None:
                continue
            if not getattr(block, 'filepath', ''):
                continue
            if block.filepath.startswith('<'):  # e.g. <builtin> fonts
                continue
            out.append(block)
        return out

    # --- Things pack_all()/pack_libraries() can actually embed ---
    images = [i for i in _unpacked(bpy.data.images) if i.source == 'FILE']
    if images:
        fixable.append(f"{len(images)} image/texture file(s)")

    for label, collection in (
        ("font(s)", bpy.data.fonts),
        ("sound(s)", bpy.data.sounds),
        ("volume/VDB file(s)", bpy.data.volumes),
    ):
        blocks = _unpacked(collection)
        if blocks:
            fixable.append(f"{len(blocks)} {label}")

    libraries = _unpacked(bpy.data.libraries)
    if libraries:
        fixable.append(f"{len(libraries)} linked .blend librarie(s)")

    # --- Things Blender refuses to pack at any version ---
    sequences = [i for i in bpy.data.images if i.source in {'SEQUENCE', 'MOVIE'}]
    if sequences:
        auto_handled.append(f"{len(sequences)} image sequence/movie(s)")

    if len(bpy.data.cache_files):
        auto_handled.append(f"{len(bpy.data.cache_files)} Alembic/USD cache(s)")

    if len(bpy.data.movieclips):
        auto_handled.append(f"{len(bpy.data.movieclips)} movie clip(s)")

    return fixable, auto_handled


def apply_packing(enable_autopack):
    """Pack external assets into the *artist's own* file.

    pack_libraries() refuses absolute paths outright ("Cannot pack absolute
    file"), so paths have to be made relative first. That can legitimately fail
    when a library lives on another volume/drive, which is not fatal — the
    packer subprocess copies whatever is left beside the .blend.
    """
    try:
        bpy.ops.file.make_paths_relative()
    except Exception as e:
        print(f"make_paths_relative failed (continuing): {e}")

    bpy.ops.file.pack_all()

    try:
        bpy.ops.file.pack_libraries()
    except Exception as e:
        print(f"pack_libraries failed (continuing): {e}")

    if enable_autopack:
        bpy.data.use_autopack = True

# ###########################################################################
#
#                                 OPERATORS
#
# ###########################################################################

class BAR_OT_SubmitRenderJob(Operator):
    """
    Submit render job to Flutter app.
    """
    bl_idname = "bar.submit_render_job"
    bl_label = "Submit Render Job"
    bl_options = {'REGISTER', 'UNDO'}

    is_animation_job: BoolProperty(default=False)

    # How to treat unpacked assets. 'ASK' (the default) triggers the prompt;
    # the prompt's buttons re-invoke this operator with a concrete choice.
    # SKIP_SAVE keeps the choice from persisting into the next submit.
    pack_mode: EnumProperty(
        items=[
            ('ASK', "Ask", "Prompt if unpacked assets are found"),
            ('PACK', "Pack Assets", "Pack assets into this .blend before submitting"),
            ('PACK_AUTO', "Pack + Auto-pack", "Pack assets and enable Automatically Pack Resources"),
            ('SKIP', "Submit Anyway", "Leave this .blend untouched"),
        ],
        default='ASK',
        options={'SKIP_SAVE'}
    )

    _timer = None
    _request_id = ""
    _thread = None
    _step = "idle"
    _temp_dir = ""
    _project_file = ""
    _subprocess = None
    _log_file = None
    _log_path = ""
    _video_promoted = False
    _packing_started = 0.0

    def invoke(self, context, event):
        """Prompt before submitting if the scene has unpacked external assets.

        Silent for self-contained scenes — there's nothing to decide.
        """
        if self.pack_mode == 'ASK':
            self._fixable, self._auto_handled = find_unpacked_assets()
            # Only prompt about things packing can actually fix.
            if self._fixable:
                return context.window_manager.invoke_popup(self, width=420)

        return self.execute(context)

    def draw(self, context):
        """Popup body. invoke_popup gives no OK/Cancel, so these are the
        actual buttons — each re-invokes the operator with a decided mode."""
        layout = self.layout
        layout.label(text="This project has unpacked external assets:", icon='ERROR')

        box = layout.box()
        for item in getattr(self, '_fixable', []):
            box.label(text=f"• {item}")

        auto_handled = getattr(self, '_auto_handled', [])
        if auto_handled:
            layout.label(text="Copied automatically (Blender can't pack these):")
            box = layout.box()
            for item in auto_handled:
                box.label(text=f"• {item}")

        layout.label(text="Pack them so the render farm can find them.")

        col = layout.column(align=True)
        op = col.operator("bar.submit_render_job", text="Pack Assets", icon='PACKAGE')
        op.is_animation_job = self.is_animation_job
        op.pack_mode = 'PACK'

        op = col.operator("bar.submit_render_job", text="Pack Assets + Turn On Auto-Pack", icon='FILE_TICK')
        op.is_animation_job = self.is_animation_job
        op.pack_mode = 'PACK_AUTO'

        col.separator()
        op = col.operator("bar.submit_render_job", text="Submit Anyway", icon='X')
        op.is_animation_job = self.is_animation_job
        op.pack_mode = 'SKIP'

    def modal(self, context, event):
        # Esc cancels a pack that is taking too long or has hung. Only during
        # packing: once transferring, the app may already be zipping the temp
        # folder, so pulling it out from under it would be worse than waiting
        # out the request's own timeout.
        if event.type == 'ESC' and event.value == 'PRESS' and self._step == "packing":
            if self._subprocess and self._subprocess.poll() is None:
                self._subprocess.terminate()
                try:
                    self._subprocess.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self._subprocess.kill()
            print("Submit cancelled during packing.")
            self.cleanup(context, remove_temp=True)
            self.report({'WARNING'}, "Submit cancelled")
            return {'CANCELLED'}

        # The state check only ever advances on a timer tick; without this gate
        # it re-runs on every mouse move.
        if event.type != 'TIMER':
            return {'PASS_THROUGH'}

        if self._step == "packing":
            # Repaint with elapsed time each tick, so a slow pack visibly keeps
            # moving instead of looking frozen on an earlier phase.
            if self._subprocess and self._subprocess.poll() is None:
                elapsed = int(time.time() - self._packing_started)
                label, factor = PHASE_PACKING
                set_progress(context, (f"{label} ({elapsed}s, Esc to cancel)", factor))

            # Check if subprocess is finished
            if self._subprocess and self._subprocess.poll() is not None:
                # Process finished
                return_code = self._subprocess.returncode
                self._close_log()
                if return_code != 0:
                    error_msg = self._read_log_tail() or "Unknown packer error"
                    print(f"Packer log ({self._log_path}):\n{error_msg}")
                    show_message_box(
                        f"Packing failed. See {self._log_path}",
                        "Packing Error",
                        "ERROR",
                    )
                    self.cleanup(context, remove_temp=True)
                    return {'FINISHED'}

                # Proceed to upload
                print(f"Packing complete. Files ready in: {self._temp_dir}")
                set_progress(context, PHASE_TRANSFERRING)
                self.transfer_job(context)
                return {'PASS_THROUGH'}

        elif self._step == "transferring":
            if self._thread and not self._thread.is_alive():
                self._thread.join()
                with thread_lock:
                    result = thread_results.pop(self._request_id, None)

                if not result or result['status'] == 'ERROR':
                    original_error = result.get('message', 'An unknown error occurred.') if result else 'Job transfer failed with no error details.'
                    show_message_box(f"Job Transfer Error: {original_error}", "Transfer Failed", "ERROR")
                    self.cleanup(context, remove_temp=True)
                    return {'FINISHED'}

                set_progress(context, PHASE_DONE)
                message = "Job transferred successfully to Flutter app!"
                if self._video_promoted:
                    message += "\nOutput format is video, so it was submitted as an animation."
                show_message_box(message, "Success", "INFO")
                self.cleanup(context)
                return {'FINISHED'}

        return {'PASS_THROUGH'}

    def execute(self, context):
        # 1. Check if file is saved
        if bpy.data.is_dirty or not bpy.data.filepath:
            show_message_box("Please save your file before submitting.", "Unsaved Changes", "ERROR")
            return {'CANCELLED'}

        # A video output can't be rendered as a single still, so a still submit
        # with a movie format becomes an animation submit.
        self._video_promoted = False
        if not self.is_animation_job and is_video_output(context.scene.render):
            self.is_animation_job = True
            self._video_promoted = True
            print("Submit Still with video output detected. Submitting as animation.")
            self.report({'INFO'}, "Output format selected is video, rendering as animation instead.")

        # 2. Ask the app where to stage files. Done before anything is written
        #    or saved, so an unreachable app costs the user nothing.
        try:
            temp_root = fetch_temp_root(context.scene.bar_props.server_port)
        except Exception as e:
            print(f"Could not reach the app for a temp directory: {e}")
            show_message_box(APP_UNREACHABLE_MESSAGE, "App Unreachable", "ERROR")
            return {'CANCELLED'}

        # 3. Setup modal
        self._step = "start"
        wm = context.window_manager
        self._timer = wm.event_timer_add(0.5, window=context.window)
        wm.modal_handler_add(self)
        set_progress(context, PHASE_SAVING)

        # Everything from here on runs with the progress bar showing, so any
        # failure must go through cleanup — an exception that escapes leaves
        # the bar stuck on "Saving project..." with no visible error.
        try:
            # 4. Create temp directory
            filename = os.path.splitext(bpy.path.basename(bpy.data.filepath))[0]
            # Sanitize filename
            filename = "".join([c for c in filename if c.isalpha() or c.isdigit() or c==' ' or c=='_']).strip().replace(' ', '_')
            if not filename: filename = "project"

            unique_id = uuid.uuid4().hex[:8]
            self._temp_dir = os.path.join(temp_root, f"{filename}_{unique_id}")
            os.makedirs(self._temp_dir, exist_ok=True)
            print(f"Created temp dir: {self._temp_dir}")

            # 5. Save the current file; the packer reads it from disk
            # Check and correct resolution to be divisible by 2 (required for video encoding)
            render = context.scene.render
            if render.resolution_x % 2 != 0:
                render.resolution_x = round(render.resolution_x / 2) * 2
                print(f"adjusted resolution_x to {render.resolution_x}")
            
            if render.resolution_y % 2 != 0:
                render.resolution_y = round(render.resolution_y / 2) * 2
                print(f"adjusted resolution_y to {render.resolution_y}")

            # Pack the artist's own file if they asked for it. Done after the
            # is_dirty guard above, since packing dirties the file.
            if self.pack_mode in {'PACK', 'PACK_AUTO'}:
                print(f"Packing assets into project (mode={self.pack_mode})")
                apply_packing(enable_autopack=(self.pack_mode == 'PACK_AUTO'))

            # We save first to ensure disk is up to date (already checked is_dirty but good practice)
            bpy.ops.wm.save_mainfile()

            # The packer runs against the ORIGINAL file, not a copy in temp.
            # Copying first would leave every "//relative" path resolving
            # against the temp folder, where the originals don't exist — so
            # pack_all and copy_and_remap would both silently find nothing.
            # The packer writes the finished scene.blend into temp itself.
            self._project_file = bpy.data.filepath

            # 6. Generate and Run Packer Script
            self.run_packer_subprocess(context)

        except Exception as e:
            traceback.print_exc()
            show_message_box(f"Submit failed: {e}", "Submit Error", "ERROR")
            self.cleanup(context, remove_temp=True)
            return {'CANCELLED'}

        return {'RUNNING_MODAL'}

    def run_packer_subprocess(self, context):
        """Generates the packer script and runs it in a background Blender process."""
        packer_script_path = os.path.join(self._temp_dir, "packer.py")

        # Define the packing script content
        # This script runs in a separate Blender process to pack resources into the temp folder
        packer_code = f'''
import bpy
import os
import re
import shutil
import sys

TEMP_DIR = r"{self._temp_dir}"
OUTPUT_BLEND = os.path.join(TEMP_DIR, "scene.blend")

def log(msg):
    print(f"[SURGICAL-PACKER] {{msg}}")

def copy_and_remap(data_block, folder_name):
    """Generic helper to copy external files and remap to local //folder/."""
    if not hasattr(data_block, "filepath") or not data_block.filepath:
        return

    # Get absolute path of the source
    src = bpy.path.abspath(data_block.filepath)
    if not os.path.exists(src):
        log(f"Warning: File not found {{src}}")
        return

    # Prepare destination
    filename = os.path.basename(src)
    target_dir = os.path.join(TEMP_DIR, folder_name)
    os.makedirs(target_dir, exist_ok=True)
    dst = os.path.join(target_dir, filename)

    # Copy file if it's not already there
    try:
        if not os.path.exists(dst):
            shutil.copy2(src, dst)
            log(f"Copied: {{filename}} to {{folder_name}}")

        # Remap path to be relative to the new .blend file location
        data_block.filepath = f"//{{folder_name}}/{{filename}}"
    except Exception as e:
        log(f"Error copying {{filename}}: {{e}}")

def copy_sequence(image, folder_name):
    """Copy every frame of a numbered image sequence, not just the first.

    copy_and_remap would take only the frame the datablock points at, which
    renders frame 1 correctly and nothing else.
    """
    src = bpy.path.abspath(image.filepath)
    directory = os.path.dirname(src)
    filename = os.path.basename(src)

    if not os.path.isdir(directory):
        log(f"Warning: sequence directory not found {{directory}}")
        return

    stem, extension = os.path.splitext(filename)
    match = re.search(r"(\\d+)$", stem)
    if not match:
        # Not actually numbered — treat it as a single file.
        copy_and_remap(image, folder_name)
        return

    prefix = stem[:match.start()]
    pattern = re.compile(
        "^" + re.escape(prefix) + r"\\d+" + re.escape(extension) + "$",
        re.IGNORECASE,
    )

    target_dir = os.path.join(TEMP_DIR, folder_name)
    os.makedirs(target_dir, exist_ok=True)

    copied = 0
    try:
        for name in os.listdir(directory):
            if not pattern.match(name):
                continue
            dst = os.path.join(target_dir, name)
            if not os.path.exists(dst):
                shutil.copy2(os.path.join(directory, name), dst)
            copied += 1
        image.filepath = f"//{{folder_name}}/{{filename}}"
        log(f"Copied {{copied}} frame(s) for sequence {{prefix}}*{{extension}}")
    except Exception as e:
        log(f"Error copying sequence {{prefix}}: {{e}}")

def surgical_pack():
    try:
        # 1. Everything Blender can embed on its own: images (source=FILE),
        #    volumes/VDB, fonts and sounds.
        log("Packing embeddable assets (images, volumes, fonts, sounds)...")
        bpy.ops.file.pack_all()

        # 2. Linked libraries. pack_libraries() rejects absolute paths
        #    outright, so paths must be made relative first. Either step can
        #    fail legitimately (e.g. a library on another volume) — log and
        #    carry on rather than failing the whole job.
        try:
            bpy.ops.file.make_paths_relative()
        except Exception as e:
            log(f"make_paths_relative failed (continuing): {{e}}")
        try:
            bpy.ops.file.pack_libraries()
        except Exception as e:
            log(f"pack_libraries failed (continuing): {{e}}")

        # 3. The genuinely unpackable data blocks get copied beside the .blend
        #    instead. Volumes are NOT here — pack_all() already embedded them.

        # 3a. Alembic / USD Cache Files
        log("Checking for Alembic/USD caches...")
        for cache in bpy.data.cache_files:
            copy_and_remap(cache, "caches")

        # 3b. Mesh Cache Modifiers (.mdd, .pc2)
        log("Checking for Mesh Cache modifiers...")
        for obj in bpy.data.objects:
            for mod in obj.modifiers:
                if mod.type == 'MESH_CACHE':
                    copy_and_remap(mod, "mesh_caches")

        # 3c. Movie clips (tracking footage)
        log("Checking for movie clips...")
        for clip in bpy.data.movieclips:
            copy_and_remap(clip, "clips")

        # 3d. Image sequences and movies — Blender refuses to pack these
        log("Checking for image sequences and movies...")
        for image in bpy.data.images:
            if image.source == 'SEQUENCE':
                copy_sequence(image, "sequences")
            elif image.source == 'MOVIE':
                copy_and_remap(image, "sequences")

        # 4. Write the finished, self-contained blend into the temp folder.
        #    relative_remap MUST be False: it defaults to True, which would
        #    rewrite the "//caches/..." paths set above to keep pointing at
        #    the original project directory instead of the temp folder.
        log(f"Saving packed blend to {{OUTPUT_BLEND}}...")
        bpy.ops.wm.save_as_mainfile(
            filepath=OUTPUT_BLEND,
            relative_remap=False,
            compress=False,
        )
        log("Success: Surgical pack complete.")

    except Exception as e:
        import traceback
        sys.stderr.write(f"PACKER ERROR: {{str(e)}}\\n")
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    surgical_pack()
'''

        with open(packer_script_path, 'w') as f:
            f.write(packer_code)
            
        print(f"Packer script written to: {packer_script_path}")
        
        # Run Blender in background
        blender_bin = bpy.app.binary_path
        # --disable-autoexec: the packer only packs and saves, so the file's
        # own auto-run scripts must not run — one that loops or waits would
        # keep this background process alive forever.
        cmd = [blender_bin, "-b", "--disable-autoexec", self._project_file, "-P", packer_script_path]
        
        print(f"Starting packer process: {' '.join(cmd)}")
        self._step = "packing"
        self._packing_started = time.time()
        set_progress(context, PHASE_PACKING)

        # Log to a file rather than PIPE. With PIPE, nothing drains the stream
        # until the process exits, so a chatty packer can fill the ~64KB OS
        # pipe buffer and block forever — poll() would never return and the
        # submit would hang. pack_all() on a heavy scene makes that likely.
        self._log_path = os.path.join(self._temp_dir, "packer.log")
        self._log_file = open(self._log_path, 'w')
        self._subprocess = subprocess.Popen(
            cmd,
            stdout=self._log_file,
            stderr=subprocess.STDOUT,
        )

    def _close_log(self):
        """Release the packer log handle once the subprocess has exited."""
        if self._log_file:
            try:
                self._log_file.close()
            except Exception:
                pass
            self._log_file = None

    def _read_log_tail(self, limit=1500):
        """Last slice of the packer log, for error reporting."""
        if not self._log_path or not os.path.exists(self._log_path):
            return ""
        try:
            with open(self._log_path, 'r', errors='replace') as f:
                return f.read()[-limit:].strip()
        except Exception as e:
            return f"(could not read packer log: {e})"

    def cleanup(self, context=None, remove_temp=False):
        """Tear down the modal timer, and the temp dir if the job never made it
        to the app.

        On success the app owns the folder — it zips the contents and deletes
        it — so we only remove it ourselves when the submit failed here.
        """
        if self._timer:
            bpy.context.window_manager.event_timer_remove(self._timer)
            self._timer = None

        self._close_log()

        # Reset state so a second submit in the same session doesn't inherit a
        # finished subprocess/thread and skip straight past its own packing.
        self._step = "idle"
        self._subprocess = None
        self._thread = None

        clear_progress(context or bpy.context)

        if remove_temp and self._temp_dir and os.path.exists(self._temp_dir):
            try:
                shutil.rmtree(self._temp_dir)
                print(f"Removed temp dir: {self._temp_dir}")
            except Exception as e:
                print(f"Could not remove temp dir {self._temp_dir}: {e}")

    def transfer_job(self, context):
        """Transfer job data to Flutter app."""
        props = context.scene.bar_props
        scene = context.scene
        render = scene.render
        
        # Get render parameters
        start_frame = scene.frame_start
        end_frame = scene.frame_end
        is_animation_render = self.is_animation_job
        is_video = is_animation_render and is_video_output(render)
        is_image_sequence = is_animation_render and not is_video
        output_format = render.image_settings.file_format

        render_params = {
            "engine": render.engine,
            "frame_start": start_frame,
            "frame_end": end_frame,
            "is_animation_render": is_animation_render,
            "is_image_sequence": is_image_sequence,
            "is_video_output": is_video,
            "cycles_device": props.cycles_device_override if render.engine == 'CYCLES' else "CUDA",
            "current_frame": scene.frame_current,
            "original_filename": bpy.path.basename(bpy.data.filepath),
            "output_format": output_format,
            "resolution": f"{int(render.resolution_x * (render.resolution_percentage / 100))}x{int(render.resolution_y * (render.resolution_percentage / 100))}",
            # Exact Blender build so the render container downloads the same version
            "blender_version": ".".join(map(str, bpy.app.version))
        }
        
        # Send the DIRECTORY path instead of the zip file
        job_data = {
            "blend_file_path": self._temp_dir, # Sending folder path
            "render_params": render_params,
            "server_url": None
        }
        
        data = json.dumps(job_data).encode('utf-8')
        headers = {'Content-Type': 'application/json'}
        url = f"http://localhost:{props.server_port}/transfer-job"

        self._request_id = f"transfer_{time.time()}"
        self._step = "transferring"
        self._thread = threading.Thread(target=self._transfer_thread, args=(self._request_id, url, data, headers))
        self._thread.start()

    def _transfer_thread(self, request_id, url, data, headers):
        """Thread function for job transfer."""
        try:
            req = urllib.request.Request(url, data=data, headers=headers)
            with urllib.request.urlopen(req, timeout=30) as response:
                result = json.loads(response.read().decode())
                with thread_lock:
                    thread_results[request_id] = {
                        'status': 'SUCCESS',
                        'data': result
                    }
        except urllib.error.URLError as e:
            # Connection refused or timeout - Flutter app not running
            with thread_lock:
                thread_results[request_id] = {
                    'status': 'ERROR',
                    'message': APP_UNREACHABLE_MESSAGE
                }
        except Exception as e:
            with thread_lock:
                thread_results[request_id] = {
                    'status': 'ERROR',
                    'message': str(e)
                }

# ###########################################################################
#
#                                 PANELS
#
# ###########################################################################

class BAR_PT_MainPanel(Panel):
    """Main panel for the addon."""
    bl_label = "BananaFarm"
    bl_idname = "BAR_PT_main_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "BananaFarm"

    def draw(self, context):
        layout = self.layout
        props = context.scene.bar_props
        progress = context.window_manager.bar_progress

        # Keep the heartbeat thread's target port in sync with the user's
        # setting. draw() runs on the main thread, so this is a safe place.
        global _heartbeat_port
        _heartbeat_port = props.server_port

        # Settings
        box = layout.box()
        box.label(text="Settings", icon='PREFERENCES')
        row = box.row()
        row.prop(props, "server_port", text="Server Port")
        row = box.row()
        row.prop(props, "flutter_app_port", text="Flutter App Port")

        # Render Job Submission
        box = layout.box()
        box.label(text="Render Job", icon='RENDER_ANIMATION')

        col = box.column()
        col.prop(props, "cycles_device_override", text="Device")

        row = col.row(align=True)
        row.enabled = not progress.job_running
        row.operator("bar.submit_render_job", text="Submit Still", icon='RENDER_STILL').is_animation_job = False
        row.operator("bar.submit_render_job", text="Submit Animation", icon='RENDER_ANIMATION').is_animation_job = True

        # Live progress for the in-flight submit
        if progress.job_running:
            col.separator()
            col.progress(factor=progress.job_progress, text=progress.job_status)

# ###########################################################################
#
#                              REGISTRATION
#
# ###########################################################################

classes = [
    SceneProperties,
    SubmitProgress,
    BAR_OT_SubmitRenderJob,
    BAR_PT_MainPanel,
]

def register():
    for cls in classes:
        bpy.utils.register_class(cls)

    bpy.types.Scene.bar_props = PointerProperty(type=SceneProperties)
    bpy.types.WindowManager.bar_progress = PointerProperty(type=SubmitProgress)

    _start_heartbeat()

def unregister():
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)

    del bpy.types.Scene.bar_props
    del bpy.types.WindowManager.bar_progress

    _heartbeat_stop.set()

if __name__ == "__main__":
    register()
