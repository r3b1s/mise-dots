# Services Tasks (`tasks/services`)

Opt-in setup and management tasks for background services, daemons, and containers on **Arch-based distributions** (Arch Linux, CachyOS, Omarchy).

All service tasks are non-destructive and strictly opt-in. None of these services are enabled by default.

## Available Tasks

| Task | Description | Type | Key Flags |
|---|---|---|---|
| `services:syncthing` | Rootless Syncthing Podman Quadlet container bound to Tailscale | User (Quadlet) | `--reconfigure`, `--remove`, `-n` |
| `services:incus` | Incus system-container and VM manager daemon setup | System | `--ui`, `--remove`, `-n` |
| `services:kanata` | Kanata keyboard remapper with enthium layout | System | `--remove`, `-n` |
| `services:paseo` | Paseo AI coding agent daemon user service | User | `--netbird`, `--tailscale`, `--remove`, `-n` |
| `services:paseo:upgrade` | Upgrade Paseo CLI and desktop app | User | `-n` |
| `services:paseo:appimage` | Install/update Paseo desktop AppImage | User | `--check`, `--remove`, `--tag <tag>`, `-n` |
| `services:sunshine` | Sunshine GameStream server for Moonlight | User / Session | `--remove`, `-n` |
| `services:voxtype` | Voxtype push-to-talk dictation with Parakeet ONNX model | User / Session | `--remove`, `-n` |

## Design & Architecture

### System vs. User Services
- **System services (`incus`, `kanata`)**:
  - Run with root privilege or dedicated unprivileged system users (`kanata`, `incus-admin`).
  - Configure device permissions via `/etc/udev/rules.d/`, kernel modules via `/etc/modules-load.d/`, and user accounts via `/etc/sysusers.d/`.
- **User services (`paseo`, `sunshine`, `syncthing`, `voxtype`)**:
  - Run within the user session (`systemctl --user` or Podman rootless Quadlet).
  - Placed in `~/.config/systemd/user/` or `~/.config/containers/systemd/`.
  - Supervised by systemd without needing root privileges.

### Graphical Session Autostart Hooks
Services that depend on active graphical displays or hotkeys (e.g., Sunshine, Voxtype) hook into:
- **i3**: `~/.config/i3/conf.d/06-services.conf`
- **Hyprland**: `~/.config/hypr/cachy-services.lua` (loaded dynamically by `~/.config/hypr/cachy.lua`)

### Assets & Configurations
Auxiliary service configurations, unit files, and layout templates are maintained under `lib/services/<service>/`:
- `lib/services/kanata/`: `enthium.kbd`, `kanata.service`, `sysusers.conf`, `udev.rules`, `modules-load.conf`
- `lib/services/paseo/`: `paseo.service`
- `lib/services/sunshine/`: `sunshine.service`
- `lib/services/syncthing/`: `syncthing.container`
- `lib/services/voxtype/`: `config.toml`

### Common Flags
All service tasks implement standard CLI flags:
- `-n, --dry-run`: Preview actions and configuration writes without altering system state.
- `-h, --help`: Display usage, flags, and descriptions.
- `--remove`: Gracefully stop running services, clean up systemd units, firewall zones, and configuration files.
