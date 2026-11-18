#!/usr/bin/env bash
# Runs INSIDE the chroot. Installs the desktop, Node 22, Claude Code and Chrome.
set -euo pipefail
BUILD=/tmp/build
say() { printf '\n\033[1;36m  --\033[0m %s\n' "$*"; }

export DEBIAN_FRONTEND=noninteractive
export PATH=/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

say "apt update"
apt-get update -qq

# snapd makes application launches visibly slower and is never wanted here.
# A negative pin means apt refuses to pull it in as a dependency, loudly,
# rather than silently installing it.
cat > /etc/apt/preferences.d/no-snapd <<'PIN'
Package: snapd
Pin: release a=*
Pin-Priority: -10
PIN

say "Generating locale"
apt-get install -y -qq locales >/dev/null
sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen >/dev/null
update-locale LANG=en_US.UTF-8

say "Installing $(grep -vcE '^\s*(#|$)' "$BUILD/packages.base") packages (this is the slow part)"
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$BUILD/packages.base")
apt-get install -y "${PKGS[@]}"

say "Installing Node ${NODE_VERSION}"
cd /tmp
TARBALL="node-${NODE_VERSION}-linux-x64.tar.xz"
curl -fsSL --retry 3 -o "$TARBALL" "https://nodejs.org/dist/${NODE_VERSION}/${TARBALL}"
curl -fsSL --retry 3 -o SHASUMS256.txt "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt"
grep " ${TARBALL}\$" SHASUMS256.txt | sha256sum -c -
mkdir -p /opt/node
tar -xJf "$TARBALL" -C /opt/node --strip-components=1
rm -f "$TARBALL" SHASUMS256.txt
for b in node npm npx; do ln -sf "/opt/node/bin/$b" "/usr/local/bin/$b"; done
cat > /etc/profile.d/10-node.sh <<'PROF'
export PATH="/opt/node/bin:$PATH"
PROF
chmod +x /etc/profile.d/10-node.sh
node --version

say "Installing Claude Code"
npm install -g --no-fund --no-audit @anthropic-ai/claude-code
ln -sf /opt/node/bin/claude /usr/local/bin/claude
test -x /opt/node/bin/claude || { echo "FATAL: claude binary missing after npm install"; exit 1; }
claude --version || echo "  (claude --version needs a TTY; binary is present)"

say "Installing Google Chrome"
curl -fsSL --retry 3 -o /tmp/chrome.deb \
  https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
apt-get install -y /tmp/chrome.deb
rm -f /tmp/chrome.deb
test -x /opt/google/chrome/chrome || { echo "FATAL: chrome missing"; exit 1; }

say "Applying system overlay"
cp -a "$BUILD/overlay/." /
chmod 0755 /usr/local/bin/godmode /usr/local/bin/godmode-welcome /usr/local/bin/godmode-tune
chmod 0440 /etc/sudoers.d/90-godmode
chmod 0755 /etc/skel /etc/skel/.config 2>/dev/null || true

say "Configuring the live session user (${LIVE_USER})"
cat > /etc/casper.conf <<CASPER
export USERNAME="${LIVE_USER}"
export USERFULLNAME="${OS_NAME} Live"
export HOST="${LIVE_HOST}"
export BUILD_SYSTEM="Ubuntu"
export FLAVOUR="${OS_NAME}"
CASPER

say "Branding"
cat > /etc/os-release <<OSR
PRETTY_NAME="${OS_NAME} ${OS_VERSION}"
NAME="${OS_NAME}"
VERSION_ID="${OS_VERSION}"
VERSION="${OS_VERSION}"
ID=${OS_ID}
ID_LIKE="ubuntu debian"
HOME_URL="https://github.com/clubbcris/claude-god-mode"
UBUNTU_CODENAME=${UBUNTU_SUITE}
OSR
cp -f /etc/os-release /usr/lib/os-release
echo "${OS_NAME} ${OS_VERSION} \\n \\l" > /etc/issue

say "Enabling services"
systemctl enable zramswap.service     >/dev/null 2>&1 || true
systemctl enable earlyoom.service     >/dev/null 2>&1 || true
systemctl enable irqbalance.service   >/dev/null 2>&1 || true
systemctl enable thermald.service     >/dev/null 2>&1 || true
systemctl enable tlp.service          >/dev/null 2>&1 || true
systemctl enable fstrim.timer         >/dev/null 2>&1 || true
systemctl enable NetworkManager.service >/dev/null 2>&1 || true
systemctl enable lightdm.service      >/dev/null 2>&1 || true

say "Disabling what only costs boot time"
# NetworkManager-wait-online blocks boot until the network is up; nothing
# in this image needs it, and it routinely adds 15-30s on a laptop.
systemctl disable NetworkManager-wait-online.service >/dev/null 2>&1 || true
systemctl mask    NetworkManager-wait-online.service >/dev/null 2>&1 || true
for s in apport.service whoopsie.service kerneloops.service \
         systemd-networkd.service systemd-networkd-wait-online.service; do
  systemctl disable "$s" >/dev/null 2>&1 || true
  systemctl mask    "$s" >/dev/null 2>&1 || true
done
sed -i 's/^enabled=1/enabled=0/' /etc/default/apport 2>/dev/null || true

say "Rebuilding initramfs with casper"
update-initramfs -u -k all

say "chroot setup complete"
