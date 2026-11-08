#!/usr/bin/env bash
# build-native-port.sh: build the unofficial native-Linux port of one TiinyOS release.
#
# Input: the vendor Windows installer, and the previous port build.
# Output: linux-native-build-<ver>/ with tiinyos-linux/ and run-tiinyos-linux.sh.
#
# Usage:
#   ./build-native-port.sh [--from <prev-build-dir>] [--version <ver>] [--exe <path>]
#                          [--caddy <path>] [--out <parent-dir>] [--force] [--check-only]
#                          [--no-sandbox-check]
#
# How the build works:
#   1. Extract the installer with 7z. This script does not run any Windows program.
#   2. Stop if the Electron version differs from the previous build.
#   3. Extract the vendor asar into a stage directory.
#   4. Replace three @img packages in the stage with the previous build's copies.
#   5. Copy the previous Linux Electron tree, without the vendor resources.
#   6. Pack the stage, and run the checks.
#   7. Move the tree to the build directory only if all checks pass.
#
# Rules:
#   - This script reads the previous build. It does not change the previous build.
#   - This script does not start, stop or restart TiinyOS or the PC Service.
#   - Installer contents are untrusted. Only the sharp check runs code from them.
#   - The sharp check uses the Linux Electron with ELECTRON_RUN_AS_NODE=1, in bwrap.
#   - If bwrap does not work, the build stops. --no-sandbox-check removes the sandbox.
#   - The download host must be on the allowlist, DOWNLOAD_HOSTS.
#   - The GUI is not tested. Headless mode segfaults on 1.0.1 and 1.0.2.
#   - The sha256 is for the record only, because the vendor publishes no checksum.
#
# The system-ocr result: the pack glob covers all of node_modules/@napi-rs.
# The vendor unpacks only the platform packages. So the vendor loader files
# @napi-rs/system-ocr/{index.js,package.json} move from the asar to the unpacked
# directory. Their bytes do not change. The unpacked-list check prints each moved file.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Builds live in TIINY_HOME, as for tiiny-native.sh. The default --from and --out use it.
BUILD_HOME="${TIINY_HOME:-$HOME/tiiny-tools}"
ENDPOINT="https://service.dev.tiiny-svr.com/update/check_update"
IMG_PACKAGES=(colour sharp-libvips-linux-x64 sharp-linux-x64)
UNPACK_ROOTS=(node_modules/@napi-rs node_modules/selection-hook node_modules/font-list
              node_modules/@img node_modules/registry-js resources out/preload)
# The vendor resources/ directory holds these entries. Any other entry stops the build.
VENDOR_RESOURCES_REQUIRED=(app-update.yml app.asar app.asar.unpacked pcsvr)
VENDOR_RESOURCES_DROPPED=(elevate.exe)   # A Windows-only helper. The port does not ship it.
DOWNLOAD_HOSTS=(files.tiinycdn.com)
CURL_TLS=(--proto '=https' --proto-redir '=https' --tlsv1.2)
ASAR=()
NO_SANDBOX_CHECK=0
PASSED=0
BUILD_DONE=0
WORK_DIR=""

log()  { printf '%s\n' "$*"; }
die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { PASSED=$((PASSED + 1)); printf 'PASS %s\n' "$*"; }

unpack_glob() {
  local root out=""
  for root in "${UNPACK_ROOTS[@]}"; do out+="${out:+,}$root,$root/**"; done
  printf '{%s}' "$out"
}

asar_cmd() { "${ASAR[@]}" "$@" </dev/null; }

# Read one top-level field from a JSON file. Print nothing if the field is absent.
json_file_get() {
  node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
           const v=j[process.argv[2]]; if(v!==undefined&&v!==null)console.log(String(v))' "$1" "$2"
}

file_count() { find "$1" -type f | wc -l; }

# A version becomes part of a path that --force deletes, and it can come from the
# endpoint. This pattern has no slash and no "..".
validate_version() {
  [[ $1 =~ ^[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]] \
    || die "$2 is not a valid version: '$1'"
}

# --- tools ------------------------------------------------------------------
detect_tools() {
  local missing=() c
  for c in "$@"; do
    case "$c" in
      asar)
        if command -v asar >/dev/null 2>&1 && asar --version </dev/null >/dev/null 2>&1; then
          ASAR=(asar)
        elif command -v npx >/dev/null 2>&1 && npx --no-install asar --version </dev/null >/dev/null 2>&1; then
          ASAR=(npx --no-install asar)
        else
          missing+=("asar (not on PATH, and 'npx --no-install asar' fails. Run: npm install -g asar)")
        fi ;;
      7z)
        command -v 7z >/dev/null 2>&1 || missing+=("7z (install the 7zip package)") ;;
      *)
        command -v "$c" >/dev/null 2>&1 || missing+=("$c") ;;
    esac
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    for c in "${missing[@]}"; do printf 'MISSING: %s\n' "$c" >&2; done
    die "${#missing[@]} required tool(s) are missing"
  fi
}

