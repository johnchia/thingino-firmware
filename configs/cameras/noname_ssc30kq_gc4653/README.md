# noname SSC30KQ / GC4653 — web UI status

What works, what does not, and why — so the gaps are not rediscovered as bugs.

## Working

Login and session auth, WebRTC live preview, snapshots and MJPEG (`/snap`,
`/mjpeg` on rhd, and the `/x/ch*.jpg|mjpg` proxies below), the agent-backed
control bar, and the settings the agent's raptor adapter maps.

## Not working: the streamer settings pages

These eight pages render with every field blank and every control inert:

| Page | Page |
| --- | --- |
| `streamer-main.html` | `streamer-substream.html` |
| `streamer-image.html` | `streamer-sensor.html` |
| `streamer-osd0.html` | `streamer-osd1.html` |
| `config-audio.html` | `config-photosensing.html` |

They fetch `/x/json-prudynt.cgi`, which shells out to `prudyntctl`. That binary
belongs to the prudynt streamer and is not on a raptor image, so the fetch
returns an empty body, the JSON parse throws, and the fields keep their empty
initial values. Nothing in `a/navigation.js` gates the menu on the streamer, so
the pages are reachable and look broken rather than absent.

**This is not a SigmaStar problem.** It is the same on any raptor board,
including Ingenic ones. The backend is not the obstacle either — the agent's
raptor adapter already implements image settings both ways (`brightness`,
`contrast`, `saturation`, `sharpness`, `anti_flicker`, `hflip`, `vflip`; see
`thingino-agent-adapter-raptor` around the `print_setting_leaf` cases). Only the
pages are still prudynt-shaped.

**Waiting on upstream, deliberately.** PR #1356 (`pr/webui-agent-pages-finish`,
"consolidate agent-backed streamer pages") rewrites exactly these eight pages
plus a new `a/streamer-agent.js` to hydrate and save through the agent, and
hides controls raptor does not map. Writing a parallel version here would be
throwaway work that then has to be untangled from #1356 at merge time. Its
predecessor #1341 was closed in favour of it; #1339 (control-bar routing through
the agent) merged 2026-07-27.

Re-check before doing anything local:

```
gh pr view 1356 --repo themactep/thingino-firmware --json state,mergedAt
```

## `/x/ch*.jpg` and `/x/ch*.mjpg` — replaced locally

`thingino-webui` ships these six CGIs (`ch0/ch1.jpg`, `ch0/ch1.mjpg`,
`dl0/dl1.jpg`) and every one of them shells out to `prudyntctl`, for the same
reason as above. They are what `a/preview.js:715` points every in-page `<img>`
preview at, and what the snapshot download buttons (`a/main.js:1819,1844`) and
the ONVIF `snapurl` (`/var/www/onvif/image.cgi`, symlinked to `ch0.jpg` by
`thingino-onvif`) use.

Unlike the settings pages, this one is **not** coming from upstream: #1356 lists
"live MJPEG/JPEG CGI rewrite (`ch*.jpg|mjpg`, `video.mjpg`)" under *Still
deferred*. So `overlay/var/www/x/rhd-preview.cgi` replaces them here, proxying to
rhd over loopback. It follows the pattern `timps` already uses for the same
problem (`package/timps/files/www/x/ch0.jpg`): one script installed under every
name the UI hardcodes, with channel and disposition derived from the name.

Retire it if that deferred item ever lands.

### Stream 1 JPEG — root cause found, fix pinned, awaiting a board test

Snapshots on stream 1 produced nothing by any route: `/snap?stream=1` returned
503 and a 25-second MJPEG hold returned zero bytes, while stream 0 worked and
both H.264 streams delivered video normally. The `ch1` proxies failed only by
relaying that faithfully — never a web-layer fault.

**The cause was a VPE port that ignored the geometry it was asked for.**
`MI_VPE_SetPortMode` returns 0 for a size it does not apply: a port configured
while the VPE channel is already running keeps the *channel's input* size,
because the scaler only honours the requested output once the port has a crop
in the input domain. rvd's own ports get one by being configured before the
channel starts; a snapshot port cloned afterwards does not.

So port 3 emitted 2560x1440 into a VENC channel built for 640x360 and the
encoder produced nothing, while every call in its setup reported success.

**Stream 0 was never correct either.** Port 2 was equally unconfigured and only
looked right because 2560x1440 is also the channel input size. It has worked by
coincidence since raptor-hal `7a23962`, so the fix makes the working path
correct rather than merely restoring parity.

raptor-hal `4360674`, pinned here, sets the crop and then reads the mode back,
failing the clone rather than trusting the return code. A failed clone falls
back to sharing the paired video stream's port (`86e7cb4`), which carries the
right geometry by construction — so that earlier pin is the safety net for
exactly this, and both earn their place.

The acceptance test is the geometry, not the picture:

```
cat /proc/mi_modules/mi_vpe/mi_vpe0
```

Under **Outputport Info**, port 2 should read 2560x1440 and port 3 **640x360**.
Snapshots working while port 3 still reads 2560x1440 would mean something else
is going on.

Ruled out along the way, so it is not re-investigated: the port budget (all four
ports bind and both JPEG channels attach), the `5 -> 1` framebase ratio, and the
VPE pass (port 3 finished 71 frames at 0.99 fps the whole time).

Full history in `~/raptor/STREAM1-JPEG-NOT-A-PORT-BUDGET.md`.

### Known: the first snapshot after an idle period can 503

`/snap` is served inline from rhd's epoll dispatch, so the two-second wait
blocks the whole event loop and a queued second request measures the sum of
both. Raising the timeout would therefore make one cold snapshot stall every
other client — the fix is to park the request on the epoll loop and complete it
when the ring publishes, which is a change to rhd's request model and is not
done. Affects stream 0 as well: a first preview load may show a broken image
that a reload fixes.
