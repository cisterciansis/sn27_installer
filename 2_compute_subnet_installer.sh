#!/bin/bash
set -u
set -o history -o histexpand

# 2_compute_subnet_installer.sh
# This script installs the NI Compute Subnet components (Compute-Subnet, Python, PM2, etc.),
# configures your miner, and launches it via PM2.
# It requires that CUDA is installed. If CUDA is not found, please run 1_cuda_installer.sh first and reboot.
# This version adds extra checks for repository location, virtual environment consistency, and file permissions.

abort() {
  echo "Error: $1" >&2
  exit 1
}

ohai() {
  echo "==> $*"
}

# Prepend CUDA Toolkit bin directory to PATH (helps when running with sudo)
if ! command -v nvcc >/dev/null 2>&1; then
  export PATH="/usr/local/cuda-12.8/bin:$PATH"
fi

# Now check for CUDA (nvcc)
if ! command -v nvcc >/dev/null 2>&1; then
  abort "CUDA does not appear to be installed. Please run 1_cuda_installer.sh first and reboot."
fi

# Set user and home variables
USER_NAME=${SUDO_USER:-$(whoami)}
HOME_DIR=$(eval echo "~${USER_NAME}")
BASHRC="${HOME_DIR}/.bashrc"
DEFAULT_WALLET_DIR="${HOME_DIR}/.bittensor/wallets"
CS_PATH="${HOME_DIR}/Compute-Subnet"
VENV_DIR="${HOME_DIR}/venv"

cat << "EOF"

   NI Compute Subnet 27 Installer - Compute Subnet Setup

EOF

##############################################
# Check Active Virtual Environment
##############################################
if [ -n "${VIRTUAL_ENV:-}" ] && [ "$VIRTUAL_ENV" != "$VENV_DIR" ]; then
  ohai "Warning: Your active virtual environment ($VIRTUAL_ENV) does not match the expected one ($VENV_DIR)."
fi

##############################################
# Install Python, pip, and create virtual environment
##############################################
ohai "Installing Python3, pip, and virtual environment..."
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv || abort "Failed to install Python or venv."

ohai "Upgrading system pip..."
sudo -H python3 -m pip install --upgrade pip || abort "Failed to upgrade pip."

if [ -d "$VENV_DIR" ]; then
  ohai "Virtual environment already exists at ${VENV_DIR}; skipping creation."
else
  ohai "Creating virtual environment in ${VENV_DIR} ..."
  sudo -u "$USER_NAME" -H python3 -m venv "${VENV_DIR}" || abort "Failed to create virtual environment."
fi

ohai "Upgrading pip in the virtual environment..."
sudo -u "$USER_NAME" -H "${VENV_DIR}/bin/pip" install --upgrade pip || abort "Failed to upgrade pip in virtual environment."

##############################################
# Clone and install Compute-Subnet repository
##############################################
ohai "Cloning or updating Compute-Subnet repository..."
# If the directory exists, ensure it is owned by the correct user.
if [ -d "$CS_PATH" ]; then
  sudo chown -R "$USER_NAME:$USER_NAME" "$CS_PATH"
fi

if [ ! -d "$CS_PATH" ]; then
  ohai "Repository not found; cloning Compute-Subnet..."
  sudo -u "$USER_NAME" git clone https://github.com/neuralinternet/Compute-Subnet.git "$CS_PATH" || abort "Git clone failed."
elif [ ! -d "${CS_PATH}/.git" ]; then
  ohai "Directory ${CS_PATH} exists but is not a valid git repository. Removing and cloning..."
  sudo rm -rf "$CS_PATH" || abort "Failed to remove invalid directory"
  sudo -u "$USER_NAME" git clone https://github.com/neuralinternet/Compute-Subnet.git "$CS_PATH" || abort "Git clone failed."
else
  ohai "Repository already exists; updating Compute-Subnet..."
  # Mark repository as safe to avoid dubious ownership warnings
  sudo -u "$USER_NAME" git -C "$CS_PATH" config --global --add safe.directory "$CS_PATH" 2>/dev/null
  sudo -u "$USER_NAME" git -C "$CS_PATH" pull --ff-only || abort "Git pull failed."
fi

# Check that the miner script exists
if [ ! -f "$CS_PATH/neurons/miner.py" ]; then
  abort "miner.py not found in ${CS_PATH}/neurons. Please check the repository."
fi

# Ensure that miner.py is executable
if [ ! -x "$CS_PATH/neurons/miner.py" ]; then
  ohai "miner.py is not executable; setting executable permission..."
  sudo -u "$USER_NAME" chmod +x "$CS_PATH/neurons/miner.py" || abort "Failed to set executable permission on miner.py."
fi

ohai "Installing Compute-Subnet dependencies..."
cd "$CS_PATH" || abort "Cannot change directory to Compute-Subnet."
sudo -u "$USER_NAME" -H "${VENV_DIR}/bin/pip" install -r requirements.txt || abort "Failed to install base requirements."
sudo -u "$USER_NAME" -H "${VENV_DIR}/bin/pip" install --no-deps -r requirements-compute.txt || abort "Failed to install compute requirements."
sudo -u "$USER_NAME" -H "${VENV_DIR}/bin/pip" install -e . || abort "Editable install of Compute-Subnet failed."

ohai "Installing extra OpenCL libraries..."
sudo apt-get install -y ocl-icd-libopencl1 pocl-opencl-icd || abort "Failed to install OpenCL libraries."

