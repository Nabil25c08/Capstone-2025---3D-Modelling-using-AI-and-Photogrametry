#!/bin/bash
set -e 

# =============================================================================
# AWS 3D Scan Processing Pipeline (v9.6 - Quiet & Explicit)
# =============================================================================

echo "=============================================="
echo "  AWS 3D Scan Processing Job"
echo "  Start time: $(date)"
echo "=============================================="

# -----------------------------------------------------------------------------
# 0. ENVIRONMENT HUNT
# -----------------------------------------------------------------------------
echo "[Setup] Hunting for AliceVision configuration..."
OCIO_FILE=$(find /opt -name config.ocio | head -n 1)
if [ -z "$OCIO_FILE" ]; then
    echo "FATAL ERROR: Could not find 'config.ocio' anywhere in /opt!"
    ls -R /opt
    exit 1
fi
ALICEVISION_ROOT=${OCIO_FILE%/share/aliceVision/config.ocio}
export ALICEVISION_ROOT="$ALICEVISION_ROOT"
export PATH="${ALICEVISION_ROOT}/bin:${PATH}"
export LD_LIBRARY_PATH="${ALICEVISION_ROOT}/lib:${LD_LIBRARY_PATH}"
export ALICEVISION_SENSOR_DB="${ALICEVISION_ROOT}/share/aliceVision/cameraSensors.db"
echo "  Root set to: $ALICEVISION_ROOT"

# -----------------------------------------------------------------------------
# 1. HARDWARE CHECK
# -----------------------------------------------------------------------------
GPU_AVAILABLE=false
if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
    GPU_AVAILABLE=true
    echo "Hardware: NVIDIA GPU detected. Enabling GPU acceleration."
else
    echo "Hardware: No GPU detected. Running in CPU mode (Slower)."
fi

# Setup Directories
WORK_DIR="/tmp/alicevision_work"
INPUT_RAW="/tmp/input_raw"
INPUT_IMAGES="/tmp/input_images"
FINAL_OUTPUT="/tmp/final_output"

rm -rf "$WORK_DIR" "$INPUT_RAW" "$INPUT_IMAGES" "$FINAL_OUTPUT"
mkdir -p "$WORK_DIR" "$INPUT_RAW" "$INPUT_IMAGES" "$FINAL_OUTPUT"

# -----------------------------------------------------------------------------
# 2. DOWNLOAD & EXTRACT
# -----------------------------------------------------------------------------
echo "[PHASE 1] Downloading s3://${INPUT_BUCKET}/${INPUT_KEY}..."
aws s3 cp "s3://${INPUT_BUCKET}/${INPUT_KEY}" "$INPUT_RAW/input_file"

FILE_TYPE=$(file --mime-type -b "$INPUT_RAW/input_file")
echo "Detected file type: $FILE_TYPE"

echo "[PHASE 2] Extracting content..."
if [[ "$FILE_TYPE" == "application/zip" ]]; then
    unzip -q "$INPUT_RAW/input_file" -d "$INPUT_IMAGES/"
    find "$INPUT_IMAGES" -mindepth 2 -type f -exec mv -t "$INPUT_IMAGES" {} + 2>/dev/null || true
