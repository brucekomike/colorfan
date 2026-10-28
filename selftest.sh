#!/usr/bin/env bash
# selftest.sh - offline checks for the pure logic in ./colorfan
# No root, no EC: the transport is stubbed by writing canned replies into REPLY_FILE,
# which is exactly the interface call() now exposes.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
fails=0
ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; fails=$((fails+1)); }
chk()  { [ "$2" = "$3" ] && ok "$1 -> $2" || bad "$1: got '$2' want '$3'"; }

# source the tool; "help" keeps it out of the commands that touch /proc/acpi/call.
# /dev/null stops the user's live /etc/colorfan.conf from changing expectations.
COLORFAN_CONF=/dev/null . "$HERE/colorfan" help >/dev/null 2>&1

# pin every value the checks below assume, independent of any installed config
CPU_CURVE='40:30 55:45 62:60 66:80 70:100'
GPU_CURVE="$CPU_CURVE"
UNMAPPED_DUTY=255
CPU_RPM_BYTES="3 4"; GPU_RPM_BYTES="5 6"; CPU_DUTY_BYTE=17; GPU_DUTY_BYTE=20

CALL_LOG=/tmp/colorfan_selftest_calls
: > "$CALL_LOG"
# drop the REPLY_FILE that sourcing colorfan just created, so nothing leaks
[ -n "${REPLY_FILE:-}" ] && rm -f "$REPLY_FILE"
REPLY_FILE=$(mktemp /tmp/colorfan_selftest_reply.XXXXXX)
cleanup_reply() { rm -f "$REPLY_FILE" "$CALL_LOG"; }
trap cleanup_reply EXIT

# two reply shapes acpi_call can hand back: comma-separated hex text, or a raw buffer
fake_hex() { local i out=(); for i in $(seq 1 256); do out+=(0x00); done
             out[2]=0x01; out[3]=0xc1; out[16]=0x80; out[19]=0xff
             printf '{ '; local IFS=','; printf '%s' "${out[*]}"; printf ' }\n'; }
# captured live from BK-X17PRO on 2026-10-26 (sudo colorfan probe), 253 bytes:
#   { 0x00, 0x00, 0x01, 0x7e, 0x05, ... }  -> byte3/4 = 0x017e = 382 -> 5644 rpm
fake_real() { local i out=(); for i in $(seq 1 42); do out+=(0x00); done
              out[2]=0x01; out[3]=0x7e; out[4]=0x05
              local IFS=','; printf '{ %s }\n' "${out[*]}"; }
fake_binary() { local i fmt=""
  for i in $(seq 1 256); do
    case $i in 3) fmt+='\001';; 4) fmt+='\301';; 17) fmt+='\200';; 20) fmt+='\377';;
             *) fmt+='\000';; esac
  done
  printf "$fmt" > "$REPLY_FILE"; }

call() {
  printf '%s %s %s\n' "$FAN_METHOD" "$1" "$2" >> "$CALL_LOG"
  case "$1" in
    "$CMD_READ") fake_hex > "$REPLY_FILE" ;;
    *) printf 'NULL\n' > "$REPLY_FILE" ;;
  esac
}

echo "== curve: duty percent from temperature =="
chk "40C" "$(curve_pct 40 "$CPU_CURVE")" 30
chk "55C" "$(curve_pct 55 "$CPU_CURVE")" 45
chk "57C" "$(curve_pct 57 "$CPU_CURVE")" 49
chk "70C" "$(curve_pct 70 "$CPU_CURVE")" 100
chk "35C clamped low"  "$(curve_pct 35 "$CPU_CURVE")" 30
chk "95C clamped high" "$(curve_pct 95 "$CPU_CURVE")" 100
chk "62.5C interpolated" "$(curve_pct 62.5 "$CPU_CURVE")" 63

echo "== percent -> 0-255 duty =="
chk "100%" "$(pct2duty 100)" 255
chk "30%"  "$(pct2duty 30)"  76
chk "0%"   "$(pct2duty 0)"   0

