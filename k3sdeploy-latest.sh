#!/usr/bin/env bash

# K3sDeploy latest stable-release bootstrapper.
# This file is also published at https://cyberpoe.uk/k3sdeploy-latest.

set -Eeuo pipefail

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
if [[ ! -t 1 || ${TERM:-dumb} == dumb || -n ${NO_COLOR:-} ]]; then YELLOW=; GREEN=; RED=; NC=; fi

readonly REPOSITORY_URL="${K3S_DEPLOY_REPOSITORY_URL:-https://github.com/cyberpoe-uk/K3sDeploy.git}"
TEMP_DIR=""

info() { printf '%b\n' "${YELLOW}[K3SDEPLOY]${NC} $*"; }
success() { printf '%b\n' "${GREEN}[SUCCESS]${NC} $*"; }
die() { printf '%b\n' "${RED}[ERROR]${NC} $*" >&2; exit 1; }

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && "$TEMP_DIR" == /tmp/k3sdeploy-installer-* ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

detect_operating_system() {
    local os_release=${OS_RELEASE_FILE:-/etc/os-release} os_name
    [[ -r $os_release ]] || return 1
    os_name=$(os_release_value PRETTY_NAME "$os_release")
    [[ -n $os_name ]] || os_name=$(os_release_value NAME "$os_release")
    OS_NAME=${os_name:-Unknown Linux}
    if command -v apt-get >/dev/null 2>&1; then OS_PACKAGE_MANAGER=apt
    elif command -v dnf >/dev/null 2>&1; then OS_PACKAGE_MANAGER=dnf
    elif command -v yum >/dev/null 2>&1; then OS_PACKAGE_MANAGER=yum
    elif command -v zypper >/dev/null 2>&1; then OS_PACKAGE_MANAGER=zypper
    else OS_PACKAGE_MANAGER=unsupported
    fi
    export OS_NAME OS_PACKAGE_MANAGER
}

os_release_value() {
    local key=$1 file=${2:-/etc/os-release}
    [[ -r $file ]] || return 0
    awk -v key="$key" '
        index($0, key "=") == 1 {
            value=substr($0, length(key)+2)
            if (value ~ /^".*"$/) { sub(/^"/, "", value); sub(/"$/, "", value) }
            else if (value ~ /^\047.*\047$/) { sub(/^\047/, "", value); sub(/\047$/, "", value) }
            gsub(/\\"/, "\"", value)
            print value
            exit
        }
    ' "$file"
}

package_refresh() {
    case "${OS_PACKAGE_MANAGER:-unsupported}" in
        apt) sudo apt-get update ;;
        dnf) sudo dnf -y makecache ;;
        yum) sudo yum -y makecache ;;
        zypper) sudo zypper --non-interactive refresh ;;
        *) die "Automatic Git installation is not supported on ${OS_NAME:-this operating system}. Install Git and CA certificates manually, then rerun the installer." ;;
    esac
}

package_install_git() {
    case "${OS_PACKAGE_MANAGER:-unsupported}" in
        apt) sudo apt-get install -y git ca-certificates ;;
        dnf) sudo dnf install -y git ca-certificates ;;
        yum) sudo yum install -y git ca-certificates ;;
        zypper) sudo zypper --non-interactive install --auto-agree-with-licenses git ca-certificates ;;
        *) die "Automatic Git installation is not supported on ${OS_NAME:-this operating system}. Install Git and CA certificates manually, then rerun the installer." ;;
    esac
}

ensure_git_dependency() {
    local answer

    [[ -n ${OS_PACKAGE_MANAGER:-} ]] || detect_operating_system

    if command -v git >/dev/null 2>&1; then
        success "Git is available."
        return 0
    fi

    info "Git is needed to download the latest tagged K3sDeploy release."
    info "With your approval, ${OS_NAME} will install Git before the K3sDeploy menu opens."
    info "sudo may request your password; the launcher itself continues as your normal user."
    if ! read -rp "Install Git and continue? [Y/n]: " answer ||
        [[ -n "$answer" && ! "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
        info "Launcher cancelled; Git was not installed."
        return 1
    fi

    package_refresh || die "${OS_NAME} package information could not be refreshed."
    package_install_git || die "Git installation failed on ${OS_NAME}."
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
    local tag release_version argument
    trap cleanup EXIT

    for argument in "$@"; do
        if [[ $argument == --no-color ]]; then YELLOW=; GREEN=; RED=; NC=; break; fi
    done

    info "Starting the K3sDeploy launcher."
    info "It will download the latest stable tagged release and open its interactive menu."

    detect_operating_system || die "K3sDeploy could not identify this operating system from /etc/os-release."
    [[ $OS_PACKAGE_MANAGER != unsupported ]] || die "K3sDeploy detected $OS_NAME, but automatic dependency installation supports apt, dnf, yum, and zypper. Install Git manually or use a supported system."
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
