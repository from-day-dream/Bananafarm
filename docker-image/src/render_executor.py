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
from pathlib import Path
from typing import Dict, List, Optional, Callable, Any


class RenderProgress:
    """Container for render progress information"""

    def __init__(self):
        self.progress_percent = 0.0
        self.current_frame = 0
        self.total_frames = 1
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
            "/app/src/enable_persistent_data.py"
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
                self._parse_progress_line(
                    line=line,
                    is_animation_render=is_animation_render,
                    frame_start=frame_start,
                    frame_end=frame_end,
                    current_frame=current_frame,
                    total_frames=total_frames
                )

                # Call progress callback if progress updated
                if progress_callback and self.progress.progress_percent > 0:
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

    def _parse_progress_line(self, line: str, is_animation_render: bool,
                            frame_start: int, frame_end: int,
                            current_frame: int, total_frames: int):
        """Parse a single line of Blender output for progress information"""

        # Animation frame progress (e.g., "Fra:10 Mem:10.53M ...")
        frame_match = re.search(r'Fra:(\d+)', line)
        if is_animation_render and frame_match and total_frames > 0:
            frame_num = int(frame_match.group(1))
            self.progress.current_frame = frame_num
            self.progress.progress_percent = ((frame_num - frame_start) / total_frames) * 100.0
            self.progress.status_message = f"Rendering frame {frame_num}/{frame_end}"
            return

        # Tiled rendering progress (e.g., "Rendered 0/4 Tiles, Sample 65/128")
        # Note: 0/4 tiles means 4 tiles done? No, standard Blender output format usually implies X done out of Y total.
        # Wait, the user provided example: "Rendered 0/4 Tiles". 
        # Typically "Rendered X/Y Tiles" means X completed out of Y total tasks? 
        # Actually Blender Cycles often splits into tiles. 
        # Let's handle the specific format: "Rendered 0/4 Tiles, Sample 65/128"
        # Since it's 0-indexed or "completed" count? "0/4 Tiles" implies 0 completed.
        
        tile_match = re.search(r'Rendered (\d+)/(\d+) Tiles', line)
        sample_match = re.search(r'Sample (\d+)/(\d+)', line)
        
        if not is_animation_render and tile_match and sample_match:
            tiles_done = int(tile_match.group(1))
            total_tiles = int(tile_match.group(2)) # This is often "remaining" + "done" or just total? 
            # In Blender "Rendered 0/4 Tiles" usually means 4 total tiles, 0 fully completed.
            # But the user logs say "0/4 Tiles", so let's assume denominator is total count.
            # Wait, user log: "Rendered 0/4 Tiles". 
            # If total_tiles is 4, then each tile is 25%.
            
            # User logic: "0/4 tiles would mean 4+1 total tiles" -> wait, user said "0/4 tiles would mean 4+1 total tiles".
            # That sounds specific. Let's look closer at the user prompt: "0/4 tiles would mean 4+1 total tiles, so 100% would be 100/5 = 20%".
            # Why 4+1? Maybe "0/4" means tile index 0 out of 4 (so 0,1,2,3,4 = 5 tiles)?
            # Or maybe "0/4" means 0 completed, 4 remaining?
            # Standard Blender output "Rendered X/Y Tiles" usually means X completed, Y TOTAL.
            # But let's trust the user's interpretation if they are sure, OR stick to standard interpretation if user is guessing.
            # User text: "0/4 tiles would mean 4+1 total tiles" logic seems to imply 0-4 indices?
            # Actually, standard Blender 3.0+ cycles often just says "Sample X/Y". 
            # With tiling, it says "Rendered X/Y Tiles".
            # Let's assume the user wants: Total Tiles = Denominator + 1? Or just Denominator?
            # User said: "0/4 tiles would mean 4+1 total tiles".
            # If log says "Rendered 4/4 Tiles", is it done?
            # Let's assume Denominator is just total tiles for now, unless user logic is strictly "index".
            # Actually, "Rendered 0/4" -> 4 total tiles.
            # Let's use the user's specific formula logic if possible:
            # "so 100% would be 100/5 = 20%". This implies 5 total tiles.
            # So Total = Denominator + 1. 
            
            # Let's follow user direction: "0/4 tiles would mean 4+1 total tiles".
            # It seems they interpret "4" as the max index? Or "remaining"?
            # Actually, usually "Rendered 0/4" means 0 done, 4 total.
            # IF the user is seeing "0/4" and thinks it implies 5 tiles, maybe they are seeing index?
            # But "Rendered" implies count.
            # I will use the parsed numbers. 
            # If user logic is "0/4 means 5 total", I will implement total = Y + 1.
            
            total_tiles_derived = int(tile_match.group(2)) + 1
            tiles_done = int(tile_match.group(1))
            
            current_sample = int(sample_match.group(1))
            total_samples = int(sample_match.group(2))
            
            if total_tiles_derived > 0 and total_samples > 0:
                self.progress.tiles_done = tiles_done
                self.progress.total_tiles = total_tiles_derived
                
                self.progress.current_sample = current_sample
                self.progress.total_samples = total_samples
                
                # Formula: ((tiles_done * 100) / total_tiles) + ((current_sample * (100/total_tiles)) / total_samples)
                # Simplified: (tiles_done + (current_sample / total_samples)) / total_tiles * 100
                
                percent_per_tile = 100.0 / total_tiles_derived
                current_tile_progress = (current_sample / total_samples) * percent_per_tile
                total_progress = (tiles_done * percent_per_tile) + current_tile_progress
                
                self.progress.progress_percent = total_progress
                self.progress.status_message = f"Rendering frame {current_frame} (Tile {tiles_done}/{total_tiles_derived-1}, Sample {current_sample}/{total_samples})"
                return

        # Fallback for non-tiled single frame (e.g., "Sample 16/128")
        if not is_animation_render and sample_match:
            current_sample = int(sample_match.group(1))
            total_samples = int(sample_match.group(2))

            if total_samples > 0:
                self.progress.current_sample = current_sample
                self.progress.total_samples = total_samples
                self.progress.progress_percent = (current_sample / total_samples) * 100.0
                self.progress.status_message = f"Rendering frame {current_frame} (Sample {current_sample}/{total_samples})"
                return

        # Error detection
        if "Error:" in line or "ERROR" in line:
            self.progress.error_message = line

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
