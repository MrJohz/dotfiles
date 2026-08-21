# Jonathan Frere's Dotfiles

This is a mise-managed dotfile/immutable distro setup. The basic principles are:

- Everything sits on top of [Bluefin](https://projectbluefin.io/)
- [Mise Bootstrap](https://mise.jdx.dev/bootstrap.html) handles most of the
  system configuration
- Flatpacks, Homebrew for standalone applications (e.g. browsing, games, etc)
- Individual projects provide their own mise.toml (or mise.local.toml) to handle
  project-specific dependencies

The main goal is to create a declarative (but not necessarily reproducible)
environment so that I can relatively easily reproduce settings across different
machines, especially when adding new computers after a long time. As a result,
Mise bootstrap is kind of the cornerstone here — as much stuff goes through that
as possible, so that it's all written down somewhere and can be properly
documented.

This repository contains the bootstrap configuration that I use across ~all my
devices, plus the runbooks/installation instructions so I know how to set up a
new device when the time comes.

## Structure

There are three things going on here:

* setup.toml in the root directory (gitignored) defines some basic
  variables and the set of features that will be installed on a particular
  machine (not all machines will get/need all features, e.g. backups may not be
  applicable on a work machine, and my laptop doesn't need the remote desktop
  server setup).
* install.ts, called using `mise run setup`, converts that config file into a
  `mise.bootstrap.toml` file.  This phase is mainly concerned with ensuring that
  the resulting `mise.bootstrap.toml` file contains only the sections necessary
  to set up the features that are needed for this machine.  It generally is a
  pure function and avoids generating data, prefering to fetch it from the
  setup.toml file.
* `mise.bootstrap.toml`, once generated, contains all the instructions needed to
  setup a new machine.  It is idempotent, and running it multiple times should
  always be possible.  It should also, wherever possible, be able to track when
  files are out of sync with the ground truths in this folder.  To this end, we
  use a custom secrets CLI that asks for secrets that are needed at the start of
  the bootstrap run, and then saves them so that we don't need to type the same
  secrets in every time (and so that the bootstrap process can be validated in
  headless/non-TTY environments in the background).

All other files in this repo are the templates and source files that will be
used by the bootstrap script.  These should only change when something has
actually changed in the configuration, e.g. we're adding a new tool to the ones
that are installed by default, or we're changing how often backups run.  Then we
can run something like `git pull && mise run setup && mise run apply` and the
machine will be updated to its latest configuration.

## Runbook: remote desktop server

Enabled per-machine with `[features.remote-desktop-server]` in `setup.toml`. It
streams a real GNOME desktop over Sunshine from boot, with no login, reachable
only over Tailscale.

**A reboot is required.** The feature turns on a DRM connector with a kernel
argument (`video=<connector>:<mode>e`), and until the machine reboots there is
no display for Sunshine to capture. `mise run apply` says so when it stages one.

**Pairing a new client** is a manual step and cannot be automated: the client has
to initiate before the host posts the PIN, inside about twenty seconds.

```bash
# on the client
moonlight pair <tailscale-ip> --pin 4321

# on the host, within ~20s — the Content-Type header is required,
# without it the API returns {"error":"Content type mismatch"}
curl -sk -u admin:"$(tools/secret get sunshine_password)" \
     -H 'Content-Type: application/json' \
     -X POST https://localhost:47990/api/pin -d '{"pin":"4321","name":"my-laptop"}'
```

Paired clients live in `~/.config/sunshine/sunshine_state.json`, and the web-UI
password in `~/.config/sunshine/credentials/`. Both are machine state, not
config — keeping them should avoid re-pairing after a rebuild, though that has
not been tested.

**Checking it.** `remote-desktop/setup-sunshine.sh --check`, which the shell
greeting also runs. It deliberately does not trust `systemctl is-active`: a
Sunshine that has fallen back to the XDG portal stays `active` forever without
opening its ports, so the check reads the capture path out of the journal and
the connector state out of sysfs.

**Access is enforced by firewalld, not by Sunshine** (which listens on 0.0.0.0
and cannot bind to one interface). `tailscale0` is placed in the `trusted` zone
and the Sunshine ports are dropped in the default zone, which is also where any
unbound interface lands. To restrict further — say, one specific laptop rather
than the whole tailnet — use Tailscale ACLs: those are enforced by `tailscaled`
on this machine, but they live in the admin console, not in this repo.

**Reverting**, if the machine should stop being a host:

```bash
sudo rpm-ostree kargs --delete-if-present='video=<connector>:<mode>e'
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
sudo systemctl unmask gnome-remote-desktop.service
sudo firewall-cmd --permanent --zone=trusted --remove-interface=tailscale0
sudo firewall-cmd --permanent --zone=FedoraWorkstation \
    --remove-rich-rule='rule port port="47984-47990" protocol="tcp" drop'   # and the other two
sudo firewall-cmd --reload
```

## TODOs

* Runbooks
* Set up laptop remote desktop client user
* Setup local backup replication job
