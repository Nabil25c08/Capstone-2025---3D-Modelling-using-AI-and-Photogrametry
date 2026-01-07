# =============================================================================
# AWS Photogrammetry Pipeline (Custom Build: NVIDIA + Meshroom 2025)
# =============================================================================

# 1. Use NVIDIA Base (Includes CUDA for GPU acceleration)
FROM nvidia/cuda:12.1.1-runtime-ubuntu22.04

# Prevent prompts
ENV DEBIAN_FRONTEND=noninteractive

# 2. Install System Dependencies (Meshroom needs these to run)
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    unzip \
    git \
    python3 \
    python3-pip \
    libgl1-mesa-glx \
    libgomp1 \
    libsm6 \
    libxi6 \
    libxrender1 \
    libxkbcommon0 \
    ffmpeg \
    file \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# 3. Install AWS CLI
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
    && unzip -q awscliv2.zip \
    && ./aws/install \
    && rm awscliv2.zip rm -rf aws/

# 4. Install Meshroom 2025.1.0 (From GitHub - Much Faster)
WORKDIR /opt
# Note: Replaced Zenodo link with GitHub Release link
# Download from GitHub (Fast & Reliable)
RUN wget -q --show-progress "https://github.com/alicevision/Meshroom/releases/download/v2023.3.0/Meshroom-2023.3.0-linux.tar.gz" \
    # Extract
    && tar -xzf Meshroom-2023.3.0-linux.tar.gz \
    # Remove the zip file to save space
    && rm Meshroom-2023.3.0-linux.tar.gz \
    # RENAME the folder (This was the fix: The extracted folder is 'Meshroom-2023.3.0')
    && mv Meshroom-2023.3.0 meshroom

# CRITICAL: Add Meshroom/AliceVision to the System PATH
# This allows 'run.sh' to just say "aliceVision_cameraInit" without knowing the exact folder
ENV PATH="/opt/meshroom/aliceVision/bin:$PATH"
ENV LD_LIBRARY_PATH="/opt/meshroom/aliceVision/lib:$LD_LIBRARY_PATH"

# 5. Install Blender 3.6 (For Cleanup)
RUN mkdir -p /usr/local/blender && \
    wget -q -O blender.tar.xz "https://download.blender.org/release/Blender3.6/blender-3.6.5-linux-x64.tar.xz" && \
    tar -xJf blender.tar.xz -C /usr/local/blender --strip-components=1 && \
    rm blender.tar.xz

ENV PATH="/usr/local/blender:$PATH"

# 6. Setup App Scripts
WORKDIR /app
COPY run.sh /app/run.sh
COPY cleanup_script.py /app/cleanup_script.py

RUN chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
