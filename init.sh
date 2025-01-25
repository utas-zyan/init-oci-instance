#!/bin/bash

# Exit on error
set -e

if [ -z "$REMOTE_HOST" ]; then
    echo "Error: REMOTE_HOST environment variable is not set"
    echo "Usage: REMOTE_HOST=user@hostname [TAILSCALE_KEY=tskey-...] $0"
    exit 1
fi

echo "Starting remote Ubuntu machine initialization on $REMOTE_HOST..."

# Function to run command on remote host
remote_exec() {
    ssh "$REMOTE_HOST" "$@"
}

# Function to start or restart Tailscale
start_tailscale() {
    if [ -n "$TAILSCALE_KEY" ]; then
        echo "Starting Tailscale with auth key and exit node configuration..."
        remote_exec "sudo tailscale up --advertise-exit-node --reset --authkey $TAILSCALE_KEY"
    else
        echo "Starting Tailscale (interactive mode)..."
        remote_exec "sudo tailscale up"
    fi
}

# 1. Install and configure tmux
echo "Checking tmux installation..."
if ! remote_exec "command -v tmux &> /dev/null"; then
    echo "Installing tmux..."
    remote_exec "sudo apt-get update && sudo apt-get install -y tmux"
else
    echo "tmux is already installed, skipping..."
fi

# Copy tmux configuration from local machine
echo "Copying tmux configuration..."
scp ~/.tmux.conf "$REMOTE_HOST":~/.tmux.conf

# 2. Install Docker
echo "Checking Docker installation..."
if ! remote_exec "command -v docker &> /dev/null && docker ps &> /dev/null"; then
    echo "Installing Docker..."
    remote_exec "sudo apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release"

    # Add Docker's official GPG key
    remote_exec 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg'

    # Set up Docker repository
    remote_exec 'echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null'

    # Install Docker Engine
    remote_exec "sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io"

    # Add user to docker group
    echo "Adding user to docker group..."
    remote_exec "sudo usermod -aG docker \$USER"
else
    echo "Docker is already installed, skipping..."
    # Check if user is in docker group
    if ! remote_exec "groups \$USER | grep -q docker"; then
        echo "Adding user to docker group..."
        remote_exec "sudo usermod -aG docker \$USER"
    fi
fi

# 3. Install and configure Tailscale
echo "Checking Tailscale installation..."
if ! remote_exec "command -v tailscale &> /dev/null"; then
    echo "Configuring network settings for Tailscale..."
    # Enable IP forwarding
    remote_exec "echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf"
    remote_exec "echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.conf"
    remote_exec "sudo sysctl -p /etc/sysctl.conf"

    # Remove UFW if present and configure iptables
    echo "Configuring firewall settings..."
    remote_exec "sudo apt-get purge -y ufw"
    remote_exec "sudo iptables -P INPUT ACCEPT"
    remote_exec "sudo iptables -P OUTPUT ACCEPT"
    remote_exec "sudo iptables -P FORWARD ACCEPT"
    remote_exec "sudo iptables -F"

    echo "Installing Tailscale..."
    remote_exec 'curl -fsSL https://tailscale.com/install.sh | sudo sh'

    # Start Tailscale
    start_tailscale
else
    echo "Tailscale is already installed, checking network configuration..."
    # Even if Tailscale is installed, ensure network settings are correct
    remote_exec "grep -q 'net.ipv4.ip_forward = 1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf"
    remote_exec "grep -q 'net.ipv6.conf.all.forwarding = 1' /etc/sysctl.conf || echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.conf"
    remote_exec "sudo sysctl -p /etc/sysctl.conf"

    # Check if UFW is present and remove it
    remote_exec "dpkg -l | grep -q '^ii.*ufw' && sudo apt-get purge -y ufw || true"
    
    # Configure iptables
    remote_exec "sudo iptables -P INPUT ACCEPT"
    remote_exec "sudo iptables -P OUTPUT ACCEPT"
    remote_exec "sudo iptables -P FORWARD ACCEPT"
    remote_exec "sudo iptables -F"

    # Check if Tailscale is running or if we have a key to force restart
    if ! remote_exec "sudo tailscale status &> /dev/null" || [ -n "$TAILSCALE_KEY" ]; then
        start_tailscale
    fi
fi

echo "Remote initialization complete!"
echo "Please log out and log back in to the remote machine for docker group changes to take effect."
