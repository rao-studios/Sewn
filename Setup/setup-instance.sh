#!/bin/bash

# Full instance setup: Nginx + SSL + Git/SSH
# Usage: sudo ./setup-instance.sh
# Tested on Ubuntu 24.04 / Debian 12

set -e

# ── Config ───────────────────────────────────────────────────────────
DOMAIN="api.seer.services"
PORT="8080"
EMAIL="rpakala@me.com"
GIT_USER="riteshpakala"
GIT_NAME="Ritesh Pakala"
GIT_EMAIL="rpakala@me.com"
SSH_KEY_FILE="/root/.ssh/id_ed25519"
# ─────────────────────────────────────────────────────────────────────

echo "══════════════════════════════════════"
echo "  Instance Setup: $DOMAIN"
echo "══════════════════════════════════════"

# ── 1. System packages ──────────────────────────────────────────────
echo ""
echo "[1/5] Installing packages..."
apt-get update
apt-get install -y nginx certbot python3-certbot-nginx git

# ── 2. Git config ───────────────────────────────────────────────────
echo ""
echo "[2/5] Configuring Git..."
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
# git config --global init.defaultBranch main

# ── 3. SSH key for GitHub ───────────────────────────────────────────
echo ""
echo "[3/5] Setting up SSH key..."

if [ -f "$SSH_KEY_FILE" ]; then
    echo "SSH key already exists at $SSH_KEY_FILE, skipping generation."
else
    ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f "$SSH_KEY_FILE" -N ""
    eval "$(ssh-agent -s)"
    ssh-add "$SSH_KEY_FILE"
fi

# Configure SSH to use this key for GitHub
mkdir -p /root/.ssh
cat > /root/.ssh/config <<EOF
Host github.com
    HostName github.com
    User git
    IdentityFile $SSH_KEY_FILE
    IdentitiesOnly yes
EOF
chmod 600 /root/.ssh/config

echo ""
echo "────────────────────────────────────────────────"
echo "  PUBLIC KEY — add this to GitHub ($GIT_USER):"
echo "  https://github.com/settings/ssh/new"
echo "────────────────────────────────────────────────"
cat "${SSH_KEY_FILE}.pub"
echo ""
echo "────────────────────────────────────────────────"

# ── 4. Nginx reverse proxy ──────────────────────────────────────────
echo ""
echo "[4/5] Configuring Nginx..."

cat > "/etc/nginx/sites-available/$DOMAIN" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl reload nginx

# ── 5. SSL via Let's Encrypt ────────────────────────────────────────
echo ""
echo "[5/5] Obtaining SSL certificate..."
echo ""
echo "NOTE: DNS for $DOMAIN must already point to this server's IP."
echo "      If it doesn't, certbot will fail. You can re-run just the"
echo "      SSL step later with:"
echo "        certbot --nginx -d $DOMAIN --email $EMAIL --agree-tos --no-eff-email --redirect"
echo ""

read -p "DNS is ready, proceed with SSL? [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    certbot --nginx -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --redirect
    systemctl enable certbot.timer
    systemctl start certbot.timer
    echo "✓ SSL configured with auto-renewal"
else
    echo "⏭ Skipping SSL for now."
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════"
echo "  Setup Complete"
echo "══════════════════════════════════════"
echo "  Nginx:  $DOMAIN -> localhost:$PORT"
echo "  Git:    $GIT_NAME <$GIT_EMAIL>"
echo "  SSH:    $SSH_KEY_FILE"
echo ""
echo "  Next steps:"
echo "    1. Add the public key above to github.com/settings/ssh/new"
echo "    2. Test with: ssh -T git@github.com"
echo "    3. If SSL was skipped, run the certbot command above once DNS is set"
echo ""