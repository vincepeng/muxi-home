#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_HTML="${LOCAL_HTML:-$ROOT_DIR/index.html}"
REGION_ID="${REGION_ID:-cn-hongkong}"
INSTANCE_ID="${INSTANCE_ID:-i-j6c2weup37y3mywpld9e}"
REMOTE_TMP_DIR="${REMOTE_TMP_DIR:-/tmp/muxi-home-upload}"
REMOTE_SITE_DIR="${REMOTE_SITE_DIR:-/usr/share/nginx/html/muxi-home}"
PUBLIC_ASSET_BASE="${PUBLIC_ASSET_BASE:-https://vincepeng.github.io/muxi-home/}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

GENERATED_HTML="$WORK_DIR/index.html"
PART_DIR="$WORK_DIR/parts"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd aliyun
require_cmd python3
require_cmd cat

python3 - <<'PY' "$LOCAL_HTML" "$GENERATED_HTML" "$PUBLIC_ASSET_BASE"
from pathlib import Path
import sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
public_asset_base = sys.argv[3]

text = src.read_text(encoding="utf-8")
needle = '<meta name="viewport" content="width=device-width, initial-scale=1" />\n'
base_tag = f'  <base href="{public_asset_base}" />\n'
if base_tag not in text:
    if needle not in text:
        raise SystemExit("cannot find viewport meta tag to inject <base>")
    text = text.replace(needle, needle + base_tag, 1)
dst.write_text(text, encoding="utf-8")
print(f"generated {dst} ({dst.stat().st_size} bytes)")
PY

python3 - <<'PY' "$GENERATED_HTML" "$PART_DIR"
from pathlib import Path
import base64
import sys

src = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
out_dir.mkdir(parents=True, exist_ok=True)

data = src.read_bytes()
chunk_size = 22000
for i in range(0, len(data), chunk_size):
    chunk = data[i:i + chunk_size]
    part_path = out_dir / f"index.html.b64.part{i // chunk_size:02d}"
    part_path.write_text(base64.b64encode(chunk).decode("ascii"), encoding="ascii")
    print(f"prepared {part_path.name} ({part_path.stat().st_size} chars)")
PY

for part in "$PART_DIR"/index.html.b64.part*; do
  name="$(basename "$part")"
  echo "sending $name"
  aliyun ecs SendFile \
    --RegionId "$REGION_ID" \
    --Name "$name" \
    --TargetDir "$REMOTE_TMP_DIR" \
    --Overwrite true \
    --ContentType Base64 \
    --Content "$(cat "$part")" \
    --InstanceId.1 "$INSTANCE_ID" >/dev/null
done

REMOTE_SCRIPT_B64="$(python3 - <<'PY' "$REMOTE_TMP_DIR" "$REMOTE_SITE_DIR"
import base64
import sys

remote_tmp_dir = sys.argv[1]
remote_site_dir = sys.argv[2]
script = f"""#!/usr/bin/env bash
set -euo pipefail
mkdir -p {remote_site_dir}
cat {remote_tmp_dir}/index.html.b64.part* > {remote_site_dir}/index.html
chown -R root:root {remote_site_dir}
chmod 755 {remote_site_dir}
chmod 644 {remote_site_dir}/index.html
systemctl enable --now nginx
nginx -t
systemctl reload nginx
printf 'deployed-bytes=%s\\n' \"$(wc -c < {remote_site_dir}/index.html)\"
head -n 8 {remote_site_dir}/index.html
"""
print(base64.b64encode(script.encode()).decode())
PY
)"

RUN_RESULT="$(aliyun ecs RunCommand \
  --RegionId "$REGION_ID" \
  --Type RunShellScript \
  --Name muxi-home-deploy-html \
  --ContentEncoding Base64 \
  --InstanceId.1 "$INSTANCE_ID" \
  --Timeout 180 \
  --CommandContent "$REMOTE_SCRIPT_B64")"

INVOKE_ID="$(python3 - <<'PY' "$RUN_RESULT"
import json
import sys
print(json.loads(sys.argv[1])["InvokeId"])
PY
)"

sleep 5
aliyun ecs DescribeInvocationResults \
  --RegionId "$REGION_ID" \
  --InvokeId "$INVOKE_ID" \
  --ContentEncoding PlainText
