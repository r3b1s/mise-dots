# Package Tasks (`tasks/pkg/`)

Tasks for installing and managing applications and packages.

## Subcategories

### 1. Open-Source Software (`pkg:oss:*`)
Installs open-source tools and applications that are not packaged in Arch/CachyOS/Omarchy repos — compiled from source using scoped Mise toolchains or installed from verified upstream release binaries:

| Task | Description | Source / Build Method |
|---|---|---|
| `pkg:oss:artcraft` | ArtCraft AI image/video creative IDE | Built from source via scoped toolchain in `lib/pkg/oss/artcraft/mise.toml` (Node 24, Rust, Tauri CLI, CMake) |
| `pkg:oss:coi` | `coi` (Code on Incus) | Installed from GitHub release binary with SHA-256 verification |

### 2. Proprietary Software (`pkg:proprietary:*`)
Installs closed-source/vendor applications shipped as prebuilt Linux archives:

| Task | Description | Source / Install Method |
|---|---|---|
| `pkg:proprietary:antigravity-app` | Google Antigravity desktop application | Scrapes official Google download page, unpacks unprivileged, extracts icon from `resources/app.asar`, installs root-owned to `/usr/local/lib/antigravity` |

### 3. CLI Tools (`pkg:*`)
- `pkg:paseo`: Installs `@getpaseo/cli` globally via Mise's npm backend.
