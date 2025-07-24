#!/bin/bash

set -e

LOG_FILE="/var/log/ssh_user_mgmt.log"

log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

# ✅ Auto-detect admin group
if grep -qi 'amazon linux' /etc/os-release || grep -qi 'rhel' /etc/os-release || grep -qi 'centos' /etc/os-release; then
    ADMIN_GROUP="wheel"
elif grep -qi 'ubuntu' /etc/os-release || grep -qi 'debian' /etc/os-release; then
    ADMIN_GROUP="sudo"
else
    echo "❌ Unsupported OS. Please configure manually."
    exit 1
fi

echo "📌 Default admin group detected: $ADMIN_GROUP"

# ✅ Username input
read -rp "👉 Enter username to create/manage: " USERNAME
if [[ -z "$USERNAME" ]]; then
    echo "❌ Username cannot be empty."
    exit 1
fi

# ✅ SSH Key input
read -rp "👉 Paste PUBLIC SSH key for '$USERNAME': " PUB_KEY

# ✅ SSH Key basic validation
if [[ ! "$PUB_KEY" =~ ^(ssh-(rsa|ed25519|ecdsa)) ]]; then
    echo "❌ Invalid or unsupported SSH key format."
    exit 1
fi

# ✅ Create user (if not exists)
if ! id "$USERNAME" &>/dev/null; then
    useradd --create-home --shell /bin/bash "$USERNAME"
    passwd -l "$USERNAME"
    log_action "User '$USERNAME' created and password locked."
else
    echo "ℹ️ User '$USERNAME' already exists."
    log_action "User '$USERNAME' exists."
fi

# ✅ Setup SSH directory
SSH_DIR="/home/$USERNAME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

# ✅ If user has keys, choose append or replace
if [[ -s "$AUTH_KEYS" ]]; then
    echo "⚠️ '$USERNAME' already has SSH keys configured."
    read -rp "👉 Type [a] to Append or [r] to Replace existing keys: " ACTION
    if [[ "$ACTION" =~ ^[Rr]$ ]]; then
        # Backup before replacement
        BACKUP_FILE="/var/backups/${USERNAME}_authorized_keys_$(date +%Y%m%d%H%M%S).bak"
        mkdir -p /var/backups
        cp "$AUTH_KEYS" "$BACKUP_FILE"
        echo "🛡️ Backup of authorized_keys saved at: $BACKUP_FILE"

        echo "$PUB_KEY" > "$AUTH_KEYS"
        echo "✅ SSH key REPLACED for '$USERNAME'."
        log_action "SSH key REPLACED for '$USERNAME'. Backup at $BACKUP_FILE"
    elif [[ "$ACTION" =~ ^[Aa]$ ]]; then
        grep -qxF "$PUB_KEY" "$AUTH_KEYS" || echo "$PUB_KEY" >> "$AUTH_KEYS"
        echo "✅ SSH key APPENDED for '$USERNAME'."
        log_action "SSH key APPENDED for '$USERNAME'."
    else
        echo "❌ Invalid option. Aborting."
        exit 1
    fi
else
    echo "$PUB_KEY" > "$AUTH_KEYS"
    echo "✅ SSH key configured for '$USERNAME'."
    log_action "SSH key configured for '$USERNAME'."
fi

# ✅ Confirm before admin group access
read -rp "⚠️ Do you want to add '$USERNAME' to the '$ADMIN_GROUP' group? [y/N]: " GRANT_ADMIN
if [[ "$GRANT_ADMIN" =~ ^[Yy]$ ]]; then
    usermod -aG "$ADMIN_GROUP" "$USERNAME"
    echo "✅ '$USERNAME' added to '$ADMIN_GROUP' group."
    log_action "'$USERNAME' added to '$ADMIN_GROUP'."
else
    echo "🚫 Skipped adding '$USERNAME' to '$ADMIN_GROUP'."
    log_action "Skipped adding '$USERNAME' to '$ADMIN_GROUP'."
fi

# ✅ Confirm before passwordless sudo
SUDOERS_FILE="/etc/sudoers.d/99-${ADMIN_GROUP}-nopasswd"
if [[ ! -f "$SUDOERS_FILE" ]]; then
    read -rp "⚠️ Do you want to grant passwordless sudo to '$ADMIN_GROUP'? [y/N]: " GRANT_SUDO
    if [[ "$GRANT_SUDO" =~ ^[Yy]$ ]]; then
        echo "%$ADMIN_GROUP ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
        chmod 440 "$SUDOERS_FILE"
        visudo -cf "$SUDOERS_FILE" || {
            echo "❌ Syntax error in $SUDOERS_FILE. Aborting."
            exit 1
        }
        echo "✅ Passwordless sudo granted to '$ADMIN_GROUP' group."
        log_action "Passwordless sudo granted to '$ADMIN_GROUP'."
    else
        echo "🚫 Skipped granting passwordless sudo."
        log_action "Skipped passwordless sudo setup."
    fi
else
    echo "ℹ️ Passwordless sudo already configured for '$ADMIN_GROUP'."
fi

echo "🎉 Setup complete for '$USERNAME'."
log_action "Setup complete for '$USERNAME'."
