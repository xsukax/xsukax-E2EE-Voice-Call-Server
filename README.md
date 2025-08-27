# xsukax E2E Encrypted Voice Call Server

A secure, end-to-end encrypted voice communication server with group-based access control, designed for private conversations with robust security protections.

## 🔒 Security & Privacy Overview

This server implements a multi-layered security architecture that ensures:

- **True End-to-End Encryption**: Audio is encrypted on the client side before transmission using AES-GCM with keys derived via ECDH P-256
- **Forward Secrecy**: Each call generates unique ephemeral keys that are never reused
- **Group Isolation**: Users can only communicate within their designated groups
- **Origin Security**: SSL/TLS encryption between all components (browser ↔ Cloudflare ↔ origin server)
- **Privacy by Design**: No audio recording, minimal data retention, and ephemeral user sessions

## 🛡️ Security Layers

### 1. Transport Layer Security
- **HTTPS/WSS Encryption**: All communications use TLS 1.2+ encryption
- **Certificate Pinning**: Self-signed certificates for origin validation
- **Cloudflare Integration**: Designed to work with Cloudflare's security features

### 2. Application Layer Encryption
- **Key Exchange**: ECDH P-256 for perfect forward secrecy
- **Audio Encryption**: AES-GCM 256-bit encryption for audio data
- **Client-Side Crypto**: All encryption/decryption happens in the browser
- **Ephemeral Keys**: Unique session keys for each call

### 3. Access Control
- **Group-Based Isolation**: Users can only see and call users in their same group
- **URL-Based Groups**: Group names are sanitized and validated
- **Session Management**: Unique 6-character user IDs for each session
- **Call State Validation**: Comprehensive call state checking prevents unauthorized actions

### 4. Privacy Protections
- **No Persistent Storage**: No audio recordings or conversation logs
- **Ephemeral Data**: User information exists only during active sessions
- **Earpiece Audio**: Audio plays at 20% volume through earpiece only
- **Screen Wake Protection**: Aggressive screen wake maintenance during calls

### 5. Network Security
- **Firewall Configuration**: Automatic firewall rules for HTTPS traffic
- **Port Security**: Only essential ports are opened (SSH, HTTPS)
- **Service Isolation**: Dedicated system user with minimal privileges

## 📋 Prerequisites

### System Requirements
- Ubuntu 20.04+ or CentOS 8+ (other Linux distributions may work)
- Python 3.8+
- 1GB RAM minimum, 2GB recommended
- CPU with AES-NI support for optimal encryption performance

### Network Requirements
- Open port 22000 (HTTPS) for the voice server
- Domain name with DNS configured
- Cloudflare account (recommended for additional security)

## 🚀 Installation Guide

### Automated Installation (Recommended)

1. **Download the installation script**:
```bash
curl -O https://raw.githubusercontent.com/your-repo/voice-server/main/install.sh
```

2. **Make the script executable**:
```bash
chmod +x install.sh
```

3. **Run as root**:
```bash
sudo ./install.sh
```

### Manual Installation

1. **Install system dependencies**:
```bash
# Ubuntu/Debian
sudo apt update && sudo apt install -y python3 python3-pip python3-venv curl ufw openssl

# CentOS/RHEL
sudo yum update -y && sudo yum install -y python3 python3-pip curl firewalld openssl
```

2. **Create service user**:
```bash
sudo useradd -r -s /bin/false -d /opt/voice-server voiceserver
```

3. **Create installation directory**:
```bash
sudo mkdir -p /opt/voice-server/app
sudo chown voiceserver:voiceserver /opt/voice-server
```

4. **Set up Python environment**:
```bash
cd /opt/voice-server
sudo -u voiceserver python3 -m venv venv
sudo -u voiceserver source venv/bin/activate
sudo -u voiceserver pip install Flask==3.0.0 Flask-SocketIO==5.3.6 eventlet==0.33.3
```

5. **Create server configuration**:
Copy the provided `server.py` to `/opt/voice-server/app/server.py`

6. **Generate SSL certificates**:
```bash
cd /opt/voice-server
sudo -u voiceserver openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
    -keyout server.key -out server.crt -subj "/CN=localhost"
sudo chmod 600 server.key
sudo chmod 644 server.crt
```

7. **Create systemd service**:
Create `/etc/systemd/system/voice-server.service` with the provided content

8. **Configure firewall**:
```bash
# Ubuntu/Debian
sudo ufw allow ssh
sudo ufw allow 22000/tcp
sudo ufw enable

# CentOS/RHEL
sudo firewall-cmd --permanent --add-port=22000/tcp
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --reload
```

9. **Start the service**:
```bash
sudo systemctl daemon-reload
sudo systemctl enable voice-server
sudo systemctl start voice-server
```

## 🌐 Cloudflare Configuration

### Tunnel Setup
1. Create a Cloudflare Tunnel in your Zero Trust dashboard
2. Configure the tunnel to point to `https://localhost:22000`
3. Set up your public hostname (e.g., `voice.yourdomain.com`)

