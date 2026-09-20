#!/usr/bin/env bash
[[ -n ${K3S_BOOTSTRAP_COMMON_LOADED:-} ]] && return 0
readonly K3S_BOOTSTRAP_COMMON_LOADED=1
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); readonly PROJECT_ROOT
VERSION=$(<"$PROJECT_ROOT/VERSION"); readonly VERSION; export VERSION
DRY_RUN=${DRY_RUN:-false}; VERBOSE=${VERBOSE:-false}; ASSUME_YES=${ASSUME_YES:-false}
K3SDEPLOY_FORCE_COLOR=${K3SDEPLOY_FORCE_COLOR:-false}
if [[ -t 1 ]]; then K3SDEPLOY_STDOUT_IS_TTY=true; else K3SDEPLOY_STDOUT_IS_TTY=false; fi
INSTALL_PROFILE=${INSTALL_PROFILE:-recommended}
LOAD_BALANCER_MODE=${LOAD_BALANCER_MODE:-metallb}
STORAGE_PROVIDER=${STORAGE_PROVIDER:-longhorn}
LOG_FILE=${LOG_FILE:-/var/log/k3s-bootstrap/k3s-bootstrap-$(date +%Y%m%d-%H%M%S).log}
STATE_FILE=${STATE_FILE:-/etc/k3s-bootstrap/config}
CONFIG_FILE=${CONFIG_FILE:-/etc/rancher/k3s/config.yaml}
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

detect_operating_system(){
  local os_release=${OS_RELEASE_FILE:-/etc/os-release} os_name
  OS_ID=$(os_release_value ID "$os_release"); OS_ID=${OS_ID:-unknown}
  OS_ID_LIKE=$(os_release_value ID_LIKE "$os_release")
  os_name=$(os_release_value PRETTY_NAME "$os_release")
  [[ -n $os_name ]] || os_name=$(os_release_value NAME "$os_release")
  OS_NAME=${os_name:-Unknown Linux}
  OS_VERSION_ID=$(os_release_value VERSION_ID "$os_release"); OS_VERSION_ID=${OS_VERSION_ID:-unknown}
  if command -v apt-get >/dev/null 2>&1; then OS_PACKAGE_MANAGER=apt
  elif command -v dnf >/dev/null 2>&1; then OS_PACKAGE_MANAGER=dnf
  elif command -v yum >/dev/null 2>&1; then OS_PACKAGE_MANAGER=yum
  elif command -v zypper >/dev/null 2>&1; then OS_PACKAGE_MANAGER=zypper
  else OS_PACKAGE_MANAGER=unsupported
  fi
  export OS_ID OS_ID_LIKE OS_NAME OS_VERSION_ID OS_PACKAGE_MANAGER
}

os_release_value(){
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

package_refresh(){
  case ${OS_PACKAGE_MANAGER:-unsupported} in
    apt) as_root apt-get update;;
    dnf) as_root dnf -y makecache;;
    yum) as_root yum -y makecache;;
    zypper) as_root zypper --non-interactive refresh;;
    *) die "Automatic package installation is not supported on ${OS_NAME:-this operating system}. Install the requested dependency manually, then retry.";;
  esac
}

package_install(){
  (($#)) || return 0
  case ${OS_PACKAGE_MANAGER:-unsupported} in
    apt) as_root apt-get install -y "$@";;
    dnf) as_root dnf install -y "$@";;
    yum) as_root yum install -y "$@";;
    zypper) as_root zypper --non-interactive install --auto-agree-with-licenses "$@";;
    *) die "Automatic package installation is not supported on ${OS_NAME:-this operating system}. Install these packages manually: $*";;
  esac
}

package_for(){
  case $1:${OS_PACKAGE_MANAGER:-unsupported} in
    arping:apt) printf 'iputils-arping\n';;
    arping:dnf|arping:yum|arping:zypper) printf 'iputils\n';;
    iscsi:dnf|iscsi:yum) printf 'iscsi-initiator-utils\n';;
    iscsi:apt|iscsi:zypper) printf 'open-iscsi\n';;
    nfs:apt) printf 'nfs-common\n';;
    nfs:dnf|nfs:yum) printf 'nfs-utils\n';;
    nfs:zypper) printf 'nfs-client\n';;
    *) return 1;;
  esac
}

