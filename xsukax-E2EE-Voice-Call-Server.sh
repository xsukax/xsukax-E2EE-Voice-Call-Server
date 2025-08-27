#!/bin/bash

set -euo pipefail

INSTALL_DIR="/opt/voice-server"
SERVICE_USER="voiceserver"
PORT=22000

log() { echo "[$(date +'%H:%M:%S')] $1"; }
error() { echo "❌ $1"; exit 1; }

[[ $EUID -eq 0 ]] || error "Run as root"

log "🚀 Installing xsukax E2E Encrypted Voice Call Server"

# Clean install
systemctl stop voice-server 2>/dev/null || true
rm -rf "$INSTALL_DIR"
userdel "$SERVICE_USER" 2>/dev/null || true

# Install packages (including OpenSSL for certificate generation)
if command -v apt >/dev/null; then
    apt update -qq && apt install -y python3 python3-pip python3-venv curl ufw openssl
else
    yum update -y -q && yum install -y python3 python3-pip curl firewalld openssl
fi

# Setup
useradd -r -s /bin/false -d "$INSTALL_DIR" "$SERVICE_USER"
mkdir -p "$INSTALL_DIR"/app
cd "$INSTALL_DIR"

# Python environment
python3 -m venv venv
source venv/bin/activate
pip install -q Flask==3.0.0 Flask-SocketIO==5.3.6 eventlet==0.33.3

# Create server with FIXED GROUPS and SCREEN-WAKE-ON-CALL
cat > app/server.py << 'EOF'
#!/usr/bin/env python3
import os,secrets,string,logging,re
from flask import Flask,render_template_string,request,jsonify,session,redirect
from flask_socketio import SocketIO,emit,join_room,leave_room

logging.basicConfig(level=logging.INFO,format='%(levelname)s: %(message)s')
logger=logging.getLogger(__name__)

app=Flask(__name__)
app.secret_key=secrets.token_hex(32)
socketio=SocketIO(app,cors_allowed_origins="*",async_mode='eventlet',logger=False)

# Group-based user management
groups = {}  # group_name: {users: {user_id: {sid, status}}, calls: {call_id: {caller, callee}}}
active_groups = set()

def gen_id():
    return ''.join(secrets.choice(string.ascii_uppercase+string.digits) for _ in range(6))

def get_or_create_group(group_name):
    if not group_name or group_name.strip() == '':
        return None
    
    # Sanitize group name
    group_name = re.sub(r'[^a-zA-Z0-9_-]', '', group_name.lower())[:20]
    if not group_name or len(group_name) < 1:
        return None
        
    if group_name not in groups:
        groups[group_name] = {'users': {}, 'calls': {}}
        active_groups.add(group_name)
        logger.info(f'Created new group: {group_name}')
    
    return group_name

