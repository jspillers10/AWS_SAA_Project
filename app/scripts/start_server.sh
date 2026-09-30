#!/bin/bash
set -e
systemctl enable --now php-fpm
systemctl restart php-fpm
systemctl enable --now httpd
echo "Web server started"
