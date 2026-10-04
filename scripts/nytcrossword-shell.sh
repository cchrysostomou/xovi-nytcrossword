#!/bin/bash
# Python-free backend for the NYT Crossword AppLoad app. Every command prints
# exactly one JSON object on stdout.
set -eu

VERSION="0.3.0"
CONFIG="${NYTCROSSWORD_CONFIG:-}"
STATE_DIR="${NYTCROSSWORD_STATE_DIR:-/home/root/xovi-nytcrossword/state}"
WORK=""
BROKER_REPLY=""
WORKER=""

json_escape() {
  printf '%s' "$1" |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' |
    tr -d '\n\r'
}

fail() {
  printf '{"ok":false,"error":"%s","message":"%s"}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")"
  exit "${3:-1}"
}

cleanup() {
  if [ -n "$WORKER" ]; then
    kill -KILL "$WORKER" 2>/dev/null || :
    wait "$WORKER" 2>/dev/null || :
    WORKER=""
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf -- "$WORK"
  fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Reads KEY from the KEY=value config file without sourcing it.
config_value() {
  [ -n "$CONFIG" ] && [ -f "$CONFIG" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONFIG" |
    tail -n 1 | tr -d '\r'
}

command_path() {
  command -v "$1" 2>/dev/null || true
}

find_curl() {
  if [ -n "${NYTCROSSWORD_CURL:-}" ] && [ -x "$NYTCROSSWORD_CURL" ]; then
    printf '%s' "$NYTCROSSWORD_CURL"
  elif [ -x /home/root/.vellum/bin/curl ]; then
    printf '%s' /home/root/.vellum/bin/curl
  else
    command_path curl
  fi
}

find_merger() {
  if [ -n "${NYTCROSSWORD_QPDF:-}" ] && [ -x "$NYTCROSSWORD_QPDF" ]; then
    printf 'qpdf:%s' "$NYTCROSSWORD_QPDF"
  elif command -v qpdf >/dev/null 2>&1; then
    printf 'qpdf:%s' "$(command -v qpdf)"
  elif [ -n "${NYTCROSSWORD_MUTOOL:-}" ] && [ -x "$NYTCROSSWORD_MUTOOL" ]; then
    printf 'mutool:%s' "$NYTCROSSWORD_MUTOOL"
  elif command -v mutool >/dev/null 2>&1; then
    printf 'mutool:%s' "$(command -v mutool)"
  fi
}

bool_for_command() {
  if command -v "$1" >/dev/null 2>&1; then
    printf true
  else
    printf false
  fi
}

pdf_valid() {
  [ -f "$1" ] && [ -s "$1" ] &&
    [ "$(dd if="$1" bs=5 count=1 2>/dev/null)" = "%PDF-" ]
}

uuid_valid() {
  printf '%s' "$1" |
    grep -Eq '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'
}

validate_folder() {
  folder=$1
  [ -n "$folder" ] || fail invalid_destination "The destination folder is empty."
  case "$folder" in
    *'
'*|*','*) fail invalid_destination "The destination folder cannot contain commas or newlines." ;;
    /*) ;;
    *) fail invalid_destination "The destination folder must be an absolute library path." ;;
  esac
  case "$folder" in
    */|*//*)
      fail invalid_destination "The destination folder contains an empty path component."
      ;;
  esac
}

puzzle_id_for_iso_date() {
  iso_year=${1%%-*}
  iso_rest=${1#*-}
  iso_month=${iso_rest%%-*}
  iso_day=${iso_rest#*-}
  case "$iso_month" in
    01) month_name=Jan ;; 02) month_name=Feb ;; 03) month_name=Mar ;;
    04) month_name=Apr ;; 05) month_name=May ;; 06) month_name=Jun ;;
    07) month_name=Jul ;; 08) month_name=Aug ;; 09) month_name=Sep ;;
    10) month_name=Oct ;; 11) month_name=Nov ;; 12) month_name=Dec ;;
    *) fail invalid_range "A date contains an invalid month." 2 ;;
  esac
  short_year=${iso_year#??}
  PUZZLE_ID_RESULT="$month_name$iso_day$short_year"
}