# --- endpoint ---------------------------------------------------------------
# Set NEED_UPDATE, NEWEST_VERSION, TOTAL_BYTES, DOWNLOAD_URL for one now_version.
query_endpoint() {
  local now=$1 body fields
  body=$(curl "${CURL_TLS[@]}" -sS -f -m 30 -X POST -H 'Content-Type: application/json' \
    -d "{\"platform\":\"windows\",\"arch\":\"amd64\",\"now_version\":\"$now\"}" "$ENDPOINT") \
    || die "the update endpoint did not answer: $ENDPOINT"
  fields=$(printf '%s' "$body" | node -e '
    const j=JSON.parse(require("fs").readFileSync(0,"utf8"));
    if(typeof j.need_update!=="boolean")process.exit(3);
    console.log([j.need_update,j.newest_version||"",j.total_bytes||"",j.downloads_url||"","end"].join("\n"))') \
    || die "the update endpoint sent an unexpected answer: $body"
  # The "end" line keeps blank trailing fields. Without it, read fails under set -e.
  { read -r NEED_UPDATE; read -r NEWEST_VERSION; read -r TOTAL_BYTES; read -r DOWNLOAD_URL; } <<<"$fields"
  [[ -z $NEWEST_VERSION ]] || validate_version "$NEWEST_VERSION" "the endpoint's newest_version"
}

# Stop unless the URL host is on the allowlist. A new host needs a person to review it.
check_download_url() {
  local url=$1 host h
  [[ $url = https://* ]] || die "the download URL is not https: $url"
  host=${url#https://}; host=${host%%/*}
  for h in "${DOWNLOAD_HOSTS[@]}"; do [[ $host != "$h" ]] || return 0; done
  die "the download host '$host' is not on the allowlist (${DOWNLOAD_HOSTS[*]}). Review it, then edit DOWNLOAD_HOSTS."
}

# --- checks: each prints positive evidence, and exits non-zero on failure ---

# Confirm that patched differs from base only in the three @img packages.
check_delta() {
  local label=$1 base=$2 patched=$3 out rc=0 line rel p ok only=() bad=()
  out=$(LC_ALL=C diff -rq "$base" "$patched") || rc=$?
  [[ $rc -le 1 ]] || die "$label: diff could not compare the trees (exit $rc)"
  [[ -n $out ]] || die "$label: no differences. The Linux @img packages are absent."
  while IFS= read -r line; do
    case "$line" in
      "Only in $patched/"*) rel=${line#Only in "$patched"/}; rel=${rel/: //} ;;
      "Files $base/"*)      rel=${line#Files "$base"/}; rel=${rel%% and "$patched"/*} ;;
      *)                    bad+=("$line"); continue ;;
    esac
    ok=0
    for p in "${IMG_PACKAGES[@]}"; do
      case "$rel" in node_modules/@img/"$p"|node_modules/@img/"$p"/*) ok=1 ;; esac
    done
    if [[ $ok = 1 ]]; then only+=("$rel"); else bad+=("$line"); fi
  done <<<"$out"
  if [[ ${#bad[@]} -gt 0 ]]; then
    printf '  unexpected: %s\n' "${bad[@]}" >&2
    die "$label: ${#bad[@]} difference(s) are outside the three @img packages"
  fi
  for p in sharp-libvips-linux-x64 sharp-linux-x64; do
    printf '%s\n' "${only[@]}" | grep -Fxq "node_modules/@img/$p" \
      || die "$label: node_modules/@img/$p is not an addition in the patched tree"
  done
  pass "$label: ${#only[@]} difference(s), all in @img/{colour,sharp-libvips-linux-x64,sharp-linux-x64}: ${only[*]}"
}

# Confirm that the Electron version in the installer equals the previous tree's version.
check_electron() {
  local exe=$1 tree=$2 ver linux_bin file_ver
  ver=$(LC_ALL=C grep -a -o 'Electron/[0-9][0-9.]*' "$exe" | sort -u) || true
  [[ -n $ver ]] || die "no Electron/<version> string in $exe"
  [[ $(wc -l <<<"$ver") -eq 1 ]] || die "more than one Electron version in $exe: $ver"
  ver=${ver#Electron/}
  linux_bin=$(LC_ALL=C grep -a -o 'Electron/[0-9][0-9.]*' "$tree/tiinyos" | sort -u) || true
  file_ver=$(cat "$tree/version")
  [[ $linux_bin = "Electron/$ver" && $file_ver = "$ver" ]] || \
    die "the Electron version changed. Vendor: $ver. Previous Linux tree: binary '$linux_bin', version file '$file_ver'. Get a Linux Electron tree for $ver. This script cannot reuse the previous tree."
  pass "electron: vendor exe $ver = previous Linux binary and version file"
}

# Confirm that the version of each @img package fits the sharp in the new stage.
check_versions() {
  local vendor_stage=$1 patched_stage=$2 img=node_modules/@img sv pv want have p
  sv=$(json_file_get "$vendor_stage/node_modules/sharp/package.json" version)
  pv=$(json_file_get "$patched_stage/node_modules/sharp/package.json" version)
  [[ -n $sv && $sv = "$pv" ]] || die "the sharp version changed: vendor '$sv', previous '$pv'. Get the Linux @img packages for $sv."
  for p in sharp-libvips-linux-x64 sharp-linux-x64; do
    [[ ! -e $vendor_stage/$img/$p ]] || die "the vendor asar now holds $img/$p. Review the recipe."
    [[ -f $patched_stage/$img/$p/package.json ]] || die "the previous build has no $img/$p"
    want=$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
                    console.log((j.optionalDependencies||{})[process.argv[2]]||"")' \
           "$vendor_stage/node_modules/sharp/package.json" "@img/$p")
    have=$(json_file_get "$patched_stage/$img/$p/package.json" version)
    [[ -n $want && $want = "$have" ]] || die "sharp $sv wants @img/$p '$want', but the previous build has '$have'"
  done
  have=$(json_file_get "$patched_stage/$img/colour/package.json" version)
  [[ -n $have ]] || die "the previous build has no $img/colour"
  if [[ -e $vendor_stage/$img/colour ]]; then
    want=$(json_file_get "$vendor_stage/$img/colour/package.json" version)
    [[ $want = "$have" ]] || die "the @img/colour version changed: vendor '$want', previous '$have'"
  fi
  pass "versions: sharp $sv, sharp-linux-x64 and libvips match sharp's pins, colour $have"
}

check_roundtrip() {
  local asar_file=$1 stage=$2 dest=$3 out rc=0 n
  rm -rf "$dest"
  asar_cmd extract "$asar_file" "$dest" || die "round trip: asar extract failed"
  out=$(LC_ALL=C diff -rq "$dest" "$stage") || rc=$?
  [[ $rc -eq 0 ]] || { printf '%s\n' "$out" >&2; die "round trip: packed asar differs from the stage (exit $rc)"; }
  n=$(file_count "$dest")
  [[ $n -gt 0 ]] || die "round trip: the extracted asar holds no files"
  pass "round trip: diff -rq reports 0 differences across $n files"
}

check_index() {
  local vendor=$1/out/main/index.js new=$2/out/main/index.js sum
  [[ -s $vendor && -s $new ]] || die "index.js: a file is absent or empty"
  cmp -s "$vendor" "$new" || die "index.js: out/main/index.js differs from the vendor copy"
  sum=$(sha256sum "$new" | cut -d' ' -f1)
  pass "index.js: byte-identical to vendor, $(stat -c %s "$new") bytes, sha256 $sum"
}

# Unpacked files must be: vendor list + three @img packages + vendor files the glob moved.
check_unpacked() {
  local vendor_asar=$1 vendor_unpacked=$2 new_asar=$3 new_unpacked=$4 vendor_stage=$5 tmp=$6
  local f p root img=() moved=() bad=()
  mkdir -p "$tmp"
  (cd "$vendor_unpacked" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) >"$tmp/vendor.files"
  (cd "$new_unpacked" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) >"$tmp/new.files"
  asar_cmd list --is-pack "$vendor_asar" | sed -n 's|^pack *: /||p' >"$tmp/vendor.packed"
  asar_cmd list --is-pack "$new_asar" | sed -n 's|^unpack *: /||p' | LC_ALL=C sort >"$tmp/new.header"
  [[ -s $tmp/vendor.files && -s $tmp/new.files && -s $tmp/vendor.packed && -s $tmp/new.header ]] \
    || die "unpacked list: a list is empty"

  f=$(LC_ALL=C comm -23 "$tmp/vendor.files" "$tmp/new.files")
  [[ -z $f ]] || { printf '  absent: %s\n' "$f" >&2; die "unpacked list: vendor files are absent"; }
  f=$(LC_ALL=C comm -23 "$tmp/new.files" "$tmp/new.header")
  [[ -z $f ]] || { printf '  no header entry: %s\n' "$f" >&2; die "unpacked list: files on disk are absent from the asar header"; }
  while IFS= read -r f; do
    cmp -s "$vendor_unpacked/$f" "$new_unpacked/$f" || bad+=("changed from vendor: $f")
  done <"$tmp/vendor.files"

  while IFS= read -r f; do
    [[ -n $f ]] || continue
    case "$f" in
      node_modules/@img/colour/*|node_modules/@img/sharp-libvips-linux-x64/*|node_modules/@img/sharp-linux-x64/*)
        img+=("$f"); continue ;;
    esac
    p=0
    for root in "${UNPACK_ROOTS[@]}"; do case "$f" in "$root"/*) p=1 ;; esac; done
    if [[ $p = 1 ]] && grep -Fxq "$f" "$tmp/vendor.packed" && cmp -s "$vendor_stage/$f" "$new_unpacked/$f"; then
      moved+=("$f")
    else
      bad+=("not explained: $f")
    fi
  done < <(LC_ALL=C comm -13 "$tmp/vendor.files" "$tmp/new.files")

  if [[ ${#bad[@]} -gt 0 ]]; then
    printf '  %s\n' "${bad[@]}" >&2
    die "unpacked list: ${#bad[@]} file(s) are outside the expected set"
  fi
  [[ -n $(find "$new_unpacked/node_modules/@img/sharp-linux-x64" -name 'sharp-linux-x64.node' -print -quit 2>/dev/null) ]] \
    || die "unpacked list: sharp-linux-x64.node is absent"
  for f in ${moved[@]+"${moved[@]}"}; do
    log "  moved from vendor asar to unpacked (the pack glob covers it, bytes unchanged): $f"
  done
  pass "unpacked list: $(wc -l <"$tmp/vendor.files") vendor files byte-identical + ${#img[@]} @img additions + ${#moved[@]} moved vendor file(s)"
}

# True if bwrap can make a new user and network namespace on this machine.
sandbox_works() {
  command -v bwrap >/dev/null 2>&1 || return 1
  bwrap --unshare-all --die-with-parent --ro-bind /usr /usr --ro-bind-try /lib /lib \
        --ro-bind-try /lib64 /lib64 --proc /proc --dev /dev /usr/bin/true >/dev/null 2>&1
}

# Load sharp from the asar with the Linux Electron, and create a tiny PNG.
# This runs vendor JS, so it runs in bwrap unless NO_SANDBOX_CHECK=1.
# The sandbox has no network, a tmpfs HOME, and read-only binds of /usr, the
# library links, the Electron tree and the asar. The JS tests these limits first.
# Neither form of the command matches the pgrep in tiiny-native.sh.
check_sharp() {
  local tiinyos=$1 asar_file=$2 tmp=$3 out rc=0 js asar_real tree probe=$HOME
  mkdir -p "$tmp/home" "$tmp/cwd"
  tmp=$(realpath "$tmp")   # The check changes directory, so the path must be absolute.
  asar_real=$(realpath "$asar_file")
  tree=$(dirname "$(realpath "$tiinyos")")
  # shellcheck disable=SC2016  # JavaScript. The shell must not expand it.
  js='const a=process.env.PORT_ASAR, q=process.env.PORT_SANDBOX_PROBE;
      if(q){ const fs=require("fs"), os=require("os");
        if(fs.existsSync(q)) throw new Error("sandbox leak: "+q+" is visible");
        const n=Object.keys(os.networkInterfaces()).filter(x=>x!=="lo");
        if(n.length) throw new Error("sandbox leak: network interfaces "+n);
        for(const w of [a+".probe", a+".unpacked/.probe", process.env.PORT_TREE+"/.probe"]){
          try{fs.writeFileSync(w,"x")}
          catch(e){if(e.code==="EROFS")continue;throw e}
          throw new Error("sandbox leak: "+w+" is writable");
        }
        console.log("sandbox ok: real HOME absent, no network interface except lo, asar and Electron tree read-only");
      }
      const p=a+"/node_modules/sharp", s=require(p);
      if(!require.resolve(p).startsWith(a+"/")) throw new Error("not from the asar: "+require.resolve(p));
      s({create:{width:2,height:2,channels:3,background:{r:1,g:2,b:3}}}).png().toBuffer().then(b=>{
        if(b.subarray(1,4).toString()!=="PNG") throw new Error("output is not a PNG");
        console.log("sharp ok: "+b.length+" byte PNG, sharp "+require(a+"/node_modules/sharp/package.json").version+", libvips "+s.versions.vips+", from "+require.resolve(p));
      }).catch(e=>{console.error(e);process.exit(1)});'
  if [[ $NO_SANDBOX_CHECK = 1 ]]; then
    log "WARNING: --no-sandbox-check: the sharp check runs vendor JS without a sandbox."
    ln -sfn "$(realpath "$tiinyos")" "$tmp/port-electron"
    out=$(cd "$tmp/cwd" && env -i PATH=/usr/bin:/bin HOME="$tmp/home" ELECTRON_RUN_AS_NODE=1 PORT_ASAR="$asar_real" \
          timeout 60 "$tmp/port-electron" -e "$js" 2>&1) || rc=$?
  else
    out=$(cd "$tmp/cwd" && env -i PATH=/usr/bin:/bin timeout 60 "$(command -v bwrap)" \
          --unshare-all --die-with-parent --new-session \
          --ro-bind /usr /usr --ro-bind-try /lib /lib --ro-bind-try /lib64 /lib64 \
          --proc /proc --dev /dev --tmpfs /tmp --tmpfs /home/port \
          --ro-bind "$tree" /port/electron \
          --ro-bind "$asar_real" /port/app/app.asar --ro-bind "$asar_real.unpacked" /port/app/app.asar.unpacked \
          --remount-ro / --chdir /tmp --setenv HOME /home/port --setenv ELECTRON_RUN_AS_NODE 1 \
          --setenv PORT_ASAR /port/app/app.asar --setenv PORT_TREE /port/electron --setenv PORT_SANDBOX_PROBE "$probe" \
          "/port/electron/$(basename "$tiinyos")" -e "$js" 2>&1) || rc=$?
    [[ $rc -ne 0 ]] || grep -q '^sandbox ok' <<<"$out" || die "sharp: no 'sandbox ok' line"
    [[ $rc -ne 0 ]] || pass "$(grep '^sandbox ok' <<<"$out")"
  fi
  [[ $rc -eq 0 ]] || { printf '%s\n' "$out" | tail -20 >&2; die "sharp: exit $rc"; }
  grep -q '^sharp ok' <<<"$out" || { printf '%s\n' "$out" >&2; die "sharp: no 'sharp ok' line"; }
  pass "$(grep '^sharp ok' <<<"$out")"
}

# --- reports: these print a result, and do not fail the build ----------------

# Names in URL or quoted-string positions. Dotted suffixes such as tiiny.ai do not match.
tiiny_names_in() {
  LC_ALL=C grep -rhaoE "(//|[\"'\`.}])[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)*\.tiiny(\.local)?(:[0-9]+)?[/\"'\`]" "$1" 2>/dev/null \
    | sed -E "s#^(//|[\"'\`.}])##; s#(:[0-9]+)?[/\"'\`]\$##" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u || true
}

report_hostnames() {
  local new_out=$1 prev_out=$2 caddy=$3 names served notserved prev_names fresh
  names=$(tiiny_names_in "$new_out")
  if [[ -z $names ]]; then
    log "REPORT hostnames: WARNING: 0 .tiiny names found in out/. The pattern may no longer fit. No comparison."
    return 0
  fi
  log "REPORT hostnames: $(wc -l <<<"$names") .tiiny name(s) in out/ (text matches, may include non-hostnames)"
  if [[ -z $caddy ]]; then
    log "REPORT hostnames: Caddy comparison skipped (no --caddy). Names: $(tr '\n' ' ' <<<"$names")"
    return 0
  fi
  served=$(sed 's/#.*//' "$caddy" | grep -oE 'http://[a-zA-Z0-9.-]+\.tiiny(\.local)?' | sed 's|^http://||' | LC_ALL=C sort -u || true)
  if [[ -z $served ]]; then
    log "REPORT hostnames: WARNING: 0 http://*.tiiny addresses in $caddy. No comparison."
    return 0
  fi
  notserved=$(LC_ALL=C comm -23 <(printf '%s\n' "$names") <(printf '%s\n' "$served"))
  prev_names=$(tiiny_names_in "$prev_out")
  fresh=$(LC_ALL=C comm -23 <(printf '%s\n' "$notserved") <(printf '%s\n' "$prev_names"))
  log "REPORT hostnames: $(wc -l <<<"$served") name(s) served in $caddy"
  log "REPORT hostnames: not served: ${notserved:-none}" | tr '\n' ' '; log ""
  log "REPORT hostnames: not served and new since the previous build: ${fresh:-none}" | tr '\n' ' '; log ""
}

report_pcsvr() {
  local prev=$1/pcsvr/windows/TiinyPCService_Installer.exe new=$2/pcsvr/windows/TiinyPCService_Installer.exe a b
  if [[ ! -f $prev || ! -f $new ]]; then
    log "REPORT PC Service: UNKNOWN: installer absent (previous: $([[ -f $prev ]] && echo present || echo absent), new: $([[ -f $new ]] && echo present || echo absent))"
    return 0
  fi
  a="$(stat -c %s "$prev") bytes, md5 $(md5sum "$prev" | cut -d' ' -f1)"
  b="$(stat -c %s "$new") bytes, md5 $(md5sum "$new" | cut -d' ' -f1)"
  if [[ $a = "$b" ]]; then log "REPORT PC Service: installer unchanged ($b)"
  else log "REPORT PC Service: installer CHANGED. Previous: $a. New: $b. This script does not install it."; fi
}

# --- build ------------------------------------------------------------------
default_from() {
  local d best=""
  while IFS= read -r d; do
    [[ -d $d/tiinyos-linux/resources ]] && best=$d
  done < <({ compgen -G "$BUILD_HOME/linux-native-build-[0-9]*" || true; } | sort -V)
  printf '%s' "$best"
}

# True if a process runs a binary from this directory. Command lines do not work
# here, because the app's main process and its helpers can name different paths.
running_from() {
  local link dir exe
  dir=$(realpath "$1")
  for link in /proc/[0-9]*/exe; do
    exe=$(readlink "$link" 2>/dev/null) || continue
    case "$exe" in "$dir"/*) return 0 ;; esac
  done
  return 1
}

usage() {
  sed -n 's/^#   \(\.\/build-native-port.sh.*\)/\1/p; s/^#  \( *\[--[cn].*\)/\1/p' "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

on_exit() {
  local rc=$?
  if [[ $BUILD_DONE != 1 && -n $WORK_DIR ]]; then
    printf 'BUILD NOT COMPLETE (exit %s). Work files are in %s\n' "$rc" "$WORK_DIR" >&2
    printf 'No tree was installed in the build directory. Use --force to run again.\n' >&2
  fi
}

main() {
  # An unguarded failed command must not exit without a message.
  trap 'printf "FAIL: command failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
  local from="" version="" exe="" caddy="" out="$BUILD_HOME" force=0 check_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from=${2:?--from needs a value}; shift 2 ;;
      --version) version=${2:?--version needs a value}; shift 2 ;;
      --exe) exe=${2:?--exe needs a value}; shift 2 ;;
      --caddy) caddy=${2:?--caddy needs a value}; shift 2 ;;
      --out) out=${2:?--out needs a value}; shift 2 ;;
      --force) force=1; shift ;;
      --check-only) check_only=1; shift ;;
      --no-sandbox-check) NO_SANDBOX_CHECK=1; shift ;;
      -h|--help) usage 0 ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; usage 2 ;;
    esac
  done
  [[ -z $version ]] || validate_version "$version" "--version"

  [[ -n $from ]] || from=$(default_from)
  local prev_ver=""
  if [[ -n $from ]]; then
    [[ $(basename "$from") != linux-native-build-* ]] || prev_ver=$(basename "$from"); prev_ver=${prev_ver#linux-native-build-}
  fi

  if [[ $check_only = 1 ]]; then
    detect_tools curl node
    local now=${version:-$prev_ver}
    [[ -n $now ]] || die "no current version. Give --version, or --from with a linux-native-build-<ver> directory."
    validate_version "$now" "the current version"
    query_endpoint "$now"
    log "current version: $now ($([[ -n $version ]] && echo 'from --version' || echo "from the name of $from"))"
    if [[ $NEED_UPDATE = true ]]; then
      log "NEWER VERSION EXISTS: $NEWEST_VERSION, $TOTAL_BYTES bytes, $DOWNLOAD_URL"
    else
      log "no newer version: the endpoint says need_update=false for $now"
    fi
    return 0
  fi

  detect_tools 7z node asar diff tar cmp sha256sum md5sum timeout
  if [[ $NO_SANDBOX_CHECK != 1 ]] && ! sandbox_works; then
    die "sharp check skipped and build stopped: bwrap is absent, or cannot make user namespaces. The check runs vendor JS. Install bwrap, or give --no-sandbox-check to run the check without a sandbox."
  fi
  [[ -n $from ]] || die "no previous build found in $BUILD_HOME (TIINY_HOME). Give --from <prev-build-dir>."
  local prev_tree="$from/tiinyos-linux" prev_res="$from/tiinyos-linux/resources"
  [[ -x $prev_tree/tiinyos ]] || die "$prev_tree/tiinyos is absent or not executable"
  [[ -f $from/run-tiinyos-linux.sh ]] || die "$from/run-tiinyos-linux.sh is absent"
  [[ -f $prev_res/app.asar.vendor && -d $prev_res/app.asar.unpacked.vendor ]] \
    || die "the previous build has no vendor asar copies. The script cannot verify that the recipe still applies."
  [[ -z $caddy || -f $caddy ]] || die "--caddy file not found: $caddy"
  [[ -z $exe || -f $exe ]] || die "--exe file not found: $exe"

  # Find the version and the download URL. No build directory exists yet.
  if [[ -z $exe ]]; then
    detect_tools curl
    # now_version 0.0.0: the endpoint omits the URL if now_version is the newest version.
    query_endpoint 0.0.0
    [[ $NEED_UPDATE = true && -n $NEWEST_VERSION && $TOTAL_BYTES =~ ^[0-9]+$ && $DOWNLOAD_URL = https://* ]] \
      || die "the endpoint gave no usable download: need_update=$NEED_UPDATE newest=$NEWEST_VERSION bytes=$TOTAL_BYTES url=$DOWNLOAD_URL"
    check_download_url "$DOWNLOAD_URL"
    if [[ -z $version ]]; then
      if [[ $NEWEST_VERSION = "$prev_ver" ]]; then
        log "no newer version: the endpoint offers $NEWEST_VERSION, and $from is already that version. Nothing built."
        return 0
      fi
      version=$NEWEST_VERSION
    elif [[ $version != "$NEWEST_VERSION" ]]; then
      die "the endpoint offers only $NEWEST_VERSION, not $version. Give --exe for another version."
    fi
  elif [[ -z $version ]]; then
    version=$(basename "$exe" | sed -nE 's/^tiinyos-([0-9][0-9A-Za-z.+-]*)-windows-amd64\.exe$/\1/p')
    [[ -n $version ]] || die "cannot read a version from the name of $exe. Give --version."
    validate_version "$version" "the version in the name of $exe"
  fi

  # Protect the previous build, then prepare the build directory.
  # The target must be a direct child of --out. A symlink at the target fails this test.
  local out_real target
  out_real=$(realpath -m "$out")
  target=$(realpath -m "$out_real/linux-native-build-$version")
  [[ $(dirname "$target") = "$out_real" && $(basename "$target") = "linux-native-build-$version" ]] \
    || die "the build directory resolves to '$target', which is not linux-native-build-$version directly in $out_real"
  mkdir -p "$out_real"
  local from_real; from_real=$(realpath "$from")
  case "$target/" in "$from_real"/*) die "the build directory $target is in or equals --from. Refused, also with --force." ;; esac
  case "$from_real/" in "$target"/*) die "--from is inside the build directory $target. Refused, also with --force." ;; esac
  if [[ -e $target ]]; then
    [[ $force = 1 ]] || die "$target exists. Use --force to replace it."
    if running_from "$target"; then
      die "a running process uses $target. Refused, also with --force."
    fi
    rm -rf "$target"
  fi
  local W="$target/.work"
  mkdir -p "$W"
  WORK_DIR=$W
  trap on_exit EXIT

  log "version $version, previous build $from_real"
  log "build directory $target"

  # Get the installer.
  if [[ -z $exe ]]; then
    mkdir -p "$W/download"
    exe="$W/download/tiinyos-$version-windows-amd64.exe"
    log "download $DOWNLOAD_URL"
    # No -L: a redirect could leave the allowlist. A redirect body fails the size test.
    curl "${CURL_TLS[@]}" -sS -f --retry 2 -o "$exe" "$DOWNLOAD_URL" || die "the download failed"
    [[ $(stat -c %s "$exe") = "$TOTAL_BYTES" ]] \
      || die "the download has $(stat -c %s "$exe") bytes, but the endpoint says $TOTAL_BYTES"
    pass "download: $TOTAL_BYTES bytes = endpoint total_bytes"
  fi
  log "installer $exe, $(stat -c %s "$exe") bytes"
  log "installer sha256 $(sha256sum "$exe" | cut -d' ' -f1) (for the record only: the vendor publishes no checksum)"

  # Step 1: extract the installer. Never run its contents.
  7z x -y -bso0 -bsp0 "-o$W/installer" "$exe" || die "7z could not extract $exe"
  local inner="$W/installer/\$PLUGINSDIR/app-64.7z"
  [[ -f $inner ]] || die "the installer has no \$PLUGINSDIR/app-64.7z"
  7z x -y -bso0 -bsp0 "-o$W/payload" "$inner" || die "7z could not extract app-64.7z"
  local res="$W/payload/resources" e known
  [[ -f $W/payload/TiinyOS.exe ]] || die "the payload has no TiinyOS.exe"
  for e in "${VENDOR_RESOURCES_REQUIRED[@]}"; do
    [[ -e $res/$e ]] || die "the payload has no resources/$e"
  done
  for e in "$res"/*; do
    e=$(basename "$e"); known=0
    for k in "${VENDOR_RESOURCES_REQUIRED[@]}" "${VENDOR_RESOURCES_DROPPED[@]}"; do [[ $e != "$k" ]] || known=1; done
    [[ $known = 1 ]] || die "the payload has an unknown entry resources/$e. Review the recipe."
  done
  pass "payload: resources/ holds only known entries (dropped: ${VENDOR_RESOURCES_DROPPED[*]})"

  # Step 2: Electron version.
  check_electron "$W/payload/TiinyOS.exe" "$prev_tree"

  # Step 3: extract the vendor asar. The vendor stage stays clean for comparison.
  asar_cmd extract "$res/app.asar" "$W/vendor-stage" || die "asar could not extract the vendor asar"
  local stage_ver; stage_ver=$(json_file_get "$W/vendor-stage/package.json" version)
  [[ $stage_ver = "$version" ]] || die "the vendor package.json says version '$stage_ver', not '$version'"
  pass "version: vendor package.json says $stage_ver"

  # Step 4: verify the recipe on the previous build, then apply it.
  # asar looks for <name>.unpacked, so give the vendor copies those names.
  mkdir -p "$W/prev-vendor-link"
  ln -s "$(realpath "$prev_res/app.asar.vendor")" "$W/prev-vendor-link/app.asar"
  ln -s "$(realpath "$prev_res/app.asar.unpacked.vendor")" "$W/prev-vendor-link/app.asar.unpacked"
  asar_cmd extract "$W/prev-vendor-link/app.asar" "$W/prev-vendor-stage" || die "asar could not extract the previous vendor asar"
  asar_cmd extract "$prev_res/app.asar" "$W/prev-patched-stage" || die "asar could not extract the previous patched asar"
  check_delta "previous build, vendor vs patched" "$W/prev-vendor-stage" "$W/prev-patched-stage"
  check_versions "$W/vendor-stage" "$W/prev-patched-stage"

  cp -a "$W/vendor-stage" "$W/stage"
  local p
  for p in "${IMG_PACKAGES[@]}"; do
    rm -rf "$W/stage/node_modules/@img/$p"
    cp -a "$W/prev-patched-stage/node_modules/@img/$p" "$W/stage/node_modules/@img/$p"
  done
  check_delta "new stage, vendor vs patched" "$W/vendor-stage" "$W/stage"

  # Step 5: copy the Linux tree. This is a real copy, because pack writes app.asar in place.
  mkdir -p "$W/tree"
  tar -C "$from" --exclude='*.log' --exclude='logs' --anchored \
      --exclude='tiinyos-linux/resources/app.asar' --exclude='tiinyos-linux/resources/app.asar.unpacked' \
      --exclude='tiinyos-linux/resources/app.asar.vendor' --exclude='tiinyos-linux/resources/app.asar.unpacked.vendor' \
      --exclude='tiinyos-linux/resources/app-update.yml' --exclude='tiinyos-linux/resources/pcsvr' \
      -cf - tiinyos-linux | tar -C "$W/tree" -xf - || die "the copy of the Linux tree failed"
  local new_tree="$W/tree/tiinyos-linux" new_res="$W/tree/tiinyos-linux/resources"
  [[ -z $(find "$new_tree" -name '*.log' -print -quit) ]] || die "the tree copy holds log files"
  cmp -s "$prev_tree/tiinyos" "$new_tree/tiinyos" || die "the copied tiinyos binary differs from the previous build"
  [[ ! -e $new_res/app.asar && ! -e $new_res/app.asar.unpacked ]] || die "an old asar survived the tree copy"
  cp -a "$res/app.asar" "$new_res/app.asar.vendor"
  cp -a "$res/app.asar.unpacked" "$new_res/app.asar.unpacked.vendor"
  cp -a "$res/pcsvr" "$new_res/pcsvr"
  cp -a "$res/app-update.yml" "$new_res/app-update.yml"

  # Step 6: pack.
  asar_cmd pack "$W/stage" "$new_res/app.asar" --unpack-dir "$(unpack_glob)" || die "asar pack failed"

  # Step 7: the launcher.
  cp -a "$from/run-tiinyos-linux.sh" "$W/tree/run-tiinyos-linux.sh"

  # Verification.
  check_roundtrip "$new_res/app.asar" "$W/stage" "$W/roundtrip"
  check_index "$W/vendor-stage" "$W/roundtrip"
  check_unpacked "$res/app.asar" "$res/app.asar.unpacked" "$new_res/app.asar" "$new_res/app.asar.unpacked" \
    "$W/vendor-stage" "$W/lists"
  check_sharp "$new_tree/tiinyos" "$new_res/app.asar" "$W/sharp"
  report_hostnames "$W/stage/out" "$W/prev-patched-stage/out" "$caddy"
  report_pcsvr "$prev_res" "$new_res"
  log "GUI not tested: --ozone-platform=headless segfaults after about 4 s on 1.0.1 and 1.0.2. Start the app once to test the GUI."

  # All checks passed. Install the tree.
  mv "$new_tree" "$target/tiinyos-linux"
  mv "$W/tree/run-tiinyos-linux.sh" "$target/run-tiinyos-linux.sh"
  [[ -x $target/tiinyos-linux/tiinyos && -f $target/tiinyos-linux/resources/app.asar ]] || die "the move to $target failed"
  rm -rf "$W"
  BUILD_DONE=1

  log ""
  log "BUILD OK: $PASSED checks passed. Result: $target"
  log "To adopt (this restart stops the running app):"
  log "  TIINY_NATIVE_BUILD=$(printf %q "$target") $(printf %q "$HERE/tiiny-native.sh") restart"
  grep -qs TIINY_NATIVE_BUILD "$HERE/tiiny-native.sh" \
    || log "  NOTE: $HERE/tiiny-native.sh does not read TIINY_NATIVE_BUILD. Set NB= in that launcher."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
