#!/usr/bin/env bash
# Redmine issue -> Markdown exporter (+ image attachment downloader)
# Requirements: bash, curl, jq
set -euo pipefail

# ===== Args =====
if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 <ISSUE_ID> (numeric)" >&2
  exit 1
fi
ISSUE="$1"

# ===== Config / Env =====
: "${REDMINE_BASE:?Please set REDMINE_BASE (ex: https://redmine.example.com)}"
: "${REDMINE_API_KEY:?Please set REDMINE_API_KEY}"
REDMINE_CACERT="${REDMINE_CACERT:-}"       # (optional) /path/to/ca.pem
USER_AGENT="${USER_AGENT:-redmine-issue-exporter/1.1}"
REDMINE_CONNECT_TIMEOUT="${REDMINE_CONNECT_TIMEOUT:-10}"
REDMINE_REQUEST_TIMEOUT="${REDMINE_REQUEST_TIMEOUT:-120}"
# Additional trusted origins, separated by spaces, e.g. https://files.example.com.
# Only these origins and REDMINE_BASE receive the API-key header.
REDMINE_ATTACHMENT_ORIGINS="${REDMINE_ATTACHMENT_ORIGINS:-}"

for setting in REDMINE_CONNECT_TIMEOUT REDMINE_REQUEST_TIMEOUT; do
  if [[ ! ${!setting} =~ ^[1-9][0-9]{0,5}$ ]]; then
    echo "${setting} must be a positive integer of at most six digits (seconds)." >&2
    exit 1
  fi
done

# Compare scheme, hostname and port, rather than URL prefixes. Reject ambiguous
# authorities (userinfo, escapes, whitespace), and normalize default ports.
url_origin() {
  local url="$1" scheme authority
  local pattern='^(https?)://([^/?#]+)([/?#]|$)'
  [[ ! "$url" =~ [[:space:][:cntrl:]] && "$url" != *\\* ]] || return 1
  [[ "${url,,}" =~ $pattern ]] || return 1
  scheme="${BASH_REMATCH[1]}" authority="${BASH_REMATCH[2]}"
  [[ "$authority" =~ ^(\[[0-9a-f:.]+\]|[a-z0-9._-]+)(:[0-9]+)?$ ]] || return 1
  case "$scheme" in
    http) authority="${authority%:80}" ;;
    https) authority="${authority%:443}" ;;
  esac
  printf '%s://%s' "$scheme" "$authority"
}

