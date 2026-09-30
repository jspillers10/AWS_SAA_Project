<?php
// DB config is written by EC2 user data from Secrets Manager (/etc/webapp/db.json).
// Nothing sensitive lives in this repo.
$cfg = json_decode(@file_get_contents('/etc/webapp/db.json'), true) ?: [];

function imds(string $path): string {
    // IMDSv2: fetch a session token first (the original page showed N/A because it skipped this)
    $tokenCtx = stream_context_create(['http' => [
        'method'  => 'PUT',
        'header'  => "X-aws-ec2-metadata-token-ttl-seconds: 60\r\n",
        'timeout' => 1,
    ]]);
    $token = @file_get_contents('http://169.254.169.254/latest/api/token', false, $tokenCtx);
    if ($token === false) return 'N/A';

    $ctx = stream_context_create(['http' => [
        'header'  => "X-aws-ec2-metadata-token: $token\r\n",
        'timeout' => 1,
    ]]);
    $val = @file_get_contents("http://169.254.169.254/latest/meta-data/$path", false, $ctx);
    return $val === false ? 'N/A' : $val;
}

$instanceId = imds('instance-id');
$az         = imds('placement/availability-zone');
?>
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Multi-Tier Web Application</title>
    <link rel="stylesheet" href="/assets/style.css">
</head>
<body>
    <h1>Secure Multi-Tier Application</h1>

    <div class="info status">
        <strong>Instance ID:</strong> <?= htmlspecialchars($instanceId) ?><br>
        <strong>Availability Zone:</strong> <?= htmlspecialchars($az) ?>
    </div>

<?php
mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
try {
    if (!$cfg) {
        throw new Exception('DB config not found');
    }
    $conn = mysqli_init();
    $conn->ssl_set(null, null, '/etc/webapp/rds-ca.pem', null, null);
    $conn->real_connect(
        $cfg['host'], $cfg['username'], $cfg['password'], $cfg['dbname'],
        (int)($cfg['port'] ?? 3306), null, MYSQLI_CLIENT_SSL
    );

    $stmt = $conn->prepare('INSERT INTO health_check (status) VALUES (?)');
    $status = 'healthy';
    $stmt->bind_param('s', $status);
    $stmt->execute();

    $count = $conn->query('SELECT COUNT(*) AS c FROM health_check')->fetch_assoc()['c'];
    $tls   = $conn->query("SHOW SESSION STATUS LIKE 'Ssl_version'")->fetch_assoc()['Value'] ?? 'unknown';

    echo '<div class="healthy status"><strong>Database:</strong> Connected (' . htmlspecialchars($tls) . ')<br>';
    echo '<strong>Host:</strong> ' . htmlspecialchars($cfg['host']) . '</div>';
    echo '<div class="info status"><strong>Total page hits logged:</strong> ' . (int)$count . '</div>';
    $conn->close();
} catch (Throwable $e) {
    error_log('DB error: ' . $e->getMessage());
    // Don't leak driver errors to the browser
    echo '<div class="unhealthy status"><strong>Database:</strong> Connection failed (see httpd error log)</div>';
}
?>
    <hr>
    <p><em>Multi-AZ | Auto Scaling | Deployed by CodePipeline + Terraform</em></p>
</body>
</html>
