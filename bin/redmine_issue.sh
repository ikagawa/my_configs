#!/usr/bin/env bash
# Redmine issue -> Markdown exporter (+ image attachment downloader)
# Requirements: bash, curl, jq
set -euo pipefail

# ===== Config / Env =====
: "${REDMINE_BASE:?Please set REDMINE_BASE (ex: https://inhouse.garden-grp.co.jp/redmine)}"
: "${REDMINE_API_KEY:?Please set REDMINE_API_KEY}"
REDMINE_CACERT="${REDMINE_CACERT:-}"       # (optional) /path/to/ca.pem
USER_AGENT="${USER_AGENT:-redmine-issue-exporter/1.0}"

# ===== Args =====
if [ $# -lt 1 ]; then
  echo "Usage: $0 <ISSUE_ID>"
  exit 1
fi
ISSUE="$1"

OUT_MD="redmine-issue-${ISSUE}.md"
ASSETS_DIR="redmine-issue-${ISSUE}-assets"

# Curl options (common)
CURL_OPTS=( -sS -H "X-Redmine-API-Key: ${REDMINE_API_KEY}" -H "User-Agent: ${USER_AGENT}" )
if [ -n "${REDMINE_CACERT}" ]; then
  CURL_OPTS+=( --cacert "${REDMINE_CACERT}" )
fi

# ===== Fetch Issue JSON =====
ISSUE_URL="${REDMINE_BASE%/}/issues/${ISSUE}.json?include=journals,attachments,children,relations"
JSON="$(curl --fail "${CURL_OPTS[@]}" "${ISSUE_URL}")"

# ===== Generate Markdown (no repetition) =====
printf "%s" "${JSON}" | jq -r '
  def h(s): (s // "") | gsub("\r\n|\r|\n"; "\n");

  .issue as $i
  | (
      ($i.attachments // [])
      | map("- " + .filename + " (" + (.filesize|tostring) + " bytes)\n" + (.content_url // ""))
      | join("\n")
    ) as $ATT

  | (
      ($i.journals // [])
      | map(
          "### " + .created_on + " — " + .user.name + "\n"
          + h(.notes)
          + (if (.details // []) | length > 0
               then "\n**Changes:**\n"
                 + ((.details // [])
                    | map("- " + (.name // "")
                          + ": " + ((.old_value // "")|tostring)
                          + " → " + ((.new_value // "")|tostring))
                    | join("\n"))
               else "" end)
        )
      | join("\n\n")
    ) as $JRN

  | [
      "# [" + ($i.tracker.name+" #"+($i.id|tostring)) + "] " + $i.subject,
      "- **Status:** " + $i.status.name
        + "  - **Priority:** " + $i.priority.name
        + "  - **Assignee:** " + ($i.assigned_to.name // "-")
        + "  - **Author:** " + $i.author.name
        + "  - **Updated:** " + $i.updated_on,
      "",
      "## Description",
      h($i.description),
      (if ($i.attachments // []) | length > 0 then "\n## Attachments\n" + $ATT else "" end),
      (if ($i.journals    // []) | length > 0 then "\n## Journals\n"    + $JRN else "" end)
    ]
  | join("\n")
' > "${OUT_MD}"

# ===== Image Attachment Download =====
mkdir -p "${ASSETS_DIR}"

mapfile -t IMG_LINES < <(
  printf "%s" "${JSON}" | jq -r '
    .issue.attachments // []
    | map(select((.content_type // "") | startswith("image/")))
    | map([(.id|tostring), (.filename // ""), (.content_url // "")] | @tsv)
    | .[]
  '
)

sanitize() { printf "%s" "$1" | sed -E 's/[^A-Za-z0-9._-]+/_/g'; }

sign_url() {
  local url="$1"
  # 相対URLを絶対化
  if [[ "$url" = /* ]]; then
    url="${REDMINE_BASE%/}${url}"
  fi
  # すでに key= があればそのまま
  if [[ "$url" == *"?key="* || "$url" == *"&key="* ]]; then
    printf "%s" "$url"; return
  fi
  # 同一 Redmine の attachments は ?key= を付与
  if [[ "$url" == "${REDMINE_BASE%/}/attachments/"* || \
        "$url" == "${REDMINE_BASE%/}/attachments/download/"* ]]; then
    if [[ "$url" == *\?* ]]; then
      printf "%s&key=%s" "$url" "$REDMINE_API_KEY"
    else
      printf "%s?key=%s" "$url" "$REDMINE_API_KEY"
    fi
  else
    printf "%s" "$url"
  fi
}

DOWNLOADED_LIST=()

for line in "${IMG_LINES[@]:-}"; do
  IFS=$'\t' read -r att_id att_name att_url <<< "$line"
  # URLが空ならスキップ
  if [[ -z "${att_url}" ]]; then
    echo "⚠️  Skip: empty attachment URL for id=${att_id}" >&2
    continue
  fi
  safe_name="$(sanitize "${att_name}")"
  target="${ASSETS_DIR}/${att_id}-${safe_name}"
  signed="$(sign_url "${att_url}")"

  if curl --fail -L "${CURL_OPTS[@]}" -o "${target}" "${signed}"; then
    DOWNLOADED_LIST+=("${target}")
  else
    echo "⚠️  Failed to download: ${signed}" >&2
  fi
done

if [ "${#DOWNLOADED_LIST[@]}" -gt 0 ]; then
  {
    echo -e "\n## Downloaded Images"
    for p in "${DOWNLOADED_LIST[@]}"; do
      echo ""
      echo "![](${p})"
      echo "<sub>${p}</sub>"
    done
    echo ""
  } >> "${OUT_MD}"
fi

echo "✅ Created: ${OUT_MD}"
if [ "${#DOWNLOADED_LIST[@]}" -gt 0 ]; then
  echo "🖼  Downloaded ${#DOWNLOADED_LIST[@]} images → ${ASSETS_DIR}/"
fi

