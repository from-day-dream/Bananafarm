FROM nvidia/opengl:1.2-glvnd-runtime-ubuntu22.04

ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}
ENV PATH=/usr/local/cuda/bin:${PATH}

# Create symlinks for CUDA libraries if needed
RUN ldconfig

# Set environment variables for non-interactive install and default Blender version
ENV DEBIAN_FRONTEND=noninteractive
# Default only. The desktop app overrides this per job; entrypoint.sh and
# src/main.py carry the same fallback, as does AppConstants in the Flutter app.
ENV BLENDER_VERSION="5.2.2"
ENV API_PORT=8000

# Large file upload optimization
ENV FASTAPI_MAX_REQUEST_SIZE=10737418240
ENV UVICORN_BACKLOG=2048
ENV UVICORN_LIMIT_CONCURRENCY=1000

# GPU rendering environment variables for CUDA
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics
ENV CUDA_VISIBLE_DEVICES=0

# EGL/OpenGL environment variables for headless rendering
ENV __EGL_VENDOR_LIBRARY_DIRS=/usr/share/glvnd/egl_vendor.d
ENV LIBGL_ALWAYS_SOFTWARE=0
ENV GALLIUM_DRIVER=
# Critical EGL platform variables for headless GPU rendering
ENV EGL_PLATFORM=device
ENV PYOPENGL_PLATFORM=egl
# Ensure proper device detection
ENV __GLX_VENDOR_LIBRARY_DIRS=/usr/share/glvnd/egl_vendor.d

# 1. Install system dependencies (removed supervisor, redis-server)
RUN apt-get update && apt-get install -y \
    wget \
    tar \
    xz-utils \
    python3.10 \
    python3-pip \
    curl \
    unzip \
    p7zip-full \
    mesa-utils \
    libgl1 \
    libxrender1 \
    libxi6 \
    libxfixes3 \
    libxkbcommon-x11-0 \
    libsm6 \
    libice6 \
    libegl1-mesa \
    libegl1-mesa-dev \
    libgl1-mesa-glx \
    libgl1-mesa-dev \
    libglu1-mesa \
    libglu1-mesa-dev \
    libxrandr2 \
    libxxf86vm1 \
    libxcursor1 \
    libxinerama1 \
    xvfb \
    libxext-dev \
    libx11-dev \
    x11proto-gl-dev \
    git \
    build-essential \
    autotools-dev \
    automake \
    libtool \
    pkg-config \
    libwayland-client0 \
    libwayland-cursor0 \
    libwayland-egl1 \
    libwayland-server0 \
    libwayland-dev \
    wayland-protocols \
    libdecor-0-0 \
    libdecor-0-dev \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Install comprehensive video codec support for professional formats
RUN apt-get update && apt-get install -y \
    ffmpeg \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    libswresample-dev \
    libavfilter-dev \
    libavdevice-dev \
    libaom-dev \
    libdav1d-dev \
    libvpx-dev \
    libx264-dev \
    libx265-dev \
    libmp3lame-dev \
    libopus-dev \
    libvorbis-dev \
    libtheora-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/NVIDIA/libglvnd.git /tmp/libglvnd && \
    cd /tmp/libglvnd && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /tmp/libglvnd

RUN mkdir -p /usr/share/glvnd/egl_vendor.d && \
    echo '{\
    "file_format_version" : "1.0.0",\
    "ICD": {\
        "library_path": "libEGL_nvidia.so.0"\
    }\
}' > /usr/share/glvnd/egl_vendor.d/10_nvidia.json

# 2. Create app directory structure
RUN mkdir -p /app/src \
    /tmp/render_output \
    /tmp/uploads && \
    chmod 755 /tmp/render_output /tmp/uploads

# 3. Set working directory
WORKDIR /app

# 4. Install Python dependencies
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

# 5. Copy application code and entrypoint script
COPY src/ /app/src/
COPY entrypoint.sh /app/entrypoint.sh
# Note: Blender is downloaded from the official source at container startup, so
# one image serves every Blender release. A previously advertised /app/dist/
# fallback was never built (nothing COPYs it in) and has been removed from
# entrypoint.sh; the desktop app's pre-submit version check is the real guard.

# 6. Convert line endings and set permissions for the entrypoint script
RUN apt-get update && apt-get install -y dos2unix && rm -rf /var/lib/apt/lists/* && \
    dos2unix /app/entrypoint.sh && \
    chmod +x /app/entrypoint.sh

# 7. Expose the control API port (Vast maps EXPOSEd ports with direct networking)
EXPOSE 8000

# 8. Build stamp reported by GET /health. Providers cache images by tag, so a
# node can serve an older build under the tag it was asked for; this is what
# makes that visible. Declared last on purpose — it changes every build, and
# anything below an invalidated layer would rebuild with it.
ARG BUILD_ID=unknown
ENV BUILD_ID=${BUILD_ID}

# 9. Use the entrypoint script to start the render pod
ENTRYPOINT ["/app/entrypoint.sh"]
