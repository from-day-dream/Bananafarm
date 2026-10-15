"""
Render pod control API.

All endpoints except GET /health require `Authorization: Bearer {API_TOKEN}`.
The desktop app is the only client: it uploads the project zip in chunks,
polls progress, downloads outputs, and can stop the render.
"""
import hashlib
import hmac
import os
import shutil
import threading
import uuid
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

from job_state import (
    INPUT_ZIP_PATH,
    OUTPUT_DIR,
    JobState,
    JobStateEnum,
    UploadSession,
)

# Assigned by main.py before the server starts
job_state: JobState = None

app = FastAPI(title="Bananafarm Render Pod API")

MAX_CHUNK_SIZE = 100 * 1024 * 1024  # hard cap per chunk request


def require_token(request: Request) -> None:
    auth = request.headers.get("authorization", "")
    expected = f"Bearer {job_state.api_token}"
    if not hmac.compare_digest(auth.encode(), expected.encode()):
        raise HTTPException(status_code=401, detail="Invalid or missing bearer token")


class UploadBeginRequest(BaseModel):
    filename: str
    total_size: int
    total_chunks: int
    chunk_size: int
    # Hex SHA-256 of the complete zip, verified after assembly.
    sha256: str


class UploadCompleteRequest(BaseModel):
    upload_id: str


@app.get("/health")
def health():
    """Unauthenticated readiness probe.

    Reports the image's build stamp too. Providers cache images by tag, so a
    node can quietly serve an older build under the tag it was asked for —
    which is otherwise only detectable by the stale error messages it emits.
    """
    return {"status": "ok", "build": os.getenv("BUILD_ID", "unknown")}


@app.get("/status", dependencies=[Depends(require_token)])
def get_status():
    return {
        "job_id": job_state.job_id,
        "state": job_state.state.value,
        "error_message": job_state.error_message,
        "outputs_ready": job_state.outputs_ready,
        # Requested vs. actually installed. The app displays the requested one
        # on the job screen; when these differ, that display is misleading.
        "blender_version": job_state.blender_version,
        "installed_blender_version": job_state.installed_blender_version,
    }


@app.get("/progress", dependencies=[Depends(require_token)])
def get_progress():
    return JSONResponse(content={
        "state": job_state.state.value,
        "progress": job_state.render_progress.to_dict(),
    })


# ============================================
# Project upload (chunked)
# ============================================

