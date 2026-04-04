source /dev/stdin <<< "$(curl -s https://raw.githubusercontent.com/pytgcalls/build-toolkit/refs/heads/master/build-toolkit.sh)"

require msvc
require xcode
require venv
require ndk

# Normalize CC and CXX to short Windows paths to avoid space issues in FFmpeg's configure.
# We do NOT normalize LIB and LIBPATH here as they are managed by MSVC and cygpath might break them.
if is_windows; then
  export CC=$(cygpath -s -m "$CC")
  export CXX=$(cygpath -s -m "$CXX")
fi

import patch-opus.sh
import libraries.properties
import libraries.properties from "github.com/pytgcalls/mesa"

sysroot_dir="$BUILD_KIT_DIR/usr"
selected_windows_arch="${FFMPEG_WINDOWS_ARCH:-}"

if is_linux; then
  build_and_install "libva" meson --prefix="$sysroot_dir"
  build_and_install "libvdpau" meson --prefix="$sysroot_dir"
fi

if is_linux || is_windows; then
  build_and_install "nv-codec-headers" make --prefix="$sysroot_dir"
fi

arch_builds=("default")

if is_android; then
  arch_builds=("x86_64" "x86" "arm64-v8a" "armv7-a")
fi

if is_windows; then
  arch_builds=("x86_64")
  if [[ -n "$selected_windows_arch" ]]; then
    case "$selected_windows_arch" in
      x86|x86_64) arch_builds=("$selected_windows_arch") ;;
      *) echo "Unsupported FFMPEG_WINDOWS_ARCH: $selected_windows_arch" >&2; exit 1 ;;
    esac
  fi
fi

