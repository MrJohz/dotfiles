#!/usr/bin/env bash
# Converge this machine into a Sunshine remote desktop host, and verify it stays
# that way.
#
# Runs from the final bootstrap hook, after the packages, managed files and user
# unit are all in place. Everything here is work that has no declarative form in
# mise: kernel arguments, unit masking, setcap, firewalld, and Sunshine's own
# credential command.
#
#   --ensure   converge; safe to re-run
#   --check    read-only; the drift signal used by fish_greeting
#
# Zero-cost elsewhere: ~/.config/sunshine/host.env only exists on a machine with
# the feature enabled, so --check exits 0 on every other box.
#
# A note that cost seven hours of downtime to learn: never configure GNOME from
# a bootstrap hook with `gsettings set`. Over SSH it reports success and
# `gsettings get` immediately echoes the new value back, but the write never
# reaches disk — it lives in dconf-service memory and dies at reboot. That is
# how this machine was left set to suspend after it had supposedly been fixed.
# GNOME settings here go through the root-owned dconf system database instead.
# To verify one, use `dconf read` (empty means no override exists) or
# `GSETTINGS_BACKEND=memory gsettings get` (the true schema default). Never
# `gsettings get`.
set -euo pipefail

conf="${XDG_CONFIG_HOME:-$HOME/.config}/sunshine"
env_file="$conf/host.env"
unit="dev.mise.sunshine.service"

# TCP 47984-47990 is the control/web-UI range (47990 is the web UI) and 48010 is
# RTSP; UDP 47998-48010 carries video, audio and control.
rich_rules=(
    'rule port port="47984-47990" protocol="tcp" drop'
    'rule port port="48010" protocol="tcp" drop'
    'rule port port="47998-48010" protocol="udp" drop'
)

die() { printf '%s: %s\n' "${0##*/}" "$1" >&2; exit 1; }
say() { printf '%s\n' "$1"; }

# --- shared ---------------------------------------------------------------

load_env() {
    [ -r "$env_file" ] || return 1
    # shellcheck disable=SC1090
    . "$env_file"
    [ -n "${RDS_CONNECTOR:-}" ] && [ -n "${RDS_MODE:-}" ] && [ -n "${RDS_USER:-}" ]
}

# The one karg the whole display problem reduces to. The trailing `e`
# force-enables the connector, and the mode spec supplies the mode directly —
# no EDID file, no dummy plug, no custom image, no initramfs work. Without a
# real DRM display present before GNOME starts there is nothing for KMS capture
# to find, and a headless GNOME session offers none.
want_karg() { printf 'video=%s:%se' "$RDS_CONNECTOR" "$RDS_MODE"; }

sunshine_bin() { command -v sunshine 2>/dev/null || echo /home/linuxbrew/.linuxbrew/bin/sunshine; }

# Prefer the system libcap binary over whatever brew may have put on PATH.
getcap_bin() { [ -x /usr/sbin/getcap ] && echo /usr/sbin/getcap || command -v getcap; }

