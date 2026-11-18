# Stage 1: bootstrap a minimal Ubuntu rootfs.

stage_rootfs() {
  log "debootstrap ${UBUNTU_SUITE} ${ARCH} -> ${ROOT}"
  rm -rf "$ROOT"
  mkdir -p "$ROOT"
  debootstrap \
    --arch="${ARCH}" \
    --variant=minbase \
    --components=main,universe,multiverse,restricted \
    "${UBUNTU_SUITE}" "${ROOT}" "${UBUNTU_MIRROR}"

  log "Writing apt sources"
  cat > "${ROOT}/etc/apt/sources.list" <<SOURCES
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE} main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE}-updates main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE}-backports main restricted universe multiverse
deb https://security.ubuntu.com/ubuntu/ ${UBUNTU_SUITE}-security main restricted universe multiverse
SOURCES

  echo "${LIVE_HOST}" > "${ROOT}/etc/hostname"
  cat > "${ROOT}/etc/hosts" <<HOSTS
127.0.0.1	localhost
127.0.1.1	${LIVE_HOST}
::1		localhost ip6-localhost ip6-loopback
HOSTS
}

# Bind the host's kernel interfaces into the rootfs so apt maintainer
# scripts and update-initramfs behave as they do on a real system.
mount_chroot() {
  mount -t proc  proc  "${ROOT}/proc"
  mount -t sysfs sys   "${ROOT}/sys"
  mount --bind /dev    "${ROOT}/dev"
  mount -t devpts devpts "${ROOT}/dev/pts"
  mount -t tmpfs tmpfs "${ROOT}/dev/shm"
  mount -t tmpfs tmpfs "${ROOT}/run"
  # systemd-resolved's postinst turns this into a symlink into /run, which
  # dangles against the tmpfs we just mounted, so replace it outright.
  rm -f "${ROOT}/etc/resolv.conf"
  cp -f /etc/resolv.conf "${ROOT}/etc/resolv.conf"
}

# The build host may sit behind an intercepting HTTPS proxy with a private
# CA. Teach the chroot about it, then strip every trace in unconfigure_proxy
# so the shipped image has no build-host state baked in.
configure_proxy() {
  [[ -n "${HTTPS_PROXY:-}" ]] || return 0
  log "Build host uses a proxy (${HTTPS_PROXY}); wiring it into the chroot temporarily"
  cat > "${ROOT}/etc/apt/apt.conf.d/01build-proxy" <<PROXY
Acquire::https::Proxy "${HTTPS_PROXY}";
Acquire::http::Proxy  "${HTTPS_PROXY}";
PROXY
  # The proxy's private CA must be trusted inside the chroot, both in the
  # system store and at the literal path the inherited *_CA_BUNDLE env vars
  # point at, or curl inside the chroot fails to load its CA bundle.
  local bundle="${CURL_CA_BUNDLE:-}"
  if [[ -n "$bundle" && -f "$bundle" ]]; then
    mkdir -p "${ROOT}/usr/local/share/ca-certificates" "${ROOT}$(dirname "$bundle")"
    cp -f "$bundle" "${ROOT}/usr/local/share/ca-certificates/build-proxy.crt"
    cp -f "$bundle" "${ROOT}${bundle}"
    echo "$bundle" > "${WORK}/.proxy-bundle-path"
  fi
}

unconfigure_proxy() {
  rm -f "${ROOT}/etc/apt/apt.conf.d/01build-proxy"
  rm -f "${ROOT}/usr/local/share/ca-certificates/build-proxy.crt"
  if [[ -f "${WORK}/.proxy-bundle-path" ]]; then
    rm -f "${ROOT}$(cat "${WORK}/.proxy-bundle-path")"
    rm -f "${WORK}/.proxy-bundle-path"
  fi
  chroot "$ROOT" update-ca-certificates --fresh >/dev/null 2>&1 || true
}
