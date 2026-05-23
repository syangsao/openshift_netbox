#!/usr/bin/env python3
"""Fix netbox-docker Dockerfile for OpenShift compatibility.

Removes 'unit' web server dependencies and skips mkdocs build.
"""

with open('Dockerfile') as f:
    lines = f.readlines()

out = []
i = 0
while i < len(lines):
    line = lines[i]

    # Skip unit apt source list
    if 'COPY docker/unit.list' in line:
        i += 1
        continue

    # Skip nginx keyring download
    if 'nginx-keyring.gpg' in line:
        i += 1
        continue

    # Remove unit-python3 and unit= from apt-get install line
    if 'unit-python3' in line:
        line = line.replace('      unit-python3.12=1.34.2-1~noble \\\n', '')
    if 'unit=1.34.2' in line:
        line = line.replace('      unit=1.34.2-1~noble \\\n', '')

    # Skip COPY docker/nginx-unit.json line
    if 'COPY docker/nginx-unit.json' in line:
        i += 1
        continue

    # Fix the RUN mkdir block
    # Line: "RUN mkdir -p static media /opt/unit/state/ /opt/unit/tmp/ \"
    if line.strip().startswith('RUN mkdir -p static media /opt/unit/'):
        line = line.replace('/opt/unit/state/ /opt/unit/tmp/', '')

    # Line: "&& chown -R unit:root /opt/unit/ media reports scripts \"
    if 'chown -R unit:root /opt/unit/' in line:
        line = line.replace('chown -R unit:root /opt/unit/', 'chown -R root:root')

    # Line: "&& chmod -R g+w /opt/unit/ media reports scripts \"
    if 'chmod -R g+w /opt/unit/' in line:
        line = line.replace('/opt/unit/ ', '')

    # Replace mkdocs build (2 lines) with echo
    # Line 94: "&& cd /opt/netbox/ && SECRET_KEY=... python -m mkdocs build \"
    # Line 95: "    --config-file /opt/netbox/mkdocs.yml --site-dir ... \"
    if 'SECRET_KEY="dummyKeyWithMinimumLength-------------------------" /opt/netbox/venv/bin/python -m mkdocs build' in line:
        # Replace this line AND skip the next line (--config-file continuation)
        line = '      && cd /opt/netbox/ && echo "Skipping mkdocs build" \\\n'
        out.append(line)
        i += 1  # skip current (already appended)
        i += 1  # skip next line (--config-file)
        continue

    # Fix django-storages sed delimiter
    if 's/django-storages/django-storages\\[azure' in line:
        line = line.replace(
            's/django-storages/django-storages\\[azure,boto3,dropbox,google,libcloud,sftp\\]/g',
            's|django-storages|django-storages[azure,boto3,dropbox,google,libcloud,sftp]|g'
        )

    out.append(line)
    i += 1

with open('Dockerfile', 'w') as f:
    f.writelines(out)

print("Dockerfile patched successfully")
