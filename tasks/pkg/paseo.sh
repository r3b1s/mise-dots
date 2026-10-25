#!/usr/bin/env bash
#MISE description="Install Paseo CLI globally via mise (npm backend)"
#MISE alias="pkg:paseo-cli"
#USAGE flag "-n --dry-run" help="Preview without modifying config"
#USAGE flag "-f --force" help="Force reinstall"
#USAGE flag "--pin" help="Pin the resolved version"
#USAGE arg "[args]..." help="Additional arguments forwarded to mise use"
set -euo pipefail

mise use -g npm:@getpaseo/cli@latest "$@"
