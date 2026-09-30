#!/bin/bash
# Must not fail on first deploy / fresh instance
systemctl stop httpd || true
echo "Web server stopped"