if ! BASE_ORIGIN="$(url_origin "$REDMINE_BASE")" || [[ "$REDMINE_BASE" == *[\?#]* ]]; then
  echo "REDMINE_BASE must be an absolute HTTP(S) URL without credentials, query or fragment." >&2
  exit 1
fi
TRUSTED_ORIGINS=("$BASE_ORIGIN")
read -r -a EXTRA_ORIGINS <<< "$REDMINE_ATTACHMENT_ORIGINS"
for origin in "${EXTRA_ORIGINS[@]}"; do
  if ! normalized="$(url_origin "$origin")" || [[ ! "${origin,,}" =~ ^https?://[^/?#]+/?$ ]]; then
    echo "REDMINE_ATTACHMENT_ORIGINS must contain HTTP(S) origins without paths or credentials." >&2
    exit 1
  fi
  TRUSTED_ORIGINS+=("$normalized")
done

is_trusted_origin() {
  local candidate="$1" origin
  for origin in "${TRUSTED_ORIGINS[@]}"; do
    [[ "$candidate" != "$origin" ]] || return 0
  done
  return 1
}

OUT_MD="${ISSUE}.md"
ASSETS_NAME="${ISSUE}-assets"
ASSETS_DIR="$ASSETS_NAME"

# Curl options (common)
CURL_OPTS=( --silent --show-error --fail --globoff --proto '=http,https'
  --connect-timeout "$REDMINE_CONNECT_TIMEOUT" --max-time "$REDMINE_REQUEST_TIMEOUT"
  --user-agent "$USER_AGENT" )
if [ -n "${REDMINE_CACERT}" ]; then
  CURL_OPTS+=( --cacert "${REDMINE_CACERT}" )
fi
API_CURL_OPTS=( "${CURL_OPTS[@]}" --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" )

# ===== Fetch Issue JSON =====
ISSUE_URL="${REDMINE_BASE%/}/issues/${ISSUE}.json?include=journals,attachments,children,relations"
# -q must be the first option: ignore curlrc settings, including redirects.
JSON="$(curl -q "${API_CURL_OPTS[@]}" "$ISSUE_URL")"
if ! printf '%s' "$JSON" | jq -e '.issue | type == "object"' >/dev/null; then
  echo "Invalid Redmine response: expected an issue object." >&2
  exit 1
fi

# ===== Resolve journal IDs to names =====
# Seed names from the issue itself, including journal authors. This avoids
# needing admin access to the users list just to identify past assignees.
NAMES="$(printf '%s' "$JSON" | jq '
  def index_names: map(select(.id != null and .name != null)
    | {key: (.id | tostring), value: .name}) | from_entries;
  .issue | {
    status_id: ([.status] | index_names),
    priority_id: ([.priority] | index_names),
    tracker_id: ([.tracker] | index_names),
    project_id: ([.project] | index_names),
    category_id: ([.category] | index_names),
    fixed_version_id: ([.fixed_version] | index_names),
    assigned_to_id: ([.author, .assigned_to, .journals[]?.user] | index_names)
  }
')"

# Lookup endpoints may be forbidden or unavailable on older installations.
# Keep exporting in that case; unresolved values are explicitly shown as IDs.
lookup() {
  local path="$1" payload
  if payload="$(curl -q "${API_CURL_OPTS[@]}" "${REDMINE_BASE%/}/${path}" 2>/dev/null)" \
     && printf '%s' "$payload" | jq -e 'type == "object" and (has("errors") | not)' >/dev/null 2>&1; then
    printf '%s' "$payload"
  else
    echo "Warning: cannot read ${path}; some journal values may remain IDs." >&2
    printf '{}'
  fi
}

merge_names() {
  local field="$1" entries="$2"
  NAMES="$(printf '%s' "$NAMES" | jq --arg field "$field" --argjson entries "$entries" '
    .[$field] += ($entries | map(select(.id != null and .name != null)
      | {key: (.id | tostring), value: .name}) | from_entries)
  ')"
}

PROJECT_ID="$(printf '%s' "$JSON" | jq -r '.issue.project.id // empty')"
for field in status_id priority_id tracker_id category_id fixed_version_id; do
  # Fetch a list only when a journal actually contains that field.
  if ! printf '%s' "$JSON" | jq -e --arg field "$field" '
    any(.issue.journals[]?.details[]?; .property == "attr" and .name == $field)
  ' >/dev/null; then
    continue
  fi
  case "$field" in
    status_id) path="issue_statuses.json"; key="issue_statuses" ;;
    priority_id) path="enumerations/issue_priorities.json"; key="issue_priorities" ;;
    tracker_id) path="trackers.json"; key="trackers" ;;
    category_id) path="projects/${PROJECT_ID}/issue_categories.json"; key="issue_categories" ;;
    fixed_version_id) path="projects/${PROJECT_ID}/versions.json"; key="versions" ;;
  esac
  payload="$(lookup "$path")"
  merge_names "$field" "$(printf '%s' "$payload" | jq --arg key "$key" '.[$key] // []')"
done

# Resolve each otherwise unknown principal once. Assignees can also be groups.
mapfile -t USER_IDS < <(printf '%s' "$JSON" | jq -r --argjson names "$NAMES" '
  [.issue.journals[]?.details[]?
   | select(.property == "attr" and .name == "assigned_to_id")
   | (.old_value, .new_value) | select(. != null and . != "") | tostring
   | select(test("^[0-9]+$")) | select($names.assigned_to_id[.] == null)]
  | unique[]
')
for user_id in "${USER_IDS[@]}"; do
  payload="$(lookup "users/${user_id}.json")"
  entries="$(printf '%s' "$payload" | jq '[.user // empty | {
    id, name: (.name // ([.firstname, .lastname] | map(select(. != null and . != "")) | join(" ")))
  } | select(.name != "")]')"
  if [[ "$entries" == '[]' ]]; then
    payload="$(lookup "groups/${user_id}.json")"
    entries="$(printf '%s' "$payload" | jq '[.group // empty]')"
  fi
  merge_names assigned_to_id "$entries"
done

# ===== Download images before rendering local references =====
WORK_DIR="$(mktemp -d ".redmine-issue-${ISSUE}.XXXXXX")"
TEMP_IMAGE=""
cleanup() {
  rm -rf -- "$WORK_DIR"
  if [[ -n "$TEMP_IMAGE" ]]; then rm -f -- "$TEMP_IMAGE"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

resolve_attachment_url() {
  case "$1" in
    //*) printf '%s:%s' "${BASE_ORIGIN%%:*}" "$1" ;;
    /*) printf '%s%s' "$BASE_ORIGIN" "$1" ;;
    *:*) printf '%s' "$1" ;;
    *) printf '%s/%s' "${REDMINE_BASE%/}" "$1" ;;
  esac
}

# curl forwards custom headers across redirects with -L. Follow at most five
# redirects ourselves, rebuilding authentication for each origin. A single
# deadline bounds the whole download, including all redirect requests.
download_image() {
  local url="$1" output="$2" origin previous_origin="" response status
  local deadline=$((SECONDS + REDMINE_REQUEST_TIMEOUT)) remaining hop
  local -a options
  for ((hop = 0; hop <= 5; hop++)); do
    origin="$(url_origin "$url")" || return 1
    if [[ "$previous_origin" == https://* && "$origin" == http://* ]]; then
      return 1
    fi
    remaining=$((deadline - SECONDS))
    ((remaining > 0)) || return 1
    options=( "${CURL_OPTS[@]}" --max-time "$remaining" )
    if is_trusted_origin "$origin"; then
      options+=( --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" )
    fi
    # Authenticate through headers, never by appending the API key to a URL.
    # Suppress curl errors so signed URLs cannot leak into diagnostics.
    response="$(curl -q "${options[@]}" --output "$output" \
      --write-out $'%{http_code}\n%{redirect_url}' "$url" 2>/dev/null)" || return 1
    status="${response%%$'\n'*}"
    case "$status" in
      200) return 0 ;;
      301|302|303|307|308)
        [[ "$response" == *$'\n'* ]] || return 1
        previous_origin="$origin"
        url="${response#*$'\n'}"
        [[ -n "$url" ]] || return 1
        ;;
      *) return 1 ;;
    esac
  done
  return 1
}

DOWNLOADED='[]'
mapfile -t IMAGES < <(printf '%s' "$JSON" | jq -c '
  .issue.attachments[]? | select((.content_type // "") | startswith("image/"))
')
if ((${#IMAGES[@]} > 0)); then mkdir -p -- "$ASSETS_DIR"; fi
for attachment in "${IMAGES[@]}"; do
  att_id="$(printf '%s' "$attachment" | jq -r '.id | tostring')"
  att_name="$(printf '%s' "$attachment" | jq -r '.filename // ""')"
  att_url="$(printf '%s' "$attachment" | jq -r '.content_url // ""')"
  if [[ ! "$att_id" =~ ^[0-9]+$ || -z "$att_name" || -z "$att_url" ]]; then
    echo "Warning: skipping image attachment with missing or invalid metadata." >&2
    continue
  fi
  safe_name="$(printf '%s' "$att_name" | sed -E 's/[^A-Za-z0-9._-]+/_/g')"
  target="${ASSETS_DIR}/${att_id}-${safe_name}"
  # A sibling temporary file guarantees the final rename stays on the same
  # filesystem. An interrupted or failed transfer leaves existing files intact.
  TEMP_IMAGE="$(mktemp "${ASSETS_DIR}/.${att_id}.XXXXXX")"
  if download_image "$(resolve_attachment_url "$att_url")" "$TEMP_IMAGE"; then
    mv -f -- "$TEMP_IMAGE" "$target"
    DOWNLOADED="$(printf '%s' "$DOWNLOADED" | jq --argjson id "$att_id" \
      --arg filename "$att_name" --arg path "${ASSETS_NAME}/${att_id}-${safe_name}" \
      '. + [{id: $id, filename: $filename, path: $path}]')"
  else
    echo "Warning: failed to download attachment ${att_id}; existing file preserved." >&2
    rm -f -- "$TEMP_IMAGE"
  fi
  TEMP_IMAGE=""
done

# ===== Generate Markdown =====
TEMP_MD="${WORK_DIR}/issue.md"
printf "%s" "${JSON}" | jq -r --argjson names "$NAMES" --argjson downloaded "$DOWNLOADED" '
  def h(s): (if s == null then "" else s end) | tostring | gsub("\r\n|\r"; "\n")
    | gsub("[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]"; "");
  def escape_alt: gsub("(?<c>[\\\\\\[\\]])"; "\\" + .c);
  def escape_regex: gsub("(?<c>[\\\\.^$|?*+(){}\\[\\]])"; "\\" + .c);
  # Redmine permits duplicate filenames. Prefer the newest successful download.
  ($downloaded | sort_by(.id) | map({key: .filename, value: .path}) | from_entries) as $images
  | ($images | keys | sort_by(length) | reverse | map(escape_regex) | join("|")) as $image_pattern
  |
  # Convert known Textile attachment images, including optional alt text.
  # Keep code spans/fences and unknown or failed attachments unchanged.
  def inline_images:
    if ($images | length) == 0 then . else
    gsub("(?<code>(?<ticks>`+)[\\s\\S]*?\\k<ticks>|(?<tildes>~{3,})[\\s\\S]*?\\k<tildes>)|!(?<filename>"
      + $image_pattern + ")(?:\\((?<alt>[^()!\\r\\n]*)\\))?!";
      if .code != null then .code
      else "![" + ((.alt // "") | escape_alt) + "](" + $images[.filename] + ")"
      end) end;
  def field_label:
    {status_id: "Status", priority_id: "Priority", tracker_id: "Tracker",
     assigned_to_id: "Assignee", project_id: "Project", category_id: "Category",
     fixed_version_id: "Target version", subject: "Subject", description: "Description",
     start_date: "Start date", due_date: "Due date", done_ratio: "Progress (%)",
     estimated_hours: "Estimated hours", parent_id: "Parent issue",
     is_private: "Private"}[.] // .;
  def value($field; $v):
    if $v == null or $v == "" then "(none)"
    elif $names | has($field) then
      h($names[$field][$v | tostring] // ("ID " + ($v | tostring)))
    else h($v) end;

  .issue as $i
  | (
      ($i.attachments // [])
      | map("- " + .filename + " (" + (.filesize|tostring) + " bytes)\n" + (.content_url // ""))
      | join("\n")
    ) as $ATT

  | (
      ($i.journals // [])
      | map(
          "### " + .created_on + " - " + .user.name + "\n"
          + (h(.notes) | inline_images)
          + (if (.details // []) | length > 0
               then "\n**Changes:**\n"
                 + ((.details // [])
                    | map(
                        if .property == "attachment" then
                          "- Attachment: " + value("attachment"; .old_value)
                          + " → " + value("attachment"; .new_value)
                        elif .property == "cf" then
                          .name as $id
                          | "- " + h(([$i.custom_fields[]? | select((.id | tostring) == $id) | .name][0])
                              // ("Custom field " + $id))
                          + ": " + value("custom"; .old_value) + " → " + value("custom"; .new_value)
                        else
                          "- " + ((.name // "Change") | field_label | h(.))
                          + ": " + value(.name; .old_value) + " → " + value(.name; .new_value)
                        end)
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
      (h($i.description) | inline_images),
      (if ($i.attachments // []) | length > 0 then "\n## Attachments\n" + $ATT else "" end),
      (if ($i.journals    // []) | length > 0 then "\n## Journals\n"    + $JRN else "" end),
      (if $downloaded | length > 0 then "\n## Downloaded Images\n"
        + ($downloaded | map("![](" + .path + ")") | join("\n\n")) else "" end)
    ]
  | join("\n")
  | h(.)
' > "${TEMP_MD}"
mv -- "$TEMP_MD" "$OUT_MD"

echo "Created: ${OUT_MD}"
COUNT="$(printf '%s' "$DOWNLOADED" | jq 'length')"
if ((COUNT > 0)); then
  echo "Downloaded ${COUNT} images → ${ASSETS_DIR}/"
fi
