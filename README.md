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
