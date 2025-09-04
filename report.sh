#!/usr/bin/env bash
# report.sh — Robust, parse-friendly report generator (macOS bash/zsh).
# Outputs:
#   ai-pack/R-Content.txt  ai-pack/R-Error.txt  ai-pack/R-Sync.txt  ai-pack/R-Root.txt
# Safe: no deletions, no edits. Works in any Android Studio project.

set +e
export LC_ALL=C

PACK_DIR="ai-pack"
OUT_CONTENT="$PACK_DIR/R-Content.txt"
OUT_ERRORS="$PACK_DIR/R-Error.txt"
OUT_SYNC="$PACK_DIR/R-Sync.txt"
OUT_TREE="$PACK_DIR/R-Root.txt"
mkdir -p "$PACK_DIR" >/dev/null 2>&1 || true

# -------- helpers --------
rel() { local p="${1:-}"; case "$p" in /*) p="${p#"$PWD/"}";; esac; printf "%s" "${p#./}"; }
abspath() { local p="${1:-}"; case "$p" in /*) printf "%s" "$p";; *) printf "%s/%s" "$PWD" "${p#./}";; esac; }
print_block() { # Path/File/Content → R-Content
  local f="$1"; [ -f "$f" ] || return 0
  local rp; rp="$(rel "$f")"
  {
    printf "Path: %s\n" "$rp"
    printf "File: %s\n" "$(basename "$f")"
    printf "Content:\n"
    cat "$f" 2>/dev/null || true
    printf "\n---\n"
  } >> "$OUT_CONTENT"
}
snippet() { local f="$1" l="$2"; [ -f "$f" ] || return 0; local a=$(( l>20 ? l-20 : 1 )); local b=$(( l+20 )); awk -v s="$a" -v e="$b" 'NR>=s&&NR<=e{print}' "$f" 2>/dev/null; }
clean_firstmsg() { sed -E 's/.*[Ee]rror:[[:space:]]*//; s/^[[:space:]]+//; s/[[:space:]]+$//' | head -n1; }

# -------- detect package tail (best-effort) --------
project_name="$(basename "$PWD" 2>/dev/null || echo project)"
app_id="$(grep -Rho --include='build.gradle' --include='build.gradle.kts' "applicationId[[:space:]]+['\"][^'\"]+['\"]" . 2>/dev/null | head -n1 | sed -E 's/.*["'\'']([^"'\'']+)["'\''].*/\1/')" || true
pkg_tail="${app_id##*.}"; [ -n "$pkg_tail" ] || pkg_tail="$project_name"

# -------- locate source roots & targets (for package scan) --------
src_roots="$PACK_DIR/.srcroots.list"
find . -type d \( -path "*/src/main/java" -o -path "*/src/main/kotlin" -o -path "*/src/*/java" -o -path "*/src/*/kotlin" \) 2>/dev/null | sort -u > "$src_roots"

targets="$PACK_DIR/.targets.list"; : > "$targets"
while IFS= read -r r; do [ -d "$r/com/example/$pkg_tail" ] && echo "$r/com/example/$pkg_tail"; done < "$src_roots" >> "$targets"
if [ ! -s "$targets" ]; then while IFS= read -r r; do [ -d "$r/com/example" ] && echo "$r/com/example"; done < "$src_roots" >> "$targets"; fi
if [ ! -s "$targets" ]; then while IFS= read -r r; do [ -d "$r/com" ] && echo "$r/com"; done < "$src_roots" >> "$targets"; fi

# -------- 1) R-Content.txt --------
gen_content() {
  : > "$OUT_CONTENT"

  # (A) تمام سورس‌های پکیج com/example/<pkg_tail> (kt/java/xml)
  pkg_files="$PACK_DIR/.pkg.files"; : > "$pkg_files"
  if [ -s "$targets" ]; then
    while IFS= read -r t; do
      find "$t" -type f \( -name '*.kt' -o -name '*.java' -o -name '*.xml' \) 2>/dev/null
    done < "$targets" >> "$pkg_files"
  fi
  if [ ! -s "$pkg_files" ]; then
    find . -path "*/src/*" -type f \( -name '*.kt' -o -name '*.java' -o -name '*.xml' \) 2>/dev/null >> "$pkg_files"
  fi
  if [ -s "$pkg_files" ]; then sort -u "$pkg_files" | while IFS= read -r f; do print_block "$f"; done; fi

  # (B) AndroidManifest.xml (قطعاً اضافه شود)
  for mani in ./app/src/main/AndroidManifest.xml ./AndroidManifest.xml; do
    [ -f "$mani" ] && print_block "$mani" || true
  done

  # (C) تمام فایل‌های پوشه app/ (برای «جزییات کامل») — بدون فایل‌های باینری/دیتابیس
  app_all="$PACK_DIR/.app.files"; : > "$app_all"
  if [ -d ./app ]; then
    find ./app -type f \
      -not -path "*/build/*" \
      -not -path "*/.gradle/*" \
      -not -path "*/.idea/*" \
      -not -path "*/.git/*" \
      \
      # تصاویر و فونت‌ها و باینری‌های رایج
      -not -name "*.png" -not -name "*.jpg" -not -name "*.jpeg" -not -name "*.webp" \
      -not -name "*.gif" -not -name "*.ico" -not -name "*.svg" \
      -not -name "*.jar" -not -name "*.aar" -not -name "*.aab" -not -name "*.apk" \
      -not -name "*.so"  -not -name "*.bin" -not -name "*.zip" -not -name "*.pdf" \
      -not -name "*.ttf" -not -name "*.otf" -not -name "*.woff" -not -name "*.woff2" \
      \
      # دیتابیس‌ها و فایل‌های مرتبط (Room/SQLite/WAL/SHM/Realm/…)
      -not -name "*.db" -not -name "*.sqlite" -not -name "*.sqlite3" \
      -not -name "*.room" -not -name "*.realm" \
      -not -name "*.wal" -not -name "*.shm" \
      -not -path "*/assets/*/*.db" -not -path "*/assets/*/*.sqlite" -not -path "*/assets/*/*.sqlite3" \
      2>/dev/null | sort -u > "$app_all"

    if [ -s "$app_all" ]; then
      while IFS= read -r f; do print_block "$f"; done < "$app_all"
    fi
  fi

  # (D) بیلدفایل‌های کلیدی (kts & groovy) + settings + catalog + properties
  for f in \
    ./app/build.gradle.kts ./app/build.gradle \
    ./build.gradle.kts ./build.gradle \
    ./settings.gradle.kts ./settings.gradle \
    ./gradle/libs.versions.toml \
    ./gradle.properties
  do [ -f "$f" ] && print_block "$f" || true; done

  printf ".\n" >> "$OUT_CONTENT"
}

# -------- 2) R-Error.txt (dedup smart) --------
gen_errors() {
  : > "$OUT_ERRORS"
  local LOG="$PACK_DIR/.build.log"

  if [ -x ./gradlew ]; then
    ./gradlew -q :app:compileDebugKotlin --stacktrace --warning-mode=all >"$LOG" 2>&1 || true
    ./gradlew -q :app:kspDebugKotlin     --stacktrace --warning-mode=all >>"$LOG" 2>&1 || true
    ./gradlew    build                    --stacktrace --warning-mode=all >>"$LOG" 2>&1 || true
  else
    printf "No build errors.\n.\n" >> "$OUT_ERRORS"; return 0
  fi

  if ! grep -qEi "FAILURE:|(^|[[:space:]])e: |(^|[[:space:]])error:|Could not |Redeclaration|Unresolved reference|Conflicting overloads" "$LOG"; then
    printf "No build errors.\n.\n" >> "$OUT_ERRORS"; return 0
  fi

  printed=false
  seen=""     # de-dup across all blocks
  seen_msg="" # de-dup for message-only blocks

  # (A) file:line refs → فقط فایل‌هایی که واقعاً در پروژه وجود دارند
  refs="$PACK_DIR/.refs"
  grep -Eo "([./][^ :\"']+|/[^ :\"']+)\.(kts|kt|java|xml|gradle|pro):[0-9]+" "$LOG" 2>/dev/null \
    | sed -E "s#^$PWD/##" | awk '!seen[$0]++' > "$refs" || true

  if [ -s "$refs" ]; then
    while IFS= read -r ref; do
      file="${ref%:*}"; line="${ref##*:}"; relf="$(rel "$file")"
      [ -f "$file" ] || file="./$relf"; [ -f "$file" ] || continue
      m="$(grep -n -E "($relf(:$line)?)([^[:alnum:]]|$)" "$LOG" | head -n1 | sed -E 's/^[0-9]+://')"
      [ -z "$m" ] && m="$(grep -E "(^|[[:space:]])e: .*$relf" "$LOG" | head -n1)"
      msg="$(printf "%s\n" "$m" | clean_firstmsg)"
      key="F|$relf|$line|$msg"; case ",$seen," in *",$key,"*) continue;; esac; seen="$seen,$key"
      {
        printf "Error in: %s\n" "$relf"
        printf "Message: %s\n" "$msg"
        printf "Code:\n"; snippet "$file" "$line"
        printf "Full Content:\n"; cat "$file" 2>/dev/null || true; printf "\n---\n"
      } >> "$OUT_ERRORS"
      printed=true
    done < "$refs"
  fi

  # (B) Kotlin 'e:' blocks (null-separated) → ممکن است بدون file:line باشند
  eblocks="$PACK_DIR/.eblocks"
  awk 'BEGIN{blk="";} /^e: /{ if (blk!=""){ printf "%s\0", blk; blk=$0; next } blk=$0; next } { if (blk!="") blk=blk ORS $0 } END{ if (blk!="") printf "%s\0", blk }' "$LOG" > "$eblocks" 2>/dev/null
  if [ -s "$eblocks" ]; then
    while IFS= read -r -d '' blk; do
      fline="$(printf "%s" "$blk" | grep -Eo "([./][^ :\"']+|/[^ :\"']+)\.(kts|kt|java|xml)(:[0-9]+)?" | head -n1)"
      file="${fline%:*}"; line="${fline##*:}"; [ "$file" = "$line" ] && line=""
      relf=""; [ -n "$file" ] && relf="$(rel "$file")"
      [ -n "$relf" ] && { [ -f "$file" ] || file="./$relf"; }
      msg="$(printf "%s" "$blk" | sed -E 's/^e:[[:space:]]*//' | head -n3 | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
      printf "%s" "$msg" | grep -qE "\.gradle\.|\.internal\.|\.xerces\." && continue
      if [ -z "$relf" ]; then mkey="MSG|$(printf "%s" "$msg" | head -n1)"; case ",$seen_msg," in *",$mkey,"*) continue;; esac; seen_msg="$seen_msg,$mkey"; fi
      key="E|${relf:-no-file}|$(printf "%s" "$msg" | head -n1)"; case ",$seen," in *",$key,"*) continue;; esac; seen="$seen,$key"
      if [ -n "$relf" ] && [ -f "$file" ]; then
        if printf "%s" "$line" | grep -q '^[0-9]\+$'; then code="$(snippet "$file" "$line")"; else code="$(sed -n '1,120p' "$file")"; fi
        {
          printf "Error in: %s\n" "$relf"
          printf "Message: %s\n" "$msg"
          printf "Code:\n%s\n" "$code"
          printf "Full Content:\n"; cat "$file" 2>/dev/null || true; printf "\n---\n"
        } >> "$OUT_ERRORS"
      else
        {
          printf "Error in: (no file path)\n"
          printf "Message: %s\n" "$msg"
          printf "Code:\n\nFull Content:\n\n---\n"
        } >> "$OUT_ERRORS"
      fi
      printed=true
    done < "$eblocks"
  fi

  # (C) Task blocks (Manifest/KSP/etc.) — تلاش برای ضمیمه‌کردن AndroidManifest.xml + دِدیوپ پیام
  taskblocks="$PACK_DIR/.task.blocks"
  awk '/^> Task /{ if (cur!="") print cur "\n"; cur=$0; next } { cur=cur ORS $0 } END{ if (cur!="") print cur }' "$LOG" > "$taskblocks" 2>/dev/null
  if [ -s "$taskblocks" ]; then
    while IFS= read -r block; do
      printf "%s" "$block" | grep -qEi "(error:|FAILURE:|Could not |process.*Manifest|AndroidManifest\.xml)" || continue
      firstmsg="$(printf "%s" "$block" | grep -E "error:|Element type |not found|Could not |FAILURE:" | head -n1 | sed -E 's/^[[:space:]]+//')"
      [ -n "$firstmsg" ] || firstmsg="$(printf "%s" "$block" | sed -n '1p')"
      mkey="MSG|$firstmsg"; case ",$seen_msg," in *",$mkey,"*) continue;; esac; seen_msg="$seen_msg,$mkey"
      key="T|$firstmsg"; case ",$seen," in *",$key,"*) continue;; esac; seen="$seen,$key"
      mani="$(printf "%s" "$block" | grep -Eo "([./][^ :\"']+|/[^ :\"']+)/AndroidManifest\.xml" | head -n1)"
      [ -z "$mani" ] && mani="$(find ./app -name AndroidManifest.xml | head -n1 || true)"
      snip=""
      if [ -n "$mani" ] && [ -f "$mani" ]; then
        lnno="$(nl -ba "$mani" | grep -n "<action" | head -n1 | cut -d: -f1)"
        if [ -n "$lnno" ]; then snip="$(snippet "$mani" "$lnno")"; else snip="$(sed -n '1,120p' "$mani")"; fi
        {
          printf "Error in: %s\n" "$(rel "$mani")"
          printf "Message: %s\n" "$firstmsg"
          printf "Code:\n%s\n" "$snip"
          printf "Full Content:\n"; cat "$mani"; printf "\n---\n"
        } >> "$OUT_ERRORS"
      else
        {
          printf "Error in: (no file path)\n"
          printf "Message: %s\n" "$firstmsg"
          printf "Code:\n\nFull Content:\n\n---\n"
        } >> "$OUT_ERRORS"
      fi
      printed=true
    done < "$taskblocks"
  fi

  $printed || printf "No build errors.\n" >> "$OUT_ERRORS"
  printf ".\n" >> "$OUT_ERRORS"
}

