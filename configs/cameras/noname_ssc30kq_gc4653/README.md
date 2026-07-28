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
