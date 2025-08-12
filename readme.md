Got it! Here’s a full **production-ready interactive cleanup script** to remove SSH user setup, including home directory removal, sudo cleanup, and user deletion — with prompts to confirm each step:

```bash
#!/usr/bin/env bash
#
# cleanup_ssh_user.sh
# Production-ready interactive + non-interactive cleanup script to remove SSH user setup.
#
# Usage (interactive):
#   sudo ./cleanup_ssh_user.sh
#
# Usage (non-interactive):
#   sudo ./cleanup_ssh_user.sh --username ranjeet.singh --remove-home --remove-nopasswd --yes --dry-run
#
set -euo pipefail

LOG_FILE="/var/log/ssh_user_mgmt_cleanup.log"
TIMESTAMP() { date '+%Y-%m-%d %H:%M:%S'; }
log_action() { echo "$(TIMESTAMP) | $*" | tee -a "$LOG_FILE"; }

# Defaults
AUTO_YES=0
DRY_RUN=0
REMOVE_HOME=0
REMOVE_NOPASSWD=0
USERNAME=""
ADMIN_GROUP=""

usage() {
  cat <<EOF
Usage: sudo $0 [options]

Options:
  --username USER          (optional) username to cleanup (interactive if omitted)
  --remove-home            (optional) remove user's home directory
  --remove-nopasswd        (optional) remove passwordless sudo config for admin group
  --yes                    (optional) non-interactive: apply cleanup without prompting
  --dry-run                (optional) audit only, do not change system
  -h, --help               show this help
EOF
  exit 1
}

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --username) USERNAME="$2"; shift 2;;
    --remove-home) REMOVE_HOME=1; shift;;
    --remove-nopasswd) REMOVE_NOPASSWD=1; shift;;
    --yes) AUTO_YES=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

detect_os_admin() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_PRETTY="${PRETTY_NAME:-$NAME}"
  else
    OS_PRETTY="unknown"
  fi

  if echo "$OS_PRETTY" | grep -qiE 'amazon linux|rhel|centos|rocky|almalinux|fedora'; then
    ADMIN_GROUP="wheel"
  elif echo "$OS_PRETTY" | grep -qiE 'ubuntu|debian'; then
    ADMIN_GROUP="sudo"
  elif echo "$OS_PRETTY" | grep -qiE 'sles|opensuse'; then
    ADMIN_GROUP="wheel"
  else
    ADMIN_GROUP="wheel"
  fi
}

run_or_dry() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

prompt_if_needed() {
  if [[ -z "$USERNAME" ]]; then
    read -rp "👉 Enter username to cleanup: " USERNAME
    while [[ -z "$USERNAME" ]]; do
      echo "❌ Username cannot be empty."
      read -rp "👉 Enter username to cleanup: " USERNAME
    done
  fi

  if [[ "$REMOVE_HOME" -eq 0 ]]; then
    read -rp "Remove home directory for '$USERNAME'? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      REMOVE_HOME=1
    fi
  fi

  if [[ "$REMOVE_NOPASSWD" -eq 0 ]]; then
    read -rp "Remove passwordless sudo config for admin group ($ADMIN_GROUP)? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      REMOVE_NOPASSWD=1
    fi
  fi

  if [[ "$AUTO_YES" -eq 0 ]]; then
    read -rp "Proceed with cleanup for user '$USERNAME'? [y/N]: " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
      echo "Aborting cleanup."
      exit 0
    fi
  else
    log_action "--yes provided; proceeding with cleanup non-interactively"
  fi
}

audit_cleanup() {
  echo
  echo "======================== CLEANUP AUDIT ========================"
  echo "System: $OS_PRETTY"
  echo "Admin group: $ADMIN_GROUP"
  echo "Target user: $USERNAME"
  echo "Remove home dir: $REMOVE_HOME"
  echo "Remove passwordless sudo config: $REMOVE_NOPASSWD"
  echo "Dry-run: $DRY_RUN"
  echo "---------------------------------------------------------------"

  if id "$USERNAME" &>/dev/null; then
    USER_EXISTS=1
    echo "✅ User '$USERNAME' exists."
  else
    USER_EXISTS=0
    echo "❌ User '$USERNAME' does not exist."
  fi

  if [[ $REMOVE_HOME -eq 1 ]]; then
    HOMEDIR=$(getent passwd "$USERNAME" | cut -d: -f6 || echo "/home/$USERNAME")
    if [[ -d "$HOMEDIR" ]]; then
      echo "✅ Home directory $HOMEDIR exists and will be removed."
    else
      echo "⚠️ Home directory $HOMEDIR does not exist or already removed."
    fi
  fi

  SUDOERS_FILE="/etc/sudoers.d/99-${ADMIN_GROUP}-nopasswd"
  if [[ $REMOVE_NOPASSWD -eq 1 ]]; then
    if [[ -f "$SUDOERS_FILE" ]]; then
      echo "✅ Passwordless sudo config $SUDOERS_FILE exists and will be removed."
    else
      echo "⚠️ Passwordless sudo config $SUDOERS_FILE does not exist."
    fi
  fi

  echo "================================================================"
  echo
}

apply_cleanup() {
  log_action "CLEANUP: Starting cleanup for user $USERNAME"

  if id "$USERNAME" &>/dev/null; then
    # Remove user from admin group if present
    if id -nG "$USERNAME" | grep -qw "$ADMIN_GROUP"; then
      run_or_dry "gpasswd -d '$USERNAME' '$ADMIN_GROUP' || true"
      log_action "Removed $USERNAME from $ADMIN_GROUP"
    else
      log_action "$USERNAME not in $ADMIN_GROUP; skipping removal"
    fi

    # Delete the user
    run_or_dry "userdel $([[ $REMOVE_HOME -eq 1 ]] && echo '-r') '$USERNAME'"
    log_action "Deleted user $USERNAME (with home: $REMOVE_HOME)"
  else
    log_action "User $USERNAME does not exist; skipping userdel"
  fi

  # Remove passwordless sudo config if requested
  if [[ $REMOVE_NOPASSWD -eq 1 ]]; then
    SUDOERS_FILE="/etc/sudoers.d/99-${ADMIN_GROUP}-nopasswd"
    if [[ -f "$SUDOERS_FILE" ]]; then
      run_or_dry "rm -f '$SUDOERS_FILE'"
      log_action "Removed passwordless sudo config $SUDOERS_FILE"
    else
      log_action "Passwordless sudo config $SUDOERS_FILE not found; skipping"
    fi
  fi

  log_action "CLEANUP: Completed for user $USERNAME"
}

# ---- main ----
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo)." >&2
  exit 1
fi

detect_os_admin
prompt_if_needed
audit_cleanup

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry-run mode: no changes will be made. Re-run without --dry-run to apply cleanup."
  exit 0
fi

apply_cleanup

echo
echo "Cleanup done. Review actions in $LOG_FILE"
```

---

### How to use:

* Interactive mode (will prompt you step-by-step):

  ```bash
  sudo ./cleanup_ssh_user.sh
  ```

* Non-interactive mode (example):

  ```bash
  sudo ./cleanup_ssh_user.sh --username ranjeet.singh --remove-home --remove-nopasswd --yes
  ```

* Dry-run mode to see what would happen without any changes:

  ```bash
  sudo ./cleanup_ssh_user.sh --username ranjeet.singh --dry-run
  ```

---

Want me to help you with integrating this into your existing setup or customizing it further?