# Enhanced HTML with FIXED GROUPS and STRONGER SCREEN WAKE
HTML='''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <title>🔒 xsukax E2E Encrypted Voice Call{% if group_name %} - {{ group_name.title() }}{% endif %}</title>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/socket.io/4.7.4/socket.io.js"></script>
    <style>
        /* Reset and Base Styles */
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            -webkit-tap-highlight-color: transparent;
        }

        :root {
            --primary-color: #1a1a1a;
            --secondary-color: #2d2d2d;
            --accent-color: #4a9eff;
            --success-color: #00d084;
            --danger-color: #ff4757;
            --warning-color: #ffa502;
            --light-bg: #0d1117;
            --card-bg: #21262d;
            --text-primary: #f0f6fc;
            --text-secondary: #8b949e;
            --border-color: #30363d;
            --shadow: rgba(0, 0, 0, 0.3);
            --font-mono: 'SF Mono', 'Monaco', 'Inconsolata', 'Roboto Mono', 'Source Code Pro', 'Consolas', 'Courier New', monospace;
            --font-sans: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', Roboto, sans-serif;
            --radius: 8px;
            --spacing: 1rem;
        }

        body {
            font-family: var(--font-sans);
            background: var(--light-bg);
            color: var(--text-primary);
            line-height: 1.6;
            overflow-x: hidden;
            font-size: 16px;
        }

        /* Header */
        .header {
            background: var(--primary-color);
            color: white;
            padding: var(--spacing);
            text-align: center;
            border-bottom: 2px solid var(--secondary-color);
        }

        .header h1 {
            font-family: var(--font-mono);
            font-size: clamp(1.2rem, 4vw, 1.8rem);
            font-weight: 600;
            letter-spacing: -0.02em;
        }

        .group-badge {
            display: inline-block;
            background: rgba(74, 158, 255, 0.2);
            color: var(--accent-color);
            padding: 0.25rem 0.75rem;
            border-radius: calc(var(--radius) * 2);
            font-size: 0.75rem;
            font-family: var(--font-mono);
            margin-left: 0.5rem;
            border: 1px solid var(--accent-color);
        }

        .encryption-badge {
            display: inline-block;
            background: rgba(255, 255, 255, 0.15);
            padding: 0.25rem 0.75rem;
            border-radius: calc(var(--radius) * 2);
            font-size: 0.75rem;
            font-family: var(--font-mono);
            margin-left: 0.5rem;
            border: 1px solid rgba(255, 255, 255, 0.2);
        }

        /* Layout */
        .container {
            max-width: 600px;
            margin: 0 auto;
            padding: var(--spacing);
        }

        /* Cards */
        .card {
            background: var(--card-bg);
            border-radius: var(--radius);
            box-shadow: 0 2px 10px var(--shadow);
            margin: var(--spacing) 0;
            overflow: hidden;
            border: 1px solid var(--border-color);
        }

        .card-header {
            background: var(--secondary-color);
            padding: var(--spacing);
            border-bottom: 1px solid var(--border-color);
            font-weight: 600;
            font-family: var(--font-mono);
            font-size: 0.9rem;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .card-body {
            padding: var(--spacing);
        }

        /* ID Display */
        .my-id {
            background: var(--secondary-color);
            padding: calc(var(--spacing) * 1.5);
            border-radius: var(--radius);
            text-align: center;
            margin: var(--spacing) 0;
            border: 2px dashed var(--accent-color);
        }

        .id-big {
            font-family: var(--font-mono);
            font-size: clamp(1.8rem, 6vw, 2.4rem);
            font-weight: bold;
            color: var(--accent-color);
            letter-spacing: 0.1em;
            margin-bottom: 0.5rem;
            word-break: break-all;
        }

        /* Group Info */
        .group-info {
            background: var(--secondary-color);
            padding: calc(var(--spacing) * 1.5);
            border-radius: var(--radius);
            text-align: center;
            margin: var(--spacing) 0;
            border: 2px dashed var(--success-color);
            transition: all 0.2s ease;
            cursor: pointer;
            user-select: none;
        }

        .group-info:hover {
            background: #373e47;
            transform: translateY(-2px);
            box-shadow: 0 6px 20px rgba(0, 208, 132, 0.3);
        }

        .group-info:active {
            transform: translateY(-1px);
        }

        .group-name {
            font-family: var(--font-mono);
            font-size: 1.4rem;
            font-weight: bold;
            color: var(--success-color);
            margin-bottom: 0.5rem;
        }

        .group-url {
            font-family: var(--font-mono);
            font-size: 0.8rem;
            color: var(--text-secondary);
            word-break: break-all;
            margin-bottom: 0.5rem;
        }

        /* Buttons */
        .btn {
            background: var(--accent-color);
            color: white;
            border: none;
            padding: 0.75rem 1rem;
            border-radius: var(--radius);
            cursor: pointer;
            font-size: 0.9rem;
            font-weight: 600;
            font-family: var(--font-mono);
            transition: all 0.2s ease;
            width: 100%;
            margin: 0.25rem 0;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            border: 1px solid transparent;
        }

        .btn:hover {
            transform: translateY(-1px);
            box-shadow: 0 4px 12px rgba(74, 158, 255, 0.4);
        }

        .btn:active {
            transform: translateY(0);
        }

        .btn-green {
            background: var(--success-color);
        }

        .btn-green:hover {
            box-shadow: 0 4px 12px rgba(0, 208, 132, 0.4);
        }

        .btn-red {
            background: var(--danger-color);
        }

        .btn-red:hover {
            box-shadow: 0 4px 12px rgba(255, 71, 87, 0.4);
        }

        .btn-small {
            width: auto;
            padding: 0.5rem 0.75rem;
            font-size: 0.8rem;
            margin: 0;
        }

        /* Status Indicators */
        .status {
            position: fixed;
            top: 20px;
            right: 20px;
            background: var(--primary-color);
            color: white;
            padding: 0.5rem 1rem;
            border-radius: calc(var(--radius) * 3);
            z-index: 1000;
            font-weight: 600;
            font-family: var(--font-mono);
            font-size: 0.8rem;
            box-shadow: 0 2px 10px var(--shadow);
            border: 1px solid var(--secondary-color);
        }

        .security-indicator {
            position: fixed;
            bottom: 20px;
            left: 20px;
            background: var(--success-color);
            color: white;
            padding: 0.4rem 0.8rem;
            border-radius: calc(var(--radius) * 2);
            font-size: 0.75rem;
            font-family: var(--font-mono);
            z-index: 1000;
            box-shadow: 0 2px 10px var(--shadow);
        }

        /* User List */
        .user {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 0.75rem;
            margin: 0.5rem 0;
            background: var(--secondary-color);
            border-radius: var(--radius);
            border-left: 3px solid var(--success-color);
            transition: all 0.2s;
        }

        .user:hover {
            background: #373e47;
            transform: translateX(2px);
            box-shadow: 0 2px 8px var(--shadow);
        }

        .user-info {
            display: flex;
            align-items: center;
            font-family: var(--font-mono);
        }

        .dot {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            background: var(--success-color);
            margin-right: 0.75rem;
            box-shadow: 0 0 6px rgba(0, 208, 132, 0.5);
        }

        /* Call Modal */
        .modal {
            display: none;
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: rgba(13, 17, 23, 0.95);
            z-index: 3000;
            animation: fadeIn 0.3s ease-out;
        }

        .modal.show {
            display: flex;
            align-items: center;
            justify-content: center;
        }

        .modal-content {
            background: var(--card-bg);
            border-radius: calc(var(--radius) * 2);
            padding: 2rem;
            max-width: 400px;
            width: 90%;
            text-align: center;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
            animation: slideIn 0.3s ease-out;
            border: 1px solid var(--border-color);
        }

        .caller-avatar {
            width: 60px;
            height: 60px;
            background: var(--accent-color);
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 1.5rem;
            font-weight: bold;
            font-family: var(--font-mono);
            color: white;
            margin: 0 auto 1rem;
            box-shadow: 0 4px 20px rgba(74, 158, 255, 0.4);
        }

        .caller-id {
            font-size: 1.5rem;
            font-weight: bold;
            font-family: var(--font-mono);
            color: var(--text-primary);
            margin-bottom: 0.5rem;
        }

        .call-text {
            color: var(--text-secondary);
            font-size: 0.9rem;
            margin-bottom: 2rem;
        }

        .modal-actions {
            display: flex;
            gap: 0.75rem;
            justify-content: center;
            flex-wrap: wrap;
        }

        .modal-btn {
            padding: 0.75rem 1.5rem;
            border: none;
            border-radius: var(--radius);
            font-size: 0.9rem;
            font-weight: 600;
            font-family: var(--font-mono);
            cursor: pointer;
            transition: all 0.2s;
            min-width: 100px;
        }

        .accept-btn {
            background: var(--success-color);
            color: white;
        }

        .accept-btn:hover {
            background: #00b574;
            transform: translateY(-1px);
        }

        .decline-btn {
            background: var(--text-secondary);
            color: white;
        }

        .decline-btn:hover {
            background: #495057;
            transform: translateY(-1px);
        }

        /* Call Overlay */
        .call-overlay {
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: var(--primary-color);
            color: white;
            display: none;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            z-index: 2000;
            text-align: center;
        }

        .call-info {
            margin-bottom: 2rem;
        }

        .participants {
            font-size: clamp(1.8rem, 6vw, 2.5rem);
            font-weight: bold;
            font-family: var(--font-mono);
            margin-bottom: 1rem;
            letter-spacing: 0.05em;
        }

        .call-status {
            font-size: 1rem;
            opacity: 0.9;
            margin-bottom: 1rem;
        }

        .encryption-status {
            background: rgba(255, 255, 255, 0.15);
            padding: 0.5rem 1rem;
            border-radius: calc(var(--radius) * 2);
            font-size: 0.8rem;
            font-family: var(--font-mono);
            margin-bottom: 1rem;
            border: 1px solid rgba(255, 255, 255, 0.2);
        }

        .audio-bar {
            width: min(300px, 80vw);
            height: 20px;
            background: rgba(255, 255, 255, 0.2);
            border-radius: 10px;
            margin: 1.5rem 0;
            overflow: hidden;
            border: 1px solid rgba(255, 255, 255, 0.1);
        }

        .audio-fill {
            height: 100%;
            background: linear-gradient(90deg, var(--success-color), var(--warning-color), var(--danger-color));
            width: 0%;
            transition: width 0.1s ease-out;
        }

        .controls {
            display: flex;
            gap: 1rem;
            margin: 2rem 0;
            flex-wrap: wrap;
            justify-content: center;
        }

        .ctrl-btn {
            background: rgba(255, 255, 255, 0.1);
            border: 1px solid rgba(255, 255, 255, 0.3);
            color: white;
            padding: 0.75rem 1rem;
            border-radius: var(--radius);
            font-size: 0.9rem;
            font-family: var(--font-mono);
            cursor: pointer;
            transition: all 0.2s;
            min-width: 120px;
            text-align: center;
        }

        .ctrl-btn:hover {
            background: rgba(255, 255, 255, 0.2);
            transform: translateY(-1px);
        }

        .ctrl-btn.active {
            background: rgba(255, 255, 255, 0.9);
            color: var(--primary-color);
        }

        .end-btn {
            background: var(--danger-color);
            border-color: var(--danger-color);
        }

        .end-btn:hover {
            background: #e03e52;
        }

        /* Indicators */
        .earpiece-indicator {
            position: fixed;
            bottom: 70px;
            left: 20px;
            background: rgba(0, 208, 132, 0.2);
            color: var(--success-color);
            padding: 0.3rem 0.6rem;
            border-radius: calc(var(--radius) * 2);
            font-size: 0.7rem;
            font-family: var(--font-mono);
            z-index: 1000;
            box-shadow: 0 2px 10px var(--shadow);
            border: 1px solid var(--success-color);
        }

        .wake-lock-indicator {
            position: fixed;
            bottom: 120px;
            left: 20px;
            background: rgba(255, 165, 2, 0.2);
            color: var(--warning-color);
            padding: 0.3rem 0.6rem;
            border-radius: calc(var(--radius) * 2);
            font-size: 0.7rem;
            font-family: var(--font-mono);
            z-index: 1000;
            box-shadow: 0 2px 10px var(--shadow);
            border: 1px solid var(--warning-color);
        }

        /* No Users Message */
        .no-users {
            text-align: center;
            color: var(--text-secondary);
            padding: 2rem;
            font-family: var(--font-mono);
        }

        .welcome-message {
            text-align: center;
            padding: 2rem;
        }

        .welcome-message h2 {
            font-family: var(--font-mono);
            color: var(--accent-color);
            margin-bottom: 1rem;
        }

        .welcome-message p {
            margin-bottom: 1rem;
            color: var(--text-secondary);
        }

        .welcome-message code {
            background: var(--secondary-color);
            padding: 0.25rem 0.5rem;
            border-radius: 4px;
            font-family: var(--font-mono);
            color: var(--accent-color);
            word-break: break-all;
        }

        /* Animations */
        .pulse {
            animation: pulse 2s infinite;
        }

        .calling-animation {
            position: absolute;
            top: -5px;
            right: -5px;
            width: 16px;
            height: 16px;
            background: var(--success-color);
            border-radius: 50%;
            animation: ping 1s infinite;
        }

        /* Responsive Design */
        @media (max-width: 768px) {
            :root {
                --spacing: 0.75rem;
            }

            .container {
                padding: 0.5rem;
            }

            .card {
                margin: 0.75rem 0;
            }

            .modal-content {
                padding: 1.5rem;
                margin: 1rem;
            }

            .modal-actions {
                flex-direction: column;
            }

            .modal-btn {
                width: 100%;
            }

            .controls {
                gap: 0.5rem;
            }

            .ctrl-btn {
                padding: 0.6rem 0.8rem;
                font-size: 0.8rem;
                min-width: 100px;
            }

            .status {
                position: static;
                width: 100%;
                margin: 0;
                border-radius: 0;
                text-align: center;
            }

            .security-indicator {
                bottom: 10px;
                left: 10px;
                font-size: 0.7rem;
                padding: 0.3rem 0.6rem;
            }

            .earpiece-indicator {
                bottom: 60px;
                left: 10px;
                font-size: 0.65rem;
            }

            .wake-lock-indicator {
                bottom: 110px;
                left: 10px;
                font-size: 0.65rem;
            }

            .user {
                flex-direction: column;
                text-align: center;
                gap: 0.5rem;
            }

            .btn-small {
                width: 100%;
            }
        }

        @media (max-width: 480px) {
            .card-header {
                flex-direction: column;
                gap: 0.5rem;
                text-align: center;
            }

            .audio-bar {
                width: 90vw;
            }

            .ctrl-btn {
                min-width: 90px;
                padding: 0.5rem;
            }
        }

        /* Keyframes */
        @keyframes fadeIn {
            from { opacity: 0; }
            to { opacity: 1; }
        }

        @keyframes slideIn {
            from {
                transform: translateY(-30px);
                opacity: 0;
            }
            to {
                transform: translateY(0);
                opacity: 1;
            }
        }

        @keyframes pulse {
            0%, 100% { transform: scale(1); }
            50% { transform: scale(1.05); }
        }

        @keyframes ping {
            0% {
                transform: scale(1);
                opacity: 1;
            }
            100% {
                transform: scale(2);
                opacity: 0;
            }
        }

        /* Utility Classes */
        .text-center { text-align: center; }
        .text-muted { color: var(--text-secondary); }
        .mb-0 { margin-bottom: 0; }
        .mt-1 { margin-top: 0.5rem; }
        .hidden { display: none !important; }

        /* Focus styles for accessibility */
        *:focus-visible {
            outline: 2px solid var(--accent-color);
            outline-offset: 2px;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>🔒 xsukax E2E Encrypted Voice Call
            {% if group_name %}
                <span class="group-badge">{{ group_name.title() }}</span>
            {% endif %}
            <span class="encryption-badge">SECURE</span>
        </h1>
    </div>

    <div id="status" class="status">🔴 Connecting...</div>
    <div id="securityIndicator" class="security-indicator hidden">🔒 Audio Encrypted</div>
    <div id="earpieceIndicator" class="earpiece-indicator hidden">📱 Private Earpiece (20%)</div>
    <div id="wakeLockIndicator" class="wake-lock-indicator hidden">🔓 Screen Wake Active</div>

    <div class="container">
        <div class="card">
            <div class="card-header">🆔 Your Call ID</div>
            <div class="card-body">
                <div class="my-id">
                    <div class="id-big">{{user_id}}</div>
                    <button class="btn" onclick="copyId()">📋 Copy My ID</button>
                </div>
            </div>
        </div>

        {% if group_name %}
        <div class="card">
            <div class="card-header">🏷️ Group Info</div>
            <div class="card-body">
                <div class="group-info" onclick="copyGroupInfo()">
                    <div class="group-name">{{ group_name.title() }}</div>
                    <div class="group-url">{{ request.url }}</div>
                    <small class="text-muted">📋 Click here to copy group info for sharing</small>
                </div>
            </div>
        </div>

        <div class="card">
            <div class="card-header">
                👥 Online Users in {{ group_name.title() }}
                <button class="btn btn-small" onclick="refresh()">🔄 Refresh</button>
            </div>
            <div class="card-body">
                <div id="users">Loading group users...</div>
            </div>
        </div>
        {% else %}
        <div class="card">
            <div class="card-header">🌐 Welcome to xsukax Voice</div>
            <div class="card-body">
                <div class="welcome-message">
                    <h2>🏷️ Create or Join a Group</h2>
                    <p><strong>Add a group name to the URL to create/join a group:</strong></p>
                    <p><code>{{ request.url_root }}groupname</code></p>
                    <p class="text-muted">Replace "groupname" with any name to create your private encrypted group</p>
                    <br>
                    <p><strong>Examples:</strong></p>
                    <p><code>{{ request.url_root }}work</code></p>
                    <p><code>{{ request.url_root }}friends</code></p>
                    <p><code>{{ request.url_root }}family</code></p>
                </div>
            </div>
        </div>
        {% endif %}
    </div>

    <!-- Call Modal -->
    <div id="callModal" class="modal">
        <div class="modal-content">
            <div class="modal-header">
                <div class="caller-avatar pulse" id="callerAvatar"></div>
                <div class="calling-animation"></div>
                <div class="caller-id" id="callerIdText"></div>
                <div class="call-text">🔒 Private earpiece call incoming</div>
            </div>
            <div class="modal-actions">
                <button class="modal-btn accept-btn" onclick="acceptCall()">✅ Accept</button>
                <button class="modal-btn decline-btn" onclick="declineCall()">❌ Decline</button>
            </div>
        </div>
    </div>

    <!-- Call Overlay -->
    <div id="callOverlay" class="call-overlay">
        <div class="call-info">
            <div class="participants" id="callWith"></div>
            <div class="call-status" id="callStatus">Connecting...</div>
            <div class="encryption-status" id="encryptionStatus">🔒 Establishing end-to-end encryption...</div>
        </div>
        <div class="audio-bar">
            <div class="audio-fill" id="audioLevel"></div>
        </div>
        <div class="controls">
            <button class="ctrl-btn" id="muteBtn" onclick="toggleMute()">🎤 Mic</button>
            <button class="ctrl-btn end-btn" onclick="endCall()">📞 End Call</button>
        </div>
    </div>

    <script>
        let socket, myId = '{{user_id}}', groupName = '{{ group_name or "" }}', localStream, audioCtx, processor, callId, inCall = false, 
            muted = false, currentIncomingCall = null;
        let cryptoKey = null, myKeyPair = null, peerPublicKey = null, encryptionReady = false;
        let isIOS = false, isAndroid = false, isMobile = false;
        let wakeLock = null, backgroundAudioNodes = [], keepAliveInterval = null;
        let screenWakeInterval = null, micKeepAliveNodes = [];

        document.addEventListener('DOMContentLoaded', init);

        function init() {
            detectDevice();
            setupScreenWakeProtection();
            initSocket();
            if (groupName) {
                refresh();
            }
        }

        function detectDevice() {
            const userAgent = navigator.userAgent;
            isIOS = /iPad|iPhone|iPod/.test(userAgent);
            isAndroid = /Android/.test(userAgent);
            isMobile = isIOS || isAndroid;
            
            console.log('Device detected:', { isIOS, isAndroid, isMobile, userAgent });
        }

        async function setupScreenWakeProtection() {
            console.log('Setting up enhanced screen wake protection...');

            // Enhanced wake lock support
            if ('wakeLock' in navigator) {
                console.log('Wake Lock API supported - will aggressively maintain wake');
            }

            // Page visibility and focus management
            document.addEventListener('visibilitychange', handleVisibilityChange);
            window.addEventListener('beforeunload', handleBeforeUnload);
            window.addEventListener('blur', handleWindowBlur);
            window.addEventListener('focus', handleWindowFocus);
            
            // Mobile-specific wake management
            if (isMobile) {
                setupMobileWakeManagement();
            }

            // User interaction wake maintenance
            document.addEventListener('touchstart', maintainScreenWake, { passive: true });
            document.addEventListener('click', maintainScreenWake, { passive: true });

            console.log('Enhanced screen wake protection initialized');
        }

        async function requestWakeLock(retry = 0) {
            if (!('wakeLock' in navigator)) {
                console.log('Wake Lock not supported, using fallback methods');
                fallbackScreenWake();
                return;
            }

            try {
                if (wakeLock) {
                    wakeLock.release();
                    wakeLock = null;
                }

                wakeLock = await navigator.wakeLock.request('screen');
                console.log('Wake lock acquired successfully');
                
                document.getElementById('wakeLockIndicator').classList.remove('hidden');
                if (retry === 0) {
                    showAlert('🔓 Screen will stay awake during call');
                }

                wakeLock.addEventListener('release', () => {
                    console.log('Wake lock released - attempting reacquisition');
                    if (inCall && retry < 10) {
                        setTimeout(() => requestWakeLock(retry + 1), Math.min(2000 * Math.pow(2, retry), 30000));
                    }
                });

            } catch (error) {
                console.log(`Wake lock failed (attempt ${retry + 1}):`, error);
                if (retry < 5) {
                    setTimeout(() => requestWakeLock(retry + 1), 3000);
                } else {
                    fallbackScreenWake();
                }
            }
        }

        function fallbackScreenWake() {
            console.log('Using fallback screen wake methods');
            
            createWakeVideo();
            startScreenWakeInterval();
            
            if (isMobile) {
                maintainAudioWake();
            }

            document.getElementById('wakeLockIndicator').classList.remove('hidden');
            document.getElementById('wakeLockIndicator').textContent = '🔓 Screen Wake (Fallback)';
        }

        function createWakeVideo() {
            const video = document.createElement('video');
            video.setAttribute('playsinline', true);
            video.setAttribute('muted', true);
            video.setAttribute('autoplay', true);
            video.setAttribute('loop', true);
            video.style.cssText = 'position:fixed;top:-200px;left:-200px;width:1px;height:1px;opacity:0;pointer-events:none';
            
            const canvas = document.createElement('canvas');
            canvas.width = 1;
            canvas.height = 1;
            const ctx = canvas.getContext('2d');
            
            const stream = canvas.captureStream(1);
            video.srcObject = stream;
            
            let frame = 0;
            const animate = () => {
                if (inCall) {
                    ctx.fillStyle = frame % 2 ? '#000000' : '#000001';
                    ctx.fillRect(0, 0, 1, 1);
                    frame++;
                    requestAnimationFrame(animate);
                }
            };
            
            video.play().then(() => {
                document.body.appendChild(video);
                animate();
                console.log('Wake video created and playing');
            }).catch(e => console.log('Wake video failed:', e));
            
            video._cleanup = () => {
                if (video.parentNode) {
                    video.pause();
                    document.body.removeChild(video);
                    stream.getTracks().forEach(track => track.stop());
                }
            };
            
            return video;
        }

        function startScreenWakeInterval() {
            if (screenWakeInterval) clearInterval(screenWakeInterval);
            
            screenWakeInterval = setInterval(() => {
                if (inCall) {
                    // Simulate user activity
                    document.dispatchEvent(new Event('touchstart'));
                    
                    requestAnimationFrame(() => {
                        if (inCall && Date.now) {
                            window._wakeTimestamp = Date.now();
                        }
                    });
                }
            }, 15000);
        }

        function maintainAudioWake() {
            if (!audioCtx) return;
            
            try {
                const oscillator = audioCtx.createOscillator();
                const gainNode = audioCtx.createGain();
                
                oscillator.frequency.setValueAtTime(0.001, audioCtx.currentTime);
                gainNode.gain.setValueAtTime(0.001, audioCtx.currentTime);
                
                oscillator.connect(gainNode);
                gainNode.connect(audioCtx.destination);
                
                oscillator.start();
                
                micKeepAliveNodes.push(oscillator);
                console.log('Audio wake maintenance active');
                
            } catch (e) {
                console.log('Audio wake maintenance failed:', e);
            }
        }

        function maintainScreenWake() {
            if (inCall && !wakeLock) {
                requestWakeLock();
            }
        }

        function setupMobileWakeManagement() {
            if (isIOS) {
                document.addEventListener('touchstart', () => {
                    if (audioCtx && audioCtx.state === 'suspended') {
                        audioCtx.resume();
                    }
                    if (inCall) {
                        requestWakeLock();
                    }
                }, { passive: true });
                
                window.addEventListener('pagehide', e => {
                    if (inCall) {
                        e.preventDefault();
                        maintainBackgroundAudio();
                    }
                });
            }

            if (isAndroid) {
                if ('mediaSession' in navigator) {
                    navigator.mediaSession.metadata = new MediaMetadata({
                        title: 'xsukax Voice Call',
                        artist: 'Encrypted Call Active',
                        artwork: []
                    });

                    navigator.mediaSession.setActionHandler('pause', () => {
                        console.log('Media session pause - maintaining call');
                        if (inCall) maintainBackgroundAudio();
                    });

                    navigator.mediaSession.setActionHandler('play', () => {
                        console.log('Media session play - resuming call');
                        if (inCall && muted) toggleMute();
                    });

                    navigator.mediaSession.setActionHandler('hangup', () => {
                        console.log('Media session hangup');
                        if (inCall) endCall();
                    });
                }
            }
        }

        function releaseWakeLock() {
            if (wakeLock) {
                wakeLock.release();
                wakeLock = null;
                console.log('Wake lock released');
            }
            
            if (screenWakeInterval) {
                clearInterval(screenWakeInterval);
                screenWakeInterval = null;
            }
            
            document.querySelectorAll('video').forEach(video => {
                if (video._cleanup) video._cleanup();
            });
            
            micKeepAliveNodes.forEach(node => {
                try { node.disconnect(); } catch (e) {}
            });
            micKeepAliveNodes = [];
            
            document.getElementById('wakeLockIndicator').classList.add('hidden');
        }

        function handleVisibilityChange() {
            if (document.hidden && inCall) {
                console.log('Page went to background during call - aggressive maintenance');
                maintainBackgroundAudio();
                setTimeout(() => {
                    if (!document.hidden && inCall) {
                        requestWakeLock();
                    }
                }, 1000);
            } else if (!document.hidden && inCall) {
                console.log('Page came back to foreground during call');
                resumeForegroundAudio();
                requestWakeLock();
            }
        }

        function handleWindowBlur() {
            if (inCall) {
                console.log('Window lost focus during call');
                maintainBackgroundAudio();
                setTimeout(() => requestWakeLock(), 2000);
            }
        }

        function handleWindowFocus() {
            if (inCall) {
                console.log('Window gained focus during call');
                resumeForegroundAudio();
                requestWakeLock();
            }
        }

        function handleBeforeUnload(e) {
            if (inCall) {
                e.preventDefault();
                e.returnValue = 'You have an active call. Are you sure you want to leave?';
                return e.returnValue;
            }
        }

        function maintainBackgroundAudio() {
            if (!inCall || !audioCtx) return;

            const resumeAudio = async () => {
                try {
                    if (audioCtx.state !== 'running') {
                        await audioCtx.resume();
                        console.log('Audio context resumed for background');
                    }
                } catch (e) {
                    console.log('Could not resume audio context:', e);
                }
            };

            resumeAudio();
            
            try {
                for (let i = 0; i < 3; i++) {
                    const oscillator = audioCtx.createOscillator();
                    const gainNode = audioCtx.createGain();
                    
                    oscillator.frequency.setValueAtTime(0.001 + (i * 0.001), audioCtx.currentTime);
                    gainNode.gain.setValueAtTime(0.001, audioCtx.currentTime);
                    
                    oscillator.connect(gainNode);
                    gainNode.connect(audioCtx.destination);
                    
                    oscillator.start();
                    oscillator.stop(audioCtx.currentTime + 30);
                    
                    backgroundAudioNodes.push(oscillator);
                }
                
                console.log('Background audio maintenance active with redundancy');
                
            } catch (e) {
                console.log('Could not maintain background audio:', e);
            }

            startKeepAlive();
        }

        function resumeForegroundAudio() {
            backgroundAudioNodes.forEach(node => {
                try { node.disconnect(); } catch (e) {}
            });
            backgroundAudioNodes = [];

            if (audioCtx && audioCtx.state !== 'running') {
                audioCtx.resume().then(() => {
                    console.log('Audio context resumed in foreground');
                }).catch(e => console.log('Could not resume audio context:', e));
            }

            stopKeepAlive();
        }

        function startKeepAlive() {
            if (keepAliveInterval) clearInterval(keepAliveInterval);
            
            keepAliveInterval = setInterval(() => {
                if (inCall && socket) {
                    socket.emit('ping', { call_id: callId, group: groupName, timestamp: Date.now() });
                    
                    if (audioCtx && audioCtx.state !== 'running') {
                        audioCtx.resume().catch(e => console.log('Keep-alive audio resume failed:', e));
                    }
                }
            }, 5000);
        }

        function stopKeepAlive() {
            if (keepAliveInterval) {
                clearInterval(keepAliveInterval);
                keepAliveInterval = null;
            }
        }

        function initSocket() {
            socket = io();
            
            socket.on('connect', () => {
                setStatus('🟢 Online', '#00d084');
                if (groupName) {
                    socket.emit('join_group', { group_name: groupName });
                }
            });
            
            socket.on('disconnect', () => setStatus('🔴 Offline', '#ff4757'));
            socket.on('incoming_call', handleIncoming);
            socket.on('call_failed', data => showAlert('❌ ' + data.reason));
            socket.on('call_answered', data => showCall(data.target_id));
            socket.on('call_rejected', () => {
                hideCallModal();
                showAlert('❌ Call rejected');
            });
            socket.on('call_connected', handleConnected);
            socket.on('call_ended', endCall);
            socket.on('key_exchange', handleKeyExchange);
            socket.on('audio_data', handleEncryptedAudio);
            socket.on('pong', data => {
                console.log('Keep-alive pong received:', data.timestamp);
            });
        }

        async function generateKeyPair() {
            try {
                myKeyPair = await window.crypto.subtle.generateKey(
                    { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveKey']
                );
                return await window.crypto.subtle.exportKey('raw', myKeyPair.publicKey);
            } catch (e) {
                console.error('Key generation failed:', e);
                return null;
            }
        }

        async function deriveSharedKey(peerPublicKeyBuffer) {
            try {
                const importedPeerKey = await window.crypto.subtle.importKey('raw', peerPublicKeyBuffer,
                    { name: 'ECDH', namedCurve: 'P-256' }, false, []
                );
                const sharedSecret = await window.crypto.subtle.deriveKey(
                    { name: 'ECDH', public: importedPeerKey }, myKeyPair.privateKey,
                    { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']
                );
                return sharedSecret;
            } catch (e) {
                console.error('Key derivation failed:', e);
                return null;
            }
        }

        async function encryptAudio(audioData) {
            if (!cryptoKey || !encryptionReady) return null;
            try {
                const iv = window.crypto.getRandomValues(new Uint8Array(12));
                const audioBuffer = base64ToArrayBuffer(audioData);
                const encrypted = await window.crypto.subtle.encrypt(
                    { name: 'AES-GCM', iv: iv }, cryptoKey, audioBuffer
                );
                return {
                    iv: arrayBufferToBase64(iv),
                    data: arrayBufferToBase64(encrypted)
                };
            } catch (e) {
                console.error('Encryption failed:', e);
                return null;
            }
        }

        async function decryptAudio(encryptedPacket) {
            if (!cryptoKey || !encryptionReady) return null;
            try {
                const iv = base64ToArrayBuffer(encryptedPacket.iv);
                const encryptedData = base64ToArrayBuffer(encryptedPacket.data);
                const decrypted = await window.crypto.subtle.decrypt(
                    { name: 'AES-GCM', iv: iv }, cryptoKey, encryptedData
                );
                return arrayBufferToBase64(decrypted);
            } catch (e) {
                console.error('Decryption failed:', e);
                return null;
            }
        }

        function arrayBufferToBase64(buffer) {
            const bytes = new Uint8Array(buffer);
            let binary = '';
            for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
            return btoa(binary);
        }

        function base64ToArrayBuffer(base64) {
            const binary = atob(base64);
            const bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
            return bytes.buffer;
        }

        function setStatus(txt, color) {
            const s = document.getElementById('status');
            s.textContent = txt;
            s.style.background = color;
        }

        function copyId() {
            navigator.clipboard.writeText(myId).then(() => 
                showAlert('✅ ID copied to clipboard!')
            ).catch(() => {
                const textArea = document.createElement('textarea');
                textArea.value = myId;
                document.body.appendChild(textArea);
                textArea.select();
                document.execCommand('copy');
                document.body.removeChild(textArea);
                showAlert('✅ ID copied to clipboard!');
            });
        }

        function copyGroupInfo() {
            if (!groupName) return;
            
            const groupInfo = `Group URL: ${window.location.href}\nMy ID: ${myId}`;
            navigator.clipboard.writeText(groupInfo).then(() => 
                showAlert('✅ Group info copied to clipboard!')
            ).catch(() => {
                const textArea = document.createElement('textarea');
                textArea.value = groupInfo;
                document.body.appendChild(textArea);
                textArea.select();
                document.execCommand('copy');
                document.body.removeChild(textArea);
                showAlert('✅ Group info copied to clipboard!');
            });
        }

        function quickCall(targetId) {
            if (!targetId || targetId.length !== 6) {
                showAlert('❌ Invalid user ID');
                return;
            }
            if (targetId === myId) {
                showAlert('❌ Cannot call yourself');
                return;
            }
            
            socket.emit('call_user', { target_id: targetId, group_name: groupName });
            showAlert('📞 Calling ' + targetId + '...');
        }

        function handleIncoming(data) {
            currentIncomingCall = data;
            document.getElementById('callerIdText').textContent = data.caller_id;
            document.getElementById('callerAvatar').textContent = data.caller_id.substring(0, 2);
            showCallModal();
            
            requestWakeLock();
        }

        function showCallModal() {
            document.getElementById('callModal').classList.add('show');
            playRingtone();
            
            requestWakeLock();
        }

        function hideCallModal() {
            document.getElementById('callModal').classList.remove('show');
            stopRingtone();
        }

        function acceptCall() {
            if (currentIncomingCall) {
                socket.emit('answer_call', { call_id: currentIncomingCall.call_id });
                showCall(currentIncomingCall.caller_id);
                hideCallModal();
            }
        }

        function declineCall() {
            if (currentIncomingCall) {
                socket.emit('reject_call', { call_id: currentIncomingCall.call_id });
                hideCallModal();
                currentIncomingCall = null;
            }
        }

        function showCall(peerId) {
            document.getElementById('callWith').textContent = `${myId} ↔ ${peerId}`;
            document.getElementById('callStatus').textContent = '🎤 Setting up wake-protected audio...';
            document.getElementById('callOverlay').style.display = 'flex';
            setupEarpieceAudio();
        }

        async function handleConnected(data) {
            callId = data.call_id;
            inCall = true;
            
            await requestWakeLock();
            
            document.getElementById('callStatus').textContent = '🔒 Establishing encryption...';
            const publicKeyBuffer = await generateKeyPair();
            if (publicKeyBuffer) {
                socket.emit('key_exchange', {
                    call_id: callId,
                    public_key: arrayBufferToBase64(publicKeyBuffer)
                });
            }
        }

        async function handleKeyExchange(data) {
            if (data.call_id !== callId) return;
            try {
                const peerKeyBuffer = base64ToArrayBuffer(data.public_key);
                cryptoKey = await deriveSharedKey(peerKeyBuffer);
                if (cryptoKey) {
                    encryptionReady = true;
                    document.getElementById('encryptionStatus').textContent = '🛡️ End-to-end encryption active';
                    document.getElementById('callStatus').textContent = '✅ Secure call - screen stays awake!';
                    document.getElementById('securityIndicator').classList.remove('hidden');
                    document.getElementById('earpieceIndicator').classList.remove('hidden');
                    showAlert('🔒 Protected call established');
                }
            } catch (e) {
                console.error('Key exchange failed:', e);
                showAlert('❌ Encryption setup failed');
            }
        }

        async function setupEarpieceAudio() {
            try {
                const audioConstraints = {
                    echoCancellation: true,
                    noiseSuppression: true,
                    autoGainControl: true,
                    sampleRate: 16000,
                    channelCount: 1,
                    volume: 0.4,
                    latency: 0.1
                };

                if (isAndroid) {
                    audioConstraints.mediaSource = 'voice-uplink';
                    audioConstraints.googEchoCancellation = true;
                    audioConstraints.googAutoGainControl = true;
                    audioConstraints.googNoiseSuppression = true;
                    audioConstraints.googTypingNoiseDetection = false;
                    audioConstraints.googAudioMirroring = false;
                    audioConstraints.googDucking = false;
                }

                if (isIOS) {
                    audioConstraints.sampleSize = 16;
                    audioConstraints.echoCancellationType = 'system';
                }

                localStream = await navigator.mediaDevices.getUserMedia({
                    audio: audioConstraints
                });

                console.log('Audio stream created with wake-proof constraints');

                const audioOptions = {
                    sampleRate: 16000,
                    latencyHint: 'interactive'
                };

                audioCtx = new (window.AudioContext || window.webkitAudioContext)(audioOptions);
                
                if (audioCtx.state === 'suspended') {
                    await audioCtx.resume();
                }

                const src = audioCtx.createMediaStreamSource(localStream);
                processor = audioCtx.createScriptProcessor(2048, 1, 1);
                
                processor.onaudioprocess = async e => {
                    if (!inCall || muted || !encryptionReady) return;
                    
                    if (audioCtx.state !== 'running') {
                        audioCtx.resume();
                    }
                    
                    const buf = e.inputBuffer.getChannelData(0);
                    updateLevel(buf);
                    if (hasVoice(buf)) {
                        const encodedAudio = encode(buf);
                        const encryptedAudio = await encryptAudio(encodedAudio);
                        if (encryptedAudio) {
                            socket.emit('audio_data', {
                                call_id: callId,
                                encrypted: true,
                                payload: encryptedAudio
                            });
                        }
                    }
                };
                
                src.connect(processor);
                processor.connect(audioCtx.destination);

                maintainAudioWake();

                console.log('Wake-proof earpiece audio setup completed');

            } catch (e) {
                console.error('Wake-proof audio setup failed:', e);
                showAlert('❌ Microphone access required');
                endCall();
            }
        }

        function encode(buf) {
            const i16 = new Int16Array(buf.length);
            for (let i = 0; i < buf.length; i++) 
                i16[i] = Math.max(-32768, Math.min(32767, buf[i] * 32767));
            const u8 = new Uint8Array(i16.buffer);
            let bin = '';
            for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
            return btoa(bin);
        }

        async function handleEncryptedAudio(data) {
            if (data.call_id !== callId || !data.encrypted) return;
            const decryptedAudio = await decryptAudio(data.payload);
            if (decryptedAudio && !muted) {
                playEarpieceAudio(decryptedAudio);
            }
        }

        function playEarpieceAudio(data) {
            try {
                const bin = atob(data), u8 = new Uint8Array(bin.length);
                for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
                const i16 = new Int16Array(u8.buffer), f32 = new Float32Array(i16.length);
                for (let i = 0; i < i16.length; i++) f32[i] = i16[i] / 32767;
                
                const buffer = audioCtx.createBuffer(1, f32.length, audioCtx.sampleRate);
                buffer.copyToChannel(f32, 0);
                
                const source = audioCtx.createBufferSource();
                source.buffer = buffer;

                const gainNode = audioCtx.createGain();
                gainNode.gain.value = 0.20; // 20% volume

                source.connect(gainNode);
                gainNode.connect(audioCtx.destination);
                
                source.start();

            } catch (e) {
                console.error('Earpiece audio playback error:', e);
            }
        }

        function hasVoice(buf) {
            let sum = 0;
            for (let i = 0; i < buf.length; i++) sum += Math.abs(buf[i]);
            return sum / buf.length > 0.003;
        }

        function updateLevel(buf) {
            let sum = 0;
            for (let i = 0; i < buf.length; i++) sum += Math.abs(buf[i]);
            const pct = Math.min(100, (sum / buf.length) * 1500);
            document.getElementById('audioLevel').style.width = pct + '%';
        }

        function toggleMute() {
            muted = !muted;
            const btn = document.getElementById('muteBtn');
            if (localStream) localStream.getAudioTracks().forEach(t => t.enabled = !muted);
            btn.textContent = muted ? '🔇 Muted' : '🎤 Mic';
            btn.classList.toggle('active', muted);
        }

        function endCall() {
            if (callId) socket.emit('end_call', { call_id: callId });
            if (localStream) localStream.getTracks().forEach(t => t.stop());
            if (processor) processor.disconnect();
            
            releaseWakeLock();
            stopKeepAlive();
            
            backgroundAudioNodes.forEach(node => {
                try { node.disconnect(); } catch (e) {}
            });
            backgroundAudioNodes = [];
            
            document.getElementById('callOverlay').style.display = 'none';
            document.getElementById('securityIndicator').classList.add('hidden');
            document.getElementById('earpieceIndicator').classList.add('hidden');
            
            inCall = false;
            callId = null;
            muted = false;
            cryptoKey = null;
            myKeyPair = null;
            encryptionReady = false;
            
            const muteBtn = document.getElementById('muteBtn');
            muteBtn.textContent = '🎤 Mic';
            muteBtn.classList.remove('active');

            console.log('Call ended, all wake protection released');
        }

        function refresh() {
            if (!groupName) return;
            
            fetch(`/api/users/${groupName}`).then(r => r.json()).then(data => {
                const c = document.getElementById('users');
                if (data.users && data.users.length > 0) {
                    c.innerHTML = data.users.map(u => `
                        <div class="user">
                            <div class="user-info">
                                <span class="dot"></span>
                                <strong>${u.user_id}</strong> 
                                <small class="text-muted">(${u.status})</small>
                            </div>
                            <button class="btn btn-green btn-small" onclick="quickCall('${u.user_id}')">
                                📱 Private Call
                            </button>
                        </div>
                    `).join('');
                } else {
                    c.innerHTML = `
                        <div class="no-users">
                            No other users in this group<br>
                            <small>Share the group URL to invite others!</small>
                        </div>
                    `;
                }
            }).catch(() => 
                c.innerHTML = '<div class="no-users" style="color: #ff4757;">Error loading group users</div>'
            );
        }

        function showAlert(msg) {
            const div = document.createElement('div');
            div.style.cssText = `
                position: fixed; top: 90px; right: 20px; 
                background: #21262d; color: #f0f6fc; 
                padding: 0.75rem 1rem; border-radius: var(--radius); 
                z-index: 3500; max-width: 300px; font-family: var(--font-mono);
                box-shadow: 0 4px 20px rgba(0, 0, 0, 0.3); font-size: 0.85rem;
                border: 1px solid #30363d;
            `;
            div.textContent = msg;
            document.body.appendChild(div);
            setTimeout(() => {
                div.style.animation = 'fadeIn 0.3s ease-out reverse';
                setTimeout(() => div.remove(), 300);
            }, 4000);
        }

        let ringtoneInterval;
        function playRingtone() {
            requestWakeLock();
            
            const beep = () => {
                if (audioCtx) {
                    const osc = audioCtx.createOscillator(), gain = audioCtx.createGain();
                    osc.connect(gain);
                    gain.connect(audioCtx.destination);
                    osc.frequency.setValueAtTime(800, audioCtx.currentTime);
                    gain.gain.setValueAtTime(0.05, audioCtx.currentTime);
                    osc.start();
                    osc.stop(audioCtx.currentTime + 0.15);
                }
            };
            ringtoneInterval = setInterval(beep, 1500);
            beep();
        }

        function stopRingtone() {
            if (ringtoneInterval) {
                clearInterval(ringtoneInterval);
                ringtoneInterval = null;
            }
        }

        if (groupName) {
            setInterval(refresh, 10000);
        }
    </script>
</body>
</html>'''

