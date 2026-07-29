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

### Stream 1 JPEG — fix pinned, awaiting a board test

`/x/ch0.jpg` and `/x/ch0.mjpg` are verified working on hardware. Stream 1 was
not: `/snap?stream=1` failed on rhd directly, so the `ch1` proxies failed only
by relaying it faithfully. The fault was never in the web layer.

The cause was a port budget. This board runs two video streams with `jpeg =
true` on both, so it wants four VPE ports, and `STAR_VPE_PORT_NUM` is 4. The
first snapshot fix (raptor-hal `7a23962`) gave every JPEG channel a port of its
own and gave up when it could not get one, which is why stream 1 had a snapshot
ring with nothing feeding it.

raptor-hal `86e7cb4`, pinned here, keeps the dedicated port as the preferred
shape but falls back to sharing the paired video stream's port when none is
free. **Not yet confirmed on hardware** — it is a predicted fix. One command
tells the three outcomes apart:

```
logread | grep -e 'bind: VPE port' -e 'snapshot channel'
```

- `snapshot channel attached on VPE port 3` — a fourth port did exist and the
  original design was mis-sequenced; keep the log, the raptor agent wants it.
- `snapshot channel sharing chn 1's VPE port 1` — fallback took; snapshots
  should now work on both streams.
- `sharing chn 1's VPE port 1 failed too` — MI enforces one bind per source
  port. The fix then needs a different shape, and the MI error code is what
  identifies it.

If stream-1 snapshots arrive at full sensor rate instead of 1 fps, the fallback
works but MI is not honouring `dstFps` on a second bind of one source; that is
a pacing question for the raptor agent, not a failure of this proxy.
