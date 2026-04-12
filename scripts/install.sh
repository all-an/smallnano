#!/bin/sh
set -eu

REPO="${SMALLNANO_REPO:-all-an/smallnano}"
VERSION="${SMALLNANO_VERSION:-latest}"
PREFIX="${SMALLNANO_PREFIX:-/usr/local/bin}"
SYSTEMD_DIR="${SMALLNANO_SYSTEMD_DIR:-/etc/systemd/system}"
CONFIG_DIR="${SMALLNANO_CONFIG_DIR:-/etc/smallnano}"
STATE_DIR="${SMALLNANO_STATE_DIR:-/var/lib/smallnano}"

detect_target() {
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Linux) os_part="linux-musl" ;;
    Darwin) os_part="macos" ;;
    *)
      echo "unsupported OS: $os" >&2
      exit 1
      ;;
  esac

  case "$arch" in
    x86_64|amd64) arch_part="x86_64" ;;
    arm64|aarch64) arch_part="aarch64" ;;
    *)
      echo "unsupported architecture: $arch" >&2
      exit 1
      ;;
  esac

  printf '%s-%s\n' "$arch_part" "$os_part"
}

target="$(detect_target)"
archive="smallnano-${target}.tar.gz"

if [ "$VERSION" = "latest" ]; then
  url="https://github.com/${REPO}/releases/latest/download/${archive}"
else
  url="https://github.com/${REPO}/releases/download/${VERSION}/${archive}"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

echo "downloading ${url}"
curl -fsSL "$url" -o "${tmpdir}/${archive}"
tar -C "$tmpdir" -xzf "${tmpdir}/${archive}"

root="${tmpdir}/smallnano-${target}"

install -d "$PREFIX" "$CONFIG_DIR" "$STATE_DIR"
install -m 0755 "${root}/smallnano" "${PREFIX}/smallnano"

if [ -d "$SYSTEMD_DIR" ] && [ -f "${root}/smallnano.service" ]; then
  install -m 0644 "${root}/smallnano.service" "${SYSTEMD_DIR}/smallnano.service"
fi

echo "installed ${PREFIX}/smallnano"
echo "config dir: ${CONFIG_DIR}"
echo "state dir: ${STATE_DIR}"
echo "review ${CONFIG_DIR}/config.toml before enabling the service"