elif [[ "$FILE_TYPE" == video/* ]]; then
    echo "Extracting frames from video (2 fps)..."
    ffmpeg -i "$INPUT_RAW/input_file" -vf fps=2 -qscale:v 2 "$INPUT_IMAGES/frame_%04d.jpg" -y
else
    echo "ERROR: Unsupported file type: $FILE_TYPE"
    exit 1
fi

IMAGE_COUNT=$(find "$INPUT_IMAGES" -maxdepth 1 -type f | wc -l)
echo "Found $IMAGE_COUNT images to process."

# -----------------------------------------------------------------------------
# 3. PHOTOGRAMMETRY PIPELINE
# -----------------------------------------------------------------------------
cd "$WORK_DIR"

# NOTE: Added '--verboseLevel warning' to keep logs clean

echo "[Step 1/9] CameraInit..."
aliceVision_cameraInit \
    --imageFolder "$INPUT_IMAGES" \
    --defaultFieldOfView 45 \
    --allowSingleView 1 \
    --sensorDatabase "$ALICEVISION_SENSOR_DB" \
    --verboseLevel warning \
    --output "$WORK_DIR/cameraInit.sfm"

echo "[Step 2/9] FeatureExtraction..."
if [ "$GPU_AVAILABLE" = true ]; then FORCE_CPU=0; else FORCE_CPU=1; fi
aliceVision_featureExtraction \
    --input "$WORK_DIR/cameraInit.sfm" \
    --output "$WORK_DIR" \
    --describerTypes sift \
    --forceCpuExtraction $FORCE_CPU \
    --verboseLevel warning

echo "[Step 3/9] ImageMatching..."
aliceVision_imageMatching \
    --input "$WORK_DIR/cameraInit.sfm" \
    --featuresFolders "$WORK_DIR" \
    --output "$WORK_DIR/imageMatches.txt" \
    --method Exhaustive \
    --verboseLevel warning

# --- SAFETY SENSOR ---
if [ ! -s "$WORK_DIR/imageMatches.txt" ]; then
    echo "FATAL ERROR: No image matches found! Photos are too difficult/blurry."
    exit 1
fi

echo "[Step 4/9] FeatureMatching..."
aliceVision_featureMatching \
    --input "$WORK_DIR/cameraInit.sfm" \
    --featuresFolders "$WORK_DIR" \
    --imagePairsList "$WORK_DIR/imageMatches.txt" \
    --describerTypes sift \
    --verboseLevel warning \
    --output "$WORK_DIR"

echo "[Step 5/9] IncrementalSfM..."
aliceVision_incrementalSfM \
    --input "$WORK_DIR/cameraInit.sfm" \
    --featuresFolders "$WORK_DIR" \
    --matchesFolders "$WORK_DIR" \
    --verboseLevel warning \
    --output "$WORK_DIR/sfm.sfm"

# INTEGRITY CHECK
if [ ! -f "$WORK_DIR/sfm.sfm" ]; then
    echo "ERROR: SfM failed. No file created."
    exit 1
fi
SOLVED_CAMERAS=$(grep -o '"poseId"' "$WORK_DIR/sfm.sfm" | wc -l)
echo "---------------------------------------------------"
echo "  COMPLETED SFM RECONSTRUCTION"
echo "  Solved Cameras: $SOLVED_CAMERAS / $IMAGE_COUNT"
echo "---------------------------------------------------"

# We lower the bar slightly to 3 cameras to allow for small tests
if [ "$SOLVED_CAMERAS" -lt 3 ]; then
    echo "FATAL ERROR: Photogrammetry Failed."
    echo "The software could only solve $SOLVED_CAMERAS cameras."
    echo "This is NOT a code error. It is a PHOTO error."
    exit 1
fi

# =============================================================================
# DENSE RECONSTRUCTION CHAIN (Explicit v9.6)
# =============================================================================
mkdir -p "$WORK_DIR/dense"

echo "[Step 6/9] PrepareDenseScene..."
# FIX: Explicitly name the output file 'mvs.sfm' so we know exactly what to look for
aliceVision_prepareDenseScene \
    --input "$WORK_DIR/sfm.sfm" \
    --output "$WORK_DIR/dense/mvs.sfm" \
    --verboseLevel warning

# THE DETECTIVE:
if [ ! -f "$WORK_DIR/dense/mvs.sfm" ]; then
    echo "FATAL ERROR: Step 6 failed. mvs.sfm was not created."
    echo "DEBUG: Listing EVERYTHING in the dense folder to see what happened:"
    ls -F "$WORK_DIR/dense"
    exit 1
fi

echo "  > Found Dense SFM file: $WORK_DIR/dense/mvs.sfm"

echo "[Step 7/9] DepthMap (Estimation)..."
aliceVision_depthMapEstimation \
    --input "$WORK_DIR/dense/mvs.sfm" \
    --imagesFolder "$WORK_DIR/dense" \
    --output "$WORK_DIR/dense" \
    --downscale 2 \
    --verboseLevel warning

echo "[Step 8/9] DepthMapFilter (Filtering)..."
aliceVision_depthMapFiltering \
    --input "$WORK_DIR/dense/mvs.sfm" \
    --depthMapsFolder "$WORK_DIR/dense" \
    --output "$WORK_DIR/dense" \
    --verboseLevel warning

echo "[Step 9/9] Meshing..."
aliceVision_meshing \
    --input "$WORK_DIR/dense/mvs.sfm" \
    --depthMapsFolder "$WORK_DIR/dense" \
    --output "$WORK_DIR/mesh.obj" \
    --estimateSpaceFromSfM 1 \
    --maxPoints 5000000 \
    --verboseLevel warning

if [ ! -f "$WORK_DIR/mesh.obj" ]; then
    echo "ERROR: Meshing failed."
    exit 1
fi

# -----------------------------------------------------------------------------
# 4. CLEANUP & UPLOAD
# -----------------------------------------------------------------------------
echo ""
echo "[PHASE 4] Blender Cleanup..."
if [ -f "/app/cleanup.py" ]; then
    blender --background --python /app/cleanup.py -- \
        "$WORK_DIR/mesh.obj" \
        "$FINAL_OUTPUT/printable_model.obj" \
        0.005
else
    echo "WARNING: cleanup.py not found. Uploading raw mesh."
    cp "$WORK_DIR/mesh.obj" "$FINAL_OUTPUT/printable_model.obj"
fi

echo "[PHASE 5] Uploading result..."
OUTPUT_FILENAME=$(basename "${INPUT_KEY%.*}")_printable.obj
aws s3 cp "$FINAL_OUTPUT/printable_model.obj" "s3://${OUTPUT_BUCKET}/${OUTPUT_FILENAME}"

echo "=============================================="
echo "  Job Complete Success!"
echo "=============================================="
