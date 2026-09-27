#!/usr/bin/env bash
#
# install-driver.sh
#
# Universal installer for the 10moons T503 tablet Linux driver:
#   - Clones/updates the repo (default: /opt/10moons-driver)
#   - Installs system dependencies (package manager auto-detected)
#   - Creates a Python venv and installs Python dependencies into it
#   - Auto-detects the tablet vendor_id/product_id (override with --vid/--pid)
#   - Installs a udev rule (rootless USB + uinput access, plug-and-play trigger)
#   - Installs and enables a background service (init system auto-detected:
#     systemd, OpenRC, runit, or udev-only fallback)
#
# Usage:
#   sudo bash install-driver.sh [options]
#
# Options:
#   --vid HEX      USB vendor ID, e.g. 08f2 (auto-detected when omitted)
#   --pid HEX      USB product ID, e.g. 6811 (auto-detected when omitted)
#   --repo URL     Git repo URL to install from
#   --dir PATH     Install directory (default: /opt/10moons-driver)
#   --yes          Assume yes for package manager prompts
#   --uninstall    Remove service, udev rule and installed files, then exit
#   -h, --help     Show this help and exit
#
set -euo pipefail

REPO_URL="https://github.com/zavzagali/10moons-t503-driver.git"
INSTALL_DIR="/opt/10moons-driver"
SERVICE_NAME="10moons-driver"
UDEV_RULE_FILE="/etc/udev/rules.d/99-10moons-t503.rules"
ASSUME_YES=0
UNINSTALL=0
VID_ARG=""
PID_ARG=""

# Known tablet USB IDs (vid:pid, lowercase) used for auto-detection.
KNOWN_IDS=("08f2:6811")

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*" >&2; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vid)       VID_ARG="${2:-}"; shift 2 ;;
        --pid)       PID_ARG="${2:-}"; shift 2 ;;
        --repo)      REPO_URL="${2:-}"; shift 2 ;;
        --dir)       INSTALL_DIR="${2:-}"; shift 2 ;;
        --yes)       ASSUME_YES=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "Unknown option: $1 (see --help)" ;;
    esac
done

# --- Root check -----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    die "This script must run as root: sudo bash $0"
fi

# --- Init system detection --------------------------------------------------
# Returns one of: systemd, openrc, runit, none.
detect_init() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        echo systemd
    elif { command -v rc-service >/dev/null 2>&1 || command -v rc-update >/dev/null 2>&1; } \
            && [[ -d /run/openrc || -d /var/lib/openrc ]]; then
        echo openrc
    elif [[ -d /run/runit || -d /run/runit/runsvdir ]] && command -v sv >/dev/null 2>&1; then
        echo runit
    else
        echo none
    fi
}

# --- Package manager detection -----------------------------------------------
PKG_MANAGER=""
detect_pkg_manager() {
    for pm in apt-get dnf pacman zypper apk xbps-install; do
        if command -v "$pm" >/dev/null 2>&1; then
            PKG_MANAGER="$pm"
            return 0
        fi
    done
    return 1
}

# --- Uninstall ----------------------------------------------------------------
uninstall_driver() {
    local init
    init="$(detect_init)"
    log "Uninstalling (init system: $init)..."

    case "$init" in
        systemd)
            systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
            rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
            systemctl daemon-reload 2>/dev/null || true
            ;;
        openrc)
            rc-update del "$SERVICE_NAME" default 2>/dev/null || true
            rc-service "$SERVICE_NAME" stop 2>/dev/null || true
            rm -f "/etc/init.d/$SERVICE_NAME"
            ;;
        runit)
            rm -f /var/service/"$SERVICE_NAME" /service/"$SERVICE_NAME" 2>/dev/null || true
            rm -rf /etc/sv/"$SERVICE_NAME"
            ;;
    esac

    rm -f "$UDEV_RULE_FILE"
    command -v udevadm >/dev/null 2>&1 && udevadm control --reload-rules || true

    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        log "Removed $INSTALL_DIR"
    fi
    log "Uninstall complete."
}

if [[ $UNINSTALL -eq 1 ]]; then
    uninstall_driver
    exit 0
fi

