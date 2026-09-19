#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../config/defaults.env
source "$ROOT/config/defaults.env"
# shellcheck source=../lib/validation.sh
source "$ROOT/lib/validation.sh"
# shellcheck source=../lib/longhorn.sh
source "$ROOT/lib/longhorn.sh"

detect_operating_system
require_privileges
confirm 'Run the temporary Longhorn provisioning and persistence smoke test?' || exit 0
run_longhorn_smoke
