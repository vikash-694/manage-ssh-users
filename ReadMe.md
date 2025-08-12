Certainly! Here’s your full, production-ready `manage_ssh_user.sh` script combining all fixes and best practices, ready to run as root (via sudo):

```bash
#!/usr/bin/env bash
#
# manage_ssh_user.sh
# Production-ready interactive + non-interactive script to audit & fix SSH user setup.
#
# Usage (interactive):
#   sudo ./manage_ssh_user.sh
#
# Usage (non-interactive):
#   sudo ./manage_ssh_user.sh --username ranjeet.singh --pubkey "ssh-ed25519 AAAA..." --yes --replace-key --nopasswd
#
set -euo pipefail

LOG_FILE="/var/log/ssh_user_mgmt.log"
TIMESTAMP() { date '+%Y-%m-%d %H:%M:%S'; }
log_action() { echo "$(TIMESTAMP) | $*" | tee -a "$LOG_FILE"; }

# Defaults
AUTO_YES=0
DRY_RUN=0
REPLACE_KEY=0
GRANT_NOPASSWD=0
USERNAME=""
PUB_KEY=""
REQUESTED_SHELL=""

usage() {
  cat <<EOF
Usage: sudo $0 [options]

Options:
  --username USER        (optional) username to audit/manage (interactive if omitted)
  --pubkey "KEY"         (optional) public SSH key to add (interactive if omitted)
  --replace-key          (optional) replace authorized_keys (backups saved)
  --nopasswd             (optional) enable passwordless sudo for admin group
  --yes                  (optional) non-interactive: apply fixes without prompting
  --dry-run              (optional) audit only, do not change system
  --shell /bin/zsh       (optional) set user's login shell if creating user
  -h, --help             show this help
EOF
  exit 1
}

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --username) USERNAME="$2"; shift 2;;
    --pubkey) PUB_KEY="$2"; shift 2;;
    --replace-key) REPLACE_KEY=1; shift;;
    --nopasswd) GRANT_NOPASSWD=1; shift;;
    --yes) AUTO_YES=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --shell) REQUESTED_SHELL="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

# --- helpers ---
run_or_dry() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

is_valid_pubkey() {
  local k="$1"
  [[ -z "$k" ]] && return 1
  # support common key prefixes (rsa, ed25519, ecdsa, sk-*)
  if [[ "$k" =~ ^(ssh-(rsa|dss)|ssh-ed25519|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256) ]]; then
    return 0
  fi
  return 1
}

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
    ADMIN_GROUP="wheel" # safe default
  fi
}

# --- interactive prompting (if needed) ---
prompt_if_needed() {
  if [[ -z "$USERNAME" ]]; then
    read -rp "👉 Enter username to create/manage: " USERNAME
    while [[ -z "$USERNAME" ]]; do
      echo "❌ Username cannot be empty."
      read -rp "👉 Enter username to create/manage: " USERNAME
    done
  fi

  if [[ -z "$PUB_KEY" ]]; then
    read -rp "👉 Paste PUBLIC SSH key for '$USERNAME' (or leave blank to skip): " PUB_KEY
    # allow empty: skip key install
    if [[ -n "$PUB_KEY" ]]; then
      until is_valid_pubkey "$PUB_KEY"; do
        echo "❌ Invalid SSH public key format. Try again or press Ctrl+C to abort."
        read -rp "👉 Paste PUBLIC SSH key for '$USERNAME' (or leave blank to skip): " PUB_KEY
        [[ -z "$PUB_KEY" ]] && break
      done
    fi
  else
    if [[ -n "$PUB_KEY" ]]; then
      if ! is_valid_pubkey "$PUB_KEY"; then
        echo "Provided --pubkey doesn't look valid. Aborting."
        exit 1
      fi
    fi
  fi
}

# --- pre-check / audit ---
audit_user() {
  echo
  echo "======================== PRE-CHECK REPORT ========================"
  echo "System: $OS_PRETTY"
  echo "Detected admin group: $ADMIN_GROUP"
  echo "Target user: $USERNAME"
  echo "Dry-run: $DRY_RUN"
  echo "---------------------------------------------------------------"

  if id "$USERNAME" &>/dev/null; then
    USER_EXISTS=1
    USER_INFO="$(getent passwd "$USERNAME")"
    HOMEDIR="$(echo "$USER_INFO" | cut -d: -f6)"
    USER_SHELL="$(echo "$USER_INFO" | cut -d: -f7)"
    USER_UID="$(echo "$USER_INFO" | cut -d: -f3)"
    USER_GID="$(echo "$USER_INFO" | cut -d: -f4)"
    echo "✅ User exists (uid:$USER_UID gid:$USER_GID shell:$USER_SHELL)"
  else
    USER_EXISTS=0
    HOMEDIR="/home/$USERNAME"
    USER_SHELL="${REQUESTED_SHELL:-/bin/bash}"
    echo "❌ User does NOT exist. Planned home: $HOMEDIR shell: $USER_SHELL"
  fi

  if [[ -d "$HOMEDIR" ]]; then
    hd_owner="$(stat -c '%U:%G' "$HOMEDIR")"
    hd_perms="$(stat -c '%a' "$HOMEDIR")"
    echo "✅ Home dir exists: $HOMEDIR (owner: $hd_owner perms: $hd_perms)"
    if [[ "$hd_perms" -gt 750 ]]; then
      echo "   ⚠️ Home perms are permissive; recommended 700/750"
    fi
  else
    echo "❌ Home dir missing: $HOMEDIR"
  fi

  if [[ -d "$HOMEDIR/.ssh" ]]; then
    ssh_perms="$(stat -c '%a' "$HOMEDIR/.ssh")"
    echo "✅ $HOMEDIR/.ssh exists (perms: $ssh_perms)"
    [[ "$ssh_perms" -ne 700 ]] && echo "   ⚠️ .ssh perms should be 700"
  else
    echo "❌ $HOMEDIR/.ssh missing"
  fi

  if [[ -f "$HOMEDIR/.ssh/authorized_keys" ]]; then
    ak_perms="$(stat -c '%a' "$HOMEDIR/.ssh/authorized_keys")"
    echo "✅ authorized_keys found (perms: $ak_perms)"
    [[ "$ak_perms" -ne 600 ]] && echo "   ⚠️ authorized_keys perms should be 600"
    if grep -E "ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp" "$HOMEDIR/.ssh/authorized_keys" &>/dev/null; then
      echo "   ✅ authorized_keys contains at least one plausible public key"
    else
      echo "   ⚠️ No recognizable SSH public key in authorized_keys"
    fi
  else
    echo "❌ authorized_keys missing"
  fi

  echo "Shell startup file checks:"
  for f in .bash_profile .bashrc .profile .zshrc; do
    if [[ -f "$HOMEDIR/$f" ]]; then
      fperms="$(stat -c '%a' "$HOMEDIR/$f")"
      fowner="$(stat -c '%U:%G' "$HOMEDIR/$f")"
      echo "  - $f exists (owner: $fowner perms: $fperms)"
      [[ "$fperms" -gt 644 ]] && echo "    ⚠️ $f has permissive perms; recommended 600 or 640"
    else
      echo "  - $f missing"
    fi
  done

  # SELinux/AppArmor info
  if command -v getenforce &>/dev/null; then
    se_status="$(getenforce || true)"
    echo "SELinux: $se_status"
    if [[ "$se_status" == "Enforcing" && -d "$HOMEDIR" ]]; then
      ctx=$(ls -Zd "$HOMEDIR" | awk '{print $1}')
      echo "  Home context: $ctx"
    fi
  fi
  if command -v aa-status &>/dev/null; then
    echo "AppArmor present: $(aa-status --parsable 2>/dev/null | head -n1 || true)"
  fi

  # admin group / sudo
  if getent group "$ADMIN_GROUP" >/dev/null; then
    if id -nG "$USERNAME" &>/dev/null && id -nG "$USERNAME" | grep -qw "$ADMIN_GROUP"; then
      echo "✅ $USERNAME is in admin group ($ADMIN_GROUP)"
    else
      echo "❌ $USERNAME is NOT in admin group ($ADMIN_GROUP)"
    fi
  else
    echo "⚠️ Admin group $ADMIN_GROUP does not exist on this system"
  fi

  if [[ -f "/etc/sudoers.d/99-${ADMIN_GROUP}-nopasswd" ]]; then
    echo "✅ Passwordless sudo configured for $ADMIN_GROUP"
  else
    echo "ℹ️ Passwordless sudo not configured for $ADMIN_GROUP"
  fi

  echo "================================================================"
  echo
}

# --- apply fixes ---
apply_fixes() {
  log_action "APPLY: Starting fixes for $USERNAME"

  # create user if missing
  if ! id "$USERNAME" &>/dev/null; then
    SHELL_TO_USE="${REQUESTED_SHELL:-}"
    if [[ -z "$SHELL_TO_USE" ]]; then
      if [[ -x /bin/bash ]]; then SHELL_TO_USE=/bin/bash
      elif [[ -x /bin/zsh ]]; then SHELL_TO_USE=/bin/zsh
      else SHELL_TO_USE=/bin/sh
      fi
    fi
    run_or_dry "useradd --create-home --shell '$SHELL_TO_USE' '$USERNAME'"
    run_or_dry "passwd -l '$USERNAME'"
    log_action "Created user $USERNAME (shell $SHELL_TO_USE)"
  else
    log_action "User $USERNAME exists"
  fi

  USER_INFO="$(getent passwd "$USERNAME")"
  HOMEDIR="$(echo "$USER_INFO" | cut -d: -f6)"
  USER_SHELL="$(echo "$USER_INFO" | cut -d: -f7)"

  # ensure homedir exists + ownership/perms
  run_or_dry "mkdir -p '$HOMEDIR'"
  run_or_dry "chown -R '$USERNAME':'$USERNAME' '$HOMEDIR'"
  run_or_dry "chmod 750 '$HOMEDIR' || true"

  # ensure shell startup files
  case "$USER_SHELL" in
    */bash)
      for f in .bash_profile .bashrc; do
        fp="$HOMEDIR/$f"
        if [[ ! -f "$fp" ]]; then
          if [[ -f "/etc/skel/$f" ]]; then run_or_dry "cp /etc/skel/$f '$fp'"; else run_or_dry "touch '$fp'"; fi
          run_or_dry "chown '$USERNAME':'$USERNAME' '$fp'"
          run_or_dry "chmod 640 '$fp'"
          log_action "Created $fp"
        fi
      done
      ;;
    */zsh)
      fp="$HOMEDIR/.zshrc"
      if [[ ! -f "$fp" ]]; then
        [[ -f /etc/skel/.zshrc ]] && run_or_dry "cp /etc/skel/.zshrc '$fp'" || run_or_dry "touch '$fp'"
        run_or_dry "chown '$USERNAME':'$USERNAME' '$fp'"
        run_or_dry "chmod 640 '$fp'"
        log_action "Created $fp"
      fi
      ;;
    */sh|*/dash|*/ksh)
      fp="$HOMEDIR/.profile"
      if [[ ! -f "$fp" ]]; then
        [[ -f /etc/skel/.profile ]] && run_or_dry "cp /etc/skel/.profile '$fp'" || run_or_dry "touch '$fp'"
        run_or_dry "chown '$USERNAME':'$USERNAME' '$fp'"
        run_or_dry "chmod 640 '$fp'"
        log_action "Created $fp"
      fi
      ;;
    */fish)
      run_or_dry "mkdir -p '$HOMEDIR/.config/fish'"
      fp="$HOMEDIR/.config/fish/config.fish"
      [[ ! -f "$fp" ]] && run_or_dry "touch '$fp'"
      run_or_dry "chown -R '$USERNAME':'$USERNAME' '$HOMEDIR/.config/fish'"
      run_or_dry "chmod 640 '$fp'"
      ;;
    *)
      for f in .bashrc .profile; do
        fp="$HOMEDIR/$f"
        [[ ! -f "$fp" ]] && run_or_dry "touch '$fp'" && run_or_dry "chown '$USERNAME':'$USERNAME' '$fp'" && run_or_dry "chmod 640 '$fp'"
      done
      ;;
  esac

  # setup .ssh and authorized_keys perms
  SSH_DIR="$HOMEDIR/.ssh"
  AUTH="$SSH_DIR/authorized_keys"
  run_or_dry "mkdir -p '$SSH_DIR'"
  run_or_dry "touch '$AUTH'"
  run_or_dry "chown -R '$USERNAME':'$USERNAME' '$SSH_DIR'"
  run_or_dry "chmod 700 '$SSH_DIR'"
  run_or_dry "chmod 600 '$AUTH'"

  # handle pubkey if provided
  if [[ -n "$PUB_KEY" ]]; then
    if ! is_valid_pubkey "$PUB_KEY"; then
      echo "ERROR: Provided public key appears invalid; skipping key install." >&2
    else
      if [[ -s "$AUTH" && $REPLACE_KEY -eq 1 ]]; then
        BACKUP="/var/backups/${USERNAME}_authorized_keys_$(date +%Y%m%d%H%M%S).bak"
        run_or_dry "mkdir -p /var/backups"
        run_or_dry "cp '$AUTH' '$BACKUP'"
        run_or_dry "chown root:root '$BACKUP' || true"
        log_action "Backed up $AUTH to $BACKUP"
        run_or_dry "echo '$PUB_KEY' > '$AUTH'"
        log_action "Replaced authorized_keys for $USERNAME"
      elif [[ -s "$AUTH" ]]; then
        if ! grep -qxF "$PUB_KEY" "$AUTH"; then
          run_or_dry "echo '$PUB_KEY' >> '$AUTH'"
          log_action "Appended key to $AUTH"
        else
          log_action "Key already present in $AUTH"
        fi
      else
        run_or_dry "echo '$PUB_KEY' > '$AUTH'"
        log_action "Wrote new authorized_keys for $USERNAME"
      fi
      run_or_dry "chown '$USERNAME':'$USERNAME' '$AUTH'"
      run_or_dry "chmod 600 '$AUTH'"
    fi
  else
    log_action "No pubkey provided; skipping key install"
  fi

  # SELinux restore if available
  if command -v restorecon &>/dev/null; then
    run_or_dry "restorecon -Rv '$HOMEDIR' || true"
    log_action "Ran restore
```