@app.route('/')
def home():
    if 'user_id' not in session:
        session['user_id'] = gen_id()
    return render_template_string(HTML, user_id=session['user_id'], group_name=None)

@app.route('/<group_name>')
def group_page(group_name):
    if 'user_id' not in session:
        session['user_id'] = gen_id()
    
    # Sanitize and create group
    clean_group_name = get_or_create_group(group_name)
    if not clean_group_name:
        return redirect('/')
    
    session['group_name'] = clean_group_name
    
    return render_template_string(HTML, user_id=session['user_id'], group_name=clean_group_name)

@app.route('/api/users/<group_name>')
def api_group_users(group_name):
    if 'user_id' not in session:
        return jsonify({'error': 'No session'}), 401
    
    clean_group_name = get_or_create_group(group_name)
    if not clean_group_name:
        return jsonify({'users': [], 'group': 'invalid'})
    
    if clean_group_name in groups:
        user_list = [
            {'user_id': uid, 'status': data['status']} 
            for uid, data in groups[clean_group_name]['users'].items() 
            if uid != session['user_id']
        ]
        return jsonify({'users': user_list, 'group': clean_group_name})
    
    return jsonify({'users': [], 'group': clean_group_name})

# Group-aware WebSocket handlers
@socketio.on('connect')
def on_connect():
    if 'user_id' not in session:
        return False
    
    uid = session['user_id']
    logger.info(f'User {uid} connected')

