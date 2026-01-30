#!/bin/bash
# install-agent.sh
# XCP-ng VM Agent Installer with automatic dependency installation
# Version: 1.0.3

set -e

VERSION="1.0.3"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}=== XCP-ng VM Agent Installer v${VERSION} ===${NC}\n"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] This script must be run as root${NC}"
    echo "Please run: sudo $0 $@"
    exit 1
fi

# Parse arguments
SERVER_URL=""
SKIP_DEPENDENCY_INSTALL=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-deps)
            SKIP_DEPENDENCY_INSTALL=true
            shift
            ;;
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        *)
            if [ -z "$SERVER_URL" ]; then
                SERVER_URL="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$SERVER_URL" ]; then
    echo -e "${RED}[ERROR] Server URL required${NC}"
    echo "Usage: $0 <server-url> [--skip-deps] [-y|--yes]"
    echo "Example: $0 https://management.company.com"
    echo ""
    echo "Options:"
    echo "  --skip-deps    Skip automatic dependency installation"
    echo "  -y, --yes      Automatic yes to prompts"
    exit 1
fi

# Detect OS
echo -e "${CYAN}Detecting operating system...${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"
    echo -e "${GREEN}[OK]${NC} Detected: $PRETTY_NAME"
else
    echo -e "${RED}[ERROR]${NC} Cannot detect OS version (/etc/os-release not found)"
    echo "This installer supports Debian, Ubuntu, RHEL, CentOS, Fedora, Rocky, AlmaLinux, and SUSE-based distributions"
    exit 1
