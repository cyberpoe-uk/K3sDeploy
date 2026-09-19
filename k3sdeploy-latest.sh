#!/usr/bin/env bash

# K3sDeploy latest stable-release bootstrapper.
# This file is also published at https://cyberpoe.uk/k3sdeploy-latest.

set -Eeuo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

readonly REPOSITORY_URL="${K3S_DEPLOY_REPOSITORY_URL:-https://github.com/cyberpoe-uk/K3sDeploy.git}"
TEMP_DIR=""

info() { printf '%b\n' "${BLUE}[K3SDEPLOY]${NC} $*"; }
success() { printf '%b\n' "${GREEN}[SUCCESS]${NC} $*"; }
die() { printf '%b\n' "${RED}[ERROR]${NC} $*" >&2; exit 1; }

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && "$TEMP_DIR" == /tmp/k3sdeploy-installer-* ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

is_ubuntu() {
    [[ -r /etc/os-release ]] || return 1
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == ubuntu ]]
}

ensure_git_dependency() {
    local answer

    if command -v git >/dev/null 2>&1; then
        success "Git is available."
        return 0
    fi

    info "Git is needed to download the latest tagged K3sDeploy release."
    info "With your approval, Ubuntu will install Git before the K3sDeploy menu opens."
    info "sudo may request your password; the launcher itself continues as your normal user."
    if ! read -rp "Install Git and continue? [y/N]: " answer ||
        [[ ! "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
        info "Launcher cancelled; Git was not installed."
        return 1
    fi

    sudo apt-get update || die "Ubuntu package information could not be refreshed."
    sudo apt-get install -y git ca-certificates || die "Git installation failed."
}

latest_stable_tag() {
    local remote_tags

    remote_tags=$(git ls-remote --tags --refs "$REPOSITORY_URL") ||
        die "Could not read release tags from ${REPOSITORY_URL}."

    awk '{
        sub("refs/tags/", "", $2)
        if ($2 ~ /^v?[0-9]+\.[0-9]+\.[0-9]+$/) print $2
    }' <<< "$remote_tags" |
        sort -V |
        tail -n 1
}

main() {
    local tag release_version
    trap cleanup EXIT

    info "Starting the K3sDeploy launcher."
    info "It will download the latest stable tagged release and open its interactive menu."

    is_ubuntu || die "K3sDeploy currently supports Ubuntu Server only."
    [[ $EUID -ne 0 ]] ||
        die "Run this launcher as a normal user, without sudo. K3sDeploy requests sudo only when needed."
    command -v sudo >/dev/null 2>&1 ||
        die "sudo is required. Add this user to the sudo group before running K3sDeploy."

    ensure_git_dependency || return 0

    info "Finding the latest stable K3sDeploy release..."
    tag=$(latest_stable_tag)
    [[ -n "$tag" ]] ||
        die "No stable version tag was found. A maintainer must publish a tag such as v0.1.0."
    info "Latest stable release: ${tag}"

    TEMP_DIR=$(mktemp -d -t k3sdeploy-installer-XXXXXX)
    info "Downloading ${tag} to a temporary directory..."
    git clone \
        --depth=1 \
        --branch "$tag" \
        -c advice.detachedHead=false \
        "$REPOSITORY_URL" \
        "$TEMP_DIR" || die "K3sDeploy ${tag} could not be downloaded."

    [[ -r "$TEMP_DIR/VERSION" ]] || die "The downloaded release has no VERSION file."
    [[ -r "$TEMP_DIR/k3s-bootstrap.sh" ]] ||
        die "The downloaded release has no k3s-bootstrap.sh entry point."

    release_version=$(tr -d '[:space:]' < "$TEMP_DIR/VERSION")
    [[ -n "$release_version" ]] || die "The downloaded release has an empty VERSION file."
    [[ "${release_version#v}" == "${tag#v}" ]] ||
        die "Release verification failed: tag ${tag} does not match VERSION ${release_version}."

    info "Launching K3sDeploy ${release_version} as user $(id -un)..."
    bash "$TEMP_DIR/k3s-bootstrap.sh" "$@"
    success "K3sDeploy ${release_version} finished."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