next_calendar_date() {
  local year=${1:0:4} month=${1:5:2} day=${1:8:2} days
  year=$((10#$year)); month=$((10#$month)); day=$((10#$day))
  case "$month" in
    4|6|9|11) days=30 ;;
    2)
      days=28
      if ((year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))); then days=29; fi ;;
    *) days=31 ;;
  esac
  ((day >= 1 && day <= days && month >= 1 && month <= 12)) ||
    fail invalid_range "A date is not a valid calendar date." 2
  day=$((day + 1))
  if ((day > days)); then day=1; month=$((month + 1)); fi
  if ((month > 12)); then month=1; year=$((year + 1)); fi
  printf -v NEXT_DATE '%04d-%02d-%02d' "$year" "$month" "$day"
}

validate_range() {
  START_DATE=$1
  END_DATE=$2
  PUZZLE_IDS=$3

  [[ "$START_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ &&
     "$END_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
    fail invalid_range "Dates must use YYYY-MM-DD format." 2
  first_date=$(printf '%s\n%s\n' "$START_DATE" "$END_DATE" | sort | head -n 1)
  [ "$first_date" = "$START_DATE" ] ||
    fail invalid_range "The start date must not be after the end date." 2

  today=$(date '+%Y-%m-%d') ||
    fail missing_dependency "The date command is required."
  first_date=$(printf '%s\n%s\n' "$END_DATE" "$today" | sort | head -n 1)
  [ "$first_date" = "$END_DATE" ] ||
    fail invalid_range "Future crossword dates are not available." 2

  [ -n "$PUZZLE_IDS" ] ||
    fail invalid_range "At least one puzzle date is required." 2
  old_ifs=$IFS
  IFS=,
  set -- $PUZZLE_IDS
  IFS=$old_ifs
  COUNT=$#
  [ "$COUNT" -ge 1 ] && [ "$COUNT" -le 31 ] ||
    fail invalid_range "Choose between 1 and 31 puzzles." 2

  seen=","
  cursor=$START_DATE
  first_puzzle_id=""
  last_puzzle_id=""
  for puzzle_id in "$@"; do
    next_calendar_date "$cursor"
    puzzle_id_for_iso_date "$cursor"
    [ "$puzzle_id" = "$PUZZLE_ID_RESULT" ] ||
      fail invalid_range "Puzzle dates must cover the entire range in date order." 2
    cursor=$NEXT_DATE
    printf '%s' "$puzzle_id" |
      grep -Eq '^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)(0[1-9]|[12][0-9]|3[01])[0-9]{2}$' ||
      fail invalid_range "A puzzle identifier is invalid." 2
    case "$seen" in
      *",$puzzle_id,"*) fail invalid_range "The date range contains a duplicate puzzle." 2 ;;
    esac
    seen="${seen}${puzzle_id},"
    [ -n "$first_puzzle_id" ] || first_puzzle_id=$puzzle_id
    last_puzzle_id=$puzzle_id
  done
  puzzle_id_for_iso_date "$START_DATE"
  [ "$first_puzzle_id" = "$PUZZLE_ID_RESULT" ] ||
    fail invalid_range "The first puzzle does not match the start date." 2
  puzzle_id_for_iso_date "$END_DATE"
  [ "$last_puzzle_id" = "$PUZZLE_ID_RESULT" ] ||
    fail invalid_range "The last puzzle does not match the end date." 2
  next_calendar_date "$END_DATE"
  [ "$cursor" = "$NEXT_DATE" ] ||
    fail invalid_range "Puzzle dates do not cover the selected range." 2
}

destination_folder() {
  base=$(config_value CROSSWORD_FOLDER)
  [ -n "$base" ] || base=$(config_value RMAPI_FOLDER)
  [ -n "$base" ] || base=/Crosswords
  base=${base%/}
  local month=${END_DATE:5:2}
  local names=(January February March April May June July August September October November December)
  year=${END_DATE%%-*}
  LEGACY_MONTH_DESTINATION="$base/$year/${month}_${names[$((10#$month - 1))]}"
  MONTH_DESTINATION="$base/NYT_Cwd_$year/${month}_${names[$((10#$month - 1))]}"
  local y=$((10#$year)) m=$((10#$month)) d=$((10#${END_DATE:8:2}))
  local offsets=(0 3 2 5 0 3 5 1 4 6 2 4)
  local weekday week_start week_end last_day cursor
  # Gregorian weekday, with Sunday = 0; avoids GNU date requirements on-device.
  if ((m < 3)); then y=$((y - 1)); fi
  weekday=$(((y + y/4 - y/100 + y/400 + offsets[m-1] + d) % 7))
  week_start=$((d - weekday)); week_end=$((d + 6 - weekday))
  ((week_start >= 1)) || week_start=1
  cursor="${END_DATE:0:7}-01"
  while :; do
    last_day=$((10#${cursor:8:2}))
    next_calendar_date "$cursor"
    [[ ${NEXT_DATE:0:7} == "${END_DATE:0:7}" ]] || break
    cursor=$NEXT_DATE
  done
  ((week_end <= last_day)) || week_end=$last_day
  local week_folder
  printf -v week_folder '%s-%s-%02d-%02d' "$year" "$month" "$week_start" "$week_end"
  DESTINATION="$MONTH_DESTINATION/$week_folder"
  LEGACY_WEEK_DESTINATION="$LEGACY_MONTH_DESTINATION/$week_folder"
  validate_folder "$DESTINATION"
}

plan_groups() {
  local cursor=$START_DATE id key previous="" index=-1
  local saved_end=$END_DATE
  GROUP_STARTS=(); GROUP_ENDS=(); GROUP_IDS=(); GROUP_COUNTS=(); GROUP_DESTINATIONS=()
  local ids
  IFS=, read -r -a ids <<<"$PUZZLE_IDS"
  for id in "${ids[@]}"; do
    END_DATE=$cursor
    destination_folder
    key=$DESTINATION
    if [ "$key" != "$previous" ]; then
      index=$((index + 1))
      GROUP_STARTS[index]=$cursor
      GROUP_IDS[index]=""
      GROUP_COUNTS[index]=0
      GROUP_DESTINATIONS[index]=$DESTINATION
      previous=$key
    fi
    GROUP_ENDS[index]=$cursor
    GROUP_IDS[index]="${GROUP_IDS[index]:+${GROUP_IDS[index]},}$id"
    GROUP_COUNTS[index]=$((GROUP_COUNTS[index] + 1))
    next_calendar_date "$cursor"
    cursor=$NEXT_DATE
  done
  END_DATE=$saved_end
}

groups_json() {
  local index separator=""
  printf '['
  for index in "${!GROUP_STARTS[@]}"; do
    printf '%s{"start_date":"%s","end_date":"%s","count":%s,"destination":"%s"}' \
      "$separator" "${GROUP_STARTS[index]}" "${GROUP_ENDS[index]}" \
      "${GROUP_COUNTS[index]}" "$(json_escape "${GROUP_DESTINATIONS[index]}")"
    separator=,
  done
  printf ']'
}

scan_range() {
  JQ=${NYTCROSSWORD_JQ:-}
  if [ -z "$JQ" ]; then
    if [ -x /home/root/.vellum/bin/jq ]; then JQ=/home/root/.vellum/bin/jq
    else JQ=$(command_path jq); fi
  fi
  [ -n "$JQ" ] && [ -x "$JQ" ] ||
    fail missing_dependency "jq is required to inspect the tablet library."
  library=${NYTCROSSWORD_LIBRARY_DIR:-/home/root/.local/share/remarkable/xochitl}
  [ -d "$library" ] && [ -r "$library" ] ||
    fail library_unavailable "The tablet library directory is unavailable."
  local saved_end=$END_DATE cursor=$START_DATE id separator="" metadata pdf
  local ids
  IFS=, read -r -a ids <<<"$PUZZLE_IDS"
  printf '[' >"$WORK/dates.json"
  for id in "${ids[@]}"; do
    END_DATE=$cursor
    destination_folder
    printf '%s{"date":"%s","puzzle_id":"%s","destination":"%s","legacy_destinations":["%s","%s","%s"]}' \
      "$separator" "$cursor" "$id" "$(json_escape "$DESTINATION")" \
      "$(json_escape "$MONTH_DESTINATION")" "$(json_escape "$LEGACY_MONTH_DESTINATION")" \
      "$(json_escape "$LEGACY_WEEK_DESTINATION")" >>"$WORK/dates.json"
    separator=,
    next_calendar_date "$cursor"; cursor=$NEXT_DATE
  done
  printf ']' >>"$WORK/dates.json"
  END_DATE=$saved_end
  local metadata_files=() pdf_ids=()
  shopt -s nullglob
  for metadata in "$library"/*.metadata; do metadata_files+=("$metadata"); done
  for pdf in "$library"/*.pdf; do
    id=${pdf##*/}; pdf_ids+=("${id%.pdf}")
  done
  shopt -u nullglob
  printf '%s\n' "${pdf_ids[@]}" | "$JQ" -Rs 'split("\n") | map(select(length > 0))' >"$WORK/pdfs.json" ||
    fail library_error "Could not read the library PDF index."
  "$JQ" -n --slurpfile dates "$WORK/dates.json" --slurpfile pdfs "$WORK/pdfs.json" \
    -f "$(dirname "${BASH_SOURCE[0]}")/nytcrossword-inventory.jq" \
    "${metadata_files[@]}" >"$WORK/inventory.json" ||
    fail library_error "Could not parse the tablet library metadata."
}

plan_missing_groups() {
  local index=-1 date id destination previous="" previous_destination=""
  GROUP_STARTS=(); GROUP_ENDS=(); GROUP_IDS=(); GROUP_COUNTS=(); GROUP_DESTINATIONS=()
  MISSING_COUNT=0
  "$JQ" -r '.[] | select(.files | length == 0) | [.date,.puzzle_id,.destination] | @tsv' \
    "$WORK/inventory.json" >"$WORK/missing.tsv" ||
    fail library_error "Could not calculate missing crossword dates."
  PUZZLE_IDS=""
  while IFS=$'\t' read -r date id destination; do
    if [ "$previous" != "$date" ] || [ "$previous_destination" != "$destination" ]; then
      index=$((index + 1))
      GROUP_STARTS[index]=$date; GROUP_IDS[index]=""; GROUP_COUNTS[index]=0
      GROUP_DESTINATIONS[index]=$destination
    fi
    GROUP_ENDS[index]=$date
    GROUP_IDS[index]="${GROUP_IDS[index]:+${GROUP_IDS[index]},}$id"
    GROUP_COUNTS[index]=$((GROUP_COUNTS[index] + 1))
    PUZZLE_IDS="${PUZZLE_IDS:+$PUZZLE_IDS,}$id"
    MISSING_COUNT=$((MISSING_COUNT + 1))
    next_calendar_date "$date"
    previous=$NEXT_DATE; previous_destination=$destination
  done <"$WORK/missing.tsv"
}

cmd_view() {
  [ "$#" -eq 3 ] || fail usage_error "Usage: view <start-date> <end-date> <puzzle-ids>" 2
  validate_range "$1" "$2" "$3"
  prepare_work
  scan_range
  plan_missing_groups
  local merge_required=false
  for group_count in "${GROUP_COUNTS[@]}"; do
    [ "$group_count" -le 1 ] || merge_required=true
  done
  "$JQ" -cn --argjson dates "$(cat "$WORK/inventory.json")" \
    --argjson groups "$(groups_json)" --argjson count "$COUNT" \
    --argjson missing "$MISSING_COUNT" --argjson merge "$merge_required" \
    --argjson quick "${QUICK_STATUS:-false}" \
    '{ok:true,count:$count,missing_count:$missing,present_count:($count-$missing),
      dates:$dates,groups:$groups,merge_required:$merge}
      + (if $quick then {include_quick_download:true} else {} end)' ||
    fail library_error "Could not render the range inventory."
}

prepare_work() {
  mkdir -p -- "$STATE_DIR" ||
    fail state_error "Could not create the app state directory."
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  WORK=$(mktemp -d "$STATE_DIR/work.XXXXXX") ||
    fail state_error "Could not create a private work directory."
  chmod 700 "$WORK"
}

download_puzzles() {
  cookie=$(config_value NYT_S_COOKIE)
  [ -n "$cookie" ] ||
    fail not_configured "Add NYT_S_COOKIE to the private config.env file."
  case "$cookie" in
    *'
'*|*'"'*|*'\'*)
      fail invalid_config "NYT_S_COOKIE contains unsupported characters."
      ;;
  esac

  curl_bin=$(find_curl)
  [ -n "$curl_bin" ] ||
    fail missing_dependency "Install a TLS-capable curl binary."

  {
    printf 'header = "Cookie: NYT-S=%s"\n' "$cookie"
    printf 'user-agent = "xovi-nytcrossword/%s"\n' "$VERSION"
    printf 'connect-timeout = 20\n'
    printf 'max-time = 90\n'
  } >"$WORK/curl.conf"
  chmod 600 "$WORK/curl.conf"

  old_ifs=$IFS
  IFS=,
  set -- $PUZZLE_IDS
  IFS=$old_ifs
  for puzzle_id in "$@"; do
    output="$WORK/$puzzle_id.pdf"
    http_code=$(
      "$curl_bin" -q --config "$WORK/curl.conf" --silent --show-error \
        --proto '=https' --tlsv1.2 --output "$output" --write-out '%{http_code}' \
        "https://www.nytimes.com/svc/crosswords/v2/puzzle/print/$puzzle_id.pdf" \
        2>"$WORK/curl-error"
    ) || fail download_failed "The NYT download failed for $puzzle_id."
    [ "$http_code" = 200 ] ||
      fail download_failed "NYT returned HTTP $http_code for $puzzle_id."
    pdf_valid "$output" ||
      fail invalid_pdf "NYT did not return a valid PDF for $puzzle_id."
  done
}

merge_puzzles() {
  if [ "$START_DATE" = "$END_DATE" ]; then
    MERGED_PDF="$WORK/NYT_Cwd_$START_DATE.pdf"
  else
    MERGED_PDF="$WORK/NYT_Cwd_$START_DATE-$END_DATE.pdf"
  fi
  old_ifs=$IFS
  IFS=,
  set -- $PUZZLE_IDS
  IFS=$old_ifs
  if [ "$COUNT" -eq 1 ]; then
    cp -- "$WORK/$1.pdf" "$MERGED_PDF" ||
      fail merge_failed "Could not prepare the crossword PDF."
  else
    merger=$(find_merger)
    [ -n "$merger" ] ||
      fail missing_dependency "Install qpdf or mutool to merge multi-day collections."
    merger_type=${merger%%:*}
    merger_path=${merger#*:}
    set -- "$@"
    case "$merger_type" in
      qpdf)
        pdf_args=""
        for puzzle_id in "$@"; do
          pdf_args="$pdf_args
$WORK/$puzzle_id.pdf"
        done
        old_ifs=$IFS
        IFS='
'
        set -- $pdf_args
        IFS=$old_ifs
        "$merger_path" --empty --pages "$@" -- "$MERGED_PDF" \
          >"$WORK/merge-output" 2>"$WORK/merge-error" ||
          fail merge_failed "qpdf could not merge the crossword PDFs."
        "$merger_path" --check "$MERGED_PDF" \
          >>"$WORK/merge-output" 2>>"$WORK/merge-error" ||
          fail invalid_pdf "qpdf reported that the merged PDF is invalid."
        ;;
      mutool)
        pdf_args=""
        for puzzle_id in "$@"; do
          pdf_args="$pdf_args
$WORK/$puzzle_id.pdf"
        done
        old_ifs=$IFS
        IFS='
'
        set -- $pdf_args
        IFS=$old_ifs
        "$merger_path" merge -o "$MERGED_PDF" "$@" \
          >"$WORK/merge-output" 2>"$WORK/merge-error" ||
          fail merge_failed "mutool could not merge the crossword PDFs."
        ;;
    esac
  fi
  pdf_valid "$MERGED_PDF" ||
    fail invalid_pdf "The merged crossword file is not a valid PDF."
}

broker_call() {
  signal=$1
  params=$2
  mb_in=$(config_value MB_IN_PATH)
  mb_out=$(config_value MB_OUT_PATH)
  timeout_s=$(config_value BROKER_TIMEOUT_S)
  [ -n "$mb_in" ] || mb_in=/run/xovi-mb
  [ -n "$mb_out" ] || mb_out=/run/xovi-mb-out
  [ -n "$timeout_s" ] || timeout_s=30
  printf '%s' "$timeout_s" | grep -Eq '^[1-9][0-9]{0,2}$' &&
    [ "$timeout_s" -le 300 ] ||
    fail invalid_config "BROKER_TIMEOUT_S must be between 1 and 300 seconds."

  [ -p "$mb_in" ] && [ -p "$mb_out" ] ||
    fail broker_unavailable "The XOVI message broker FIFOs are not available."
  command -v flock >/dev/null 2>&1 &&
    command -v stat >/dev/null 2>&1 ||
    fail missing_dependency "Broker access requires Bash, flock, and stat."
  case "$params" in
    *'
'*) fail invalid_broker_request "Broker parameters cannot contain newlines." ;;
  esac

  payload=">e$signal:$params
"
  [ "${#payload}" -le 1024 ] ||
    fail invalid_broker_request "The broker request is too large."
  printf '%s' "$payload" >"$WORK/broker-request"

  lock_file="$mb_in.nytcrossword.lock"
  pending_file="$mb_in.nytcrossword-pending"
  exec 9>"$lock_file"
  flock -n 9 ||
    fail busy "Another crossword broker operation is running."

  identity="$(stat -Lc '%d:%i' "$mb_in")/$(stat -Lc '%d:%i' "$mb_out")" ||
    fail broker_unavailable "Could not identify the broker FIFOs."
  if [ -e "$pending_file" ]; then
    previous=$(cat "$pending_file" 2>/dev/null) ||
      fail broker_recovery_required "The broker recovery marker is unreadable."
    [ "$previous" != "$identity" ] ||
      fail broker_recovery_required "An earlier broker request was not confirmed. Restart xochitl with XOVI before retrying; an import may already exist."
    rm -f -- "$pending_file"
  fi
  printf '%s\n' "$identity" >"$pending_file.new.$$"
  mv -f -- "$pending_file.new.$$" "$pending_file"

  # Builtins only: killing this exact worker also cancels blocked FIFO opens.
  (
    trap - EXIT HUP INT TERM
    exec 7>"$mb_in"
    printf '%s' "$payload" >&7
    exec 7>&-
    exec 8<"$mb_out"
    response=""
    if IFS= read -r -d '' -n 65537 response <&8; then exit 2; fi
    printf '%s' "$response" >"$WORK/broker-response"
    exec 8<&-
  ) 2>"$WORK/broker-error" &
  WORKER=$!
  deadline=$((SECONDS + timeout_s))
  while kill -0 "$WORKER" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill -KILL "$WORKER" 2>/dev/null || :
      wait "$WORKER" 2>/dev/null || :
      WORKER=""
      fail broker_timeout "The XOVI message broker did not confirm the request. Restart xochitl with XOVI before retrying; an import may already exist."
    fi
    sleep 0.05
  done
  worker_result=0
  wait "$WORKER" || worker_result=$?
  WORKER=""
  [ "$worker_result" -eq 0 ] ||
    fail broker_error "The broker worker failed or its response exceeded 65536 bytes. Restart xochitl with XOVI before retrying."
  rm -f -- "$pending_file"
  flock -u 9
  exec 9>&-

  BROKER_REPLY=$(tr -d '\r\n' <"$WORK/broker-response")
  case "$BROKER_REPLY" in
    ERROR:*) fail broker_error "rm-librarian reported an error." ;;
  esac
  uuid_valid "$BROKER_REPLY" ||
    fail broker_error "rm-librarian returned an invalid UUID."
  BROKER_REPLY=$(printf '%s' "$BROKER_REPLY" | tr 'A-F' 'a-f')
}

cmd_version() {
  printf '{"ok":true,"version":"%s"}\n' "$VERSION"
}

settings_directory() {
  mkdir -p -- "$STATE_DIR" ||
    fail state_error "Could not create the settings directory."
  chmod 700 "$STATE_DIR" ||
    fail state_error "Could not protect the settings directory."
}

quick_download_setting() {
  local value
  value=$(config_value INCLUDE_QUICK_DOWNLOAD)
  case "$value" in
    "") QUICK_DOWNLOAD_ENABLED=true ;;
    true|false) QUICK_DOWNLOAD_ENABLED=$value ;;
    *) fail invalid_config "INCLUDE_QUICK_DOWNLOAD must be true or false." ;;
  esac
}

