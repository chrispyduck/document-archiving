#!/bin/bash -eu
set -o pipefail

TMPDIR=$(pwd)/work
OUTDIR=$(pwd)/out
DEVICE='dsseries:usb:0x04F9:0x60E0'
declare -A PAGE_SIZES=(
  ["letter"]="-x 215.9 -y 279.4"
  ["legal"]="-x 215.9 -y 355.6"
  ["auto"]=" "
)
DPI=150
SCANIMAGE_ARGS="-d ${DEVICE} --mode color --resolution $DPI --format pnm"

DATE=""
TITLE=""
NAME=""
WHO=""
COMPANY=""
PAGE_SIZE=""
PAGE_LIMIT=""
INTERACTIVE=1

print_usage() {
  if [ "$*" != "" ]; then
    >&2 echo "Error: $*"
  fi
  >&2 cat <<EOF
$0 usage

Required Parameters
  -d|--date <arg>       Specifies a date in YYYY-MM-dd format
  -t|--title <arg>      Specifies a title for the document
  -k|--keyword <arg>    Adds a keyword to the generated file metadata (may be specified multiple times)
  -w|--who <arg>        The person that this scan concerns
  -c|--company <arg>    The company that generated the document being scanned
  -p|--page-size <size> Specifies the size of the pages being scanned

Optioanl Paraleters
  -i|--interactive      Prompts for all values, even if they were provided as arguments already
  -m|--multipage <n>    Number of pages to scan before exiting

Supported Page Sizes
  * letter
  * legal

Examples
  $0 -d 2020-01-05 -t "Costco receipt"
  $0 -d 2020-01-05 -t "EOB for Doctor Visit" -w John -c "Alexandria Family Medicine"
EOF
  exit 1
}

join_keywords() {
  local IFS=,
  KEYWORDS_JOINED="${KEYWORDS[*]}"
}
split_keywords() {
  local IFS=,
  read -r -a KEYWORDS <<< "${KEYWORDS_JOINED}"
}

SETTINGS=~/.scandoc/
[ ! -d "${SETTINGS}" ] && mkdir -p $SETTINGS
load_vars() {
  set +e # don't exit on failure to read
  DATE=$(cat "$SETTINGS/date")
  TITLE=$(cat "$SETTINGS/title")
  WHO=$(cat "$SETTINGS/who")
  COMPANY=$(cat "$SETTINGS/company")
  KEYWORDS_JOINED=$(cat "$SETTINGS/keywords")
  split_keywords
  PAGE_SIZE=$(cat "$SETTINGS/page_size")
  set -e
}
write_vars() {
  echo $DATE > "$SETTINGS/date"
  echo $TITLE > "$SETTINGS/title"
  echo $WHO > "$SETTINGS/who"
  echo $COMPANY > "$SETTINGS/company"
  echo $PAGE_SIZE > "$SETTINGS/page_size"
  
  join_keywords
  echo $KEYWORDS_JOINED > "$SETTINGS/keywords"
  split_keywords
}

declare -a KEYWORDS
load_vars 

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
  -h | --help)
    print_usage
    ;;
  -d | --date)
    DATE=$2
    shift
    shift
    ;;
  -t | --title)
    TITLE=$2
    shift
    shift
    ;;
  -k | --keyword)
    KEYWORDS+=("$2")
    shift
    shift
    ;;
  -w | --who)
    WHO=$2
    KEYWORDS+=("$2")
    shift
    shift
    ;;
  -c | --company)
    COMPANY=$2
    KEYWORDS+=("$2")
    shift
    shift
    ;;
  -p | --page-size)
    PAGE_SIZE=$2
    shift
    shift
    ;;
  -i | --interactive)
    INTERACTIVE=1
    shift
    ;;
  -m | --multipage)
    PAGE_LIMIT=$2
    shift
    shift
    ;;
  *)
    print_usage "Unknown option: $key"
    ;;
  esac
