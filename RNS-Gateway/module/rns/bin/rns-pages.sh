#!/system/bin/sh
# Start ONLY the admin panel and captive portal listener.
# Do not source store.sh, net.sh, common.sh, or rns-http.sh.
# Called from service.sh (boot), boot-completed.sh (BOOT_COMPLETED),
# action.sh (Magisk Action), and rnsd.sh.
# A broken voucher or firewall script must not stop this listener.
#
# v8: ENGINES ARE LIVE-VERIFIED. A pid file is NOT proof that the pages are
# being served: on the phone the compiled listeners can fail to exec, and the
# busybox nc fallback can die instantly when this ROM's nc lacks -k or -e.
# The old code logged "pages listening" even when the process was already
# dead — which is exactly how the admin panel and the captive portal could
# both be "not showing" while every script claimed success.
#
# Engine ladder — each rung is started, then a real HTTP request is sent to
# 127.0.0.1:PORT/health. Only a rung that ANSWERS is kept:
#   1. bin       rns-httpd-<abi> compiled listener (full function, CLIENT_IP)
#   2. nc-e      busybox nc -l -p PORT -e wrap in a keep-alive loop
#   3. nc-c      same loop with -c (some nc builds spell it -c)
#   4. nc-fifo   inetd loop over a named pipe — ANY nc that can do
#                `nc -l -p PORT` (no -e needed)
#   5. httpd     busybox httpd with a generated www overlay — pages, admin
#                login and every captive probe path still work; voucher APIs
#                are degraded (last resort, never silent)
# The supervisor re-runs this script every 15 s, so a phone with no working
# rung right now is re-laddered forever instead of sitting dark.