fi

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to prompt user
prompt_user() {
    local message="$1"
    
    if [ "$AUTO_YES" = true ]; then
        echo -e "${CYAN}$message${NC} (auto-yes enabled)"
        return 0
    fi
    
    read -p "$message (Y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# Install dependencies for Debian/Ubuntu
install_deps_debian() {
    echo -e "\n${CYAN}Installing dependencies for Debian/Ubuntu...${NC}"
    
    apt-get update || {
        echo -e "${RED}[ERROR]${NC} Failed to update package lists"
        return 1
    }
    
    local packages=(
        "python3"
        "python3-pip"
        "cloud-guest-utils"
        "parted"
        "e2fsprogs"
        "xfsprogs"
        "util-linux"
    )
    
    for package in "${packages[@]}"; do
        echo "  Installing $package..."
        apt-get install -y "$package" || {
            echo -e "${YELLOW}[WARNING]${NC} Failed to install $package"
        }
    done
    
    # Try to install xe-guest-utilities
    if apt-cache search xe-guest-utilities | grep -q xe-guest-utilities; then
        echo "  Installing xe-guest-utilities..."
        apt-get install -y xe-guest-utilities || {
            echo -e "${YELLOW}[WARNING]${NC} xe-guest-utilities installation failed"
        }
    else
        echo -e "${YELLOW}[INFO]${NC} xe-guest-utilities not available in repositories"
    fi
    
    return 0
}

# Install dependencies for RHEL/CentOS/Fedora
install_deps_rhel() {
    echo -e "\n${CYAN}Installing dependencies for RHEL/CentOS/Fedora...${NC}"
    
    local packages=(
        "python3"
        "python3-pip"
        "cloud-utils-growpart"
        "parted"
        "e2fsprogs"
        "xfsprogs"
        "util-linux"
    )
    
    for package in "${packages[@]}"; do
        echo "  Installing $package..."
        yum install -y "$package" || dnf install -y "$package" || {
            echo -e "${YELLOW}[WARNING]${NC} Failed to install $package"
        }
    done
    
    return 0
}

# Install dependencies for SUSE
install_deps_suse() {
    echo -e "\n${CYAN}Installing dependencies for SUSE/openSUSE...${NC}"
    
    local packages=(
        "python3"
        "python3-pip"
        "cloud-utils-growpart"
        "parted"
        "e2fsprogs"
        "xfsprogs"
        "util-linux"
    )
    
    for package in "${packages[@]}"; do
        echo "  Installing $package..."
        zypper install -y "$package" || {
            echo -e "${YELLOW}[WARNING]${NC} Failed to install $package"
        }
    done
    
    return 0
}

# Check prerequisites
check_prerequisites() {
    echo -e "\n${CYAN}Checking prerequisites...${NC}"
    
    local all_met=true
    local missing_required=()
    local missing_optional=()
    local can_auto_install=false
    
    # Check Python version
    if command_exists python3; then
        PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
        PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d. -f1)
        PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d. -f2)
        
        if [ "$PYTHON_MAJOR" -ge 3 ] && [ "$PYTHON_MINOR" -ge 6 ]; then
            echo -e "${GREEN}[OK]${NC} Python version: $PYTHON_VERSION"
        else
            echo -e "${RED}[ERROR]${NC} Python 3.6+ required (Current: $PYTHON_VERSION)"
            missing_required+=("python3 (version 3.6+)")
            all_met=false
        fi
    else
        echo -e "${RED}[ERROR]${NC} python3 not found"
        missing_required+=("python3")
        all_met=false
        can_auto_install=true
    fi
    
    # Check for Python pip
    if command_exists pip3; then
        echo -e "${GREEN}[OK]${NC} pip3 available"
    else
        echo -e "${RED}[ERROR]${NC} pip3 not found"
        missing_required+=("python3-pip")
        all_met=false
        can_auto_install=true
    fi
    
    # Check for required system commands
    local required_commands=(
        "growpart:cloud-utils-growpart or cloud-guest-utils"
        "parted:parted"
        "blkid:util-linux"
        "mkfs.ext4:e2fsprogs"
        "resize2fs:e2fsprogs"
        "findmnt:util-linux"
        "blockdev:util-linux"
    )
    
    for cmd_info in "${required_commands[@]}"; do
        IFS=':' read -r cmd package <<< "$cmd_info"
        if command_exists "$cmd"; then
            echo -e "${GREEN}[OK]${NC} $cmd available"
        else
            echo -e "${RED}[ERROR]${NC} $cmd not found (package: $package)"
            missing_required+=("$cmd (from $package)")
            all_met=false
            can_auto_install=true
        fi
    done
    
    # Check for optional commands
    if command_exists mkfs.xfs; then
        echo -e "${GREEN}[OK]${NC} mkfs.xfs available"
    else
        echo -e "${YELLOW}[WARNING]${NC} mkfs.xfs not found (package: xfsprogs)"
        missing_optional+=("mkfs.xfs (from xfsprogs) - required for XFS filesystem support")
    fi
    
    if command_exists xfs_growfs; then
        echo -e "${GREEN}[OK]${NC} xfs_growfs available"
    else
        echo -e "${YELLOW}[WARNING]${NC} xfs_growfs not found (package: xfsprogs)"
        missing_optional+=("xfs_growfs (from xfsprogs) - required for XFS filesystem support")
    fi
    
    if command_exists xenstore-read; then
        echo -e "${GREEN}[OK]${NC} xenstore-read available (XenServer/XCP-ng guest tools installed)"
    else
        echo -e "${YELLOW}[WARNING]${NC} xenstore-read not found (package: xe-guest-utilities)"
        missing_optional+=("xenstore-read (from xe-guest-utilities) - recommended for VM UUID detection")
    fi
    
    # Check if /sys/class/dmi/id/product_uuid exists (fallback for UUID)
    if [ -r /sys/class/dmi/id/product_uuid ]; then
        echo -e "${GREEN}[OK]${NC} DMI product UUID available (fallback UUID method)"
    else
        echo -e "${YELLOW}[WARNING]${NC} Cannot read DMI product UUID"
        if ! command_exists xenstore-read; then
            missing_optional+=("Either xe-guest-utilities or readable /sys/class/dmi/id/product_uuid required for UUID detection")
        fi
    fi
    
    # Print results and offer to install
    if [ "$all_met" = false ]; then
        echo -e "\n${RED}[FAILED] Prerequisite check failed!${NC}"
        echo -e "${RED}Missing required dependencies:${NC}"
        for dep in "${missing_required[@]}"; do
            echo -e "  ${RED}-${NC} $dep"
        done
        
        if [ ${#missing_optional[@]} -gt 0 ]; then
            echo -e "\n${YELLOW}Missing optional dependencies:${NC}"
            for dep in "${missing_optional[@]}"; do
                echo -e "  ${YELLOW}-${NC} $dep"
            done
        fi
        
        # Offer to install dependencies
        if [ "$can_auto_install" = true ] && [ "$SKIP_DEPENDENCY_INSTALL" = false ]; then
            echo -e "\n${CYAN}[INFO] This installer can attempt to install missing dependencies automatically.${NC}"
            
            if prompt_user "Install missing dependencies now?"; then
                case "$OS_ID" in
                    debian|ubuntu)
                        install_deps_debian
                        ;;
                    rhel|centos|fedora|rocky|almalinux)
                        install_deps_rhel
                        ;;
                    sles|opensuse*)
                        install_deps_suse
                        ;;
                    *)
                        echo -e "${YELLOW}[WARNING]${NC} Automatic installation not supported for $OS_ID"
                        print_installation_instructions
                        return 1
                        ;;
                esac
                
                # Re-check prerequisites after installation
                echo -e "\n${CYAN}Re-checking prerequisites after installation...${NC}"
                return check_prerequisites
            else
                print_installation_instructions
                return 1
            fi
        else
            print_installation_instructions
            return 1
        fi
    fi
    
    if [ ${#missing_optional[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Missing optional dependencies:${NC}"
        for dep in "${missing_optional[@]}"; do
            echo -e "  ${YELLOW}-${NC} $dep"
        done
        
        if [ "$SKIP_DEPENDENCY_INSTALL" = false ]; then
            echo -e "\n${YELLOW}Installation can continue, but some features may not work correctly.${NC}"
            
            if ! prompt_user "Continue with installation?"; then
                echo "Installation cancelled by user."
                exit 0
            fi
        fi
    fi
    
    echo -e "\n${GREEN}[OK]${NC} All required prerequisites met!"
    return 0
}

# Print OS-specific installation instructions
print_installation_instructions() {
    echo -e "\n${CYAN}Manual Installation Instructions:${NC}"
    
    case "$OS_ID" in
        debian|ubuntu)
            echo -e "\n${CYAN}For Debian/Ubuntu:${NC}"
            echo "  sudo apt-get update"
            echo "  sudo apt-get install -y python3 python3-pip cloud-guest-utils parted e2fsprogs xfsprogs util-linux"
            echo ""
            echo "Optional (for XenServer/XCP-ng guest tools):"
            echo "  sudo apt-get install -y xe-guest-utilities"
            ;;
        
        rhel|centos|fedora|rocky|almalinux)
            echo -e "\n${CYAN}For RHEL/CentOS/Fedora/Rocky/AlmaLinux:${NC}"
            echo "  sudo yum install -y python3 python3-pip cloud-utils-growpart parted e2fsprogs xfsprogs util-linux"
            echo "  # or use dnf instead of yum on newer systems"
            ;;
        
        sles|opensuse*)
            echo -e "\n${CYAN}For SUSE/openSUSE:${NC}"
            echo "  sudo zypper install -y python3 python3-pip cloud-utils-growpart parted e2fsprogs xfsprogs util-linux"
            ;;
        
        *)
            echo -e "\n${CYAN}For your distribution:${NC}"
            echo "  Install the packages listed above using your distribution's package manager"
            ;;
    esac
    
    echo -e "\nAfter installing dependencies, run this installer again."
}

