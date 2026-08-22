#!/usr/bin/env bash
# Enrol this machine with the offsite backup box, and verify it stays enrolled.
#
# Runs from the post-dotfiles bootstrap hook, so ~/.ssh/config.d/10-storagebox.conf
# already exists and the `storagebox` alias resolves. Everything here goes
# through that alias rather than a literal host and port. That is the whole
# point: ssh-copy-id used to probe `user@host -p 23` directly and report success
# while restic — which uses the alias — was falling back to a password prompt on
# port 22. Checking anything other than the real code path is how that hid.
#
#   --ensure       generate a key if absent, enrol it if it does not work, verify
#   --check        read-only; the drift signal used by fish_greeting
#   --rotate-key   replace the key, verifying the new one before dropping the old
set -euo pipefail

ALIAS=storagebox
conf="${XDG_CONFIG_HOME:-$HOME/.config}/restic"
keydir="$conf/keys"
key="$keydir/id_ed25519_storagebox"

die() { printf '%s: %s\n' "${0##*/}" "$1" >&2; exit 1; }

# The storage box runs a restricted shell, so `ssh ... true` exits 8 even when
# auth succeeded. sftp is both a reliable probe and what restic actually does.
probe() {
    local id=("$@")
    # Bounded: --check runs unattended from fish's greeting, so nothing here
    # may block indefinitely.
    timeout 30 sftp -q -o BatchMode=yes -o ConnectTimeout=10 \
        "${id[@]}" -b /dev/null "$ALIAS" >/dev/null 2>&1
}

# Read the identity back out of the ssh config so it has one definition.
remote_id() {
    ssh -G "$ALIAS" 2>/dev/null |
        awk '/^user /{u=$2} /^hostname /{h=$2} END{print u"@"h}'
}

ensure_key() {
    [ -f "$key" ] && return 0
    mkdir -p "$keydir"
    chmod 700 "$keydir"
    # A key is machine-specific and must never travel, so it is generated here
    # on the target rather than shipped with the config.
    ssh-keygen -t ed25519 -C "$(remote_id)" -f "$key" -N "" >/dev/null
    printf 'generated a new backup key: %s\n' "$key"
}

cmd_ensure() {
    ensure_key
    if probe; then
        return 0
    fi

    # ssh-copy-id will ask for the storage box password. With no terminal to
    # ask on it would block forever, so refuse instead — an unattended apply
    # (cron, CI, a hung timer) must fail loudly rather than hang.
    { true >/dev/tty; } 2>/dev/null ||
        die "$ALIAS will not authenticate and there is no terminal to enrol from; run '${0##*/} --ensure' by hand"

    printf 'enrolling %s with %s (this will ask for the storage box password)\n' \
        "$key" "$ALIAS"
    # ssh-copy-id is already idempotent: it probes with publickey-only auth
    # first and skips keys that are installed, without prompting. -s is
    # required because the box allows sftp only.
    ssh-copy-id -s -i "$key" "$ALIAS"

    probe || die "enrolled the key but $ALIAS still will not authenticate"
    printf 'enrolled and verified\n'
}

# --- checks ---------------------------------------------------------------

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }
mode_is() { [ "$(stat -c %a "$1" 2>/dev/null)" = "$2" ]; }

cmd_check() {
    if [ -f "$key" ]; then
        mode_is "$key" 600 && ok "key present, 0600" || bad "key mode is not 0600: $key"
    else
        bad "no backup key at $key"
    fi

    mode_is "$keydir" 700 && ok "key dir 0700" || bad "key dir is not 0700: $keydir"

    if [ -f "$conf/env" ]; then
        mode_is "$conf/env" 600 && ok "env present, 0600" || bad "env is not 0600: $conf/env"
    else
        bad "no restic env at $conf/env"
    fi

    local auth_ok=0
    if probe; then
        ok "auth via the $ALIAS alias"
        auth_ok=1
    else
        bad "cannot authenticate to $ALIAS without a password"
    fi

    # Only meaningful once auth works, and bounded for the same reason as
    # probe: restic retries with backoff, which turns a wrong port into a
    # multi-minute hang rather than a failed check.
    if [ "$auth_ok" = 1 ] && [ -r "$conf/env" ] && command -v restic >/dev/null; then
        if (set -a; . "$conf/env"; set +a; timeout 30 restic cat config >/dev/null 2>&1); then
            ok "repository reachable"
        else
            bad "repository unreachable or wrong password"
        fi
    fi

    [ "$fails" -eq 0 ] || die "$fails check(s) failed"
}

# --- rotation -------------------------------------------------------------

cmd_rotate_key() {
    [ -f "$key" ] || die "no key to rotate; run --ensure first"
    local new="$key.new" old_pub
    old_pub=$(awk '{print $2}' "$key.pub")

    rm -f "$new" "$new.pub"
    ssh-keygen -t ed25519 -C "$(remote_id)" -f "$new" -N "" >/dev/null

    ssh-copy-id -s -i "$new" "$ALIAS"

    # Verify the new key on its own before removing the old one. The reverse
    # order can leave you locked out of a box you have no shell on.
    probe -o IdentitiesOnly=yes -i "$new" ||
        die "the new key does not authenticate; leaving the old one in place"

    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    sftp -q -o BatchMode=yes -o IdentitiesOnly=yes -i "$new" -b - "$ALIAS" <<-EOF
		get .ssh/authorized_keys $tmp/authorized_keys
	EOF
    grep -vF "$old_pub" "$tmp/authorized_keys" >"$tmp/filtered" || true
    sftp -q -o BatchMode=yes -o IdentitiesOnly=yes -i "$new" -b - "$ALIAS" <<-EOF
		put $tmp/filtered .ssh/authorized_keys
	EOF

    mv -f "$new" "$key"
    mv -f "$new.pub" "$key.pub"
    probe || die "rotation left $ALIAS unauthenticated — investigate before the next backup"
    printf 'rotated the backup key and removed the old one from %s\n' "$ALIAS"
}

case "${1---ensure}" in
    --ensure)     cmd_ensure ;;
    --check)      cmd_check ;;
    --rotate-key) cmd_rotate_key ;;
    *)            die "usage: ${0##*/} [--ensure|--check|--rotate-key]" ;;
esac
