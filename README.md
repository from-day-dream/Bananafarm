<div align="center">

<img src="logo.jpg" alt="" width="88" height="88">

# Bananafarm

**Render Blender scenes on cloud GPUs you rent yourself.**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Windows-lightgrey)
![Blender](https://img.shields.io/badge/Blender-4.0%2B-orange)

</div>

---

Bananafarm is a desktop app and a Blender add-on. You submit a render from inside
Blender, the app rents a GPU from [Vast.ai](https://vast.ai) or
[RunPod](https://runpod.io) using your own API key, and the finished frames come
back to your machine.

There is no account, no subscription and no Bananafarm server. The app talks
directly to the provider you chose, and you pay them directly at their rates —
nothing sits in the middle taking a cut.

## How it works

```
   Blender                Your machine                      Rented GPU
┌────────────┐         ┌────────────────┐               ┌────────────────┐
│  add-on    │  POST   │  desktop app   │   rent via    │   container    │
│  N-panel   ├────────►│                ├──────────────►│  FastAPI :8000 │
│            │ :47288  │  packs · zips  │  provider API │    + Blender   │
│            │         │  orchestrates  │               │                │
└────────────┘         └───────┬────────┘               └───────┬────────┘
                               │                                │
                               │   upload .zip (chunked)        │
                               ├───────────────────────────────►│
                               │   poll /progress               │
                               │◄───────────────────────────────┤
                               │   GET /outputs/{frame}         │
                               │◄───────────────────────────────┘
                               ▼
                         frames on disk
```

The desktop app is the only orchestrator. Nothing runs on a server anyone else
owns, no job metadata leaves your machine except to the provider you picked, and
your API keys are never given to the rented container — it gets a random
per-job bearer token instead.

| Component | Role |
| --- | --- |
| **Blender add-on** | Packs the scene and every external dependency, then POSTs the job to the app on `localhost:47288` |
| **Desktop app** | Zips the project, rents the GPU, uploads, tracks progress, downloads frames, destroys the instance |
| **Render container** | FastAPI control API on port `8000` alongside Blender; one job per container |

## Platforms

**macOS** and **Windows**.

A `linux/` target is scaffolded — DEB and AppImage scripts, a `.desktop` file —
but it is not shippable: no Linux 7-Zip binary is bundled, so project extraction
fails. Linux is unsupported.

## Getting started

The full walkthrough is the `/docs` page on the Bananafarm website. The short version:

1. Install the app, open the **Home** tab and click **Configure Addon**. Pick your
   Blender version — the newest installed one is already selected — and click
   **Install Add-on**.
2. In Blender, open **Preferences → Add-ons**, find Bananafarm and tick it.
   Installing copies the file; this is what switches it on.
3. In the app's **Settings → API Keys**, paste a key from Vast.ai or RunPod.
   Keys are stored locally and sent only to that provider.
4. In Blender, save your file, press <kbd>N</kbd>, open the **BananaFarm** tab and
   click **Submit Still** or **Submit Animation**. External files — textures,
   caches, image sequences, linked `.blend`s — are packed automatically.
5. In the app, open the job, click **Select GPU**, pick one from the live list and
   click **Submit Job**.
6. When it finishes, download the output, then click **Delete Instance**.

> [!WARNING]
> **The rented machine keeps billing until you delete it.** Finishing a render
> does not stop the clock, and a *failed* render does not either — the instance
> is left running on purpose so a slow download never costs you the results.
> Nothing is destroyed automatically except an instance that never becomes
> reachable within 25 minutes, or an upload still unfinished after 6 hours.
> **Delete Instance** also erases the outputs held on that machine, so download
> first.

## Repository layout

```
Bananafarm/
├── flutter-app/              Desktop app (Flutter)
│   ├── lib/
│   │   ├── constants/        App-wide constants, incl. the render image tag
│   │   ├── models/           Jobs, GPU offers, providers, errors
│   │   ├── providers/        Riverpod state
│   │   ├── screens/          Dashboard, job submission/detail, settings
│   │   ├── services/         Job queue, local storage, add-on install, …
│   │   │   └── providers/    Vast.ai and RunPod API clients
│   │   ├── theme/ utils/ widgets/
│   │   └── main.dart
│   ├── assets/
│   │   ├── addon/            The Blender add-on (bananafarm.py)
│   │   ├── bin/              Bundled 7-Zip (mac/7zz, win/7za.exe)
│   │   ├── data/             GPU and model catalogs (JSON)
│   │   └── icon/ images/ animations/
│   ├── test/                 Unit and fixture-gated integration tests
│   ├── macos/ windows/ linux/  Platform runners and packaging
│   ├── scripts/              Icon, installer-image, DMG and Linux build scripts
│   └── docker/               Dockerfile for a Linux build environment
├── docker-image/             Render container image
│   ├── Dockerfile
│   ├── entrypoint.sh         Downloads the requested Blender, starts the API
│   ├── requirements.txt
│   └── src/                  FastAPI app, job pipeline, render executor
├── logo.jpg
└── LICENSE
```

| Path | What it is |
| --- | --- |
| [`flutter-app/`](flutter-app/) | The desktop app. Also ships the add-on as a bundled asset |
| [`flutter-app/assets/addon/bananafarm.py`](flutter-app/assets/addon/bananafarm.py) | The Blender add-on, a single file |
| [`flutter-app/lib/services/providers/`](flutter-app/lib/services/providers/) | GPU provider clients — the authoritative reference for how each provider API is called |
| [`flutter-app/windows/`](flutter-app/windows/) | Windows runner plus installer notes ([`BUILD_INSTALLER.md`](flutter-app/windows/BUILD_INSTALLER.md), [`BUILD_INSTALLER_MSIX.md`](flutter-app/windows/BUILD_INSTALLER_MSIX.md)) and the Inno Setup script |
| [`docker-image/`](docker-image/) | Source for the render container image |

## Building from source

### Prerequisites

| Tool | Version |
| --- | --- |
| Flutter | ≥ 3.35 |
| Dart | ^3.9.2 |
| Docker | to build the render image |
| Blender | 4.0+ (to use the add-on) |
| Xcode + CocoaPods | for macOS builds |
| Visual Studio + Inno Setup 6 | for Windows builds |

### Desktop app

Every asset the app needs is committed under `flutter-app/assets/`, including the
bundled 7-Zip binaries for macOS (`bin/mac/7zz`) and Windows (`bin/win/7za.exe`),
so a fresh clone builds as-is.

The bundled `7zz` is an arm64 build, so macOS packing works on Apple Silicon
only. Intel Macs need a universal or x86_64 `7zz` in its place.

```bash
cd flutter-app
flutter pub get
flutter run -d macos     # or: flutter run -d windows
```

#### macOS installer (DMG)

```bash
brew install create-dmg                 # once
./flutter-app/scripts/macos/build_dmg.sh  # add --clean for a clean build
```

This builds the release app and writes
`flutter-app/build/macos/dmg/BananaFarm-<version>-<arch>.dmg`, a
drag-to-Applications installer. The app keeps the signature Xcode gives it
during the build (Apple Development) and is not notarized. On other Macs it must
be opened with right-click → **Open** the first time.

`flutter test` runs the suite. Several tests are integration tests that skip
themselves unless fixture archives are present, so a plain run is safe and needs
no API keys.

`build_runner`, `riverpod_generator` and `riverpod_annotation` are declared in
`pubspec.yaml` but nothing uses them — there are no `.g.dart` files and no
codegen step to run.

### Render image

```bash
cd docker-image
docker build --platform linux/amd64 \
  --build-arg BUILD_ID=$(git rev-parse --short HEAD) \
  -t docker.io/<you>/bananafarm-render:<tag> .
docker push docker.io/<you>/bananafarm-render:<tag>
```

`--platform linux/amd64` is required when building on Apple Silicon. The CUDA base
image is amd64-only and every rented GPU host is x86-64, but Docker on an arm64
Mac would otherwise label the image arm64. Expect a slower build there, since the
`RUN` steps go through emulation.

`BUILD_ID` is surfaced by `GET /health`. It exists because providers cache images
by tag, so a node can serve a stale build under the tag you asked for — the stamp
is what makes that visible.

The image the app currently rents is `docker.io/subinkx/bananafarm-render:2.0.0`,
set in [`app_constants.dart`](flutter-app/lib/constants/app_constants.dart).
Change that constant to point at your own build.

## The render container

One container per job. It exposes a small HTTP API on port `8000`; every endpoint
except `/health` requires the job's bearer token.

| Endpoint | Purpose |
| --- | --- |
| `GET /health` | Readiness probe and build stamp (unauthenticated) |
| `GET /status`, `GET /progress` | Job state, frame and sample progress |
| `POST /upload-project/begin` · `PUT …/chunk/{id}/{n}` · `GET …/status` · `POST …/complete` | Chunked, resumable project upload with SHA-256 verification |
| `GET /outputs`, `GET /outputs/{name}` | List and download finished frames |
| `POST /control/stop` | Stop Blender, salvaging any frames already written |

Blender is **not** baked into the image — the entrypoint downloads the version the
add-on reported at container start, so one image serves every Blender release.

The container never self-terminates. When a job finishes it idles, holding the
outputs, until you delete the instance from the app.

## Contributing

Issues and pull requests are welcome. There is no CI and no contribution guide
yet, so please describe how you tested a change.

## Third-party components

- **[7-Zip](https://www.7-zip.org/)** — LGPL-2.1-or-later, bundled as binaries
  (`7zz` on macOS, `7za.exe` on Windows) and used to pack and unpack projects.
- **[Blender](https://www.blender.org/)** — GPL-2.0-or-later. Downloaded at
  container start, not redistributed here. The add-on uses Blender's `bpy` API.
- **[Urbanist](https://fonts.google.com/specimen/Urbanist)** and
  **[Manrope](https://fonts.google.com/specimen/Manrope)** — SIL Open Font License
  1.1, loaded by the desktop app through `google_fonts`.

## Credits

Made by [day-dream](https://www.day-dream.studio), led by
[Subin Krishna](http://instagram.com/5x00.art), in collaboration with
[Rabah Ahmed](https://github.com/Silvie3D).

## License

[GPL-3.0-or-later](LICENSE).
