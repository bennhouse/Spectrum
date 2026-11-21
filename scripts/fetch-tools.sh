#!/bin/zsh
# Builds the decoder Spectrum bundles: a minimal FFmpeg (ffmpeg + ffprobe) with only what reading
# audio needs (demuxers, parsers, audio decoders, raw float output). About 10 MB each instead of
# 66 MB for a full static build, and quicker to start. The source tarball is checked against its
# SHA-256 and the binaries land in vendor/bin (not in the repository); build-app.sh copies them
# into Contents/Resources/bin. Needs the Xcode command line tools (clang, make).
#   scripts/fetch-tools.sh
#
# Built without --enable-gpl and without external libraries: the binaries are LGPL 2.1.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="7.1.2"
SHA256="089bc60fb59d6aecc5d994ff530fd0dcb3ee39aa55867849a2bbc4e555f9c304"
SRC="vendor/src"; mkdir -p "$SRC"
TAR="$SRC/ffmpeg-$VERSION.tar.xz"
[[ -f "$TAR" ]] || curl -fsSL -o "$TAR" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
got=$(shasum -a 256 "$TAR" | cut -d' ' -f1)
if [[ "$got" != "$SHA256" ]]; then echo "error: checksum mismatch for $TAR" >&2; rm -f "$TAR"; exit 1; fi

rm -rf "$SRC/ffmpeg-$VERSION"
tar -xf "$TAR" -C "$SRC"
cd "$SRC/ffmpeg-$VERSION"
# Video decoders are left out: Spectrum only maps audio streams (-map 0:a:N -vn).
NOVIDEO='*_cuvid,*_v4l2m2m,*_mediacodec,*_qsv,*_rkmpp,h264,hevc,vp8,vp9,av1,mpeg2video,mpeg4,prores,dnxhd,mjpeg,png,tiff,webp,gif,bmp,jpeg2000,vc1,wmv1,wmv2,wmv3,h263,theora,cinepak,qtrle,rawvideo,ffv1,hap,huffyuv,utvideo,dirac,exr,dds,dpx,jpegls,ffvhuff,vvc,mpeg1video,flv,h261,msmpeg4v1,msmpeg4v2,msmpeg4v3'
./configure --disable-everything --disable-autodetect --disable-doc --disable-network --disable-avdevice \
    --disable-swscale --disable-postproc --disable-ffplay --enable-ffmpeg --enable-ffprobe --disable-debug \
    --enable-protocol=file,pipe --enable-demuxers --enable-parsers --enable-bsfs \
    --enable-decoders --disable-decoder="$NOVIDEO" \
    --enable-encoder=pcm_f32le,wrapped_avframe --enable-muxer=pcm_f32le,null \
    --enable-filter=aresample,aformat,anull,null,format,atrim --enable-swresample \
    --extra-cflags="-mmacosx-version-min=15.0" --extra-ldflags="-mmacosx-version-min=15.0" >/dev/null
make -j"$(sysctl -n hw.ncpu)" >/dev/null 2>&1
cd - >/dev/null
rm -rf vendor/bin; mkdir -p vendor/bin
cp "$SRC/ffmpeg-$VERSION/ffmpeg" "$SRC/ffmpeg-$VERSION/ffprobe" vendor/bin/
strip vendor/bin/ffmpeg vendor/bin/ffprobe
echo "Tools ready in vendor/bin: $(vendor/bin/ffmpeg -version | head -1 | cut -d' ' -f1-3)"
