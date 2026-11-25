#!/bin/zsh
# Vicinia — build the two pinned native C dependencies for iOS/iPadOS 27 arm64:
#   OpenSSL libcrypto (vetted big-integer / constant-time modular exponentiation
#   for SRP; also libsrtp's AES/HMAC backend) and libsrtp (SRTP/SRTCP).
#
#   ./build-deps.sh            build every slice whose libraries are missing
#   ./build-deps.sh --force    rebuild both slices
#
# Slices (same sources, same options, one SDK each):
#   Vendor/ios-arm64      physical devices          (iphoneos SDK)
#   Vendor/iossim-arm64   Apple-silicon simulators  (iphonesimulator SDK)
# Tarballs are downloaded into Vendor/.work once and ALWAYS verified against the
# SHA-256 values pinned below before anything is unpacked; a mismatch aborts.
# Complete configure/make output is kept in Vendor/build-logs/.
emulate -L zsh                 # first: `emulate` resets options, so it must precede `set`
set -euo pipefail

OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a   # openssl-3.5.9.tar.gz, GitHub release, first download 12 Nov 2026
LIBSRTP_VERSION=2.8.1
LIBSRTP_SHA256=ef5569220749529d778013aae1178391d972570a2b4f7288dda22effa875b07c   # tarball of tag v2.8.1, first download 12 Nov 2026
MIN_IOS=27.0

FORCE=0
case ${1:-} in
  "") ;;
  --force) FORCE=1 ;;
  *) print -u2 "usage: ./build-deps.sh [--force]"; exit 2 ;;
esac

ROOT=${0:A:h}
WORK=$ROOT/Vendor/.work
LOGS=$ROOT/Vendor/build-logs
mkdir -p "$WORK" "$LOGS"
JOBS=$(sysctl -n hw.ncpu)
export ZERO_AR_DATE=1          # archives without member timestamps

fetch_verified() {  # url file sha256
  [[ -f $WORK/$2 ]] || curl -sSfL -o "$WORK/$2" "$1"
  local actual=$(shasum -a 256 "$WORK/$2" | awk '{print $1}')
  if [[ $actual != $3 ]]; then
    print -u2 "$2: SHA-256 mismatch (expected $3, found $actual); refusing to build"
    exit 1
  fi
  print "$2 sha256 $actual (pinned value verified)"
}

fetch_verified "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
  openssl.tar.gz $OPENSSL_SHA256
fetch_verified "https://github.com/cisco/libsrtp/archive/refs/tags/v$LIBSRTP_VERSION.tar.gz" \
  libsrtp.tar.gz $LIBSRTP_SHA256

build_slice() {  # name sdk openssl-target min-version-flag
  local name=$1 sdk=$2 target=$3 minflag=$4
  local out=$ROOT/Vendor/$name src=$WORK/$name log=$LOGS/$name.log
  if (( ! FORCE )) && [[ -f $out/lib/libcrypto.a && -f $out/lib/libsrtp2.a ]]; then
    print "$name: libraries present, not rebuilt (use --force to rebuild)"
    return 0
  fi
  local sdkpath=$(xcrun --sdk $sdk --show-sdk-path)
  local cc=$(xcrun --sdk $sdk -f clang)
  local cflags="-arch arm64 -isysroot $sdkpath $minflag -O2 -fno-common"
  print "$name: building (log: ${log#$ROOT/})"
  # Explicit && chains: errexit does not apply inside a tested command list.
  if ! {
    print "== $name  $(date -u +%Y-%m-%dT%H:%M:%SZ)  sdk=$sdkpath" &&
    print "== $(xcodebuild -version | tr '\n' ' ')  $(xcrun --sdk $sdk clang --version | head -1)" &&
    rm -rf "$src" && mkdir -p "$src" &&
    tar xzf "$WORK/openssl.tar.gz" -C "$src" &&
    ( cd "$src/openssl-$OPENSSL_VERSION" &&
      ./Configure $target no-shared no-apps no-tests no-docs no-engine no-dso \
          no-ui-console no-async no-autoload-config "$minflag" \
          --prefix=/opt/openssl --openssldir=/opt/openssl/ssl &&
      make -j$JOBS build_libs &&
      make DESTDIR="$src/openssl-stage" install_dev ) &&
    tar xzf "$WORK/libsrtp.tar.gz" -C "$src" &&
    ( cd "$src/libsrtp-$LIBSRTP_VERSION" &&
      ./configure --host=aarch64-apple-darwin --enable-openssl --with-openssl-dir="$src/openssl-stage/opt/openssl" \
          CC="$cc" CFLAGS="$cflags" &&
      make -j$JOBS libsrtp2.a ) &&
    print "== $name build completed $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$log" 2>&1; then
    print -u2 "$name: build FAILED, see $log"
    exit 1
  fi
  rm -rf "$out"; mkdir -p "$out/include/srtp2" "$out/lib"
  cp -R "$src/openssl-stage/opt/openssl/include/openssl" "$out/include/"
  cp "$src/openssl-stage/opt/openssl/lib/libcrypto.a" "$out/lib/"
  cp "$src/libsrtp-$LIBSRTP_VERSION/include/srtp.h" "$out/include/srtp2/"
  cp "$src/libsrtp-$LIBSRTP_VERSION/libsrtp2.a" "$out/lib/"
}

build_slice ios-arm64    iphoneos        ios64-xcrun              "-mios-version-min=$MIN_IOS"
build_slice iossim-arm64 iphonesimulator iossimulator-arm64-xcrun "-mios-simulator-version-min=$MIN_IOS"

for lib in "$ROOT"/Vendor/{ios-arm64,iossim-arm64}/lib/*.a; do
  print "${lib#$ROOT/}: $(lipo -archs $lib) $(shasum -a 256 $lib | awk '{print $1}')"
done
