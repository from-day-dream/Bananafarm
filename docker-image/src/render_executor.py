"""
Render Executor Module for Blender Rendering
=============================================
Handles Blender render execution with real-time progress tracking.
Extracted and adapted from celery_worker.py for Supabase pod mode.

Features:
- Parse render parameters from JSON
- Execute Blender subprocess with xvfb-run
- Track rendering progress (frames and samples)
- Collect output files after render
"""

import subprocess
import re
import os
import json
from pathlib import Path
from typing import Dict, List, Optional, Callable, Any


class RenderProgress:
    """Container for render progress information"""

    def __init__(self):
        self.progress_percent = 0.0
        self.current_frame = 0
        self.total_frames = 1
        self.frames_done = 0
        self.current_sample = 0
        self.total_samples = 0
        self.tiles_done = 0
        self.total_tiles = 0
        self.status_message = "Initializing render..."
        self.is_rendering = False
        self.error_message = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert progress to dictionary for API responses"""
        return {
            'progress_percent': round(self.progress_percent, 2),
            'current_frame': self.current_frame,
            'total_frames': self.total_frames,
            'frames_done': self.frames_done,
            'current_sample': self.current_sample,
            'total_samples': self.total_samples,
            'tiles_done': self.tiles_done,
            'total_tiles': self.total_tiles,
            'status_message': self.status_message,
            'is_rendering': self.is_rendering,
            'error_message': self.error_message,
        }


class RenderExecutor:
    """Blender render executor with progress tracking"""

    def __init__(self, blend_file_path: str, output_dir: str,
                 render_params: Dict[str, Any],
                 blender_version: str = "4.0"):
        """
        Initialize render executor

        Args:
            blend_file_path: Path to .blend file
            output_dir: Directory for render outputs
            render_params: Render parameters from job
            blender_version: Blender version (for future version-specific handling)
        """
        self.blend_file = Path(blend_file_path)
        self.output_dir = Path(output_dir)
        self.render_params = render_params
        self.blender_version = blender_version

        # Progress tracking
        self.progress = RenderProgress()

        # Blender process (exposed for interruption)
        self.blender_process = None

        # Blender executable path
        self.blender_path = os.getenv('BLENDER_PATH', '/usr/local/blender/blender')

        # Validate inputs
        if not self.blend_file.exists():
            raise FileNotFoundError(f"Blend file not found: {self.blend_file}")

        # Create output directory
        self.output_dir.mkdir(parents=True, exist_ok=True)

    def execute_render(self, progress_callback: Optional[Callable[[RenderProgress], None]] = None) -> bool:
        """
        Execute Blender render with real-time progress tracking

        Args:
            progress_callback: Optional callback function called on progress updates

        Returns:
            True if render successful, False otherwise
        """
        try:
            # Parse render parameters
            engine = self.render_params.get("engine", "CYCLES")
            cycles_device = self.render_params.get("cycles_device", "OPTIX")
            is_animation_render = self.render_params.get("is_animation_render", False)
            is_image_sequence = self.render_params.get("is_image_sequence", False)
            is_video_output = self.render_params.get("is_video_output", False)
            frame_start = self.render_params.get("frame_start", 1)
            frame_end = self.render_params.get("frame_end", 1)
            current_frame = self.render_params.get("current_frame", 1)

            print("\n" + "="*60)
            print("🎨 BLENDER RENDER CONFIGURATION")
            print("="*60)
            print(f"Engine: {engine}")
            if engine == 'CYCLES':
                print(f"Cycles Device: {cycles_device or 'Default'}")
            print(f"Animation Render: {is_animation_render}")
            print(f"Image Sequence: {is_image_sequence}")
            print(f"Video Output: {is_video_output}")

            if is_animation_render:
                print(f"Frame Range: {frame_start} to {frame_end}")
                self.progress.total_frames = frame_end - frame_start + 1
            else:
                print(f"Single Frame: {current_frame}")
                self.progress.total_frames = 1

            print("="*60 + "\n")

            # Build output path
            if is_video_output:
                output_path = self.output_dir / "render_output"  # No extension
            else:
                output_path = self.output_dir / "frame_####"  # Frame padding

            # Build Blender command
            command = self._build_blender_command(
                engine=engine,
                cycles_device=cycles_device,
                output_path=str(output_path),
                is_animation_render=is_animation_render,
                frame_start=frame_start,
                frame_end=frame_end,
                current_frame=current_frame
            )

            print("🚀 Starting Blender render process...")
            print(f"   Command: {' '.join(command)}\n")

            self.progress.is_rendering = True
            self.progress.status_message = "Starting render..."

            if progress_callback:
                progress_callback(self.progress)

            # Execute Blender
            success = self._execute_blender_process(
                command=command,
                is_animation_render=is_animation_render,
                frame_start=frame_start,
                frame_end=frame_end,
                current_frame=current_frame,
                progress_callback=progress_callback
            )

            self.progress.is_rendering = False

            if success:
                self.progress.progress_percent = 100.0
                self.progress.status_message = "Render completed successfully"
                print("\n✅ Render completed successfully\n")
            else:
                self.progress.status_message = "Render failed"
                print("\n❌ Render failed\n")

            if progress_callback:
                progress_callback(self.progress)

            return success

        except Exception as e:
            print(f"❌ Render execution error: {e}")
            self.progress.is_rendering = False
            self.progress.error_message = str(e)
            self.progress.status_message = f"Error: {e}"

            if progress_callback:
                progress_callback(self.progress)

            return False

    def _build_blender_command(self, engine: str, cycles_device: Optional[str],
                               output_path: str, is_animation_render: bool,
                               frame_start: int, frame_end: int,
                               current_frame: int) -> List[str]:
        """
        Builds the Blender command line. 
        Note: Environment variables (EGL_PLATFORM, etc.) must be set 
        at the OS level before this process starts.
        """
        
        # 1. Start with the base binary
        command = [self.blender_path]

        # 2. Add Background mode and File path (Must be early)
        command.extend(["-b", str(self.blend_file)])

        # 3. Set the Engine
        # It is critical to set this BEFORE running scripts so that 
        # EEVEE_NEXT vs CYCLES logic in your scripts can detect the engine.
        command.extend(["--engine", engine])

        # 4. Attach Configuration Scripts
        # Order matters: Hardware config should run first to initialize the GPU list
        script_paths = [
            "/app/src/hardware_config.py",
            "/app/src/gpu_monitor.py",
            "/app/src/enable_persistent_data.py",
            # Frame start/done events for progress; see _parse_progress_line
            "/app/src/progress_reporter.py",
        ]

        for script in script_paths:
            p = Path(script)
            if p.exists():
                command.extend(["-P", str(p)])
            else:
                print(f"⚠️ Warning: Script not found: {script}")

        # 5. Output Configuration
        command.extend(["--render-output", output_path])

        # 6. Frame Logic 
        # Using short-codes (-s, -e, -a, -f) is more robust across Blender versions
        if is_animation_render:
            command.extend([
                "-s", str(frame_start),
                "-e", str(frame_end),
                "-a"
            ])
        else:
            command.extend(["-f", str(current_frame)])

        # 7. Cycles Specific Tail Arguments
        # Note: These are passed to the python scripts via sys.argv after the '--'
        if engine == 'CYCLES' and cycles_device:
            command.append("--")
            command.append(cycles_device)

        return command

    def _execute_blender_process(self, command: List[str], is_animation_render: bool,
                                 frame_start: int, frame_end: int, current_frame: int,
                                 progress_callback: Optional[Callable[[RenderProgress], None]]) -> bool:
        """Execute Blender subprocess and parse output for progress"""

        try:
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                universal_newlines=True
            )

            # Store process for external interruption
            self.blender_process = process

            total_frames = self.progress.total_frames
            log_buffer = []  # Keep last few lines for error reporting

            # Parse Blender output line by line
            for line in iter(process.stdout.readline, ''):
                if not line:
                    break

                line = line.strip()
                if line:
                    print(f"Blender: {line}")
                    
                    # Maintain log buffer (last 50 lines)
                    log_buffer.append(line)
                    if len(log_buffer) > 50:
                        log_buffer.pop(0)

                # Parse progress from Blender output
                changed = self._parse_progress_line(
                    line=line,
                    is_animation_render=is_animation_render,
                    frame_start=frame_start,
                    frame_end=frame_end,
                    current_frame=current_frame,
                    total_frames=total_frames
                )

                # Publish every change, including the first frame starting at 0%
                if progress_callback and changed:
                    progress_callback(self.progress)

            process.wait()

            if process.returncode != 0:
                print(f"❌ Blender exited with code {process.returncode}")
                
                # Check for crash log
                crash_log_content = ""
                crash_log = Path("/tmp/scene.crash.txt")
                if crash_log.exists():
                    print(f"\n🚨 BLENDER CRASH LOG ({crash_log}):")
                    print("="*40)
                    try:
                        crash_content = crash_log.read_text()
                        print(crash_content)
                        crash_log_content = f"\n\nCRASH LOG:\n{crash_content}"
                    except Exception as exc:
                        print(f"Could not read crash log: {exc}")
                    print("="*40 + "\n")

                # If we haven't caught a specific error yet, use the log tail
                if not self.progress.error_message:
                    log_tail = "\n".join(log_buffer)
                    self.progress.error_message = f"Blender exited with code {process.returncode}:\nLast logs:\n{log_tail}{crash_log_content}"
                    self.progress.status_message = f"Failed (Exit {process.returncode})"

            return process.returncode == 0

        except Exception as e:
            print(f"❌ Blender process error: {e}")
            self.progress.error_message = str(e)
            return False

    # Per-frame sample counters. Cycles prints "Sample 8/128" and EEVEE prints
    # "Rendering 25 / 64 samples"; both tolerate the spacing changes Blender 5
    # made to its log lines.
    _SAMPLE_PATTERNS = (
        re.compile(r'Sample\s+(\d+)\s*/\s*(\d+)'),
        re.compile(r'Rendering\s+(\d+)\s*/\s*(\d+)\s+samples'),
    )
    _EVENT_MARKER = "BANANAFARM_PROGRESS "

    def _parse_progress_line(self, line: str, is_animation_render: bool,
                            frame_start: int, frame_end: int,
                            current_frame: int, total_frames: int) -> bool:
        """Update progress from one line of Blender output.

        Frames come from progress_reporter.py's structured events, which fire
        for every engine and output type. Samples only refine progress within
        the current frame. Returns True when the progress changed.
        """
        progress = self.progress
        total = max(total_frames, 1)

        marker_at = line.find(self._EVENT_MARKER)
        if marker_at != -1:
            try:
                event = json.loads(line[marker_at + len(self._EVENT_MARKER):])
            except ValueError:
                return False

            kind = event.get("event")
            frame = event.get("frame", progress.current_frame)
            if kind == "frame_start":
                progress.current_frame = frame
                progress.current_sample = 0
                progress.total_samples = 0
            elif kind == "frame_done":
                progress.frames_done = min(progress.frames_done + 1, total)
                progress.current_sample = 0
            else:
                return False

            self._update_percent(total)
            index = min(progress.frames_done + (1 if kind == "frame_start" else 0), total)
            counter = f" ({index}/{total})" if total > 1 else ""
            verb = "Rendering" if kind == "frame_start" else "Finished"
            progress.status_message = f"{verb} frame {frame}{counter}"
            return True

        for pattern in self._SAMPLE_PATTERNS:
            match = pattern.search(line)
            if not match:
                continue
            current_sample, total_samples = int(match.group(1)), int(match.group(2))
            if total_samples <= 0:
                return False
            progress.current_sample = min(current_sample, total_samples)
            progress.total_samples = total_samples
            self._update_percent(total)
            frame_label = progress.current_frame or current_frame
            index = min(progress.frames_done + 1, total)
            prefix = f"Rendering frame {frame_label} ({index}/{total})" if total > 1 else f"Rendering frame {frame_label}"
            progress.status_message = f"{prefix} - Sample {progress.current_sample}/{total_samples}"
            return True

        # Error detection
        if "Error:" in line or "ERROR" in line:
            progress.error_message = line

        return False

    def _update_percent(self, total_frames: int):
        """One formula for every output: whole frames plus the current frame's
        sample fraction. Held below 100 until execute_render reports success."""
        progress = self.progress
        fraction = 0.0
        if progress.total_samples > 0 and progress.frames_done < total_frames:
            fraction = progress.current_sample / progress.total_samples
        percent = (progress.frames_done + fraction) / total_frames * 100.0
        progress.progress_percent = min(percent, 99.9)

    def get_output_files(self) -> List[str]:
        """
        Get list of output files generated by render

        Returns:
            List of output file paths
        """
        try:
            output_files = []

            for file_path in self.output_dir.rglob("*"):
                if file_path.is_file():
                    output_files.append(str(file_path))

            print(f"📁 Found {len(output_files)} output file(s)")
            for f in output_files:
                print(f"   - {Path(f).name}")

            return output_files

        except Exception as e:
            print(f"❌ Error collecting output files: {e}")
            return []

    def get_progress(self) -> RenderProgress:
        """Get current render progress"""
        return self.progress


if __name__ == "__main__":
    # Test render executor
    print("🧪 Testing Render Executor...")

    # Example usage
    render_params = {
        "engine": "CYCLES",
        "cycles_device": "GPU",
        "is_animation_render": False,
        "is_image_sequence": False,
        "is_video_output": False,
        "current_frame": 1,
    }

    def progress_callback(progress: RenderProgress):
        """Example progress callback"""
        print(f"Progress: {progress.progress_percent:.1f}% - {progress.status_message}")

    # This would fail without actual .blend file
    # executor = RenderExecutor(
    #     blend_file_path="/path/to/file.blend",
    #     output_dir="/tmp/render_output",
    #     render_params=render_params
    # )
    # success = executor.execute_render(progress_callback=progress_callback)

    print("✅ Render Executor module loaded")
