#!/usr/bin/env bash
# Build the on-router tailscale-router image — buildx loads it into the
# local docker daemon, then skopeo converts it to a docker-archive .tar
# that RouterOS /container can ingest. Buildx's own
# `--output type=docker,dest=...` writes OCI-layout instead, which
# RouterOS rejects with "could not load next layer".
#
# Skopeo: https://github.com/containers/skopeo
#   macOS:        brew install skopeo
#   Debian/Ubuntu: apt install skopeo
#   Fedora/RHEL:   dnf install skopeo
#   Arch:          pacman -S skopeo
#   Alpine:        apk add skopeo
#   From source:   see the install guide in the repo above
#
# Versions are pinned to upstream Tailscale's go.mod:
#   - Tailscale v1.96.5  (go.mod declares `go 1.26.1`)
#   - Go        1.26.1   (matches Tailscale's declared toolchain)
#   - Alpine    3.22     (matches the runtime stage)
#
# When bumping TAILSCALE_VERSION, re-check the upstream go.mod and bump
# GO_VERSION to match — Tailscale tracks Go releases tightly and a stale
# Go can break the build with `undefined: <newer stdlib symbol>`.
#
# Architecture: linux/arm/v7 for the RB3011. To target a different model,
# change PLATFORM (and ensure QEMU emulation is registered if cross-building).

set -euo pipefail

PLATFORM="${PLATFORM:-linux/arm/v7}"
IMAGE_NAME="${IMAGE_NAME:-mikrotik-tailscale-router}"
TAILSCALE_VERSION="${TAILSCALE_VERSION:-1.96.5}"
GO_VERSION="${GO_VERSION:-1.26.1}"
ALPINE_VERSION="${ALPINE_VERSION:-3.22}"
BUILDER="${BUILDER:-tailscale-router-builder}"
TAR_OUT="${TAR_OUT:-tailscale-router.tar}"

cd "$(dirname "$0")"

# Ensure a buildx builder exists (idempotent)
if ! docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
    docker buildx create --name "${BUILDER}" --use
else
    docker buildx use "${BUILDER}"
fi

docker buildx build \
    --no-cache \
    --build-arg "TAILSCALE_VERSION=${TAILSCALE_VERSION}" \
    --build-arg "GO_VERSION=${GO_VERSION}" \
    --build-arg "ALPINE_VERSION=${ALPINE_VERSION}" \
    --platform "${PLATFORM}" \
    --load \
    -t "${IMAGE_NAME}:${TAILSCALE_VERSION}" \
    .

if command -v skopeo >/dev/null 2>&1; then
    rm -f "${TAR_OUT}"
    skopeo copy "docker-daemon:${IMAGE_NAME}:${TAILSCALE_VERSION}" \
                "docker-archive:${TAR_OUT}"
    echo "Built ${TAR_OUT} for ${PLATFORM}"
    ls -lh "${TAR_OUT}"
else
    echo "skopeo not installed; skipping tar export."
    echo "Install: https://github.com/containers/skopeo (e.g. 'brew install skopeo' on macOS)"
fi
