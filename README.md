## Why Continuous Updates?

ProtonVPN's port forwarding requires a persistent loop to keep the port open. If the loop process stops, the forwarded port closes after 60 seconds. The included systemd service keeps `natpmpc` alive by refreshing the mapping every ~24–25 seconds (<45% of ProtonVPN's 60-second granted lease so at least two independent renewal attempts fit inside every lease window) with wall-clock elapsed-time compensation.

> "Port forwarding is now activated. Note that closing your terminal window will terminate the loop process. You will need to re-run this loop script each time you want to start a new port forwarding session or the port will only stay open for 60 seconds." — ProtonVPN Docs

**Summary:**
- Keeping the NAT-PMP lease alive prevents ProtonVPN from reclaiming your forwarded port.
- Port changes are hot-applied via qBittorrent's WebUI API (`POST /api/v2/app/setPreferences`) with **zero service restarts and zero torrent downtime**.

# qBittorrent WireGuard Port Sync

A bash script that continuously refreshes the ProtonVPN NAT-PMP forwarded port and keeps qBittorrent's listening port in sync. Perfect for VPN setups with dynamic port forwarding over WireGuard.

> Although ProtonVPN is currently the primary provider exposing a NAT-PMP gateway on its WireGuard tunnels, the script works with any VPN service that offers the same NAT-PMP interface—just point `NATPMP_GATEWAY` at the provider’s gateway if it can’t be auto-detected.

## Features

- 🔄 Automatically refreshes ProtonVPN / RFC-6886 NAT-PMP mappings (`NATPMP_LIFETIME=120`, adaptive `CHECK_INTERVAL=25`) with wall-clock elapsed compensation
- ⚡ Zero-downtime hot port rebinding via qBittorrent WebUI API (`QBITTORRENT_RESTART_COMMAND` used strictly as an emergency fallback if hot-apply verification fails)
- 🩹 Automatic UDP/TCP port-split self-healing (hinted TCP resync followed by lease release and symmetric re-request) plus transient UDP packet-loss retries
- 📡 Updates qBittorrent via Web API with optional credentials
- 📝 Comprehensive logging with automatic 5 MiB `port-sync.log` rotation
- 🔧 Includes WireGuard port detection as a fallback for manual force operations
- ⚙️ Ready-to-run systemd service that maintains ProtonVPN NAT-PMP leases
- 🛡️ Automated offline unit test suite (`tests/test_port_sync.sh`)
- 🔍 Status checking and manual override options

## Requirements

- Debian/Ubuntu Linux (or similar)
- **Bash shell** (not sh - scripts use bash-specific features)
- ProtonVPN WireGuard connection active (WireGuard tools installed)
- qBittorrent with Web UI enabled (supply credentials via env if required)
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
- Offer to install/refresh the bundled systemd service (continuous ~24–25-second adaptive renewal loop)
- Provide a manual option if you prefer to run the script yourself

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

## Operation Modes

