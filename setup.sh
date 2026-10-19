#!/bin/sh
# Spud — zero-footprint reverse tunnel installer
# Uses bore.pub as relay, ntfy.sh for push notifications.
# No VPS needed. No account needed.
#
# Usage (run as root on potato):
#   curl -fsSL https://raw.githubusercontent.com/rex/spud/main/setup.sh | sh
#
# ── Configure these before publishing ────────────────────────────────────
ADMIN_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMvKicOMTrRyFyWzYyEMn+WQ+9TYJ7YDhGo4NGPEktat spud-admin"
NTFY_TOPIC_PREFIX="spud-k9x2mq7r4p"
# Final ntfy topic per machine = $NTFY_TOPIC_PREFIX-$(hostname)
# Subscribe on phone: ntfy app → + → ntfy.sh/$NTFY_TOPIC_PREFIX-*
# ─────────────────────────────────────────────────────────────────────────

set -eu

SPUD_DIR="/etc/spud"
HOST_KEY="$SPUD_DIR/host_key"
BORE_BIN="$SPUD_DIR/bore"
LOOP_SCRIPT="$SPUD_DIR/tunnel-loop.sh"

log() { printf '[spud] %s\n' "$*"; }
die() { printf '[spud] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Fetch helpers ─────────────────────────────────────────────────────────
fetch_url() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$1"
    else
        die "Need curl or wget"
    fi
}

fetch_to_file() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        die "Need curl or wget"
    fi
}

fetch_post() {
    local url="$1" data="$2" header="$3"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -X POST -H "$header" -d "$data" "$url" >/dev/null 2>&1 || true
    elif command -v wget >/dev/null 2>&1; then
        wget -qO /dev/null --post-data="$data" --header="$header" "$url" 2>/dev/null || true
    fi
}

# ── Arch detection ────────────────────────────────────────────────────────
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)         echo "x86_64-unknown-linux-musl" ;;
        aarch64|arm64)        echo "aarch64-unknown-linux-musl" ;;
        armv7l|armv7*)        echo "armv7-unknown-linux-musleabihf" ;;
        armv6l|armv6*)        echo "arm-unknown-linux-musleabihf" ;;
        mipsel|mipsle)        echo "mipsel-unknown-linux-musl" ;;
        mips)                 echo "mips-unknown-linux-musl" ;;
        i386|i486|i586|i686) echo "i686-unknown-linux-musl" ;;
        riscv64)              echo "riscv64gc-unknown-linux-musl" ;;
        *) die "Unsupported arch: $(uname -m). Open an issue at github.com/rex/spud" ;;
    esac
}

# ── Key generation helpers ────────────────────────────────────────────────
find_keygen() {
    if command -v ssh-keygen >/dev/null 2>&1; then
        echo "ssh-keygen"
    elif command -v dropbearkey >/dev/null 2>&1; then
        echo "dropbearkey"
    elif [ -x "$SPUD_DIR/dropbearkey" ]; then
        echo "$SPUD_DIR/dropbearkey"
    else
        echo ""
    fi
}

gen_key_ed25519() {
    local keygen="$1" path="$2"
    if [ "$keygen" = "ssh-keygen" ]; then
        ssh-keygen -t ed25519 -f "$path" -N "" -q
    else
        $keygen -t ed25519 -f "$path" 2>/dev/null
    fi
}

# ── Ensure SSH server ─────────────────────────────────────────────────────
ensure_sshd() {
    # Check if anything already listens on port 22
    local listening=false
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null | grep -qE ':22[[:space:]]' && listening=true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -qE ':22[[:space:]]' && listening=true
    fi

    if $listening; then
        log "SSH server already running on :22."
        return 0
    fi

    log "No SSH server found. Installing dropbear..."

    # Try package managers first
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -yq dropbear 2>/dev/null && _start_dropbear && return 0
    fi
    if command -v opkg >/dev/null 2>&1; then
        opkg update -q 2>/dev/null; opkg install dropbear 2>/dev/null && _start_dropbear && return 0
    fi
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache dropbear 2>/dev/null && _start_dropbear && return 0
    fi
    if command -v yum >/dev/null 2>&1; then
        yum install -y -q dropbear 2>/dev/null && _start_dropbear && return 0
    fi
    if command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm dropbear 2>/dev/null && _start_dropbear && return 0
    fi

    # Fall back to downloading static dropbear binary
    _download_dropbear && _start_dropbear
}

