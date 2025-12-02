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
    -c "$SHADER_DIR/Kernels/TestGradient.metal" \
    -o "$BUILD_DIR/TestGradient.air" \
    -I "$SHADER_DIR"

xcrun -sdk macosx metal \
    -c "$SHADER_DIR/Kernels/SimpleRayTracing.metal" \
    -o "$BUILD_DIR/SimpleRayTracing.air" \
    -I "$SHADER_DIR"

# 创建 .metallib
echo "[2/3] Linking .air -> .metallib..."
xcrun -sdk macosx metallib \
    "$BUILD_DIR/TestGradient.air" \
    "$BUILD_DIR/SimpleRayTracing.air" \
    -o "$BUILD_DIR/default.metallib"

# 复制到资源目录
echo "[3/3] Copying to Resources..."
mkdir -p Resources
cp "$BUILD_DIR/default.metallib" Resources/

echo "✓ Shaders compiled successfully!"
echo "  Output: Resources/default.metallib"
echo "  Kernels: test_gradient, simple_raytrace"
