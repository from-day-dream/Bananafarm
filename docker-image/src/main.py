#!/usr/bin/env python3
"""
Render Pod Main Entry Point
===========================
Standalone render container orchestrated entirely by the Bananafarm desktop app.
No Supabase, no Redis, no R2 — the app talks to this container's HTTP API directly.

Lifecycle:
1. Container starts and serves the FastAPI control API on port 8000.
2. The app uploads the project zip in chunks.
3. On upload completion a worker thread extracts, renders and archives outputs.
4. The container idles forever serving output files until the user destroys
   the instance from the app. It never self-deletes.

Environment Variables:
- JOB_ID          (required) job UUID, used in output archive naming
- API_TOKEN       (required) bearer token the app must present on every call
- RENDER_PARAMS   (required) JSON render parameters. May carry a legacy
                  lock_key for projects zipped before encryption was dropped.
- BLENDER_VERSION (optional) Blender release to use, default 5.2.2
- BLENDER_INSTALL_ERROR    (set by entrypoint.sh) why the Blender install
                  failed. Present means the job cannot render; the API still
                  starts so the app can read the reason instead of seeing a
                  container that boots and never answers.
- BLENDER_INSTALLED_VERSION (set by entrypoint.sh) the version read back
                  from the installed binary, which may differ from the one
                  requested
- PROVIDER        (optional) vast|runpod — selects the bind host. 'salad'
                  is still honoured (it binds IPv6) but the app no longer
                  offers Salad; the branch is kept for a future attempt
- BUILD_ID        (optional) baked in at image build, reported by /health so a
                  stale cached image is identifiable without guessing
"""
import json
import os
import sys
import threading

import uvicorn

from job_state import JobState, JobStateEnum


def main() -> None:
    print("\n" + "=" * 70)
    print("🚀 BANANAFARM RENDER POD")
    print("=" * 70 + "\n")

    job_id = os.getenv("JOB_ID")
    api_token = os.getenv("API_TOKEN")
    render_params_json = os.getenv("RENDER_PARAMS")
    blender_version = os.getenv("BLENDER_VERSION", "").strip() or "5.2.2"
    provider = os.getenv("PROVIDER", "").strip() or "vast"
    # Written by entrypoint.sh from `blender --version`, so it reflects what is
    # actually on disk rather than what was asked for.
    installed_version = os.getenv("BLENDER_INSTALLED_VERSION", "").strip()
    install_error = os.getenv("BLENDER_INSTALL_ERROR", "").strip()

    missing = [
        name
        for name, value in (
            ("JOB_ID", job_id),
            ("API_TOKEN", api_token),
            ("RENDER_PARAMS", render_params_json),
        )
        if not value
    ]
    if missing:
        print(f"❌ Missing required environment variables: {', '.join(missing)}")
        sys.exit(1)

    try:
        render_params = json.loads(render_params_json)
    except json.JSONDecodeError as e:
        print(f"❌ Invalid RENDER_PARAMS JSON: {e}")
        sys.exit(1)

    print(f"📋 Job ID: {job_id}")
    print(f"🏷️ Build: {os.getenv('BUILD_ID', 'unknown')}")
    print(f"🔧 Provider: {provider}")
    print(f"🎨 Blender Version: {blender_version} (requested)")
    if installed_version and installed_version != blender_version:
        print(f"   ⚠️ Installed: {installed_version}")
    elif installed_version:
        print(f"   Installed: {installed_version}")
    print("✅ Render parameters loaded:")
    print(json.dumps({k: v for k, v in render_params.items() if k != "lock_key"}, indent=2))
    print()

    job_state = JobState(
        job_id=job_id,
        api_token=api_token,
        render_params=render_params,
        blender_version=blender_version,
        provider=provider,
    )
    job_state.installed_blender_version = installed_version

    if install_error:
        # Deliberately not sys.exit(1): the app's only way to learn why a job
        # died is this API, so the container has to come up to say so. An
        # instance that exits here looks identical to one still booting, and
        # the app burns its whole 25-minute startup budget before giving up.
        print(f"❌ Blender unavailable: {install_error}")
        job_state.set_state(JobStateEnum.FAILED, install_error)
    else:
        job_state.set_state(JobStateEnum.WAITING_FOR_UPLOAD)

    # Import here so the module-level FastAPI app binds to this job state
    import api

    api.job_state = job_state

    host = "::" if provider == "salad" else "0.0.0.0"
    print(f"🌐 Control API listening on {host}:8000 — waiting for project upload\n")
    uvicorn.run(api.app, host=host, port=8000, log_level="info", access_log=False)


if __name__ == "__main__":
    main()
