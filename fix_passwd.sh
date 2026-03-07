#!/bin/sh
# Fix /etc/passwd root entry to use x (shadow mode)
awk 'BEGIN{FS=":"; OFS=":"} /^root:/{$2="x"; print; next} {print}' /etc/passwd > /data/tmp/passwd.new
cp /data/tmp/passwd.new /etc/passwd
rm -f /data/tmp/passwd.new
grep ^root /etc/passwd
echo done
