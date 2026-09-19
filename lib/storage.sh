#!/usr/bin/env bash

readonly LONGHORN_STANDARD_PATH=/var/lib/longhorn
export STORAGE_MODE STORAGE_DEVICE STORAGE_DEVICE_MAJMIN STORAGE_DESCRIPTION LONGHORN_PATH LONGHORN_DEVICE_UUID

gib_from_bytes(){ awk -v bytes="$1" 'BEGIN { printf "%d", bytes / 1073741824 }'; }
capacity_meets_minimum(){ (( $1 >= $2 )); }

show_storage(){
  if [[ ! -e $1 && $DRY_RUN == true ]]; then change "Would inspect filesystem capacity for $1"; return; fi
  df -hT "$1"
  findmnt -T "$1" -o SOURCE,FSTYPE,SIZE,USED,AVAIL,TARGET
}

root_source_device(){ findmnt -no SOURCE / | head -1; }

root_parent_disk(){
  local device parent
  device=$(readlink -f "$(root_source_device)")
  [[ -b $device ]] || return 1
  while parent=$(lsblk -ndo PKNAME "$device" 2>/dev/null) && [[ -n $parent ]]; do device="/dev/$parent"; done
  printf '%s\n' "$device"
}

root_capacity_gib(){
  local bytes
  bytes=$(df -B1 --output=size / | awk 'NR==2{print $1}')
  gib_from_bytes "$bytes"
}

root_available_gib(){
  local bytes
  bytes=$(df -B1 --output=avail / | awk 'NR==2{print $1}')
  gib_from_bytes "$bytes"
}

block_capacity_gib(){ gib_from_bytes "$(lsblk -bdno SIZE "$1")"; }

list_disks(){
  printf '\nAvailable block devices (nothing is selected automatically):\n'
  lsblk -e7 -o NAME,MODEL,SIZE,TYPE,FSTYPE,MOUNTPOINTS
}

require_storage_inspection_tools(){ local cmd; for cmd in awk df findmnt lsblk readlink; do need_cmd "$cmd"; done; }

ensure_parted_for_planning(){
  command -v parted >/dev/null 2>&1 && return
  $DRY_RUN && die "Option 2 needs the 'parted' package to inspect unallocated space. Install it, then repeat the dry run."
  confirm "Install the standard 'parted' package to inspect unallocated space safely?" || die "Cannot plan a new partition without parted"
  as_root apt-get update
  as_root apt-get install -y parted
  need_cmd parted
}

ensure_storage_preparation_tools(){
  local missing=false cmd
  for cmd in blkid mkfs.ext4 parted partprobe udevadm; do command -v "$cmd" >/dev/null 2>&1 || missing=true; done
  if $missing; then
    info "Installing standard Ubuntu disk tools (parted, e2fsprogs, util-linux) before storage preparation"
    as_root apt-get update
    as_root apt-get install -y parted e2fsprogs util-linux
  fi
  for cmd in blkid mkfs.ext4 parted partprobe udevadm; do need_cmd "$cmd"; done
}

partition_table_type(){ as_root_capture parted -m -s "$1" unit B print | awk -F: 'NR==2{print $6}'; }

parse_largest_free_region(){
  awk -F: '
    $5 == "free;" {
      gsub(/B/, "", $2); gsub(/B/, "", $3); gsub(/B/, "", $4)
      if ($4 > largest) { start=$2; end=$3; largest=$4 }
    }
    END { if (largest > 0) print start, end, largest }
  '
}

largest_free_region(){ as_root_capture parted -m -s "$1" unit B print free | parse_largest_free_region; }

range_is_still_free(){
  local disk=$1 wanted_start=$2 wanted_end=$3
  as_root_capture parted -m -s "$disk" unit B print free | awk -F: -v wanted_start="$wanted_start" -v wanted_end="$wanted_end" '
    $5 == "free;" {
      gsub(/B/, "", $2); gsub(/B/, "", $3)
      if (wanted_start >= $2 && wanted_end <= $3) found=1
    }
    END { exit(found ? 0 : 1) }
  '
}

