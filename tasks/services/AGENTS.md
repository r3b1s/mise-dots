# Notes for agents working on tasks/services

## Dedicated Service Directories & Setup Pattern

Each service managed under `tasks/services/` resides in its own dedicated directory named after the service (e.g., `tasks/services/<service>/`).

### 1. Setup Task Convention (`setup.sh`)
- The main entrypoint or installer task for each service must be named `setup.sh` within its directory:
  ```text
  tasks/services/<service>/setup.sh
  ```
- Mise maps this path to the task identifier `services:<service>:setup`.
- **Always provide a short-form alias** to preserve the top-level command:
  ```bash
  #MISE description="<Brief description>"
  #MISE alias="services:<service>"
  ```
  This guarantees that both `mise run services:<service>` and `mise run services:<service>:setup` are valid and resolve to the same script.

### 2. Service Subtasks
- Supplementary tasks specific to a service (such as upgrades, downloads, or maintenance) live in the same directory alongside `setup.sh`:
  - `tasks/services/paseo/upgrade.sh` -> `services:paseo:upgrade`
  - `tasks/services/paseo/appimage.sh` -> `services:paseo:appimage`

### 3. Relative Path Resolution (`MISE_TASK_DIR`)
- Because service tasks are three directory levels deep from the repository root (`tasks/services/<service>`), use three parent traversals (`../../../`) when referencing the repository root or `lib/`:
  ```bash
  source "${MISE_TASK_DIR}/../../../lib/common.sh"
  source "${MISE_TASK_DIR}/../../../lib/firewalld.sh"
  ```
- Static assets, unit templates, and configurations stored in `lib/services/<service>/` are also accessed via:
  ```bash
  "${MISE_TASK_DIR}/../../../lib/services/<service>/<filename>"
  ```

### 4. Standard Flags & Behavior
- All service tasks must be non-destructive and opt-in.
- Declare [`#USAGE`](https://usage.jdx.dev) specification comments for all flags and arguments.
- Always implement standard flags:
  - `-n, --dry-run`: Preview operations without modifying the host.
  - `--remove`: Cleanly stop, disable, and uninstall systemd units, configurations, or packages.
