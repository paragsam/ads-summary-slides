#!/usr/bin/env bash
# upload_to_google_drive.sh — Upload a file to Google Drive using the gws CLI.
#
# To swap in a different storage backend (Dropbox, S3, etc.),
# replace the implementation below while keeping the same interface.
#
# Usage:
#   ./upload_to_google_drive.sh \
#     --file output/report.pptx \
#     --folder-id 1AbCdEfGhIjKlMnOpQrStUvWx \
#     --title "Weekly Brand Report — May 2026"
#
# Outputs the Drive URL to stdout on success.
# Exits non-zero and prints error to stderr on failure.

set -euo pipefail

FILE=""
FOLDER_ID=""
TITLE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --file)      FILE="$2";      shift 2 ;;
        --folder-id) FOLDER_ID="$2"; shift 2 ;;
        --title)     TITLE="$2";     shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$FILE" || -z "$FOLDER_ID" || -z "$TITLE" ]]; then
    echo "Usage: upload_to_google_drive.sh --file <path> --folder-id <id> --title <title>" >&2
    exit 1
fi

if [[ ! -f "$FILE" ]]; then
    echo "File not found: $FILE" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Proxy passthrough — gws uses lowercase vars; propagate if not already set
# ---------------------------------------------------------------------------
[[ -z "${http_proxy:-}"  && -n "${HTTP_PROXY:-}"  ]] && export http_proxy="$HTTP_PROXY"
[[ -z "${https_proxy:-}" && -n "${HTTPS_PROXY:-}" ]] && export https_proxy="$HTTPS_PROXY"

# ---------------------------------------------------------------------------
# Upload implementation — swap this block to change storage backend
# ---------------------------------------------------------------------------

# Step 1: upload the file and capture the new file ID
UPLOAD_OUTPUT=$(gws drive files create \
    --upload "$FILE" \
    --json "{\"name\":$(printf '%s' "$TITLE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),\"parents\":[\"$FOLDER_ID\"]}" \
    2>&1) || { echo "$UPLOAD_OUTPUT" >&2; exit 1; }

FILE_ID=$(echo "$UPLOAD_OUTPUT" | python3 -c \
    'import sys,json; s=sys.stdin.read(); d=json.loads(s[s.index("{"):s.rindex("}")+1]); print(d["id"])' 2>/dev/null || true)

if [[ -z "$FILE_ID" ]]; then
    echo "$UPLOAD_OUTPUT" >&2
    exit 1
fi

# Step 2: construct the Slides URL from the file ID
echo "https://docs.google.com/presentation/d/${FILE_ID}/view"
