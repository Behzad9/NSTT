#!/bin/bash

# dnstt Server Setup Script
# Supports Fedora, Rocky, CentOS, Debian, Ubuntu

set -e

SCRIPT_VERSION="1.1.0"

# Usage text is defined before the root check so that --help and
# --version work for any user, without needing root or tools.
print_usage() {
    cat <<'EOF'
Usage: dnstt-deploy [--install --subdomain DOMAIN --mode socks|ssh [--mtu N] [--yes]]
       dnstt-deploy [--status | --update | --check-update]
       dnstt-deploy [--help | --version]

With no arguments, shows the interactive menu.

Options:
  --install                 Install/reconfigure without prompts. Requires
                            --subdomain and --mode; --mtu defaults to 1232
                            (or the stored value, when reconfiguring).
  --subdomain DOMAIN        Nameserver subdomain, e.g. t.example.com
  --mtu N                   MTU, a number between 576 and 9000
  --mode socks|ssh         Tunnel mode (also accepts 1 for socks, 2 for ssh)
  --yes                     Confirm prompts in scripted use, including
                            removing a conflicting dnstt service
  --status                  Show service status and configuration, then exit
  --update                  Update this script from SCRIPT_URL, then exit
  --check-update            Only check whether a newer script is available
  --help, -h                Show this help
  --version                 Show the script version
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then print_usage; exit 0; fi
if [ "${1:-}" = "--version" ]; then echo "dnstt-deploy $SCRIPT_VERSION"; exit 0; fi

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m This script must be run as root"
    exit 1
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
DNSTT_BASE_URL="https://dnstt.network"
# NOTE: https://github.com/Behzad9/NSTT is only the repo page (HTML).
# The script itself must be downloaded from the raw URL below, and the
# file must first be pushed to this repo as dnstt-deploy.sh on main.
# Until then the raw URL returns 404 and the self-update must refuse it.
SCRIPT_URL="https://raw.githubusercontent.com/Behzad9/NSTT/main/dnstt-deploy.sh"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/dnstt"
SYSTEMD_DIR="/etc/systemd/system"
DNSTT_PORT="5300"
DNSTT_USER="dnstt"
CONFIG_FILE="${CONFIG_DIR}/dnstt-server.conf"
SCRIPT_INSTALL_PATH="/usr/local/bin/dnstt-deploy"
# Dante service/config differ by distro; set by set_dante_names() in detect_os()
# (Debian/Ubuntu: danted + /etc/danted.conf, RHEL/Fedora: sockd + /etc/sockd.conf)
DANTE_SERVICE="danted"
DANTE_CONF="/etc/danted.conf"

# Global variable to track if update is available
UPDATE_AVAILABLE=false

# How this script was invoked, resolved to a real path.
# $0 alone is not reliable: it is the full path when run via PATH or by
# absolute path, but it is "dnstt-deploy" for `bash dnstt-deploy` and
# "./dnstt-deploy" for `./dnstt-deploy` (verified: the first two resolve
# to the installed path, the last two do not). An exact $0 comparison
# therefore misdetects an installed script as a fresh download: main()
# would reinstall from GitHub and skip the menu, and check_for_updates()
# would silently skip the update check. Resolve once, here.
resolve_invoked_path() {
    local p="$1" resolved=""
    if [[ "$p" == */* ]]; then
        resolved="$(readlink -f -- "$p" 2>/dev/null || true)"
        if [ -n "$resolved" ]; then printf '%s\n' "$resolved"; else printf '%s\n' "$p"; fi
    else
        resolved="$(command -v -- "$p" 2>/dev/null || true)"
        if [ -n "$resolved" ]; then printf '%s\n' "$resolved"; else printf '%s\n' "$p"; fi
    fi
}
SCRIPT_SELF="$(resolve_invoked_path "$0")"

# True when this process is the installed script, however it was invoked.
is_installed_invocation() {
    local installed=""
    installed="$(readlink -f -- "$SCRIPT_INSTALL_PATH" 2>/dev/null || true)"
    [ -n "$installed" ] || installed="$SCRIPT_INSTALL_PATH"
    [ "$SCRIPT_SELF" = "$installed" ]
}

# Function to install/update the script itself
install_script() {
    # Defensive check: main() now runs check_required_tools() first,
    # but never let a missing curl/sha256sum produce a cryptic error.
    if ! command -v curl >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
        print_error "curl and sha256sum are required to install/update the script"
        return 1
    fi

    print_status "Installing/updating dnstt-deploy script..."

    # Download the latest version into a unique temp file, never a
    # fixed /tmp name that another run or user could pre-create.
    local temp_script
    temp_script="$(mktemp /tmp/dnstt-deploy-new.XXXXXX)"
    if ! curl -fsSL "$SCRIPT_URL" -o "$temp_script"; then
        print_error "Failed to download latest version from $SCRIPT_URL"
        rm -f "$temp_script"
        return 1
    fi

    # Refuse HTML / 404 pages and empty downloads: never overwrite the
    # installed script with something that is not this bash script.
    if [ ! -s "$temp_script" ] || ! head -n 1 "$temp_script" | grep -q '^#!/bin/bash'; then
        print_error "Downloaded file is not a valid dnstt-deploy script, refusing to install it"
        rm -f "$temp_script"
        return 1
    fi

    # Make it executable
    chmod +x "$temp_script"

    # Check if we're updating an existing installation
    if [ -f "$SCRIPT_INSTALL_PATH" ]; then
        # Compare checksums to see if update is needed
        local current_checksum
        local new_checksum
        current_checksum=$(sha256sum "$SCRIPT_INSTALL_PATH" | cut -d' ' -f1)
        new_checksum=$(sha256sum "$temp_script" | cut -d' ' -f1)

        if [ "$current_checksum" = "$new_checksum" ]; then
            print_status "Script is already up to date"
            rm "$temp_script"
            return 0
        else
            print_status "Updating existing script installation..."
        fi
    else
        print_status "Installing script for the first time..."
    fi

    # Copy to installation directory
    cp "$temp_script" "$SCRIPT_INSTALL_PATH"
    rm "$temp_script"

    print_status "Script installed to $SCRIPT_INSTALL_PATH"
    print_status "You can now run 'dnstt-deploy' from anywhere"
}

# Function to handle manual update
update_script() {
    print_status "Checking for script updates..."

    local temp_script
    temp_script="$(mktemp /tmp/dnstt-deploy-latest.XXXXXX)"
    if ! curl -fsSL "$SCRIPT_URL" -o "$temp_script"; then
        print_error "Failed to download latest version"
        rm -f "$temp_script"
        return 1
    fi

    if [ ! -s "$temp_script" ] || ! head -n 1 "$temp_script" | grep -q '^#!/bin/bash'; then
        print_error "Downloaded file is not a valid dnstt-deploy script, refusing to update"
        rm -f "$temp_script"
        return 1
    fi

    local current_checksum
    local latest_checksum
    current_checksum=$(sha256sum "$SCRIPT_INSTALL_PATH" | cut -d' ' -f1)
    latest_checksum=$(sha256sum "$temp_script" | cut -d' ' -f1)

    if [ "$current_checksum" = "$latest_checksum" ]; then
        print_status "You are already running the latest version"
        rm "$temp_script"
        return 0
    fi

    print_status "New version available! Updating..."
    chmod +x "$temp_script"
    cp "$temp_script" "$SCRIPT_INSTALL_PATH"
    rm "$temp_script"
    print_status "Script updated successfully!"
    print_status "Restarting with new version..."

    # Restart the script with the new version immediately
    exec "$SCRIPT_INSTALL_PATH"
}

# Function to show main menu
show_menu() {
    echo ""
    print_status "dnstt Server Management"
    print_status "======================="

    # Show update notification if available
    if [ "$UPDATE_AVAILABLE" = true ]; then
        echo -e "${YELLOW}[UPDATE AVAILABLE]${NC} A new version of this script is available!"
        echo -e "${YELLOW}                  ${NC} Use option 2 to update to the latest version."
        echo ""
    fi

    echo "1) Install/Reconfigure dnstt server"
    echo "2) Update dnstt-deploy script"
    echo "3) Check service status"
    echo "4) View service logs"
    echo "5) Show configuration info"
    echo "6) Uninstall dnstt server"
    echo "0) Exit"
    echo ""
    print_question "Please select an option (0-6): "
}

# Function to handle menu selection
handle_menu() {
    while true; do
        show_menu
        read -r choice

        case $choice in
            1)
                print_status "Starting dnstt server installation/reconfiguration..."
                return 0  # Continue with main installation
                ;;
            2)
                update_script
                ;;
            3)
                if systemctl is-active --quiet dnstt-server; then
                    print_status "dnstt-server service is running"
                else
                    print_warning "dnstt-server service is not running"
                fi
                # systemctl status exits 3 when inactive / 4 when the unit
                # is missing; never let that exit the menu under set -e.
                systemctl status dnstt-server --no-pager -l || true
                ;;
            4)
                print_status "Showing dnstt-server logs (Press Ctrl+C to exit)..."
                # Ctrl+C makes journalctl exit 130; do not exit the menu.
                journalctl -u dnstt-server -f || true
                ;;
            5)
                show_configuration_info
                ;;
            6)
                uninstall_dnstt
                ;;
            0)
                print_status "Goodbye!"
                exit 0
                ;;
            *)
                print_error "Invalid choice. Please enter 0-6."
                ;;
        esac

        if [ "$choice" != "4" ]; then
            echo ""
            print_question "Press Enter to continue..."
            read -r
        fi
    done
}

# Function to show configuration information
show_configuration_info() {
    print_status "Current Configuration Information"
    print_status "================================"

    # Check if configuration file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        print_warning "No configuration found. Please install/configure dnstt server first."
        return 1
    fi

    # Load existing configuration
    if ! load_existing_config; then
        print_error "Failed to load configuration from $CONFIG_FILE"
        return 1
    fi

    # Check if service is running
    local service_status
    if systemctl is-active --quiet dnstt-server; then
        service_status="${GREEN}Running${NC}"
    else
        service_status="${RED}Stopped${NC}"
    fi

    echo ""
    echo -e "${BLUE}Configuration Details:${NC}"
    echo -e "  Nameserver subdomain: ${YELLOW}$NS_SUBDOMAIN${NC}"
    echo -e "  MTU: ${YELLOW}$MTU_VALUE${NC}"
    echo -e "  Tunnel mode: ${YELLOW}$TUNNEL_MODE${NC}"
    echo -e "  Service user: ${YELLOW}$DNSTT_USER${NC}"
    echo -e "  Listen port: ${YELLOW}$DNSTT_PORT${NC} (DNS traffic redirected from port 53)"
    echo -e "  Service status: $service_status"
    echo ""

    # Show public key if it exists
    if [ -f "$PUBLIC_KEY_FILE" ]; then
        echo -e "${BLUE}Public Key Content:${NC}"
        echo -e "${YELLOW}$(cat "$PUBLIC_KEY_FILE")${NC}"
        echo ""
    else
        print_warning "Public key file not found: $PUBLIC_KEY_FILE"
    fi

    echo -e "${BLUE}Management Commands:${NC}"
    echo -e "  Run menu:           ${YELLOW}dnstt-deploy${NC}"
    echo -e "  Start service:      ${YELLOW}systemctl start dnstt-server${NC}"
    echo -e "  Stop service:       ${YELLOW}systemctl stop dnstt-server${NC}"
    echo -e "  Service status:     ${YELLOW}systemctl status dnstt-server${NC}"
    echo -e "  View logs:          ${YELLOW}journalctl -u dnstt-server -f${NC}"

    # Show SOCKS info if applicable
    if [ "$TUNNEL_MODE" = "socks" ]; then
        echo ""
        echo -e "${BLUE}SOCKS Proxy Information:${NC}"
        echo -e "SOCKS proxy is running on ${YELLOW}127.0.0.1:1080${NC}"
        echo -e "${BLUE}Dante service commands:${NC}"
        echo -e "  Status:  ${YELLOW}systemctl status ${DANTE_SERVICE:-danted}${NC}"
        echo -e "  Stop:    ${YELLOW}systemctl stop ${DANTE_SERVICE:-danted}${NC}"
        echo -e "  Start:   ${YELLOW}systemctl start ${DANTE_SERVICE:-danted}${NC}"
        echo -e "  Logs:    ${YELLOW}journalctl -u ${DANTE_SERVICE:-danted} -f${NC}"
    fi

    echo ""
}
check_for_updates() {
    # Only check for updates if we're running from the installed location.
    # Compare resolved paths, not $0: `bash dnstt-deploy` and
    # `./dnstt-deploy` leave $0 as a bare or relative name.
    if is_installed_invocation; then
        print_status "Checking for script updates..."

        local temp_script
        temp_script="$(mktemp /tmp/dnstt-deploy-latest.XXXXXX)"
        if curl -fsSL "$SCRIPT_URL" -o "$temp_script" 2>/dev/null && [ -s "$temp_script" ] && head -n 1 "$temp_script" | grep -q '^#!/bin/bash'; then
            local current_checksum
            local latest_checksum
            current_checksum=$(sha256sum "$SCRIPT_INSTALL_PATH" | cut -d' ' -f1)
            latest_checksum=$(sha256sum "$temp_script" | cut -d' ' -f1)

            if [ "$current_checksum" != "$latest_checksum" ]; then
                UPDATE_AVAILABLE=true
                print_warning "New version available! Use menu option 2 to update."
            else
                print_status "Script is up to date"
            fi
            rm "$temp_script"
        else
            print_warning "Could not check for updates (network issue)"
        fi
    fi
}

# --- Input validation and safe config handling ---
# A nameserver subdomain must be a valid DNS name: labels of letters,
# digits and hyphens, separated by dots, no slash, space or shell
# metacharacters, so it cannot escape CONFIG_DIR or break ExecStart.
is_valid_subdomain() {
    local value="$1"
    [ "${#value}" -le 253 ] || return 1
    [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

# dnstt MTU: numeric, in a sane range for a DNS tunnel.
is_valid_mtu() {
    local value="$1" n
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    n=$((10#$value))
    [ "$n" -ge 576 ] && [ "$n" -le 9000 ]
}

# A key file must live directly under CONFIG_DIR and contain no "..".
is_valid_key_file() {
    local value="$1"
    case "$value" in
        "$CONFIG_DIR"/*)
            [[ "$value" != *".."* ]]
            ;;
        *) return 1 ;;
    esac
}

# Escape a value for writing inside double quotes in the config file.
escape_config_value() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//\$/\\\$}"
    v="${v//\`/\\\`}"
    printf '%s' "$v"
}

# Dante service/config names differ by distro.
set_dante_names() {
    case "$PKG_MANAGER" in
        dnf|yum)
            DANTE_SERVICE="sockd"
            DANTE_CONF="/etc/sockd.conf"
            ;;
        *)
            DANTE_SERVICE="danted"
            DANTE_CONF="/etc/danted.conf"
            ;;
    esac
}

# Function to load existing configuration
load_existing_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi
    print_status "Loading existing configuration..."
    # Never source the config file: it is data, not code. Parse only
    # KEY="value" lines for the five known keys, so a crafted value
    # cannot execute as root and cannot override DNSTT_USER, DNSTT_PORT,
    # SCRIPT_URL or any other global.
    local line key raw_value value
    NS_SUBDOMAIN=""
    MTU_VALUE=""
    TUNNEL_MODE=""
    PRIVATE_KEY_FILE=""
    PUBLIC_KEY_FILE=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            *=*) ;;
            *) print_warning "Ignoring malformed config line: $line"; continue ;;
        esac
        key="${line%%=*}"
        raw_value="${line#*=}"
        key="$(printf '%s' "$key" | tr -d '[:space:]')"
        value="$raw_value"
        if [ "${#value}" -ge 2 ] && [ "${value:0:1}" = '"' ] && [ "${value: -1}" = '"' ]; then
            value="${value:1:${#value}-2}"
        fi
        case "$key" in
            NS_SUBDOMAIN|MTU_VALUE|TUNNEL_MODE|PRIVATE_KEY_FILE|PUBLIC_KEY_FILE)
                printf -v "$key" '%s' "$value"
                ;;
            *)
                print_warning "Ignoring unknown key in config: $key"
                ;;
        esac
    done < "$CONFIG_FILE"
    # Validate what was loaded; drop invalid fields so the user is
    # prompted again instead of silently using a broken value.
    if [ -n "$NS_SUBDOMAIN" ] && ! is_valid_subdomain "$NS_SUBDOMAIN"; then
        print_warning "Ignoring invalid subdomain in config: $NS_SUBDOMAIN"
        NS_SUBDOMAIN=""
    fi
    if [ -n "$MTU_VALUE" ] && ! is_valid_mtu "$MTU_VALUE"; then
        print_warning "Ignoring invalid MTU in config: $MTU_VALUE"
        MTU_VALUE=""
    fi
    if [ -n "$TUNNEL_MODE" ] && [ "$TUNNEL_MODE" != "socks" ] && [ "$TUNNEL_MODE" != "ssh" ]; then
        print_warning "Ignoring invalid tunnel mode in config: $TUNNEL_MODE"
        TUNNEL_MODE=""
    fi
    if [ -n "$PRIVATE_KEY_FILE" ] && ! is_valid_key_file "$PRIVATE_KEY_FILE"; then
        print_warning "Ignoring key file outside config dir: $PRIVATE_KEY_FILE"
        PRIVATE_KEY_FILE=""
    fi
    if [ -n "$PUBLIC_KEY_FILE" ] && ! is_valid_key_file "$PUBLIC_KEY_FILE"; then
        print_warning "Ignoring key file outside config dir: $PUBLIC_KEY_FILE"
        PUBLIC_KEY_FILE=""
    fi
    return 0
}

# Function to save configuration
save_config() {
    print_status "Saving configuration..."

    cat > "$CONFIG_FILE" << EOF
# dnstt Server Configuration
# Generated on $(date)

NS_SUBDOMAIN="$(escape_config_value "$NS_SUBDOMAIN")"
MTU_VALUE="$(escape_config_value "$MTU_VALUE")"
TUNNEL_MODE="$(escape_config_value "$TUNNEL_MODE")"
PRIVATE_KEY_FILE="$(escape_config_value "$PRIVATE_KEY_FILE")"
PUBLIC_KEY_FILE="$(escape_config_value "$PUBLIC_KEY_FILE")"
EOF

    chmod 640 "$CONFIG_FILE"
    chown root:"$DNSTT_USER" "$CONFIG_FILE"
    print_status "Configuration saved to $CONFIG_FILE"
}

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_question() {
    echo -ne "${BLUE}[QUESTION]${NC} $1"
}

# Function to print success box without [INFO] prefix
print_success_box() {
    local border_color='\033[1;32m'  # Bright green
    local text_color='\033[1;37m'    # Bright white text
    local key_color='\033[1;33m'     # Yellow for key
    local header_color='\033[1;36m'  # Cyan for headers
    local reset='\033[0m'

    echo ""
    # Top border
    echo -e "${border_color}+================================================================================${reset}"
    echo -e "${border_color}|                          SETUP COMPLETED SUCCESSFULLY!                       |${reset}"
    echo -e "${border_color}+================================================================================${reset}"
    echo ""

    # Configuration Details
    echo -e "${header_color}Configuration Details:${reset}"
    echo -e "  ${text_color}Nameserver subdomain: $NS_SUBDOMAIN${reset}"
    echo -e "  ${text_color}MTU: $MTU_VALUE${reset}"
    echo -e "  ${text_color}Tunnel mode: $TUNNEL_MODE${reset}"
    echo -e "  ${text_color}Service user: $DNSTT_USER${reset}"
    echo -e "  ${text_color}Listen port: $DNSTT_PORT (DNS traffic redirected from port 53)${reset}"
    echo ""

    # Public Key
    echo -e "${header_color}Public Key Content:${reset}"
    local pub_key_content
    pub_key_content=$(cat "$PUBLIC_KEY_FILE")
    echo -e "${key_color}$pub_key_content${reset}"
    echo ""

    # Script Location
    echo -e "${text_color}Script installed at: $SCRIPT_INSTALL_PATH${reset}"
    echo ""

    # Management Commands
    echo -e "${header_color}Management Commands:${reset}"
    echo -e "  ${text_color}Run menu:           dnstt-deploy${reset}"
    echo -e "  ${text_color}Start service:      systemctl start dnstt-server${reset}"
    echo -e "  ${text_color}Stop service:       systemctl stop dnstt-server${reset}"
    echo -e "  ${text_color}Service status:     systemctl status dnstt-server${reset}"
    echo -e "  ${text_color}View logs:          journalctl -u dnstt-server -f${reset}"

    # SOCKS info if applicable
    if [ "$TUNNEL_MODE" = "socks" ]; then
        echo ""
        echo -e "${header_color}SOCKS Proxy Information:${reset}"
        echo -e "${text_color}SOCKS proxy is running on 127.0.0.1:1080${reset}"
        echo -e "${text_color}Dante service commands:${reset}"
        echo -e "  ${text_color}Status:  systemctl status ${DANTE_SERVICE:-danted}${reset}"
        echo -e "  ${text_color}Stop:    systemctl stop ${DANTE_SERVICE:-danted}${reset}"
        echo -e "  ${text_color}Start:   systemctl start ${DANTE_SERVICE:-danted}${reset}"
        echo -e "  ${text_color}Logs:    journalctl -u ${DANTE_SERVICE:-danted} -f${reset}"
    fi

    # Bottom border
    echo ""
    echo -e "${border_color}+================================================================================${reset}"
    echo ""
}

# Function to print info lines without [INFO] prefix for final display
print_info_line() {
    local text_color='\033[1;37m'    # Bright white
    local reset='\033[0m'
    echo -e "${text_color}$1${reset}"
}

# Function to print section headers in final display
print_section_header() {
    local header_color='\033[1;36m'  # Bright cyan
    local reset='\033[0m'
    echo -e "${header_color}$1${reset}"
}

# Function to detect OS and package manager
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
    else
        print_error "Cannot detect OS"
        exit 1
    fi

    # Determine package manager
    if command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    elif command -v apt &> /dev/null; then
        PKG_MANAGER="apt"
    else
        print_error "Unsupported package manager"
        exit 1
    fi

    set_dante_names

    print_status "Detected OS: $OS"
    print_status "Package manager: $PKG_MANAGER"
    print_status "Dante service: $DANTE_SERVICE ($DANTE_CONF)"
}

# Function to detect architecture
detect_arch() {
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7l|armv6l)
            ARCH="arm"
            ;;
        i386|i686)
            ARCH="386"
            ;;
        *)
            print_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
    print_status "Detected architecture: $ARCH"
}

# Function to check and install required tools
check_required_tools() {
    print_status "Checking required tools..."

    # curl (script download), ip/ss (interface detection and the port
    # check) and iptables are installed on demand by install_dependencies().
    local required_tools=("curl" "ip" "ss" "iptables")
    local missing_tools=()

    # Check which tools are missing
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_status "Installing missing tools: ${missing_tools[*]}"
        install_dependencies "${missing_tools[@]}"
    else
        print_status "All required tools are available"
    fi

    # These are expected from coreutils/systemd and are not installed
    # by this script; fail with a clear message instead of failing
    # later inside a checksum or service command.
    local essential_tool
    for essential_tool in md5sum sha1sum sha256sum systemctl useradd; do
        if ! command -v "$essential_tool" &> /dev/null; then
            print_error "Required tool '$essential_tool' is not available and cannot be installed by this script"
            exit 1
        fi
    done

    # Verify iptables installation after potential installation
    verify_iptables_installation
}

# Function to verify iptables installation and capabilities
verify_iptables_installation() {
    print_status "Verifying iptables installation..."

    if ! command -v iptables &> /dev/null; then
        print_error "iptables is not available after installation attempt"
        exit 1
    fi

    # Check if ip6tables is available (should be part of iptables package)
    if command -v ip6tables &> /dev/null; then
        print_status "Both iptables and ip6tables are available"
    else
        print_warning "ip6tables not found, IPv6 rules will be skipped"
    fi

    # Check if IPv6 is supported on the system
    if [ -f /proc/net/if_inet6 ]; then
        print_status "IPv6 support detected"
    else
        print_warning "IPv6 not supported on this system"
    fi
}

# Function to install dependencies
install_dependencies() {
    local tools=("$@")
    print_status "Installing dependencies: ${tools[*]}"

    # Safety check for PKG_MANAGER
    if [[ -z "$PKG_MANAGER" ]]; then
        print_error "Package manager not detected. Make sure detect_os() is called first."
        exit 1
    fi

    case $PKG_MANAGER in
        dnf|yum)
            # For RHEL-based systems
            local packages_to_install=()

            for tool in "${tools[@]}"; do
                case $tool in
                    "iptables")
                        packages_to_install+=("iptables" "iptables-services")
                        ;;
                    "ip"|"ss")
                        packages_to_install+=("iproute")
                        ;;
                    *)
                        packages_to_install+=("$tool")
                        ;;
                esac
            done

            if ! $PKG_MANAGER install -y "${packages_to_install[@]}"; then
                print_error "Failed to install packages: ${packages_to_install[*]}"
                exit 1
            fi
            ;;
        apt)
            # For Debian-based systems
            if ! apt update; then
                print_error "Failed to update package lists"
                exit 1
            fi

            local packages_to_install=()

            for tool in "${tools[@]}"; do
                case $tool in
                    "iptables")
                        # iptables package includes both iptables and ip6tables
                        packages_to_install+=("iptables" "iptables-persistent")
                        ;;
                    "ip"|"ss")
                        packages_to_install+=("iproute2")
                        ;;
                    *)
                        packages_to_install+=("$tool")
                        ;;
                esac
            done

            if ! apt install -y "${packages_to_install[@]}"; then
                print_error "Failed to install packages: ${packages_to_install[*]}"
                exit 1
            fi
            ;;
        *)
            print_error "Unsupported package manager: $PKG_MANAGER"
            exit 1
            ;;
    esac

    print_status "Dependencies installed successfully"
}

# Function to get user input
get_user_input() {
    # CLI flags (only set by --install) must survive load_existing_config,
    # which resets NS_SUBDOMAIN/MTU_VALUE/TUNNEL_MODE from the stored file.
    local cli_domain="$NS_SUBDOMAIN" cli_mtu="$MTU_VALUE" cli_mode="$TUNNEL_MODE"

    # Load existing configuration if available
    local existing_domain=""
    local existing_mtu=""
    local existing_mode=""

    if load_existing_config; then
        existing_domain="$NS_SUBDOMAIN"
        existing_mtu="$MTU_VALUE"
        existing_mode="$TUNNEL_MODE"
        # load_existing_config already cleared an invalid mode, but
        # never trust a stored value that is not exactly socks/ssh.
        if [ -n "$existing_mode" ] && [ "$existing_mode" != "socks" ] && [ "$existing_mode" != "ssh" ]; then
            existing_mode=""
        fi
        print_status "Found existing configuration for domain: $existing_domain"
    fi

    # Non-interactive install: flags win, then the stored config, then
    # the MTU default. Prompts are skipped, and a missing or invalid
    # value is a hard error instead of a question that can never be
    # answered. Under set -e, return 1 here stops the install.
    if [ "${NONINTERACTIVE:-0}" = "1" ]; then
        [ -n "$cli_domain" ] && NS_SUBDOMAIN="$cli_domain"
        [ -n "$NS_SUBDOMAIN" ] || NS_SUBDOMAIN="$existing_domain"
        [ -n "$cli_mtu" ] && MTU_VALUE="$cli_mtu"
        [ -n "$MTU_VALUE" ] || MTU_VALUE="${existing_mtu:-1232}"
        [ -n "$cli_mode" ] && TUNNEL_MODE="$cli_mode"
        [ -n "$TUNNEL_MODE" ] || TUNNEL_MODE="$existing_mode"
        case "$TUNNEL_MODE" in
            1) TUNNEL_MODE="socks" ;;
            2) TUNNEL_MODE="ssh" ;;
        esac
        if [ -z "$NS_SUBDOMAIN" ] || ! is_valid_subdomain "$NS_SUBDOMAIN"; then
            print_error "--install needs a valid --subdomain (e.g. t.example.com)"
            return 1
        fi
        if ! is_valid_mtu "$MTU_VALUE"; then
            print_error "--install needs a valid --mtu between 576 and 9000"
            return 1
        fi
        if [ "$TUNNEL_MODE" != "socks" ] && [ "$TUNNEL_MODE" != "ssh" ]; then
            print_error "--install needs --mode socks or --mode ssh"
            return 1
        fi
        print_status "Configuration:"
        print_status "  Nameserver subdomain: $NS_SUBDOMAIN"
        print_status "  MTU: $MTU_VALUE"
        print_status "  Tunnel mode: $TUNNEL_MODE"
        return 0
    fi

    # Get nameserver subdomain
    while true; do
        if [[ -n "$existing_domain" ]]; then
            print_question "Enter the nameserver subdomain (current: $existing_domain): "
        else
            print_question "Enter the nameserver subdomain (e.g., t.example.com): "
        fi
        read -r NS_SUBDOMAIN

        # Use existing domain if user just presses enter
        if [[ -z "$NS_SUBDOMAIN" && -n "$existing_domain" ]]; then
            NS_SUBDOMAIN="$existing_domain"
        fi

        if [[ -z "$NS_SUBDOMAIN" ]]; then
            print_error "Please enter a valid subdomain"
        elif ! is_valid_subdomain "$NS_SUBDOMAIN"; then
            print_error "Invalid subdomain: use letters, digits and hyphens, e.g. t.example.com"
            NS_SUBDOMAIN=""
        else
            break
        fi
    done

    # Get MTU value (validated: numeric, 576-9000)
    while true; do
        if [[ -n "$existing_mtu" ]]; then
            print_question "Enter MTU value (current: $existing_mtu): "
        else
            print_question "Enter MTU value (default: 1232): "
        fi
        read -r MTU_VALUE

        # Use existing MTU if user just presses enter, otherwise use default
        if [[ -z "$MTU_VALUE" ]]; then
            if [[ -n "$existing_mtu" ]]; then
                MTU_VALUE="$existing_mtu"
            else
                MTU_VALUE="1232"
            fi
        fi

        if is_valid_mtu "$MTU_VALUE"; then
            break
        else
            print_error "Invalid MTU: enter a number between 576 and 9000"
            MTU_VALUE=""
        fi
    done

    # Get tunnel mode
    while true; do
        echo "Select tunnel mode:"
        echo "1) SOCKS proxy"
        echo "2) SSH mode"
        if [[ -n "$existing_mode" ]]; then
            local mode_number
            if [[ "$existing_mode" == "socks" ]]; then
                mode_number="1"
            else
                mode_number="2"
            fi
            print_question "Enter choice (current: $mode_number - $existing_mode): "
        else
            print_question "Enter choice (1 or 2): "
        fi
        read -r TUNNEL_MODE

        # Use existing mode if user just presses enter
        if [[ -z "$TUNNEL_MODE" && -n "$existing_mode" ]]; then
            TUNNEL_MODE="$existing_mode"
            break
        fi

        case $TUNNEL_MODE in
            1)
                TUNNEL_MODE="socks"
                break
                ;;
            2)
                TUNNEL_MODE="ssh"
                break
                ;;
            *)
                print_error "Invalid choice. Please enter 1 or 2"
                ;;
        esac
    done

    print_status "Configuration:"
    print_status "  Nameserver subdomain: $NS_SUBDOMAIN"
    print_status "  MTU: $MTU_VALUE"
    print_status "  Tunnel mode: $TUNNEL_MODE"
}

# Function to download and verify dnstt-server
# Expected hash for $filename in a checksum file, or empty.
# The upstream files list "<hash>  <filename>", with an optional
# leading "*" on the filename.
dnstt_expected_hash() {
    local sumfile="$1" fname="$2"
    awk -v f="$fname" '{ h = $1; n = $2; sub(/^\*/, "", n); if (n == f) { print h; exit } }' "$sumfile" 2>/dev/null
}

# Verify one file against MD5SUMS, SHA1SUMS and SHA256SUMS in $2.
# Returns 0 only if all three hashes are listed and match.
verify_dnstt_hashes() {
    local file="$1" dir="$2" fname="$3"
    local expected actual algo
    for algo in md5 sha1 sha256; do
        case "$algo" in
            md5) expected=$(dnstt_expected_hash "$dir/MD5SUMS" "$fname"); actual=$(md5sum "$file" 2>/dev/null | cut -d' ' -f1) ;;
            sha1) expected=$(dnstt_expected_hash "$dir/SHA1SUMS" "$fname"); actual=$(sha1sum "$file" 2>/dev/null | cut -d' ' -f1) ;;
            sha256) expected=$(dnstt_expected_hash "$dir/SHA256SUMS" "$fname"); actual=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1) ;;
        esac
        if [ -z "$expected" ]; then
            print_error "$algo checksum for $fname not found in checksum file"
            return 1
        fi
        if [ "$expected" != "$actual" ]; then
            print_error "$algo checksum mismatch for $file"
            return 1
        fi
    done
    return 0
}