echo "== duty word byte order (byte0 = channel 1) =="
chk "all max"       "$(duty_word 255 255 255 255)"  0xffffffff
chk "cpu255 gpu128" "$(duty_word 255 128 255 255)"  0xffff80ff

echo "== apply_duty honours the channel map =="
: > "$CALL_LOG"; CPU_DUTY=1 GPU_DUTY=2 apply_duty 255 128
chk "map 1/2" "$(grep -o '0x[0-9a-fx]*' "$CALL_LOG" | tail -1)" 0xffff80ff
: > "$CALL_LOG"; CPU_DUTY=2 GPU_DUTY=1 apply_duty 0 255
chk "map 2/1 swapped" "$(grep -o '0x[0-9a-fx]*' "$CALL_LOG" | tail -1)" 0xffff00ff
: > "$CALL_LOG"; CPU_DUTY=3 GPU_DUTY=4 apply_duty 200 100
chk "map 3/4, ch1-2 stay full" "$(grep -o '0x[0-9a-fx]*' "$CALL_LOG" | tail -1)" 0x64c8ffff

echo "== telemetry parsing: hex text reply =="
read_telemetry
chk "byte count"       "${#TEL[@]}" 256
chk "byte 3 (hi tach)" "$(getb 3)"   1
chk "byte 4 (lo tach)" "$(getb 4)"   193
chk "stopped fan"      "$(rpm_at 5 6)" -
chk "duty ch1"         "$(getb 17)"  128
chk "duty ch2"         "$(getb 20)"  255
chk "out of range"     "$(getb 999)" '?'
rpm_at 3 4 | grep -qE '^(47|48)[0-9]{2}$' && ok "rpm_at 3/4 -> $(rpm_at 3 4) (expect ~4800)" \
  || bad "rpm_at 3/4 -> $(rpm_at 3 4), expected ~4800"

echo "== the exact reply shape captured from your BIOS (253 bytes, ~42 values) =="
fake_real > "$REPLY_FILE"
TEL=(); for b in $(reply_bytes); do TEL+=("$b"); done
chk "real value count" "${#TEL[@]}" 42
chk "real byte 3"      "$(getb 3)"   1
chk "real byte 4"      "$(getb 4)"   126
chk "real cpu rpm"     "$(rpm_at 3 4)" 5644
chk "real gpu rpm"     "$(rpm_at 5 6)" 1684
chk "real no NUL warn" "$(fake_real > "$REPLY_FILE"; reply_bytes 2>&1 >/dev/null | grep -c 'null byte')" 0

echo "== telemetry parsing: raw buffer with NUL bytes (the line-41 bug) =="
fake_binary
TEL=(); for b in $(reply_bytes); do TEL+=("$b"); done
chk "raw byte count" "${#TEL[@]}" 256
chk "raw NUL kept"   "${TEL[0]}"  0
chk "raw byte 4"     "$(getb 4)"  193
chk "raw duty ch1"   "$(getb 17)" 128
rpm_at 3 4 | grep -qE '^(47|48)[0-9]{2}$' && ok "raw rpm_at 3/4 -> $(rpm_at 3 4)" \
  || bad "raw rpm_at 3/4 -> $(rpm_at 3 4)"
# a void method answering NULL must not be fatal
printf 'NULL\n' > "$REPLY_FILE"
call $CMD_SET_DUTY 0xffffffff && ok "NULL reply tolerated on duty write" || bad "NULL reply fatal"

echo "== auto + mode writes =="
: > "$CALL_LOG"; auto_all
chk "auto word" "$(awk '{print $2, $3}' "$CALL_LOG" | tail -1)" "0x69 0x0000000f"

echo
if [ "$fails" = 0 ]; then echo "selftest: all checks passed"; else echo "selftest: $fails FAILED"; fi
exit "$fails"