@app.post("/upload-project/begin", dependencies=[Depends(require_token)])
def upload_begin(body: UploadBeginRequest):
    with job_state.lock:
        if job_state.state not in (JobStateEnum.WAITING_FOR_UPLOAD, JobStateEnum.RECEIVING_UPLOAD):
            raise HTTPException(
                status_code=409,
                detail=f"Cannot start upload in state '{job_state.state.value}'",
            )
        if body.total_chunks < 1 or body.total_size < 1 or body.chunk_size < 1:
            raise HTTPException(
                status_code=400,
                detail="total_size, total_chunks and chunk_size must be positive",
            )
        # The client derives total_chunks from chunk_size; a disagreement means
        # the two sides would slice the file differently.
        expected_chunks = -(-body.total_size // body.chunk_size)
        if body.total_chunks != expected_chunks:
            raise HTTPException(
                status_code=400,
                detail=f"total_chunks {body.total_chunks} inconsistent with "
                       f"total_size/chunk_size (expected {expected_chunks})",
            )

        # A fresh begin resets any previous (possibly stale) session
        if job_state.upload_session is not None:
            shutil.rmtree(job_state.upload_session.chunk_dir, ignore_errors=True)

        session = UploadSession(
            upload_id=uuid.uuid4().hex,
            filename=body.filename,
            total_size=body.total_size,
            total_chunks=body.total_chunks,
            chunk_size=body.chunk_size,
            sha256=body.sha256.lower(),
        )
        session.chunk_dir.mkdir(parents=True, exist_ok=True)
        job_state.upload_session = session
        job_state.state = JobStateEnum.RECEIVING_UPLOAD

    print(f"📥 Upload started: {body.filename} ({body.total_size} bytes, {body.total_chunks} chunks)")
    return {"upload_id": session.upload_id}


@app.put("/upload-project/chunk/{upload_id}/{index}", dependencies=[Depends(require_token)])
async def upload_chunk(upload_id: str, index: int, request: Request):
    session = job_state.upload_session
    if session is None or session.upload_id != upload_id:
        raise HTTPException(status_code=404, detail="Unknown upload_id")
    if index < 0 or index >= session.total_chunks:
        raise HTTPException(status_code=400, detail="Chunk index out of range")

    data = await request.body()
    if len(data) > MAX_CHUNK_SIZE:
        raise HTTPException(status_code=413, detail="Chunk too large")

    # A short body means the transfer was cut off (or a proxy truncated it).
    # Rejecting here keeps a partial chunk from being recorded as received and
    # skipped by the next resume.
    expected = session.expected_chunk_length(index)
    if len(data) != expected:
        raise HTTPException(
            status_code=400,
            detail=f"Chunk {index} length {len(data)} != expected {expected}",
        )

    declared = request.headers.get("x-chunk-sha256")
    if declared:
        actual = hashlib.sha256(data).hexdigest()
        if not hmac.compare_digest(actual, declared.lower()):
            raise HTTPException(
                status_code=400,
                detail=f"Chunk {index} checksum mismatch (corrupt transfer)",
            )

    # Write off the event loop — a blocking 50MB write here would stall every
    # other in-flight chunk PUT and the progress polls. Write-then-rename so a
    # torn write can never be observed as a complete chunk.
    chunk_path = session.chunk_dir / f"{index:06d}.part"
    await run_in_threadpool(_write_chunk_atomic, chunk_path, data)
    with job_state.lock:
        session.received_chunks.add(index)

    return {"received": sorted(session.received_chunks)}


def _write_chunk_atomic(chunk_path: Path, data: bytes) -> None:
    tmp_path = chunk_path.with_suffix(".tmp")
    tmp_path.write_bytes(data)
    os.replace(tmp_path, chunk_path)


@app.get("/upload-project/status", dependencies=[Depends(require_token)])
def upload_status():
    session = job_state.upload_session
    if session is None:
        return {
            "upload_id": None,
            "received_chunks": [],
            "total_chunks": None,
            "total_size": None,
            "chunk_size": None,
        }
    return {
        "upload_id": session.upload_id,
        "received_chunks": sorted(session.received_chunks),
        "total_chunks": session.total_chunks,
        "total_size": session.total_size,
        "chunk_size": session.chunk_size,
    }


@app.post("/upload-project/complete", dependencies=[Depends(require_token)])
def upload_complete(body: UploadCompleteRequest):
    """Kick off assembly and return immediately.

    Assembly of a multi-GB zip takes far longer than any sane HTTP timeout
    (and longer than the ~100s origin timeout of RunPod's proxy), so it runs on
    a background thread and the client polls GET /status. Returning inline used
    to let a timed-out client retry into a *second* concurrent assembly, which
    truncated the half-written zip and produced a right-sized file with a hole
    in it — surfacing later as a bogus "wrong key? corrupted?" extract failure.
    """
    with job_state.lock:
        session = job_state.upload_session
        if session is None or session.upload_id != body.upload_id:
            raise HTTPException(status_code=404, detail="Unknown upload_id")

        # Idempotent: a retry that lands while assembly is already underway (or
        # already finished) must never start a second assembler.
        if session.assembling or job_state.state in (
            JobStateEnum.ASSEMBLING,
            JobStateEnum.EXTRACTING,
        ):
            return {"status": "already_started"}

        if job_state.state != JobStateEnum.RECEIVING_UPLOAD:
            raise HTTPException(
                status_code=409,
                detail=f"Cannot complete upload in state '{job_state.state.value}'",
            )
        missing = [i for i in range(session.total_chunks) if i not in session.received_chunks]
        if missing:
            raise HTTPException(status_code=400, detail=f"Missing chunks: {missing[:20]}")

        session.assembling = True
        job_state.state = JobStateEnum.ASSEMBLING

    print("🧩 Assembling uploaded chunks...")
    threading.Thread(target=_assemble_and_start, args=(session,), daemon=True).start()
    return JSONResponse(status_code=202, content={"status": "assembling"})


def _assemble_and_start(session: UploadSession) -> None:
    """Concatenate chunks, verify integrity, then hand off to the pipeline."""
    import job_pipeline

    try:
        digest = hashlib.sha256()
        with open(INPUT_ZIP_PATH, "wb") as out:
            for i in range(session.total_chunks):
                chunk_path = session.chunk_dir / f"{i:06d}.part"
                with open(chunk_path, "rb") as part:
                    while True:
                        buf = part.read(1024 * 1024)
                        if not buf:
                            break
                        digest.update(buf)
                        out.write(buf)
        shutil.rmtree(session.chunk_dir, ignore_errors=True)

        actual_size = INPUT_ZIP_PATH.stat().st_size
        if actual_size != session.total_size:
            _reset_for_reupload(
                f"Upload size mismatch: expected {session.total_size} bytes, "
                f"got {actual_size}"
            )
            return

        actual_sha = digest.hexdigest()
        if session.sha256 and not hmac.compare_digest(actual_sha, session.sha256):
            _reset_for_reupload(
                "Uploaded project failed its checksum — the transfer was "
                f"corrupted (expected {session.sha256[:16]}…, got {actual_sha[:16]}…)"
            )
            return
    except Exception as e:
        _reset_for_reupload(f"Failed to assemble uploaded chunks: {e}")
        return

    print(f"✅ Project received: {INPUT_ZIP_PATH} ({actual_size} bytes, sha256 ok)")
    job_state.set_state(JobStateEnum.EXTRACTING)
    job_state.pipeline_thread = job_pipeline.start_pipeline(job_state)


def _reset_for_reupload(message: str) -> None:
    """Drop the bad upload and let the client start over from /begin."""
    print(f"❌ {message}")
    session = job_state.upload_session
    if session is not None:
        shutil.rmtree(session.chunk_dir, ignore_errors=True)
    job_state.upload_session = None
    INPUT_ZIP_PATH.unlink(missing_ok=True)
    job_state.set_state(JobStateEnum.WAITING_FOR_UPLOAD, message)


# ============================================
# Outputs
# ============================================

def _list_output_files():
    files = []
    if OUTPUT_DIR.exists():
        for path in sorted(OUTPUT_DIR.rglob("*")):
            if path.is_file():
                files.append({"name": path.name, "size": path.stat().st_size})
    return files


@app.get("/outputs", dependencies=[Depends(require_token)])
def list_outputs():
    archive = None
    if job_state.output_archive:
        archive = {
            "name": job_state.output_archive["name"],
            "size": job_state.output_archive["size"],
            "sha256": job_state.output_archive.get("sha256"),
        }
    return {
        "state": job_state.state.value,
        "files": job_state.output_files or _list_output_files(),
        "archive": archive,
    }


@app.get("/outputs/{filename}", dependencies=[Depends(require_token)])
def download_output(filename: str):
    # The archive lives in /tmp, frames/videos in /tmp/render_output
    if job_state.output_archive and filename == job_state.output_archive["name"]:
        archive_path = Path(job_state.output_archive["path"])
        if archive_path.is_file():
            return FileResponse(path=str(archive_path), filename=filename)
        raise HTTPException(status_code=404, detail="Archive not found")

    output_root = OUTPUT_DIR.resolve()
    resolved = (OUTPUT_DIR / filename).resolve()
    if resolved.parent != output_root:
        raise HTTPException(status_code=400, detail="Invalid filename")
    if not resolved.is_file():
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(path=str(resolved), filename=filename)


# ============================================
# Control
# ============================================

@app.post("/control/stop", dependencies=[Depends(require_token)])
def control_stop():
    import job_pipeline

    with job_state.lock:
        if job_state.is_terminal:
            return {"status": "already_finished", "state": job_state.state.value}
        job_state.stop_requested = True

    if job_state.state == JobStateEnum.RENDERING:
        job_pipeline.terminate_blender(job_state)
        return {"status": "stopping"}

    # Not rendering yet — nothing to salvage
    job_state.set_state(JobStateEnum.FAILED, "Stopped by user before rendering started")
    return {"status": "stopped", "state": job_state.state.value}
