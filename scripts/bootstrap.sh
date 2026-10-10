#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor="$root/Vendor"
cache="$root/.cache"
mkdir -p "$vendor" "$cache"

download() {
  local url="$1" output="$2"
  if [[ ! -f "$output" ]]; then
    curl --fail --location --retry 3 --output "$output" "$url"
  fi
}

verify() {
  local expected="$1" file="$2"
  printf '%s  %s\n' "$expected" "$file" | shasum -a 256 -c -
}

i2pd_commit=ca007dc57dad3ea743e018ed7f652a8671ec8bed
if [[ ! -d "$vendor/i2pd" ]]; then
  git clone --filter=blob:none https://github.com/PurpleI2P/i2pd.git "$vendor/i2pd"
  git -C "$vendor/i2pd" checkout --detach "$i2pd_commit"
  git -C "$vendor/i2pd" apply "$root/patches/i2pd-ios.patch"
  touch "$vendor/i2pd/.ios-patch-applied"
elif [[ ! -f "$vendor/i2pd/.ios-patch-applied" ]]; then
  echo "Incomplete i2pd checkout. Remove Vendor/i2pd and rerun bootstrap." >&2
  exit 1
fi

boost_archive="$cache/boost_1_86_0.tar.gz"
if [[ ! -f "$vendor/Boost/boost/version.hpp" ]]; then
  download https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.gz "$boost_archive"
  verify 2575e74ffc3ef1cd0babac2c1ee8bdb5782a0ee672b1912da40e5b4b591ca01f "$boost_archive"
  tar -xzf "$boost_archive" -C "$cache"
  mv "$cache/boost_1_86_0" "$vendor/Boost"
fi

openssl_archive="$cache/openssl-3.5.8.tar.gz"
openssl_source="$cache/openssl-3.5.8"
if [[ ! -f "$vendor/OpenSSL/iphoneos/libssl.a" || ! -f "$vendor/OpenSSL/iphonesimulator/libssl.a" ]]; then
  download https://www.openssl.org/source/openssl-3.5.8.tar.gz "$openssl_archive"
  verify a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2 "$openssl_archive"
  if [[ ! -d "$openssl_source" ]]; then
    tar -xzf "$openssl_archive" -C "$cache"
  fi
  jobs="$(sysctl -n hw.ncpu)"
  for platform in iphoneos iphonesimulator; do
    target="$vendor/OpenSSL/$platform"
    if [[ -f "$target/libssl.a" && -f "$target/libcrypto.a" ]]; then continue; fi
    if [[ "$platform" == iphoneos ]]; then configure_target=ios64-xcrun
    else configure_target=iossimulator-arm64-xcrun; fi
    build="$cache/openssl-build-$platform"
    install="$cache/openssl-install-$platform"
    mkdir -p "$build" "$install" "$target"
    (
      cd "$build"
      "$openssl_source/Configure" "$configure_target" no-shared no-tests no-apps no-module \
        "--prefix=$install" --libdir=lib
      make -j "$jobs"
      make install_sw
    )
    mkdir -p "$target/include"
    cp -R "$install/include/." "$target/include/"
    cp "$install/lib/libssl.a" "$install/lib/libcrypto.a" "$target/"
  done
fi

mkdir -p "$cache/swift-module-cache"
swift -module-cache-path "$cache/swift-module-cache" "$root/scripts/render-icon.swift" \
  "$root/Assets/i2pd_logo_2_icon.svg" \
  "$root/Sources/I2PDApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

if command -v xcodegen >/dev/null; then
  (cd "$root" && xcodegen generate)
else
  echo "Dependencies are ready. Install XcodeGen, then run 'xcodegen generate' here."
fi