for arch in "${arch_builds[@]}"; do
  if is_windows; then
    # Adjust MSVC environment for x86. build-toolkit defaults to x64.
    extra_configure_flags=""
    if [[ "$arch" == "x86" ]]; then
      msvc_bin_dir=$(dirname "$CC")
      x86_bin_dir="${msvc_bin_dir//\/x64/\/x86}"
      export PATH="$x86_bin_dir:$PATH"
      export CC="$x86_bin_dir/cl.exe"
      export CXX="$x86_bin_dir/cl.exe"
      export LIB="${LIB//\\x64/\\x86}"; export LIB="${LIB//\/x64/\/x86}"
      export LIBPATH="${LIBPATH//\\x64/\\x86}"; export LIBPATH="${LIBPATH//\/x64/\/x86}"
      # Force x86 target for MSVC compiler and linker
      extra_configure_flags="--extra-ldflags=/MACHINE:X86"
      echo "[info] Switched MSVC environment to x86"
    fi

    opus_prefix="$sysroot_dir"
    cmake_arch="x64"
    [[ "$arch" == "x86" ]] && cmake_arch="Win32"

    build_and_install "opus" cmake -G "Visual Studio 17 2022" -A "$cmake_arch" \
      -DCMAKE_INSTALL_PREFIX="$opus_prefix" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_INSTALL_INCLUDEDIR=include

    win_opus_prefix=$(to_windows "$opus_prefix" | sed 's|\\|/|g')
    export libopus_CFLAGS="-I$win_opus_prefix/include/opus"
    export libopus_LIBS="$win_opus_prefix/lib/opus.lib"
    export LIBOPUS_CFLAGS="$libopus_CFLAGS"
    export LIBOPUS_LIBS="$libopus_LIBS"

    (
      # We explicitly set --host-cc to $CC to avoid FFmpeg looking for 'gcc'
      # which might be missing or incompatible. This fixes "Host compiler lacks C11 support".
      build_and_install "FFmpeg" configure-static \
        --windows="--target-os=$(if [[ "$arch" == "x86" ]]; then echo win32; else echo win64; fi) \
            --arch=$arch \
            --toolchain=msvc \
            --enable-cross-compile \
            --host-cc='$CC' \
            --host-ld='$CC' \
            --extra-cflags=-I$win_opus_prefix/include \
            --extra-ldflags=-L$win_opus_prefix/lib \
            --extra-libs=opus.lib \
            $extra_configure_flags" \
        --disable-programs --disable-doc \
        --disable-network --disable-everything \
        --enable-runtime-cpudetect --enable-protocol=file \
        --enable-hwaccels --disable-dxva2 \
        --enable-libopus \
        --enable-decoder=h264 --enable-decoder=mp3 --enable-decoder=mp3adu \
        --enable-decoder=mp3adufloat --enable-decoder=mp3float --enable-decoder=mp3on4 \
        --enable-decoder=mp3on4float --enable-decoder=mp1 --enable-decoder=mp1float \
        --enable-decoder=mp2 --enable-decoder=mp2float --enable-decoder=mpeg4 \
        --enable-decoder=hevc --enable-decoder=msmpeg4v2 --enable-decoder=msmpeg4v3 \
        --enable-decoder=opus --enable-decoder=pcm_alaw --enable-decoder=pcm_f32be \
        --enable-decoder=pcm_f32le --enable-decoder=pcm_f64be --enable-decoder=pcm_f64le \
        --enable-decoder=pcm_lxf --enable-decoder=pcm_mulaw --enable-decoder=pcm_s16be \
        --enable-decoder=pcm_s16be_planar --enable-decoder=pcm_s16le --enable-decoder=pcm_s16le_planar \
        --enable-decoder=pcm_s24be --enable-decoder=pcm_s24daud --enable-decoder=pcm_s24le \
        --enable-decoder=pcm_s24le_planar --enable-decoder=pcm_s32be --enable-decoder=pcm_s32le \
        --enable-decoder=pcm_s32le_planar --enable-decoder=pcm_s64be --enable-decoder=pcm_s64le \
        --enable-decoder=pcm_s8 --enable-decoder=pcm_s8_planar --enable-decoder=pcm_u16be \
        --enable-decoder=pcm_u16le --enable-decoder=pcm_u24be --enable-decoder=pcm_u24le \
        --enable-decoder=pcm_u32be --enable-decoder=pcm_u32le --enable-decoder=pcm_u8 \
        --enable-decoder=wavpack --enable-decoder=wmalossless --enable-decoder=wmapro \
        --enable-decoder=wmav1 --enable-decoder=wmav2 --enable-decoder=wmavoice \
        --enable-decoder=aac --enable-decoder=aac_fixed --enable-decoder=aac_latm \
        --enable-encoder=libopus --enable-demuxer=h264 --enable-demuxer=hevc \
        --enable-demuxer=matroska --enable-demuxer=m4v --enable-demuxer=mov \
        --enable-demuxer=mp3 --enable-demuxer=ogg --enable-demuxer=wav \
        --enable-demuxer=aac --enable-muxer=ogg --enable-muxer=opus \
        --enable-muxer=mp4 --enable-parser=h264 --enable-parser=hevc \
        --enable-parser=mpegaudio --enable-parser=mpeg4video --enable-parser=opus \
        --enable-parser=aac --enable-parser=aac_latm
    ) || {
      echo "[error] FFmpeg configure failed. Printing config.log (last 200 lines):"
      find . -name config.log -exec tail -n 200 {} \; || true
      exit 1
    }
  elif is_android; then
    build_and_install "opus" cmake -DCMAKE_TOOLCHAIN_FILE="$(android_tool toolchain)" \
        -DANDROID_ABI="$(normalize_arch "$arch" "fancy")" --setup-commands="patch_opus" --prefix="$sysroot_dir" \
        -DCMAKE_C_FLAGS="-O2 -fvisibility=hidden -ffunction-sections -fdata-sections -g -fno-omit-frame-pointer"
  else
    build_and_install "opus" configure --prefix="$sysroot_dir"
    build_and_install "FFmpeg" configure-static \
      --linux="..." --macos="..." --android="..." --linux-windows="..." --linux-macos-android="..." \
      --disable-programs --disable-doc --disable-network --disable-everything \
      --enable-runtime-cpudetect --enable-protocol=file --enable-hwaccels --disable-dxva2 --enable-libopus \
      --enable-decoder=... --enable-encoder=libopus --enable-demuxer=... --enable-muxer=... --enable-parser=...
  fi

  if is_windows; then
    copy_libs "FFmpeg" "artifacts" "avcodec" "avformat" "avutil" "swresample" --arch="default"
  else
    copy_libs "FFmpeg" "artifacts" "avcodec" "avformat" "avutil" "swresample" --arch="$arch"
  fi
done
