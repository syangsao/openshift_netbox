#!/usr/bin/env python3
"""Fix netbox-docker Dockerfile for OpenShift compatibility."""

with open('Dockerfile') as f:
    lines = f.readlines()

# Patterns for lines to skip entirely
SKIP_PATTERNS = [
    'unit.list', 'nginx-keyring.gpg',
    'unit-python3', 'unit=',
    'nginx-unit.json',
    '--config-file /opt/netbox/mkdocs.yml',
]

# Pattern to replace in the mkdocs build line
OLD_MKDOCS = 'SECRET_KEY="dummyKeyWithMinimumLength-------------------------" /opt/netbox/venv/bin/python -m mkdocs build'
NEW_MKDOCS = 'echo "Skipping mkdocs build"'

# Pattern to fix in django-storages sed
OLD_STORAGE = "s/django-storages/django-storages\\[azure,boto3,dropbox,google,libcloud,sftp\\]/g"
NEW_STORAGE = "s|django-storages|django-storages[azure,boto3,dropbox,google,libcloud,sftp]|g"

# For the unit RUN line: we need to surgically remove /opt/unit/ paths but keep the rest
UNIT_DIR_PATTERN = '/opt/unit/state/ /opt/unit/tmp/ \\'

out = []
for line in lines:
    # Skip lines matching any skip pattern
    skip = False
    for pattern in SKIP_PATTERNS:
        if pattern in line:
            skip = True
            break
    if skip:
        continue

    # Fix django-storages sed delimiter
    if OLD_STORAGE in line:
        line = line.replace(OLD_STORAGE, NEW_STORAGE)

    # Replace mkdocs build with echo
    if OLD_MKDOCS in line:
        line = line.replace(OLD_MKDOCS, NEW_MKDOCS)

    # Surgically fix the unit directory creation in the RUN mkdir line
    if UNIT_DIR_PATTERN in line:
        line = line.replace(UNIT_DIR_PATTERN, '')

    out.append(line)

with open('Dockerfile', 'w') as f:
    f.writelines(out)

print("Dockerfile patched successfully")
