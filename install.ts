import * as toml from "jsr:@std/toml";
import * as z from "jsr:@zod/zod";
import { deepMerge } from "jsr:@cross/deepmerge";
import type { Mise, Vars1 } from "./mise-schema.d.ts";

/**
 * Hetzner storage boxes speak SSH on port 23, not 22.
 *
 * This is the only definition. It reaches ssh via the config template, and
 * everything else talks to the `storagebox` alias so it inherits the port from
 * there — a second copy is what silently broke backups once already.
 */
const BACKUP_PORT = "23";

function hostname(config: Config): Mise {
  return {
    vars: { hostname: config.vars.hostname },
    bootstrap: {
      files: {
        "/etc/hostname": {
          mode: "0644",
          owner: "root",
          group: "root",
          content: config.vars.hostname + "\n",
        },
      },
      hooks: {
        final: {
          run: ['sudo hostnamectl set-hostname "$(cat /etc/hostname)"'],
        },
      },
    },
  };
}

function fish(): Mise {
  return {
    bootstrap: {
      hooks: { final: { run: ['sudo usermod -s /usr/bin/fish "$USER"'] } },
    },
    dotfiles: {
      "~/.config/fish/conf.d": { source: "fish/conf.d", mode: "symlink-each" },
      "~/.config/fish/functions": {
        source: "fish/functions",
        mode: "symlink-each",
      },
    },
  };
}

function git(config: Config): Mise {
  const vars = {} as Vars1;
  if (config.vars.git_email) vars["git_email"] = config.vars.git_email;
  return {
    vars,
    dotfiles: {
      "~/.config/git/config": { source: "git/config.tmpl", mode: "template" },
      "~/.config/git/ignore": "git/ignore",
    },
  };
}

function ssh(): Mise {
  return { dotfiles: { "~/.ssh/config": "ssh/config" } };
}

function tools(): Mise {
  return {
    dotfiles: {
      "~/.config/mise/conf.d/tools.toml": "tools/mise-tools.toml",
    },
  };
}

/**
 * Backups to a Hetzner storage box.
 *
 * Pure: everything here is a description of the desired state. The key is
 * generated on the target by the post-dotfiles hook (a key is machine-specific
 * and must never travel), and the repository password is prompted for once by
 * the pre-packages hook and cached by tools/secret.
 */
function backup(config: Config): Mise {
  if (!config.features?.backup) return {};

  const { host, user } = config.features.backup;

  return {
    vars: { backup_host: host, backup_user: user, backup_port: BACKUP_PORT },
    dotfiles: {
      "~/.local/bin/restic-backup": "backups/restic-backup.sh",
      "~/.config/restic/exclude": "backups/exclude",
      "~/.ssh/config.d/10-storagebox.conf": {
        source: "ssh/storagebox.conf.tmpl",
        mode: "template",
      },
    },
    bootstrap: {
      // mise will not create a managed file's parent directory.
      directories: { "~/.config/restic": { mode: "0700" } },
      files: {
        // Not a dotfile entry: `mode = "template"` copies the *source* file's
        // permissions, and git records only the exec bit, so a checked-in
        // template would render this password world-readable. A managed file
        // takes an explicit mode.
        "~/.config/restic/env": {
          source: "backups/restic-env.tmpl",
          template: true,
          mode: "0600",
        },
      },
      hooks: {
        // The env file renders during the files phase, which runs well before
        // the dotfiles phase — pre-packages is the only hook early enough to
        // have the password cached in time.
        "pre-packages": { run: ["tools/secret ensure restic_password"] },
        // Needs ~/.ssh/config.d/10-storagebox.conf, which arrives with the
        // dotfiles, so that the enrolment goes through the `storagebox` alias.
        "post-dotfiles": { run: ["backups/enrol-backup.sh --ensure"] },
      },
      linux: {
        systemd: {
          units: {
            "restic-backup": {
              description:
                `restic backup of ${config.vars.hostname} to offsite repository`,
              type: "oneshot",
              exec_start: "%h/.local/bin/restic-backup",
              after: ["network-online.target"],
              wants: ["network-online.target"],
              wanted_by: [],
              start: false,
            },
            "restic-backup-timer": {
              description: `regular restic backup timer`,
              unit: "restic-backup",
              on_boot_sec: "5min",
              on_unit_active_sec: "2h",
              persistent: true, // for laptops/devices that may not always be running
            },
          },
        },
      },
    },
  };
}

async function main() {
  const config = await loadConfig("./setup.toml");
  const file = toml.stringify(
    deepMerge(
      hostname(config),
      fish(),
      git(config),
      ssh(),
      tools(),
      backup(config),
    ),
  );

  await Deno.writeTextFile("./mise.bootstrap.toml", file);
}

type Config = z.infer<typeof MachineToml>;

const MachineToml = z.object({
  vars: z.object({ hostname: z.string(), git_email: z.string().optional() }),
  features: z.object({
    backup: z.object({ host: z.string(), user: z.string() }).optional(),
  }).optional(),
}).strict();

async function loadConfig(source: string): Promise<Config> {
  const text = await Deno.readTextFile(source);
  const object = toml.parse(text);
  return MachineToml.parse(object);
}

await main();
