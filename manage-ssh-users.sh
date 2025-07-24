#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# ✅ Auto-detect default admin group based on OS
if grep -qi 'amazon linux' /etc/os-release || grep -qi 'rhel' /etc/os-release || grep -qi 'centos' /etc/os-release; then
    ADMIN_GROUP="wheel"
elif grep -qi 'ubuntu' /etc/os-release || grep -qi 'debian' /etc/os-release; then
    ADMIN_GROUP="sudo"
else
    echo "❌ Unsupported OS. Please configure manually."
    exit 1
fi

# Check if the admin group is set correctly
if [[ -z "$ADMIN_GROUP" ]]; then
    echo "❌ Unable to determine the default admin group."
    exit 1
fi

echo "📌 Default admin group detected: $ADMIN_GROUP"

# ✅ Prompt for username to create or manage
read -rp "👉 Enter username to create/manage: " USERNAME
if [[ -z "$USERNAME" ]]; then
    echo "❌ Username cannot be empty."
    exit 1
fi

# ✅ Prompt for SSH public key for the user
read -rp "👉 Paste PUBLIC SSH key for '$USERNAME': " PUB_KEY
if [[ -z "$PUB_KEY" ]]; then
    echo "❌ SSH key required."
    exit 1
fi

# ✅ Create the user if they do not exist, and lock their password
if ! id "$USERNAME" &>/dev/null; then
    useradd --create-home --shell /bin/bash "$USERNAME"
    passwd -l "$USERNAME"
    echo "✅ User '$USERNAME' created and password locked."
else
    echo "ℹ️ User '$USERNAME' already exists."
fi

# ✅ Setup SSH access for the user
# Get the user's home directory (handles custom home paths)
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
if [[ -z "$USER_HOME" ]]; then
    echo "❌ Unable to retrieve home directory for '$USERNAME'."
    exit 1
fi

# Create .ssh directory if it doesn't exist
mkdir -p "$USER_HOME/.ssh"

# Check if the SSH key is already present in authorized_keys
if grep -q "$PUB_KEY" "$USER_HOME/.ssh/authorized_keys"; then
    echo "ℹ️ SSH key already exists."
else
    echo "$PUB_KEY" >> "$USER_HOME/.ssh/authorized_keys"
    echo "✅ SSH key added."
fi

# Set correct ownership and permissions
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
echo "✅ SSH key configured for '$USERNAME'."

# ✅ Add the user to the admin group for sudo privileges
usermod -aG "$ADMIN_GROUP" "$USERNAME"
echo "✅ '$USERNAME' added to '$ADMIN_GROUP' group."

# ✅ Ask for confirmation before granting passwordless sudo privileges
read -rp "👉 Do you want to grant passwordless sudo privileges to the '$ADMIN_GROUP' group? (y/n): " CONFIRM_SUDO
if [[ "$CONFIRM_SUDO" =~ ^[Yy]$ ]]; then
    # ✅ Grant passwordless sudo to the admin group (one-time setup)
    SUDOERS_FILE="/etc/sudoers.d/99-${ADMIN_GROUP}-nopasswd"
    if [[ ! -f "$SUDOERS_FILE" ]]; then
        # Write sudoers rule for the admin group
        echo "%$ADMIN_GROUP ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
        chmod 440 "$SUDOERS_FILE"
        # Validate sudoers file syntax before applying
        visudo -cf "$SUDOERS_FILE" || {
            echo "❌ Syntax error in $SUDOERS_FILE. Aborting."
            exit 1
        }
        echo "✅ Passwordless sudo granted to '$ADMIN_GROUP' group."
    else
        echo "ℹ️ Passwordless sudo already configured for '$ADMIN_GROUP'."
    fi
else
    echo "ℹ️ Passwordless sudo configuration skipped."
fi

echo "🎉 Setup complete for '$USERNAME'."