cmd_settings() {
  settings_directory
  base=$(config_value CROSSWORD_FOLDER)
  [ -n "$base" ] || base=$(config_value RMAPI_FOLDER)
  [ -n "$base" ] || base=/Crosswords
  timeout_s=$(config_value BROKER_TIMEOUT_S)
  [ -n "$timeout_s" ] || timeout_s=30
  quick_download_setting
  configured=false
  [ -n "$(config_value NYT_S_COOKIE)" ] && configured=true
  printf '{"ok":true,"configured":%s,"folder":"%s","broker_timeout":"%s","include_quick_download":%s}\n' \
    "$configured" "$(json_escape "$base")" "$(json_escape "$timeout_s")" "$QUICK_DOWNLOAD_ENABLED"
}

cmd_settings_apply() {
  settings_directory
  umask 077
  exec 6>"$STATE_DIR/settings.lock"
  flock -n 6 || fail busy "Another settings save is running."
  draft="$STATE_DIR/settings-draft.env"
  [ -f "$draft" ] && [ ! -L "$draft" ] ||
    fail invalid_config "The settings draft is missing or invalid."
  chmod 600 "$draft" || fail state_error "Could not protect the settings draft."
  original_config=$CONFIG
  CONFIG=$draft
  base=$(config_value CROSSWORD_FOLDER)
  timeout_s=$(config_value BROKER_TIMEOUT_S)
  cookie=$(config_value NYT_S_COOKIE)
  quick_download=$(config_value INCLUDE_QUICK_DOWNLOAD)
  CONFIG=$original_config
  if [ -z "$quick_download" ]; then
    quick_download_setting
    quick_download=$QUICK_DOWNLOAD_ENABLED
  fi
  rm -f -- "$draft" || fail state_error "Could not remove the settings draft."
  validate_folder "$base"
  case "$quick_download" in
    true|false) ;;
    *) fail invalid_config "INCLUDE_QUICK_DOWNLOAD must be true or false." ;;
  esac
  printf '%s' "$timeout_s" | grep -Eq '^[1-9][0-9]{0,2}$' &&
    [ "$timeout_s" -le 300 ] ||
    fail invalid_config "Broker wait must be between 1 and 300 seconds."
  case "$cookie" in
    *'"'*|*'\'*) fail invalid_config "The cookie contains unsupported characters." ;;
  esac
  [ -n "$CONFIG" ] && [ ! -L "$CONFIG" ] ||
    fail invalid_config "The configuration path is invalid."
  temporary=$(mktemp "$CONFIG.XXXXXX") ||
    fail state_error "Could not create the private configuration."
  if [ -f "$CONFIG" ]; then
    if ! sed '/^[[:space:]]*CROSSWORD_FOLDER[[:space:]]*=/d; /^[[:space:]]*BROKER_TIMEOUT_S[[:space:]]*=/d; /^[[:space:]]*INCLUDE_QUICK_DOWNLOAD[[:space:]]*=/d' "$CONFIG" >"$temporary"; then
      rm -f -- "$temporary"
      fail state_error "Could not read the existing configuration."
    fi
  fi
  if [ -n "$cookie" ]; then
    sed '/^[[:space:]]*NYT_S_COOKIE[[:space:]]*=/d' "$temporary" >"$temporary.filtered" ||
      fail state_error "Could not update the cookie."
    mv -- "$temporary.filtered" "$temporary"
    printf '\nNYT_S_COOKIE=%s\n' "$cookie" >>"$temporary"
  fi
  printf '\nCROSSWORD_FOLDER=%s\nBROKER_TIMEOUT_S=%s\nINCLUDE_QUICK_DOWNLOAD=%s\n' \
    "$base" "$timeout_s" "$quick_download" >>"$temporary"
  chmod 600 "$temporary" && mv -f -- "$temporary" "$CONFIG" ||
    fail state_error "Could not save the private configuration."
  exec 6>&-
  cmd_settings
}