_here=${0%/*}
export RNS_HOME=${RNS_HOME:-${_here%/*}}
export RNS_LAB=${RNS_LAB:-0}

if [ -z "${BB:-}" ]; then
  if [ -x /data/adb/magisk/busybox ]; then
    BB=/data/adb/magisk/busybox
  elif [ -x /usr/bin/busybox ]; then
    BB=/usr/bin/busybox
  else
    BB=busybox
  fi
fi
export BB
export RNS_BB=$BB

if [ "$RNS_LAB" = "1" ] && [ -n "${RNS_DATA:-}" ]; then
  STATE=$RNS_DATA
else
  STATE=/data/adb/rns
fi
mkdir -p "$STATE" 2>/dev/null || true
mkdir -p /data/local/tmp 2>/dev/null || true

# The pid and mode files decide whether the listener is already up. If the
# state directory cannot be written, pid_alive() would never see the listener
# and every supervisor pass would try to relaunch it. Pick a writable state
# directory instead, and still read the port config from every known place.
if [ ! -w "$STATE" ]; then
  for _d in "${RNS_DATA:-}" /data/local/tmp /tmp; do
    [ -n "$_d" ] || continue
    if mkdir -p "$_d" 2>/dev/null && [ -w "$_d" ]; then
      STATE=$_d
      break
    fi
  done
fi

read_port_file() {
  _f=$1
  [ -f "$_f" ] || return 1
  _p=$("$BB" sed -n 's/^PORTAL_PORT=//p' "$_f" 2>/dev/null | "$BB" head -n 1 | "$BB" tr -d '\r')
  case "$_p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  PORT=$_p
  return 0
}

PORT=8080
if [ -n "${RNS_PORT:-}" ]; then
  case "$RNS_PORT" in
    *[!0-9]*) ;;
    *) PORT=$RNS_PORT ;;
  esac
else
  read_port_file "$STATE/page.env" \
    || read_port_file "$STATE/config.env" \
    || read_port_file /data/adb/rns/page.env \
    || read_port_file /data/adb/rns/config.env \
    || true
fi

if [ -w /data/local/tmp ]; then
  LOG=/data/local/tmp/rns_hotspot.log
else
  LOG="$STATE/pages.log"
fi

logp() {
  _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
  printf '%s %s\n' "$_ts" "$*" >> "$LOG" 2>/dev/null || true
}

HANDLER="$RNS_HOME/bin/rns-front.sh"
printf '%s\n' "$PORT" > "$STATE/portal.port" 2>/dev/null || true

record_engine() {
  # The page shell and diagnostics read this to say which listener serves.
  printf '%s\n' "$1" > "$STATE/httpd.engine" 2>/dev/null || true
  printf '%s\n' "$1" > "$RNS_HOME/engine" 2>/dev/null || true
}

pid_alive() {
  [ -f "$STATE/httpd.pid" ] || return 1
  _pid=$(cat "$STATE/httpd.pid" 2>/dev/null)
  case "$_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$_pid" 2>/dev/null
}

stop_listener() {
  # TERM, wait, then KILL. Leaves no stale pid file behind. The group kill
  # and the /proc sweep cover loop-based engines whose nc child can outlive
  # its parent shell on some busybox builds and keep holding the port.
  _old=$(cat "$STATE/httpd.pid" 2>/dev/null)
  if [ -n "$_old" ]; then
    kill "$_old" 2>/dev/null || true
    sleep 1
    kill -9 "$_old" 2>/dev/null || true
    kill -9 "-$_old" 2>/dev/null || true
  fi
  for _p in /proc/[0-9]*; do
    _pid=${_p#/proc/}
    [ "$_pid" = "$$" ] && continue
    if "$BB" cat "$_p/cmdline" 2>/dev/null | "$BB" tr '\0' ' ' | "$BB" grep -q -- "nc.*-p $PORT"; then
      kill -9 "$_pid" 2>/dev/null || true
    fi
  done
  rm -f "$STATE/httpd.pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# LIVE PROBE. The only proof that the pages are being served is an HTTP
# answer on the port. curl -> busybox wget -> raw nc request. Both the page
# shell and the static httpd overlay answer /health with "pages":true.
# ---------------------------------------------------------------------------
probe_pages() {
  _url="http://127.0.0.1:${PORT}/health"
  _out=""
  if command -v curl >/dev/null 2>&1; then
    _out=$(curl -sS -m 2 "$_url" 2>/dev/null)
  fi
  if [ -z "$_out" ] && "$BB" wget --help >/dev/null 2>&1; then
    _out=$("$BB" wget -q -T 2 -O - "$_url" 2>/dev/null)
  fi
  if [ -z "$_out" ]; then
    _out=$(printf 'GET /health HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n' \
      | "$BB" nc -w 2 127.0.0.1 "$PORT" 2>/dev/null)
  fi
  case "$_out" in
    *'"pages":true'*) return 0 ;;
  esac
  return 1
}

wait_for_pages() {
  # Give a just-launched listener a moment, then insist on a real answer.
  _i=0
  while [ "$_i" -lt 5 ]; do
    probe_pages && return 0
    _i=$((_i + 1))
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------------------
# Compiled listeners. The ABI property can lie (32-bit userspace on a 64-bit
# kernel is common on budget phones), so every shipped binary gets a --check
# run, and the ladder live-verifies the launch itself. RNS_SKIP names the
# binaries already proven broken this ladder run.
# ---------------------------------------------------------------------------
BIN_DIR=${RNS_HTTPD_DIR:-$RNS_HOME/bin}

pick_httpd() {
  _abi=""
  if command -v getprop >/dev/null 2>&1; then
    _abi=$(getprop ro.product.cpu.abi 2>/dev/null)
  fi
  case "$_abi" in
    arm64*)        set -- arm64 arm x86_64 ;;
    armeabi*|arm*) set -- arm arm64 x86_64 ;;
    x86_64)        set -- x86_64 arm arm64 ;;
    *)             set -- arm64 arm x86_64 ;;
  esac
  for _a in "$@"; do
    case " ${RNS_SKIP:-} " in
      *" rns-httpd-$_a "*) continue ;;
    esac
    _b="$BIN_DIR/rns-httpd-$_a"
    if [ -x "$_b" ] && "$_b" --check >/dev/null 2>&1; then
      printf '%s' "$_b"
      return 0
    fi
  done
  return 1
}

# Detach a background program from the caller's session so the caller
# returning (Magisk Action, late_start service) cannot take the pages down.
# `setsid PROG` execs PROG, so $! is the program's own pid. Builds without
# setsid fall back to a HUP-ignoring subshell.
SETSID=""
for _c in "$BB" setsid /system/bin/setsid /usr/bin/setsid; do
  if "$_c" setsid true >/dev/null 2>&1; then
    SETSID="$_c setsid"
    break
  fi
done

launch() {
  # Start detached; the pid recorded is the listener's own when setsid execs.
  if [ -n "$SETSID" ]; then
    # shellcheck disable=SC2086
    $SETSID "$@" >> "$LOG" 2>&1 < /dev/null &
  else
    (
      trap '' HUP
      exec "$@"
    ) >> "$LOG" 2>&1 < /dev/null &
  fi
  echo $! > "$STATE/httpd.pid"
}

# ---------------------------------------------------------------------------
# Fallback wrappers. Written to $STATE because that is the only place
# guaranteed writable on a phone. Each one execs the page shell per
# connection exactly like the compiled listener does.
# ---------------------------------------------------------------------------
write_wrap() {
  # The wrap is EXECUTED by `nc -e`, so its shebang interpreter must exist
  # on THIS machine: /system/bin/sh on Android, /bin/sh in the lab. A wrong
  # shebang makes nc die with "can't execute ... No such file or directory"
  # and every fallback rung fails while looking broken for no reason.
  _sh=/system/bin/sh
  [ -x "$_sh" ] || _sh=/bin/sh
  _wrap="$STATE/nc-wrap.sh"
  cat > "$_wrap" << EOF
#!$_sh
export RNS_HOME='$RNS_HOME'
export RNS_DATA='${RNS_DATA:-/data/adb/rns}'
export RNS_LAB='${RNS_LAB}'
export RNS_DATA_AUTO='${RNS_DATA_AUTO:-1}'
export RNS_NO_WATCHDOG='${RNS_NO_WATCHDOG:-0}'
export BB='$BB'
export RNS_BB='$BB'
exec '$BB' sh '$HANDLER'
EOF
  chmod 755 "$_wrap" 2>/dev/null || true
}

write_nc_loop() {
  # $1 = per-connection exec flag (-e or -c). Used only where nc lacks -k:
  # one connection at a time, respawned with only a 100 ms gap so a probe
  # rarely lands in it. The nc runs as a tracked child so stopping the loop
  # really frees the port.
  _loop="$STATE/nc-loop.sh"
  cat > "$_loop" << EOF
#!/system/bin/sh
C=""
trap '[ -n "\$C" ] && kill "\$C" 2>/dev/null; exit 0' TERM INT HUP
while :; do
  '$BB' nc -l -p '$PORT' $1 '$STATE/nc-wrap.sh' &
  C=\$!
  wait "\$C"
  C=""
  '$BB' usleep 10000 2>/dev/null || true
done
EOF
  chmod 755 "$_loop" 2>/dev/null || true
}

write_nc_fifo() {
  # Inetd over a named pipe: needs nothing from nc but `nc -l -p PORT`.
  _fifo="$STATE/nc-fifo-loop.sh"
  cat > "$_fifo" << EOF
#!/system/bin/sh
F='$STATE/nc.fifo'
rm -f "\$F"
'$BB' mkfifo "\$F" 2>/dev/null || exit 1
C=""
trap '[ -n "\$C" ] && kill "\$C" 2>/dev/null; rm -f "\$F"; exit 0' TERM INT HUP
while :; do
  '$BB' sh '$STATE/nc-wrap.sh' < "\$F" | '$BB' nc -l -p '$PORT' > "\$F" &
  C=\$!
  wait "\$C"
  C=""
  '$BB' usleep 10000 2>/dev/null || true
done
EOF
  chmod 755 "$_fifo" 2>/dev/null || true
}

write_httpd_www() {
  # busybox httpd overlay: the two pages plus every captive probe path as
  # real files (200 answers), custom 404 = portal. This rung cannot run the
  # voucher API, but the sign-in page and the staff login still come up —
  # and the log says so, loudly.
  WWW="$STATE/httpd-www"
  mkdir -p "$WWW/library/test" "$WWW/kindle-wifi" 2>/dev/null || true
  if [ -s "$RNS_HOME/www/portal.html" ]; then
    cp "$RNS_HOME/www/portal.html" "$WWW/index.html" 2>/dev/null || true
    cp "$RNS_HOME/www/portal.html" "$WWW/portal.html" 2>/dev/null || true
  fi
  if [ -s "$RNS_HOME/www/admin.html" ]; then
    cp "$RNS_HOME/www/admin.html" "$WWW/admin" 2>/dev/null || true
    cp "$RNS_HOME/www/admin.html" "$WWW/admin.html" 2>/dev/null || true
  fi
  [ -s "$WWW/index.html" ] || printf '<!doctype html><html><body><h1>Welcome online.</h1><p>Enter the voucher from the counter. One code unlocks this phone.</p><form method="post" action="/api/redeem"><input name="code" placeholder="ABCD-1234"><button type="submit">Connect securely</button></form></body></html>\n' > "$WWW/index.html"
  [ -s "$WWW/admin" ] || printf '<!doctype html><html><body><h1>Staff login</h1></body></html>\n' > "$WWW/admin"
  printf '{"ok":true,"service":"rns-httpd-static","pages":true,"admin":true,"portal":true,"engine":"httpd-static","client_ip":""}' > "$WWW/health"
  for _p in generate_204 gen_204 generate204 hotspot-detect.html \
    ncsi.txt connecttest.txt success.txt canonical.html \
    check_network_status.txt connectivity-check.html neverssl.txt blank.html; do
    cp "$WWW/index.html" "$WWW/$_p" 2>/dev/null || true
  done
  cp "$WWW/index.html" "$WWW/library/test/success.html" 2>/dev/null || true
  cp "$WWW/index.html" "$WWW/kindle-wifi/wifistub.html" 2>/dev/null || true
  printf 'E404:index.html\n' > "$WWW/httpd.conf" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# The ladder.
# ---------------------------------------------------------------------------
run_bin_all() {
  # Try every shipped binary until one answers /health for real.
  RNS_SKIP=""
  while _bin=$(pick_httpd); do
    logp "trying compiled listener $_bin"
    launch "$_bin" "$PORT" "$HANDLER"
    if wait_for_pages; then
      record_engine "rns-httpd ${_bin##*/}"
      printf 'front\n' > "$STATE/httpd.mode"
      logp "pages listening 0.0.0.0:$PORT pid=$(cat "$STATE/httpd.pid" 2>/dev/null) engine=rns-httpd ${_bin##*/}"
      return 0
    fi
    logp "compiled listener ${_bin##*/} did not answer — next engine"
    stop_listener
    RNS_SKIP="$RNS_SKIP ${_bin##*/}"
  done
  return 1
}

