function fish_greeting --description 'report dotfiles drift'
    # Print what the last check found. Reading a variable cannot hang a login.
    if set -q dotfiles_drift[1]
        set_color yellow
        printf '%s\n' $dotfiles_drift
        set_color normal
    end

    # Refresh for the next shell, detached, at most once an hour.
    set -q dotfiles_drift_at; or set -U dotfiles_drift_at 0
    if test (math (date +%s) - $dotfiles_drift_at) -gt 3600
        fish --command __fish_greeting_dotfiles-check &
        disown
    end
end

function __fish_greeting_dotfiles-check
    set -l repo ~/dotfiles
    set -l notes

    # Best effort — may be offline. The rev-count below works off the last
    # fetched remote ref either way, so a failed fetch goes stale, not silent.
    git -C $repo fetch --quiet 2>/dev/null

    # 'HEAD..@{u}' must be quoted: fish would brace-expand {u}.
    set -l behind (git -C $repo rev-list --count 'HEAD..@{u}' 2>/dev/null; or echo 0)
    test $behind -gt 0
    and set -a notes "dotfiles: $behind unapplied commit(s) — run: up"

    # Local drift: the repo is current but the machine no longer matches it.
    mise bootstrap status --missing >/dev/null 2>&1
    or set -a notes 'dotfiles: machine has drifted — run: mise bootstrap --dry-run'

    # A failed backup is the other way things go missing, and nothing else
    # reports it. Local and instant — systemd remembers the last result.
    if systemctl --user is-failed --quiet dev.mise.restic-backup.service
        set -a notes 'backup: last restic run FAILED — journalctl --user -u dev.mise.restic-backup'
    end

    # Overwrite, never append. Appending to a universal variable is the classic
    # fish footgun — it grows by one entry per shell, forever.
    set -U dotfiles_drift $notes
    set -U dotfiles_drift_at (date +%s)
end