##############################################
# Install PM2 (NodeJS process manager)
##############################################
ohai "Installing npm and PM2..."
sudo apt-get update
sudo apt-get install -y npm || abort "Failed to install npm."
sudo npm install -g pm2 || abort "Failed to install PM2."

##############################################
# Configuration: Ask user for miner setup parameters
##############################################
echo
echo "Please configure your miner setup."
echo "-------------------------------------"

# Network selection: Netuid is either 27 (Main) or 15 (Test)
echo "Select the Bittensor network:"
echo "  1) Main Network (netuid 27)"
echo "  2) Test Network (netuid 15)"
read -rp "Enter your choice [1 or 2]: " network_choice
if [[ "$network_choice" == "1" ]]; then
  NETUID=27
  SUBTENSOR_NETWORK_DEFAULT="subvortex.info:9944"
elif [[ "$network_choice" == "2" ]]; then
  NETUID=15
  SUBTENSOR_NETWORK_DEFAULT="test"
else
  echo "Invalid choice. Defaulting to Main Network."
  NETUID=27
  SUBTENSOR_NETWORK_DEFAULT="subvortex.info:9944"
fi

read -rp "Enter the --subtensor.network value (default: ${SUBTENSOR_NETWORK_DEFAULT}): " SUBTENSOR_NETWORK
SUBTENSOR_NETWORK=${SUBTENSOR_NETWORK:-$SUBTENSOR_NETWORK_DEFAULT}

# Ask for axon port
read -rp "Enter the axon port (default: 8091): " axon_port
axon_port=${axon_port:-8091}

echo
ohai "Detecting available wallets in ${DEFAULT_WALLET_DIR}..."
if [ ! -d "${DEFAULT_WALLET_DIR}" ]; then
  echo "Wallet directory ${DEFAULT_WALLET_DIR} does not exist."
  echo "It appears that you have not created any wallets yet."
  echo "Before proceeding, please activate your virtual environment:"
  echo "  source ${VENV_DIR}/bin/activate"
  echo "Then create your wallets using the following commands:"
  echo "  btcli new_coldkey"
  echo "  btcli new_hotkey"
  exit 1
else
  wallet_files=("${DEFAULT_WALLET_DIR}"/*)
  if [ ${#wallet_files[@]} -eq 0 ]; then
    echo "No wallets found in ${DEFAULT_WALLET_DIR}."
    echo "Please create your wallets using 'btcli new_coldkey' and 'btcli new_hotkey' after activating your virtual environment."
    exit 1
  else
    echo "Available wallets:"
    i=1
    declare -A wallet_map
    for wallet in "${wallet_files[@]}"; do
      wallet_name=$(basename "$wallet")
      echo "  [$i] $wallet_name"
      wallet_map[$i]="$wallet_name"
      ((i++))
    done
  fi
fi

# Ask user to choose coldkey wallet
read -rp "Enter the number corresponding to your COLDKEY wallet: " coldkey_choice
COLDKEY_WALLET="${wallet_map[$coldkey_choice]}"
if [[ -z "$COLDKEY_WALLET" ]]; then
  abort "Invalid selection for coldkey wallet."
fi

# Ask user to choose hotkey wallet
read -rp "Enter the number corresponding to your HOTKEY wallet: " hotkey_choice
HOTKEY_WALLET="${wallet_map[$hotkey_choice]}"
if [[ -z "$HOTKEY_WALLET" ]]; then
  abort "Invalid selection for hotkey wallet."
fi

##############################################
# Create PM2 Miner Process Configuration
##############################################
ohai "Creating PM2 configuration file for the miner process..."
# Capture current environment variables, with a default for LD_LIBRARY_PATH if not set.
CURRENT_PATH=${PATH}
CURRENT_LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}

PM2_CONFIG_FILE="${CS_PATH}/pm2_miner_config.json"
cat > "$PM2_CONFIG_FILE" <<EOF
{
  "apps": [{
    "name": "subnet27_miner",
    "cwd": "${CS_PATH}",
    "script": "./neurons/miner.py",
    "interpreter": "${VENV_DIR}/bin/python3",
    "args": "--netuid ${NETUID} --subtensor.network ${SUBTENSOR_NETWORK} --wallet.name ${COLDKEY_WALLET} --wallet.hotkey ${HOTKEY_WALLET} --axon.port ${axon_port} --logging.debug --miner.blacklist.force_validator_permit --auto_update yes",
    "env": {
      "PATH": "/usr/local/cuda-12.8/bin:${CURRENT_PATH}",
      "LD_LIBRARY_PATH": "/usr/local/cuda-12.8/lib64:${CURRENT_LD_LIBRARY_PATH}"
    }
  }]
}
EOF

ohai "PM2 configuration file created at ${PM2_CONFIG_FILE}"

##############################################
# Start Miner Process with PM2
##############################################
ohai "Starting miner process with PM2..."
cd "$CS_PATH" || abort "Cannot change directory to Compute-Subnet."
pm2 start "$PM2_CONFIG_FILE" || abort "Failed to start PM2 process."

ohai "Miner process started."
echo "You can view logs using: pm2 logs subnet27_miner"
echo "Ensure that your chosen hotkey is registered on chain (using btcli register)."
echo "The miner process will automatically begin working once your hotkey is registered on chain."
echo
echo "Installation and setup complete. Your miner is now running in the background."
