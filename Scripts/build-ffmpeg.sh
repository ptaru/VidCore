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
FREETYPE_VERSION="2.13.2"
FRIBIDI_VERSION="1.0.13"
HARFBUZZ_VERSION="8.3.0"
LIBASS_VERSION="0.17.1"
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
echo "freetype version: $FREETYPE_VERSION"
echo "fribidi version: $FRIBIDI_VERSION"
echo "harfbuzz version: $HARFBUZZ_VERSION"
echo "libass version: $LIBASS_VERSION"
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
    command -v autoconf >/dev/null 2>&1 || missing+=("autoconf (brew install autoconf)")
    command -v automake >/dev/null 2>&1 || missing+=("automake (brew install automake)")
    command -v libtool >/dev/null 2>&1 || missing+=("libtool (brew install libtool)")
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo "ERROR: Missing required tools:"
        printf '  - %s\n' "${missing[@]}"
        echo ""
        echo "Install with: brew install autoconf automake nasm meson ninja pkg-config"
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

    # Download freetype
    echo ""
    echo "Downloading freetype $FREETYPE_VERSION..."
    if [ -d "freetype-$FREETYPE_VERSION" ]; then
        echo "freetype source already exists, skipping."
    else
        curl -L -o "freetype-${FREETYPE_VERSION}.tar.xz" "https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"
        tar xf "freetype-${FREETYPE_VERSION}.tar.xz"
        rm "freetype-${FREETYPE_VERSION}.tar.xz"
    fi

    # Download fribidi
    echo ""
    echo "Downloading fribidi $FRIBIDI_VERSION..."
    if [ -d "fribidi-$FRIBIDI_VERSION" ]; then
        echo "fribidi source already exists, skipping."
    else
        curl -L -o "fribidi-${FRIBIDI_VERSION}.tar.xz" "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz"
        tar xf "fribidi-${FRIBIDI_VERSION}.tar.xz"
        rm "fribidi-${FRIBIDI_VERSION}.tar.xz"
    fi

    # Download harfbuzz
    echo ""
    echo "Downloading harfbuzz $HARFBUZZ_VERSION..."
    if [ -d "harfbuzz-$HARFBUZZ_VERSION" ]; then
        echo "harfbuzz source already exists, skipping."
    else
        curl -L -o "harfbuzz-${HARFBUZZ_VERSION}.tar.xz" "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
        tar xf "harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
        rm "harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
    fi

    # Download libass
    echo ""
    echo "Downloading libass $LIBASS_VERSION..."
    if [ -d "libass-$LIBASS_VERSION" ]; then
        echo "libass source already exists, skipping."
    else
        curl -L -o "libass-${LIBASS_VERSION}.tar.xz" "https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.xz"
        tar xf "libass-${LIBASS_VERSION}.tar.xz"
        rm "libass-${LIBASS_VERSION}.tar.xz"
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

# Build freetype
build_freetype_arch() {
    local arch=$1
    local src_dir="$BUILD_DIR/freetype-$FREETYPE_VERSION"
    local build_dir="$BUILD_DIR/freetype-build-$arch"
    local install_dir="$BUILD_DIR/install-$arch"
    
    echo ""
    echo "Building freetype for $arch..."
    
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir"
    
    local host_arg=""
    if [ "$arch" = "arm64" ]; then
        host_arg="--host=aarch64-apple-darwin"
    else
        host_arg="--host=x86_64-apple-darwin"
    fi
    
    local cflags="-arch $arch -mmacosx-version-min=$MACOS_MIN_VERSION"
    
    "$src_dir/configure" \
        --prefix="$install_dir" \
        $host_arg \
        --enable-static \
        --disable-shared \
        --with-png=no \
        --with-harfbuzz=no \
        --with-brotli=no \
        --with-zlib=no \
        CFLAGS="$cflags" \
        LDFLAGS="$cflags"
        
    make -j$(sysctl -n hw.ncpu)
    make install
    
    echo "freetype build complete for $arch"
}

# Build fribidi
build_fribidi_arch() {
    local arch=$1
    local src_dir="$BUILD_DIR/fribidi-$FRIBIDI_VERSION"
    local build_dir="$BUILD_DIR/fribidi-build-$arch"
    local install_dir="$BUILD_DIR/install-$arch"
    
    echo ""
    echo "Building fribidi for $arch..."
    
    rm -rf "$build_dir"
    cp -R "$src_dir" "$build_dir"
    cd "$build_dir"
    
    local host_arg=""
    if [ "$arch" = "arm64" ]; then
        host_arg="--host=aarch64-apple-darwin"
    else
        host_arg="--host=x86_64-apple-darwin"
    fi
    
    local cflags="-arch $arch -mmacosx-version-min=$MACOS_MIN_VERSION"
    
    ./configure \
        --prefix="$install_dir" \
        $host_arg \
        --enable-static \
        --disable-shared \
        CFLAGS="$cflags" \
        LDFLAGS="$cflags"
        
    make -j$(sysctl -n hw.ncpu)
    make install
    
    echo "fribidi build complete for $arch"
}

