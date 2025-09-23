## Important: Why the 1-Minute Interval?

ProtonVPN's port forwarding requires a persistent loop to keep the port open. If the loop process stops, the port will close after 60 seconds. This is why the cron job and service are designed to run the sync script every minute (cron) or every 30 seconds (service).

> "Port forwarding is now activated. Note that closing your terminal window will terminate the loop process. You will need to re-run this loop script each time you want to start a new port forwarding session or the port will only stay open for 60 seconds." — ProtonVPN Docs

**Summary:**
- The frequent interval is required to keep the port forwarding session alive, not just to minimize qBittorrent downtime.
- The script is lightweight and safe to run frequently.

# qBittorrent WireGuard Port Sync

A bash script that automatically monitors your WireGuard listening port and updates qBittorrent's port mapping when it changes. Perfect for VPN setups with dynamic NAT port forwarding.

## Features

- 🔄 Automatically detects WireGuard port changes
- 📡 Updates qBittorrent via Web API (localhost, no auth required)
- 📝 Comprehensive logging for debugging
- 🔧 Multiple methods to detect WireGuard port
- ⚡ Lightweight and efficient for cron execution
- 🛡️ Error handling and validation
- 🔍 Status checking and manual override options

## Requirements

- Debian/Ubuntu Linux (or similar)
- **Bash shell** (not sh - scripts use bash-specific features)
- WireGuard installed and configured
- qBittorrent with Web UI enabled (no authentication)
- `curl` command available
- Bash 4.0+ (standard on modern systems)

## Quick Setup

### Option 1: Automated Installation (Recommended)

```bash
# Clone or download the project
git clone https://github.com/Simon-CR/qbittorrent-wireguard-pmp.git
cd qbittorrent-wireguard-pmp

# Run the installation script (requires bash, not sh)
chmod +x install.sh
./install.sh

# Alternative if chmod doesn't work:
bash install.sh
```

The installation script will:
- Check all dependencies (curl, WireGuard tools)
- **Verify qBittorrent is running** and detect the process
- **Auto-detect qBittorrent Web UI port** from config files or by scanning running processes
- Verify your WireGuard interface is active
- Test qBittorrent Web UI connectivity
- Configure the script for your setup
- Offer deployment options:
  - **Cron job** (every 5 minutes) - Simple and reliable
  - **Systemd service** (continuous monitoring every 30 seconds) - More responsive
  - **Both options** - Install tools for flexible switching
  - **Manual setup** - Skip automation for custom setup

### Option 2: Manual Setup

```bash
# Clone or download the script
git clone https://github.com/Simon-CR/qbittorrent-wireguard-pmp.git
cd qbittorrent-wireguard-pmp

# Make script executable (requires bash, not sh)
chmod +x port-sync.sh

# Test the script
./port-sync.sh --check
```

## Deployment Options

After installation, you have several options for running the script:


### Option A: Cron Job (Recommended for most users)
- Runs automatically every **minute** (recommended)
- Simple, reliable, low resource usage
- Set up during installation or manually:

```bash
crontab -e
# Add this line for best results:
* * * * * /path/to/port-sync.sh >/dev/null 2>&1
```

**Why 1-minute interval?**

- ProtonVPN's port forwarding session will only stay open for 60 seconds unless the loop process is kept running. Quoting ProtonVPN docs: "Port forwarding is now activated. Note that closing your terminal window will terminate the loop process. You will need to re-run this loop script each time you want to start a new port forwarding session or the port will only stay open for 60 seconds."
- Running the sync every minute ensures the port forwarding session remains active and your port stays open.
- The script is lightweight and only updates qBittorrent if a change is detected, so frequent execution is safe and efficient.

### Option B: Systemd Service (Advanced users)
- Continuous monitoring with 30-second intervals
- More responsive to port changes
- Includes proper logging and service management
- Set up using the service manager:

```bash
# Install and start the service
./service-manager.sh install

# Manage the service
./service-manager.sh status    # Check status
./service-manager.sh logs      # View logs
./service-manager.sh stop      # Stop service
./service-manager.sh start     # Start service
./service-manager.sh restart   # Restart service
./service-manager.sh uninstall # Remove service
```

### Option C: Manual Operation
Run the script directly when needed:

```bash
./port-sync.sh           # Normal sync
./port-sync.sh --check   # Check status only
./port-sync.sh --force   # Force update qBittorrent
./port-sync.sh --daemon  # Run as daemon (30s intervals)
```

### 2. Configure qBittorrent Web UI (if using manual setup)

Ensure qBittorrent Web UI is enabled and accessible:

1. Open qBittorrent
2. Go to **Tools** → **Options** → **Web UI**
3. Enable **Web User Interface (Remote control)**
4. Set **Port** to `8080` (or edit script if different)
5. **Disable authentication** or set to **Bypass authentication for clients on localhost**
6. Click **OK** and restart qBittorrent

### 3. Configure WireGuard Interface (if needed)

If your WireGuard interface is not `wg0`, you may need to edit the script:

```bash
# Edit the script to match your interface name
nano port-sync.sh

# Change this line if needed:
WG_INTERFACE="wg0"  # Change to your interface name (e.g., "wg-vpn")
```

**Note:** The installation script will help you configure this automatically.

### 4. Test the Script