# Wireless interfaces only. A machine on Ethernet has none, and every power
# save step below then does nothing — which is the desired answer, since
# Ethernet is the better fix rather than something to warn about.
wifi_devices() {
    local dev
    for dev in /sys/class/net/*; do
        [ -d "$dev/wireless" ] && basename "$dev"
    done
}

powersave_state() { iw dev "$1" get power_save 2>/dev/null | awk '{ print $NF }'; }

# --- ensure ---------------------------------------------------------------

reboot_required=0

ensure_karg() {
    local want; want=$(want_karg)
    if rpm-ostree kargs | tr ' ' '\n' | grep -qxF "$want"; then
        return 0
    fi

    # Deliberately not `--append-if-missing`: it keys on `video`, so a stale
    # video= for a different connector or mode would silently survive and the
    # machine would come back up with the wrong display.
    local stale
    stale=$(rpm-ostree kargs | tr ' ' '\n' | grep -x "video=${RDS_CONNECTOR}:.*" || true)
    if [ -n "$stale" ]; then
        say "replacing stale kernel argument: $stale"
        sudo rpm-ostree kargs --delete-if-present="$stale"
    fi

    say "adding kernel argument: $want"
    sudo rpm-ostree kargs --append="$want"
    reboot_required=1
}

ensure_capabilities() {
    local prefix
    prefix=$(brew --prefix sunshine 2>/dev/null) ||
        die "sunshine is not installed via brew — has the packages phase run?"

    # Every apply, not just the first: an upgrade moves the Cellar path and the
    # capability does not follow it. postinst is modprobe uhid, the
    # cap_sys_admin,cap_sys_nice+p setcap, and a udev reload — all idempotent.
    # cap_sys_admin is why Sunshine has to come from brew at all; it cannot be
    # granted inside a Flatpak sandbox, which rules the Flatpak out of KMS
    # capture entirely.
    sudo "$prefix/bin/postinst"
}

ensure_no_sleep() {
    sudo dconf update

    # The dconf layer alone is not enough — a running session can still override
    # it in dconf-service memory, and the lock files proved advisory. Masking
    # cannot be undone from a user session. For an always-on headless streaming
    # host this is the correct posture: the machine suspended itself 15 minutes
    # after the spike ended and stayed down for 7 hours, and with no Ethernet
    # there was no Wake-on-LAN to recover it.
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
}

ensure_no_gnome_remote_desktop() {
    # GNOME Remote Login is not merely redundant, it is the thing Sunshine
    # cannot see: its headless session is a PipeWire/compositor construct with
    # no DRM CRTC, invisible to both KMS and portal capture. Mutter reports
    # empty monitor arrays inside it.
    sudo systemctl disable --now gnome-remote-desktop.service 2>/dev/null || true
    sudo systemctl mask gnome-remote-desktop.service
}

# The managed drop-in in /etc/NetworkManager/conf.d is what makes this survive a
# reboot, but it only binds at the next association — so a converge that does not
# reboot would leave power save on until the link happened to bounce. Both halves
# are needed: reload so NetworkManager reads the drop-in, and set the live state
# directly for the session already up.
#
# Measured on this hardware: power save on gave 90.5 ms average LAN round-trip
# with repeated stream stalls, off gave 13.1 ms with none. It regressed silently
# across one reboot and was found only by someone noticing mid-stream lag, which
# is why check_wifi_powersave exists.
ensure_wifi_powersave() {
    local dev devs
    devs=$(wifi_devices)
    [ -n "$devs" ] || return 0

    # Deliberately not `nmcli connection reload`, which re-reads connection
    # profiles; the drop-in is main configuration and needs this instead.
    sudo nmcli general reload conf
    for dev in $devs; do
        sudo iw dev "$dev" set power_save off
    done
}

# Sunshine listens on 0.0.0.0 and has no bind-address setting, so reaching only
# the tailnet is a firewall property.
#
# firewalld picks exactly one zone per packet, by ingress interface, and rich
# rules cannot match interfaces — so "allow on tailscale0, drop on the LAN" is
# not expressible within a single zone. Hence the split: tailscale0 gets its own
# zone, and the drops go in the default zone, which is also where every unbound
# interface (the unplugged Ethernet, anything added later) lands by default.
#
# Ordering matters. tailscale0 must leave the default zone *before* the drops
# arrive in it, or they would apply to the tailnet too.
ensure_firewall() {
    local zone
    # --permanent queries are themselves privileged (polkit refuses them for a
    # normal user), so every call here goes through sudo, not just the writes.
    sudo firewall-cmd --permanent --zone=trusted --query-interface=tailscale0 >/dev/null 2>&1 ||
        sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0

    zone=$(firewall-cmd --get-default-zone)
    for rule in "${rich_rules[@]}"; do
        sudo firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1 ||
            sudo firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule"
    done

    # Permanent config is inert until this; it is also what makes the runtime
    # state --check reads agree with what was just written.
    sudo firewall-cmd --reload >/dev/null
}

ensure_credentials() {
    local repo password
    repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
    password=$("$repo/tools/secret" get sunshine_password)
    "$(sunshine_bin)" --creds admin "$password" >/dev/null
}

cmd_ensure() {
    load_env || die "no $env_file — this machine is not configured as a remote desktop server"

    # The bootstrap acquires sudo once in its first hook; refresh here so a long
    # package phase cannot let the 15-minute timestamp expire and turn this into
    # a surprise password prompt halfway through.
    sudo -v

    ensure_karg
    ensure_capabilities
    ensure_no_sleep
    ensure_no_gnome_remote_desktop
    ensure_wifi_powersave
    ensure_firewall
    ensure_credentials

    systemctl --user restart "$unit"

    if [ "$reboot_required" = 1 ]; then
        say ''
        say "REBOOT REQUIRED: the display kernel argument is staged but not live."
        say "Until then there is no DRM display and capture cannot work."
        return 0
    fi

    # Only meaningful once the karg is actually live; a restart re-probes
    # capture, so this is the moment the KMS path is confirmed rather than
    # assumed. Bounded, because the probe takes a moment and the failure mode
    # being guarded against is Sunshine hanging on the portal fallback — an
    # unbounded wait would reproduce the bug instead of reporting it.
    local waited=0
    until verify_capture; do
        waited=$((waited + 1))
        if [ "$waited" -gt 15 ]; then
            die "sunshine restarted but did not select KMS capture — journalctl --user -u $unit"
        fi
        sleep 1
    done
    say 'remote desktop host converged'
}

# --- checks ---------------------------------------------------------------

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

masked_is() { [ "$(systemctl is-enabled "$1" 2>/dev/null)" = "masked" ]; }

# `active` is not evidence of anything: Sunshine stays active while hung on the
# portal fallback, with its ports never opened. The capture path has to be read
# out of the journal for the current run of the service.
verify_capture() {
    local since
    since=$(systemctl --user show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null)
    [ -n "$since" ] || return 1
    grep -q 'Screencasting with KMS' < <(journalctl --user -u "$unit" --since "$since" 2>/dev/null)
}

check_display() {
    # The connector state is the thing that actually degrades: after an idle
    # blank this reads enabled=disabled, dpms=Off and the KMS monitor list goes
    # empty, while the service still looks healthy.
    local dir
    for dir in /sys/class/drm/card*-"$RDS_CONNECTOR"; do
        [ -d "$dir" ] || continue
        [ "$(cat "$dir/status" 2>/dev/null)" = "connected" ] ||
            { bad "connector $RDS_CONNECTOR is not connected"; return; }
        [ "$(cat "$dir/enabled" 2>/dev/null)" = "enabled" ] ||
            { bad "connector $RDS_CONNECTOR is not enabled"; return; }
        [ "$(cat "$dir/dpms" 2>/dev/null)" = "On" ] ||
            { bad "connector $RDS_CONNECTOR has dpms off"; return; }
        ok "display $RDS_CONNECTOR connected, enabled, dpms on"
        return
    done
    bad "no drm connector matching $RDS_CONNECTOR"
}

# Reading power save needs no privilege, so this runs from fish_greeting like
# the rest. Silent on a machine with no wireless interface.
check_wifi_powersave() {
    local dev state
    for dev in $(wifi_devices); do
        state=$(powersave_state "$dev")
        [ "$state" = "off" ] &&
            ok "wifi $dev power save off" ||
            bad "wifi $dev power save is ${state:-unknown} — expect multi-frame stream stalls"
    done
}

# Runtime, not --permanent: --permanent queries need root and this runs
# unprivileged from fish_greeting, but more importantly the runtime ruleset is
# the one actually enforcing. A permanent rule that was never reloaded is not
# protecting anything.
check_firewall() {
    local zone missing=0
    firewall-cmd --zone=trusted --query-interface=tailscale0 >/dev/null 2>&1 &&
        ok "tailscale0 is in the trusted zone" ||
        bad "tailscale0 is not in the trusted zone — sunshine ports would be dropped for the tailnet too"

    zone=$(firewall-cmd --get-default-zone)
    for rule in "${rich_rules[@]}"; do
        firewall-cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1 ||
            missing=$((missing + 1))
    done
    [ "$missing" -eq 0 ] &&
        ok "sunshine ports dropped in the $zone zone" ||
        bad "$missing sunshine drop rule(s) missing from the $zone zone — the ports are open to the LAN"
}

cmd_check() {
    # Not configured here: succeed silently. This is the whole zero-cost
    # contract, and fish_greeting calls this on every machine.
    load_env || return 0

    grep -qw -- "$(want_karg)" /proc/cmdline &&
        ok "kernel argument live" ||
        bad "kernel argument $(want_karg) not in /proc/cmdline — reboot pending?"

    check_display

    local t unmasked=0
    for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
        masked_is "$t" || { unmasked=$((unmasked + 1)); }
    done
    [ "$unmasked" -eq 0 ] &&
        ok "sleep targets masked" ||
        bad "$unmasked sleep target(s) not masked — the machine can suspend itself off the network"

    masked_is gnome-remote-desktop.service &&
        ok "gnome-remote-desktop masked" ||
        bad "gnome-remote-desktop is not masked"

    "$(getcap_bin)" "$(readlink -f "$(sunshine_bin)")" 2>/dev/null | grep -q cap_sys_admin &&
        ok "sunshine has cap_sys_admin" ||
        bad "sunshine is missing cap_sys_admin — kms capture will fail"

    check_wifi_powersave
    check_firewall

    if systemctl --user is-active --quiet "$unit"; then
        verify_capture &&
            ok "sunshine active, capturing via kms" ||
            bad "sunshine is active but has not reported kms capture — it may be hung on the portal fallback"
    else
        bad "$unit is not active"
    fi

    [ "$fails" -eq 0 ] || die "$fails check(s) failed"
}

case "${1---ensure}" in
    --ensure) cmd_ensure ;;
    --check)  cmd_check ;;
    *)        die "usage: ${0##*/} [--ensure|--check]" ;;
esac
