#!/bin/bash
#
# check-target-libs.sh <target-dir>
#
# Confirm every DT_NEEDED of every ELF in the target resolves to a library that
# is actually in the target. Exits non-zero and names the offenders if not.
#
# This catches a failure mode that the build cannot: a package links against a
# library that exists in the toolchain sysroot but is never shipped. Buildroot's
# toolchain-external copies only a fixed set of runtime libraries into the target
# (libc, libm, libgcc_s, libstdc++ ...), never the extra libraries a vendor
# sysroot happens to bundle. The OpenIPC ARM toolchain bundles libcurl, libevent,
# libjson-c, libmbed*, libogg, libopus, libyaml and libz, so on this fork the
# hazard is live rather than theoretical.
#
# The build stays green in that case. The binary fails at exec time, with the
# loader error going wherever the init script's stdout went -- which is usually
# nowhere. Two real instances on this port:
#
#   uhttpd  needed libjson-c.so.5, because the toolchain's json-c shadowed
#           thingino-jct's libjson-c.so -> libjct.so.1.0.0 symlink in staging.
#           S60uhttpd reported only "FAIL": it checks pgrep and netstat, so a
#           binary that cannot resolve its DT_NEEDED looks exactly like one that
#           started and refused to listen.
#   curl    needed libz.so.1, with no target zlib selected at all. telegrambot
#           inherited it through libcurl.
#
# Intended for CI (plan phase 6) as well as by hand. Takes seconds.
#
# Usage:
#   scripts/check-target-libs.sh output/<board>/<config>/target

set -u

TARGET="${1:-}"
if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
	echo "usage: $0 <target-dir>" >&2
	exit 2
fi

READELF="${READELF:-readelf}"
command -v "$READELF" >/dev/null 2>&1 || {
	echo "$0: no readelf in PATH (set READELF=)" >&2
	exit 2
}

LIBDIRS="$TARGET/lib $TARGET/usr/lib"
SEARCH="$TARGET/bin $TARGET/sbin $TARGET/usr/bin $TARGET/usr/sbin
        $TARGET/usr/lib $TARGET/lib $TARGET/usr/libexec"

rc=0
declare -A users
# Counted separately: under `set -u`, ${#users[@]} on an as-yet-unassigned
# associative array is an unbound-variable error in bash < 4.4, which made the
# success path exit 0 after printing an error -- the worst outcome for a CI gate.
missing=0

while IFS= read -r f; do
	# Cheap ELF test: avoids running readelf on every script and data file.
	[ "$(head -c4 "$f" 2>/dev/null | tr -d '\0')" = $'\x7fELF' ] || continue
	while IFS= read -r need; do
		[ -n "$need" ] || continue
		found=
		for d in $LIBDIRS; do
			[ -e "$d/$need" ] && { found=1; break; }
		done
		if [ -z "$found" ]; then
			[ -n "${users[$need]:-}" ] || missing=$((missing + 1))
			users["$need"]="${users[$need]:-} ${f#"$TARGET"}"
		fi
	done < <("$READELF" -d "$f" 2>/dev/null | sed -rn 's/.*\(NEEDED\).*\[(.*)\]/\1/p')
done < <(find $SEARCH -type f 2>/dev/null)

if [ "$missing" -eq 0 ]; then
	echo "check-target-libs: OK -- every DT_NEEDED resolves inside the target"
else
	for lib in "${!users[@]}"; do
		echo "check-target-libs: MISSING $lib"
		for u in ${users[$lib]}; do
			echo "    needed by $u"
		done
		rc=1
	done
	echo
	echo "Fix by either building the library for the target (and adding it to"
	echo "sigmastar-toolchain-prune so the toolchain's copy stops shadowing it),"
	echo "or naming it in BR2_TOOLCHAIN_EXTRA_LIBS so it is copied to the target."
fi

exit $rc