done

die() {
  >&2 echo "Fatal: $*"
  exit 2
}

prompt_with_default() {
  local VAR=$1
  local TEXT=$2
  read -p "${TEXT} [${!VAR}]: " INPUT
  if [ "${INPUT}" != "" ]; then
    printf -v "$VAR" '%s' "$INPUT"
  fi
}

if [ "${INTERACTIVE}" == "1" ]; then
  prompt_with_default DATE "Date"
  prompt_with_default TITLE "Document Title"
  prompt_with_default WHO "Subject of Document"
  prompt_with_default COMPANY "Company"
  prompt_with_default KEYWORDS_JOINED "Keywords"
  prompt_with_default PAGE_SIZE "Page Size"
  split_keywords
fi 

[ "${DATE}" == "" ] && die "no --date argument provided"
[ "${TITLE}" == "" ] && die "no --title argument provided"
[ "${PAGE_SIZES[${PAGE_SIZE}]}" == "" ] && die "Unrecognized page size: \"${PAGE_SIZE}\""

NAME="$DATE"
if [ "${COMPANY}" != "" ]; then
  NAME+=", ${COMPANY}"
fi
if [ "${WHO}" != "" ]; then
  NAME+=", ${WHO}"
fi
NAME+=", ${TITLE}"
echo "Using filename: ${NAME}"

if [ ! -d "$TMPDIR" ]; then
  mkdir -p $TMPDIR
fi
if [ ! -d "$OUTDIR" ]; then
  mkdir -p $OUTDIR
fi

# Save settings for later
write_vars
join_keywords
  cat <<EOF
Date      = $DATE
Title     = $TITLE
Company   = $COMPANY
Subject   = $WHO
Keywords  = $KEYWORDS_JOINED
Page size = $PAGE_SIZE
EOF

# Scan the document
[ "${PAGE_LIMIT}" == "" ] && PAGE_LIMIT=9999
PAGE=1
CONTINUE=""
echo "Scanning page $PAGE of up to ${PAGE_LIMIT} page(s)..."
while [ "${CONTINUE}" == "" ] && scanimage ${SCANIMAGE_ARGS} ${PAGE_SIZES[${PAGE_SIZE}]} -o "$TMPDIR/$NAME $(printf %03d $PAGE).pnm"
do
  PAGE=$(($PAGE + 1))
  if [ ${PAGE_LIMIT} -ge $PAGE ]; then
    echo -n "Press ENTER to scan page $PAGE or ESC to stop"
    read -s -n1 CONTINUE
    echo
  else
    echo "Reached page limit (${PAGE_LIMIT})"
    CONTINUE="no"
  fi
  
done

# Post-process and convert to PDF
echo "Processing..."
img2pdf "$TMPDIR/$NAME"*.pnm | ocrmypdf - "$TMPDIR/$NAME.pdf" \
  --deskew \
  --remove-background \
  --clean \
  --title "$TITLE" \
  --author "$COMPANY" \
  --keywords "$KEYWORDS_JOINED" \
  --optimize 1

# Set metadata
echo "Updating metadata..."
pdftk "$TMPDIR/$NAME.pdf" dump_data output "$TMPDIR/$NAME.meta"
cat <<EOF >> "$TMPDIR/$NAME.meta"
InfoBegin
InfoKey: Scanned By
InfoValue: $(whoami) on $(hostname)
InfoBegin
InfoKey: Date Scanned
InfoValue: $(date -Iseconds)
InfoBegin
InfoKey: Company
InfoValue: $COMPANY
InfoBegin
InfoKey: Document Subject
InfoValue: $WHO
EOF
pdftk "$TMPDIR/$NAME.pdf" update_info "$TMPDIR/$NAME.meta" output "$OUTDIR/$NAME.pdf"

# Clean up
echo "Removing temporary files..."
rm -rf "$TMPDIR/$NAME"*

echo "Done"