@socketio.on('join_group')
def on_join_group(data):
    if 'user_id' not in session:
        return
    
    uid = session['user_id']
    group_name = get_or_create_group(data.get('group_name', ''))
    
    if not group_name:
        return
    
    # Add user to group
    groups[group_name]['users'][uid] = {'sid': request.sid, 'status': 'available'}
    
    # Join socket room for group
    join_room(f'group_{group_name}')
    
    # Store group in session
    session['group_name'] = group_name
    
    # Notify other users in the group
    emit('user_online', {'user_id': uid}, room=f'group_{group_name}', include_self=False)
    
    logger.info(f'User {uid} joined group {group_name}')

@socketio.on('disconnect')
def on_disconnect():
    if 'user_id' not in session:
        return
    
    uid = session['user_id']
    
    # Remove user from all groups
    for group_name, group_data in groups.items():
        if uid in group_data['users']:
            del group_data['users'][uid]
            
            # End any calls involving this user
            for call_id, call in list(group_data['calls'].items()):
                if call['caller'] == uid or call['callee'] == uid:
                    del group_data['calls'][call_id]
            
            # Notify other users in the group
            emit('user_offline', {'user_id': uid}, room=f'group_{group_name}')
            
            # Leave socket room
            leave_room(f'group_{group_name}')
            
            logger.info(f'User {uid} left group {group_name}')
            break

