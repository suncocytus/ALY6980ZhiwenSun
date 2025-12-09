#!/bin/bash

# CONFIGURABLE Akamai Connected Cloud (Linode) + NANDA Agent Deployment Script
# This script creates a Linode instance and deploys a fully configurable modular NANDA agent
# Usage: bash akamai-single-agent-deployment.sh <AGENT_ID> <ANTHROPIC_API_KEY> <AGENT_NAME> <DOMAIN> <SPECIALIZATION> <DESCRIPTION> <CAPABILITIES> [REGISTRY_URL] [PORT] [REGION] [INSTANCE_TYPE] [ROOT_PASSWORD]

set -e

# Parse arguments
AGENT_ID="$1"
ANTHROPIC_API_KEY="$2"
AGENT_NAME="$3"
DOMAIN="$4"
SPECIALIZATION="$5"
DESCRIPTION="$6"
CAPABILITIES="$7"
REGISTRY_URL="${8:-}"
PORT="${9:-6000}"
REGION="${10:-us-east}"
INSTANCE_TYPE="${11:-g6-nanode-1}"
ROOT_PASSWORD="${12:-}"

# Validate inputs
if [ -z "$AGENT_ID" ] || [ -z "$ANTHROPIC_API_KEY" ] || [ -z "$AGENT_NAME" ] || [ -z "$DOMAIN" ] || [ -z "$SPECIALIZATION" ] || [ -z "$DESCRIPTION" ] || [ -z "$CAPABILITIES" ]; then
    echo "❌ Usage: $0 <AGENT_ID> <ANTHROPIC_API_KEY> <AGENT_NAME> <DOMAIN> <SPECIALIZATION> <DESCRIPTION> <CAPABILITIES> [REGISTRY_URL] [PORT] [REGION] [INSTANCE_TYPE] [ROOT_PASSWORD]"
    echo ""
    echo "Example:"
    echo "  $0 data-scientist sk-ant-xxxxx \"Data Scientist\" \"data analysis\" \"analytical and precise AI assistant\" \"I specialize in data analysis, statistics, and machine learning.\" \"data analysis,statistics,machine learning,Python,R\" \"https://registry.example.com\" 6000 us-east g6-nanode-1 \"SecurePassword123!\""
    echo ""
    echo "Parameters:"
    echo "  AGENT_ID: Unique identifier for the agent"
    echo "  ANTHROPIC_API_KEY: Your Anthropic API key"
    echo "  AGENT_NAME: Display name for the agent"
    echo "  DOMAIN: Primary domain/field of expertise"
    echo "  SPECIALIZATION: Brief description of agent's role"
    echo "  DESCRIPTION: Detailed description of the agent"
    echo "  CAPABILITIES: Comma-separated list of capabilities"
    echo "  REGISTRY_URL: Optional registry URL for agent discovery"
    echo "  PORT: Port for the agent service (default: 6000)"
    echo "  REGION: Linode region (default: us-east)"
    echo "  INSTANCE_TYPE: Linode plan type (default: g6-nanode-1)"
    echo "  ROOT_PASSWORD: Root password for the instance (will be generated if not provided)"
    echo ""
    echo "Common Linode regions: us-east, us-west, eu-west, ap-south"
    echo "Common instance types: g6-nanode-1 (1GB), g6-standard-1 (2GB), g6-standard-2 (4GB)"
    exit 1
fi


# Generate secure password if not provided
if [ -z "$ROOT_PASSWORD" ]; then
    ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    echo "🔑 Generated root password: $ROOT_PASSWORD"
fi


echo "🚀 Configurable Akamai Connected Cloud (Linode) + NANDA Agent Deployment"
echo "========================================================================"
echo "Agent ID: $AGENT_ID"
echo "Agent Name: $AGENT_NAME"
echo "Domain: $DOMAIN"
echo "Specialization: $SPECIALIZATION"
echo "Capabilities: $CAPABILITIES"
echo "Registry URL: ${REGISTRY_URL:-"None"}"
echo "Port: $PORT"
echo "Region: $REGION"
echo "Instance Type: $INSTANCE_TYPE"
echo ""


# Configuration
FIREWALL_LABEL="nanda-nest-agents"
SSH_KEY_LABEL="nanda-agent-key"
IMAGE_ID="linode/ubuntu25.04"  # Ubuntu 2532.04 LTS


# Check Linode CLI credentials
echo "[1/6] Checking Linode CLI credentials..."
if ! linode-cli --version >/dev/null 2>&1; then
    echo "❌ Linode CLI not installed. Install it: https://techdocs.akamai.com/cloud-computing/docs/install-and-configure-the-cli"
    exit 1
fi

