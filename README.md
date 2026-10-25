Personal global mise configuration, predominantly for shell-agnostic, portable, accessible tasks

[setup.sh](https://raw.githubusercontent.com/r3b1s/mise-dots/refs/heads/main/setup.sh)

```sh
curl 'https://raw.githubusercontent.com/r3b1s/mise-dots/refs/heads/main/setup.sh' | bash
```

## Layout

```
config.toml        settings, env, tools, and the task_config include
lib/common.sh      shared shell helpers (sourced by task scripts)
tasks/             one executable script per task; the path is the task name
```

`config.toml` points mise at `tasks/`:

```toml
[task_config]
includes = ["~/Dotfiles/mise-dots/tasks"]
```

Task metadata lives in `#MISE` headers in each script. `tasks/dots/omarchy/setup.sh`
is `mise run dots:omarchy:setup`; subdirectories become `:`-separated namespaces.

## Tasks

```sh
mise tasks ls                       # list tasks
mise run dots:omarchy:setup         # clone + install Omarchy dotfiles over HTTPS
mise run dots:omarchy:setup --ssh   # ...and rewrite cloned remotes to SSH
mise run dots:arch:setup --ssh      # same for Arch/CachyOS
mise run dots:clone:harness         # clone just harness-dots
mise run ctf:engagement <name>      # copy the engagement template into the cwd
mise run scaffold-dirs              # create the common directory tree
mise run 'dots:*'                   # every dots task
```