# -------- 3) R-Sync.txt --------
gen_sync() {
  : > "$OUT_SYNC"
  local LOG="$PACK_DIR/.sync.log"
  if [ -x ./gradlew ]; then
    ./gradlew --stacktrace --warning-mode=all tasks >"$LOG" 2>&1 || true
    if grep -qEi "FAILURE:|\* What went wrong:|Caused by:|Plugin [^ ]+ not found|Could not resolve|Version .* not found|Dependency .* not found|Invalid plugin|Problem occurred|error:" "$LOG"; then
      grep -Ei "^(FAILURE:|\* What went wrong:|Caused by:|Plugin [^ ]+ not found|Could not resolve|Version .* not found|Dependency .* not found|Invalid plugin|Problem occurred|error:)" "$LOG" \
        | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//' \
        | awk '{print "Sync Error: "$0"\n---"}' >> "$OUT_SYNC"
    else
      printf "No sync errors.\n.\n" >> "$OUT_SYNC"
    fi
  else
    printf "No sync errors.\n.\n" >> "$OUT_SYNC"
  fi
}

# -------- 4) R-Root.txt (ABS_ROOT=1 → absolute) --------
gen_tree() {
  : > "$OUT_TREE"
  local list="$PACK_DIR/.tree.files"; : > "$list"

  # فقط فایل‌های kt/java/xml پروژه (پکیج یا کل src/*)
  if [ -s "$targets" ]; then
    while IFS= read -r t; do
      find "$t" -type f \( -name '*.kt' -o -name '*.java' -o -name '*.xml' \) 2>/dev/null
    done < "$targets" >> "$list"
  fi
  [ -s "$list" ] || find . -path "*/src/*" -type f \( -name '*.kt' -o -name '*.java' -o -name '*.xml' \) 2>/dev/null >> "$list"

  if [ -s "$list" ]; then
    sort -u "$list" | while IFS= read -r f; do
      if [ "${ABS_ROOT:-1}" = "1" ]; then
        printf "%s\n" "$(abspath "$f")"
      else
        printf "%s\n" "$(rel "$f")"
      fi
    done >> "$OUT_TREE"
  fi
}

# -------- run --------
gen_content
gen_errors
gen_sync
gen_tree

echo "Done. Outputs in: $PACK_DIR/"
ls -1 "$PACK_DIR" 2>/dev/null || true