# --- System dependencies -------------------------------------------------------
install_system_deps() {
    if ! detect_pkg_manager; then
        warn "No supported package manager found (apt/dnf/pacman/zypper/apk/xbps)."
        warn "Please install manually: git, python3, python3-venv, libusb."
        return 0
    fi
    log "Package manager: $PKG_MANAGER"

    local pkgs=()
    case "$PKG_MANAGER" in
        apt-get) pkgs=(git python3 python3-venv libusb-1.0-0) ;;
        dnf)     pkgs=(git python3 python3-pip libusb1) ;;
        pacman)  pkgs=(git python python-pip libusb) ;;
        zypper)  pkgs=(git python3 python3-pip libusb-1_0-0) ;;
        apk)     pkgs=(git python3 py3-pip libusb) ;;
        xbps-install) pkgs=(git python3 python3-pip libusb) ;;
    esac

    case "$PKG_MANAGER" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || warn "apt-get update failed, continuing anyway."
            if [[ $ASSUME_YES -eq 1 ]]; then
                apt-get install -qq -y "${pkgs[@]}"
            else
                apt-get install "${pkgs[@]}"
            fi
            ;;
        dnf)
            if [[ $ASSUME_YES -eq 1 ]]; then
                dnf install -y "${pkgs[@]}"
            else
                dnf install "${pkgs[@]}"
            fi
            ;;
        pacman)
            if [[ $ASSUME_YES -eq 1 ]]; then
                pacman -S --noconfirm --needed "${pkgs[@]}"
            else
                pacman -S --needed "${pkgs[@]}"
            fi
            ;;
        zypper)
            if [[ $ASSUME_YES -eq 1 ]]; then
                zypper --non-interactive install "${pkgs[@]}"
            else
                zypper install "${pkgs[@]}"
            fi
            ;;
        apk)
            apk add "${pkgs[@]}"
            ;;
        xbps-install)
            if [[ $ASSUME_YES -eq 1 ]]; then
                xbps-install -Sy "${pkgs[@]}"
            else
                xbps-install -S "${pkgs[@]}"
            fi
            ;;
    esac || die "Failed to install system packages."
}

# --- Clone / update the repo ----------------------------------------------------
# Local edits to tracked files block fast-forward pulls; in that case keep the
# local copy and warn instead of aborting the whole install.
update_repo() {
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        log "Repo already exists, updating..."
        if git -C "$INSTALL_DIR" pull --ff-only; then
            log "Repo updated."
        else
            warn "Could not fast-forward (local changes?). Keeping the current copy."
        fi
    else
        log "Cloning repo: $REPO_URL -> $INSTALL_DIR"
        git clone "$REPO_URL" "$INSTALL_DIR" \
            || die "git clone failed. Check the URL and your network connection."
    fi
}

# --- Python environment ----------------------------------------------------------
# Prefers a venv inside the install dir; falls back to pip --target so the
# system Python stays untouched when venv creation is unavailable.
DRIVER_PYTHON=""
DRIVER_ENV_FILE=""
setup_python_env() {
    local venv_py="$INSTALL_DIR/.venv/bin/python"
    if python3 -m venv "$INSTALL_DIR/.venv" 2>/dev/null \
            && [[ -x "$venv_py" ]]; then
        log "Installing Python dependencies into the venv..."
        "$venv_py" -m pip install -q -r "$INSTALL_DIR/requirements.txt" \
            || die "pip install failed."
        DRIVER_PYTHON="$venv_py"
    else
        warn "Could not create a venv, falling back to pip --target."
        mkdir -p "$INSTALL_DIR/lib"
        if python3 -m pip install -q --target="$INSTALL_DIR/lib" \
                --break-system-packages -r "$INSTALL_DIR/requirements.txt" 2>/dev/null \
        || python3 -m pip install -q --target="$INSTALL_DIR/lib" \
                -r "$INSTALL_DIR/requirements.txt"; then
            DRIVER_ENV_FILE="$INSTALL_DIR/driver.env"
            echo "PYTHONPATH=$INSTALL_DIR/lib" > "$DRIVER_ENV_FILE"
            DRIVER_PYTHON="$(command -v python3)"
        else
            die "pip install failed and no venv is available."
        fi
    fi
}

