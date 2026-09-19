#!/usr/bin/env bash
security_updates_supported(){ [[ ${OS_PACKAGE_MANAGER:-unsupported} == apt ]]; }
configure_updates(){ security_updates_supported || { warn "Automatic security-update configuration is not available for $OS_NAME. Use the operating system's native update policy."; return 1; }; package_refresh; package_install unattended-upgrades; local cfg
  # Literal apt placeholders are expanded by unattended-upgrades, not this shell.
  # shellcheck disable=SC2016
  cfg='APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };
'; write_root_file /etc/apt/apt.conf.d/52k3s-bootstrap-security 644 "$cfg" || true; ok "Security-only unattended upgrades enabled; automatic reboot disabled"; }
