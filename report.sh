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

  # بیلد با لاگ کامل
  if [ -x ./gradlew ]; then
    ./gradlew build --stacktrace --warning-mode=all >"$BUILD_LOG" 2>&1 || true
  else
    echo "No build errors." > "$OUT_ERRORS"
    echo "." >> "$OUT_ERRORS"
    return 0
  fi

  # اگر عملاً خطایی دیده نمی‌شود
  if ! grep -qEi "FAILURE:|(^|[[:space:]])e: |(^|[[:space:]])error:|Could not |BUILD FAILED" "$BUILD_LOG" 2>/dev/null; then
    echo "No build errors." >> "$OUT_ERRORS"
    echo "." >> "$OUT_ERRORS"
    return 0
  fi

  # 1) ارجاع‌های file:line که واقعاً داخل پروژه‌اند (kts/kt/java/xml/gradle/pro)
  #   - اول همه‌ی refها را بگیر
  local all_refs="$PACK_DIR/.all.refs"
  grep -Eo "([./][^ :'\"]+|/[^ :'\"]+)\.(kts|kt|java|xml|gradle|pro):[0-9]+" "$BUILD_LOG" 2>/dev/null \
    | sed -E "s#^$PWD/##" > "$all_refs" || true

  #   - فقط آن‌هایی که فایل‌شان در پروژه واقعاً وجود دارد را نگه دار
  local refs="$PACK_DIR/.refs.filtered"; : > "$refs"
  if [ -s "$all_refs" ]; then
    awk '!seen[$0]++' "$all_refs" | while IFS= read -r ref; do
      file="${ref%:*}"
      rel="${file#./}"; [ -f "$file" ] || file="./$rel"
      # حذف مسیرهایی که خارج از پروژه‌اند یا فایل ندارند
      if [ -f "$file" ] && printf "%s" "$file" | grep -qE "^\./"; then
        echo "$ref" >> "$refs"
      fi
    done
  fi

  # کمک‌تابع: پیام + ۲ خط کانتکست بعد از خط match
  extract_message_with_context() {
    local file_rel="$1" line="$2" m msg_core ctx
    m="$(grep -n -E "($file_rel(:$line)?)([^[:alnum:]]|$)" "$BUILD_LOG" 2>/dev/null | head -n1 | sed -E 's/^[0-9]+://')"
    [ -z "$m" ] && m="$(grep -E "(error:|^e: ).*$file_rel" "$BUILD_LOG" 2>/dev/null | head -n1)"
    if printf "%s" "$m" | grep -qi "error:"; then
      msg_core="$(printf "%s" "$m" | sed -E 's/.*[Ee]rror:[[:space:]]*//')"
    else
      msg_core="$(printf "%s" "$m" | sed -E "s#^.*$file_rel(:[0-9]+(:[0-9]+)?)?:[[:space:]]*##")"
    fi
    local esc; esc="$(printf "%s" "$m" | sed 's/[.[\*^$()+?{}|/\\]/\\&/g')"
    ctx="$(awk -v pat="$esc" 'f==0 && index($0,pat)>0 {f=1; next} f>0 && n<2 {print; n++}' "$BUILD_LOG" 2>/dev/null)"
    printf "%s\n%s" "$msg_core" "$ctx" | sed 's/\r$//'
  }

  printed=false
  seen_keys=""  # برای دِدیوپ

  # الف) چاپ بلاک‌های file:line فقط برای فایل‌های واقعی پروژه
  if [ -s "$refs" ]; then
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      file="${ref%:*}"; line="${ref##*:}"
      file_rel="$(relpath "$file")"
      [ -f "$file" ] || file="./$file_rel"

      msg="$(extract_message_with_context "$file_rel" "$line")"
      msg_first="$(printf "%s" "$msg" | head -n1)"

      key="F|$file_rel|$line|$msg_first"
      case ",$seen_keys," in
        *",$key,"*) continue ;;
      esac
      seen_keys="$seen_keys,$key"

      start=$(( line>20 ? line-20 : 1 ))
      end=$(( line+20 ))
      code="$(awk -v s="$start" -v e="$end" 'NR>=s && NR<=e {print}' "$file" 2>/dev/null)"

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

  # ب) بلاک‌های Task (بدون file:line) — فشرده و یکتا، بدون استک‌تریس
  #   واژه‌های ممنوعهٔ استک‌تریس را حذف می‌کنیم تا تکرارها نیاید
  local task_blocks="$PACK_DIR/.task.blocks"
  awk '
    /^> Task / { if (cur!="") print cur; cur=$0; next }
    { cur=cur ORS $0 }
    END{ if (cur!="") print cur }
  ' "$BUILD_LOG" > "$task_blocks" 2>/dev/null || true

  if [ -s "$task_blocks" ]; then
    while IFS= read -r -d '' block; do
      title="$(printf "%s" "$block" | sed -n '1p')"
      msgs="$(printf "%s" "$block" \
        | grep -E "error:|^e: |Element type |is missing|not found|duplicate|Cannot find|Could not |FAILURE:" \
        | grep -Ev "\.gradle\.|\.internal\.|\.xerces\.|\.DefaultBuildOperationRunner|\.Execute|\.java:[0-9]+" \
        | sed -E 's/^[[:space:]]+//')"

      [ -n "$msgs" ] || continue
      first_msg="$(printf "%s" "$msgs" | head -n1)"

      key="T|$title|$first_msg"
      case ",$seen_keys," in
        *",$key,"*) continue ;;
      esac
      seen_keys="$seen_keys,$key"

      # تلاش برای Manifest
      mani_path="$(printf "%s" "$block" | grep -Eo "([./][^ :'\"]+|/[^ :'\"]+)/AndroidManifest\.xml" | head -n1)"
      [ -n "$mani_path" ] || mani_path="$(find . -name AndroidManifest.xml | head -n1 || true)"
      snip=""
      if [ -f "$mani_path" ]; then
        lnno="$(nl -ba "$mani_path" | grep -n "<action" 2>/dev/null | head -n1 | cut -d: -f1)"
        if [ -n "$lnno" ]; then
          a=$(( lnno>20 ? lnno-20 : 1 ))
          b=$(( lnno+20 ))
          snip="$(awk -v s="$a" -v e="$b" 'NR>=s && NR<=e {print}' "$mani_path" 2>/dev/null)"
        fi
      fi

      {
        printf "Error in: %s\n" "$( [ -n "$mani_path" ] && relpath "$mani_path" || echo "(no file path)" )"
        printf "Message: %s\n" "$first_msg"
        printf "Code:\n%s\n" "${snip:-}"
        printf "Full Content:\n"
        [ -f "$mani_path" ] && cat "$mani_path" || true
        printf "\n---\n"
      } >> "$OUT_ERRORS"

      printed=true
    done < <(awk 'BEGIN{RS="";ORS="\0"}{print}' "$task_blocks")
  fi

  # ج) اگر هیچ‌چیز چاپ نشد، خلاصهٔ عمومی
  if ! $printed; then
    {
      echo "Error in: (no file path)"
      grep -E "^(FAILURE:|\* What went wrong:|Caused by:|> Could not |Could not )" "$BUILD_LOG" 2>/dev/null | head -n 80
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
    # همه‌ی انواع ارورهای کانفیگ/دیپندنسی/پلاگین
    if grep -qEi "FAILURE:|\* What went wrong:|Caused by:|Plugin [^ ]+ not found|Could not resolve|Version .* not found|Dependency .* not found|Invalid plugin|Problem occurred|error:" "$SYNC_LOG"; then
      grep -Ei "^(FAILURE:|\* What went wrong:|Caused by:|Plugin [^ ]+ not found|Could not resolve|Version .* not found|Dependency .* not found|Invalid plugin|Problem occurred|error:)" "$SYNC_LOG" \
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
