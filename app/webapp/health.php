<?php
// ALB target health check. Deliberately does not touch the DB so a DB
// failover doesn't make the ASG terminate healthy web servers.
http_response_code(200);
header('Content-Type: text/plain');
echo "ok";
