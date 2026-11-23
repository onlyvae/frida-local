#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
version=${1:?Frida version required}
if [ "$version" != 17.27.4 ]; then
    echo 'Update the release checksums before changing the Frida version.' >&2
    exit 1
fi
base="https://github.com/frida/frida/releases/download/$version"
mkdir -p .deps/downloads

fetch() {
    base=$1
    asset=$2
    checksum=$3
    destination=$4
    if ! printf '%s  %s\n' "$checksum" "$destination" | shasum -a 256 -c - >/dev/null 2>&1; then
        temporary=$(mktemp "${destination}.XXXXXX")
        trap 'rm -f "$temporary"' EXIT HUP INT TERM
        curl --fail --location --retry 2 "$base/$asset" -o "$temporary"
        printf '%s  %s\n' "$checksum" "$temporary" | shasum -a 256 -c -
        mv "$temporary" "$destination"
        trap - EXIT HUP INT TERM
    fi
}

fetch "$base" "frida-core-devkit-$version-ios-arm64.tar.xz" \
    b6131aba2c14fcbd41e4c04dc5e0801bb263b0c2ff417f2561ff0303bb186c27 .deps/downloads/core.tar.xz
fetch "$base" "frida_${version}_iphoneos-arm64.deb" \
    3c6af43b48202ac1c9824dcafc393087e0080cf7486738f80b36b9170c5df232 .deps/downloads/server.deb

fetch "https://github.com/frida/frida/releases/download/16.7.19" "frida-core-devkit-16.7.19-ios-arm64.tar.xz" \
    90bca1ae4e8f0de1bcd70ce9f8e4f1e4635b5d9ef1c5af97b10880a7bc26c365 .deps/downloads/core-16.7.19.tar.xz

mkdir -p .deps/core .deps/core-16 .deps/server
tar -xf .deps/downloads/core-16.7.19.tar.xz -C .deps/core-16
tar -xf .deps/downloads/core.tar.xz -C .deps/core
dpkg-deb -x .deps/downloads/server.deb .deps/server
