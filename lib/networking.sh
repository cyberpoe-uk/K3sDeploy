#!/usr/bin/env bash
detect_interface(){ ip -4 route show default 2>/dev/null | awk 'NR==1{print $5}'; }
detect_node_ip(){ local dev=${1:-$(detect_interface)}; ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk 'NR==1{sub(/\/.*/,"",$4);print $4}'; }
port_reachable(){ timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }
local_ipv4_present(){ ip -4 -o addr show scope global | awk '{sub(/\/.*/,"",$4); print $4}' | grep -Fxq "$1"; }
vip_conflict_check(){ local vip=$1 iface=$2; if command -v arping >/dev/null; then if arping -D -c 2 -I "$iface" "$vip" >/dev/null 2>&1; then ok "VIP $vip is currently unclaimed"; else warn "VIP $vip responds on $iface (expected for an existing cluster; investigate for a new cluster)"; fi; else warn "arping unavailable; could not test address ownership"; fi; }

JOIN_CHECK_TEMP_DIR=
cleanup_join_check(){
  if [[ -n ${JOIN_CHECK_TEMP_DIR:-} && -d $JOIN_CHECK_TEMP_DIR && $JOIN_CHECK_TEMP_DIR == /tmp/k3sdeploy-join-check-* ]]; then
    rm -rf -- "$JOIN_CHECK_TEMP_DIR"
  fi
  JOIN_CHECK_TEMP_DIR=
}

k3s_ca_hash(){
  local bundle=$1 count cert_dir cert subject issuer
  count=$(grep -c -- '-----END CERTIFICATE-----' "$bundle" || true)
  ((count > 0)) || return 1
  if ((count == 1)); then
    sha256sum "$bundle" | awk '{print $1}'
    return
  fi

  command -v openssl >/dev/null 2>&1 || return 1
  cert_dir=$(mktemp -d -t k3sdeploy-certs-XXXXXX)
  awk -v dir="$cert_dir" '
    /-----BEGIN CERTIFICATE-----/ { n++; file=sprintf("%s/cert-%d.pem", dir, n) }
    n { print > file }
  ' "$bundle"
  for cert in "$cert_dir"/cert-*.pem; do
    subject=$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null || true)
    issuer=$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253 2>/dev/null || true)
    if [[ -n $subject && ${subject#subject=} == "${issuer#issuer=}" ]]; then
      openssl x509 -in "$cert" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
      rm -rf -- "$cert_dir"
      return
    fi
  done
  rm -rf -- "$cert_dir"
  return 1
}

verify_existing_cluster_token(){
  local role=$1 token=$2 endpoint expected_hash token_user token_password
  local temp_dir ca_file curl_config actual_hash escaped_user escaped_password

  if [[ ! $token =~ ^K10([a-fA-F0-9]{64})::([^:]+):(.+)$ ]]; then
    die "Use the full secure token beginning with K10. Copy it from /var/lib/rancher/k3s/server/token on an existing manager."
  fi
  expected_hash=${BASH_REMATCH[1],,}
  token_user=${BASH_REMATCH[2]}
  token_password=${BASH_REMATCH[3]}
  if [[ $role == server && $token_user != server ]]; then
    die "This is not a K3s server token. A manager must use /var/lib/rancher/k3s/server/token from an existing manager."
  fi

  temp_dir=$(mktemp -d /tmp/k3sdeploy-join-check-XXXXXX)
  JOIN_CHECK_TEMP_DIR=$temp_dir
  ca_file=$temp_dir/cacerts.pem
  curl_config=$temp_dir/curl.conf
  chmod 700 "$temp_dir"

  if ! curl --fail --silent --show-error --insecure --connect-timeout 3 --max-time 10 \
      "https://$API_VIP:6443/cacerts" --output "$ca_file"; then
    cleanup_join_check
    die "A K3s manager could not be reached at $API_VIP:6443. Create the first manager with option 1, or check the VIP and network."
  fi
  actual_hash=$(k3s_ca_hash "$ca_file" || true)
  if [[ -z $actual_hash || $actual_hash != "$expected_hash" ]]; then
    cleanup_join_check
    die "The token does not match the K3s cluster CA at $API_VIP. Check that you entered the existing cluster's VIP and full token."
  fi

  endpoint=/v1-k3s/config
  [[ $role == server ]] && endpoint=/v1-k3s/server-bootstrap
  escaped_user=${token_user//\\/\\\\}; escaped_user=${escaped_user//\"/\\\"}
  escaped_password=${token_password//\\/\\\\}; escaped_password=${escaped_password//\"/\\\"}
  printf 'user = "%s:%s"\n' "$escaped_user" "$escaped_password" >"$curl_config"
  chmod 600 "$curl_config" "$ca_file"

  if ! curl --fail --silent --show-error --cacert "$ca_file" --config "$curl_config" \
      --connect-timeout 3 --max-time 15 "https://$API_VIP:6443$endpoint" --output /dev/null; then
    cleanup_join_check
    if [[ $role == server ]]; then
      die "The manager rejected this server token. Copy /var/lib/rancher/k3s/server/token from a healthy manager and try again."
    fi
    die "The cluster rejected this join token. Copy a current server or agent token from a healthy manager and try again."
  fi
  cleanup_join_check
  ok "Existing K3s cluster and join token verified at $API_VIP:6443"
}
