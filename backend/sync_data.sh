#!/usr/bin/env bash

# Check environment variables
if [[ -z "$WEBDAV_URL" ]] || [[ -z "$WEBDAV_USERNAME" ]] || [[ -z "$WEBDAV_PASSWORD" ]]; then
    echo "Missing WEBDAV_URL, WEBDAV_USERNAME, or WEBDAV_PASSWORD. Backup feature will be disabled on startup."
    exit 0
fi

# Set backup path
WEBDAV_BACKUP_PATH=${WEBDAV_BACKUP_PATH:-""}
if [ -n "$WEBDAV_BACKUP_PATH" ]; then
    FULL_WEBDAV_URL="${WEBDAV_URL}/${WEBDAV_BACKUP_PATH}"
else
    FULL_WEBDAV_URL="${WEBDAV_URL}"
fi

# Set max number of backup files
MAX_BACKUP_FILES=${MAX_BACKUP_FILES:-5}
if [ "$MAX_BACKUP_FILES" -le 0 ]; then
    MAX_BACKUP_FILES=5
fi

# Set encryption password (if empty, do not encrypt) and trim whitespace
BACKUP_ENCRYPT_PASSWORD=$(echo "${BACKUP_ENCRYPT_PASSWORD:-""}" | xargs)
if [ -n "$BACKUP_ENCRYPT_PASSWORD" ]; then
    echo "Encryption password is set. Encrypted compression will be used."
else
    echo "No encryption password set. Plain compression will be used."
fi

# Download the latest backup and restore
restore_backup() {
    echo "Starting to download the latest backup from WebDAV..."
    python3 <<PYCODE
import sys
import os
import tarfile
import requests
import subprocess
import shutil
from webdav3.client import Client

# Shell-expanded variables
FULL_WEBDAV_URL = "${FULL_WEBDAV_URL}"
WEBDAV_USERNAME = "${WEBDAV_USERNAME}"
WEBDAV_PASSWORD = "${WEBDAV_PASSWORD}"
BACKUP_ENCRYPT_PASSWORD = "${BACKUP_ENCRYPT_PASSWORD}"

options = {
    'webdav_hostname': FULL_WEBDAV_URL,
    'webdav_login': WEBDAV_USERNAME,
    'webdav_password': WEBDAV_PASSWORD
}
client = Client(options)

backups = [f for f in client.list() if f.startswith('webui_backup_') and f.endswith('.tar.gz')]
if not backups:
    print('No backup file found')
    sys.exit(0)
latest = sorted(backups)[-1]
print(f'Latest backup file: {latest}')

tmp_archive = f'/tmp/{latest}'
with requests.get(f'{FULL_WEBDAV_URL}/{latest}', auth=(WEBDAV_USERNAME, WEBDAV_PASSWORD), stream=True) as r:
    r.raise_for_status()
    with open(tmp_archive, 'wb') as fp:
        for chunk in r.iter_content(8192):
            fp.write(chunk)
print(f'Downloaded successfully to {tmp_archive}')

temp_dir = '/tmp/restore'
shutil.rmtree(temp_dir, ignore_errors=True)
os.makedirs(temp_dir, exist_ok=True)
success = False

# Plain decompression
try:
    print('Attempting plain decompression...')
    with tarfile.open(tmp_archive, 'r:gz') as t:
        t.extractall(temp_dir)
    print('Plain decompression succeeded')
    success = True
except Exception as e:
    print(f'Plain decompression failed: {e}')

# Decrypt and decompress with password
if not success and BACKUP_ENCRYPT_PASSWORD:
    try:
        print('Attempting decryption...')
        dec_file = '/tmp/decrypted.tar'
        cmd = (
            f"openssl enc -aes-256-cbc -pbkdf2 -d -salt "
            f"-k '{BACKUP_ENCRYPT_PASSWORD}' "
            f"-in {tmp_archive} "
            f"-out {dec_file}"
        )
        subprocess.run(cmd, shell=True, check=True)
        with tarfile.open(dec_file, 'r') as t:
            t.extractall(temp_dir)
        os.remove(dec_file)
        print('Decryption and decompression succeeded')
        success = True
    except Exception as e:
        print(f'Decryption failed: {e}')

if not success:
    print('All decompression methods failed. Exiting.')
    sys.exit(1)

# Move webui.db
for root, _, files in os.walk(temp_dir):
    if 'webui.db' in files:
        src = os.path.join(root, 'webui.db')
        os.makedirs('./data', exist_ok=True)
        dst = './data/webui.db'
        os.replace(src, dst)
        shutil.copy2(dst, '/tmp/webui.db.prev')
        print(f'Restore successful: {dst}')
        break
else:
    print('webui.db not found')

# Cleanup
shutil.rmtree(temp_dir, ignore_errors=True)
os.remove(tmp_archive)
PYCODE
}