```bash
# Check current status
./port-sync.sh --check

# Run a manual sync
./port-sync.sh

# Force update qBittorrent to match WireGuard
./port-sync.sh --force
```

### 5. Alternative Setup (if not using installer)

If you didn't use the installation script, you can set up automation manually:

**For Cron Job:**
```bash
# Edit your crontab
crontab -e

# Add this line (adjust path as needed):
*/5 * * * * /home/yourusername/qbittorrent-wireguard-pmp/port-sync.sh >/dev/null 2>&1
```

**For Systemd Service:**
```bash
# Use the service manager
./service-manager.sh install
```

Or with logging to see cron output:
```bash
*/5 * * * * /home/yourusername/qbittorrent-wireguard-pmp/port-sync.sh >> /home/yourusername/qbittorrent-wireguard-pmp/cron.log 2>&1
```

## Usage

### Command Line Options

```bash
# Normal operation (use in cron)
./port-sync.sh

# Check current status without making changes
./port-sync.sh --check

# Force update qBittorrent to match WireGuard
./port-sync.sh --force

# Run as daemon (continuous monitoring every 30 seconds)
./port-sync.sh --daemon

# Show detailed debugging information
./port-sync.sh --debug

# Show help
./port-sync.sh --help
```

### Output Examples

**Normal operation:**
```bash
$ ./port-sync.sh
[2025-09-23 10:15:30] Starting port sync check...
[2025-09-23 10:15:30] Current WireGuard port: 51820
[2025-09-23 10:15:30] Current qBittorrent port: 48392
[2025-09-23 10:15:30] Port mismatch detected - updating qBittorrent from 48392 to 51820
[2025-09-23 10:15:30] Successfully updated qBittorrent port to: 51820
[2025-09-23 10:15:31] Port update verified: qBittorrent is now using port 51820
[2025-09-23 10:15:31] Port sync check completed successfully
```

**Status check:**
```bash
$ ./port-sync.sh --check
WireGuard port: 51820
qBittorrent port: 51820
```

## Configuration

Edit the script to customize these settings:

```bash
# qBittorrent Web UI settings
QBITTORRENT_HOST="localhost"
QBITTORRENT_PORT="8080"

# WireGuard interface name
WG_INTERFACE="wg0"

# File locations (automatically set to script directory)
LOG_FILE="${SCRIPT_DIR}/port-sync.log"
```

## How It Works

1. **Port Detection**: The script uses multiple methods to detect your WireGuard listening port:
   - `wg show` command (primary method)
   - Parse WireGuard config file (fallback)
   - Network socket analysis (last resort)

2. **Port Comparison**: Gets the current qBittorrent listening port via Web API and compares it with the WireGuard port

3. **qBittorrent Update**: If ports don't match, uses the qBittorrent Web API to update the listening port:
   - `GET /api/v2/app/preferences` - Get current settings
   - `POST /api/v2/app/setPreferences` - Update port setting

4. **Verification**: Confirms the port was actually changed in qBittorrent

5. **Logging**: All activities are logged to `port-sync.log` with timestamps

## Troubleshooting

### Common Issues

**"Error: This script requires bash, not sh":**
```bash
# ✗ Wrong - don't use sh
sh install.sh

# ✓ Correct - use one of these instead:
bash install.sh
# or
chmod +x install.sh && ./install.sh
```

**qBittorrent not accessible:**
```bash
ERROR: qBittorrent Web UI is not accessible at http://localhost:8080
```
- Ensure qBittorrent is running
- Check Web UI is enabled in qBittorrent settings
- Try common ports: 8080, 8090, 8081, 8888, 9090
- The installation script auto-detects the port, but you can manually specify it
- Disable authentication for localhost

**WireGuard port not detected:**
```bash
ERROR: Could not determine WireGuard listening port
```
- Check WireGuard is running: `sudo wg show`
- Verify interface name matches script: `ip link show | grep wg`
- Ensure you have permission to read WireGuard status

**Permission denied:**
- Make script executable: `chmod +x port-sync.sh`
- Check file permissions on script directory
- Run with appropriate user permissions

### Debug Mode

Check logs for detailed information:
```bash
# View recent log entries
tail -f port-sync.log

# View full log
cat port-sync.log

# Clear log file
> port-sync.log
```

### Manual Testing

Test individual components:
```bash
# Test WireGuard port detection
wg show wg0 listen-port

# Test qBittorrent API access
curl http://localhost:8080/api/v2/app/version

# Test port retrieval
curl http://localhost:8080/api/v2/app/preferences | grep listen_port

# Test the script with debug mode
bash port-sync.sh --debug
```

## File Structure

```
qbittorrent-wireguard-pmp/
├── port-sync.sh           # Main script
├── port-sync.log          # Activity log (auto-created)
├── install.sh             # Installation helper
├── cron.log               # Cron output (optional)
└── README.md              # This file
```

## Security Notes

- Script runs locally and communicates only with localhost services
- No sensitive data is transmitted over network
- Log files may contain port numbers (not sensitive but keep private)
- Ensure qBittorrent Web UI is only accessible from localhost

## Contributing

Feel free to submit issues and enhancement requests!

## License

This project is released under the MIT License. See LICENSE file for details.

---

**Need help?** Check the troubleshooting section or create an issue with:
- Your system details (OS, WireGuard version, qBittorrent version)
- Relevant log entries from `port-sync.log`
- Output from `./port-sync.sh --check`