_download_dropbear() {
    local arch
    arch="$(detect_arch)"

    # Map bore arch string → our dropbearmulti binary name
    local db_arch
    case "$arch" in
        x86_64-unknown-linux-musl)      db_arch="x86_64"  ;;
        aarch64-unknown-linux-musl)     db_arch="aarch64" ;;
        armv7-unknown-linux-musleabihf) db_arch="armv7"   ;;
        arm-unknown-linux-musleabihf)   db_arch="armv6"   ;;
        mipsel-unknown-linux-musl)      db_arch="mipsel"  ;;
        mips-unknown-linux-musl)        db_arch="mips"    ;;
        i686-unknown-linux-musl)        db_arch="i686"    ;;
        riscv64gc-unknown-linux-musl)   db_arch="riscv64" ;;
        *)
            die "No static dropbear binary for arch: $arch. Install dropbear manually and re-run."
            ;;
    esac

    # Binaries are built by .github/workflows/dropbear-bins.yml and published
    # as a GitHub release in this same repo.
    local url="https://github.com/rexackermann/spud/releases/download/dropbear-bins/dropbearmulti-${db_arch}"
    log "Downloading static dropbear ($db_arch)..."
    fetch_to_file "$url" "$SPUD_DIR/dropbearmulti" \
        || die "Failed to download dropbear from $url
  Make sure the 'dropbear-bins' release exists in the repo.
  Run the 'Build dropbear static binaries' GitHub Actions workflow first."

    chmod +x "$SPUD_DIR/dropbearmulti"
    # dropbearmulti acts as server/client/keygen depending on argv[0]
    ln -sf dropbearmulti "$SPUD_DIR/dropbear"
    ln -sf dropbearmulti "$SPUD_DIR/dropbearkey"
    ln -sf dropbearmulti "$SPUD_DIR/dbclient"
    export PATH="$SPUD_DIR:$PATH"
}

_start_dropbear() {
    local dropbear_bin=""
    if command -v dropbear >/dev/null 2>&1; then
        dropbear_bin="dropbear"
    elif [ -x "$SPUD_DIR/dropbear" ]; then
        dropbear_bin="$SPUD_DIR/dropbear"
    else
        die "dropbear not found after install attempt"
    fi

    # Generate host key if missing
    if [ ! -f "$HOST_KEY" ]; then
        log "Generating SSH host key..."
        local kg
        kg="$(find_keygen)"
        [ -n "$kg" ] || die "No key generator found"
        gen_key_ed25519 "$kg" "$HOST_KEY"
    fi

    # Start dropbear: -s no password, -g no root password, -F foreground would block
    # so we start detached; init system will manage it afterward
    $dropbear_bin -r "$HOST_KEY" -p 22 -s -g \
        && log "Dropbear SSH server started." \
        || log "Warning: dropbear failed to start (port in use?)"
}

# ── Ensure bore ───────────────────────────────────────────────────────────
ensure_bore() {
    if command -v bore >/dev/null 2>&1; then
        BORE_BIN="$(command -v bore)"
        log "bore already in PATH: $BORE_BIN"
        return 0
    fi
    if [ -x "$SPUD_DIR/bore" ]; then
        log "bore already at $SPUD_DIR/bore"
        return 0
    fi

    local arch
    arch="$(detect_arch)"

    # Get latest bore version
    local ver
    ver="$(fetch_url https://api.github.com/repos/ekzhang/bore/releases/latest 2>/dev/null \
          | grep '"tag_name"' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)" \
        || ver="v0.5.0"

    log "Downloading bore $ver for $arch..."
    local tarball="bore-${ver}-${arch}.tar.gz"
    local url="https://github.com/ekzhang/bore/releases/download/${ver}/${tarball}"
    local tmp="$SPUD_DIR/bore.tar.gz"

    fetch_to_file "$url" "$tmp" \
        || die "Failed to download bore for $arch ($url)"

    # Extract — bore tar.gz contains a single 'bore' binary
    if command -v tar >/dev/null 2>&1; then
        tar -xzf "$tmp" -C "$SPUD_DIR" bore 2>/dev/null \
            || tar -xzf "$tmp" -C "$SPUD_DIR" 2>/dev/null
    else
        die "tar not found — cannot extract bore"
    fi

    rm -f "$tmp"
    chmod +x "$BORE_BIN"
    log "bore installed at $BORE_BIN"
}

