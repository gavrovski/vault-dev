#!/bin/sh -x
set -e
apk update
apk add jq
mkdir -p /opt/
mv /tmp/run.sh /opt/
chmod a+x /opt/run.sh
rm -rf /var/cache/apk/*