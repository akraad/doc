#!/usr/bin/env bash
# report.sh — Minimal, robust pack builder for AI debugging (macOS, zsh/bash).
# Produces: ai-pack/R-Content.txt, R-Error.txt, R-Sync.txt, R-Root.txt
# - Never crashes on missing files or no errors
# - Relative paths only
# - Detects errors from .kts/.kt/.java/.xml and includes code/context/full file

# -------------------- Setup --------------------
PACK_DIR="ai-pack"
OUT_CONTENT="$PACK_DIR/R-Content.txt"
OUT_ERRORS="$PACK_DIR/R-Error.txt"
OUT_SYNC="$PACK_DIR/R-Sync.txt"
OUT_TREE="$PACK_DIR/R-Root.txt"

mkdir -p "$PACK_DIR" 2>/dev/null || true

# -------------------- Helpers --------------------
relpath() {
  local p="${1:-}"
  case "$p" in
    /*) p="${p#"$PWD/"}" ;;
  esac
  p="${p#./}"
  printf "%s" "$p"
}

print_block() { # Path/File/Content block for R-Content
  local f="$1"
  [ -f "$f" ] || return 0
  local rp; rp="$(relpath "$f")"
  {
    printf "Path: %s\n" "$rp"
    printf "File: %s\n" "$(basename "$f")"
    printf "Content:\n"
    cat "$f" 2>/dev/null || true
    printf "\n---\n"
  } >> "$OUT_CONTENT" 2>/dev/null || true
}

# Detect project/package tail (best-effort, never fail)
project_name="$(basename "$PWD" 2>/dev/null || echo project)"
app_id="$(grep -Rho --include='build.gradle' --include='build.gradle.kts' "applicationId[[:space:]]\+['\"][^'\"]\+['\"]" . 2>/dev/null \
         | head -n1 | sed -E 's/.*["'\'']([^"'\'']+)["'\''].*/\1/' 2>/dev/null)"
pkg_tail="$project_name"
[ -n "$app_id" ] && pkg_tail="${app_id##*.}"

# Collect candidate roots & targets (don’t fail if empty)
src_roots="$PACK_DIR/.srcroots.list"
find . -type d \( -path "*/src/main/java" -o -path "*/src/main/kotlin" -o -path "*/src/*/java" -o -path "*/src/*/kotlin" \) \
  2>/dev/null | sort -u > "$src_roots"

targets_file="$PACK_DIR/.targets.list"
: > "$targets_file"
# prefer com/example/<pkg_tail>
while IFS= read -r r; do
  [ -d "$r/com/example/$pkg_tail" ] && printf "%s\n" "$r/com/example/$pkg_tail" >> "$targets_file"
done < "$src_roots"
# then com/example
if [ ! -s "$targets_file" ]; then
  while IFS= read -r r; do
    [ -d "$r/com/example" ] && printf "%s\n" "$r/com/example" >> "$targets_file"
  done < "$src_roots"
fi
# then com
if [ ! -s "$targets_file" ]; then
  while IFS= read -r r; do
    [ -d "$r/com" ] && printf "%s\n" "$r/com" >> "$targets_file"
  done < "$src_roots"
fi

# -------------------- 1) R-Content.txt --------------------
gen_content() {
  : > "$OUT_CONTENT"
  local col="$PACK_DIR/.content.files"; : > "$col"

  # Only kt/java/xml under target package; if not found, fallback to all src/*
  if [ -s "$targets_file" ]; then
    while IFS= read -r t; do
      find "$t" -type f \( -name "*.kt" -o -name "*.java" -o -name "*.xml" \) 2>/dev/null
    done < "$targets_file" >> "$col"
  fi
  if [ ! -s "$col" ]; then
    find . -path "*/src/*" -type f \( -name "*.kt" -o -name "*.java" -o -name "*.xml" \) 2>/dev/null >> "$col"
  fi

  # Print code blocks
  if [ -s "$col" ]; then
    sort -u "$col" | while IFS= read -r f; do print_block "$f"; done
  fi

  # Also include the specified build files (skip silently if missing)
  for f in ./app/build.gradle.kts ./build.gradle.kts ./settings.gradle.kts ./gradle/libs.versions.toml; do
    [ -f "$f" ] && print_block "$f" || true
  done

  printf ".\n" >> "$OUT_CONTENT" 2>/dev/null || true
}

# -------------------- 2) R-Error.txt --------------------
gen_errors() {
  : > "$OUT_ERRORS"
  local BUILD_LOG="$PACK_DIR/.build.log"

  if [ -x ./gradlew ]; then
    ./gradlew build >"$BUILD_LOG" 2>&1 || true
  else
    echo "No build errors." > "$OUT_ERRORS"
    echo "." >> "$OUT_ERRORS"
    return 0
  fi

  # If no failure markers → no errors
  if ! grep -qE "FAILURE:|\berror:|^e: " "$BUILD_LOG" 2>/dev/null; then
    echo "No build errors." >> "$OUT_ERRORS"
    echo "." >> "$OUT_ERRORS"
    return 0
  fi

  # Capture references like foo.kts:37 OR foo.kt:37 OR foo.java/xml:37
  local refs="$PACK_DIR/.build.refs"
  grep -Eo "([./][^ :'\"]+|/[^ :'\"]+)\.(kts|kt|java|xml):[0-9]+" "$BUILD_LOG" 2>/dev/null \
    | sed -E "s#^$PWD/##" | awk '!seen[$0]++' > "$refs" || true

  # Helper: extract a cleaner message + 2 lines of context after the match
  extract_message_with_context() {
    local file_rel="$1" line="$2" m msg_core ctx
    m="$(grep -n -E "($file_rel(:$line)?)([^[:alnum:]]|$)" "$BUILD_LOG" 2>/dev/null | head -n1 | sed -E 's/^[0-9]+://')"
    # Fallback: any line that has "error:" near the file
    [ -z "$m" ] && m="$(grep -E "(error:|^e: ).*$file_rel" "$BUILD_LOG" 2>/dev/null | head -n1)"

    if printf "%s" "$m" | grep -qi "error:"; then
      msg_core="$(printf "%s" "$m" | sed -E 's/.*[Ee]rror:[[:space:]]*//')"
    else
      msg_core="$(printf "%s" "$m" | sed -E "s#^.*$file_rel(:[0-9]+(:[0-9]+)?)?:[[:space:]]*##")"
    fi

    # Also take the next up-to-2 lines after the matched one for context
    # (Search the exact matched line string, then print next 2)
    local esc; esc="$(printf "%s" "$m" | sed 's/[.[\*^$()+?{}|/\\]/\\&/g')"
    ctx="$(awk -v pat="$esc" 'found==0 && index($0, pat)>0 {found=1; next}
                              found>0 && ctx<2 {print; ctx++}' "$BUILD_LOG" 2>/dev/null)"
    printf "%s\n%s" "$msg_core" "$ctx" | sed 's/\r$//'
  }

  local printed=false
  if [ -s "$refs" ]; then
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      local file="${ref%:*}"
      local line="${ref##*:}"
      local file_rel; file_rel="$(relpath "$file")"
      [ -f "$file" ] || file="./$file_rel"

      local msg; msg="$(extract_message_with_context "$file_rel" "$line")"

      # Code snippet: ±20 lines around the error
      local start=$(( line>20 ? line-20 : 1 ))
      local end=$(( line+20 ))
      local code; code="$(awk -v s="$start" -v e="$end" 'NR>=s && NR<=e {print}' "$file" 2>/dev/null)"

      {
        printf "Error in: %s\n" "$file_rel"
        printf "Message: %s\n" "$msg"
        printf "Code:\n%s\n" "$code"
        printf "Full Content:\n"
        cat "$file" 2>/dev/null || true
        printf "\n---\n"
      } >> "$OUT_ERRORS"

      printed=true
    done < "$refs"
  fi

  # General failure but no file:line refs → still give minimal failure lines
  if ! $printed; then
    {
      echo "Error in: (no file path)"
      # Show a concise subset of failure lines
      grep -E "^(FAILURE:|\* What went wrong:|Caused by:|> Could not |Could not )" "$BUILD_LOG" 2>/dev/null | head -n 60
      echo "Message: (see lines above)"
      echo "Code:"
      echo
      echo "Full Content:"
      echo
      echo "---"
    } >> "$OUT_ERRORS"
  fi

  echo "." >> "$OUT_ERRORS"
}

# -------------------- 3) R-Sync.txt --------------------
gen_sync() {
  : > "$OUT_SYNC"
  local SYNC_LOG="$PACK_DIR/.sync.log"
  if [ -x ./gradlew ]; then
    ./gradlew --stacktrace --warning-mode=all tasks >"$SYNC_LOG" 2>&1 || true
    if grep -qE "FAILURE:|\* What went wrong:|Caused by:|> Could not |Plugin [^ ]+ not found|Could not resolve|Version .* not found|Dependency .* not found|error:" "$SYNC_LOG" 2>/dev/null; then
      grep -E "^(FAILURE:|\* What went wrong:|Caused by:|> Could not |Plugin [^ ]+ not found|Could not resolve|Version .* not found|Dependency .* not found|error:)" "$SYNC_LOG" 2>/dev/null \
        | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//' \
        | awk '{print "Sync Error: "$0"\n---"}' >> "$OUT_SYNC"
    else
      echo "No sync errors." >> "$OUT_SYNC"
      echo "." >> "$OUT_SYNC"
    fi
  else
    echo "No sync errors." >> "$OUT_SYNC"
    echo "." >> "$OUT_SYNC"
  fi
}

# -------------------- 4) R-Root.txt --------------------
gen_tree() {
  : > "$OUT_TREE"
  local tree_list="$PACK_DIR/.tree.files"; : > "$tree_list"

  if [ -s "$targets_file" ]; then
    while IFS= read -r t; do
      find "$t" -type f \( -name "*.kt" -o -name "*.java" -o -name "*.xml" \) 2>/dev/null
    done < "$targets_file" >> "$tree_list"
  fi
  if [ ! -s "$tree_list" ]; then
    find . -path "*/src/*" -type f \( -name "*.kt" -o -name "*.java" -o -name "*.xml" \) 2>/dev/null >> "$tree_list"
  fi

  if [ -s "$tree_list" ]; then
    sort -u "$tree_list" | while IFS= read -r f; do
      echo "$(relpath "$f")"
    done >> "$OUT_TREE"
  fi
}

# -------------------- Run all --------------------
gen_content
gen_errors
gen_sync
gen_tree

echo "Done. See ai-pack/:"
ls -1 "$PACK_DIR" 2>/dev/null || true
