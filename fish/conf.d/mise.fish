# Interactive shells get the full activation (hooks on directory change).
# Non-interactive ones get shims, so `ssh kestrel -- node --version` works.
if type -q mise
    if status is-interactive
        mise activate fish | source
    else
        mise activate fish --shims | source
    end
end