run_nc_flag() {
  # $1 = -e or -c. Prefer the keep-open form: one process, zero gap
  # between connections (a probe landing in a respawn gap sees a dead
  # port). nc builds without -k get the instant-respawn loop instead.
  write_wrap
  logp "trying busybox nc -lk $1"
  launch "$BB" nc -lk -p "$PORT" "$1" "$STATE/nc-wrap.sh"
  if wait_for_pages; then
    record_engine "nc$1"
    printf 'front\n' > "$STATE/httpd.mode"
    logp "pages listening 0.0.0.0:$PORT pid=$(cat "$STATE/httpd.pid" 2>/dev/null) engine=nc$1"
    return 0
  fi
  stop_listener
  logp "busybox nc -lk $1 not usable here — trying the respawn loop"
  write_nc_loop "$1"
  launch "$BB" sh "$STATE/nc-loop.sh"
  if wait_for_pages; then
    record_engine "nc$1"
    printf 'front\n' > "$STATE/httpd.mode"
    logp "pages listening 0.0.0.0:$PORT pid=$(cat "$STATE/httpd.pid" 2>/dev/null) engine=nc$1"
    return 0
  fi
  logp "busybox nc $1 loop did not answer — next engine"
  stop_listener
  return 1
}

run_nc_fifo() {
  write_wrap
  write_nc_fifo
  logp "trying busybox nc fifo inetd loop (needs no -e)"
  launch "$BB" sh "$STATE/nc-fifo-loop.sh"
  if wait_for_pages; then
    record_engine "nc-fifo"
    printf 'front\n' > "$STATE/httpd.mode"
    logp "pages listening 0.0.0.0:$PORT pid=$(cat "$STATE/httpd.pid" 2>/dev/null) engine=nc-fifo"
    return 0
  fi
  logp "nc fifo loop did not answer — next engine"
  stop_listener
  return 1
}