# --- VID/PID detection ---------------------------------------------------------------
# Priority: --vid/--pid flags > lsusb auto-detection > values in config.yaml.
detect_ids() {
    local vid="$VID_ARG" pid="$PID_ARG"

    if [[ -z "$vid" || -z "$pid" ]] && command -v lsusb >/dev/null 2>&1; then
        while read -r line; do
            local id
            id="$(echo "$line" | grep -oiE '[0-9a-f]{4}:[0-9a-f]{4}' | head -n1 || true)"
            [[ -z "$id" ]] && continue
            id="$(echo "$id" | tr 'A-F' 'a-f')"
            if echo "$line" | grep -qiE '10moon|tablet'; then
                vid="${id%%:*}"; pid="${id##*:}"; break
            fi
            for known in "${KNOWN_IDS[@]}"; do
                if [[ "$id" == "$known" ]]; then
                    vid="${id%%:*}"; pid="${id##*:}"; break 2
                fi
            done
        done < <(lsusb 2>/dev/null || true)
    fi

    if [[ -z "$vid" || -z "$pid" ]]; then
        # Fall back to config.yaml (parsed with the venv python, which has yaml).
        local cfg
        if cfg="$("$DRIVER_PYTHON" - "$INSTALL_DIR/config.yaml" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
vid, pid = cfg["vendor_id"], cfg["product_id"]
if isinstance(vid, str):
    vid = int(vid, 0)
if isinstance(pid, str):
    pid = int(pid, 0)
print(f"{vid:04x} {pid:04x}")
PYEOF
        )"; then
            read -r vid pid <<< "$cfg"
        fi
    fi

    # Normalize: strip an optional 0x prefix, udev/sysfs want bare hex.
    vid="${vid#0x}"; vid="${vid#0X}"
    pid="${pid#0x}"; pid="${pid#0X}"
    [[ -n "${vid:-}" && -n "${pid:-}" ]] || die "Could not determine VID/PID. Plug in the tablet or pass --vid/--pid."
    VID_HEX="$(echo "$vid" | tr 'A-F' 'a-f')"
    PID_HEX="$(echo "$pid" | tr 'A-F' 'a-f')"
    log "Using vendor_id=0x$VID_HEX product_id=0x$PID_HEX"
}

# Stamp the effective IDs into the installed config.yaml so the driver,
# the udev rule and future updates all agree.
stamp_config_ids() {
    "$DRIVER_PYTHON" - "$INSTALL_DIR/config.yaml" "$VID_HEX" "$PID_HEX" <<'PYEOF'
import sys
path, vid, pid = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    text = f.read()
import re
text = re.sub(r'^vendor_id:.*$', f'vendor_id: 0x{vid}', text, flags=re.M)
text = re.sub(r'^product_id:.*$', f'product_id: 0x{pid}', text, flags=re.M)
with open(path, 'w') as f:
    f.write(text)
PYEOF
}

# --- udev rule ------------------------------------------------------------------------
write_udev_rule() {
    local init="$1" extra="" run_extra=""
    if [[ "$init" == "systemd" ]]; then
        extra=' TAG+="systemd", ENV{SYSTEMD_WANTS}="'"${SERVICE_NAME}.service"'"'
    elif [[ "$init" == "openrc" ]]; then
        # OpenRC has no device-activated services, so start it from udev on hotplug.
        run_extra=', RUN+="/etc/init.d/'"${SERVICE_NAME}"' start"'
    fi
    log "Writing udev rule: $UDEV_RULE_FILE"
    cat > "$UDEV_RULE_FILE" <<EOF
# 10moons T503 tablet - auto-generated by install-driver.sh (do not edit manually,
# re-run the installer instead).

# Rootless USB access for the tablet; on systemd also triggers the driver service.
SUBSYSTEM=="usb", ATTR{idVendor}=="${VID_HEX}", ATTR{idProduct}=="${PID_HEX}", \\
    MODE="0666", TAG+="uaccess"${extra}${run_extra}

# Access to the virtual pen/button devices created via uinput.
KERNEL=="uinput", MODE="0660", GROUP="input", TAG+="uaccess"
EOF
}

# --- Service installation ------------------------------------------------------------------
write_systemd_service() {
    local file="/etc/systemd/system/${SERVICE_NAME}.service" env_line=""
    [[ -n "$DRIVER_ENV_FILE" ]] && env_line="EnvironmentFile=$DRIVER_ENV_FILE"
    log "Writing systemd service: $file"
    cat > "$file" <<EOF
[Unit]
Description=10moons T503 Tablet Driver
After=multi-user.target
# Stop retrying when the tablet is unplugged; plugging it back in
# re-triggers the service through the udev rule.
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${DRIVER_PYTHON} ${INSTALL_DIR}/driver.py
WorkingDirectory=${INSTALL_DIR}
${env_line}
Restart=on-failure
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
}

