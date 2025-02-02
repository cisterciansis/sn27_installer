#!/bin/bash
set -u
set -o history -o histexpand

# 1_cuda_installer.sh
# This script installs Docker, NVIDIA drivers, NVIDIA Docker support, and the CUDA Toolkit.
# It will automatically reboot your machine after successful installation.
# Please save your work—your system will reboot at the end.

abort() {
  echo "Error: $1" >&2
  exit 1
}

ohai() {
  echo "==> $*"
}

wait_for_user() {
  echo
  echo "Press ENTER to continue or CTRL+C to abort..."
  read -r
}

# Only support Linux
if [[ "$(uname)" != "Linux" ]]; then
  abort "This installer only supports Linux."
fi

ohai "WARNING: This script will install Docker, NVIDIA drivers, NVIDIA Docker support, and the CUDA Toolkit, then reboot your machine."
wait_for_user

##############################################
# Install prerequisites and Docker
##############################################
ohai "Updating package lists and installing prerequisites..."
sudo apt-get update || abort "Failed to update package lists."
sudo apt-get install --no-install-recommends --no-install-suggests -y apt-utils curl git cmake build-essential ca-certificates || abort "Failed to install prerequisites."

ohai "Setting up Docker repository..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || abort "Failed to download Docker GPG key."
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Load OS release information
. /etc/os-release || abort "Cannot determine OS version."
DOCKER_REPO="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable"
echo "$DOCKER_REPO" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update || abort "Failed to update package lists after adding Docker repository."
ohai "Installing Docker packages..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || abort "Docker installation failed."

# Add the current user to the docker group
USER_NAME=${SUDO_USER:-$(whoami)}
ohai "Adding user ${USER_NAME} to docker group..."
sudo usermod -aG docker "$USER_NAME" || abort "Failed to add user to docker group."

ohai "Installing 'at' package..."
sudo apt-get install -y at || abort "Failed to install 'at'."

##############################################
# Install NVIDIA Docker support
##############################################
ohai "Installing NVIDIA Docker support..."

# Add NVIDIA Docker GPG key using gpg --dearmor (avoids using the deprecated apt-key)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/nvidia-docker.gpg > /dev/null || abort "Failed to add NVIDIA Docker GPG key."

# Determine the correct NVIDIA distribution identifier.
# For Ubuntu 22.04 (codename "jammy"), use "ubuntu22.04" since that's what NVIDIA expects.
UBUNTU_CODENAME=$(lsb_release -cs)
if [[ "$UBUNTU_CODENAME" == "jammy" ]]; then
  NVIDIA_DIST="ubuntu22.04"
else
  NVIDIA_DIST="$UBUNTU_CODENAME"
fi

curl -s -L "https://nvidia.github.io/nvidia-docker/${NVIDIA_DIST}/nvidia-docker.list" | sudo tee /etc/apt/sources.list.d/nvidia-docker.list || abort "Failed to add NVIDIA Docker repository."
sudo apt-get update -y || abort "Failed to update package lists after adding NVIDIA Docker repository."
sudo apt-get install -y nvidia-container-toolkit nvidia-docker2 || abort "Failed to install NVIDIA Docker packages."
ohai "NVIDIA Docker support installed."

##############################################
# Install CUDA Toolkit and NVIDIA Drivers
##############################################
if command -v nvcc >/dev/null 2>&1; then
  ohai "CUDA is already installed; skipping CUDA installation."
else
  # For Ubuntu 22.04 (jammy) or 24.04 (lunar)
  if [[ "$VERSION_CODENAME" == "jammy" ]]; then
    ohai "Installing CUDA Toolkit 12.8 for Ubuntu 22.04..."
    sudo apt-get update
    sudo apt-get install -y build-essential dkms linux-headers-$(uname -r) || abort "Failed to install build essentials for CUDA."
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-ubuntu2204.pin -O /tmp/cuda.pin || abort "Failed to download CUDA pin."
    sudo mv /tmp/cuda.pin /etc/apt/preferences.d/cuda-repository-pin-600
    wget https://developer.download.nvidia.com/compute/cuda/12.8.0/local_installers/cuda-repo-ubuntu2204-12-8-local_12.8.0-570.86.10-1_amd64.deb -O /tmp/cuda-repo.deb || abort "Failed to download CUDA repository package."
    sudo dpkg -i /tmp/cuda-repo.deb || abort "dpkg failed for CUDA repository package."
    sudo cp /var/cuda-repo-ubuntu2204-12-8-local/cuda-*-keyring.gpg /usr/share/keyrings/ || abort "Failed to copy CUDA keyring."
    sudo apt-get update
    sudo apt-get -y install cuda-toolkit-12-8 cuda-drivers || abort "Failed to install CUDA Toolkit or drivers."
  elif [[ "$VERSION_CODENAME" == "lunar" ]]; then
    ohai "Installing CUDA Toolkit 12.8 for Ubuntu 24.04..."
    sudo apt-get update
    sudo apt-get install -y build-essential dkms linux-headers-$(uname -r) || abort "Failed to install build essentials for CUDA."
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-ubuntu2404.pin -O /tmp/cuda.pin || abort "Failed to download CUDA pin."
    sudo mv /tmp/cuda.pin /etc/apt/preferences.d/cuda-repository-pin-600
    wget https://developer.download.nvidia.com/compute/cuda/12.8.0/local_installers/cuda-repo-ubuntu2404-12-8-local_12.8.0-570.86.10-1_amd64.deb -O /tmp/cuda-repo.deb || abort "Failed to download CUDA repository package."
    sudo dpkg -i /tmp/cuda-repo.deb || abort "dpkg failed for CUDA repository package."
    sudo cp /var/cuda-repo-ubuntu2404-12-8-local/cuda-*-keyring.gpg /usr/share/keyrings/ || abort "Failed to copy CUDA keyring."
    sudo apt-get update
    sudo apt-get -y install cuda-toolkit-12-8 cuda-drivers || abort "Failed to install CUDA Toolkit or drivers."
  else
    ohai "Automatic CUDA installation is not supported for Ubuntu ${VERSION_CODENAME}. Please install CUDA manually from https://developer.nvidia.com/cuda-downloads."
    exit 1
  fi

  ohai "Configuring CUDA environment variables in ~/.bashrc..."
  echo "" | sudo tee -a "$HOME/.bashrc" > /dev/null
  echo "# CUDA configuration added by 1_cuda_installer.sh" | sudo tee -a "$HOME/.bashrc" > /dev/null
  echo "export PATH=/usr/local/cuda-12.8/bin:\$PATH" | sudo tee -a "$HOME/.bashrc" > /dev/null
  echo "export LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:\$LD_LIBRARY_PATH" | sudo tee -a "$HOME/.bashrc" > /dev/null
  ohai "CUDA Toolkit 12.8 installed successfully!"
fi

ohai "Installation of Docker, NVIDIA components, and CUDA is complete."
ohai "A reboot is required to finalize installations. Rebooting now..."
sudo reboot
