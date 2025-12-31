#!/bin/bash
#
# build-ffmpeg.sh
# Builds FFmpeg + dav1d as universal static libraries for macOS (arm64 + x86_64)
#
# Usage: ./build-ffmpeg.sh
#
# Output: VidCore/Frameworks/FFmpeg/{include,lib}
#

set -e

# Configuration
FFMPEG_VERSION="8.0.1"
DAV1D_VERSION="1.5.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build-ffmpeg"
OUTPUT_DIR="$ROOT_DIR/Frameworks/FFmpeg"
ARCHS=("arm64" "x86_64")

# Minimum macOS version
MACOS_MIN_VERSION="14.0"

# Libraries we need
FFMPEG_LIBS=(
    "libavcodec"
    "libavformat"
    "libavutil"
    "libswresample"
    "libswscale"
)

echo "=========================================="
echo "FFmpeg + dav1d Static Library Builder"
echo "=========================================="
echo "FFmpeg version: $FFMPEG_VERSION"
echo "dav1d version: $DAV1D_VERSION"
echo "Target architectures: ${ARCHS[*]}"
echo "Output directory: $OUTPUT_DIR"
echo ""

# Check for required tools
check_dependencies() {
    echo "Checking dependencies..."
    
    local missing=()
    
    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v make >/dev/null 2>&1 || missing+=("make")
    command -v nasm >/dev/null 2>&1 || missing+=("nasm (brew install nasm)")
    command -v meson >/dev/null 2>&1 || missing+=("meson (brew install meson)")
    command -v ninja >/dev/null 2>&1 || missing+=("ninja (brew install ninja)")
    command -v pkg-config >/dev/null 2>&1 || missing+=("pkg-config (brew install pkg-config)")
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo "ERROR: Missing required tools:"
        printf '  - %s\n' "${missing[@]}"
        echo ""
        echo "Install with: brew install nasm meson ninja pkg-config"
        exit 1
    fi
    
    echo "All dependencies found."
}

# Download sources
download_sources() {
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    
    # Download FFmpeg
    echo ""
    echo "Downloading FFmpeg $FFMPEG_VERSION..."
    if [ -d "ffmpeg-$FFMPEG_VERSION" ]; then
        echo "FFmpeg source already exists, skipping."
    else
        curl -L -o "ffmpeg-${FFMPEG_VERSION}.tar.xz" "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
        tar xf "ffmpeg-${FFMPEG_VERSION}.tar.xz"
        rm "ffmpeg-${FFMPEG_VERSION}.tar.xz"
    fi
    
    # Download dav1d
    echo ""
    echo "Downloading dav1d $DAV1D_VERSION..."
    if [ -d "dav1d-$DAV1D_VERSION" ]; then
        echo "dav1d source already exists, skipping."
    else
        curl -L -o "dav1d-${DAV1D_VERSION}.tar.xz" "https://code.videolan.org/videolan/dav1d/-/archive/${DAV1D_VERSION}/dav1d-${DAV1D_VERSION}.tar.bz2"
        tar xf "dav1d-${DAV1D_VERSION}.tar.xz"
        rm "dav1d-${DAV1D_VERSION}.tar.xz"
    fi
}

