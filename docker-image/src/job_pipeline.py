"""
Render pipeline worker.

Runs in a background thread after the project upload completes:
extract (password-protected zip) -> render -> archive outputs.
On failure or a user stop request during an animation, partial frames are
zipped and the job ends as partially_completed.

Ported from the old supabase_pod_main.py minus all Supabase/Redis/R2 calls.
"""
import hashlib
import subprocess
import threading
from pathlib import Path
from typing import List, Optional, Tuple

from job_state import (
    INPUT_ZIP_PATH,
    OUTPUT_DIR,
    JobState,
    JobStateEnum,
)
from output_archiver import zip_outputs
from render_executor import RenderExecutor, RenderProgress

EXTRACT_DIR = Path("/tmp/project_extracted")
UNZIP_TIMEOUT_SECONDS = 30 * 60


def start_pipeline(job_state: JobState) -> threading.Thread:
    thread = threading.Thread(target=_run_pipeline, args=(job_state,), daemon=True)
    thread.start()
    return thread


def terminate_blender(job_state: JobState) -> None:
    """Gracefully stop the running Blender process (user stop request)."""
    process = job_state.blender_process
    if process is None or process.poll() is not None:
        return
    print("🛑 Stopping Blender render process...")
    try:
        process.terminate()
        process.wait(timeout=5)
        print("✅ Blender process terminated gracefully")
    except subprocess.TimeoutExpired:
        print("⚠️ Blender didn't stop gracefully, force killing...")
        process.kill()
        process.wait()
        print("✅ Blender process killed")
    except Exception as e:
        print(f"⚠️ Error stopping Blender: {e}")


def _run_pipeline(job_state: JobState) -> None:
    try:
        # ============================================
        # 1. Extract project zip
        # ============================================
        job_state.render_progress.status_message = "Unpacking project..."
        lock_key = job_state.render_params.get("lock_key")
        blend_file, extract_error = _extract_project_zip(INPUT_ZIP_PATH, lock_key)

        if blend_file is None:
            job_state.set_state(JobStateEnum.FAILED, extract_error)
            return

        if job_state.stop_requested:
            job_state.set_state(JobStateEnum.FAILED, "Stopped by user")
            return

        # ============================================
        # 2. Render
        # ============================================
        job_state.set_state(JobStateEnum.RENDERING)
        job_state.render_progress.status_message = "Rendering..."
        print("\n🎨 Starting Blender render...\n")

        render_success, output_files = _execute_render(job_state, blend_file)

        # ============================================
        # 3. Archive / finalize outputs
        # ============================================
        if render_success:
            _finalize_outputs(job_state, output_files, partial=False)
        else:
            _handle_render_failure(job_state)

    except Exception as e:
        import traceback
        traceback.print_exc()
        job_state.set_state(JobStateEnum.FAILED, f"Pipeline error: {e}")


def _extract_project_zip(
    zip_path: Path, lock_key: Optional[str]
) -> Tuple[Optional[Path], Optional[str]]:
    """Extract the project zip.

    Project zips are no longer encrypted. `lock_key` is a compatibility shim
    for drafts zipped before that change, which still carry a 4-digit ZipCrypto
    password in their stored render params.

    Returns (blend_path, None) on success or (None, reason) on failure. The
    reason is specific — a wrong lock key, a corrupt archive and a zip with no
    .blend in it are genuinely different problems and used to share one
    misleading message.
    """
    print(f"📦 Extracting {zip_path}...")

    if not zip_path.exists():
        return None, "Project zip is missing on the pod"

    if EXTRACT_DIR.exists():
        import shutil
        shutil.rmtree(EXTRACT_DIR)
    EXTRACT_DIR.mkdir(parents=True, exist_ok=True)

    try:
        cmd = ["unzip", "-o"]
        if lock_key:
            cmd.extend(["-P", str(lock_key)])
        cmd.extend([str(zip_path), "-d", str(EXTRACT_DIR)])

        print(f"Running unzip to {EXTRACT_DIR}")
        # stdin=DEVNULL: without a key on an encrypted zip, unzip would
        # otherwise block forever on its password prompt.
        # No check=True: exit 1 has to be inspected rather than raised on.
        result = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=UNZIP_TIMEOUT_SECONDS,
        )
        stderr = (result.stderr or b"").decode(errors="replace").strip()

        if result.returncode == 1:
            # Info-ZIP's "extracted, but with warnings" — a filename it had to
            # transliterate, an attribute it couldn't restore. The files are on
            # disk, so the .blend lookup below is the honest verdict, not this.
            print(f"⚠️ Unzip reported warnings: {stderr}")
        elif result.returncode != 0:
            print(f"❌ Unzip failed (exit {result.returncode}): {stderr}")
            if result.returncode == 82:
                reason = "Wrong lock key for the project zip"
            elif result.returncode in (2, 3, 9):
                reason = "Project zip is corrupt or incomplete"
            else:
                reason = (
                    f"Failed to extract project zip (unzip exit {result.returncode})"
                )
            detail = stderr.splitlines()[-1] if stderr else ""
            return None, f"{reason}: {detail}" if detail else reason

        blend_file = EXTRACT_DIR / "scene.blend"
        if not blend_file.exists():
            # Recursive: a .blend nested in a subfolder is a valid project, not
            # a corrupt archive.
            blends = sorted(EXTRACT_DIR.rglob("*.blend"))
            if blends:
                blend_file = blends[0]
            else:
                print("❌ No .blend file found in zip")
                return None, "Project zip contains no .blend file"

        print(f"✅ Extracted project to: {blend_file}")
        return blend_file, None

    except subprocess.TimeoutExpired:
        print("❌ Unzip timed out")
        return None, f"Extracting the project zip timed out after {UNZIP_TIMEOUT_SECONDS}s"
    except Exception as e:
        print(f"❌ Extraction error: {e}")
        return None, f"Failed to extract project zip: {e}"


