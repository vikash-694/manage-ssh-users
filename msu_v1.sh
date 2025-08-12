#!/usr/bin/env bash
#
# ssh_user_mgmt.sh
# Production-ready single script:
#  - Pre-check / Audit
#  - Interactive confirmation
#  - Fix mode (idempotent)
#
# Usage:
#   sudo ./ssh_user_mgmt.sh --username ranjeet.singh --pubkey "ssh-ed25519 AAAA..." [--yes] [--replace-key] [--nopasswd] [--dry-run]
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
FORCE_CREATE_USER=0
REQUESTED_SHELL=""

usage() {
cat <<EOF
Usage: sudo $0 --username USER --pubkey 'ssh-...' [options]

Options:
  --username USER        (required) username to audit/manage
  --pubkey "KEY"         (optional) public SSH key to add (wrapped in quotes)
  --replace-key          (optional) when pubkey given, replace existing authorized_keys
  --nopasswd             (optional) enable passwordless sudo for admin group
  --yes                  (optional) non-interactive: apply fixes without prompting
  --dry-run              (optional) only report actions, don't modify system
  --shell /bin/zsh       (optional) set user's login shell (if user created)
  -h, --help             show this help
EOF
exit 1
}

# Parse args
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

[[ -n "$USERNAME" ]] || { echo "ERROR: --username required"; usage; }

# Helpers for dry-run
run_or_dry() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# Validate pubkey basic format
is_valid_pubkey() {
    local k="$1"
    [[ -z "$k" ]] && return 1
    # Supports ssh-rsa, ssh-ed25519, ssh-dss, ecdsa-sha2-nistp*, sk-*, etc.
    [[ "$k" =~ ^(ssh-[r|d]sa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256) ]] && return 0
    return 1
}

# Detect OS & admin group
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
        ADMIN_GROUP="wheel"  # safe default
    fi
}

