#!/bin/sh
set -eu
mkdir -p /tmp/rds-ca
awk 'BEGIN {n=0} /BEGIN CERTIFICATE/ {n++} {print > ("/tmp/rds-ca/" n ".pem")}' /etc/rds/global-bundle.pem
for certificate in /tmp/rds-ca/*.pem; do
  if grep -q 'BEGIN CERTIFICATE' "$certificate"; then
    keytool -importcert -noprompt -alias "rds-$(basename "$certificate" .pem)" -file "$certificate" -cacerts -storepass changeit
  fi
done
rm -rf /tmp/rds-ca