# ── Admin pubkey ──────────────────────────────────────────────────────────
install_admin_pubkey() {
    local ak="/root/.ssh/authorized_keys"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch "$ak"
    chmod 600 "$ak"

    if ! grep -qF "$ADMIN_PUBKEY" "$ak" 2>/dev/null; then
        printf '%s\n' "$ADMIN_PUBKEY" >> "$ak"
        log "Admin pubkey installed in $ak"
    else
        log "Admin pubkey already present."
    fi
}

# ── Write tunnel loop script ──────────────────────────────────────────────
write_tunnel_loop() {
    local topic="${NTFY_TOPIC_PREFIX}-$(hostname)"

    cat > "$LOOP_SCRIPT" <<EOF
#!/bin/sh
# Spud tunnel loop — auto-reconnects, notifies via ntfy on each connection
BORE="$BORE_BIN"
NTFY_TOPIC="$topic"

notify() {
    local port="\$1"
    local msg="ssh -p \$port root@bore.pub  [\$(hostname) | \$(date '+%H:%M')]"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL \\
             -H "Title: Spud: \$(hostname) online" \\
             -H "Priority: low" \\
             -H "Tags: computer" \\
             -d "\$msg" \\
             "https://ntfy.sh/\$NTFY_TOPIC" >/dev/null 2>&1 || true
    elif command -v wget >/dev/null 2>&1; then
        wget -qO /dev/null \\
             --header="Title: Spud: \$(hostname) online" \\
             --header="Priority: low" \\
             --post-data="\$msg" \\
             "https://ntfy.sh/\$NTFY_TOPIC" 2>/dev/null || true
    fi
}

run_bore() {
    # bore outputs a line like:
    #   2024-01-01T00:00:00Z  INFO bore_cli::client: listening at bore.pub:PORT
    # We pipe through a line reader, capture the port, notify, then wait.
    "\$BORE" local 22 --to bore.pub 2>&1 | while IFS= read -r line; do
        printf '%s\n' "\$line" >> /var/log/spud.log 2>/dev/null || true
        case "\$line" in
            *"listening at bore.pub:"*)
                PORT="\$(printf '%s' "\$line" | grep -oE 'bore\\.pub:[0-9]+' | cut -d: -f2)"
                if [ -n "\$PORT" ]; then
                    printf '%s\n' "\$PORT" > /etc/spud/current_port
                    notify "\$PORT"
                fi
                ;;
        esac
    done
}

while true; do
    run_bore
    sleep 10
done
EOF

    chmod +x "$LOOP_SCRIPT"
    log "Tunnel loop written to $LOOP_SCRIPT"
}

