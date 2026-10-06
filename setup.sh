#!/usr/bin/env bash

# dotfiles location
DOTS="/home/$USER/Dotfiles"

# repo
mise_dots_https='https://github.com/r3b1s/mise-dots.git'
mise_dots_ssh='git@github.com:r3b1s/mise-dots.git'

# symlink source & target
mise_dots="${DOTS}/mise-dots"
link_dir="/home/$USER/.config/mise"

mkdir -p "${DOTS}"
cd "${DOTS}"
git clone "${mise_dots_https}"

mkdir -p "${link_dir}"
rm "${link_dir}/config.toml"
ln -s  "${mise_dots}/config.toml" "${link_dir}/config.toml"