con on \$HOMEDIR (if SELinux)"
fi

# add to admin group if missing

if getent group "\$ADMIN\_GROUP" >/dev/null; then
if id -nG "\$USERNAME" | grep -qw "\$ADMIN\_GROUP"; then
log\_action "\$USERNAME already in \$ADMIN\_GROUP"
else
run\_or\_dry "usermod -aG '\$ADMIN\_GROUP' '\$USERNAME'"
log\_action "Added \$USERNAME to \$ADMIN\_GROUP"
fi
else
log\_action "Admin group \$ADMIN\_GROUP not present; skipping group add"
fi

# passwordless sudo if requested

if \[\[ "\$GRANT\_NOPASSWD" -eq 1 ]]; then
SUDOERS\_FILE="/etc/sudoers.d/99-\${ADMIN\_GROUP}-nopasswd"
if \[\[ ! -f "\$SUDOERS\_FILE" ]]; then
run\_or\_dry "printf '%%%s ALL=(ALL) NOPASSWD: ALL\n' '\$ADMIN\_GROUP' > '\$SUDOERS\_FILE'"
run\_or\_dry "chmod 440 '\$SUDOERS\_FILE'"
if \[\[ "\$DRY\_RUN" -eq 0 ]]; then
if ! visudo -cf "\$SUDOERS\_FILE"; then
echo "ERROR: visudo check failed for \$SUDOERS\_FILE; removing file" >&2
run\_or\_dry "rm -f '\$SUDOERS\_FILE'"
exit 1
fi
fi
log\_action "Created \$SUDOERS\_FILE (passwordless sudo for \$ADMIN\_GROUP)"
else
log\_action "Passwordless sudo already present at \$SUDOERS\_FILE"
fi
fi

