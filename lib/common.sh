#!/usr/bin/env bash
[[ -n ${K3S_BOOTSTRAP_COMMON_LOADED:-} ]] && return 0
readonly K3S_BOOTSTRAP_COMMON_LOADED=1
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); readonly PROJECT_ROOT
VERSION=$(<"$PROJECT_ROOT/VERSION"); readonly VERSION; export VERSION
DRY_RUN=${DRY_RUN:-false}; VERBOSE=${VERBOSE:-false}; ASSUME_YES=${ASSUME_YES:-false}
LOG_FILE=${LOG_FILE:-/var/log/k3s-bootstrap/k3s-bootstrap-$(date +%Y%m%d-%H%M%S).log}
STATE_FILE=${STATE_FILE:-/etc/k3s-bootstrap/config}
CONFIG_FILE=${CONFIG_FILE:-/etc/rancher/k3s/config.yaml}
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

colour() { [[ -t 1 ]] && printf '\033[%sm' "$1" || true; }
log() { local level=$1 colour_code=$2; shift 2; printf '%s[%s] %-6s%s %s\n' "$(colour "$colour_code")" "$(date '+%F %T')" "$level" "$(colour 0)" "$*"; [[ -w ${LOG_FILE%/*} ]] && printf '[%s] %-6s %s\n' "$(date '+%F %T')" "$level" "$*" >>"$LOG_FILE" || true; }
info(){ log INFO 36 "$*"; }; ok(){ log OK 32 "$*"; }; warn(){ log WARN 33 "$*"; }; error(){ log ERROR 31 "$*"; }; skip(){ log SKIP 34 "$*"; }; change(){ log CHANGE 35 "$*"; }
die(){ error "$*"; exit 1; }
on_error(){ local rc=$? line=$1; error "Failed at line $line (exit $rc). Log: $LOG_FILE"; exit "$rc"; }
confirm(){ local prompt=${1:-Proceed?}; $ASSUME_YES && return 0; read -r -p "$prompt [y/N] " reply; [[ $reply =~ ^[Yy]([Ee][Ss])?$ ]]; }
confirm_yes(){ local prompt=${1:-Continue?}; $ASSUME_YES && return 0; read -r -p "$prompt [Y/n] " reply; [[ -z $reply || $reply =~ ^[Yy]([Ee][Ss])?$ ]]; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
require_privileges(){
  [[ $EUID -eq 0 ]] && { info "Running as root; no sudo authentication is needed"; ensure_log; return; }
  need_cmd sudo
  info "Administrator access is required for system packages, services and protected configuration."
  info "The main installer remains your normal user; sudo is used only for privileged operations."
  sudo -v || die "Could not obtain sudo access"
  ensure_log
}
phase(){
  local current=$1 total=$2 title=$3 width=24 filled empty bar empty_bar
  filled=$((current*width/total)); empty=$((width-filled))
  printf -v bar '%*s' "$filled" ''; bar=${bar// /#}
  printf -v empty_bar '%*s' "$empty" ''; bar+="${empty_bar// /-}"
  printf '\n+----------------------------------------------------------+\n'
  printf '| K3s Bootstrap %-8s  [%s] %2d/%-2d |\n' "$VERSION" "$bar" "$current" "$total"
  printf '| %-56s |\n' "$title"
  printf '+----------------------------------------------------------+\n'
}
short_hostname(){
  local name
  if command -v hostname >/dev/null 2>&1; then
    hostname -s
    return
  fi
  if command -v hostnamectl >/dev/null 2>&1; then
    name=$(hostnamectl --static 2>/dev/null || true)
  fi
  [[ -n ${name:-} ]] || name=$(uname -n)
  printf '%s\n' "${name%%.*}"
}
run(){ if $DRY_RUN; then change "Would run: $*"; return 0; fi; $VERBOSE && info "Running: $*"; "$@"; }
run_secret(){ if $DRY_RUN; then change "Would run a command containing redacted credentials"; return 0; fi; "$@"; }
as_root(){ if [[ $EUID -eq 0 ]]; then run "$@"; else run sudo "$@"; fi; }
as_root_capture(){ if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
backup_file(){ local f=$1 b; [[ -e $f ]] || return 0; b="$f.backup-$(date +%Y%m%d-%H%M%S)"; as_root cp -a -- "$f" "$b"; info "Backed up $f to $b"; }
write_root_file(){ local target=$1 mode=$2 content=$3 tmp; tmp=$(mktemp); printf '%s' "$content" >"$tmp"; if [[ -f $target ]] && cmp -s "$tmp" "$target"; then rm -f "$tmp"; skip "$target already correct"; return 1; fi; backup_file "$target"; if $DRY_RUN; then change "Would write $target (mode $mode)"; rm -f "$tmp"; return 0; fi; as_root install -D -o root -g root -m "$mode" "$tmp" "$target"; rm -f "$tmp"; change "Updated $target"; }
validate_ipv4(){ local ip=$1 IFS=. o; read -ra o <<<"$ip"; [[ ${#o[@]} -eq 4 ]] || return 1; for n in "${o[@]}"; do [[ $n =~ ^[0-9]+$ && $n -le 255 && ! ($n =~ ^0[0-9]+$) ]] || return 1; done; }
ip_to_int(){ local IFS=. a b c d; read -r a b c d <<<"$1"; printf '%u' "$((a*16777216+b*65536+c*256+d))"; }
ip_in_range(){ local x s e; x=$(ip_to_int "$1"); s=$(ip_to_int "$2"); e=$(ip_to_int "$3"); (( x>=s && x<=e )); }
same_subnet(){ local a=$1 b=$2 prefix=${3:-24}; (( prefix == 24 )) && [[ ${a%.*} == "${b%.*}" ]]; }
prompt_default(){ local var=$1 prompt=$2 default=$3 value; read -r -p "$prompt [$default]: " value; printf -v "$var" '%s' "${value:-$default}"; }
prompt_required(){
  local var=$1 prompt=$2 value
  read -r -p "$prompt: " value
  [[ -n $value ]] || die "$prompt cannot be empty"
  printf -v "$var" '%s' "$value"
}
ensure_log(){ if [[ $EUID -eq 0 ]]; then mkdir -p "${LOG_FILE%/*}"; touch "$LOG_FILE"; chmod 600 "$LOG_FILE"; elif sudo -n true 2>/dev/null; then sudo mkdir -p "${LOG_FILE%/*}"; sudo touch "$LOG_FILE"; sudo chmod 600 "$LOG_FILE"; fi; }
