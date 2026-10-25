#!/usr/bin/env bash
# Shared helpers for mise-dots tasks. Source this file; do not execute it.
#
# Task scripts source it through MISE_TASK_DIR:
#   source "${MISE_TASK_DIR}/../../lib/common.sh"

# Omarchy Pinkrot theme
DOTS_THEME_NAME='omarchy-pinkrot-theme'
DOTS_THEME_HTTPS="https://github.com/r3b1s/${DOTS_THEME_NAME}.git"
DOTS_THEME_SSH="git@github.com:r3b1s/${DOTS_THEME_NAME}.git"

# require_os <needle>
# Exit unless /etc/os-release ID or NAME contains <needle> (case-insensitive).
require_os() {
  local needle="${1:?require_os needs an OS name}"
  if [[ ! -r /etc/os-release ]]; then
    echo "Error: /etc/os-release not found; cannot verify OS." >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ "${ID,,}" != *"${needle,,}"* && "${NAME,,}" != *"${needle,,}"* ]]; then
    echo "Error: this task requires ${needle} (detected: ${PRETTY_NAME:-${NAME:-unknown}})." >&2
    exit 1
  fi
}

# clone_repo <https-url> <ssh-url> <destination>
# Clones over HTTPS unless the repo is already there. With DOTS_GIT_PROTOCOL=ssh,
# rewrites origin to the SSH URL afterwards.
clone_repo() {
  local https_url="${1:?https url required}"
  local ssh_url="${2:?ssh url required}"
  local dest="${3:?destination required}"

  mkdir -p "$(dirname "$dest")"
  if [[ -d "${dest}/.git" ]]; then
    printf 'Already cloned, skipping: %s\n' "$dest"
  else
    git clone "$https_url" "$dest"
  fi

  if [[ "${DOTS_GIT_PROTOCOL:-https}" == "ssh" ]]; then
    git -C "$dest" remote set-url origin "$ssh_url"
  fi
}

# link_theme
# Symlink the theme checkout into the Omarchy themes directory.
link_theme() {
  local themes_dir="${HOME}/.config/omarchy/themes"
  mkdir -p "$themes_dir"
  ln -sfn "${DOTS_DIR}/${DOTS_THEME_NAME}" "${themes_dir}/${DOTS_THEME_NAME}"
}

# use_ssh_when_requested <usage_ssh value>
# Maps a task's --ssh flag onto DOTS_GIT_PROTOCOL.
use_ssh_when_requested() {
  if [[ "${1:-false}" == "true" ]]; then
    export DOTS_GIT_PROTOCOL=ssh
  fi
}