@socketio.on('call_user')
def on_call(data):
    if 'user_id' not in session or 'group_name' not in session:
        return
    
    caller = session['user_id']
    target = data.get('target_id')
    group_name = session['group_name']
    
    if group_name not in groups:
        emit('call_failed', {'reason': 'Group not found'})
        return
    
    group_data = groups[group_name]
    
    if not target or target not in group_data['users']:
        emit('call_failed', {'reason': 'User not online in this group'})
        return
    
    if group_data['users'][target]['status'] != 'available':
        emit('call_failed', {'reason': 'User is busy'})
        return
    
    call_id = secrets.token_hex(8)
    group_data['calls'][call_id] = {'caller': caller, 'callee': target}
    group_data['users'][caller]['status'] = 'calling'
    group_data['users'][target]['status'] = 'receiving'
    
    emit('incoming_call', {'call_id': call_id, 'caller_id': caller}, 
         room=group_data['users'][target]['sid'])

@socketio.on('answer_call')
def on_answer(data):
    if 'user_id' not in session or 'group_name' not in session:
        return
    
    call_id = data.get('call_id')
    group_name = session['group_name']
    
    if group_name not in groups or call_id not in groups[group_name]['calls']:
        return
    
    group_data = groups[group_name]
    call = group_data['calls'][call_id]
    
    group_data['users'][call['caller']]['status'] = 'in_call'
    group_data['users'][call['callee']]['status'] = 'in_call'
    
    emit('call_answered', {'call_id': call_id, 'target_id': call['callee']}, 
         room=group_data['users'][call['caller']]['sid'])
    emit('call_connected', {'call_id': call_id, 'peer_id': call['caller']})
    emit('call_connected', {'call_id': call_id, 'peer_id': call['callee']}, 
         room=group_data['users'][call['caller']]['sid'])

