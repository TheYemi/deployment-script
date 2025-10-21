#!/bin/bash
set -e

LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date +'%H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
trap 'log "ERROR at line $LINENO"; exit 1' ERR

log "=== Production Deployment (Nginx Reverse Proxy) ==="

read -p "Git Repo URL: " GIT_REPO
read -sp "Personal Access Token: " PAT
echo
read -p "EC2 IP: " EC2_IP
read -p "SSH Key Path: " SSH_KEY
read -p "SSH User [ubuntu]: " SSH_USER
SSH_USER=${SSH_USER:-ubuntu}
read -p "App Port: " APP_PORT

APP_NAME="nginx-app"
REPO_NAME=$(basename "$GIT_REPO" .git)
AUTH_REPO="https://${PAT}@${GIT_REPO#https://}"

# Clone/update
if [ -d "$REPO_NAME" ]; then
    cd "$REPO_NAME"
    git pull origin main >> "$LOG_FILE" 2>&1
else
    git clone "$AUTH_REPO" "$REPO_NAME" >> "$LOG_FILE" 2>&1
    cd "$REPO_NAME"
fi

# Setup EC2
log "Installing Docker and Nginx on EC2..."
ssh -i "$SSH_KEY" -T "$SSH_USER@$EC2_IP" << 'EOF'
# Update system
sudo apt-get update -qq

# Install Docker
if ! command -v docker &> /dev/null; then
    sudo apt-get install -y docker.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER
fi

# Install Nginx (on host, not in Docker)
if ! command -v nginx &> /dev/null; then
    sudo apt-get install -y nginx
    sudo systemctl enable --now nginx
fi

docker --version
nginx -v
EOF

# Deploy container
log "Deploying Docker container..."
REMOTE_DIR="/home/$SSH_USER/$REPO_NAME"
ssh -i "$SSH_KEY" -T "$SSH_USER@$EC2_IP" "mkdir -p $REMOTE_DIR"
scp -i "$SSH_KEY" -r ./* "$SSH_USER@$EC2_IP:$REMOTE_DIR/" >> "$LOG_FILE" 2>&1

ssh -i "$SSH_KEY" -T "$SSH_USER@$EC2_IP" << EOF
cd $REMOTE_DIR
docker stop $APP_NAME 2>/dev/null || true
docker rm $APP_NAME 2>/dev/null || true
docker build -t $APP_NAME .
docker run -d -p $APP_PORT:8080 --name $APP_NAME $APP_NAME
sleep 3
docker ps | grep $APP_NAME
curl http://localhost:$APP_PORT
EOF

# Configure Nginx reverse proxy
log "Configuring Nginx reverse proxy..."
ssh -i "$SSH_KEY" -T "$SSH_USER@$EC2_IP" bash << EOF
# Create Nginx config
sudo tee /etc/nginx/sites-available/$APP_NAME > /dev/null << 'NGINX'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Health check
    location /health {
        access_log off;
        return 200 "healthy from proxy\n";
        add_header Content-Type text/plain;
    }
}
NGINX

# Enable site
sudo ln -sf /etc/nginx/sites-available/$APP_NAME /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Test and reload
sudo nginx -t
sudo systemctl reload nginx
EOF

# Validate
log "Testing deployment..."
ssh -i "$SSH_KEY" -T "$SSH_USER@$EC2_IP" << 'EOF'
echo "=== Docker Status ==="
docker ps

echo -e "\n=== Testing Container Directly ==="
curl -s http://localhost:8080 | head -n 5

echo -e "\n=== Testing Nginx Proxy ==="
curl -I http://localhost
EOF

log "========================================="
log "Deployment Complete!"
log "========================================="
log "Application: http://$EC2_IP"
log "Architecture: Nginx (Port 80) → Docker (Port 8080)"
log "Health Check: http://$EC2_IP/health"
log "========================================="