write_openrc_service() {
    local file="/etc/init.d/$SERVICE_NAME"
    log "Writing OpenRC service: $file"
    cat > "$file" <<EOF
#!/sbin/openrc-run
# 10moons T503 tablet driver - auto-generated by install-driver.sh
name="$SERVICE_NAME"
command="${DRIVER_PYTHON}"
command_args="${INSTALL_DIR}/driver.py"
command_background=true
pidfile="/run/${SERVICE_NAME}.pid"
directory="${INSTALL_DIR}"
depend() {
    need local
}
EOF
    chmod +x "$file"
    if [[ -n "$DRIVER_ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        set -a; . "$DRIVER_ENV_FILE"; set +a
        sed -i "s|^command=|export PYTHONPATH=\"$INSTALL_DIR/lib\"\ncommand=|" "$file"
    fi
    rc-update add "$SERVICE_NAME" default 2>/dev/null \
        || warn "Could not add the service to the default runlevel."
}

write_runit_service() {
    local dir="/etc/sv/$SERVICE_NAME" link_dir="" pyenv_line=""
    log "Writing runit service: $dir"
    mkdir -p "$dir"
    [[ -n "$DRIVER_ENV_FILE" ]] && pyenv_line="export PYTHONPATH=\"$INSTALL_DIR/lib\""
    # The wait loop avoids a tight respawn cycle while the tablet is unplugged:
    # runsv restarts the script, the script waits for the device, then execs.
    cat > "$dir/run" <<EOF
#!/bin/sh
# 10moons T503 tablet driver - auto-generated by install-driver.sh
${pyenv_line}
exec 2>&1
while :; do
    for dev in /sys/bus/usb/devices/*; do
        if [ "\$(cat "\$dev/idVendor" 2>/dev/null)" = "$VID_HEX" ] && \\
           [ "\$(cat "\$dev/idProduct" 2>/dev/null)" = "$PID_HEX" ]; then
            exec ${DRIVER_PYTHON} ${INSTALL_DIR}/driver.py
        fi
    done
    sleep 2
done
EOF
    chmod +x "$dir/run"
    if [[ -d /var/service ]]; then
        link_dir=/var/service
    elif [[ -d /service ]]; then
        link_dir=/service
    fi
    if [[ -n "$link_dir" ]]; then
        ln -sfn "$dir" "$link_dir/$SERVICE_NAME"
    else
        warn "No runit service directory found; start it manually: sv start $dir"
    fi
}

install_service() {
    local init="$1"
    case "$init" in
        systemd) write_systemd_service ;;
        openrc)  write_openrc_service ;;
        runit)   write_runit_service ;;
        none)
            warn "No supported init system found; skipping service installation."
            echo "Run the driver manually after plugging in the tablet:"
            echo "  sudo ${DRIVER_PYTHON} ${INSTALL_DIR}/driver.py"
            ;;
    esac
}

# --- Main ---------------------------------------------------------------------------
INIT="$(detect_init)"
log "Init system: $INIT"

for cmd in git python3; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found. Install it and re-run."
done

install_system_deps
update_repo
setup_python_env
detect_ids
stamp_config_ids
write_udev_rule "$INIT"
install_service "$INIT"

# Add the invoking user to the input group for uinput access.
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
log "Adding user to the input group: $REAL_USER"
usermod -aG input "$REAL_USER" 2>/dev/null \
    || warn "Could not add $REAL_USER to the input group, check manually."

if command -v udevadm >/dev/null 2>&1; then
    log "Reloading udev rules..."
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=usb --action=add 2>/dev/null || true
fi

log "Install complete."
echo
echo "  -> Unplug and replug the tablet, then check:"
case "$INIT" in
    systemd) echo "       systemctl status ${SERVICE_NAME}.service" ;;
    openrc)  echo "       rc-service $SERVICE_NAME status" ;;
    runit)   echo "       sv status $SERVICE_NAME" ;;
esac
echo "  -> You may need to log out and back in for the group change to apply."