download_dnstt_server() {
    local filename="dnstt-server-linux-${ARCH}"
    local filepath="${INSTALL_DIR}/dnstt-server"
    local tmpdir
    tmpdir="$(mktemp -d "/tmp/dnstt-download.XXXXXX")" || {
        print_error "Could not create temp directory for download"
        exit 1
    }
    # Clean up the temp dir when this function returns.
    trap 'rm -rf "$tmpdir" || true' RETURN

    # Download the checksums first, with -f so a 404 fails loudly.
    print_status "Downloading dnstt-server checksums..."
    local sumfile checksums_ok=true
    for sumfile in MD5SUMS SHA1SUMS SHA256SUMS; do
        if ! curl -fsSL -o "$tmpdir/$sumfile" "${DNSTT_BASE_URL}/$sumfile"; then
            print_warning "Could not download $sumfile"
            checksums_ok=false
            break
        fi
    done

    if [ "$checksums_ok" = false ]; then
        if [ -f "$filepath" ]; then
            print_warning "Could not verify existing dnstt-server (checksum download failed), keeping it"
            return 0
        fi
        print_error "Could not download checksums and no dnstt-server is installed"
        exit 1
    fi

    # An existing binary is never trusted on sight: verify it against
    # the freshly downloaded checksums, and re-download on any mismatch.
    if [ -f "$filepath" ]; then
        if verify_dnstt_hashes "$filepath" "$tmpdir" "$filename"; then
            print_status "Existing dnstt-server verified (MD5/SHA1/SHA256 match), keeping it"
            return 0
        else
            print_warning "Existing dnstt-server failed verification, re-downloading it"
        fi
    fi

    print_status "Downloading dnstt-server..."

    if ! curl -fsSL -o "$tmpdir/$filename" "${DNSTT_BASE_URL}/$filename"; then
        print_error "Failed to download dnstt-server"
        exit 1
    fi

    if [ ! -s "$tmpdir/$filename" ]; then
        print_error "Downloaded dnstt-server is empty"
        exit 1
    fi

    # Verify checksums before installing, never after.
    print_status "Verifying file integrity..."
    if ! verify_dnstt_hashes "$tmpdir/$filename" "$tmpdir" "$filename"; then
        print_error "Checksum verification failed, refusing to install downloaded binary"
        exit 1
    fi
    print_status "MD5/SHA1/SHA256 checksums verified"

    mkdir -p "$INSTALL_DIR"
    chmod +x "$tmpdir/$filename"
    if ! install -m 755 "$tmpdir/$filename" "$filepath"; then
        print_error "Failed to install dnstt-server to $filepath"
        exit 1
    fi

    print_status "dnstt-server installed successfully"
}