terminal_colours(){
  [[ $K3SDEPLOY_STDOUT_IS_TTY == true && ${TERM:-dumb} != dumb ]] || return 1
  [[ $K3SDEPLOY_FORCE_COLOR == true || -z ${NO_COLOR:-} ]]
}
interactive_terminal(){ [[ -t 0 && -t 1 && ${TERM:-dumb} != dumb && ${K3SDEPLOY_PLAIN_MENU:-0} != 1 ]]; }
colour() { terminal_colours && printf '\033[%sm' "$1" || true; }
explain_colour_mode(){
  if [[ $K3SDEPLOY_STDOUT_IS_TTY == true && ${TERM:-dumb} != dumb && -n ${NO_COLOR:-} && $K3SDEPLOY_FORCE_COLOR != true ]]; then
    printf '%s\n' '[K3SDEPLOY] Colours are disabled because NO_COLOR is set. Run with --color to override it for this session.'
  fi
}
log() { local level=$1 colour_code=$2; shift 2; printf '%s[%s] %-6s%s %s\n' "$(colour "$colour_code")" "$(date '+%F %T')" "$level" "$(colour 0)" "$*"; [[ -w ${LOG_FILE%/*} ]] && printf '[%s] %-6s %s\n' "$(date '+%F %T')" "$level" "$*" >>"$LOG_FILE" || true; }
info(){ log INFO 96 "$*"; }; ok(){ log OK 92 "$*"; }; warn(){ log WARN '38;5;208' "$*"; }; error(){ log ERROR '1;91' "$*"; }; skip(){ log SKIP 94 "$*"; }; change(){ log CHANGE 95 "$*"; }
section(){ local title=$1 rule yellow reset; printf -v rule '%*s' "${#title}" ''; yellow=$(colour '1;33'); reset=$(colour 0); printf '\n%b%s\n%s%b\n\n' "$yellow" "$title" "${rule// /-}" "$reset"; }
render_menu_options(){
  local selected=$1; shift
  local index=1 option display yellow reset max_width=$(( ${COLUMNS:-80} - 10 ))
  ((max_width < 30)) && max_width=30
  yellow=$(colour '1;33'); reset=$(colour 0)
  for option in "$@"; do
    display=$option
    ((${#display} > max_width)) && display="${display:0:max_width-1}…"
    printf '\033[2K\r'
    if ((index == selected)); then
      printf '%b  ❯ %d. %s%b\n' "$yellow" "$index" "$display" "$reset"
    else
      printf '    %d. %s\n' "$index" "$display"
    fi
    index=$((index+1))
  done
}
menu_select(){
  local _menu_target=$1 _menu_prompt=$2 _menu_default=$3; shift 3
  local -a _menu_options=("$@")
  local _menu_selected=$_menu_default _menu_key _menu_rest= _menu_count=${#_menu_options[@]} _menu_index
  ((_menu_count > 0)) || return 1
  if ! interactive_terminal; then
    for ((_menu_index=0; _menu_index<_menu_count; _menu_index++)); do printf '  %d. %s\n' "$((_menu_index+1))" "${_menu_options[_menu_index]}"; done
    printf '\n'
    read -r -p "$_menu_prompt [$_menu_default]: " _menu_selected
    _menu_selected=${_menu_selected:-$_menu_default}
    printf -v "$_menu_target" '%s' "$_menu_selected"
    return 0
  fi

  printf '%s\n\n' '  Use ↑/↓ (or j/k) to move. Press Enter or Space to select.'
  render_menu_options "$_menu_selected" "${_menu_options[@]}"
  while true; do
    IFS= read -rsn1 _menu_key || return 1
    if [[ $_menu_key == $'\033' ]]; then
      IFS= read -rsn2 -t 0.2 _menu_rest || true
      _menu_key+=$_menu_rest
    fi
    case $_menu_key in
      $'\033[A'|k|K) ((_menu_selected > 1)) && _menu_selected=$((_menu_selected-1));;
      $'\033[B'|j|J) ((_menu_selected < _menu_count)) && _menu_selected=$((_menu_selected+1));;
      '') break;;
      ' ') break;;
      [1-9]) ((_menu_key <= _menu_count)) && _menu_selected=$_menu_key;;
      *) continue;;
    esac
    printf '\033[%dA' "$_menu_count"
    render_menu_options "$_menu_selected" "${_menu_options[@]}"
  done
  printf -v "$_menu_target" '%s' "$_menu_selected"
  printf '\n'
}
show_banner(){
  local yellow= reset=
  yellow=$(colour '1;33'); reset=$(colour 0)
  printf '%b' "$yellow"
  cat <<'EOF'
 _  __ _____      ____             _
| |/ /|___ / ___ |  _ \  ___ _ __ | | ___  _   _
| ' /   |_ \/ __|| | | |/ _ \ '_ \| |/ _ \| | | |
| . \  ___) \__ \| |_| |  __/ |_) | | (_) | |_| |
|_|\_\|____/|___/|____/ \___| .__/|_|\___/ \__, |
                             |_|             |___/
EOF
  printf '\n[K3SDEPLOY] Launching K3sDeploy %s...\n' "$VERSION"
  printf 'Safe, guided K3s cluster installation and node management\n%b' "$reset"
}
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
  local current=$1 total=$2 title=$3 width=24 filled empty bar empty_bar yellow reset
  filled=$((current*width/total)); empty=$((width-filled))
  printf -v bar '%*s' "$filled" ''; bar=${bar// /#}
  printf -v empty_bar '%*s' "$empty" ''; bar+="${empty_bar// /-}"
  yellow=$(colour '1;33'); reset=$(colour 0)
  printf '\n%b+----------------------------------------------------------+\n' "$yellow"
  printf '| K3sDeploy %-14s[%s] %2d/%-2d |\n' "$VERSION" "$bar" "$current" "$total"
  printf '| %-56s |\n' "$title"
  printf '+----------------------------------------------------------+%b\n' "$reset"
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
  while true; do
    read -r -p "$prompt: " value
    [[ -n $value ]] && break
    warn "$prompt cannot be empty; please try again."
  done
  printf -v "$var" '%s' "$value"
}
ensure_log(){ if [[ $EUID -eq 0 ]]; then mkdir -p "${LOG_FILE%/*}"; touch "$LOG_FILE"; chmod 600 "$LOG_FILE"; elif sudo -n true 2>/dev/null; then sudo mkdir -p "${LOG_FILE%/*}"; sudo touch "$LOG_FILE"; sudo chmod 600 "$LOG_FILE"; fi; }