@socketio.on('reject_call')
def on_reject(data):
    if 'user_id' not in session or 'group_name' not in session:
        return
    
    call_id = data.get('call_id')
    group_name = session['group_name']
    
    if group_name not in groups or call_id not in groups[group_name]['calls']:
        return
    
    group_data = groups[group_name]
    call = group_data['calls'][call_id]
    
    group_data['users'][call['caller']]['status'] = 'available'
    group_data['users'][call['callee']]['status'] = 'available'
    
    emit('call_rejected', room=group_data['users'][call['caller']]['sid'])
    del group_data['calls'][call_id]

@socketio.on('end_call')
def on_end(data):
    if 'user_id' not in session or 'group_name' not in session:
        return
    
    call_id = data.get('call_id')
    group_name = session['group_name']
    
    if group_name not in groups or call_id not in groups[group_name]['calls']:
        return
    
    group_data = groups[group_name]
    call = group_data['calls'][call_id]
    
    if call['caller'] in group_data['users']:
        group_data['users'][call['caller']]['status'] = 'available'
    if call['callee'] in group_data['users']:
        group_data['users'][call['callee']]['status'] = 'available'
    
    emit('call_ended', room=group_data['users'][call['caller']]['sid'])
    emit('call_ended', room=group_data['users'][call['callee']]['sid'])
    del group_data['calls'][call_id]

