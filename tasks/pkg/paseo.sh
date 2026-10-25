#!/usr/bin/env bash
#MISE description="Install Paseo CLI globally via mise (npm backend)"
#MISE alias="pkg:paseo-cli"
set -euo pipefail

mise use -g npm:@getpaseo/cli@latest "$@"
