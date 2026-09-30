"""Idempotent schema + app-user bootstrap.

Runs in the pipeline's Migrate stage (CodeBuild inside the VPC). It is the only
thing that ever uses the master credentials; EC2 instances only see the
least-privilege app user.
"""
import json
import os

import boto3
import pymysql

sm = boto3.client("secretsmanager")


def secret(arn_env: str) -> dict:
    return json.loads(sm.get_secret_value(SecretId=os.environ[arn_env])["SecretString"])


master = secret("DB_MASTER_SECRET_ARN")
app = secret("DB_APP_SECRET_ARN")
db = master["dbname"]

conn = pymysql.connect(
    host=master["host"],
    port=int(master["port"]),
    user=master["username"],
    password=master["password"],
    ssl={"ca": os.environ["RDS_CA_BUNDLE"]},
    autocommit=True,
)

with conn.cursor() as cur:
    cur.execute(f"CREATE DATABASE IF NOT EXISTS `{db}`")
    cur.execute("CREATE USER IF NOT EXISTS %s@'%%' IDENTIFIED BY %s REQUIRE SSL",
                (app["username"], app["password"]))
    # Keep password in sync if the secret was regenerated
    cur.execute("ALTER USER %s@'%%' IDENTIFIED BY %s REQUIRE SSL",
                (app["username"], app["password"]))
    cur.execute(f"GRANT SELECT, INSERT, UPDATE, DELETE ON `{db}`.* TO %s@'%%'",
                (app["username"],))
    cur.execute(f"""
        CREATE TABLE IF NOT EXISTS `{db}`.health_check (
            id INT AUTO_INCREMENT PRIMARY KEY,
            check_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            status VARCHAR(50)
        )
    """)

conn.close()
print("migration complete")