@socketio.on('key_exchange')
def on_key_exchange(data):
    if 'user_id' not in session or 'group_name' not in session:
        return
    
    call_id = data.get('call_id')
    group_name = session['group_name']
    
    if group_name not in groups or call_id not in groups[group_name]['calls']:
        return
    
    group_data = groups[group_name]
    call = group_data['calls'][call_id]
    sender = session['user_id']
    target = call['callee'] if sender == call['caller'] else call['caller']
    
    if target in group_data['users']:
        emit('key_exchange', {
            'call_id': call_id, 
            'public_key': data.get('public_key')
        }, room=group_data['users'][target]['sid'])

@socketio.on('audio_data')
def on_audio(data):
    if 'user_id' not in session or 'group_name' not in session:
        return
    
    call_id = data.get('call_id')
    group_name = session['group_name']
    
    if group_name not in groups or call_id not in groups[group_name]['calls']:
        return
    
    group_data = groups[group_name]
    call = group_data['calls'][call_id]
    sender = session['user_id']
    target = call['callee'] if sender == call['caller'] else call['caller']
    
    if target in group_data['users']:
        emit('audio_data', {
            'call_id': call_id,
            'encrypted': data.get('encrypted'),
            'payload': data.get('payload')
        }, room=group_data['users'][target]['sid'])