# Build harfbuzz
build_harfbuzz_arch() {
    local arch=$1
    local src_dir="$BUILD_DIR/harfbuzz-$HARFBUZZ_VERSION"
    local build_dir="$BUILD_DIR/harfbuzz-build-$arch"
    local install_dir="$BUILD_DIR/install-$arch"
    
    echo ""
    echo "Building harfbuzz for $arch..."
    
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    
    # Create meson cross file
    local cross_file="$build_dir/cross.txt"
    if [ "$arch" = "x86_64" ]; then
        cat > "$cross_file" << EOF
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'ar'
strip = 'strip'
pkgconfig = 'pkg-config'

[built-in options]
c_args = ['-arch', 'x86_64', '-mmacosx-version-min=$MACOS_MIN_VERSION']
cpp_args = ['-arch', 'x86_64', '-mmacosx-version-min=$MACOS_MIN_VERSION']
c_link_args = ['-arch', 'x86_64', '-mmacosx-version-min=$MACOS_MIN_VERSION']
cpp_link_args = ['-arch', 'x86_64', '-mmacosx-version-min=$MACOS_MIN_VERSION']

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
pkgconfig = 'pkg-config'

[built-in options]
c_args = ['-arch', 'arm64', '-mmacosx-version-min=$MACOS_MIN_VERSION']
cpp_args = ['-arch', 'arm64', '-mmacosx-version-min=$MACOS_MIN_VERSION']
c_link_args = ['-arch', 'arm64', '-mmacosx-version-min=$MACOS_MIN_VERSION']
cpp_link_args = ['-arch', 'arm64', '-mmacosx-version-min=$MACOS_MIN_VERSION']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
    fi

    cd "$build_dir"
    
    # Needs freetype
    # Use subshell-like variable assignment for configure/build env to avoid global pollution
    local pkg_path="$install_dir/lib/pkgconfig"
    export PKG_CONFIG_PATH="$pkg_path"
    
    meson setup \
        --prefix="$install_dir" \
        --cross-file="$cross_file" \
        --default-library=static \
        --buildtype=release \
        -Dtests=disabled \
        -Ddocs=disabled \
        -Dglib=disabled \
        -Dgobject=disabled \
        -Dcairo=disabled \
        -Dicu=disabled \
        -Dfreetype=enabled \
        "$src_dir"
        
    ninja
    ninja install
    
    echo "harfbuzz build complete for $arch"
}

# Build libass
build_libass_arch() {
    local arch=$1
    local src_dir="$BUILD_DIR/libass-$LIBASS_VERSION"
    local build_dir="$BUILD_DIR/libass-build-$arch"
    local install_dir="$BUILD_DIR/install-$arch"
    
    echo ""
    echo "Building libass for $arch..."
    
    rm -rf "$build_dir"
    cp -R "$src_dir" "$build_dir"
    cd "$build_dir"
    
    local host_arg=""
    if [ "$arch" = "arm64" ]; then
        host_arg="--host=aarch64-apple-darwin"
    else
        host_arg="--host=x86_64-apple-darwin"
    fi
    
    local cflags="-arch $arch -mmacosx-version-min=$MACOS_MIN_VERSION"
    
    # Needs freetype, fribidi, harfbuzz
    local pkg_path="$install_dir/lib/pkgconfig"
    export PKG_CONFIG_PATH="$pkg_path"
    
    ./configure \
        --prefix="$install_dir" \
        $host_arg \
        --enable-static \
        --disable-shared \
        --disable-fontconfig \
        --disable-libunibreak \
        --disable-require-system-font-provider \
        CFLAGS="$cflags" \
        LDFLAGS="$cflags"
        
    make -j$(sysctl -n hw.ncpu)
    make install
    
    echo "libass build complete for $arch"
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
    
    export PKG_CONFIG_PATH="$install_dir/lib/pkgconfig"

    # Add gettext (libintl) if available
    if command -v brew >/dev/null 2>&1; then
        local gettext_prefix=$(brew --prefix gettext 2>/dev/null)
        if [ -n "$gettext_prefix" ] && [ -d "$gettext_prefix" ]; then
             extra_cflags="$extra_cflags -I$gettext_prefix/include"
             extra_ldflags="$extra_ldflags -L$gettext_prefix/lib"
        fi
    fi
    
    # Debug: Check if libass.pc is found
    echo "Checking libass pkg-config:"
    pkg-config --modversion libass || echo "Error: libass not found by pkg-config"
    pkg-config --cflags --libs libass || echo "Error: libass flags retrieval failed"

    # Configure FFmpeg with all decoders + dav1d
    "$src_dir/configure" \
        --prefix="$install_dir" \
        --arch="$arch" \
        --enable-cross-compile \
        --target-os=darwin \
        --cc="clang" \
        --cxx="clang++" \
        --pkg-config-flags="--static" \
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
        --enable-libass \
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
        lipo -info "$OUTPUT_DIR/lib/libdav1d.a"
    fi
    
    # Create universal libraries for dependencies
    local deps=("freetype" "fribidi" "harfbuzz" "ass")
    for dep in "${deps[@]}"; do
        local lib_name="lib${dep}.a"
        local arm64_lib="$BUILD_DIR/install-arm64/lib/$lib_name"
        local x86_lib="$BUILD_DIR/install-x86_64/lib/$lib_name"
        
        if [ -f "$arm64_lib" ] && [ -f "$x86_lib" ]; then
            echo "Creating universal library: $lib_name"
            lipo -create "$arm64_lib" "$x86_lib" -output "$OUTPUT_DIR/lib/$lib_name"
            lipo -info "$OUTPUT_DIR/lib/$lib_name"
        fi
    done
    
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
        build_freetype_arch "$arch"
        build_fribidi_arch "$arch"
        build_harfbuzz_arch "$arch"
        build_libass_arch "$arch"
        build_ffmpeg_arch "$arch"
    done
    
    create_universal_libs
    cleanup
    print_summary
}

main "$@"