# Pre-check audit
audit_user() {
    echo "======================== PRE-CHECK REPORT ========================"
    echo "System: $OS_PRETTY"
    echo "Detected admin group: $ADMIN_GROUP"
    echo "Target user: $USERNAME"
    echo "Dry-run: $DRY_RUN"
    echo "---------------------------------------------------------------"

    USER_EXISTS=0
    if id "$USERNAME" &>/dev/null; then
        USER_EXISTS=1
        USER_INFO="$(getent passwd "$USERNAME")"
        HOMEDIR="$(echo "$USER_INFO" | cut -d: -f6)"
        USER_SHELL="$(echo "$USER_INFO" | cut -d: -f7)"
        USER_UID="$(echo "$USER_INFO" | cut -d: -f3)"
        USER_GID="$(echo "$USER_INFO" | cut -d: -f4)"
        echo "✅ User exists (uid: $USER_UID gid: $USER_GID shell: $USER_SHELL)"
    else
        USER_EXISTS=0
        HOMEDIR="/home/$USERNAME"
        USER_SHELL="${REQUESTED_SHELL:-/bin/bash}"
        echo "❌ User does NOT exist. Planned home: $HOMEDIR shell: $USER_SHELL"
    fi

    # Home dir checks
    if [[ -d "$HOMEDIR" ]]; then
        HD_OWNER="$(stat -c '%U:%G' "$HOMEDIR")"
        HD_PERMS="$(stat -c '%a' "$HOMEDIR")"
        echo "✅ Home dir exists: $HOMEDIR (owner: $HD_OWNER perms: $HD_PERMS)"
        if [[ "$HD_PERMS" -ne 700 && "$HD_PERMS" -ne 750 ]]; then
            echo "   ⚠️ Home perms may be nonstandard (recommended 700 or 750)"
        fi
    else
        echo "❌ Home dir missing: $HOMEDIR"
    fi

    # .ssh and authorized_keys checks
    if [[ -d "$HOMEDIR/.ssh" ]]; then
        SSH_PERMS="$(stat -c '%a' "$HOMEDIR/.ssh")"
        echo "✅ $HOMEDIR/.ssh exists (perms: $SSH_PERMS)"
        [[ "$SSH_PERMS" -ne 700 ]] && echo "   ⚠️ .ssh perms should be 700"
    else
        echo "❌ $HOMEDIR/.ssh missing"
    fi

    if [[ -f "$HOMEDIR/.ssh/authorized_keys" ]]; then
        AK_PERMS="$(stat -c '%a' "$HOMEDIR/.ssh/authorized_keys")"
        echo "✅ authorized_keys found (perms: $AK_PERMS)"
        [[ "$AK_PERMS" -ne 600 ]] && echo "   ⚠️ authorized_keys perms should be 600"
        # Check for any valid-looking key
        if grep -E "ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp" "$HOMEDIR/.ssh/authorized_keys" &>/dev/null; then
            echo "   ✅ authorized_keys contains at least one plausible public key"
        else
            echo "   ⚠️ No recognizable SSH public key found in authorized_keys"
        fi
    else
        echo "❌ authorized_keys missing"
    fi

    # Shell startup files
    echo "Checking shell startup files (some may not be required depending on shell):"
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

    # SELinux / AppArmor
    if command -v getenforce &>/dev/null; then
        SELINUX_STATUS="$(getenforce || true)"
        echo "SELinux: $SELINUX_STATUS"
        if [[ "$SELINUX_STATUS" == "Enforcing" ]]; then
            if command -v restorecon &>/dev/null; then
                echo "  restorecon available"
            fi
            # show context
            if [[ -d "$HOMEDIR" ]]; then
                ctx=$(ls -Zd "$HOMEDIR" | awk '{print $1}')
                echo "  Home context: $ctx"
            fi
        fi
    fi
    if command -v aa-status &>/dev/null; then
        echo "AppArmor present: $(aa-status --parsable 2>/dev/null | head -n1 || true)"
    fi

    # Sudo / admin group checks
    if getent group "$ADMIN_GROUP" >/dev/null; then
        if id -nG "$USERNAME" &>/dev/null && id -nG "$USERNAME" | grep -qw "$ADMIN_GROUP"; then
            echo "✅ $USERNAME is in admin group ($ADMIN_GROUP)"
        else
            echo "❌ $USERNAME is NOT in admin group ($ADMIN_GROUP)"
        fi
    else
        echo "⚠️ Admin group $ADMIN_GROUP does not exist on this system"
    fi

    SUDOERS_FILE="/etc/sudoers.d/99-${ADMIN_GROUP}-nopasswd"
    if [[ -f "$SUDOERS_FILE" ]]; then
        echo "✅ Passwordless sudo file exists: $SUDOERS_FILE"
    else
        echo "ℹ️ Passwordless sudo not configured for $ADMIN_GROUP"
    fi

    echo "================================================================"
}