### Systemd Service (Recommended)
- Refreshes the ProtonVPN NAT-PMP lease every ~24–25 seconds (`CHECK_INTERVAL=25`, adapting automatically to `<=40%` of the gateway's granted lifetime)
- Automatically hot-updates qBittorrent via WebUI API without restarting the service
- Provides journaled logs and simple management commands via `service-manager.sh`

```bash
# Install and start the service (installer does this interactively)
./service-manager.sh install

# Useful shortcuts
./service-manager.sh status     # Check status
./service-manager.sh logs       # Tail recent logs
./service-manager.sh restart    # Restart service
./service-manager.sh uninstall  # Remove service
```

### Manual Operation
Run the script directly if you prefer to supervise it yourself:

```bash
./port-sync.sh           # Normal sync
./port-sync.sh --check   # Check status only
./port-sync.sh --force   # Force qBittorrent to match the WireGuard listen port (fallback)
./port-sync.sh --daemon  # Run as daemon (~24-25s adaptive renewal intervals)
```

### 2. Configure qBittorrent Web UI (if using manual setup)

Ensure qBittorrent Web UI is enabled and accessible:

1. Open qBittorrent
2. Go to **Tools** → **Options** → **Web UI**
3. Enable **Web User Interface (Remote control)**
4. Set **Port** to `8080` (or edit script if different)
5. **Disable authentication** or set to **Bypass authentication for clients on localhost** (alternatively, set `QBITTORRENT_USERNAME`/`QBITTORRENT_PASSWORD` when running the script)
6. Click **OK** and restart qBittorrent

### 3. Configure ProtonVPN WireGuard interface (if needed)

The script uses your WireGuard interface to derive the NAT-PMP gateway. If your ProtonVPN interface is not `wg0`, export `WG_INTERFACE` before running the script or add it to the service environment:

```bash
WG_INTERFACE="wg-vpn" ./port-sync.sh --check
```

**Note:** The installation script will prompt for your interface and write the value to the service configuration automatically.

### 4. Test the Script

```bash
# Check current status
./port-sync.sh --check

# Run a manual sync
./port-sync.sh

# Force update qBittorrent to match WireGuard
# Force qBittorrent to match the WireGuard listen port (fallback)
./port-sync.sh --force
```

### 5. Alternative Setup (if not using installer)

If you prefer to skip the installer, download the helper scripts and invoke the service manager directly:

```bash
# Download latest helpers
curl -fsSL -O https://raw.githubusercontent.com/Simon-CR/qbittorrent-wireguard-pmp/main/port-sync.sh
curl -fsSL -O https://raw.githubusercontent.com/Simon-CR/qbittorrent-wireguard-pmp/main/service-manager.sh
curl -fsSL -O https://raw.githubusercontent.com/Simon-CR/qbittorrent-wireguard-pmp/main/qbittorrent-wireguard-sync.service
chmod +x port-sync.sh service-manager.sh

# Install the service
sudo ./service-manager.sh install
```

## Usage

### Command Line Options

```bash
# Normal operation
./port-sync.sh

# Check current status without making changes
./port-sync.sh --check

# Force qBittorrent to match the WireGuard listen port (fallback)
./port-sync.sh --force

# Run as daemon (continuous monitoring ~24-25 seconds)
./port-sync.sh --daemon

# Show detailed debugging information
./port-sync.sh --debug

# Show help
./port-sync.sh --help

### Logging & Troubleshooting

- Logs are written to `port-sync.log` in the project directory and to the systemd journal when running as a service.
- Enable verbose NAT-PMP diagnostics by setting `DEBUG=1`:

```bash
DEBUG=1 ./port-sync.sh --check
DEBUG=1 ./port-sync.sh --daemon
```

- Adjust debug payload length with `DEBUG_PAYLOAD_PREVIEW` if large responses are being truncated.

- For service logs:

```bash
journalctl -u qbittorrent-wireguard-sync -f
```

- See the [Configuration](#configuration) section for the complete list of environment overrides (`QBITTORRENT_*`, `WG_INTERFACE`, `NATPMP_GATEWAY`, etc.).
```

### Output Examples

**Normal operation:**
```bash
$ ./port-sync.sh
[2025-09-23 10:15:30] Starting port sync check...
[2025-09-23 10:15:30] NAT-PMP mapped public port: 35476
[2025-09-23 10:15:30] Detected ProtonVPN NAT-PMP port: 35476
[2025-09-23 10:15:30] Current qBittorrent port: 48392
[2025-09-23 10:15:30] Port mismatch detected - updating qBittorrent from 48392 to 35476
[2025-09-23 10:15:31] Updated qBittorrent port to: 35476
[2025-09-23 10:15:32] Port update verified: qBittorrent is now using port 35476
[2025-09-23 10:15:31] Port sync check completed successfully
```

**Status check:**
```bash
$ ./port-sync.sh --check
WireGuard port: 51820
qBittorrent port: 35476
```

> The `--check` output still shows the WireGuard listen port for diagnostics, but the NAT-PMP forwarded port is the authoritative value used for syncing.

## Configuration

Most behavior is controlled through environment variables. Defaults are shown below:

| Variable | Default | Description |
| --- | --- | --- |
| `WG_INTERFACE` | `wg0` | WireGuard interface to monitor |
| `QBITTORRENT_HOST` | `localhost` | qBittorrent Web UI hostname or IP |
| `QBITTORRENT_PORT` / `QB_PORT` | `8080` | qBittorrent Web UI port |
| `QBITTORRENT_USERNAME` / `QB_USERNAME` | _(empty)_ | Optional Web UI username |
| `QBITTORRENT_PASSWORD` / `QB_PASSWORD` | _(empty)_ | Optional Web UI password |
| `NATPMP_GATEWAY` | _(auto-detect)_ | Override ProtonVPN NAT-PMP gateway IP |
| `NATPMP_LIFETIME` | `120` | Requested NAT-PMP lease lifetime in seconds passed to `natpmpc` |
| `NATPMP_RETRIES` | `3` | Maximum `natpmpc` attempts per protocol on transient UDP packet loss |
| `CHECK_INTERVAL` | `25` | Base renewal target interval in seconds (adapts to `min(CHECK_INTERVAL, max(15, granted_lifetime * 2 / 5))`) |
| `QBITTORRENT_RESTART_COMMAND` / `QBT_RESTART_COMMAND` | _(empty)_ | Emergency fallback command to restart qBittorrent **only** if WebUI API hot-apply verification fails |
| `QBITTORRENT_RESTART_WAIT` | `5` | Seconds to wait after fallback restart before verification |
| `QBITTORRENT_FORCE_RESTART` | `0` | Set to `1` to force a service restart on every port change instead of hot API apply |
| `QBITTORRENT_RESTART_ON_FAILURE` | `1` | Invoke `QBITTORRENT_RESTART_COMMAND` automatically when hot-apply verification fails |
| `LOG_MAX_BYTES` | `5242880` | Rotate `port-sync.log` to `port-sync.log.1` when size exceeds limit (5 MiB) |
| `DEBUG` | `0` | Enable extra logging when set to `1` |
| `DEBUG_PAYLOAD_PREVIEW` | `512` | Max characters printed for debug payloads |
| `PORT_SYNC_TMPDIR` | `./tmp` | Directory for temporary curl/state files |

### Examples

```bash
# Run once with fallback restart command and debug logging
QBITTORRENT_RESTART_COMMAND="systemctl restart qbittorrent-nox" \
DEBUG=1 ./port-sync.sh --force

# Override NAT-PMP gateway and credentials when starting the daemon
NATPMP_GATEWAY=10.2.0.1 \
QBITTORRENT_USERNAME=admin \
QBITTORRENT_PASSWORD=secret \
./port-sync.sh --daemon
```

When using the systemd unit, export these variables in `/etc/default/qbittorrent-wireguard-sync` (created by the installer) or edit the unit file to set `Environment=` entries.

## How It Works

1. **Resilient NAT-PMP Lease Renewal & Self-Healing**: Every cycle (`CHECK_INTERVAL=25`, or `24s` for ProtonVPN's 60-second granted lifetime), the script refreshes UDP and TCP mappings via `natpmpc` (`NATPMP_LIFETIME=120`) with per-protocol retries (`NATPMP_RETRIES=3`). If UDP and TCP mapped ports ever diverge, it automatically attempts a hinted TCP resync and, if still split, releases both mappings (`lifetime 0`) and immediately re-requests a fresh symmetric port pair.

2. **Wall-Clock Elapsed Compensation**: Daemon cycles measure wall-clock execution time (`elapsed`) and sleep `target_interval - elapsed` (clamped to `>=5s`). If any slow API or recovery operation takes `>=20s`, the daemon immediately refreshes the NAT-PMP lease before sleeping so a 60-second lease never expires between cycles.

3. **Zero-Downtime Hot Port Rebind**: When a port mismatch is detected, `set_qbittorrent_port()` updates qBittorrent dynamically via `POST /api/v2/app/setPreferences` (`{"listen_port": <port>}`) and verifies the new port in `<0.5s` with **zero service restarts**.

4. **Emergency Fallback Restart**: `QBITTORRENT_RESTART_COMMAND` is invoked **only** if hot-reload verification fails after retries (or if `QBITTORRENT_FORCE_RESTART=1` is explicitly set).

5. **Logging & Rotation**: Every step logs to `port-sync.log` (automatically rotated to `port-sync.log.1` at 5 MiB) and the systemd journal in daemon mode.

> Need to align qBittorrent with the WireGuard listen port directly? Use `./port-sync.sh --force`, which still leverages the legacy WireGuard detection helpers.

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

**WireGuard port not detected (fallback mode):**
```bash
ERROR: Could not determine WireGuard listening port
```
- This only affects the legacy `--force` path; normal NAT-PMP syncing continues without it.
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
# Test WireGuard port detection (legacy force mode)
wg show wg0 listen-port

# Test qBittorrent API access
curl http://localhost:8080/api/v2/app/version

# Test port retrieval
curl http://localhost:8080/api/v2/app/preferences | grep listen_port

# Test the script with debug mode
bash port-sync.sh --debug
# Run the offline automated unit test suite
bash tests/test_port_sync.sh
```

## File Structure

```
qbittorrent-wireguard-pmp/
├── port-sync.sh                       # Main NAT-PMP sync & daemon script
├── qbittorrent-wireguard-sync.service # Systemd unit template
├── service-manager.sh                 # Systemd unit installer/helper
├── install.sh                         # Interactive setup & updater
├── tests/test_port_sync.sh            # Offline automated mock test suite
├── .gitattributes                     # Enforces LF line endings on scripts/units
└── README.md                          # Documentation
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