# Function to create dnstt user
create_dnstt_user() {
    print_status "Creating dnstt user..."

    if ! id "$DNSTT_USER" &>/dev/null; then
        useradd -r -s /bin/false -d /nonexistent -c "dnstt service user" "$DNSTT_USER"
        print_status "Created user: $DNSTT_USER"
    else
        print_status "User $DNSTT_USER already exists"
    fi

    # Create config directory first
    mkdir -p "$CONFIG_DIR"

    # Config dir stays root-owned (group dnstt may traverse it, 750)
    # so the service user can read its key but cannot replace it.
    # Key files themselves are chowned to the service user in generate_keys().
    chown -R root:"$DNSTT_USER" "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
}

# Function to generate keys
generate_keys() {
    # Generate key file names based on subdomain
    local key_prefix
    # shellcheck disable=SC2001
    key_prefix=$(echo "$NS_SUBDOMAIN" | sed 's/\./_/g')
    PRIVATE_KEY_FILE="${CONFIG_DIR}/${key_prefix}_server.key"
    PUBLIC_KEY_FILE="${CONFIG_DIR}/${key_prefix}_server.pub"

    # Check if keys already exist for this domain
    if [[ -f "$PRIVATE_KEY_FILE" && -f "$PUBLIC_KEY_FILE" ]]; then
        print_status "Found existing keys for domain: $NS_SUBDOMAIN"
        print_status "  Private key: $PRIVATE_KEY_FILE"
        print_status "  Public key: $PUBLIC_KEY_FILE"

        # Verify key ownership and permissions
        chown "$DNSTT_USER":"$DNSTT_USER" "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE"
        chmod 600 "$PRIVATE_KEY_FILE"
        chmod 644 "$PUBLIC_KEY_FILE"

        print_status "Using existing keys (verified ownership and permissions)"
    else
        print_status "Generating new keys for domain: $NS_SUBDOMAIN"

        # Generate keys (run as root, then change ownership).
        # Use the installed binary by full path, not a bare name from PATH.
        if [ ! -x "${INSTALL_DIR}/dnstt-server" ]; then
            print_error "dnstt-server binary not found at ${INSTALL_DIR}/dnstt-server"
            exit 1
        fi
        "${INSTALL_DIR}/dnstt-server" -gen-key -privkey-file "$PRIVATE_KEY_FILE" -pubkey-file "$PUBLIC_KEY_FILE"

        # Set proper ownership and permissions
        chown "$DNSTT_USER":"$DNSTT_USER" "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE"
        chmod 600 "$PRIVATE_KEY_FILE"
        chmod 644 "$PUBLIC_KEY_FILE"

        print_status "New keys generated:"
        print_status "  Private key: $PRIVATE_KEY_FILE"
        print_status "  Public key: $PUBLIC_KEY_FILE"
    fi

    # A reused or newly generated key pair must actually exist and
    # be non-empty, otherwise the service will only fail later.
    if [ ! -s "$PRIVATE_KEY_FILE" ] || [ ! -s "$PUBLIC_KEY_FILE" ]; then
        print_error "Key files are missing or empty: $PRIVATE_KEY_FILE / $PUBLIC_KEY_FILE"
        exit 1
    fi

    # Always display public key content
    print_status "Public key content:"
    cat "$PUBLIC_KEY_FILE"
}