# Apply fixes based on pre-check
apply_fixes() {
    log_action "APPLY: Starting fixes for user $USERNAME"

    # Create user if missing
    if ! id "$USERNAME" &>/dev/null; then
        # pick a reasonable shell
        SHELL_TO_USE="${REQUESTED_SHELL:-}"
        if [[ -z "$SHELL_TO_USE" ]]; then
            if [[ -x /bin/bash ]]; then SHELL_TO_USE=/bin/bash
            elif [[ -x /bin/zsh ]]; then SHELL_TO_USE=/bin/zsh
            else SHELL_TO_USE=/bin/sh
            fi
        fi
        run_or_dry "useradd --create-home --shell $SHELL_TO_USE '$USERNAME'"
        run_or_dry "passwd -l '$USERNAME'"
        log_action "Created user $USERNAME with shell $SHELL_TO_USE"
    else
        log_action "User $USERNAME already exists"
    fi

    USER_INFO="$(getent passwd "$USERNAME")"
    HOMEDIR="$(echo "$USER_INFO" | cut -d: -f6)"
    USER_SHELL="$(echo "$USER_INFO" | cut -d: -f7)"

    # Ensure home ownership and perms
    run_or_dry "mkdir -p '$HOMEDIR'"
    run_or_dry "chown -R '$USERNAME':'$USERNAME' '$HOMEDIR'"
    run_or_dry "chmod 750 '$HOMEDIR' || true"   # allow 750; some prefer 700

    # Setup .ssh and authorized_keys
    SSH_DIR="$HOMEDIR/.ssh"
    AUTH="$SSH_DIR/authorized_keys"
    run_or_dry "mkdir -p '$SSH_DIR'"
    run_or_dry "touch '$AUTH'"
    run_or_dry "chown -R '$USERNAME':'$USERNAME' '$SSH_DIR'"
    run_or_dry "chmod 700 '$SSH_DIR'"
    run_or_dry "chmod 600 '$AUTH'"

    if [[ -n "$PUB_KEY" ]]; then
        if ! is_valid_pubkey "$PUB_KEY"; then
            echo "ERROR: Provided public key doesn't look valid. Aborting key install." >&2
        else
            if [[ -s "$AUTH" && $REPLACE_KEY -eq 1 ]]; then
                BACKUP="/var/backups/${USERNAME}_authorized_keys_$(date +%Y%m%d%H%M%S).bak"
                run_or_dry "mkdir -p /var/backups"
                run_or_dry "cp '$AUTH' '$BACKUP'"
                run_or_dry "chown root:root '$BACKUP' || true"
                log_action "Backup authorized_keys to $BACKUP"
                run_or_dry "echo '$PUB_KEY' > '$AUTH'"
                log_action "Replaced authorized_keys for $USERNAME"
            elif [[ -s "$AUTH" ]]; then
                # append only if not present
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
        log_action "No pubkey provided, skipping key install"
    fi

    # Ensure shell startup files exist (based on user's shell)
    case "$USER_SHELL" in
        */bash)
            for f in .bashrc .bash_profile; do
                fp="$HOMEDIR/$f"
                if [[ ! -f "$fp" ]]; then
                    if [[ -f "/etc/skel/$f" ]]; then
                        run_or_dry "cp /etc/skel/$f '$fp'"
                    else
                        run_or_dry "touch '$fp'"
                    fi
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
            # generic fallback
            for f in .bashrc .profile; do
                fp="$HOMEDIR/$f"
                [[ ! -f "$fp" ]] && run_or_dry "touch '$fp'" && run_or_dry "chown '$USERNAME':'$USERNAME' '$fp'" && run_or_dry "chmod 640 '$fp'"
            done
            ;;
    esac

    # SELinux restore if available
    if command -v restorecon &>/dev/null; then
        run_or_dry "restorecon -Rv '$HOMEDIR' || true"
        log_action "restorecon run on $HOMEDIR (if SELinux enabled)"
    fi

    # Add to admin group if not present
    if getent group "$ADMIN_GROUP" >/dev/null; then
        if id -nG "$USERNAME" | grep -qw "$ADMIN_GROUP"; then
            log_action "$USERNAME already in $ADMIN_GROUP"
        else
            run_or_dry "usermod -aG '$ADMIN_GROUP' '$USERNAME'"
            log_action "Added $USERNAME to $ADMIN_GROUP"
        fi
    else
        log_action "ADMIN_GROUP $ADMIN_GROUP does not exist; skipping group add"
    fi

    # Passwordless sudo if requested
    if [[ "$GRANT_NOPASSWD" -eq 1 ]]; then
        SUDOERS_FILE="/etc/sudoers.d/99-${ADMIN_GROUP}-nopasswd"
        if [[ ! -f "$SUDOERS_FILE" ]]; then
            run_or_dry "echo \"%$ADMIN_GROUP ALL=(ALL) NOPASSWD: ALL\" > '$SUDOERS_FILE'"
            run_or_dry "chmod 440 '$SUDOERS_FILE'"
            if [[ "$DRY_RUN" -eq 0 ]]; then
                visudo -cf "$SUDOERS_FILE" || { echo "ERROR: visudo check failed; removing $SUDOERS_FILE"; rm -f "$SUDOERS_FILE"; exit 1; }
            fi
            log_action "Created $SUDOERS_FILE (passwordless sudo for $ADMIN_GROUP)"
        else
            log_action "Passwordless sudo already configured at $SUDOERS_FILE"
        fi
    fi

    log_action "APPLY: Fixes complete for $USERNAME"
}

#######################
# main
#######################
detect_os_admin
audit_user

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry-run mode: no changes will be made. To apply fixes, re-run without --dry-run or with --yes."
    exit 0
fi

if [[ "$AUTO_YES" -eq 0 ]]; then
    echo
    read -rp "Proceed to apply fixes described above for '$USERNAME'? [y/N]: " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo "Aborting; no changes made."
        exit 0
    fi
else
    log_action "--yes provided; applying fixes non-interactively"
fi

apply_fixes

echo
echo "Done. Check $LOG_FILE for details."
