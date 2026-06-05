#!/bin/bash
# compile_shaders.sh
# 编译 Metal 着色器

set -e

echo "=== Compiling Metal Shaders ==="

SHADER_DIR="Shaders"
BUILD_DIR=".build/metal"

mkdir -p "$BUILD_DIR"

# 编译所有 .metal 文件到 .air
echo "[1/3] Compiling .metal -> .air..."

xcrun -sdk macosx metal \
    -c "$SHADER_DIR/Kernels/RayTracing.metal" \
    -o "$BUILD_DIR/RayTracing.air" \
    -I "$SHADER_DIR"

xcrun -sdk macosx metal \
    -c "$SHADER_DIR/Kernels/Accumulation.metal" \
    -o "$BUILD_DIR/Accumulation.air" \
    -I "$SHADER_DIR"

xcrun -sdk macosx metal \
    -c "$SHADER_DIR/Kernels/Blit.metal" \
    -o "$BUILD_DIR/Blit.air" \
    -I "$SHADER_DIR"

xcrun -sdk macosx metal \
    -c "$SHADER_DIR/Kernels/HUD.metal" \
    -o "$BUILD_DIR/HUD.air" \
    -I "$SHADER_DIR"

xcrun -sdk macosx metal \
    -c "$SHADER_DIR/Kernels/Bloom.metal" \
    -o "$BUILD_DIR/Bloom.air" \
    -I "$SHADER_DIR"

xcrun -sdk macosx metal \
    -c "$SHADER_DIR/Kernels/AdaptiveSampling.metal" \
    -o "$BUILD_DIR/AdaptiveSampling.air" \
    -I "$SHADER_DIR"

# 创建 .metallib
echo "[2/3] Linking .air -> .metallib..."
xcrun -sdk macosx metallib \
    "$BUILD_DIR/RayTracing.air" \
    "$BUILD_DIR/Accumulation.air" \
    "$BUILD_DIR/Blit.air" \
    "$BUILD_DIR/HUD.air" \
    "$BUILD_DIR/Bloom.air" \
    "$BUILD_DIR/AdaptiveSampling.air" \
    -o "$BUILD_DIR/default.metallib"

# 复制到资源目录
echo "[3/3] Copying to Resources..."
mkdir -p Resources
cp "$BUILD_DIR/default.metallib" Resources/

echo "✓ Shaders compiled successfully!"
echo "  Output: Resources/default.metallib"
echo "  Kernels: raytrace, accumulate_kernel, reset_accumulation_kernel, blitVertex, blitFragment, hudVertex, hudFragment, bright_pass, downsample, upsample, blend_bloom"
