#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../k3sdeploy-latest.sh
source "$ROOT/k3sdeploy-latest.sh"
OS_NAME='Test Linux'
OS_PACKAGE_MANAGER=apt

pass=0
fail=0

assert_ok() {
    if "$@"; then
        ((++pass))
    else
        printf 'FAIL expected success: %s\n' "$*"
        ((++fail))
    fi
}

assert_bad() {
    if "$@"; then
        printf 'FAIL expected failure: %s\n' "$*"
        ((++fail))
    else
        ((++pass))
    fi
}

assert_eq() {
    if [[ "$1" == "$2" ]]; then
        ((++pass))
    else
        printf "FAIL '%s' != '%s'\n" "$1" "$2"
        ((++fail))
    fi
}

command() {
    if [[ "$*" == '-v git' ]]; then
        return "${MOCK_GIT_PRESENT:-1}"
    fi
    builtin command "$@"
}

sudo() {
    printf 'UNEXPECTED_PRIVILEGED_OPERATION\n' >&2
    return 97
}

for response in 'n' 'invalid'; do
    output=$(ensure_git_dependency <<< "$response" 2>&1) && status=0 || status=$?
    if [[ $status -eq 0 ]]; then
        printf 'FAIL expected declined Git installation to return non-zero\n'
        ((++fail))
    elif [[ "$output" == *'Launcher cancelled; Git was not installed.'* &&
        "$output" != *'UNEXPECTED_PRIVILEGED_OPERATION'* ]]; then
        ((++pass))
    else
        printf 'FAIL declined Git installation was not handled safely\n'
        ((++fail))
    fi
done

MOCK_GIT_PRESENT=0
assert_ok ensure_git_dependency
MOCK_GIT_PRESENT=1

sudo() {
    case "$*" in
        'apt-get update'|'apt-get install -y git ca-certificates') return 0 ;;
        *) return 97 ;;
    esac
}
assert_ok ensure_git_dependency <<< 'yes'
assert_ok ensure_git_dependency <<< ''

git() {
    printf '%s\n' \
        'a refs/tags/v0.9.0' \
        'b refs/tags/v1.2.0-rc1' \
        'c refs/tags/v1.2.0' \
        'd refs/tags/v1.10.0' \
        'e refs/tags/nightly'
}
assert_eq "$(latest_stable_tag)" 'v1.10.0'

git() {
    printf '%s\n' 'a refs/tags/v1.2.0-rc1' 'b refs/tags/nightly'
}
assert_eq "$(latest_stable_tag)" ''

assert_ok bash -n "$ROOT/k3sdeploy-latest.sh"

printf '%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