# Function to configure iptables rules
configure_iptables() {
    print_status "Configuring iptables rules for DNS redirection..."

    # Verify iptables is available
    if ! command -v iptables &> /dev/null; then
        print_error "iptables command not found. Cannot configure firewall rules."
        exit 1
    fi

    # Get the primary network interface
    local interface
    interface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "$interface" ]]; then
        # Try alternative method to get interface
        interface=$(ip link show | grep -E "^[0-9]+: (eth|ens|enp)" | head -1 | cut -d':' -f2 | awk '{print $1}')
        if [[ -z "$interface" ]]; then
            if ip link show eth0 >/dev/null 2>&1; then
                interface="eth0"  # fallback
                print_warning "Could not detect network interface, using eth0 as fallback"
            else
                print_error "Could not detect network interface and eth0 does not exist"
                exit 1
            fi
        else
            print_status "Detected network interface: $interface"
        fi
    else
        print_status "Using network interface: $interface"
    fi

    # Never configure a redirect on an interface that does not exist:
    # the rule would be accepted and silently never match.
    if ! ip link show "$interface" >/dev/null 2>&1; then
        print_error "Network interface '$interface' does not exist, cannot configure iptables"
        exit 1
    fi

    # IPv4 rules (idempotent: check with -C first, so a re-run does
    # not stack duplicate rules on top of the existing ones)
    print_status "Setting up IPv4 iptables rules..."

    if iptables -C INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null; then
        print_status "IPv4 INPUT rule already exists, skipping"
    elif ! iptables -I INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT; then
        print_error "Failed to add IPv4 INPUT rule"
        exit 1
    fi

    if iptables -t nat -C PREROUTING -i "$interface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT" 2>/dev/null; then
        print_status "IPv4 NAT rule already exists, skipping"
    elif ! iptables -t nat -I PREROUTING -i "$interface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT"; then
        print_error "Failed to add IPv4 NAT rule"
        exit 1
    fi

    print_status "IPv4 iptables rules configured successfully"

    # IPv6 rules (if IPv6 and ip6tables are available)
    if command -v ip6tables &> /dev/null && [ -f /proc/net/if_inet6 ]; then
        print_status "Setting up IPv6 iptables rules..."

        if ip6tables -C INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null; then
            print_status "IPv6 INPUT rule already exists, skipping"
        elif ip6tables -I INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null; then
            print_status "IPv6 INPUT rule added successfully"
        else
            print_warning "Failed to add IPv6 INPUT rule (IPv6 might not be fully configured)"
        fi

        if ip6tables -t nat -C PREROUTING -i "$interface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT" 2>/dev/null; then
            print_status "IPv6 NAT rule already exists, skipping"
        elif ip6tables -t nat -I PREROUTING -i "$interface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT" 2>/dev/null; then
            print_status "IPv6 NAT rule added successfully"
        else
            print_warning "Failed to add IPv6 NAT rule (IPv6 NAT might not be supported)"
        fi
    else
        if ! command -v ip6tables &> /dev/null; then
            print_warning "ip6tables not available, skipping IPv6 rules"
        elif [ ! -f /proc/net/if_inet6 ]; then
            print_warning "IPv6 not enabled on system, skipping IPv6 rules"
        fi
    fi

    # Save iptables rules based on distribution
    save_iptables_rules
}