CONFIG="$HOME/.config/linode-cli"
echo "$CONFIG is readable: $( [ -r "$CONFIG" ] && echo yes || echo no )"

if [ ! -s "$CONFIG" ] && [ -z "$LINODE_CLI_TOKEN" ]; then
    echo "❌ Linode CLI not configured. Run 'linode-cli configure' first."
    exit 1
fi
echo "✅ Linode CLI credentials valid"


# Setup firewall
echo "[2/6] Setting up firewall..."
FIREWALL_ID=$(linode-cli firewalls list --text --no-headers --format="id,label" | grep "$FIREWALL_LABEL" | cut -f1 || echo "")

if [ -z "$FIREWALL_ID" ]; then
    echo "Creating firewall..."
    linode-cli firewalls create \
        --label "$FIREWALL_LABEL" \
        --rules.inbound_policy DROP \
        --rules.outbound_policy ACCEPT \
        --rules.inbound '[{"protocol": "TCP", "ports": "22", "addresses": {"ipv4": ["0.0.0.0/0"]}, "action": "ACCEPT"}, {"protocol": "TCP", "ports": "'$PORT'", "addresses": {"ipv4": ["0.0.0.0/0"]}, "action": "ACCEPT"}]'

    FIREWALL_ID=$(linode-cli firewalls list --text --no-headers --format="id,label" | grep "$FIREWALL_LABEL" | cut -f1 || echo "")
fi
echo "✅ Firewall: $FIREWALL_ID - $FIREWALL_LABEL"


# Setup SSH key
echo "[3/6] Setting up SSH key..."
if [ ! -f "${SSH_KEY_LABEL}.pub" ]; then
    echo "Generating SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_LABEL" -N "" -C "nanda-agent-$AGENT_ID"
fi