log\_action "APPLY: Fixes complete for \$USERNAME"
}

# ---- main ----

if \[\[ \$EUID -ne 0 ]]; then
echo "This script must be run as root (sudo)." >&2
exit 1
fi

detect\_os\_admin
prompt\_if\_needed
audit\_user

if \[\[ "\$DRY\_RUN" -eq 1 ]]; then
echo "Dry-run mode: no changes will be made. Re-run without --dry-run to apply fixes."
exit 0
fi

if \[\[ "\$AUTO\_YES" -eq 0 ]]; then
read -rp "Proceed to apply fixes described above for '\$USERNAME'? \[y/N]: " ans
if \[\[ ! "\$ans" =\~ ^\[Yy]\$ ]]; then
echo "Aborting; no changes made."
exit 0
fi
else
log\_action "--yes provided; applying fixes non-interactively"
fi

apply\_fixes

echo
echo "Done. Review actions in \$LOG\_FILE"

````

---

### How to use:

- Interactive mode (prompts for username and pubkey):

```bash
sudo ./manage_ssh_user.sh
````

* Non-interactive mode (replace with your actual username and key):

```bash
sudo ./manage_ssh_user.sh --username johndoe --pubkey "ssh-ed25519 AAAA..." --yes --replace-key --nopasswd
```

* Dry run (audit only, no changes):

```bash
sudo ./manage_ssh_user.sh --username johndoe --dry-run
```

---

If you want, I can also help with creating a README or packaging it for easy reuse!