# Install Python dependencies
install_python_dependencies() {
    echo -e "\n${CYAN}Installing Python dependencies...${NC}"
    
    # Check if requests module is already installed
    if python3 -c "import requests" 2>/dev/null; then
        echo -e "${GREEN}[OK]${NC} Python requests module already installed"
        return 0
    fi
    
    echo "Installing requests module..."
    if pip3 install requests; then
        echo -e "${GREEN}[OK]${NC} Python requests module installed"
    else
        echo -e "${RED}[ERROR]${NC} Failed to install Python requests module"
        return 1
    fi
}

# Install the agent
install_agent() {
    echo -e "\n${CYAN}Creating installation directories...${NC}"
    
    # Create directories
    mkdir -p /opt/xcp-vm-agent
    mkdir -p /etc/xcp-vm-agent
    mkdir -p /var/log/xcp-vm-agent
    
    echo -e "${GREEN}[OK]${NC} Directories created"
    
    # Copy agent script
    echo -e "\n${CYAN}Installing agent script...${NC}"
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    if [ -f "$SCRIPT_DIR/vm-agent.py" ]; then
        cp "$SCRIPT_DIR/vm-agent.py" /opt/xcp-vm-agent/
        chmod +x /opt/xcp-vm-agent/vm-agent.py
        echo -e "${GREEN}[OK]${NC} Agent script installed"
    else
        echo -e "${RED}[ERROR]${NC} vm-agent.py not found in $SCRIPT_DIR"
        echo "Ensure vm-agent.py is in the same directory as this installer"
        return 1
    fi
    
    # Create config
    echo -e "\n${CYAN}Creating configuration file...${NC}"
    
    cat > /etc/xcp-vm-agent/config.json <<EOF
{
    "server_url": "$SERVER_URL",
    "check_in_interval": 30
}
EOF
    
    echo -e "${GREEN}[OK]${NC} Configuration file created at /etc/xcp-vm-agent/config.json"
    
    # Create systemd service
    echo -e "\n${CYAN}Installing systemd service...${NC}"
    
    cat > /etc/systemd/system/xcp-vm-agent.service <<EOF
[Unit]
Description=XCP-ng VM Agent
Documentation=https://xcp-ng.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/xcp-vm-agent/vm-agent.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security hardening
PrivateTmp=true
NoNewPrivileges=false
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/xcp-vm-agent /etc/fstab /dev

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd
    systemctl daemon-reload
    
    echo -e "${GREEN}[OK]${NC} Systemd service installed"
    
    # Enable and start service
    echo -e "\n${CYAN}Enabling and starting service...${NC}"
    
    systemctl enable xcp-vm-agent
    
    if systemctl start xcp-vm-agent; then
        echo -e "${GREEN}[OK]${NC} Service start command issued"
    else
        echo -e "${RED}[ERROR]${NC} Failed to start service"
        echo "Check logs with: journalctl -u xcp-vm-agent -n 50"
        return 1
    fi
    
    # Wait and check status
    sleep 3
    
    if systemctl is-active --quiet xcp-vm-agent; then
        echo -e "${GREEN}[OK]${NC} Service is running"
    else
        echo -e "${YELLOW}[WARNING]${NC} Service may still be starting"
        echo "Check status with: systemctl status xcp-vm-agent"
    fi
    
    return 0
}