partition_path(){ if [[ $1 =~ [0-9]$ ]]; then printf '%sp%s\n' "$1" "$2"; else printf '%s%s\n' "$1" "$2"; fi; }

partition_created_at(){
  local disk=$1 wanted_start=$2 number
  number=$(as_root_capture parted -m -s "$disk" unit B print | awk -F: -v wanted_start="$wanted_start" '
    $1 ~ /^[0-9]+$/ {
      gsub(/B/, "", $2); difference=$2-wanted_start
      if (difference >= -2097152 && difference <= 2097152) { print $1; exit }
    }
  ')
  [[ -n $number ]] || return 1
  partition_path "$disk" "$number"
}

unused_partitions(){
  local disk=$1 path type fstype mounts size_gib
  while read -r path type; do
    [[ $type == part ]] || continue
    fstype=$(lsblk -dnro FSTYPE "$path"); mounts=$(lsblk -dnro MOUNTPOINTS "$path")
    [[ -z $fstype && -z $mounts ]] || continue
    size_gib=$(block_capacity_gib "$path")
    capacity_meets_minimum "$size_gib" "$LONGHORN_DATA_MIN_GIB" || continue
    printf '%s\n' "$path"
  done < <(lsblk -lnpo NAME,TYPE "$disk")
}

choose_existing_partition(){
  local disk=$1 answer index=1 partition
  local -a candidates=()
  mapfile -t candidates < <(unused_partitions "$disk")
  ((${#candidates[@]})) || die "No unused partition of at least ${LONGHORN_DATA_MIN_GIB} GiB was found on $disk"
  printf '\nUnused partitions on the OS disk:\n'
  for partition in "${candidates[@]}"; do printf '  %d. %-20s %s\n' "$index" "$partition" "$(lsblk -dnro SIZE "$partition")"; ((index+=1)); done
  read -r -p 'Choose a partition number: ' answer
  if [[ ! $answer =~ ^[0-9]+$ ]] || ((answer<1 || answer>${#candidates[@]})); then die "Invalid partition selection"; fi
  STORAGE_MODE=os-partition; STORAGE_DEVICE=${candidates[answer-1]}; STORAGE_DEVICE_MAJMIN=$(lsblk -dnro MAJ:MIN "$STORAGE_DEVICE"); STORAGE_DESCRIPTION="format $STORAGE_DEVICE ($(lsblk -dnro SIZE "$STORAGE_DEVICE")) as ext4, label longhorn-data"; LONGHORN_PATH=$LONGHORN_STANDARD_PATH; LONGHORN_DEVICE_UUID=
  info "Planned Longhorn partition: $STORAGE_DEVICE. No formatting has occurred."
}

ensure_longhorn_mountpoint_empty(){
  if findmnt -rn "$LONGHORN_STANDARD_PATH" >/dev/null 2>&1; then die "$LONGHORN_STANDARD_PATH is already mounted; use validation mode instead of replacing it."; fi
  if [[ -d $LONGHORN_STANDARD_PATH ]] && [[ -n $(find "$LONGHORN_STANDARD_PATH" -mindepth 1 -maxdepth 1 2>/dev/null | head -1) ]]; then
    die "$LONGHORN_STANDARD_PATH already contains data. Refusing to hide or overwrite it with a new mount."
  fi
}

sudo_if_needed_tee_append(){ if [[ $EUID -eq 0 ]]; then tee -a "$1" >/dev/null; else sudo tee -a "$1" >/dev/null; fi; }

configure_storage_service_guard(){
  local guard='[Unit]
RequiresMountsFor=/var/lib/longhorn
After=local-fs.target
'
  write_root_file /etc/systemd/system/k3s.service.d/longhorn-mount.conf 644 "$guard" || true
  write_root_file /etc/systemd/system/k3s-agent.service.d/longhorn-mount.conf 644 "$guard" || true
  as_root systemctl daemon-reload
}

add_longhorn_mount(){
  local partition=$1 uuid fstab_line mounted_uuid
  uuid=$(as_root_capture blkid -s UUID -o value "$partition")
  [[ -n $uuid ]] || die "Could not read the filesystem UUID from $partition"
  LONGHORN_PATH=$LONGHORN_STANDARD_PATH
  LONGHORN_DEVICE_UUID=$uuid
  as_root mkdir -p "$LONGHORN_PATH"
  fstab_line="UUID=$uuid $LONGHORN_PATH ext4 defaults,nofail 0 2"
  if as_root grep -Fqx "$fstab_line" /etc/fstab; then
    skip "/etc/fstab already contains the Longhorn mount"
  else
    backup_file /etc/fstab
    if $DRY_RUN; then change "Would append UUID-based mount for $LONGHORN_PATH to /etc/fstab"; else printf '%s\n' "$fstab_line" | sudo_if_needed_tee_append /etc/fstab; fi
  fi
  $DRY_RUN && { change "Would mount and validate $LONGHORN_PATH"; return; }
  as_root mount "$LONGHORN_PATH"
  findmnt -rn "$LONGHORN_PATH" >/dev/null || die "Mount validation failed for $LONGHORN_PATH"
  mounted_uuid=$(findmnt -no UUID "$LONGHORN_PATH" 2>/dev/null || true)
  [[ $mounted_uuid == "$uuid" ]] || die "Mounted filesystem UUID does not match the selected device"
  configure_storage_service_guard
  ok "Longhorn filesystem is mounted persistently at $LONGHORN_PATH"
}

format_existing_partition(){
  local partition=$1 already_confirmed=${2:-false} model size exact size_gib parent_disk part_type fstype mounts
  [[ -b $partition ]] || die "Selected partition no longer exists: $partition"
  part_type=$(lsblk -dnro TYPE "$partition"); fstype=$(lsblk -dnro FSTYPE "$partition"); mounts=$(lsblk -dnro MOUNTPOINTS "$partition")
  [[ $part_type == part && -z $fstype && -z $mounts ]] || die "$partition changed after planning or is no longer empty. No formatting was attempted."
  parent_disk="/dev/$(lsblk -dnro PKNAME "$partition")"
  model=$(lsblk -dnro MODEL "$parent_disk"); size=$(lsblk -dnro SIZE "$partition"); size_gib=$(block_capacity_gib "$partition")
  capacity_meets_minimum "$size_gib" "$LONGHORN_DATA_MIN_GIB" || die "$partition is ${size_gib} GiB; Longhorn storage requires at least ${LONGHORN_DATA_MIN_GIB} GiB by this installer's safety policy."
  ensure_longhorn_mountpoint_empty
  ensure_storage_preparation_tools
  if ! $already_confirmed; then
    warn "FORMATTING WILL ERASE partition $partition (parent model: ${model:-unknown}, size: $size)."
    read -r -p "Type the exact partition name '$partition' to continue: " exact
    [[ $exact == "$partition" ]] || die "Exact partition confirmation failed"
  fi
  if $DRY_RUN; then change "Would create an ext4 filesystem on confirmed partition $partition"; LONGHORN_PATH=$LONGHORN_STANDARD_PATH; return; fi
  as_root mkfs.ext4 -L longhorn-data "$partition"
  add_longhorn_mount "$partition"
}

create_os_disk_partition(){
  local disk=$STORAGE_DEVICE exact partition
  ensure_storage_preparation_tools
  range_is_still_free "$disk" "$STORAGE_PARTITION_START" "$STORAGE_PARTITION_END" || die "The disk layout changed after planning. No partition was created; run the installer again."
  warn "A new ${STORAGE_PARTITION_SIZE_GIB} GiB partition will be created in existing unallocated space on $disk. Existing partitions will not be resized."
  read -r -p "Type 'CREATE ${STORAGE_PARTITION_SIZE_GIB}GiB ON $disk' to continue: " exact
  [[ $exact == "CREATE ${STORAGE_PARTITION_SIZE_GIB}GiB ON $disk" ]] || die "Exact partition-creation confirmation failed"
  if $DRY_RUN; then change "Would create and format a ${STORAGE_PARTITION_SIZE_GIB} GiB partition on $disk"; LONGHORN_PATH=$LONGHORN_STANDARD_PATH; return; fi
  as_root parted -s "$disk" unit B mkpart longhorn ext4 "${STORAGE_PARTITION_START}B" "${STORAGE_PARTITION_END}B"
  as_root partprobe "$disk"; as_root udevadm settle
  partition=$(partition_created_at "$disk" "$STORAGE_PARTITION_START") || die "The partition was created but its device path was not detected. Reboot, then rerun and choose the existing unused partition."
  [[ -b $partition ]] || die "The new partition $partition is not available yet. Reboot, then rerun and choose the existing unused partition."
  STORAGE_DEVICE=$partition
  info "Created Longhorn partition $partition (${STORAGE_PARTITION_SIZE_GIB} GiB, label longhorn-data)"
  format_existing_partition "$partition" true
}

prepare_empty_disk(){
  local device=$1 part model size exact size_gib type children fstype mounts pttype current_root_disk
  [[ -b $device ]] || die "Selected disk no longer exists: $device"
  type=$(lsblk -dnro TYPE "$device"); children=$(lsblk -nrpo NAME "$device" | wc -l); fstype=$(lsblk -dnro FSTYPE "$device"); mounts=$(lsblk -nrpo MOUNTPOINTS "$device" | sed '/^$/d'); pttype=$(lsblk -dnro PTTYPE "$device"); current_root_disk=$(root_parent_disk || true)
  [[ $type == disk ]] && ((children==1)) && [[ -z $fstype && -z $mounts && -z $pttype ]] || die "$device changed after planning or is no longer completely empty. No partitioning was attempted."
  [[ -z $current_root_disk || $(readlink -f "$device") != "$current_root_disk" ]] || die "Refusing current root/OS disk: $device"
  model=$(lsblk -dnro MODEL "$device"); size=$(lsblk -dnro SIZE "$device"); size_gib=$(block_capacity_gib "$device")
  capacity_meets_minimum "$size_gib" "$LONGHORN_DATA_MIN_GIB" || die "$device is ${size_gib} GiB; a dedicated Longhorn disk must be at least ${LONGHORN_DATA_MIN_GIB} GiB."
  ensure_longhorn_mountpoint_empty
  ensure_storage_preparation_tools
  warn "FORMATTING WILL ERASE the entire disk $device (model: ${model:-unknown}, size: $size)."
  read -r -p "Type the exact disk name '$device' to continue: " exact
  [[ $exact == "$device" ]] || die "Exact-disk confirmation failed"
  if $DRY_RUN; then change "Would create GPT, one ext4 partition, and a UUID mount on $device"; LONGHORN_PATH=$LONGHORN_STANDARD_PATH; return; fi
  as_root parted -s "$device" mklabel gpt mkpart primary ext4 0% 100%
  as_root partprobe "$device"; as_root udevadm settle
  part="${device}1"; [[ $device == *nvme* || $device == *mmcblk* ]] && part="${device}p1"
  [[ -b $part ]] || die "Expected partition was not created: $part"
  as_root mkfs.ext4 -L longhorn-data "$part"
  add_longhorn_mount "$part"
}

select_root_storage(){
  local root_gib available_gib root_fstype
  root_gib=$(root_capacity_gib); available_gib=$(root_available_gib)
  root_fstype=$(findmnt -no FSTYPE /)
  [[ $root_fstype == ext4 || $root_fstype == xfs ]] || die "Root uses '$root_fstype'. This installer supports ext4 or XFS for Longhorn V1 filesystem storage."
  capacity_meets_minimum "$root_gib" "$LONGHORN_ROOT_MIN_GIB" || die "The root filesystem is ${root_gib} GiB. This installer requires at least ${LONGHORN_ROOT_MIN_GIB} GiB for shared OS and Longhorn storage; select a separate partition or disk."
  capacity_meets_minimum "$available_gib" "$LONGHORN_ROOT_MIN_AVAILABLE_GIB" || die "Root has only ${available_gib} GiB available. At least ${LONGHORN_ROOT_MIN_AVAILABLE_GIB} GiB free is required before using shared root storage."
  STORAGE_MODE=root; STORAGE_DEVICE='root filesystem'; STORAGE_DEVICE_MAJMIN=; STORAGE_DESCRIPTION="share root filesystem (${root_gib} GiB total, ${available_gib} GiB free)"; LONGHORN_PATH=$LONGHORN_STANDARD_PATH; LONGHORN_DEVICE_UUID=
  info "Root storage selected: ${root_gib} GiB total, ${available_gib} GiB currently available, $root_fstype filesystem."
  info "Longhorn will reserve ${LONGHORN_ROOT_RESERVED_PERCENT}% from replica scheduling and stop scheduling below ${LONGHORN_MIN_AVAILABLE_PERCENT}% free."
  warn "These are Longhorn scheduling guardrails, not a hard OS quota. OS files and Longhorn still share one filesystem."
  show_storage /
}

select_os_disk_partition(){
  local root_disk table_type region free_start free_end free_bytes free_gib maximum_gib recommended_gib requested_gib subchoice
  local -a _existing_partitions=()
  root_disk=$(root_parent_disk) || die "Could not safely identify the physical OS disk. Choose a dedicated disk instead."
  capacity_meets_minimum "$(block_capacity_gib "$root_disk")" "$LONGHORN_ROOT_MIN_GIB" || die "The OS disk is smaller than ${LONGHORN_ROOT_MIN_GIB} GiB; this safety policy requires a second physical disk."
  ensure_parted_for_planning
  table_type=$(partition_table_type "$root_disk")
  [[ $table_type == gpt ]] || die "Guided partition creation supports GPT disks only; $root_disk uses '$table_type'. Choose root storage, a dedicated disk, or prepare a partition manually."
  list_disks
  region=$(largest_free_region "$root_disk" || true)
  read -r free_start free_end free_bytes <<<"$region"
  free_gib=0; [[ -z ${free_bytes:-} ]] || free_gib=$(gib_from_bytes "$free_bytes")
  mapfile -t _existing_partitions < <(unused_partitions "$root_disk")
  printf '\nOS-disk storage choices for %s:\n' "$root_disk"
  if ((free_gib > LONGHORN_DATA_MIN_GIB)); then printf '  1. Create a new Longhorn partition from the largest unallocated region (%d GiB free)\n' "$free_gib"; else printf '  1. Create a new partition (unavailable: largest free region is only %d GiB)\n' "$free_gib"; fi
  printf '  2. Use an existing unused partition (%d eligible found)\n' "${#_existing_partitions[@]}"
  printf '\nNo existing partition will be shrunk or moved.\n'
  read -r -p 'Selection [1]: ' subchoice; subchoice=${subchoice:-1}
  if [[ $subchoice == 2 ]]; then choose_existing_partition "$root_disk"; return; fi
  [[ $subchoice == 1 ]] || die "Invalid partition choice"
  ((free_gib > LONGHORN_DATA_MIN_GIB)) || die "There is not enough unallocated space. At least ${LONGHORN_DATA_MIN_GIB} GiB plus 1 GiB safety margin is required."
  maximum_gib=$((free_gib-1)); recommended_gib=$maximum_gib
  printf '\nLargest unallocated region: %d GiB\n' "$free_gib"
  printf 'Recommended Longhorn partition: %d GiB (leaves approximately 1 GiB unallocated for alignment/recovery)\n' "$recommended_gib"
  read -r -p "Longhorn partition size in GiB [$recommended_gib]: " requested_gib; requested_gib=${requested_gib:-$recommended_gib}
  [[ $requested_gib =~ ^[0-9]+$ ]] || die "Partition size must be a whole number of GiB"
  ((requested_gib>=LONGHORN_DATA_MIN_GIB && requested_gib<=maximum_gib)) || die "Choose a size between ${LONGHORN_DATA_MIN_GIB} and ${maximum_gib} GiB"
  STORAGE_MODE=os-new-partition; STORAGE_DEVICE=$root_disk; STORAGE_DEVICE_MAJMIN=$(lsblk -dnro MAJ:MIN "$root_disk"); STORAGE_DESCRIPTION="create ${requested_gib} GiB ext4 partition named longhorn on $root_disk"; LONGHORN_PATH=$LONGHORN_STANDARD_PATH; LONGHORN_DEVICE_UUID=
  STORAGE_PARTITION_START=$free_start; STORAGE_PARTITION_SIZE_GIB=$requested_gib
  STORAGE_PARTITION_END=$((free_start + requested_gib*1073741824 - 1))
  ((STORAGE_PARTITION_END<=free_end)) || die "Calculated partition exceeds the selected free region"
  info "Planned partition: ${requested_gib} GiB on $root_disk, filesystem label longhorn-data. No partition has been created."
}

select_dedicated_disk(){
  local root_disk device type children fstype mounts pttype answer index=1 model size
  local -a candidates=()
  root_disk=$(root_parent_disk || true); list_disks
  while read -r device type; do
    [[ $type == disk ]] || continue
    [[ -z $root_disk || $(readlink -f "$device") != "$root_disk" ]] || continue
    children=$(lsblk -nrpo NAME "$device" | wc -l); fstype=$(lsblk -dnro FSTYPE "$device"); mounts=$(lsblk -nrpo MOUNTPOINTS "$device" | sed '/^$/d'); pttype=$(lsblk -dnro PTTYPE "$device")
    ((children==1)) && [[ -z $fstype && -z $mounts && -z $pttype ]] || continue
    capacity_meets_minimum "$(block_capacity_gib "$device")" "$LONGHORN_DATA_MIN_GIB" || continue
    candidates+=("$device")
  done < <(lsblk -dnpo NAME,TYPE)
  ((${#candidates[@]})) || die "No safe empty disk of at least ${LONGHORN_DATA_MIN_GIB} GiB was found. No disk was changed."
  printf '\nEligible empty disks:\n'
  for device in "${candidates[@]}"; do model=$(lsblk -dnro MODEL "$device"); size=$(lsblk -dnro SIZE "$device"); printf '  %d. %-14s %-10s %s\n' "$index" "$device" "$size" "${model:-unknown model}"; ((index+=1)); done
  read -r -p 'Choose a disk number: ' answer
  if [[ ! $answer =~ ^[0-9]+$ ]] || ((answer<1 || answer>${#candidates[@]})); then die "Invalid disk selection"; fi
  device=${candidates[answer-1]}
  STORAGE_MODE=dedicated-disk; STORAGE_DEVICE=$device; STORAGE_DEVICE_MAJMIN=$(lsblk -dnro MAJ:MIN "$device"); STORAGE_DESCRIPTION="erase $device ($(lsblk -dnro SIZE "$device")), create GPT and ext4 longhorn-data filesystem"; LONGHORN_PATH=$LONGHORN_STANDARD_PATH; LONGHORN_DEVICE_UUID=
  info "Planned dedicated Longhorn disk: $device. No partitioning or formatting has occurred."
}

apply_storage_plan(){
  if [[ -n ${STORAGE_DEVICE_MAJMIN:-} ]]; then
    [[ -b $STORAGE_DEVICE ]] || die "The selected storage device disappeared after planning"
    [[ $(lsblk -dnro MAJ:MIN "$STORAGE_DEVICE") == "$STORAGE_DEVICE_MAJMIN" ]] || die "The device at $STORAGE_DEVICE changed after planning. No storage action was attempted."
  fi
  case ${STORAGE_MODE:-} in
    root) as_root mkdir -p "$LONGHORN_PATH"; show_storage "$LONGHORN_PATH";;
    os-partition) format_existing_partition "$STORAGE_DEVICE";;
    os-new-partition) create_os_disk_partition;;
    dedicated-disk) prepare_empty_disk "$STORAGE_DEVICE";;
    *) die "No valid Longhorn storage plan was selected";;
  esac
}

select_storage(){
  local root_gib available_gib root_disk root_disk_gib=unknown default_choice=1 choice
  require_storage_inspection_tools
  root_gib=$(root_capacity_gib); available_gib=$(root_available_gib); root_disk=$(root_parent_disk || true)
  [[ -z $root_disk ]] || root_disk_gib=$(block_capacity_gib "$root_disk")
  if ! capacity_meets_minimum "$root_gib" "$LONGHORN_ROOT_MIN_GIB" || ! capacity_meets_minimum "$available_gib" "$LONGHORN_ROOT_MIN_AVAILABLE_GIB"; then default_choice=3; fi
  cat <<EOF

Longhorn storage

Detected root filesystem: ${root_gib} GiB total, ${available_gib} GiB available
Detected OS disk:         ${root_disk:-unknown} (${root_disk_gib} GiB)

1. Use the root filesystem (simplest)
   Recommended only when root is at least ${LONGHORN_ROOT_MIN_GIB} GiB. Longhorn reserves
   ${LONGHORN_ROOT_RESERVED_PERCENT}% for OS headroom, but this is not a hard quota.

2. Use a separate, already-created partition on the OS disk
   Better space isolation, but not protection from physical disk failure.
   The installer never shrinks your live OS partition automatically.

3. Use a separate physical disk (recommended for important data)
   Best isolation. The disk must be empty and at least ${LONGHORN_DATA_MIN_GIB} GiB.

All separate storage is mounted by UUID at $LONGHORN_STANDARD_PATH.
EOF
  read -r -p "Selection [$default_choice]: " choice; choice=${choice:-$default_choice}
  case $choice in 1) select_root_storage;; 2) select_os_disk_partition;; 3) select_dedicated_disk;; *) die "Invalid storage selection";; esac
}

validate_storage_selection(){
  local actual_uuid
  [[ -d ${LONGHORN_PATH:-$LONGHORN_STANDARD_PATH} ]] || { report 'Longhorn storage path' FAIL 'directory missing'; return 1; }
  case ${STORAGE_MODE:-unknown} in
    root) report 'Longhorn storage path' OK 'shared root filesystem';;
    os-partition|dedicated-disk)
      if ! findmnt -rn "$LONGHORN_PATH" >/dev/null; then report 'Longhorn storage mount' FAIL 'expected separate filesystem is not mounted'; return 1; fi
      actual_uuid=$(findmnt -no UUID "$LONGHORN_PATH" 2>/dev/null || true)
      if [[ -n ${LONGHORN_DEVICE_UUID:-} && $actual_uuid != "$LONGHORN_DEVICE_UUID" ]]; then report 'Longhorn storage UUID' FAIL 'mounted filesystem differs from installer state'; return 1; fi
      report 'Longhorn storage mount' OK "UUID=$actual_uuid"
      ;;
    *) report 'Longhorn storage path' WARN 'installer storage mode is unknown';;
  esac
}