### Security Settings
1. **SSL/TLS Encryption Mode**: Set to "Full (Strict)"
2. **Always Use HTTPS**: Enable
3. **TLS Settings**: Disable TLS verification (for self-signed cert)
4. **HTTP Settings**: Disable chunked encoding

### Additional Security
1. **WAF Rules**: Configure appropriate Web Application Firewall rules
2. **Access Policies**: Set up authentication if needed
3. **DDoS Protection**: Enable Cloudflare's DDoS mitigation

## 🏷️ Group Management

### Creating Groups
Groups are created automatically via URL访问:
- `https://voice.example.com/work` → Creates "work" group
- `https://voice.example.com/family` → Creates "family" group
- `https://voice.example.com/friends` → Creates "friends" group

### Group Security
- **Name Sanitization**: Group names are sanitized (alphanumeric, hyphens, underscores only)
- **Length Limits**: Group names truncated to 20 characters
- **Case Insensitive**: Group names are converted to lowercase
- **Isolation**: Complete separation between different groups

### Sharing Groups
1. Visit your group URL (e.g., `https://voice.example.com/mygroup`)
2. Click the "Group Info" section
3. This copies both the group URL and your user ID
4. Share via secure messaging apps (WhatsApp, Telegram, Signal)

## 📱 Usage Guide

### Joining a Call
1. **Access the group**: Visit your group URL
2. **Get your ID**: Note your 6-character user ID
3. **See online users**: View other users in your group
4. **Initiate call**: Click "Private Call" next to any user

### During a Call
- **Earpiece Audio**: Audio plays at 20% volume through earpiece only
- **Screen Wake**: Screen stays awake automatically during calls
- **Encryption Status**: Visual indicator shows encryption status
- **Mute Control**: Microphone can be muted during calls

### Security Indicators
- 🔒 **Encryption Active**: End-to-end encryption is established
- 📱 **Earpiece Mode**: Audio routing through private earpiece
- 🔓 **Screen Wake**: Screen wake protection active
- 🟢 **Online Status**: Connection status indicator

## 🔧 Troubleshooting

### Common Issues

**Audio not working:**
- Check browser microphone permissions
- Ensure HTTPS is properly configured
- Verify Cloudflare tunnel is active

**Screen wake not working:**
- Check browser support for Wake Lock API
- iOS may have limitations on background audio

**Connection issues:**
- Verify port 22000 is open and accessible
- Check Cloudflare tunnel configuration
- Validate SSL certificate setup

### Logs and Monitoring

**View service logs:**
```bash
journalctl -u voice-server -f
```

**Check service status:**
```bash
systemctl status voice-server
```

**Test SSL connection:**
```bash
openssl s_client -connect localhost:22000
```

### Performance Issues

**High CPU usage:**
- Ensure AES-NI is available on the CPU
- Consider upgrading server resources for large groups

**Audio quality problems:**
- Check network latency between users and Cloudflare
- Verify sufficient bandwidth is available

## 🚨 Security Best Practices

### Deployment Recommendations
1. **Regular Updates**: Keep the OS and Python dependencies updated
2. **Network Segmentation**: Isolate the voice server in its own network segment
3. **Monitoring**: Implement comprehensive logging and monitoring
4. **Backups**: Regularly backup SSL certificates and configuration

### Cloudflare Security
1. **WAF Rules**: Implement appropriate Web Application Firewall rules
2. **Rate Limiting**: Configure rate limiting to prevent abuse
3. **Bot Protection**: Enable bot management features
4. **Access Policies**: Use Cloudflare Access for additional authentication

### Client-Side Security
1. **Browser Updates**: Ensure clients use updated browsers
2. **Network Security**: Advise users to avoid public Wi-Fi for sensitive calls
3. **Session Management**: Encourage users to refresh for new session IDs periodically

## 🔄 Maintenance

### Updating the Server
1. Stop the service: `systemctl stop voice-server`
2. Update the `server.py` file
3. Restart the service: `systemctl start voice-server`

### Certificate Renewal
SSL certificates are valid for 365 days. To renew:
```bash
cd /opt/voice-server
sudo -u voiceserver openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
    -keyout server.key -out server.crt -subj "/CN=localhost"
sudo systemctl restart voice-server
```

### Monitoring Health
Set up monitoring for:
- Service availability (port 22000)
- CPU and memory usage
- Network bandwidth
- Active calls and groups

## 📞 Support

For general support and troubleshooting, check:
- Service logs: `journalctl -u voice-server -f`
- Network connectivity: `telnet yourdomain.com 22000`
- SSL certificate: `openssl s_client -connect yourdomain.com:22000`

## 📄 License

This project is licensed under the GNU General Public License v3.0 - see the LICENSE file for details.

## 🙏 Acknowledgments

- Flask and Flask-SocketIO teams for the excellent web framework
- Cloudflare for security and performance enhancements
- WebRTC and modern browser APIs for real-time communication capabilities

---

**Important**: This software is designed for secure communications but should be regularly audited for security vulnerabilities. Always keep the system and dependencies updated to the latest versions.