# Save one iptables ruleset atomically: write to a temp file first,
# back up the existing file with a timestamp, then move it into place.
# Never truncate the destination directly, and never overwrite it
# without a backup.
save_iptables_file() {
    local save_cmd="$1" dest="$2" tmp_file backup_file
    tmp_file="$(mktemp "/tmp/iptables-save.XXXXXX")" || {
        print_warning "Could not create temp file for $dest"
        return 1
    }
    if ! "$save_cmd" > "$tmp_file"; then
        print_warning "Failed to save iptables rules for $dest"
        rm -f "$tmp_file"
        return 1
    fi
    if [ -f "$dest" ]; then
        backup_file="${dest}.bak.$(date +%Y%m%d%H%M%S)"
        if cp -a "$dest" "$backup_file"; then
            print_status "Backed up existing rules to $backup_file"
        else
            print_warning "Could not back up $dest"
        fi
    fi
    if mv "$tmp_file" "$dest"; then
        print_status "iptables rules saved to $dest"
        return 0
    else
        print_warning "Failed to save iptables rules to $dest"
        rm -f "$tmp_file"
        return 1
    fi
}

# Function to save iptables rules with better error handling
save_iptables_rules() {
    print_status "Saving iptables rules..."

    case $PKG_MANAGER in
        dnf|yum)
            # For RHEL-based systems
            if command -v iptables-save &> /dev/null; then
                # Create directory if it doesn't exist
                mkdir -p /etc/sysconfig

                save_iptables_file iptables-save /etc/sysconfig/iptables || print_warning "Failed to save IPv4 iptables rules"

                if command -v ip6tables-save &> /dev/null && [ -f /proc/net/if_inet6 ]; then
                    save_iptables_file ip6tables-save /etc/sysconfig/ip6tables || print_warning "Failed to save IPv6 iptables rules"
                fi

                # Enable and start iptables service if available
                if systemctl list-unit-files | grep -q iptables.service; then
                    systemctl enable iptables 2>/dev/null || print_warning "Could not enable iptables service"
                    if command -v ip6tables &> /dev/null && [ -f /proc/net/if_inet6 ]; then
                        systemctl enable ip6tables 2>/dev/null || print_warning "Could not enable ip6tables service"
                    fi
                fi
            else
                print_warning "iptables-save not available, rules will not persist after reboot"
            fi
            ;;
        apt)
            # For Debian-based systems
            if command -v iptables-save &> /dev/null; then
                # Create directory if it doesn't exist
                mkdir -p /etc/iptables

                save_iptables_file iptables-save /etc/iptables/rules.v4 || print_warning "Failed to save IPv4 iptables rules"

                if command -v ip6tables-save &> /dev/null && [ -f /proc/net/if_inet6 ]; then
                    save_iptables_file ip6tables-save /etc/iptables/rules.v6 || print_warning "Failed to save IPv6 iptables rules"
                fi

                # Try to enable netfilter-persistent if available
                if systemctl list-unit-files | grep -q netfilter-persistent.service; then
                    systemctl enable netfilter-persistent 2>/dev/null || print_warning "Could not enable netfilter-persistent service"
                fi
            else
                print_warning "iptables-save not available, rules will not persist after reboot"
            fi
            ;;
    esac
}

# True (exit 0) if $1 is listened on by a process other than
# dnstt-server. A listener from our own previous install on 5300
# must not block a reconfigure.
port_in_use_by_other() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 2
    # ss columns: Netid State Recv-Q Send-Q Local-Address:Port Peer-Address:Port Process
    # so the local address is $5, not $4.
    ss -tulnp 2>/dev/null | awk -v p="$port" '
        NR == 1 { next }
        {
            n = split($5, a, ":")
            if (n > 0 && a[n] == p) {
                if ($0 ~ /dnstt-server/) next
                # Port 53 is only used for the iptables redirect on
                # the external interface, so a listener on loopback
                # only (e.g. systemd-resolved on 127.0.0.53 or
                # 127.0.0.54) never receives external DNS traffic
                # and does not block the tunnel.
                if (p == 53 && ($5 ~ /^127\./ || $5 ~ /^\[::1\]/)) next
                found = 1
            }
        }
        END { exit !found }
    '
}

# Print the ss lines for dnstt processes listening on $1, if any.
dnstt_listener_line() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 0
    ss -tulnp 2>/dev/null | awk -v p="$port" '
        NR == 1 { next }
        {
            n = split($5, a, ":")
            if (n > 0 && a[n] == p && tolower($0) ~ /dnstt/) print
        }
    '
}

# Print the ss lines for non-dnstt processes listening on $1, if any.
non_dnstt_listener_line() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 0
    ss -tulnp 2>/dev/null | awk -v p="$port" '
        NR == 1 { next }
        {
            n = split($5, a, ":")
            if (n > 0 && a[n] == p && tolower($0) !~ /dnstt/) {
                # Same loopback exception as port_in_use_by_other:
                # a loopback-only listener on port 53 does not block
                # the tunnel.
                if (p == 53 && ($5 ~ /^127\./ || $5 ~ /^\[::1\]/)) next
                print
            }
        }
    '
}

