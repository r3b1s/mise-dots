# Notes for agents working on mise-dots

## Task Arguments and CLI Specifications (`#USAGE`)

Mise uses [usage-cli](https://usage.jdx.dev) specification comments to parse, validate, and document task CLI arguments.

When creating or modifying task scripts that accept arguments, flags, or forward `"$@"` to an underlying command:
1. **Always declare `#USAGE` comments**: Never rely on `"$@"` alone without declaring the usage spec. Without `#USAGE` comments, mise reports:
   ```text
   This task does not accept any arguments.
   To define arguments, add #USAGE comments to the script file.
   ```
2. **Flags**: Declare flags with short/long forms, help text, and optional defaults:
   ```bash
   #USAGE flag "--ssh" help="Rewrite cloned remotes to SSH"
   #USAGE flag "-n --dry-run" help="Preview changes without modifying config"
   #USAGE flag "-f --force" help="Force reinstall"
   ```
3. **Arguments & Passthrough**:
   - Single arguments: `#USAGE arg "<name>" help="..."` or optional `#USAGE arg "[name]" help="..."`
   - Passthrough / variadic arguments: `#USAGE arg "[args]..." help="Additional arguments forwarded to underlying command"`
   - Combining flags and passthrough: Define common flags explicitly for clean `--help` output, plus an `arg "[args]..."` catch-all when forwarding arbitrary extra options.

## Task Conventions

- **Directory Mapping**: Standalone executable scripts (`chmod +x`) reside under `tasks/`. Nested folders map to colon-separated namespaces (`tasks/dots/clone/all.sh` -> `mise run dots:clone:all`).
- **Standard Header**:
  ```bash
  #!/usr/bin/env bash
  #MISE description="<Brief description>"
  #MISE alias="<optional-alias>"
  #USAGE ...
  set -euo pipefail
  ```
- **Shared Helpers**: Sourced from `lib/common.sh` using `MISE_TASK_DIR` with the appropriate relative path depth:
  ```bash
  source "${MISE_TASK_DIR}/../../lib/common.sh"
  ```
  Available helpers: `require_os`, `clone_repo`, `link_theme`, `use_ssh_when_requested`.

## Configuration & Syncing

- **Copy, Not Symlink**: `config.toml` is copied to `~/.config/mise/config.toml` using `sync.sh` (or `setup.sh`), **never symlinked**. This prevents accidental mutations to the git repository when tools modify the global mise config.

## Commit Style

- Strictly adhere to **Conventional Commits**:
  - `feat(<scope>): ...`
  - `fix(<scope>): ...`
  - `refactor(<scope>): ...`
  - `chore(<scope>): ...`
- Keep commits atomic and logically separated.
