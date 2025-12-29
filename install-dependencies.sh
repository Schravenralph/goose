#!/bin/bash
# Script to install system dependencies for building goose

echo "Installing system dependencies for goose..."
echo "This requires sudo privileges."

# Update package list
sudo apt update

# Install required packages for building goose Desktop on Linux
sudo apt install -y \
    dpkg \
    fakeroot \
    build-essential \
    libxcb1-dev \
    libxcb-util-dev \
    protobuf-compiler

echo ""
echo "✅ System dependencies installed!"
echo ""
echo "Next steps:"
echo "1. Activate Hermit environment: source bin/activate-hermit"
echo "2. Build the Rust backend: cargo build --release -p goose-server"
echo "3. (Optional) Build Desktop app: cd ui/desktop && npm install"