def _execute_render(job_state: JobState, blend_file: Path) -> tuple:
    """Run the Blender render; returns (success, output_files)."""
    try:
        OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

        executor = RenderExecutor(
            blend_file_path=str(blend_file),
            output_dir=str(OUTPUT_DIR),
            render_params=job_state.render_params,
            blender_version=job_state.blender_version,
        )

        def progress_callback(progress: RenderProgress):
            job_state.render_progress = progress
            if executor.blender_process:
                job_state.blender_process = executor.blender_process

        success = executor.execute_render(progress_callback=progress_callback)
        output_files = executor.get_output_files() if success else []
        return success, output_files

    except Exception as e:
        print(f"❌ Render execution error: {e}")
        job_state.render_progress.error_message = str(e)
        return False, []


def _collect_output_files() -> List[str]:
    if not OUTPUT_DIR.exists():
        return []
    return [str(p) for p in sorted(OUTPUT_DIR.rglob("*")) if p.is_file()]


def _sha256(path: str) -> str:
    """Streamed so a multi-GB video or archive never sits in memory."""
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _finalize_outputs(job_state: JobState, output_files: List[str], partial: bool) -> None:
    """Zip multi-file outputs, record the listing, and enter a terminal state."""
    if not output_files:
        job_state.set_state(JobStateEnum.FAILED, "No output files generated")
        return

    # The app verifies each download against size + sha256 before it deletes
    # the instance, which is the only copy of the render.
    job_state.output_files = [
        {"name": Path(f).name, "size": Path(f).stat().st_size, "sha256": _sha256(f)}
        for f in output_files
        if Path(f).exists()
    ]

    # Image sequences (or partial animation frames) get zipped; a single
    # image/video file is served directly.
    if len(output_files) > 1:
        job_state.set_state(JobStateEnum.ZIPPING_OUTPUT)
        job_state.render_progress.status_message = "Zipping output files..."

        zip_name = f"render-{job_state.job_id}.zip"
        zip_path = zip_outputs(output_files, zip_name)
        if zip_path is None:
            job_state.set_state(JobStateEnum.FAILED, "Failed to zip output files")
            return
        job_state.output_archive = {
            "name": zip_name,
            "size": Path(zip_path).stat().st_size,
            "sha256": _sha256(zip_path),
            "path": zip_path,
        }

    if partial:
        job_state.render_progress.status_message = (
            f"Partially completed - {len(output_files)} file(s) saved"
        )
        job_state.set_state(JobStateEnum.PARTIALLY_COMPLETED)
    else:
        job_state.render_progress.status_message = "Render completed - outputs ready"
        job_state.set_state(JobStateEnum.COMPLETED)

    print(f"\n✅ Outputs ready ({len(output_files)} file(s)). "
          "Container will idle until the instance is deleted from the app.\n")


def _handle_render_failure(job_state: JobState) -> None:
    """On failure or user stop, salvage partial animation frames if any."""
    stopped = job_state.stop_requested
    error_msg = (
        "Stopped by user"
        if stopped
        else job_state.render_progress.error_message or "Render process failed"
    )

    is_animation = job_state.render_params.get("is_animation_render", False)
    partial_files = _collect_output_files() if is_animation else []

    if partial_files:
        print(f"⚠️ Render {'stopped' if stopped else 'failed'} - "
              f"salvaging {len(partial_files)} partial frame(s)")
        job_state.error_message = error_msg
        _finalize_outputs(job_state, partial_files, partial=True)
    else:
        print(f"\n❌ Render failed: {error_msg}")
        job_state.set_state(JobStateEnum.FAILED, error_msg)
