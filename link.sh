#!/usr/bin/env bash
mise_dots="/home/$USER/Dotfiles/mise-dots"
link_dir="/home/$USER/.config/mise"

mkdir -p "${link_dir}"
rm "${link_dir}/config.toml"
ln -s  "${mise_dots}/config.toml" "${link_dir}/config.toml"