# True if our own dnstt-server systemd service is currently active.
# Together with RECONFIGURE_MODE=1 this marks a dnstt listener on
# DNSTT_PORT as our own install being reconfigured, rather than
# another dnstt that must be removed. (Our service never listens on
# port 53, so this is only used for DNSTT_PORT.)
is_own_dnstt_active() {
    [ -f "${SYSTEMD_DIR}/dnstt-server.service" ] \
        && command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet dnstt-server 2>/dev/null
}

# A dnstt process other than our own active service is using $1.
# Warn the user, and if they confirm, remove that dnstt completely
# and then make sure the port is really free before the install
# continues. Returns 0 when the port is free afterwards, 1 when the
# user declines or the port stays busy.
handle_dnstt_conflict() {
    local port="$1" listener="$2"
    print_warning "Another dnstt service is already running and using port $port:"
    echo "  $listener"
    print_warning "It must be completely removed before this install can continue."
    # Load the old config only to describe what the removal deletes
    # (tunnel mode, Dante). Restore the install's own values right
    # after, so a --install run keeps its CLI flags.
    local saved_subdomain="${NS_SUBDOMAIN:-}" saved_mtu="${MTU_VALUE:-}" saved_mode="${TUNNEL_MODE:-}"
    load_existing_config || true
    print_uninstall_summary without-script
    NS_SUBDOMAIN="$saved_subdomain"; MTU_VALUE="$saved_mtu"; TUNNEL_MODE="$saved_mode"
    # If another service that is not dnstt also holds a port, say so
    # now: removing dnstt will not free that port, and the install
    # will still stop until that service is stopped or reconfigured.
    local other_port other
    for other_port in 53 "$DNSTT_PORT"; do
        other=$(non_dnstt_listener_line "$other_port" || true)
        if [ -n "$other" ]; then
            print_warning "Note: port $other_port is also used by another service (not dnstt):"
            echo "  $other"
            print_warning "Removing dnstt will not free that port; the install will still stop until that service is stopped or reconfigured."
        fi
    done
    if [ "${NONINTERACTIVE:-0}" = "1" ]; then
        if [ "${CLI_YES:-0}" = "1" ]; then
            print_status "Non-interactive mode with --yes: removing the conflicting dnstt..."
        else
            print_error "Run the install interactively to confirm the removal, or re-run with --install --yes to allow it"
            return 1
        fi
    else
        echo ""
        print_question "Type YES to remove it completely and continue with the installation (anything else cancels): "
        local confirm
        read -r confirm
        if [ "$confirm" != "YES" ]; then
            print_error "Installation cancelled, the running dnstt was left untouched"
            return 1
        fi
    fi

    remove_dnstt_install

    # The managed install is gone, but a manually started dnstt
    # process may still hold the port. Stop it by PID if it does.
    local remaining pid wait_attempt
    remaining=$(dnstt_listener_line "$port" || true)
    if [ -n "$remaining" ]; then
        pid=$(printf '%s' "$remaining" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -1)
        if [ -n "$pid" ]; then
            print_status "Stopping the remaining dnstt process (PID $pid)..."
            kill "$pid" 2>/dev/null || true
            for wait_attempt in 1 2 3 4 5; do
                if [ -z "$(dnstt_listener_line "$port" || true)" ]; then
                    break
                fi
                sleep 1
            done
        fi
    fi
    if [ -n "$(dnstt_listener_line "$port" || true)" ]; then
        print_error "Port $port is still in use by a dnstt process after removal; stop it manually and run the install again"
        return 1
    fi
    print_status "Conflicting dnstt removed, port $port is free now"
    return 0
}

# Fail fast if port 53 (DNS) or DNSTT_PORT is already owned by
# another service, e.g. systemd-resolved on 127.0.0.53:53, dnsmasq
# or BIND. Without this the tunnel silently never receives queries.
check_ports_free() {
    print_status "Checking ports 53 and $DNSTT_PORT are free..."

    if ! command -v ss >/dev/null 2>&1; then
        print_warning "ss is not available, cannot check whether ports 53 and $DNSTT_PORT are already in use"
        return 0
    fi

    # Phase 1: dnstt conflicts on either port first. Port 53 is
    # often also held by another service (e.g. systemd-resolved),
    # and checking it first used to abort the install before the
    # dnstt on DNSTT_PORT was ever looked at, so the removal was
    # never offered. Check both ports for dnstt before failing on
    # any other service.
    local port listener
    for port in 53 "$DNSTT_PORT"; do
        listener=$(dnstt_listener_line "$port" || true)
        if [ -n "$listener" ]; then
            # Our own active service on DNSTT_PORT is a reconfigure,
            # not a conflict, but only when reconfiguring from the
            # menu (RECONFIGURE_MODE=1). A dnstt listener on port 53
            # is never our service, so it is always a conflict.
            if [ "$port" = "$DNSTT_PORT" ] && [ "${RECONFIGURE_MODE:-0}" = "1" ] && is_own_dnstt_active; then
                print_status "Port $port is used by our own running dnstt-server (reconfiguring it)"
                continue
            fi
            handle_dnstt_conflict "$port" "$listener" || exit 1
        fi
    done
    # Phase 2: any other listener on either port fails the install.
    local rc
    for port in 53 "$DNSTT_PORT"; do
        port_in_use_by_other "$port"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            print_error "Port $port is already in use by another process"
            non_dnstt_listener_line "$port" || true
            print_error "Stop or reconfigure that service first, then run the install again"
            exit 1
        elif [ "$rc" -eq 2 ]; then
            print_warning "Could not check port $port (ss failed), continuing"
        fi
    done

    print_status "Ports 53 and $DNSTT_PORT are free"
}

# Function to configure firewall
configure_firewall() {
    print_status "Configuring firewall..."

    # Check if firewalld is available and active
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        print_status "Configuring active firewalld..."
        firewall-cmd --permanent --add-port="$DNSTT_PORT"/udp
        firewall-cmd --permanent --add-port=53/udp
        firewall-cmd --reload
        print_status "Firewalld configured successfully"

    # Check if ufw is available and active
    elif command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        print_status "Configuring active ufw..."
        ufw allow "$DNSTT_PORT"/udp
        ufw allow 53/udp
        print_status "UFW configured successfully"

    else
        print_status "No active firewall service detected"
        print_status "Available firewall tools:"

        # List available but inactive firewall tools
        if command -v firewall-cmd &> /dev/null; then
            print_status "  - firewalld (inactive)"
        fi
        if command -v ufw &> /dev/null; then
            print_status "  - ufw (inactive)"
        fi

        print_status "Relying on iptables rules only"
        print_status "If you have a firewall active, manually allow ports $DNSTT_PORT/udp and 53/udp"
    fi

    # Configure iptables rules regardless of firewall service
    configure_iptables
}

# Function to detect SSH port
detect_ssh_port() {
    local sshd_config ssh_port

    # Read the effective sshd configuration instead of listening sockets,
    # which may also include temporary SSH forwarding ports.
    if command -v sshd >/dev/null 2>&1; then
        sshd_config=$(sshd -T 2>/dev/null || true)
    fi

    # Prefer the standard port when multiple effective ports are configured.
    ssh_port=$(printf '%s\n' "$sshd_config" | awk '
        $1 == "port" && $2 ~ /^[0-9]+$/ && $2 >= 1 && $2 <= 65535 {
            if ($2 == 22) standard_port = 22
            if (!first_port) first_port = $2
        }
        END {
            if (standard_port) print standard_port
            else if (first_port) print first_port
        }
    ')

    if [[ ! "$ssh_port" =~ ^[0-9]+$ ]]; then
        # Fall back to the default SSH port when no valid port is detected.
        ssh_port="22"
    fi
    echo "$ssh_port"
}

# Function to install and configure Dante SOCKS proxy
setup_dante() {
    print_status "Setting up Dante SOCKS proxy..."

    # Install Dante
    case $PKG_MANAGER in
        dnf|yum)
            if ! $PKG_MANAGER install -y dante-server; then
                print_error "Failed to install dante-server"
                exit 1
            fi
            ;;
        apt)
            # apt needs a fresh package list first; without it the
            # install can fail on a stale cache.
            if ! apt update; then
                print_error "Failed to update package lists"
                exit 1
            fi
            if ! apt install -y dante-server; then
                print_error "Failed to install dante-server"
                exit 1
            fi
            ;;
    esac

    # Get the primary network interface for external interface
    local external_interface
    external_interface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "$external_interface" ]]; then
        if ip link show eth0 >/dev/null 2>&1; then
            external_interface="eth0"  # fallback
        else
            print_error "Could not detect network interface for Dante and eth0 does not exist"
            exit 1
        fi
    fi
    if ! ip link show "$external_interface" >/dev/null 2>&1; then
        print_error "Network interface '$external_interface' does not exist, cannot configure Dante"
        exit 1
    fi

    # Configure Dante (config path and service name differ by distro:
    # Debian/Ubuntu use /etc/danted.conf + danted, RHEL/Fedora use
    # /etc/sockd.conf + sockd; see set_dante_names())
    cat > "$DANTE_CONF" << EOF
# Dante SOCKS server configuration - managed by dnstt-deploy (NSTT)
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

# Internal interface (where clients connect)
internal: 127.0.0.1 port = 1080

# External interface (where connections go out)
external: $external_interface

# Authentication method
socksmethod: none

# Compatibility settings
compatibility: sameport
extension: bind

# Client rules - allow connections from localhost
client pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    log: error
}

