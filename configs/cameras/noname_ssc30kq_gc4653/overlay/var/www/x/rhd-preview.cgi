#!/bin/sh
#
# rhd-preview.cgi -- serve /x/ch<N>.jpg and /x/ch<N>.mjpg from raptor's rhd.
#
# The web UI's in-page previews are plain <img> tags pointing at the webui
# origin: preview.js:715 sets src to "/x/<ch>.mjpg" for any element carrying a
# data-stream attribute, and preview.js:178-182 lists /x/ch0.mjpg and
# /x/ch1.mjpg as its endpoints. Nothing on a raptor board answered those --
# rhd serves the same content, but on its own port, with its own credentials,
# and (by default here) over TLS with a self-signed certificate a browser will
# not silently accept from an <img>. Hence a proxy rather than a redirect.
#
# Reached through four symlinks (ch0.jpg, ch1.jpg, ch0.mjpg, ch1.mjpg) because
# the URL is what the web UI hardcodes; the channel and the format both come
# from SCRIPT_NAME. uhttpd runs everything under its -x prefix as CGI, so the
# ".jpg" and ".mjpg" names are executed rather than served as static files.
#
# Placement: this is raptor's proxy, not this board's, and its natural home is
# beside webrtc-whip.cgi in package/thingino-raptor/files/www/x/. It lives in
# the camera overlay instead because that package installs its www files one
# INSTALL line at a time, so adding it there means editing a shared file for
# three lines of benefit. Move it if a second SigmaStar board appears, or if it
# is offered upstream.

. /var/www/x/auth.sh
require_auth

set -u

send_error() {
	printf 'Status: %s\r\n' "$1"
	printf 'Content-Type: application/json\r\n'
	printf 'Cache-Control: no-store\r\n\r\n'
	printf '{"error":"%s"}\n' "$2"
	exit 0
}

# ── Which channel, which format, which disposition ───────────────────────────
# Names follow the set thingino-webui installs (ch0/ch1 .jpg and .mjpg, dl0/dl1
# .jpg for the download buttons at main.js:1819,1844) plus the image.cgi /
# image1.cgi that thingino-onvif symlinks in for its snapurls. Same convention
# timps uses for the same reason -- see package/timps/files/www/x/ch0.jpg.
#
# The name comes from SCRIPT_NAME rather than $0 because these are symlinks:
# $0 is whatever path the server chose to exec, which may already be resolved
# to this file, whereas SCRIPT_NAME is the URL and always distinguishes them.
name="${SCRIPT_NAME:-$0}"
name="${name##*/}"
ext="${name##*.}"

stream=0
attach=0
case "$name" in
	ch1.* | dl1.* | image1.*) stream=1 ;;
	ch0.* | dl0.* | image.* | image0.*) stream=0 ;;
	*) send_error "404 Not Found" "bad_channel" ;;
esac
case "$name" in
	dl[01].*) attach=1 ;;
esac

# image.cgi is an ONVIF snapshot: a still, despite the extension.
case "$ext" in
	mjpg) fmt=mjpeg ;;
	jpg | cgi) fmt=jpeg ;;
	*) send_error "404 Not Found" "bad_format" ;;
esac

# An explicit chn= wins, matching the stock and timps handlers.
OLD_IFS=$IFS
IFS='&'
for kv in ${QUERY_STRING:-}; do
	case "$kv" in
		chn=0) stream=0 ;;
		chn=1) stream=1 ;;
	esac
done
IFS=$OLD_IFS

# ── Where rhd is ──────────────────────────────────────────────────────────────
# Section and key names from rhd_main.c:940-968. Defaults match its own.
rhd_cfg() {
	raptorctl config get http "$1" 2>/dev/null | tr -d ' \t\r\n"'
}

port="$(rhd_cfg port)"
[ -n "$port" ] || port=8080

case "$(rhd_cfg https)" in
	true | 1 | yes | on) scheme=https ;;
	*) scheme=http ;;
esac

user="$(rhd_cfg username)"
pass="$(rhd_cfg password)"

base="$scheme://127.0.0.1:$port"

# -k because rhd's certificate is the same self-signed uhttpd one and this hop
# never leaves the loopback interface.
set -- -skS --max-time 0
[ -n "$user$pass" ] && set -- "$@" -u "$user:$pass"

# ── Preflight ────────────────────────────────────────────────────────────────
# An unrouted path costs rhd nothing: handle_request checks auth first, then
# falls through to a 404 (rhd_main.c:383). A snapshot would be the obvious probe
# but it wakes the JPEG encoder and burns a frame, and for the .mjpg case we
# have to know the backend is up *before* emitting the multipart header --
# once headers are out there is no way to report a failure.
code="$(curl "$@" --max-time 3 -o /dev/null -w '%{http_code}' "$base/preflight" 2>/dev/null)" || {
	send_error "502 Bad Gateway" "backend_unreachable"
}

case "$code" in
	401) send_error "502 Bad Gateway" "backend_auth_failed" ;;
	000 | "") send_error "502 Bad Gateway" "backend_unreachable" ;;
esac

# ── Serve ────────────────────────────────────────────────────────────────────
if [ "$fmt" = "jpeg" ]; then
	# Buffered: a snapshot is one small response, so the status can still be
	# inspected and reported properly.
	body="$(mktemp /tmp/rhd-preview.XXXXXX)" || send_error "500 Internal Server Error" "no_tmp"
	trap 'rm -f "$body"' EXIT INT TERM

	# Bounded: handle_snapshot gives up after 2s of its own, so anything past
	# 10 means rhd is wedged rather than waiting, and an <img> that never
	# completes is worse than one that fails.
	code="$(curl "$@" --max-time 10 -o "$body" -w '%{http_code}' "$base/snap?stream=$stream" 2>/dev/null)" ||
		send_error "502 Bad Gateway" "backend_unreachable"

	if [ "$code" != "200" ]; then
		# 503 here is rhd's "No snapshot available yet" -- the JPEG encoder
		# was woken but produced no frame within its 2s budget.
		send_error "503 Service Unavailable" "no_snapshot"
	fi

	# Content-Length exactly, because NVRs pulling the ONVIF snapurl reject a
	# truncated or chunked JPEG.
	printf 'Status: 200 OK\r\n'
	printf 'Content-Type: image/jpeg\r\n'
	printf 'Content-Length: %s\r\n' "$(wc -c <"$body" | tr -d ' \t\n')"
	[ "$attach" = "1" ] &&
		printf 'Content-Disposition: attachment; filename=ch%s-%s.jpg\r\n' \
			"$stream" "$(date +%s)"
	printf 'Cache-Control: no-store\r\n\r\n'
	cat "$body"
	exit 0
fi

# MJPEG is unbounded, so headers go out first and the body is streamed.
# The boundary is RHD_MJPEG_BOUNDARY (rhd.h:35), a compile-time constant, which
# is why it can be named here instead of read back from the response.
printf 'Status: 200 OK\r\n'
printf 'Content-Type: multipart/x-mixed-replace;boundary=raptorframe\r\n'
printf 'Cache-Control: no-store\r\n'
printf 'Connection: close\r\n\r\n'

exec curl "$@" -N "$base/mjpeg?stream=$stream" 2>/dev/null