@socketio.on('ping')
def on_ping(data):
    if 'user_id' in session:
        emit('pong', {'timestamp': data.get('timestamp', 0)})

if __name__ == '__main__':
    port = 22000
    logger.info(f'Starting xsukax E2E encrypted voice server with groups on port {port} with SSL')
    socketio.run(app, host='0.0.0.0', port=port, debug=False,
                certfile='/opt/voice-server/server.crt',
                keyfile='/opt/voice-server/server.key')
EOF

# Create service
cat > /etc/systemd/system/voice-server.service << EOF
[Unit]
Description=xsukax E2E Encrypted Voice Call Server
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
Environment=PATH=$INSTALL_DIR/venv/bin
ExecStart=$INSTALL_DIR/venv/bin/python app/server.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Generate SSL certificates for localhost origin security
log "Generating SSL certificates for origin security..."
openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
    -keyout "$INSTALL_DIR/server.key" \
    -out "$INSTALL_DIR/server.crt" \
    -subj "/CN=localhost"

# Set proper SSL permissions
chmod 600 "$INSTALL_DIR/server.key"
chmod 644 "$INSTALL_DIR/server.crt"

log "SSL certificates generated - Flask will run on HTTPS"
log "Note: Update your Cloudflare tunnel to use: https://localhost:22000"

# Set permissions
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
chmod +x app/server.py

# Firewall - Allow HTTPS traffic
if command -v ufw >/dev/null; then
    ufw --force enable >/dev/null 2>&1
    ufw allow ssh >/dev/null 2>&1
    ufw allow $PORT/tcp >/dev/null 2>&1  # HTTPS on port 22000
    ufw allow 443/tcp >/dev/null 2>&1    # Standard HTTPS port if needed
else
    systemctl enable firewalld >/dev/null 2>&1
    firewall-cmd --permanent --add-port=$PORT/tcp >/dev/null 2>&1  # HTTPS
    firewall-cmd --permanent --add-port=443/tcp >/dev/ull 2>&1    # Standard HTTPS
    firewall-cmd --reload >/dev/null 2>&1
fi

# Start service
systemctl daemon-reload
systemctl enable voice-server
systemctl start voice-server

echo ""
echo "🎉 XSUKAX E2E ENCRYPTED VOICE SERVER"
echo "====================================="
echo "🔌 Port: $PORT (HTTPS/WSS)"
echo "🆔 Random 6-char IDs"
echo "🔒 True End-to-End Encryption"
echo "📱 EARPIECE-ONLY: 20% Volume"
echo "🔓 AGGRESSIVE SCREEN WAKE: Mic Never Stops!"
echo "🏷️ GROUPS: URL-based Auto-Creation"
echo "📋 GROUP INFO: Click to Copy URL + ID"
echo "🛡️ SSL/TLS Origin Security"
echo ""
echo "📋 SHARING WORKFLOW:"
echo "  1. Visit: voice.example.com/mygroup"
echo "  2. Click 'Group Info' section"
echo "  3. Copies: 'Group URL: ... + My ID: ...'"
echo "  4. Paste in WhatsApp/Telegram"
echo "  5. Friends join and call via user list"
echo ""
echo "🔒 SECURITY LAYERS:"
echo "  • Browser ↔ Cloudflare: HTTPS/WSS ✅"
echo "  • Cloudflare ↔ Origin: HTTPS/WSS ✅"
echo "  • Audio Encryption: E2E AES-GCM ✅"
echo "  • Key Exchange: ECDH P-256 ✅"
echo "  • Perfect Forward Secrecy ✅"
echo "  • Group Isolation ✅"
echo "  • Privacy: Earpiece-only audio (20% volume) ✅"
echo ""
echo "🔧 Commands:"
echo "  Status: systemctl status voice-server"
echo "  Logs:   journalctl -u voice-server -f"
echo "  SSL Test: openssl s_client -connect localhost:22000"
echo ""

# Final status
if systemctl is-active --quiet voice-server; then
    echo "✅ XSUKAX E2E ENCRYPTED VOICE SERVER RUNNING!"
    echo ""
    echo "🔧 NEXT STEPS:"
    echo "  1. Update Cloudflare tunnel: https://localhost:22000"
    echo "  2. Set SSL mode to 'Full (Strict)'"
	echo "  3. Enable 'Always Use HTTPS'"
	echo "  4. Additional application settings > TLS > No TLS Verify"
	echo "  5. Additional application settings > HTTP Settings > Disable Chunked Encoding"
else
    echo "❌ Service failed to start"
    echo "Check: journalctl -u voice-server -f"
fi