# Build dav1d for a specific architecture
build_dav1d_arch() {
    local arch=$1
    local src_dir="$BUILD_DIR/dav1d-$DAV1D_VERSION"
    local build_dir="$BUILD_DIR/dav1d-build-$arch"
    local install_dir="$BUILD_DIR/install-$arch"
    
    echo ""
    echo "Building dav1d for $arch..."
    
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    
    # Create meson cross file for the architecture
    local cross_file="$build_dir/cross.txt"
    
    if [ "$arch" = "x86_64" ]; then
        cat > "$cross_file" << EOF
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'ar'
strip = 'strip'

[built-in options]
c_args = ['-arch', 'x86_64', '-mmacosx-version-min=$MACOS_MIN_VERSION']
c_link_args = ['-arch', 'x86_64', '-mmacosx-version-min=$MACOS_MIN_VERSION']

[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
    else
        cat > "$cross_file" << EOF
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'ar'
strip = 'strip'

[built-in options]
c_args = ['-arch', 'arm64', '-mmacosx-version-min=$MACOS_MIN_VERSION']
c_link_args = ['-arch', 'arm64', '-mmacosx-version-min=$MACOS_MIN_VERSION']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
    fi
    
    cd "$build_dir"
    meson setup \
        --prefix="$install_dir" \
        --cross-file="$cross_file" \
        --default-library=static \
        --buildtype=release \
        -Denable_tools=false \
        -Denable_tests=false \
        "$src_dir"
    
    ninja
    ninja install
    
    echo "dav1d build complete for $arch"
}

# Build FFmpeg for a specific architecture
build_ffmpeg_arch() {
    local arch=$1
    local src_dir="$BUILD_DIR/ffmpeg-$FFMPEG_VERSION"
    local build_dir="$BUILD_DIR/ffmpeg-build-$arch"
    local install_dir="$BUILD_DIR/install-$arch"
    
    echo ""
    echo "=========================================="
    echo "Building FFmpeg for $arch"
    echo "=========================================="
    
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir"
    
    # Set up architecture flags
    local extra_cflags="-mmacosx-version-min=$MACOS_MIN_VERSION"
    local extra_ldflags="-mmacosx-version-min=$MACOS_MIN_VERSION"
    
    if [ "$arch" = "x86_64" ]; then
        extra_cflags="$extra_cflags -arch x86_64"
        extra_ldflags="$extra_ldflags -arch x86_64"
    else
        extra_cflags="$extra_cflags -arch arm64"
        extra_ldflags="$extra_ldflags -arch arm64"
    fi
    
    # Add dav1d paths
    export PKG_CONFIG_PATH="$install_dir/lib/pkgconfig:$PKG_CONFIG_PATH"
    extra_cflags="$extra_cflags -I$install_dir/include"
    extra_ldflags="$extra_ldflags -L$install_dir/lib"
    
    # Configure FFmpeg with all decoders + dav1d
    "$src_dir/configure" \
        --prefix="$install_dir" \
        --arch="$arch" \
        --enable-cross-compile \
        --target-os=darwin \
        --cc="clang" \
        --cxx="clang++" \
        --extra-cflags="$extra_cflags" \
        --extra-ldflags="$extra_ldflags" \
        \
        --enable-static \
        --disable-shared \
        --enable-pic \
        --enable-gpl \
        --enable-version3 \
        \
        --disable-programs \
        --disable-doc \
        --disable-htmlpages \
        --disable-manpages \
        --disable-podpages \
        --disable-txtpages \
        \
        --enable-videotoolbox \
        --enable-audiotoolbox \
        --enable-libdav1d \
        \
        --disable-network \
        --disable-debug \
        \
        --disable-avfilter \
        --disable-avdevice \
        --disable-encoders \
        --disable-muxers \
        --disable-devices \
        --disable-outdevs \
        --disable-indevs \
        \
        --enable-protocol=file \
        --enable-protocol=pipe
    
    # Build
    echo "Compiling FFmpeg (this may take a while)..."
    make -j$(sysctl -n hw.ncpu)
    make install
    
    echo "FFmpeg build complete for $arch"
}

# Create universal (fat) libraries
create_universal_libs() {
    echo ""
    echo "=========================================="
    echo "Creating universal libraries"
    echo "=========================================="
    
    mkdir -p "$OUTPUT_DIR/lib"
    mkdir -p "$OUTPUT_DIR/include"
    
    # Copy headers from arm64 build
    cp -R "$BUILD_DIR/install-arm64/include/"* "$OUTPUT_DIR/include/"
    
    # Create universal FFmpeg libraries
    for lib in "${FFMPEG_LIBS[@]}"; do
        local lib_name="${lib}.a"
        local arm64_lib="$BUILD_DIR/install-arm64/lib/$lib_name"
        local x86_64_lib="$BUILD_DIR/install-x86_64/lib/$lib_name"
        local output_lib="$OUTPUT_DIR/lib/$lib_name"
        
        if [ -f "$arm64_lib" ] && [ -f "$x86_64_lib" ]; then
            echo "Creating universal library: $lib_name"
            lipo -create "$arm64_lib" "$x86_64_lib" -output "$output_lib"
            lipo -info "$output_lib"
        fi
    done
    
    # Create universal dav1d library
    local dav1d_arm64="$BUILD_DIR/install-arm64/lib/libdav1d.a"
    local dav1d_x86="$BUILD_DIR/install-x86_64/lib/libdav1d.a"
    if [ -f "$dav1d_arm64" ] && [ -f "$dav1d_x86" ]; then
        echo "Creating universal library: libdav1d.a"
        lipo -create "$dav1d_arm64" "$dav1d_x86" -output "$OUTPUT_DIR/lib/libdav1d.a"
        lipo -info "$OUTPUT_DIR/lib/libdav1d.a"
    fi
    
    echo ""
    echo "Universal libraries created in: $OUTPUT_DIR/lib"
}

# Cleanup
cleanup() {
    echo ""
    read -p "Clean up build directory ($BUILD_DIR)? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$BUILD_DIR"
        echo "Build directory cleaned up."
    else
        echo "Build directory preserved at: $BUILD_DIR"
    fi
}

# Print summary
print_summary() {
    echo ""
    echo "=========================================="
    echo "Build Complete!"
    echo "=========================================="
    echo ""
    echo "Output location: $OUTPUT_DIR"
    echo ""
    echo "Libraries built:"
    ls -lh "$OUTPUT_DIR/lib/"*.a 2>/dev/null || echo "  (none found)"
    echo ""
    echo "Next steps:"
    echo "  1. Build VidCore in Xcode"
    echo "  2. Build and run your app to verify"
}

# Main
main() {
    check_dependencies
    download_sources
    
    for arch in "${ARCHS[@]}"; do
        build_dav1d_arch "$arch"
        build_ffmpeg_arch "$arch"
    done
    
    create_universal_libs
    cleanup
    print_summary
}

main "$@"