run_httpd_static() {
  if ! "$BB" --list 2>/dev/null | "$BB" grep -qx httpd; then
    logp "busybox httpd not available in this busybox"
    return 1
  fi
  write_httpd_www
  logp "trying busybox httpd static overlay (pages only — voucher API degraded)"
  launch "$BB" httpd -f -p "$PORT" -h "$STATE/httpd-www"
  if wait_for_pages; then
    record_engine "httpd-static"
    printf 'front\n' > "$STATE/httpd.mode"
    logp "pages listening 0.0.0.0:$PORT pid=$(cat "$STATE/httpd.pid" 2>/dev/null) engine=httpd-static"
    return 0
  fi
  logp "busybox httpd overlay did not answer"
  stop_listener
  return 1
}

# --- mutual exclusion: two starters racing must not double-bind -------------
LOCK="$STATE/pages.lock"
lock_or_wait() {
  _i=0
  while [ "$_i" -lt 20 ]; do
    if mkdir "$LOCK" 2>/dev/null; then
      printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null || true
      return 0
    fi
    # Someone else is laddering right now. If the pages come up, we are done.
    probe_pages && return 1
    sleep 1
    _i=$((_i + 1))
  done
  # Stale lock (holder died): take it over.
  rm -rf "$LOCK" 2>/dev/null || true
  mkdir "$LOCK" 2>/dev/null && return 0
  return 1
}