# ── Persistence ───────────────────────────────────────────────────────────
install_persistence() {
    local svc_installed=false

    # ── systemd ───────────────────────────────────────────────────────────
    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        log "Detected systemd."

        cat > /etc/systemd/system/spud-tunnel.service <<EOF
[Unit]
Description=Spud reverse tunnel (bore.pub)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$LOOP_SCRIPT
Restart=always
RestartSec=10
StandardOutput=append:/var/log/spud.log
StandardError=append:/var/log/spud.log

[Install]
WantedBy=multi-user.target
EOF

        # If we started dropbear ourselves, manage it too
        if [ -x "$SPUD_DIR/dropbear" ]; then
            cat > /etc/systemd/system/spud-sshd.service <<EOF
[Unit]
Description=Spud dropbear SSH server
After=network.target
Before=spud-tunnel.service

[Service]
ExecStart=$SPUD_DIR/dropbear -r $HOST_KEY -p 22 -s -g -F -E
Restart=always

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable --now spud-sshd.service
        fi

        systemctl daemon-reload
        systemctl enable --now spud-tunnel.service
        svc_installed=true
        log "systemd service installed."

    # ── OpenRC ────────────────────────────────────────────────────────────
    elif command -v rc-update >/dev/null 2>&1; then
        log "Detected OpenRC."
        cat > /etc/init.d/spud-tunnel <<EOF
#!/sbin/openrc-run
description="Spud reverse tunnel"
command="$LOOP_SCRIPT"
command_background=true
pidfile="/run/spud-tunnel.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/spud-tunnel
        rc-update add spud-tunnel default 2>/dev/null || true
        rc-service spud-tunnel start
        svc_installed=true
        log "OpenRC service installed."

    # ── busybox inittab (embedded / OpenWRT) ─────────────────────────────
    elif [ -f /etc/inittab ] && command -v init >/dev/null 2>&1; then
        log "Detected inittab (busybox/sysvinit)."
        if ! grep -q spud-tunnel /etc/inittab 2>/dev/null; then
            printf '::respawn:%s\n' "$LOOP_SCRIPT" >> /etc/inittab
            kill -HUP 1 2>/dev/null || true
        fi
        svc_installed=true
        log "inittab respawn entry added."

    # ── rc.local fallback ─────────────────────────────────────────────────
    elif [ -f /etc/rc.local ]; then
        log "Falling back to rc.local."
        if ! grep -q spud-tunnel /etc/rc.local 2>/dev/null; then
            # Insert before exit 0, or append
            if grep -q '^exit 0' /etc/rc.local; then
                sed -i "s|^exit 0|${LOOP_SCRIPT} \&\nexit 0|" /etc/rc.local
            else
                printf '%s &\n' "$LOOP_SCRIPT" >> /etc/rc.local
            fi
            chmod +x /etc/rc.local
        fi
        svc_installed=true
        log "rc.local entry added."

    # ── cron @reboot last resort ──────────────────────────────────────────
    elif command -v crontab >/dev/null 2>&1; then
        log "Falling back to cron @reboot."
        ( crontab -l 2>/dev/null | grep -v spud-tunnel
          printf '@reboot %s\n' "$LOOP_SCRIPT"
        ) | crontab -
        svc_installed=true
        log "cron @reboot entry added."

    else
        log "WARNING: No init system detected. Start manually with: $LOOP_SCRIPT"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
    log "Spud installer — $(uname -s) $(uname -m)"
    log "ntfy topic: ${NTFY_TOPIC_PREFIX}-$(hostname)"

    [ "$(id -u)" -eq 0 ] || die "Must run as root. Try: sudo sh setup.sh"

    [ "$ADMIN_PUBKEY" = "ssh-ed25519 AAAA_REPLACE_WITH_YOUR_PUBLIC_KEY spud-admin" ] \
        && die "Set ADMIN_PUBKEY in setup.sh before running."
    [ "$NTFY_TOPIC_PREFIX" = "spud-REPLACE_WITH_RANDOM_STRING" ] \
        && die "Set NTFY_TOPIC_PREFIX in setup.sh before running."

    mkdir -p "$SPUD_DIR"
    chmod 700 "$SPUD_DIR"

    ensure_sshd
    ensure_bore
    install_admin_pubkey
    write_tunnel_loop
    install_persistence

    # Start immediately without waiting for reboot
    log "Starting tunnel now..."
    nohup "$LOOP_SCRIPT" >/dev/null 2>&1 &

    NTFY_TOPIC="${NTFY_TOPIC_PREFIX}-$(hostname)"
    log ""
    log "══════════════════════════════════════════════════════"
    log "  Spud installed."
    log ""
    log "  Watch for your connect command at:"
    log "    https://ntfy.sh/$NTFY_TOPIC"
    log "  or install the ntfy app and subscribe to:"
    log "    $NTFY_TOPIC"
    log ""
    log "  Current port (once tunnel is up):"
    log "    cat /etc/spud/current_port"
    log "══════════════════════════════════════════════════════"
}

main "$@"
