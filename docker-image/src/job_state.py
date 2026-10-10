"""
Shared job state for the render pod.

Single job per container. State transitions:
waiting_for_upload -> receiving_upload -> assembling -> extracting -> rendering
    -> zipping_output -> completed | partially_completed | failed

A failed integrity check during `assembling` returns to `waiting_for_upload` so
the client can restart the upload from scratch.
"""
import threading
from enum import Enum
from pathlib import Path
from typing import Dict, List, Optional

from render_executor import RenderProgress

UPLOAD_CHUNK_DIR = Path("/tmp/upload_chunks")
INPUT_ZIP_PATH = Path("/tmp/input.zip")
OUTPUT_DIR = Path("/tmp/render_output")
ARCHIVE_DIR = Path("/tmp")


class JobStateEnum(str, Enum):
    WAITING_FOR_UPLOAD = "waiting_for_upload"
    RECEIVING_UPLOAD = "receiving_upload"
    ASSEMBLING = "assembling"
    EXTRACTING = "extracting"
    RENDERING = "rendering"
    ZIPPING_OUTPUT = "zipping_output"
    COMPLETED = "completed"
    PARTIALLY_COMPLETED = "partially_completed"
    FAILED = "failed"


TERMINAL_STATES = {
    JobStateEnum.COMPLETED,
    JobStateEnum.PARTIALLY_COMPLETED,
    JobStateEnum.FAILED,
}


class UploadSession:
    def __init__(self, upload_id: str, filename: str, total_size: int, total_chunks: int,
                 chunk_size: int, sha256: str):
        self.upload_id = upload_id
        self.filename = filename
        self.total_size = total_size
        self.total_chunks = total_chunks
        self.chunk_size = chunk_size
        # Hex SHA-256 of the whole zip, verified after assembly.
        self.sha256 = sha256
        self.received_chunks: set = set()
        self.chunk_dir = UPLOAD_CHUNK_DIR / upload_id
        # Guards against a second /upload-project/complete starting a parallel
        # assembly into the same output file.
        self.assembling = False

    def expected_chunk_length(self, index: int) -> int:
        """Byte length chunk `index` must have, given the client's chunking."""
        offset = index * self.chunk_size
        return min(self.chunk_size, self.total_size - offset)


class JobState:
    def __init__(self, job_id: str, api_token: str, render_params: dict,
                 blender_version: str, provider: str):
        self.job_id = job_id
        self.api_token = api_token
        self.render_params = render_params
        self.blender_version = blender_version
        # What entrypoint.sh read back from the installed binary. May differ
        # from blender_version (the request) — empty if nothing installed.
        self.installed_blender_version: str = ""
        self.provider = provider

        self.lock = threading.Lock()
        self.state = JobStateEnum.WAITING_FOR_UPLOAD
        self.error_message: Optional[str] = None
        self.render_progress = RenderProgress()

        self.upload_session: Optional[UploadSession] = None
        self.pipeline_thread: Optional[threading.Thread] = None

        self.blender_process = None
        self.stop_requested = False

        # Populated when outputs are ready: [{"name": str, "size": int}]
        self.output_files: List[Dict] = []
        # {"name": str, "size": int, "path": str} when a zip archive was produced
        self.output_archive: Optional[Dict] = None

    def set_state(self, state: JobStateEnum, error_message: Optional[str] = None) -> None:
        with self.lock:
            self.state = state
            if error_message is not None:
                self.error_message = error_message
        print(f"🔁 Job state -> {state.value}" + (f" ({error_message})" if error_message else ""))

    @property
    def is_terminal(self) -> bool:
        return self.state in TERMINAL_STATES

    @property
    def outputs_ready(self) -> bool:
        return self.state in (JobStateEnum.COMPLETED, JobStateEnum.PARTIALLY_COMPLETED)
