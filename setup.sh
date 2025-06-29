#!/bin/bash

echo "Configuring UFW firewall..."
sudo sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
sudo systemctl restart ufw
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 5432/tcp
yes | sudo ufw enable
sudo ufw status

IP=$(ip -4 addr show enp0s8 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Detected IP address on enp0s8: $IP"

echo "Installing required packages..."
sudo apt update
sudo apt install -y postgresql python3-pip python3-venv nginx ipcalc

echo "Find subnet..."
IP_WITH_CIDR=$(ip -4 addr show enp0s8 | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')
SUBNET=$(ipcalc -n "$IP_WITH_CIDR" | grep -oP 'Network:\s+\K[\d./]+')

echo "Configuring PostgreSQL..."
sudo -u postgres psql <<EOF
CREATE USER admin WITH PASSWORD 'password';
CREATE DATABASE serbian_cities OWNER admin;
GRANT ALL PRIVILEGES ON DATABASE serbian_cities TO admin;
EOF

PG_HBA=$(find /etc/postgresql -name pg_hba.conf)
sudo sed -i 's/^local\s\+all\s\+all\s\+peer/local all all md5/' "$PG_HBA"
echo "host all all $SUBNET md5" | sudo tee -a "$PG_HBA"
echo "host replication all $SUBNET md5" | sudo tee -a "$PG_HBA"

PG_CONF=$(find /etc/postgresql -name postgresql.conf)
sudo sed -i "s/^#listen_addresses =.*/listen_addresses = '*'/" "$PG_CONF"

sudo systemctl restart postgresql

echo "Setting up Python app..."
git clone https://github.com/vanvanich9/serbian-cities-explorer-os-final-exam src
cd src
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python init_db.py
gunicorn main:app --bind :8000 --workers 4 --worker-class uvicorn.workers.UvicornWorker --daemon

echo "Configuring Nginx..."
NGINX_DEFAULT="/etc/nginx/sites-available/default"
sudo tee "$NGINX_DEFAULT" > /dev/null <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

sudo nginx -t && sudo systemctl reload nginx

echo "Server setup complete. Access your app at: http://$IP"
