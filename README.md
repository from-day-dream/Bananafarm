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
but it is not shippable: `flutter_app/assets/bin/lin/` has no `7zz` binary, so
project extraction fails. Treat Linux as unsupported for now.

## Getting started

The full walkthrough is the site's `/docs` page
([source](website/src/pages/Docs.tsx)). The short version:

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

| Path | What it is |
| --- | --- |
| [`flutter_app/`](flutter_app/) | The desktop app (Flutter). Also ships the add-on as a bundled asset |
| [`flutter_app/assets/addon/bananafarm.py`](flutter_app/assets/addon/bananafarm.py) | The Blender add-on, a single file |
| [`website/`](website/) | Marketing site and docs (React + Vite + Tailwind v4) |
| [`docker-image/`](docker-image/) | Source for the render container image |
| [`PROVIDER_API_REFERENCE.md`](PROVIDER_API_REFERENCE.md) | Archived notes on the three provider REST APIs. Documentation, not a spec — the implementation in `lib/services/providers/` is authoritative |

## Building from source

### Prerequisites

| Tool | Version |
| --- | --- |
| Flutter | ≥ 3.35 |
| Dart | ^3.9.2 |
| Node | ≥ 20.19 (Vite 7) |
| Blender | 4.0+ (to use the add-on) |
| Xcode + CocoaPods | for macOS builds |
| Visual Studio + Inno Setup 6 | for Windows builds |

### Desktop app

> [!IMPORTANT]
> **A fresh clone will not build yet.** `.gitignore` excludes `flutter_app/assets/*`
> and re-includes only `data/` and `addon/`, but `pubspec.yaml` declares eight
> asset directories. The icon, splash image, loading animation and the bundled
> 7-Zip binary are all missing from a clone and have to be restored first.

```bash
cd flutter_app

# 1. Create the declared asset directories. Flutter skips empty ones, so this
#    alone is enough to get a build; the steps below restore what they held.
mkdir -p assets/{icon,images,animations,bin/mac,bin/win,bin/lin}

# 2. Bundled 7-Zip, used to zip projects and unpack downloads (macOS)
brew install sevenzip
cp "$(brew --prefix sevenzip)/bin/7zz" assets/bin/mac/7zz
chmod +x assets/bin/mac/7zz

# 3. Icon and splash, regenerated from the images at the repo root.
#    Note Cover.jpg is an outdated screenshot — it still shows a removed tab
#    and the old credits UI — so this gets you building, not a correct splash.
sips -s format png ../logo.jpg  --out assets/icon/icon.png
sips -s format png ../Cover.jpg --out assets/images/splash_screen.png

# 4. Build
flutter pub get
flutter run -d macos
```

Two gaps this does not close. `assets/animations/loading.json` is a Lottie file
that exists in no form in the repo — the build succeeds without it, but the
splash screen's spinner will render an error box until a maintainer supplies it.
And `assets/bin/win/7za.exe` is required at runtime by
[`addon_provider.dart`](flutter_app/lib/providers/addon_provider.dart) and is
absent, so a Windows build cannot zip projects until you place a 7-Zip
executable there yourself.

`flutter test` runs the suite. Several tests are integration tests that skip
themselves unless fixture archives are present, so a plain run is safe and needs
no API keys.

`build_runner`, `riverpod_generator` and `riverpod_annotation` are declared in
`pubspec.yaml` but nothing uses them — there are no `.g.dart` files and no
codegen step to run.

### Website

```bash
cd website
cp .env.example .env     # EmailJS credentials for the contact form
npm install
npm run dev              # or: npm run build
```

The `VITE_*` values are **not secrets** — Vite inlines them into the client
bundle at build time. `.env.example` explains what actually protects them.

### Render image

```bash
cd docker-image
docker build --build-arg BUILD_ID=$(git rev-parse --short HEAD) \
  -t docker.io/<you>/bananafarm-render:<tag> .
docker push docker.io/<you>/bananafarm-render:<tag>
```

`BUILD_ID` is surfaced by `GET /health`. It exists because providers cache images
by tag, so a node can serve a stale build under the tag you asked for — the stamp
is what makes that visible.

The image the app currently rents is `docker.io/subinkx/bananafarm-render:2.0.0`,
set in [`app_constants.dart`](flutter_app/lib/constants/app_constants.dart).
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

- **[7-Zip](https://www.7-zip.org/)** — LGPL-2.1-or-later, bundled as a binary
  (`7zz`) and used to pack and unpack projects.
- **[Blender](https://www.blender.org/)** — GPL-2.0-or-later. Downloaded at
  container start, not redistributed here. The add-on uses Blender's `bpy` API.
- **[Urbanist](https://fonts.google.com/specimen/Urbanist)** and
  **[Manrope](https://fonts.google.com/specimen/Manrope)** — SIL Open Font License
  1.1, used by the website.

## License

[GPL-3.0-or-later](LICENSE).

Built by [day-dream](https://www.day-dream.studio).
