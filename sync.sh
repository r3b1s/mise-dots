#!/usr/bin/env bash
mise_dots="/home/$USER/Dotfiles/mise-dots"
config_dir="/home/$USER/.config/mise"

mkdir -p "${config_dir}"
rm -f "${config_dir}/config.toml"
cp "${mise_dots}/config.toml" "${config_dir}/config.toml"