echo "Performing initial restore..."
restore_backup

# Sync and periodic backup
sync_data() {
    while true; do
        echo "[$(date)] Starting a sync backup"

        if [ -f "./data/webui.db" ]; then
            if [ -f "/tmp/webui.db.prev" ] && cmp -s "./data/webui.db" "/tmp/webui.db.prev"; then
                echo "Database unchanged. Skipping backup."
                sleep "${SYNC_INTERVAL:-600}"
                continue
            fi

            timestamp=$(date +%Y%m%d_%H%M%S)
            backup_name="webui_backup_${timestamp}.tar.gz"

            # Prepare packaging
            rm -rf /tmp/data
            mkdir -p /tmp/data
            cp ./data/webui.db /tmp/data/

            cd /tmp || exit
            if [ -n "$BACKUP_ENCRYPT_PASSWORD" ]; then
                tar -cf - data | \
                  openssl enc -aes-256-cbc -salt -pbkdf2 -k "$BACKUP_ENCRYPT_PASSWORD" \
                  -out "${backup_name}"
                echo "Encrypted and packed -> ${backup_name}"
            else
                tar -czf "${backup_name}" data
                echo "Plain packed -> ${backup_name}"
            fi
            cd - >/dev/null

            # Upload
            curl -s -o /dev/null -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" \
                 -T "/tmp/${backup_name}" \
                 "$FULL_WEBDAV_URL/${backup_name}"
            if [ $? -eq 0 ]; then
                echo "Upload succeeded -> ${backup_name}"
                cp /tmp/data/webui.db /tmp/webui.db.prev
            else
                echo "Upload failed -> ${backup_name}"
            fi

            rm -rf /tmp/data
            rm -f /tmp/${backup_name}

            # Clean old backups
            python3 <<PYCODE
import os
import sys
from webdav3.client import Client

FULL_WEBDAV_URL = "${FULL_WEBDAV_URL}"
WEBDAV_USERNAME = "${WEBDAV_USERNAME}"
WEBDAV_PASSWORD = "${WEBDAV_PASSWORD}"
MAX_FILES = int("${MAX_BACKUP_FILES}")

options = {
    'webdav_hostname': FULL_WEBDAV_URL,
    'webdav_login': WEBDAV_USERNAME,
    'webdav_password': WEBDAV_PASSWORD
}
client = Client(options)

backs = sorted([f for f in client.list()
                if f.startswith('webui_backup_') and f.endswith('.tar.gz')])
if len(backs) > MAX_FILES:
    for fn in backs[:len(backs) - MAX_FILES]:
        client.clean(fn)
        print(f'Deleted old backup: {fn}')
else:
    print(f'Total backups: {len(backs)}. No cleanup needed.')
PYCODE

        else
            echo "No ./data/webui.db found. Waiting for next round."
        fi

        echo "Next sync in ${SYNC_INTERVAL:-600} seconds"
        sleep "${SYNC_INTERVAL:-600}"
    done
}

# Run in background
sync_data &
