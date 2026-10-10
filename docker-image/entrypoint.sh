#!/bin/bash
set -e

# --- Blender Installation ---
#
# Two rules shape this script, both learned the expensive way:
#
#   1. Never destroy a working install before a replacement is in hand. The
#      GPU is already rented by the time this runs, so a failed upgrade that
#      also wipes the previous Blender turns a recoverable state into a dead
#      container.
#
#   2. Never exit non-zero. The control API is the only channel back to the
#      desktop app; if this script dies, the app sees an instance that boots
#      and never answers, which is indistinguishable from a slow start. It
#      then waits out its full 25-minute startup timeout on a billing GPU.
#      Instead we record why the install failed and let main.py report it.

# Default when the desktop app didn't supply one. Keep in step with
# `ENV BLENDER_VERSION` in the Dockerfile, `AppConstants.defaultBlenderVersion`
# in the Flutter app, and the default in src/main.py.
if [ -z "$BLENDER_VERSION" ]; then
  echo "⚠️ Warning: BLENDER_VERSION not set. Using default: 5.2.2"
  BLENDER_VERSION="5.2.2"
fi
export BLENDER_VERSION

BLENDER_INSTALL_PATH="/usr/local/blender"
BLENDER_STAGING_PATH="/usr/local/blender.incoming"
VERSION_FILE="${BLENDER_INSTALL_PATH}/.version"

# Set when the install fails. main.py reads it and fails the job with this
# message instead of the container simply vanishing.
BLENDER_INSTALL_ERROR=""

install_blender() {
  # Blender's release layout: /release/BlenderX.Y/blender-X.Y.Z-linux-x64.tar.xz
  # This URL is mirrored by AppConstants.blenderDownloadUrl in the Flutter app,
  # which HEADs it before renting a GPU. Changing the shape here without
  # changing it there re-opens the failure this script exists to survive.
  local series url archive
  series=$(echo "${BLENDER_VERSION}" | cut -d. -f1-2)
  url="https://download.blender.org/release/Blender${series}/blender-${BLENDER_VERSION}-linux-x64.tar.xz"
  archive="/tmp/blender-${BLENDER_VERSION}.tar.xz"

  echo "⬇️ Downloading Blender ${BLENDER_VERSION}"
  echo "   ${url}"

  if ! wget -q -O "${archive}" "${url}"; then
    rm -f "${archive}"
    BLENDER_INSTALL_ERROR="Blender ${BLENDER_VERSION} could not be downloaded. \
It is most likely not a published release — development and daily builds are \
not on download.blender.org. Save your file from a released Blender version \
and submit again."
    return 1
  fi

  # Unpack into staging. Only once this succeeds does the live install move.
  rm -rf "${BLENDER_STAGING_PATH}"
  mkdir -p "${BLENDER_STAGING_PATH}"
  if ! tar -xJf "${archive}" -C "${BLENDER_STAGING_PATH}" --strip-components=1; then
    rm -f "${archive}"
    rm -rf "${BLENDER_STAGING_PATH}"
    BLENDER_INSTALL_ERROR="The Blender ${BLENDER_VERSION} archive downloaded \
but could not be extracted; it may have been truncated in transit."
    return 1
  fi
  rm -f "${archive}"

  if [ ! -x "${BLENDER_STAGING_PATH}/blender" ]; then
    rm -rf "${BLENDER_STAGING_PATH}"
    BLENDER_INSTALL_ERROR="The Blender ${BLENDER_VERSION} archive did not \
contain a blender executable where one was expected."
    return 1
  fi

  # Swap in. The old install stays intact until this point.
  rm -rf "${BLENDER_INSTALL_PATH}"
  mv "${BLENDER_STAGING_PATH}" "${BLENDER_INSTALL_PATH}"

  # Record what actually installed, read from the binary rather than echoing
  # back what was requested. A self-asserting marker cannot detect the case
  # where the archive contents differ from the version in its filename.
  local installed
  installed=$("${BLENDER_INSTALL_PATH}/blender" --version 2>/dev/null \
    | head -n 1 | awk '{print $2}')
  if [ -z "${installed}" ]; then
    installed="${BLENDER_VERSION}"
    echo "⚠️ Could not read the version back from the binary; recording the requested one."
  fi
  echo "${installed}" > "${VERSION_FILE}"

  if [ "${installed}" != "${BLENDER_VERSION}" ]; then
    echo "⚠️ Requested Blender ${BLENDER_VERSION} but installed ${installed}."
  fi
  echo "✅ Blender ${installed} installed."
  return 0
}

if [ -f "$VERSION_FILE" ] && [ "$(cat "$VERSION_FILE")" = "$BLENDER_VERSION" ]; then
  echo "✅ Blender ${BLENDER_VERSION} is already installed. Skipping."
else
  echo "⏳ Blender ${BLENDER_VERSION} not present. Installing..."
  # `install_blender` returns non-zero on failure and `set -e` would kill the
  # script — which is exactly rule 2. Guard it.
  if ! install_blender; then
    echo "❌ ${BLENDER_INSTALL_ERROR}"
    if [ -x "${BLENDER_INSTALL_PATH}/blender" ]; then
      echo "ℹ️ A previous Blender install is still present and was left untouched."
    fi
  fi
fi

export BLENDER_INSTALL_ERROR
export BLENDER_INSTALLED_VERSION="$(cat "${VERSION_FILE}" 2>/dev/null || true)"

export PATH="${BLENDER_INSTALL_PATH}:${PATH}"

# --- Start Render Pod ---
# Started unconditionally. If Blender is missing, main.py fails the job with
# BLENDER_INSTALL_ERROR over the API, which the app can actually read.
echo "🎯 Starting Bananafarm Render Pod"
echo "   Job ID: ${JOB_ID:-'Not set - will fail'}"
echo ""

exec python3 /app/src/main.py