# SOCKS rules - allow SOCKS requests to anywhere
socks pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: error
}

# Block IPv6 if not properly configured
socks block {
    from: 0.0.0.0/0 to: ::/0
    log: error
}

client block {
    from: 0.0.0.0/0 to: ::/0
    log: error
}
EOF

    # Enable and start Dante service, then verify it is really running.
    # A restart that fails must stop the setup here, not be reported
    # as success and leave dnstt pointing at a dead SOCKS proxy.
    if ! systemctl enable "$DANTE_SERVICE"; then
        print_error "Failed to enable $DANTE_SERVICE"
        exit 1
    fi
    if ! systemctl restart "$DANTE_SERVICE"; then
        print_error "Failed to start $DANTE_SERVICE"
        systemctl status "$DANTE_SERVICE" --no-pager -l || true
        exit 1
    fi
    if ! systemctl is-active --quiet "$DANTE_SERVICE"; then
        print_error "$DANTE_SERVICE is not running after restart"
        systemctl status "$DANTE_SERVICE" --no-pager -l || true
        journalctl -u "$DANTE_SERVICE" -n 50 --no-pager || true
        exit 1
    fi

    print_status "Dante SOCKS proxy configured and started on port 1080 ($DANTE_SERVICE)"
    print_status "External interface: $external_interface"
}

# Function to create systemd service
create_systemd_service() {
    print_status "Creating systemd service..."

    local service_name="dnstt-server"
    local service_file="${SYSTEMD_DIR}/${service_name}.service"
    local target_port

    if [ "$TUNNEL_MODE" = "ssh" ]; then
        target_port=$(detect_ssh_port)
        print_status "Detected SSH port: $target_port"
    else
        target_port="1080"  # Dante SOCKS port
    fi

    # Stop service if it's running to allow reconfiguration
    if systemctl is-active --quiet "$service_name"; then
        print_status "Stopping existing dnstt-server service for reconfiguration..."
        systemctl stop "$service_name"
    fi

    # In SOCKS mode dnstt must start after Dante; in SSH mode there
    # is no Dante dependency. network-online (not just network) so
    # DNS / routing is actually up when the tunnel starts.
    local dante_unit=""
    if [ "$TUNNEL_MODE" = "socks" ]; then
        dante_unit="${DANTE_SERVICE:-danted}.service"
    fi

    # Create systemd service file
    cat > "$service_file" << EOF
[Unit]
Description=dnstt DNS Tunnel Server
After=network-online.target $dante_unit
Wants=network-online.target $dante_unit
# Stop an infinite restart loop on a bad config: after 5 failed
# starts in 60s systemd stops trying, instead of flooding the log
# forever while Restart=always hides the failure.
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=$DNSTT_USER
Group=$DNSTT_USER
ExecStart=${INSTALL_DIR}/dnstt-server -udp :${DNSTT_PORT} -privkey-file ${PRIVATE_KEY_FILE} -mtu ${MTU_VALUE} ${NS_SUBDOMAIN} 127.0.0.1:${target_port}
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=5

# Security settings
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/
ReadWritePaths=${CONFIG_DIR}
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and enable service
    systemctl daemon-reload
    systemctl enable "$service_name"

    print_status "Systemd service created: $service_name"
    print_status "Service will run as user: $DNSTT_USER"
    print_status "Service will listen on port: $DNSTT_PORT (redirected from port 53)"
    print_status "Service will tunnel to 127.0.0.1:$target_port"
    print_status "Mode: $TUNNEL_MODE"
}

# Detect the primary network interface, using the same method as
# configure_iptables(). Returns an empty string if none is found.
detect_primary_interface() {
    local iface=""
    if command -v ip >/dev/null 2>&1; then
        iface=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -1)
        if [ -z "$iface" ]; then
            iface=$(ip link show 2>/dev/null | grep -E "^[0-9]+: (eth|ens|enp)" | head -1 | cut -d':' -f2 | awk '{print $1}')
        fi
        if [ -z "$iface" ] && ip link show eth0 >/dev/null 2>&1; then
            iface="eth0"
        fi
    fi
    printf '%s' "$iface"
}

# Delete every copy of one iptables/ip6tables rule, if it exists.
# $1 = iptables or ip6tables, $2 = table, remaining args = rule.
remove_iptables_rule() {
    local cmd="$1" table="$2"
    shift 2
    if ! command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    local guard=0
    while [ "$guard" -lt 20 ]; do
        if ! "$cmd" -t "$table" -C "$@" 2>/dev/null; then
            return 0
        fi
        if ! "$cmd" -t "$table" -D "$@" 2>/dev/null; then
            print_warning "Could not remove $cmd ($table) rule: $*"
            return 0
        fi
        guard=$((guard + 1))
    done
    print_warning "Stopped removing $cmd ($table) rule after 20 copies"
}

# True if the Dante config file was written by this script.
is_dante_managed() {
    [ -f "$DANTE_CONF" ] && head -n 5 "$DANTE_CONF" 2>/dev/null | grep -q "Dante SOCKS server configuration"
}

# Print what a complete removal deletes. $1 = with-script: also list
# this script itself (menu uninstall); without-script: do not list
# it (install-time removal, where the script must keep running).
print_uninstall_summary() {
    echo ""
    print_warning "This will permanently remove:"
    echo "  - dnstt-server systemd service (stop, disable, delete the unit file)"
    echo "  - Configuration directory $CONFIG_DIR, including private and public keys"
    echo "  - Binary ${INSTALL_DIR}/dnstt-server"
    echo "  - iptables rules for UDP $DNSTT_PORT and the port 53 redirect (IPv4 and IPv6)"
    echo "  - firewalld/ufw rules for ports 53/udp and $DNSTT_PORT/udp, if present"
    if [ "${TUNNEL_MODE:-}" = "socks" ] || is_dante_managed; then
        echo "  - Dante SOCKS service ($DANTE_SERVICE) and its config $DANTE_CONF"
    fi
    if [ "$1" = "with-script" ]; then
        echo "  - This script itself ($SCRIPT_INSTALL_PATH)"
    fi
    echo "  - The dante-server package is NOT removed."
    echo ""
    print_warning "Private keys cannot be recovered. After a reinstall with the same subdomain, clients will need the new public key."
}

# Completely remove a dnstt install: service, Dante (only if this
# install used it), iptables/firewall rules, keys and config, and
# the binary. This is the core used by both the menu uninstall and
# the install-time conflict removal. It never deletes this script
# itself and never exits, so the caller can continue afterwards.
# The dante-server package is left installed on purpose, so a
# Dante used for something else is not broken by removing its
# package. Returns 0 on completion; individual failures only warn.
remove_dnstt_install() {
    local service_file="${SYSTEMD_DIR}/dnstt-server.service"
    local binary_file="${INSTALL_DIR}/dnstt-server"

    # 1. Stop and disable dnstt-server.
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet dnstt-server 2>/dev/null; then
            print_status "Stopping dnstt-server..."
            systemctl stop dnstt-server || print_warning "Could not stop dnstt-server"
        fi
        if systemctl is-enabled --quiet dnstt-server 2>/dev/null; then
            systemctl disable dnstt-server || print_warning "Could not disable dnstt-server"
        fi
    fi

    # 2. Stop and disable Dante, but only if this install used it.
    # The config file is removed only if this script wrote it; a
    # Dante config written by someone else is left alone.
    local remove_dante=false
    if [ "${TUNNEL_MODE:-}" = "socks" ]; then
        remove_dante=true
    elif is_dante_managed; then
        remove_dante=true
    fi
    if [ "$remove_dante" = true ]; then
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl is-active --quiet "$DANTE_SERVICE" 2>/dev/null; then
                print_status "Stopping $DANTE_SERVICE..."
                systemctl stop "$DANTE_SERVICE" || print_warning "Could not stop $DANTE_SERVICE"
            fi
            if systemctl is-enabled --quiet "$DANTE_SERVICE" 2>/dev/null; then
                systemctl disable "$DANTE_SERVICE" || print_warning "Could not disable $DANTE_SERVICE"
            fi
        fi
        if [ -f "$DANTE_CONF" ]; then
            if is_dante_managed; then
                rm -f "$DANTE_CONF" && print_status "Removed Dante config $DANTE_CONF"
            else
                print_warning "Dante config $DANTE_CONF was not created by this script, leaving it"
            fi
        fi
    else
        print_status "Dante was not used by this install, leaving it alone"
    fi

    # 3. Remove the systemd unit file.
    if [ -f "$service_file" ]; then
        rm -f "$service_file" && print_status "Removed $service_file"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || print_warning "Could not reload systemd"
        systemctl reset-failed dnstt-server 2>/dev/null || true
    fi

    # 4. Remove the iptables rules added at install time. The NAT
    # rule was added for a specific interface, so detect it the
    # same way as configure_iptables() did.
    if command -v iptables >/dev/null 2>&1; then
        print_status "Removing iptables rules..."
        remove_iptables_rule iptables filter INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT
        local iface
        iface=$(detect_primary_interface || true)
        if [ -n "$iface" ]; then
            remove_iptables_rule iptables nat PREROUTING -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT"
        else
            print_warning "Could not detect network interface, the NAT redirect rule may remain; check with: iptables -t nat -L PREROUTING -n --line-numbers"
        fi
        if command -v ip6tables >/dev/null 2>&1; then
            remove_iptables_rule ip6tables filter INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT
            if [ -n "$iface" ]; then
                remove_iptables_rule ip6tables nat PREROUTING -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT"
            fi
        fi
        # Persist the removal, so the rules do not come back on reboot.
        # save_iptables_rules() backs up the previous saved file first.
        save_iptables_rules || print_warning "Could not save iptables rules, removal may not persist after reboot"
    else
        print_warning "iptables is not available, skipping iptables cleanup"
    fi

    # 5. Remove firewalld and ufw rules, if those services are active.
    if command -v firewall-cmd >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        local fw_port removed_fw=false
        for fw_port in "$DNSTT_PORT"/udp 53/udp; do
            if firewall-cmd --permanent --query-port="$fw_port" >/dev/null 2>&1; then
                if firewall-cmd --permanent --remove-port="$fw_port" >/dev/null 2>&1; then
                    removed_fw=true
                else
                    print_warning "Could not remove firewalld port $fw_port"
                fi
            fi
        done
        if [ "$removed_fw" = true ]; then
            firewall-cmd --reload >/dev/null 2>&1 || print_warning "Could not reload firewalld"
            print_status "Removed firewalld ports"
        fi
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        local ufw_port
        for ufw_port in "$DNSTT_PORT"/udp 53/udp; do
            if ufw status 2>/dev/null | grep -q "$ufw_port"; then
                ufw --force delete allow "$ufw_port" >/dev/null 2>&1 || print_warning "Could not remove ufw rule for $ufw_port"
            fi
        done
    fi

    # 6. Remove the binary and the whole configuration directory.
    if [ -f "$binary_file" ]; then
        rm -f "$binary_file" && print_status "Removed $binary_file"
    fi
    if [ -n "$CONFIG_DIR" ] && [ "$CONFIG_DIR" != "/" ] && [ "$CONFIG_DIR" != "/etc" ] && [ -d "$CONFIG_DIR" ]; then
        rm -rf "$CONFIG_DIR" && print_status "Removed $CONFIG_DIR (including private keys)"
    fi

    print_status "Uninstall complete"
    return 0
}

