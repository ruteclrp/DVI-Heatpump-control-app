# Tunnel URL Discovery Feature

## Overview

This app now includes automatic tunnel URL discovery to handle situations where the trycloudflare tunnel needs to be recreated. When connected to the home network, the app can fetch the latest tunnel URL directly from the bridge.

## How It Works

### 1. **Automatic Discovery During mDNS**
When the app discovers the bridge on the local network via mDNS:
- It reads the tunnel URL from the TXT record (existing behavior)
- It also makes an HTTP request to fetch the latest tunnel URL from the bridge
- This ensures the app always has the most up-to-date tunnel URL

### 2. **Manual Refresh Button**
When connected to the home network:
- An "Update Tunnel URL" button appears in the UI
- Users can click it to manually fetch the latest tunnel URL from the bridge
- Useful when the tunnel has been recreated and you want to update immediately

### 3. **Automatic Background Refresh**
The app can automatically refresh the tunnel URL when:
- Connected to the home network
- Network transitions occur

## Bridge Requirements

The bridge (Raspberry Pi) must expose an HTTP endpoint that returns the current tunnel URL:

### Endpoint: `/api/tunnel`

**Method:** GET

**Response Format:**
```json
{
  "tunnel_url": "https://example.trycloudflare.com"
}
```

**Status Codes:**
- `200 OK` - Tunnel URL is available
- `503 Service Unavailable` - Tunnel is currently down or being recreated

### Example Implementation (Python/Flask)

```python
from flask import Flask, jsonify
import subprocess
import re

app = Flask(__name__)

# Global variable to store current tunnel URL
current_tunnel_url = None

def get_current_tunnel_url():
    """
    Extract the tunnel URL from the running cloudflared process
    or from a status file
    """
    # Method 1: Read from a status file that cloudflared writes to
    try:
        with open('/var/run/cloudflared/tunnel_url.txt', 'r') as f:
            return f.read().strip()
    except FileNotFoundError:
        pass
    
    # Method 2: Parse from cloudflared logs or process output
    # (Implementation depends on how you run cloudflared)
    
    return current_tunnel_url

@app.route('/api/tunnel', methods=['GET'])
def get_tunnel():
    """Return the current tunnel URL"""
    tunnel_url = get_current_tunnel_url()
    
    if tunnel_url:
        return jsonify({
            'tunnel_url': tunnel_url,
            'status': 'active'
        }), 200
    else:
        return jsonify({
            'status': 'unavailable',
            'message': 'Tunnel is currently being established'
        }), 503

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
```

### Bridge Tunnel Monitoring Script

You can also add a monitoring script that automatically updates the tunnel URL file:

```bash
#!/bin/bash
# /usr/local/bin/monitor-tunnel.sh

TUNNEL_URL_FILE="/var/run/cloudflared/tunnel_url.txt"
LOG_FILE="/var/log/cloudflared.log"

# Monitor cloudflared log for tunnel URL
tail -F "$LOG_FILE" | while read line; do
    # Extract trycloudflare URL from log line
    if [[ $line =~ (https://[a-z0-9-]+\.trycloudflare\.com) ]]; then
        TUNNEL_URL="${BASH_REMATCH[1]}"
        echo "$TUNNEL_URL" > "$TUNNEL_URL_FILE"
        echo "Updated tunnel URL: $TUNNEL_URL"
        
        # Optionally update mDNS TXT record
        # avahi-publish -s "DVI-Bridge" _dvi-bridge._tcp 5000 "tunnel_url=$TUNNEL_URL" &
    fi
done
```

## Usage

### For Users

1. **First Time Setup:**
   - Scan QR code or manually enter bridge address
   - App automatically discovers and saves tunnel URL

2. **When Tunnel Changes:**
   - If on home network: Click "Update Tunnel URL" button
   - If away: Scan new QR code with updated tunnel URL

3. **Automatic Handling:**
   - App automatically fetches new tunnel URL when you return home
   - Network switching between WiFi/cellular handles URL selection

### For Bridge Setup

1. **Implement the `/api/tunnel` endpoint** on your bridge web server
2. **Monitor cloudflared** and keep the tunnel URL updated
3. **Optional:** Update mDNS TXT record when tunnel changes
4. **Optional:** Generate new QR codes automatically when tunnel changes

## Benefits

- ✅ No need to manually scan QR codes every time tunnel changes
- ✅ Automatic update when on home network
- ✅ Seamless experience for users
- ✅ Bridge can recreate tunnel as needed without user intervention
- ✅ Works alongside existing QR code scanning for remote setup

## Technical Details

### App Implementation

**File:** `BridgeConfig.swift`

**Key Methods:**
- `fetchTunnelURLFromBridge(bridgeURL:completion:)` - Fetches tunnel URL from bridge via HTTP
- `refreshTunnelURLIfLocal()` - Public method to trigger refresh when on local network
- `netServiceDidResolveAddress(_:)` - Automatically fetches tunnel URL during mDNS discovery

**Timeout:** 5 seconds for HTTP requests
**Endpoint:** `/api/tunnel`
**Expected Response:** JSON with `tunnel_url` field

### Network Detection

The app uses:
- mDNS for local bridge discovery
- Network monitoring to detect WiFi/cellular switches
- Network scope detection to identify home network
- Health checks (when appropriate) to verify connectivity

### State Management

- Tunnel URL saved in UserDefaults: `savedTunnelURL`
- Bridge name saved: `savedBridgeName`
- Home network scope saved: `homeNetworkScope`
- All updates trigger UI refresh via `@Published` properties
