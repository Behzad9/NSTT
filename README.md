# NSTT

**Languages:** [English](README.md) | [فارسی](README-fa.md)


🚀 **One-click dnstt server deployment and management**

A comprehensive automation script for deploying and managing [dnstt](https://www.bamsoftware.com/software/dnstt) DNS tunnel servers on Linux systems. This script handles everything from installation to configuration, making DNS tunnel deployment effortless.

NSTT is a hardened version of [bugfloyd/dnstt-deploy](https://github.com/bugfloyd/dnstt-deploy), with input validation, safe configuration handling, idempotent firewall rules, per-distribution Dante support, a port-conflict check, binary verification on every run, a safe uninstall option, and a non-interactive install mode for automation.

## DNS Domain Setup

Before using this script, you need to properly configure your domain's DNS records. Here's the required setup:

### Example Configuration
- **Your domain name**: `example.com`
- **Your server's IPv4 address**: `203.0.113.2`
- **Your server's IPv6 address**: `2001:db8::2` (optional)
- **Tunnel subdomain**: `t.example.com`
- **Server hostname**: `tns.example.com`

### DNS Records Setup
Go into your name registrar's configuration panel and add these records:

| Type | Name | Points to |
|------|------|-----------|
| A | `tns.example.com` | `203.0.113.2` |
| AAAA | `tns.example.com` | `2001:db8::2` (if IPv6 available) |
| NS | `t.example.com` | `tns.example.com` |

**Important**: Wait for DNS propagation (can take up to 24 hours) before testing your tunnel.

## Features

- **Multi-distribution support**: Fedora, Rocky Linux, CentOS, Debian, Ubuntu
- **Interactive management menu**: Easy-to-use interface for all operations
- **Self-updating capability**: Built-in update mechanism for the script, with download validation (a bad or HTML download never overwrites the installed script)
- **Automatic detection**: OS, architecture, and SSH port detection
- **Systemd service integration**: Creates and manages a dedicated systemd service for reliable operation, automatic startup on boot, and comprehensive logging
- **Security hardened**: Non-root service execution with systemd security features, a root-owned configuration directory, and a restart limit so a bad configuration does not loop forever
- **Smart configuration**: Persistent settings and automatic key reuse; the configuration file is parsed as data, never executed as code
- **Input validation**: The subdomain must be a valid DNS name and the MTU must be a number between 576 and 9000
- **Flexible tunneling**: SSH mode or SOCKS proxy mode
- **Network ready**: Automatic firewall and iptables configuration; rules are added only once, and saved rules are backed up before being overwritten
- **Port-conflict check**: The setup stops early if port 53 or 5300 is already owned by another service (for example systemd-resolved), instead of silently never receiving queries. If the listener is another dnstt service, the installer warns you and, only after you type `YES` (any letter case), removes that dnstt completely and then continues with the installation
- **Binary verification**: MD5, SHA1, and SHA256 checksum validation on every run, including for an already installed binary; a mismatched or corrupted binary is re-downloaded
- **Per-distribution Dante**: `danted` on Debian/Ubuntu and `sockd` on Fedora/Rocky/CentOS, with the matching configuration file and service checks
- **Safe uninstall**: menu option 6 completely removes the dnstt install (service, keys, iptables and firewall rules, binary, and the script itself) after a typed `YES` confirmation, and only removes Dante when this install used it
- **Official binaries**: Downloads from [dnstt.network](https://dnstt.network)

## Quick Start

### Prerequisites
- Linux server (Fedora, Rocky, CentOS, Debian, or Ubuntu)
- Root access or sudo privileges
- Internet connection for package downloads
- **Domain name with proper DNS configuration** (see DNS Domain Setup section above)

### Installation

**One-command installation:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Behzad9/NSTT/main/dnstt-deploy.sh)
```

This command will:
1. Install any missing tools (`curl`, `ip`, `ss`, `iptables`) and check the remaining required tools
2. Download and install the script to `/usr/local/bin/dnstt-deploy`
3. Check that ports 53 and 5300 are free
4. Start the interactive setup process
5. Configure your dnstt server automatically

### Post-Installation Usage

After installation, you can manage your dnstt server using the installed command:

```bash
dnstt-deploy
```

This will show an interactive menu with these options:

1. **Install/Reconfigure dnstt server** - Set up or modify configuration
2. **Update dnstt-deploy script** - Check for and install script updates
3. **Check service status** - View current service status
4. **View service logs** - Monitor real-time logs (Ctrl+C to exit)
5. **Show configuration info** - Show the current configuration, public key, and management commands
6. **Uninstall dnstt server** - Completely remove the dnstt install (asks for confirmation first)
0. **Exit** - Quit the menu

### Setup Process

During the setup (option 1), you'll be prompted for:
- **Nameserver subdomain** (e.g., `t.example.com`)
- **MTU value** (default: 1232)
- **Tunnel mode** (SSH or SOCKS)

## Configuration

### Tunnel Modes

**SOCKS Mode (Option 1)**
- Sets up integrated Dante SOCKS5 proxy
- Listens on `127.0.0.1:1080`
- Provides full internet proxy capabilities

**SSH Mode (Option 2)**
- Tunnels DNS traffic to your SSH service
- Automatically detects SSH port (default: 22)
- Perfect for secure shell access via DNS
- Compatible with mobile apps

### MTU Settings
- **Default**: 1232 bytes
- **Accepted range**: 576-9000 bytes (enforced by the script)
- **Recommended values**:
    - Stable/Fast networks: 1400
    - Standard networks: 1232
    - Unstable/Slow networks: 1200

### Changing Settings
To change MTU or other settings:
1. Run `dnstt-deploy`
2. Choose option 1 (Install/Reconfigure dnstt server)
3. Enter new values when prompted

The script will automatically update the configuration and restart services.

## Client Usage

### Download Client Binary

Download the appropriate dnstt client binary for your platform from [dnstt.network](https://dnstt.network):

**Common platforms:**
- **Linux x64**: `dnstt-client-linux-amd64`
- **Windows x64**: `dnstt-client-windows-amd64.exe`
- **macOS Intel**: `dnstt-client-darwin-amd64`
- **macOS Apple Silicon**: `dnstt-client-darwin-arm64`

### Connection Command

After server deployment, you'll receive a public key. Use it to connect:

```bash
dnstt-client -udp DNS_SERVER_IP:53 -pubkey-file server.pub t.example.com 127.0.0.1:7000
```

#### DNS_SERVER_IP

The DNS server IP depends on your system:

**Linux**:
```bash
systemd-resolve --status | grep "DNS Servers"
```
Common options: `127.0.0.53:53`, `127.0.0.1:53`, or your router's IP

**Windows**:
```cmd
ipconfig /all | findstr /C:"DNS Servers"
```

**macOS**:
```bash
scutil --dns | grep nameserver
```

You can also use:
- Your router/modem internal IP (e.g., `192.168.1.1:53`)
- Your ISP's DNS server IP
- Public DNS servers like `8.8.8.8:53` or `1.1.1.1:53` (If Available)

### Mobile Apps (SSH Mode)

For SSH tunnels, you can use these Android/iOS apps without needing a computer:

**Android**:
- [HTTP Injector](https://play.google.com/store/apps/details?id=com.evozi.injector)
- [HTTP Custom](https://play.google.com/store/apps/details?id=xyz.easypro.httpcustom)
- [DarkTunnel](https://play.google.com/store/apps/details?id=net.darktunnel.app)

**iOS**:
- [HTTP Injector](https://apps.apple.com/us/app/http-injector/id1659992827)

## Management

### Management Menu

The easiest way to manage your dnstt server is through the interactive menu:

```bash
dnstt-deploy
```

This provides quick access to:
- Server reconfiguration
- Script updates
- Service status monitoring
- Real-time log viewing
- Configuration info
- Safe uninstall (option 6)

### Command-Line Usage

For scripts and automation, the same operations are available without the menu:

```bash
dnstt-deploy --install --subdomain t.example.com --mode socks --mtu 1232
dnstt-deploy --status
dnstt-deploy --update
dnstt-deploy --check-update
dnstt-deploy --help
dnstt-deploy --version
```

`--install` needs `--subdomain` and `--mode socks|ssh` (`--mtu` defaults to 1232, or to the stored value when reconfiguring). A missing or invalid value stops the install with an error instead of asking. Uninstall stays interactive: run `dnstt-deploy` and choose option 6, then type `YES` (any letter case) to confirm.

### File Locations

```
/usr/local/bin/dnstt-deploy             # Management script
/usr/local/bin/dnstt-server             # Main binary
/etc/dnstt/                             # Configuration directory
├── dnstt-server.conf                  # Main configuration
├── {domain}_server.key                # Private key (per domain)
└── {domain}_server.pub                # Public key (per domain)
/etc/systemd/system/dnstt-server.service  # Systemd service
```

### Manual Service Commands

If you prefer command-line management:

**dnstt-server Service**:
```bash
sudo systemctl status dnstt-server    # Check status
sudo systemctl start dnstt-server     # Start service
sudo systemctl stop dnstt-server      # Stop service
sudo systemctl restart dnstt-server   # Restart service
sudo journalctl -u dnstt-server -f    # View logs
```

**Dante SOCKS Service (SOCKS mode only)**:

The service name depends on your distribution:

| Distribution | Service | Configuration file |
|--------------|---------|--------------------|
| Debian, Ubuntu | `danted` | `/etc/danted.conf` |
| Fedora, Rocky, CentOS | `sockd` | `/etc/sockd.conf` |

```bash
# Debian / Ubuntu
sudo systemctl status danted          # Check status
sudo systemctl start danted           # Start service
sudo systemctl stop danted            # Stop service
sudo systemctl restart danted         # Restart service
sudo journalctl -u danted -f          # View logs
```

```bash
# Fedora / Rocky / CentOS
sudo systemctl status sockd           # Check status
sudo systemctl start sockd            # Start service
sudo systemctl stop sockd             # Stop service
sudo systemctl restart sockd          # Restart service
sudo journalctl -u sockd -f           # View logs
```

### Updating the Script

The script can update itself in two ways:

**Method 1: Using the menu (recommended)**
```bash
dnstt-deploy
# Choose option 2: Update dnstt-deploy script
```

**Method 2: Re-run the curl command**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Behzad9/NSTT/main/dnstt-deploy.sh)
# The script will detect and install updates automatically
```

### Uninstalling

To completely remove a dnstt install, run `dnstt-deploy` and choose option 6 (Uninstall dnstt server). The script shows exactly what will be removed and asks you to type `YES` (any letter case) to confirm; anything else cancels and nothing is removed.

The uninstall removes:
- The `dnstt-server` systemd service (stop, disable, delete the unit file)
- The Dante SOCKS service and its config, but only if this install used SOCKS mode; a Dante config written by someone else is left alone
- The iptables rules for UDP 5300 and the port 53 redirect (IPv4 and IPv6), and the saved rules are updated so they do not come back on reboot
- The firewalld/ufw rules for ports 53/udp and 5300/udp, if present
- The configuration directory `/etc/dnstt`, including private and public keys (private keys cannot be recovered, so clients will need the new public key after a reinstall)
- The `dnstt-server` binary and the `dnstt-deploy` script itself

The `dante-server` package itself is not removed.



## Troubleshooting

### Using the Built-in Tools

The management menu provides quick access to troubleshooting tools:

1. **Check service status** (menu option 3): Shows if services are running properly
2. **View service logs** (menu option 4): Real-time monitoring of service logs
3. **Show configuration info** (menu option 5): Shows the current configuration and public key

### MTU Size Errors

If you see errors like this:
```
FORMERR: requester payload size 512 is too small (minimum 1232)
```

Raise the MTU to at least the mentioned number:
1. Run `dnstt-deploy`
2. Choose option 1 (Install/Reconfigure dnstt server)
3. Enter the suggested MTU value when prompted (for example, 1232)

Consider the performance trade-offs when using very low MTU values.

### Common Issues

**Service Won't Start**:
```bash
dnstt-deploy  # Use menu option 3 to check status
# Or manually:
sudo systemctl status dnstt-server    # Check service status
sudo journalctl -u dnstt-server -n 50 # Check logs for errors
ls -la /usr/local/bin/dnstt-server    # Verify binary permissions
```

**Port Already in Use**:
If the setup stops with "Port 53 is already in use" or "Port 5300 is already in use", another service owns that port. Check it with:
```bash
sudo ss -tulnp | grep -E ":(53|5300)[[:space:]]"
```
On many systems the listener on port 53 is systemd-resolved on `127.0.0.53:53` or `127.0.0.54:53`, but a loopback-only listener like that does not block the install, because the port 53 redirect only applies to the external interface. Only a listener on `0.0.0.0:53` or a public address blocks it; stop or reconfigure that service first, then run the setup again. A listener from your own previous dnstt-server install on port 5300 does not block a reconfigure (menu option 1); a fresh install offers to remove it instead, see below.

**Another dnstt is already running**: if the process using port 53 or 5300 is a dnstt service other than your own active one, the installer shows the listener, explains that it must be completely removed, and asks you to type `YES` (any letter case) to remove it and continue. Anything else cancels the installation and leaves the running dnstt untouched. A running dnstt is offered for removal during a fresh install (the one-command install or `--install`), even if it is your own previous install. Only menu option 1 (Install/Reconfigure) treats your own active dnstt-server as a reconfigure, not a conflict. The installer checks both ports for a dnstt service before failing on any other service, so a dnstt on port 5300 is still offered for removal even when another service also holds port 53; in that case it warns you that removing dnstt will not free port 53, and the install will still stop until that service is stopped or reconfigured. A listener on port 53 that only listens on loopback (for example systemd-resolved on 127.0.0.53 or 127.0.0.54) does not block the install, because the port 53 redirect only applies to the external interface; a listener on 0.0.0.0:53 or a public address still blocks it. In non-interactive mode (`--install`), the removal only happens with `--yes`; without it the install stops with an error. After the removal, the installer restarts itself once from the top, so the installation runs on the clean system; if a dnstt is still running after the restart, it is handled without another restart. The port check itself never hangs: listing sockets is capped at 10 seconds, and if `ss` fails or times out the check is skipped with a warning instead of stopping the install.

**Binary Verification Failed**:
If the setup reports a checksum mismatch, the downloaded binary was not installed and the previously installed binary was left untouched. Check your network connection and try again; do not install a binary from an untrusted source.

**Invalid Subdomain or MTU**:
The setup only accepts a valid DNS subdomain (for example `t.example.com`) and an MTU between 576 and 9000. Invalid input is rejected and asked again, so a typo cannot break the configuration or the systemd service.

**Dante Won't Start (SOCKS Mode)**:
```bash
sudo systemctl status danted    # Debian / Ubuntu
sudo systemctl status sockd     # Fedora / Rocky / CentOS
sudo journalctl -u danted -n 50 # Debian / Ubuntu
sudo journalctl -u sockd -n 50  # Fedora / Rocky / CentOS
```
A wrong external interface is the most common cause. The setup now verifies that Dante is actually running before finishing; if it fails, fix the interface or the Dante configuration and run the setup again.

**DNS Configuration Issues**:
```bash
dig @YOUR_SERVER_IP t.mydomain.com           # Test DNS tunnel (from client)
sudo iptables -t nat -L PREROUTING -n -v     # Check iptables rules
```

**SOCKS Proxy Issues**:
```bash
curl --socks5 127.0.0.1:1080 http://httpbin.org/ip  # Test SOCKS proxy locally
sudo cat /etc/danted.conf                           # Check Dante configuration (Debian / Ubuntu)
sudo cat /etc/sockd.conf                            # Check Dante configuration (Fedora / Rocky / CentOS)
```

**Port Check**:
```bash
sudo ss -tulnp | grep 5300  # Check dnstt-server port
sudo ss -tulnp | grep 1080  # Check SOCKS proxy port (if enabled)
```

## Advanced Features

### Multiple Domain Support

The script supports multiple domains by generating separate key pairs for each domain. However, only one domain configuration can be active at a time since all configurations use port 53 for DNS traffic. To switch between domains:

1. Run `dnstt-deploy`
2. Choose option 1 (Install/Reconfigure dnstt server)
3. Enter the new subdomain when prompted

### DoH and DoT Support

For DNS-over-HTTPS (DoH) or DNS-over-TLS (DoT) configurations, refer to the [official dnstt documentation](https://dnstt.network) for detailed setup instructions.

### Performance Monitoring

Use the built-in log viewer (menu option 4) or manual commands:

```bash
sudo ss -tulnp | grep -E "(5300|1080)"        # Monitor connection count
sudo systemctl status dnstt-server            # Check service resources
sudo journalctl -u dnstt-server -f --no-pager # Monitor logs for errors
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

## Acknowledgments

- [dnstt](https://dnstt.network) by David Fifield
- [Dante SOCKS server](https://www.inet.no/dante/) for SOCKS proxy functionality
- Based on [bugfloyd/dnstt-deploy](https://github.com/bugfloyd/dnstt-deploy)

## Support

- **Issues**: [GitHub Issues](https://github.com/Behzad9/NSTT/issues)
- **Discussions**: [GitHub Discussions](https://github.com/Behzad9/NSTT/discussions)
- **Official project website**: [dnstt.network](https://dnstt.network)

---

**Made with ❤️ for privacy and security**
