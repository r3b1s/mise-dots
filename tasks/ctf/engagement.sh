#!/usr/bin/env bash
#MISE description="Clone a CTF / engagement template into the cwd"
#MISE dir="{{cwd}}"
#USAGE arg "[name]" help="Destination directory" default="engagement-template"
set -euo pipefail

git clone 'https://github.com/r3b1s/engagement-template' "${usage_name:?}"
rm -rf "${usage_name:?}/.git"