# Main installation flow
main() {
    # Check prerequisites first - offer to install if missing
    if ! check_prerequisites; then
        echo -e "\n${RED}Installation aborted due to missing prerequisites.${NC}"
        echo "Please install the required dependencies and run this installer again."
        exit 1
    fi
    
    # Install Python dependencies
    if ! install_python_dependencies; then
        echo -e "\n${RED}Installation failed: Could not install Python dependencies${NC}"
        exit 1
    fi
    
    # Install agent
    if ! install_agent; then
        echo -e "\n${RED}Installation failed${NC}"
        exit 1
    fi
    
    # Display installation summary
    echo -e "\n${GREEN}=== Installation Complete ===${NC}"
    echo "Service Name:      xcp-vm-agent"
    echo "Install Path:      /opt/xcp-vm-agent"
    echo "Config Path:       /etc/xcp-vm-agent/config.json"
    echo "Log Path:          /var/log/xcp-vm-agent"
    echo "Server URL:        $SERVER_URL"
    echo "Status:            $(systemctl is-active xcp-vm-agent)"
    
    echo -e "\n${CYAN}Management Commands:${NC}"
    echo "  View service:      systemctl status xcp-vm-agent"
    echo "  Start service:     systemctl start xcp-vm-agent"
    echo "  Stop service:      systemctl stop xcp-vm-agent"
    echo "  Restart service:   systemctl restart xcp-vm-agent"
    echo "  View logs:         journalctl -u xcp-vm-agent -f"
    echo "  Tail log file:     tail -f /var/log/xcp-vm-agent/agent.log"
    echo "  View config:       cat /etc/xcp-vm-agent/config.json"
    echo "  Uninstall:         systemctl stop xcp-vm-agent && systemctl disable xcp-vm-agent && rm -rf /opt/xcp-vm-agent /etc/xcp-vm-agent /etc/systemd/system/xcp-vm-agent.service"
    
    echo -e "\n${GREEN}The agent is now running and will check in with the management server every 30 seconds.${NC}"
    echo -e "${CYAN}Monitor the first few check-ins with: journalctl -u xcp-vm-agent -f${NC}"
    
    exit 0
}

# Run main installation
main