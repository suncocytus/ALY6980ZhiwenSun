#!/bin/bash
exec > /var/log/user-data.log 2>&1
echo "=== NANDA Agent Setup Started: nanda-agent-zwen-001 ==="
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
sudo -u ubuntu git clone https://github.com/projnanda/NEST.git nanda-agent-nanda-agent-zwen-001
cd nanda-agent-nanda-agent-zwen-001
# Create virtual environment and install
sudo -u ubuntu python3 -m venv env
sudo -u ubuntu bash -c "source env/bin/activate && pip install --upgrade pip && pip install -e . && pip install anthropic"
# Configure the modular agent with all environment variables
sudo -u ubuntu sed -i "s/PORT = 6000/PORT = 6000/" examples/nanda_agent.py
# Get public IP using Linode metadata service
echo "Getting public IP address..."
for attempt in {1..10}; do
    # Linode metadata service
    TOKEN=$(curl -s -X PUT -H "Metadata-Token-Expiry-Seconds: 3600" http://169.254.169.254/v1/token 2>/dev/null)
    if [ -n "$TOKEN" ]; then
        NETWORK_INFO=$(curl -s --connect-timeout 5 --max-time 10 -H "Metadata-Token: $TOKEN" http://169.254.169.254/v1/network 2>/dev/null)
        # Extract IPv4 public IP from response like "ipv4.public: 45.79.145.23/32 ipv6.link_local: ..."
        PUBLIC_IP=$(echo "$NETWORK_INFO" | grep -o 'ipv4\.public: [0-9]*\.[0-9]*\.[0-9]*\.[0-9]*' | cut -d' ' -f2 | cut -d'/' -f1)
    fi
    
    # Fallback to external service if metadata service fails
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP=$(curl -s --connect-timeout 5 --max-time 10 https://ipinfo.io/ip 2>/dev/null)
    fi
    
    if [ -n "$PUBLIC_IP" ] && [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Retrieved public IP: $PUBLIC_IP"
        break
    fi
    echo "Attempt $attempt failed, retrying..."
    sleep 3
done
if [ -z "$PUBLIC_IP" ]; then
    echo "ERROR: Could not retrieve public IP after 10 attempts"
    exit 1
fi
# Start the agent with all configuration
echo "Starting NANDA agent with PUBLIC_URL: http://$PUBLIC_IP:6000"
sudo -u ubuntu bash -c "
    cd /home/ubuntu/nanda-agent-nanda-agent-zwen-001
    source env/bin/activate
    export ANTHROPIC_API_KEY='...'
    export AGENT_ID='nanda-agent-zwen-001'
    export AGENT_NAME='SmartDay Planner'
    export AGENT_DOMAIN='daily life plan and design'
    export AGENT_SPECIALIZATION='samrt dayily plan specialist'
    export AGENT_DESCRIPTION='I help with plan the day and check conflicts'
    export AGENT_CAPABILITIES='planning,python,ubuntu,cloud,a2a'
    export REGISTRY_URL='http://registry.chat39.com:6900'
    export PUBLIC_URL='http://$PUBLIC_IP:6000'
    export PORT='6000'
    nohup python3 examples/nanda_agent.py > agent.log 2>&1 &
"
echo "=== NANDA Agent Setup Complete: nanda-agent-zwen-001 ==="
echo "Agent URL: http://$PUBLIC_IP:6000/a2a"
