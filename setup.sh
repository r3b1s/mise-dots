#!/usr/bin/env bash

# dotfiles location
DOTS="/home/$USER/Dotfiles"

# repo
mise_dots_https='https://github.com/r3b1s/mise-dots.git'
mise_dots_ssh='git@github.com:r3b1s/mise-dots.git'

# copy source & target
mise_dots="${DOTS}/mise-dots"
config_dir="/home/$USER/.config/mise"

mkdir -p "${DOTS}"
cd "${DOTS}"
git clone "${mise_dots_https}"

mkdir -p "${config_dir}"
rm -f "${config_dir}/config.toml"
cp "${mise_dots}/config.toml" "${config_dir}/config.toml"