# Create user data script
echo "[4/6] Creating user data script..."
cat > "user_data_${AGENT_ID}.sh" << EOF
#!/bin/bash
exec > /var/log/user-data.log 2>&1
echo "=== NANDA Agent Setup Started: $AGENT_ID ==="
date
# Update system and install dependencies
apt-get update -y
apt-get install -y python3 python3-venv python3-pip git curl
# Create ubuntu user (Linode uses root by default)
useradd -m -s /bin/bash ubuntu
mkdir -p /home/ubuntu/.ssh
cp /root/.ssh/authorized_keys /home/ubuntu/.ssh/authorized_keys 2>/dev/null || true
chown -R ubuntu:ubuntu /home/ubuntu/.ssh
chmod 700 /home/ubuntu/.ssh
chmod 600 /home/ubuntu/.ssh/authorized_keys 2>/dev/null || true
# Setup project as ubuntu user
cd /home/ubuntu
sudo -u ubuntu git clone https://github.com/projnanda/NEST.git nanda-agent-$AGENT_ID
cd nanda-agent-$AGENT_ID
# Create virtual environment and install
sudo -u ubuntu python3 -m venv env
sudo -u ubuntu bash -c "source env/bin/activate && pip install --upgrade pip && pip install -e . && pip install anthropic"
# Configure the modular agent with all environment variables
sudo -u ubuntu sed -i "s/PORT = 6000/PORT = $PORT/" examples/nanda_agent.py
# Get public IP using Linode metadata service
echo "Getting public IP address..."
for attempt in {1..10}; do
    # Linode metadata service
    TOKEN=\$(curl -s -X PUT -H "Metadata-Token-Expiry-Seconds: 3600" http://169.254.169.254/v1/token 2>/dev/null)
    if [ -n "\$TOKEN" ]; then
        NETWORK_INFO=\$(curl -s --connect-timeout 5 --max-time 10 -H "Metadata-Token: \$TOKEN" http://169.254.169.254/v1/network 2>/dev/null)
        # Extract IPv4 public IP from response like "ipv4.public: 45.79.145.23/32 ipv6.link_local: ..."
        PUBLIC_IP=\$(echo "\$NETWORK_INFO" | grep -o 'ipv4\\.public: [0-9]*\\.[0-9]*\\.[0-9]*\\.[0-9]*' | cut -d' ' -f2 | cut -d'/' -f1)
    fi
    
    # Fallback to external service if metadata service fails
    if [ -z "\$PUBLIC_IP" ]; then
        PUBLIC_IP=\$(curl -s --connect-timeout 5 --max-time 10 https://ipinfo.io/ip 2>/dev/null)
    fi
    
    if [ -n "\$PUBLIC_IP" ] && [[ \$PUBLIC_IP =~ ^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\$ ]]; then
        echo "Retrieved public IP: \$PUBLIC_IP"
        break
    fi
    echo "Attempt \$attempt failed, retrying..."
    sleep 3
done
if [ -z "\$PUBLIC_IP" ]; then
    echo "ERROR: Could not retrieve public IP after 10 attempts"
    exit 1
fi
# Start the agent with all configuration
echo "Starting NANDA agent with PUBLIC_URL: http://\$PUBLIC_IP:$PORT"
sudo -u ubuntu bash -c "
    cd /home/ubuntu/nanda-agent-$AGENT_ID
    source env/bin/activate
    export ANTHROPIC_API_KEY='$ANTHROPIC_API_KEY'
    export AGENT_ID='$AGENT_ID'
    export AGENT_NAME='$AGENT_NAME'
    export AGENT_DOMAIN='$DOMAIN'
    export AGENT_SPECIALIZATION='$SPECIALIZATION'
    export AGENT_DESCRIPTION='$DESCRIPTION'
    export AGENT_CAPABILITIES='$CAPABILITIES'
    export REGISTRY_URL='$REGISTRY_URL'
    export PUBLIC_URL='http://\$PUBLIC_IP:$PORT'
    export PORT='$PORT'
    nohup python3 examples/nanda_agent.py > agent.log 2>&1 &
"
echo "=== NANDA Agent Setup Complete: $AGENT_ID ==="
echo "Agent URL: http://\$PUBLIC_IP:$PORT/a2a"
EOF

echo "[5/6] Running Linode instance..."
# Check if instance already exists
INSTANCE_ID=$(linode-cli linodes list --label "nanda-agent-$AGENT_ID" --text --no-headers --format="id" | head -n1)
if [ ! -n "$INSTANCE_ID" ]; then
    # Launch Linode instance
    INSTANCE_ID=$(linode-cli linodes create \
        --type "$INSTANCE_TYPE" \
        --region "$REGION" \
        --image "$IMAGE_ID" \
        --label "nanda-agent-$AGENT_ID" \
        --tags "NANDA-NEST" \
        --root_pass "$ROOT_PASSWORD" \
        --authorized_keys "$(cat ${SSH_KEY_LABEL}.pub)" \
        --firewall_id "$FIREWALL_ID"\
        --text --no-headers --format="id")
fi
echo "✅ Instance id: $INSTANCE_ID"

# Wait for instance to be running
echo "Waiting for instance to be running..."
while true; do
    STATUS=$(linode-cli linodes view "$INSTANCE_ID" --text --no-headers --format="status")
    if [ "$STATUS" = "running" ]; then
        break
    fi
    echo "Instance status: $STATUS, waiting..."
    sleep 10
done

# Get public IP
PUBLIC_IP=$(linode-cli linodes view "$INSTANCE_ID" --text --no-headers --format="ipv4")
echo "Public IP: $PUBLIC_IP"

echo "[6/6] Deploying agent (this process may take a few minutes)..."
# Copy the user data script and execute it
scp -i "$SSH_KEY_LABEL" -o StrictHostKeyChecking=no "user_data_${AGENT_ID}.sh" "root@$PUBLIC_IP:/tmp/"
ssh -i "$SSH_KEY_LABEL" -o StrictHostKeyChecking=no "root@$PUBLIC_IP" "chmod +x /tmp/user_data_${AGENT_ID}.sh && /tmp/user_data_${AGENT_ID}.sh"


echo ""
echo "🎉 NANDA Agent Deployment Complete!"
echo "=================================="
echo "Instance ID: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo "Root Password: $ROOT_PASSWORD"
echo "Agent URL: http://$PUBLIC_IP:$PORT/a2a"
echo ""
echo "🤖 Agent ID for A2A Communication: ${AGENT_ID}-[6-char-hex]"
echo ""
echo "📞 Use this agent in A2A messages:"
echo "   @${AGENT_ID}-[hex] your message here"
echo "   (The actual hex suffix is generated at runtime)"

echo ""
echo "🧪 Test your agent (direct communication):"
echo "curl -X POST http://$PUBLIC_IP:$PORT/a2a \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '{\"content\":{\"text\":\"Hello! What can you help me with?\",\"type\":\"text\"},\"role\":\"user\",\"conversation_id\":\"test123\"}'"

echo ""
echo "🧪 Test A2A communication (example with another agent):"
echo "curl -X POST http://$PUBLIC_IP:$PORT/a2a \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '{\"content\":{\"text\":\"@$AGENT_ID-[6-char-hex] What can you help me with?\",\"type\":\"text\"},\"role\":\"user\",\"conversation_id\":\"test123\"}'"
echo ""
echo "🔐 SSH Access:"
echo "ssh -i ${SSH_KEY_LABEL} ubuntu@$PUBLIC_IP"
echo "ssh -i ${SSH_KEY_LABEL} root@$PUBLIC_IP"
echo ""
echo "🛑 To terminate:"
echo "linode-cli linodes delete $INSTANCE_ID"
