#!/usr/bin/env bash

readonly LONGHORN_STANDARD_PATH=/var/lib/longhorn
export STORAGE_MODE STORAGE_DEVICE STORAGE_DEVICE_MAJMIN STORAGE_DESCRIPTION LONGHORN_PATH LONGHORN_DEVICE_UUID
export STORAGE_LVM_VG STORAGE_LVM_LV STORAGE_LVM_FREE_BYTES

gib_from_bytes(){ awk -v bytes="$1" 'BEGIN { printf "%d", bytes / 1073741824 }'; }
capacity_meets_minimum(){ (( $1 >= $2 )); }

show_storage(){
  if [[ ! -e $1 && $DRY_RUN == true ]]; then change "Would inspect filesystem capacity for $1"; return; fi
  df -hT "$1"
  findmnt -T "$1" -o SOURCE,FSTYPE,SIZE,USED,AVAIL,TARGET
}

root_source_device(){ findmnt -no SOURCE / | head -1; }

parse_physical_disks(){ awk '$2 == "disk" { sub(/^.*\/dev\//, "/dev/", $1); if (!seen[$1]++) print $1 }'; }

root_parent_disk(){
  local device
  local -a disks=()
  device=$(readlink -f "$(root_source_device)")
  [[ -b $device ]] || return 1
  mapfile -t disks < <(lsblk -srnpo NAME,TYPE "$device" 2>/dev/null | parse_physical_disks)
  ((${#disks[@]} == 1)) || return 1
  printf '%s\n' "${disks[0]}"
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

parse_root_lvm_vg(){
  local device=$1 vg lv_path resolved match=
  while IFS='|' read -r vg lv_path; do
    vg=${vg#"${vg%%[![:space:]]*}"}; vg=${vg%"${vg##*[![:space:]]}"}
    lv_path=${lv_path#"${lv_path%%[![:space:]]*}"}; lv_path=${lv_path%"${lv_path##*[![:space:]]}"}
    [[ -n $vg && -n $lv_path ]] || continue
    resolved=$(readlink -f "$lv_path" 2>/dev/null || true)
    [[ $lv_path != "$device" && $resolved != "$device" ]] || match=$vg
  done
  [[ -n $match ]] || return 1
  printf '%s\n' "$match"
}

root_lvm_vg(){
  local device type
  command -v lvs >/dev/null 2>&1 || return 1
  device=$(readlink -f "$(root_source_device)")
  [[ -b $device ]] || return 1
  type=$(lsblk -dnro TYPE "$device" 2>/dev/null || true)
  [[ $type == lvm ]] || return 1
  as_root_capture lvs --noheadings --separator '|' -o vg_name,lv_path 2>/dev/null | parse_root_lvm_vg "$device"
}

parse_lvm_bytes(){ awk '{gsub(/[<>,]/, "", $1); printf "%.0f", $1; exit}'; }
vg_free_bytes(){ as_root_capture vgs --noheadings --units b --nosuffix -o vg_free "$1" 2>/dev/null | parse_lvm_bytes; }

check_os_headroom(){
  local disk=$1 root_gib available_gib disk_gib allocated_percent
  root_gib=$(root_capacity_gib); available_gib=$(root_available_gib); disk_gib=$(block_capacity_gib "$disk")
  allocated_percent=$((root_gib * 100 / disk_gib))
  section 'OS disk safety check'
  printf '  Root filesystem: %d GiB total, %d GiB available\n' "$root_gib" "$available_gib"
  printf '  Root allocation: approximately %d%% of the %d GiB OS disk\n' "$allocated_percent" "$disk_gib"
  if ((allocated_percent < OS_DISK_MIN_ROOT_PERCENT)); then
    warn "The root filesystem is below the ${OS_DISK_MIN_ROOT_PERCENT}% OS-headroom guideline. Creating separate Longhorn storage will not enlarge root."
    confirm "Continue with the smaller fixed root filesystem?" || return 1
  else
    ok "The root allocation meets the ${OS_DISK_MIN_ROOT_PERCENT}% OS-headroom guideline"
  fi
  if ((available_gib < OS_ROOT_MIN_AVAILABLE_GIB)); then
    warn "Root has only ${available_gib} GiB available. At least ${OS_ROOT_MIN_AVAILABLE_GIB} GiB is required before creating separate Longhorn storage on the OS disk."
    return 1
  fi
}

warn_small_longhorn_capacity(){
  local size_gib=$1
  if ((size_gib < LONGHORN_DATA_RECOMMENDED_GIB)); then
    warn "${size_gib} GiB is suitable only for a small lab or light workloads. This project recommends planning at least ${LONGHORN_DATA_RECOMMENDED_GIB} GiB per storage node for general use."
    info 'Longhorn capacity is consumed by every replica and snapshot. Size the disk from your actual PVC and retention plan.'
  fi
}

show_additional_storage_guidance(){
  section 'Recommended storage actions'
  cat <<EOF
  - Virtual machine: use your hypervisor or cloud console to attach a new empty
    virtual disk. Follow that platform's hot-add or shutdown instructions, then
    confirm the disk appears in 'lsblk' and rerun K3sDeploy using option 3.
  - Physical machine: install an empty SSD or NVMe drive, confirm Linux detects
    it with 'lsblk', then rerun K3sDeploy using option 3.
  - Existing OS disk: choose option 2 only when K3sDeploy reports usable LVM
    free extents, physical unallocated space, or an eligible empty partition.

SSD or NVMe storage is recommended for K3s database responsiveness and
Longhorn stability. Never select a disk that contains data you need to keep.
EOF
}

list_disks(){
  section 'Available block devices'
  printf '  Nothing is selected automatically. Review device names and sizes carefully.\n\n'
  lsblk -e7 -o NAME,MODEL,SIZE,TYPE,FSTYPE,MOUNTPOINTS
}

require_storage_inspection_tools(){ local cmd; for cmd in awk df findmnt lsblk readlink; do need_cmd "$cmd"; done; }

ensure_parted_for_planning(){
  command -v parted >/dev/null 2>&1 && return
  $DRY_RUN && die "Option 2 needs the 'parted' package to inspect unallocated space. Install it, then repeat the dry run."
  confirm_yes "Install the standard 'parted' package for $OS_NAME to inspect unallocated space safely?" || die "Cannot plan a new partition without parted"
  package_refresh
  package_install parted
  need_cmd parted
}

ensure_storage_preparation_tools(){
  local missing=false cmd
  for cmd in blkid mkfs.ext4 parted partprobe udevadm; do command -v "$cmd" >/dev/null 2>&1 || missing=true; done
  if $missing; then
    info "Installing standard disk tools for $OS_NAME (parted, e2fsprogs, util-linux) before storage preparation"
    package_refresh
    package_install parted e2fsprogs util-linux
  fi
  for cmd in blkid mkfs.ext4 parted partprobe udevadm; do need_cmd "$cmd"; done
}

ensure_lvm_preparation_tools(){
  local missing=false cmd
  for cmd in blkid mkfs.ext4 lvs vgs lvcreate udevadm; do command -v "$cmd" >/dev/null 2>&1 || missing=true; done
  if $missing; then
    info "Installing standard LVM and filesystem tools for $OS_NAME (lvm2, e2fsprogs, util-linux)"
    package_refresh
    package_install lvm2 e2fsprogs util-linux
  fi
  for cmd in blkid mkfs.ext4 lvs vgs lvcreate udevadm; do need_cmd "$cmd"; done
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
  local disk=$1 answer partition
  local -a candidates=() menu_options=()
  mapfile -t candidates < <(unused_partitions "$disk")
  ((${#candidates[@]})) || die "No unused partition of at least ${LONGHORN_DATA_MIN_GIB} GiB was found on $disk"
  section 'Unused partitions on the OS disk'
  for partition in "${candidates[@]}"; do menu_options+=("$partition - $(lsblk -dnro SIZE "$partition")"); done
  while true; do
    menu_select answer 'Choose an unused partition' 1 "${menu_options[@]}"
    [[ $answer =~ ^[0-9]+$ ]] && ((answer>=1 && answer<=${#candidates[@]})) && break
    warn "Choose a number from 1 to ${#candidates[@]}."
  done
  STORAGE_MODE=os-partition; STORAGE_DEVICE=${candidates[answer-1]}; STORAGE_DEVICE_MAJMIN=$(lsblk -dnro MAJ:MIN "$STORAGE_DEVICE"); STORAGE_DESCRIPTION="format $STORAGE_DEVICE ($(lsblk -dnro SIZE "$STORAGE_DEVICE")) as ext4, label longhorn-data"; LONGHORN_PATH=$LONGHORN_STANDARD_PATH; LONGHORN_DEVICE_UUID=
  warn_small_longhorn_capacity "$(block_capacity_gib "$STORAGE_DEVICE")"
  info "Planned Longhorn partition: $STORAGE_DEVICE. No formatting has occurred."
}

ensure_longhorn_mountpoint_empty(){
  if findmnt -rn "$LONGHORN_STANDARD_PATH" >/dev/null 2>&1; then die "$LONGHORN_STANDARD_PATH is already mounted. Use validation mode instead of replacing it."; fi
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
  capacity_meets_minimum "$size_gib" "$LONGHORN_DATA_MIN_GIB" || die "$partition is ${size_gib} GiB. Longhorn storage requires at least ${LONGHORN_DATA_MIN_GIB} GiB by this installer's safety policy."
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
  range_is_still_free "$disk" "$STORAGE_PARTITION_START" "$STORAGE_PARTITION_END" || die "The disk layout changed after planning. No partition was created. Run the installer again."
  warn "A new ${STORAGE_PARTITION_SIZE_GIB} GiB partition will be created in existing unallocated space on $disk. Existing partitions will not be resized."
  read -r -p "Type 'CREATE' to create this partition: " exact
  [[ $exact == CREATE ]] || die "Exact partition-creation confirmation failed"
  if $DRY_RUN; then change "Would create and format a ${STORAGE_PARTITION_SIZE_GIB} GiB partition on $disk"; LONGHORN_PATH=$LONGHORN_STANDARD_PATH; return; fi
  as_root parted -s "$disk" unit B mkpart longhorn ext4 "${STORAGE_PARTITION_START}B" "${STORAGE_PARTITION_END}B"
  as_root partprobe "$disk"; as_root udevadm settle
  partition=$(partition_created_at "$disk" "$STORAGE_PARTITION_START") || die "The partition was created but its device path was not detected. Reboot, then rerun and choose the existing unused partition."
  [[ -b $partition ]] || die "The new partition $partition is not available yet. Reboot, then rerun and choose the existing unused partition."
  STORAGE_DEVICE=$partition
  info "Created Longhorn partition $partition (${STORAGE_PARTITION_SIZE_GIB} GiB, label longhorn-data)"
  format_existing_partition "$partition" true
}

plan_lvm_volume(){
  local vg=$1 free_bytes=$2 free_gib maximum_gib recommended_gib requested_gib
  free_gib=$(gib_from_bytes "$free_bytes")
  ((free_gib > LONGHORN_DATA_MIN_GIB)) || return 1
  maximum_gib=$((free_gib-1)); recommended_gib=$maximum_gib
  section 'Longhorn LVM plan'
  printf '  Operating system:  %s\n' "$OS_NAME"
  printf '  Volume group:      %s\n' "$vg"
  printf '  Free in group:     %d GiB\n' "$free_gib"
  printf '  Recommended size:  %d GiB\n' "$recommended_gib"
  printf '  Safety margin:     approximately 1 GiB remains free in the volume group\n'
  printf '  Existing volumes:  no root or existing logical volume will be resized\n\n'
  while true; do
    read -r -p "Longhorn logical volume size in GiB [$recommended_gib]: " requested_gib
    requested_gib=${requested_gib:-$recommended_gib}
    if [[ $requested_gib =~ ^[0-9]+$ ]] && ((requested_gib>=LONGHORN_DATA_MIN_GIB && requested_gib<=maximum_gib)); then break; fi
    warn "Choose a whole-number size between ${LONGHORN_DATA_MIN_GIB} and ${maximum_gib} GiB."
  done
  warn_small_longhorn_capacity "$requested_gib"
  STORAGE_MODE=os-lvm
  STORAGE_LVM_VG=$vg
  STORAGE_LVM_LV=longhorn-data
  STORAGE_LVM_FREE_BYTES=$free_bytes
  STORAGE_PARTITION_SIZE_GIB=$requested_gib
  STORAGE_DEVICE="/dev/$vg/$STORAGE_LVM_LV"
  STORAGE_DEVICE_MAJMIN=
  STORAGE_DESCRIPTION="create ${requested_gib} GiB LVM logical volume $vg/$STORAGE_LVM_LV and format it as ext4"
  LONGHORN_PATH=$LONGHORN_STANDARD_PATH
  LONGHORN_DEVICE_UUID=
  info "Planned LVM logical volume: $vg/$STORAGE_LVM_LV (${requested_gib} GiB). No LVM or filesystem change has occurred."
}

create_lvm_volume(){
  local current_free required_bytes exact device
  ensure_longhorn_mountpoint_empty
  ensure_lvm_preparation_tools
  as_root_capture lvs "$STORAGE_LVM_VG/$STORAGE_LVM_LV" >/dev/null 2>&1 &&
    die "Logical volume $STORAGE_LVM_VG/$STORAGE_LVM_LV now exists. No formatting was attempted. Inspect it before retrying."
  current_free=$(vg_free_bytes "$STORAGE_LVM_VG")
  required_bytes=$((STORAGE_PARTITION_SIZE_GIB * 1073741824))
  [[ $current_free =~ ^[0-9]+$ ]] && ((current_free >= required_bytes)) ||
    die "LVM free space changed after planning. No logical volume was created. Run K3sDeploy again."
  warn "A new ${STORAGE_PARTITION_SIZE_GIB} GiB logical volume will be allocated from free space in $STORAGE_LVM_VG. Existing logical volumes will not be resized."
  read -r -p "Type 'CREATE' to create this logical volume: " exact
  [[ $exact == CREATE ]] || die 'Exact LVM confirmation failed'
  if $DRY_RUN; then
    change "Would create and format LVM logical volume $STORAGE_LVM_VG/$STORAGE_LVM_LV"
    LONGHORN_PATH=$LONGHORN_STANDARD_PATH
    return
  fi
  as_root lvcreate --yes --size "${STORAGE_PARTITION_SIZE_GIB}G" --name "$STORAGE_LVM_LV" "$STORAGE_LVM_VG"
  as_root udevadm settle
  device=$(as_root_capture lvs --noheadings -o lv_path "$STORAGE_LVM_VG/$STORAGE_LVM_LV" | awk '{$1=$1; print; exit}')
  [[ -b $device ]] || die "The logical volume was created, but its block device is unavailable. Inspect $STORAGE_LVM_VG/$STORAGE_LVM_LV before retrying."
  STORAGE_DEVICE=$device
  as_root mkfs.ext4 -L longhorn-data "$device"
  add_longhorn_mount "$device"
}

prepare_empty_disk(){
  local device=$1 part model size exact size_gib type children fstype mounts pttype current_root_disk
  [[ -b $device ]] || die "Selected disk no longer exists: $device"
  type=$(lsblk -dnro TYPE "$device"); children=$(lsblk -nrpo NAME "$device" | wc -l); fstype=$(lsblk -dnro FSTYPE "$device"); mounts=$(lsblk -nrpo MOUNTPOINTS "$device" | sed '/^$/d'); pttype=$(lsblk -dnro PTTYPE "$device"); current_root_disk=$(root_parent_disk || true)
  [[ $type == disk ]] && ((children==1)) && [[ -z $fstype && -z $mounts && -z $pttype ]] || die "$device changed after planning or is no longer completely empty. No partitioning was attempted."
  [[ -z $current_root_disk || $(readlink -f "$device") != "$current_root_disk" ]] || die "Refusing current root/OS disk: $device"
  model=$(lsblk -dnro MODEL "$device"); size=$(lsblk -dnro SIZE "$device"); size_gib=$(block_capacity_gib "$device")
  capacity_meets_minimum "$size_gib" "$LONGHORN_DATA_MIN_GIB" || die "$device is ${size_gib} GiB. A dedicated Longhorn disk must be at least ${LONGHORN_DATA_MIN_GIB} GiB."
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
  if [[ $root_fstype != ext4 && $root_fstype != xfs ]]; then
    warn "Root storage is unavailable because '$root_fstype' is not supported. Longhorn V1 root storage requires ext4 or XFS."
    show_additional_storage_guidance
    return 1
  fi
  if ! capacity_meets_minimum "$root_gib" "$LONGHORN_ROOT_MIN_GIB" || ! capacity_meets_minimum "$available_gib" "$LONGHORN_ROOT_MIN_AVAILABLE_GIB"; then
    warn "Root storage is unavailable: detected ${root_gib} GiB total and ${available_gib} GiB available."
    info "Shared root storage requires at least ${LONGHORN_ROOT_MIN_GIB} GiB total and ${LONGHORN_ROOT_MIN_AVAILABLE_GIB} GiB available."
    info 'Choose option 2 when the OS disk has safe separate space, or option 3 after adding an empty disk.'
    return 1
  fi
  STORAGE_MODE=root; STORAGE_DEVICE='root filesystem'; STORAGE_DEVICE_MAJMIN=; STORAGE_DESCRIPTION="share root filesystem (${root_gib} GiB total, ${available_gib} GiB free)"; LONGHORN_PATH=$LONGHORN_STANDARD_PATH; LONGHORN_DEVICE_UUID=
  info "Root storage selected: ${root_gib} GiB total, ${available_gib} GiB currently available, $root_fstype filesystem."
  info "Longhorn will reserve ${LONGHORN_ROOT_RESERVED_PERCENT}% from replica scheduling and stop scheduling below ${LONGHORN_MIN_AVAILABLE_PERCENT}% free."
  warn "These are Longhorn scheduling guardrails, not a hard OS quota. OS files and Longhorn still share one filesystem."
  show_storage /
}

select_os_disk_partition(){
  local root_disk table_type region free_start free_end free_bytes free_gib maximum_gib recommended_gib requested_gib subchoice
  local root_device root_type lvm_vg= lvm_free_bytes= lvm_free_gib=0 lvm_status=not-applicable default_subchoice=4
  local -a _existing_partitions=() os_choices=()
  root_disk=$(root_parent_disk) || die "Could not safely identify the physical OS disk. Choose a dedicated disk instead."
  check_os_headroom "$root_disk" || {
    warn 'Separate storage on the OS disk is not recommended with the current root allocation/free space.'
    return 1
  }
  root_device=$(readlink -f "$(root_source_device)")
  root_type=$(lsblk -dnro TYPE "$root_device" 2>/dev/null || true)
  if [[ $root_type == lvm ]]; then
    lvm_status=inspection-failed
    lvm_vg=$(root_lvm_vg || true)
  fi
  if [[ -n $lvm_vg ]]; then
    lvm_free_bytes=$(vg_free_bytes "$lvm_vg" || true)
    if [[ $lvm_free_bytes =~ ^[0-9]+$ ]]; then
      lvm_status=inspected
      lvm_free_gib=$(gib_from_bytes "$lvm_free_bytes")
    fi
  fi
  ensure_parted_for_planning
  table_type=$(partition_table_type "$root_disk")
  [[ $table_type == gpt ]] || die "Guided partition creation supports GPT disks only. $root_disk uses '$table_type'. Choose root storage, a dedicated disk, or prepare a partition manually."
  list_disks
  region=$(largest_free_region "$root_disk" || true)
  read -r free_start free_end free_bytes <<<"$region"
  free_gib=0; [[ -z ${free_bytes:-} ]] || free_gib=$(gib_from_bytes "$free_bytes")
  mapfile -t _existing_partitions < <(unused_partitions "$root_disk")
  section "OS-disk storage choices: $root_disk"
  if [[ $lvm_status == inspection-failed ]]; then
    os_choices+=("${MENU_DISABLED_PREFIX}Create an LVM logical volume [Unavailable - LVM inspection failed]")
  elif [[ $lvm_status == not-applicable ]]; then
    os_choices+=("${MENU_DISABLED_PREFIX}Create an LVM logical volume [Unavailable - root is not on LVM]")
  elif ((lvm_free_gib > LONGHORN_DATA_MIN_GIB)); then
    os_choices+=("Create a Longhorn logical volume - $lvm_free_gib GiB LVM space free")
    default_subchoice=1
  else
    os_choices+=("${MENU_DISABLED_PREFIX}Create an LVM logical volume [Unavailable - only $lvm_free_gib GiB free]")
  fi
  if ((free_gib > LONGHORN_DATA_MIN_GIB)); then
    os_choices+=("Create a physical partition - $free_gib GiB unallocated")
    [[ $default_subchoice == 4 ]] && default_subchoice=2
  else
    os_choices+=("${MENU_DISABLED_PREFIX}Create a physical partition [Unavailable - only $free_gib GiB unallocated]")
  fi
  if ((${#_existing_partitions[@]} > 0)); then
    os_choices+=("Use an existing unused partition - ${#_existing_partitions[@]} eligible found")
    [[ $default_subchoice == 4 ]] && default_subchoice=3
  else
    os_choices+=("${MENU_DISABLED_PREFIX}Use an existing unused partition [Unavailable - 0 eligible partitions found]")
  fi
  os_choices+=('Return to the main storage choices')
  printf '\n  Safety: no root filesystem, logical volume, or existing partition will be shrunk or moved.\n'
  if [[ $lvm_status == inspected && $free_gib == 0 ]]; then
    printf '  Note: 0 GiB physical space is expected on a fully partitioned LVM disk.\n'
    printf '  K3sDeploy checked inside volume group %s separately. Use choice 1 when it reports enough free space.\n' "$lvm_vg"
  fi
  if [[ $default_subchoice == 4 ]]; then
    printf '\n  No safe separate space is currently available on the OS disk.\n'
    if [[ $lvm_status == inspection-failed ]]; then
      printf 'The root is on LVM, but K3sDeploy could not map it safely to a volume group. No LVM change will be attempted.\n'
      printf 'For troubleshooting, run both commands: sudo lvs -o vg_name,lv_name,lv_path,lv_size and sudo vgs -o vg_name,vg_size,vg_free\n'
    fi
    show_additional_storage_guidance
  fi
  printf '\n'
  menu_select subchoice 'Choose an OS-disk storage action' "$default_subchoice" "${os_choices[@]}"
  case $subchoice in
    1)
      [[ $lvm_status == inspected ]] && ((lvm_free_gib > LONGHORN_DATA_MIN_GIB)) || { warn 'The LVM choice is unavailable because it could not be inspected safely or does not have enough free space.'; return 1; }
      plan_lvm_volume "$lvm_vg" "$lvm_free_bytes"
      return
      ;;
    2)
      ((free_gib > LONGHORN_DATA_MIN_GIB)) || { warn 'The physical-partition choice is unavailable because there is not enough unallocated disk space.'; return 1; }
      ;;
    3)
      ((${#_existing_partitions[@]} > 0)) || { warn 'No eligible unused partition is available.'; return 1; }
      choose_existing_partition "$root_disk"
      return
      ;;
    4) return 1;;
    *) warn 'Invalid OS-disk storage choice'; return 1;;
  esac
  ((free_gib > LONGHORN_DATA_MIN_GIB)) || die "There is not enough unallocated space. At least ${LONGHORN_DATA_MIN_GIB} GiB plus 1 GiB safety margin is required."
  maximum_gib=$((free_gib-1)); recommended_gib=$maximum_gib
  section 'Longhorn partition plan'
  printf '  Largest unallocated region: %d GiB\n' "$free_gib"
  printf '  Recommended partition:     %d GiB\n' "$recommended_gib"
  printf '  Safety margin:             approximately 1 GiB remains unallocated\n\n'
  while true; do
    read -r -p "Longhorn partition size in GiB [$recommended_gib]: " requested_gib
    requested_gib=${requested_gib:-$recommended_gib}
    if [[ $requested_gib =~ ^[0-9]+$ ]] && ((requested_gib>=LONGHORN_DATA_MIN_GIB && requested_gib<=maximum_gib)); then break; fi
    warn "Choose a whole-number size between ${LONGHORN_DATA_MIN_GIB} and ${maximum_gib} GiB."
  done
  warn_small_longhorn_capacity "$requested_gib"
  STORAGE_MODE=os-new-partition; STORAGE_DEVICE=$root_disk; STORAGE_DEVICE_MAJMIN=$(lsblk -dnro MAJ:MIN "$root_disk"); STORAGE_DESCRIPTION="create ${requested_gib} GiB ext4 partition named longhorn on $root_disk"; LONGHORN_PATH=$LONGHORN_STANDARD_PATH; LONGHORN_DEVICE_UUID=
  STORAGE_PARTITION_START=$free_start; STORAGE_PARTITION_SIZE_GIB=$requested_gib
  STORAGE_PARTITION_END=$((free_start + requested_gib*1073741824 - 1))
  ((STORAGE_PARTITION_END<=free_end)) || die "Calculated partition exceeds the selected free region"
  info "Planned partition: ${requested_gib} GiB on $root_disk, filesystem label longhorn-data. No partition has been created."
}

select_dedicated_disk(){
  local root_disk device type children fstype mounts pttype answer model size
  local -a candidates=() menu_options=()
  root_disk=$(root_parent_disk || true); list_disks
  while read -r device type; do
    [[ $type == disk ]] || continue
    [[ -z $root_disk || $(readlink -f "$device") != "$root_disk" ]] || continue
    children=$(lsblk -nrpo NAME "$device" | wc -l); fstype=$(lsblk -dnro FSTYPE "$device"); mounts=$(lsblk -nrpo MOUNTPOINTS "$device" | sed '/^$/d'); pttype=$(lsblk -dnro PTTYPE "$device")
    ((children==1)) && [[ -z $fstype && -z $mounts && -z $pttype ]] || continue
    capacity_meets_minimum "$(block_capacity_gib "$device")" "$LONGHORN_DATA_MIN_GIB" || continue
    candidates+=("$device")
  done < <(lsblk -dnpo NAME,TYPE)
  if ((${#candidates[@]} == 0)); then
    warn "No safe empty disk of at least ${LONGHORN_DATA_MIN_GIB} GiB was found. No disk was changed."
    show_additional_storage_guidance
    return 1
  fi
  section 'Eligible empty disks'
  for device in "${candidates[@]}"; do model=$(lsblk -dnro MODEL "$device"); size=$(lsblk -dnro SIZE "$device"); menu_options+=("$device - $size - ${model:-unknown model}"); done
  while true; do
    menu_select answer 'Choose an empty Longhorn disk' 1 "${menu_options[@]}"
    [[ $answer =~ ^[0-9]+$ ]] && ((answer>=1 && answer<=${#candidates[@]})) && break
    warn "Choose a number from 1 to ${#candidates[@]}."
  done
  device=${candidates[answer-1]}
  STORAGE_MODE=dedicated-disk; STORAGE_DEVICE=$device; STORAGE_DEVICE_MAJMIN=$(lsblk -dnro MAJ:MIN "$device"); STORAGE_DESCRIPTION="erase $device ($(lsblk -dnro SIZE "$device")), create GPT and ext4 longhorn-data filesystem"; LONGHORN_PATH=$LONGHORN_STANDARD_PATH; LONGHORN_DEVICE_UUID=
  warn_small_longhorn_capacity "$(block_capacity_gib "$device")"
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
    os-lvm) create_lvm_volume;;
    dedicated-disk) prepare_empty_disk "$STORAGE_DEVICE";;
    *) die "No valid Longhorn storage plan was selected";;
  esac
}

select_storage(){
  local root_gib available_gib root_fstype root_disk root_disk_gib=unknown root_eligible=true default_choice=1 choice root_choice root_reason
  require_storage_inspection_tools
  root_gib=$(root_capacity_gib); available_gib=$(root_available_gib); root_disk=$(root_parent_disk || true)
  root_fstype=$(findmnt -no FSTYPE /)
  [[ -z $root_disk ]] || root_disk_gib=$(block_capacity_gib "$root_disk")
  if [[ $root_fstype != ext4 && $root_fstype != xfs ]] || ! capacity_meets_minimum "$root_gib" "$LONGHORN_ROOT_MIN_GIB" || ! capacity_meets_minimum "$available_gib" "$LONGHORN_ROOT_MIN_AVAILABLE_GIB"; then
    root_eligible=false
    if [[ -n $root_disk ]]; then default_choice=2; else default_choice=3; fi
  fi
  while true; do
    section 'Longhorn storage'
    cat <<EOF
Detected storage
  Root filesystem: ${root_gib} GiB total, ${available_gib} GiB available (${root_fstype})
  OS disk:         ${root_disk:-unknown} (${root_disk_gib} GiB)

Storage guidance

Root filesystem$($root_eligible || printf ' [UNAVAILABLE]')
   Requires ext4/XFS, ${LONGHORN_ROOT_MIN_GIB} GiB total and ${LONGHORN_ROOT_MIN_AVAILABLE_GIB} GiB available.
   Detected: ${root_fstype}, ${root_gib} GiB total and ${available_gib} GiB available.
   Longhorn reserves ${LONGHORN_ROOT_RESERVED_PERCENT}% for OS headroom, but this is not a hard quota.

Separate storage on the OS disk
   The installer detects both physical unallocated space and free Linux LVM
   extents, recommends a size, and never shrinks or moves existing data.

Separate physical or virtual disk (recommended for important data)
   Best isolation. SSD or NVMe is recommended. The disk must be empty.
   ${LONGHORN_DATA_RECOMMENDED_GIB} GiB is recommended.
   The ${LONGHORN_DATA_MIN_GIB} GiB installer floor is intended only for small labs.

All separate storage is mounted by UUID at $LONGHORN_STANDARD_PATH.
EOF
    printf '\n'
    root_choice='Use the root filesystem - simplest'
    if ! $root_eligible; then
      if [[ $root_fstype != ext4 && $root_fstype != xfs ]]; then
        root_reason="requires ext4 or XFS, detected $root_fstype"
      else
        root_reason="requires ${LONGHORN_ROOT_MIN_GIB} GiB total and ${LONGHORN_ROOT_MIN_AVAILABLE_GIB} GiB available"
      fi
      root_choice="${MENU_DISABLED_PREFIX}${root_choice} [Unavailable - $root_reason]"
    fi
    menu_select choice 'Choose Longhorn storage' "$default_choice" \
      "$root_choice" \
      'Create separate storage on the OS disk - guided partition or LVM' \
      'Use a separate physical or virtual disk - best isolation'
    case $choice in
      1) if select_root_storage; then return; fi;;
      2) if select_os_disk_partition; then return; fi;;
      3) if select_dedicated_disk; then return; fi;;
      *) warn 'Invalid storage selection';;
    esac
  done
}

validate_storage_selection(){
  local actual_uuid
  if [[ ${STORAGE_PROVIDER:-longhorn} != longhorn || ${STORAGE_MODE:-} == external ]]; then
    report 'Longhorn storage path' SKIP 'external storage selected'
    return 0
  fi
  [[ -d ${LONGHORN_PATH:-$LONGHORN_STANDARD_PATH} ]] || { report 'Longhorn storage path' MISSING 'not configured on this node'; return 1; }
  case ${STORAGE_MODE:-unknown} in
    root) report 'Longhorn storage path' OK 'shared root filesystem';;
    os-partition|os-new-partition|os-lvm|dedicated-disk)
      if ! findmnt -rn "$LONGHORN_PATH" >/dev/null; then report 'Longhorn storage mount' FAIL 'expected separate filesystem is not mounted'; return 1; fi
      actual_uuid=$(findmnt -no UUID "$LONGHORN_PATH" 2>/dev/null || true)
      if [[ -n ${LONGHORN_DEVICE_UUID:-} && $actual_uuid != "$LONGHORN_DEVICE_UUID" ]]; then report 'Longhorn storage UUID' FAIL 'mounted filesystem differs from installer state'; return 1; fi
      report 'Longhorn storage mount' OK "UUID=$actual_uuid"
      ;;
    *) report 'Longhorn storage path' WARN 'installer storage mode is unknown';;
  esac
}