cmd_status() {
  configured=false
  curl_available=false
  merger_available=false
  broker_ready=false
  [ -n "$(config_value NYT_S_COOKIE)" ] && configured=true
  [ -n "$(find_curl)" ] && curl_available=true
  merger=$(find_merger)
  [ -n "$merger" ] && merger_available=true
  mb_in=$(config_value MB_IN_PATH)
  mb_out=$(config_value MB_OUT_PATH)
  [ -n "$mb_in" ] || mb_in=/run/xovi-mb
  [ -n "$mb_out" ] || mb_out=/run/xovi-mb-out
  [ -p "$mb_in" ] && [ -p "$mb_out" ] &&
    command -v flock >/dev/null 2>&1 &&
    command -v stat >/dev/null 2>&1 &&
    broker_ready=true
  printf '{"ok":true,"version":"%s","configured":%s,"curl_available":%s,"merger_available":%s,"broker_ready":%s}\n' \
    "$VERSION" "$configured" "$curl_available" "$merger_available" "$broker_ready"
}

cmd_preview() {
  [ "$#" -eq 3 ] ||
    fail usage_error "Usage: preview <start-date> <end-date> <puzzle-ids>" 2
  validate_range "$1" "$2" "$3"
  plan_groups
  merge_required=false
  for group_count in "${GROUP_COUNTS[@]}"; do
    [ "$group_count" -le 1 ] || merge_required=true
  done
  printf '{"ok":true,"start_date":"%s","end_date":"%s","count":%s,"destination":"%s","merge_required":%s,"groups":%s}\n' \
    "$START_DATE" "$END_DATE" "$COUNT" "$(json_escape "$DESTINATION")" \
    "$merge_required" "$(groups_json)"
}

