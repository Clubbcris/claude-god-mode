# Stage 2: install everything into the rootfs.

stage_chroot() {
  log "Preparing chroot"
  mount_chroot
  configure_proxy

  # Keep daemons from starting (and failing) inside the chroot.
  cat > "${ROOT}/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
exit 101
POLICY
  chmod +x "${ROOT}/usr/sbin/policy-rc.d"
  chroot "$ROOT" dpkg-divert --local --rename --add /sbin/initctl >/dev/null
  ln -sf /bin/true "${ROOT}/sbin/initctl"

  rm -rf "${ROOT}/tmp/build"
  mkdir -p "${ROOT}/tmp/build"
  cp -a "${HERE}/config/." "${ROOT}/tmp/build/"

  log "Running chroot-setup.sh inside the rootfs"
  chroot "$ROOT" /usr/bin/env \
    OS_NAME="$OS_NAME" OS_ID="$OS_ID" OS_VERSION="$OS_VERSION" \
    UBUNTU_SUITE="$UBUNTU_SUITE" NODE_VERSION="$NODE_VERSION" \
    LIVE_USER="$LIVE_USER" LIVE_HOST="$LIVE_HOST" \
    DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 \
    /bin/bash /tmp/build/chroot-setup.sh

  log "Removing build-host state from the image"
  unconfigure_proxy
  rm -f "${ROOT}/usr/sbin/policy-rc.d"
  rm -f "${ROOT}/sbin/initctl"
  chroot "$ROOT" dpkg-divert --rename --remove /sbin/initctl >/dev/null
  chroot "$ROOT" apt-get clean
  rm -rf "${ROOT}/tmp/build" "${ROOT}/var/lib/apt/lists"/*
  rm -rf "${ROOT}/var/log"/*.log "${ROOT}/var/log"/*/*.log
  rm -f  "${ROOT}/root/.bash_history" "${ROOT}/etc/resolv.conf"
  # resolv.conf is managed by NetworkManager on the booted system.
  ln -sf ../run/systemd/resolve/stub-resolv.conf "${ROOT}/etc/resolv.conf"
  : > "${ROOT}/etc/machine-id"

  cleanup
}