# Menu uninstall: confirm, remove everything, then delete this
# script itself and exit.
uninstall_dnstt() {
    print_status "Uninstall dnstt server"
    print_status "====================="

    # Load the config if there is one, only to know the tunnel mode
    # and subdomain for the summary. A missing config is not fatal.
    load_existing_config || true

    print_uninstall_summary with-script
    echo ""
    print_question "Type YES to confirm complete removal (anything else cancels): "
    local confirm
    read -r confirm
    if [ "$confirm" != "YES" ]; then
        print_status "Uninstall cancelled, nothing was removed"
        return 0
    fi

    remove_dnstt_install

    # Remove this script itself. Deleting it while bash is still
    # reading it can fail, so defer the deletion to the EXIT trap:
    # it runs after this script has finished executing.
    if [ -n "$SCRIPT_INSTALL_PATH" ] && [ "$SCRIPT_INSTALL_PATH" != "/" ] && [ -f "$SCRIPT_INSTALL_PATH" ]; then
        print_status "Removing $SCRIPT_INSTALL_PATH"
        trap 'rm -f "$SCRIPT_INSTALL_PATH" || true' EXIT
    fi
    exit 0
}

# Function to start services
start_services() {
    print_status "Starting services..."

    # In SOCKS mode the tunnel is useless if Dante is down; fail
    # here with a clear message instead of printing SUCCESS later.
    if [ "$TUNNEL_MODE" = "socks" ]; then
        if ! systemctl is-active --quiet "${DANTE_SERVICE:-danted}"; then
            print_error "Dante (${DANTE_SERVICE:-danted}) is not running, cannot start dnstt-server"
            exit 1
        fi
    fi

    # Start dnstt-server service
    if ! systemctl start dnstt-server; then
        print_error "Failed to start dnstt-server"
        exit 1
    fi

    # Wait up to 10s for the service to actually become active.
    # systemctl start alone only queues the job, it does not prove
    # the process stayed up.
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if systemctl is-active --quiet dnstt-server; then
            break
        fi
        sleep 1
    done

    if ! systemctl is-active --quiet dnstt-server; then
        print_error "dnstt-server did not become active"
        systemctl status dnstt-server --no-pager -l || true
        journalctl -u dnstt-server -n 50 --no-pager || true
        exit 1
    fi

    print_status "dnstt-server service started and is active"

    # Display only: systemctl status exits non-zero when a service
    # is not active, so never let it exit the script under set -e.
    systemctl status dnstt-server --no-pager -l || true
}

# Function to display final information
display_final_info() {
    print_success_box
}

# Main function
main() {
    # Parse arguments first, before any tool installation, so a typo or
    # --help/--version fails fast without touching the system.
    # Flags only apply with --install; without it the menu flow is
    # unchanged and any flags are ignored.
    local cli_mode=""
    NONINTERACTIVE=0
    CLI_YES=0
    # 1 only when the user chose menu option 1 (Install/Reconfigure):
    # then our own active service is a reconfigure, not a conflict.
    # A fresh install (one-command or --install) leaves it 0, so a
    # running dnstt, even our own previous install, is offered for
    # complete removal instead of being silently kept.
    RECONFIGURE_MODE=0
    CLI_SUBDOMAIN="" CLI_MTU="" CLI_MODE=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --install) cli_mode="install"; NONINTERACTIVE=1; shift ;;
            --status) cli_mode="status"; shift ;;
            --update) cli_mode="update"; shift ;;
            --check-update) cli_mode="check-update"; shift ;;
            --subdomain)
                if [ $# -lt 2 ]; then print_error "--subdomain needs a value"; print_usage; exit 2; fi
                CLI_SUBDOMAIN="$2"; shift 2 ;;
            --subdomain=*) CLI_SUBDOMAIN="${1#--subdomain=}"; shift ;;
            --mtu)
                if [ $# -lt 2 ]; then print_error "--mtu needs a value"; print_usage; exit 2; fi
                CLI_MTU="$2"; shift 2 ;;
            --mtu=*) CLI_MTU="${1#--mtu=}"; shift ;;
            --mode)
                if [ $# -lt 2 ]; then print_error "--mode needs a value"; print_usage; exit 2; fi
                CLI_MODE="$2"; shift 2 ;;
            --mode=*) CLI_MODE="${1#--mode=}"; shift ;;
            --yes) CLI_YES=1; shift ;;  # confirm prompts in scripted use, including removing a conflicting dnstt
            -h|--help) print_usage; exit 0 ;;
            --version) echo "dnstt-deploy $SCRIPT_VERSION"; exit 0 ;;
            *) print_error "Unknown option: $1"; print_usage; exit 2 ;;
        esac
    done

    # Tools: detect_os sets PKG_MANAGER, check_required_tools installs
    # curl, ip, ss and iptables if missing. install_script and
    # check_for_updates both need curl and sha256sum, so they must run
    # only after this point, not before it.
    detect_os
    detect_arch
    check_required_tools

    # Single-purpose modes exit here and never touch the install flow.
    if [ "$cli_mode" = "status" ]; then
        if show_configuration_info; then exit 0; else exit 1; fi
    fi
    if [ "$cli_mode" = "update" ]; then
        if update_script; then exit 0; else exit 1; fi
    fi
    if [ "$cli_mode" = "check-update" ]; then
        check_for_updates
        if [ "$UPDATE_AVAILABLE" = true ]; then
            print_warning "A newer version is available; run with --update or menu option 2."
        else
            print_status "Script is up to date (or the update check did not apply)."
        fi
        exit 0
    fi

    if [ "$cli_mode" = "install" ]; then
        # Non-interactive install: no menu, no prompts. Values come from
        # flags (or the stored config) in get_user_input.
        NS_SUBDOMAIN="$CLI_SUBDOMAIN"
        MTU_VALUE="$CLI_MTU"
        TUNNEL_MODE="$CLI_MODE"
        if ! is_installed_invocation; then
            print_status "Installing dnstt-deploy script..."
            install_script
            print_status "Starting dnstt server setup..."
        else
            print_status "Starting dnstt server installation/reconfiguration..."
        fi
    # If not running from installed location (curl/GitHub), install the script first
    elif ! is_installed_invocation; then
        print_status "Installing dnstt-deploy script..."
        install_script
        print_status "Starting dnstt server setup..."
    else
        # Running from installed location - check for updates and show menu
        check_for_updates
        handle_menu
        # If we reach here, user chose option 1 (Install/Reconfigure), so continue
        RECONFIGURE_MODE=1
        print_status "Starting dnstt server installation/reconfiguration..."
    fi

    # Fail fast if another service already owns port 53 or 5300,
    # before asking the user for input or changing anything.
    # Our own previous dnstt-server listener on 5300 is exempt only
    # when reconfiguring from the menu (RECONFIGURE_MODE=1).
    check_ports_free

    # Get user input
    get_user_input

    # Download and verify dnstt-server
    download_dnstt_server

    # Create dnstt user
    create_dnstt_user

    # Generate keys
    generate_keys

    # Save configuration after keys are generated
    save_config

    # Configure firewall and iptables
    configure_firewall

    # Setup tunnel mode specific configurations
    if [ "$TUNNEL_MODE" = "socks" ]; then
        setup_dante
    else
        # If switching from SOCKS to SSH, stop and disable Dante
        if systemctl is-active --quiet "$DANTE_SERVICE"; then
            print_status "Switching from SOCKS to SSH mode - stopping Dante service..."
            systemctl stop "$DANTE_SERVICE"
            systemctl disable "$DANTE_SERVICE"
        fi
    fi

    # Create systemd service
    create_systemd_service

    # Start services
    start_services

    # Display final information
    display_final_info
}

# Run main function
main "$@"