cmd_import() {
  [ "$#" -eq 3 ] ||
    fail usage_error "Usage: import <start-date> <end-date> <puzzle-ids>" 2
  validate_range "$1" "$2" "$3"
  plan_groups
  prepare_work
  exec 5>"$STATE_DIR/import.lock"
  flock -n 5 || fail busy "Another crossword import is running."
  if [ "${IMPORT_MISSING:-false}" = true ]; then
    scan_range
    plan_missing_groups
    if [ "$MISSING_COUNT" -eq 0 ]; then
      printf '{"ok":true,"count":0,"documents":[],"message":"All selected dates are already present."}\n'
      return
    fi
    COUNT=$MISSING_COUNT
  fi
  uncertainty="$STATE_DIR/import-uncertain"
  [ ! -e "$uncertainty" ] ||
    fail import_uncertain "A previous import may already exist. Inspect the tablet library and remove the recovery marker only after resolving it."
  download_puzzles
  local full_start=$START_DATE full_end=$END_DATE full_count=$COUNT
  local index
  local merged_files=()
  for index in "${!GROUP_STARTS[@]}"; do
    START_DATE=${GROUP_STARTS[index]}
    END_DATE=${GROUP_ENDS[index]}
    COUNT=${GROUP_COUNTS[index]}
    PUZZLE_IDS=${GROUP_IDS[index]}
    merge_puzzles
    merged_files[index]=$MERGED_PDF
  done
  START_DATE=$full_start; END_DATE=$full_end; COUNT=$full_count
  {
    printf 'range=%s..%s\n' "$START_DATE" "$END_DATE"
    printf 'monthly_groups=%s\n' "${#GROUP_STARTS[@]}"
  } >"$uncertainty"
  chmod 600 "$uncertainty"
  documents=""
  separator=""
  for index in "${!GROUP_STARTS[@]}"; do
  MERGED_PDF=${merged_files[index]}
  DESTINATION=${GROUP_DESTINATIONS[index]}
  case "$MERGED_PDF" in
    *,*|*'
'*) fail invalid_import_path "The generated PDF path cannot contain commas or newlines." ;;
  esac
  broker_call ensureFolder "$DESTINATION"
  folder_uuid=$BROKER_REPLY

  broker_call importDocument "$MERGED_PDF,$folder_uuid"
  document_uuid=$BROKER_REPLY
  printf 'confirmed_document=%s\n' "$document_uuid" >>"$uncertainty"
  documents="$documents$separator{\"destination\":\"$(json_escape "$DESTINATION")\",\"count\":${GROUP_COUNTS[index]},\"document_uuid\":\"$document_uuid\"}"
  separator=,
  done
  rm -f -- "$uncertainty"

  printf '{"ok":true,"start_date":"%s","end_date":"%s","count":%s,"destination":"%s","folder_uuid":"%s","document_uuid":"%s","documents":[%s]}\n' \
    "$START_DATE" "$END_DATE" "$COUNT" "$(json_escape "$DESTINATION")" \
    "$folder_uuid" "$document_uuid" "$documents"
}

