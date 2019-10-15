#!/bin/bash

echo "Installing deps..."
apt-get install python3 python3-dev -y
apt install git curl python3-pip python3-mysqldb python-dev libmysqlclient-dev -y

pip3 install -r requirements.txt