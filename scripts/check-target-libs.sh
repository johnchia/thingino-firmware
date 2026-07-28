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

# ── Second pass: per-package copies that disagree ────────────────────────────
#
# A library can be present and still be the WRONG BUILD. Under per-package
# directories each package gets a private target/ seeded from its dependencies
# at its own build time, and target-finalize rsyncs them all into the real
# target. So after a library is rebuilt, any package whose private dir was
# populated earlier still holds the old copy -- and if it sorts later in the
# rsync, it silently overwrites the new one.
#
# The build is green, the build directory holds a correct library, and the image
# holds a stale one. It surfaces as a runtime "undefined symbol" for something
# the library visibly provides. Twice here: libjson-c, and libmbedtls rebuilt
# with MBEDTLS_SSL_DTLS_SRTP, where rwd died on
# mbedtls_ssl_conf_dtls_srtp_protection_profiles.
#
# Compare the per-package copies against EACH OTHER, not against the installed
# file: target libraries are stripped at finalize, so they never match byte for
# byte and comparing to them reports every library in the tree. Disagreement
# between two private copies is the real signal -- it means the rsync had a
# choice to make.
PPD="$(dirname "$TARGET")/per-package"
if [ -d "$PPD" ]; then
	# One traversal of the whole per-package tree, then group by relative path.
	# Doing a find per library instead is O(libs x tree) and takes minutes.
	report="$(
		find "$PPD" -type f \( -path '*/target/lib/*.so*' \
			-o -path '*/target/usr/lib/*.so*' \) -print0 2>/dev/null |
		xargs -0 -r md5sum 2>/dev/null |
		awk -v ppd="$PPD/" '
			{
				sum = $1
				path = $0
				sub(/^[^ ]+  /, "", path)
				rest = substr(path, length(ppd) + 1)
				slash = index(rest, "/")
				pkg = substr(rest, 1, slash - 1)
				rel = rest
				sub(/^[^\/]+\/target\//, "", rel)
				key = rel
				if (!(key in seen)) { order[++n] = key }
				seen[key] = 1
				sums[key, sum] = 1
				if (!((key SUBSEP sum) in listed)) {
					listed[key SUBSEP sum] = 1
					distinct[key]++
				}
				pkgs[key, sum] = pkgs[key, sum] " " pkg
			}
			END {
				for (i = 1; i <= n; i++) {
					k = order[i]
					if (distinct[k] < 2) continue
					printf "check-target-libs: DISAGREEMENT %s\n", k
					for (c in sums) {
						split(c, a, SUBSEP)
						if (a[1] != k) continue
						printf "    %s %s\n", substr(a[2], 1, 8), pkgs[k, a[2]]
					}
				}
			}'
	)"
	if [ -n "$report" ]; then
		printf '%s\n' "$report"
		echo
		echo "Those packages hold different builds of the same library. Whichever"
		echo "sorts last in the finalize rsync wins, which may not be the newest."
		echo "Dirclean the ones carrying the old build: make CAMERA=<cam> br-<pkg>-dirclean"
		rc=1
	else
		echo "check-target-libs: OK -- per-package library copies all agree"
	fi
fi

exit $rc
