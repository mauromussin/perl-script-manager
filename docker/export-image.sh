#!/bin/sh
set -eu

mkdir -p image-artifact
docker tag perl-script-manager:ci perl-script-manager:production
docker save --output image-artifact/perl-script-manager.tar perl-script-manager:production
(
    cd image-artifact
    sha256sum perl-script-manager.tar > perl-script-manager.tar.sha256
    sha256sum --check perl-script-manager.tar.sha256
)
docker load --input image-artifact/perl-script-manager.tar
expected=$(docker image inspect perl-script-manager:ci --format '{{.Id}}')
actual=$(docker image inspect perl-script-manager:production --format '{{.Id}}')
if [ "$actual" != "$expected" ]; then
    echo "Exported image does not match the production build." >&2
    exit 1
fi
