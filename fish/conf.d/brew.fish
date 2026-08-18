# ublue sets Homebrew's PATH in /etc/profile, which fish does not read.
if test -x /home/linuxbrew/.linuxbrew/bin/brew
    /home/linuxbrew/.linuxbrew/bin/brew shellenv fish | source
end