release_lock() {
  rm -rf "$LOCK" 2>/dev/null || true
}

# --- main ------------------------------------------------------------------
# 1. A healthy, ANSWERING page listener is already up. One exception: a
#    fallback engine is upgraded to a compiled binary the moment one works —
#    the fallback is a lifeboat, not a destination.
if pid_alive && [ -f "$STATE/httpd.mode" ] && [ "$(cat "$STATE/httpd.mode" 2>/dev/null)" = "front" ]; then
  if probe_pages; then
    _eng=$(cat "$STATE/httpd.engine" 2>/dev/null)
    case "$_eng" in
      rns-httpd\ *)
        logp "pages already listening port=$PORT pid=$(cat "$STATE/httpd.pid" 2>/dev/null) engine=$_eng"
        exit 0
        ;;
    esac
    RNS_SKIP=""
    if _upbin=$(pick_httpd); then
      logp "upgrading fallback engine ${_eng:-unknown} to $_upbin"
      stop_listener
    else
      logp "pages already listening port=$PORT pid=$(cat "$STATE/httpd.pid" 2>/dev/null) engine=${_eng:-unknown}"
      exit 0
    fi
  else
    logp "listener pid=$(cat "$STATE/httpd.pid" 2>/dev/null) is alive but does NOT answer HTTP — replacing it"
    stop_listener
  fi
fi

if pid_alive; then
  logp "replacing listener that is not the isolated page shell pid=$(cat "$STATE/httpd.pid" 2>/dev/null)"
  stop_listener
fi

if ! lock_or_wait; then
  # Another starter won the race and the pages answer (or we cannot lock).
  exit 0
fi

# Engine order can be forced for tests: RNS_ENGINES="nc-fifo" etc.
RNG=${RNS_ENGINES:-bin nc-e nc-c nc-fifo httpd}
for _eng in $RNG; do
  case "$_eng" in
    bin)     run_bin_all     && { release_lock; exit 0; } ;;
    nc-e)    run_nc_flag -e  && { release_lock; exit 0; } ;;
    nc-c)    run_nc_flag -c  && { release_lock; exit 0; } ;;
    nc-fifo) run_nc_fifo     && { release_lock; exit 0; } ;;
    httpd)   run_httpd_static && { release_lock; exit 0; } ;;
  esac
done

record_engine "NONE"
printf 'front\n' > "$STATE/httpd.mode" 2>/dev/null || true
logp "NO engine could serve the pages on port $PORT — will retry on the next supervisor pass"
release_lock
exit 1
