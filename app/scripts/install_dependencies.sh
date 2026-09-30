#!/bin/bash
set -e
dnf install -y httpd php php-fpm php-mysqlnd php-json
rm -f /var/www/html/index.html   # placeholder from user data; index.php takes over
echo "Dependencies installed"
