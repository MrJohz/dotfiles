import * as toml from "jsr:@std/toml";
import $ from "jsr:@david/dax";
import * as z from "jsr:@zod/zod";
import { deepMerge } from "jsr:@cross/deepmerge";
import { undent } from "jsr:@okikio/undent";
import type { Mise, Vars1 } from "./mise-schema.d.ts";

/**
 * file-style undents
 *
 * Ensures that if the text block ends with \n, then exactly
 * one trailing newline will appear in the trimmed string (default
 * is to trim all newlines)
 */
const file = undent.with({ trim: { leading: "all", trailing: "one" } });

/**
 * file path in the ephemeral folder
 *
 * Defines a path that will show up in the ephemeral (not-checked-in)
 * folder in this project, for files that are generated during install
 * and need to be copied to the server later
 */
const ephemeral = (str: string | TemplateStringsArray, ...subs: unknown[]) =>
  `ephemeral/${
    typeof str === "string" ? str : String.raw({ raw: str }, ...subs)
  }`;

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

async function backup(config: Config): Promise<Mise> {
  if (!config.features?.backup) return {};

  const username = await $.prompt("Backup box user");
  const password = await $.prompt("Restic password", { mask: true });

  const remote = `${username}@${config.features.backup.host}`;

  const backupKeyFolder = ephemeral`storagebox`;
  const backupKeyFile = backupKeyFolder + "/id_ed25519_storagebox";
  await $`mkdir -p ${backupKeyFolder}`;
  await $`ssh-keygen -t ed25519 -C ${remote} -f ${backupKeyFile} -N ""`;

  return {
    vars: { backup_host: config.features.backup.host, backup_user: username },
    dotfiles: {
      "~/.config/restic/exclude": "backups/exclude",
      "~/.local/bin/restic-backup": "backups/restic-backup.sh",
      "~/.config/restic/keys": backupKeyFolder,
      "~/.ssh/config.d/10-storagebox.conf": {
        source: "ssh/storagebox.conf.tmpl",
        mode: "template",
      },
    },
    bootstrap: {
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
      hooks: {
        // Get storage box set up with a copy of the backup key
        // This will prompt for a password -- I couldn't find a better way of
        // doing this than just letting the prompt happen
        final: { run: [`ssh-copy-id -p 23 ${remote} -i ${backupKeyFile}`] },
      },
      files: {
        "~/.config/restic/env": {
          // only owner can access this file
          mode: "0600",
          content: file`
            RESTIC_REPOSITORY=sftp:storagebox:restic
            RESTIC_PASSWORD=${password}\n
        `,
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
      await backup(config),
    ),
  );

  await Deno.writeTextFile("./mise.bootstrap.toml", file);
}

type Config = z.infer<typeof MachineToml>;

const MachineToml = z.object({
  vars: z.object({ hostname: z.string(), git_email: z.string().optional() }),
  features: z.object({
    backup: z.object({ host: z.string() }).optional(),
  }).optional(),
}).strict();

async function loadConfig(source: string): Promise<Config> {
  const text = await Deno.readTextFile(source);
  const object = toml.parse(text);
  return MachineToml.parse(object);
}

await main();