command="${1:-}"
[ "$#" -eq 0 ] || shift
case "$command" in
  version) cmd_version "$@" ;;
  status) cmd_status "$@" ;;
  settings) cmd_settings "$@" ;;
  settings-apply) cmd_settings_apply "$@" ;;
  preview) cmd_preview "$@" ;;
  view) cmd_view "$@" ;;
  import) cmd_import "$@" ;;
  import-missing) IMPORT_MISSING=true; cmd_import "$@" ;;
  quick-status|today-status|download-today)
    if [ "$command" = quick-status ]; then
      quick_download_setting
      if [ "$QUICK_DOWNLOAD_ENABLED" = false ]; then
        printf '%s\n' '{"ok":true,"include_quick_download":false}'
        exit 0
      fi
      QUICK_STATUS=true
    fi
    today=$(date '+%Y-%m-%d') || fail missing_dependency "Could not read today's date."
    puzzle_id_for_iso_date "$today"
    if [ "$command" != download-today ]; then
      cmd_view "$today" "$today" "$PUZZLE_ID_RESULT"
    else
      IMPORT_MISSING=true
      cmd_import "$today" "$today" "$PUZZLE_ID_RESULT"
    fi
    ;;
  "") fail usage_error "Usage: nytcrossword-run.sh <version|status|preview|import>" 2 ;;
  *) fail unknown_command "Unknown command: $command" 2 ;;
esac
