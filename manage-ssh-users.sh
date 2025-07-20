#!/bin/bash

set -e

# ✅ Auto-detect default admin group
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
if [[ -z "$PUB_KEY" ]]; then
    echo "❌ SSH key required."
    exit 1
fi

# ✅ Create user (if not exists)
if ! id "$USERNAME" &>/dev/null; then
    useradd --create-home --shell /bin/bash "$USERNAME"
    passwd -l "$USERNAME"
    echo "✅ User '$USERNAME' created and password locked."
else
    echo "ℹ️ User '$USERNAME' already exists."
fi

# ✅ Setup SSH access
mkdir -p "/home/$USERNAME/.ssh"
echo "$PUB_KEY" > "/home/$USERNAME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
chmod 700 "/home/$USERNAME/.ssh"
chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
echo "✅ SSH key configured for '$USERNAME'."

# ✅ Add user to admin group
usermod -aG "$ADMIN_GROUP" "$USERNAME"
echo "✅ '$USERNAME' added to '$ADMIN_GROUP' group."

# ✅ Grant passwordless sudo to admin group (one-time setup)
SUDOERS_FILE="/etc/sudoers.d/99-${ADMIN_GROUP}-nopasswd"
if [[ ! -f "$SUDOERS_FILE" ]]; then
    echo "%$ADMIN_GROUP ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    visudo -cf "$SUDOERS_FILE" || {
        echo "❌ Syntax error in $SUDOERS_FILE. Aborting."
        exit 1
    }
    echo "✅ Passwordless sudo granted to '$ADMIN_GROUP' group."
else
    echo "ℹ️ Passwordless sudo already configured for '$ADMIN_GROUP'."
fi

echo "🎉 Setup complete for '$USERNAME'."
