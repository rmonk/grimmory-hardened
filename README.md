# grimmory-hardened

Rebuilds upstream [grimmory](https://github.com/grimmory-tools/grimmory) release tags with security fixes
applied, gates each build on a Trivy scan and a smoke test, and publishes the result to
`ghcr.io/rmonk/grimmory`.

No fork: each build clones upstream at the tag in `UPSTREAM_VERSION` and applies a small, anchored overlay.

## What gets changed

| Area | Upstream | Hardened |
|---|---|---|
| `kepubify` | prebuilt v4.0.4 binary from 2022 (go1.17.8, old `x/text`) | same v4.0.4 source, built with current Go and latest `golang.org/x/{text,sync}` |
| Java deps | whatever the release locked | security floors from `overlay/security-overrides.init.gradle.kts` (Tomcat, Jackson 2/3, MariaDB Connector/J, org.json); only ever raise versions, only within the same major.minor |
| Alpine packages | frozen at release time | `apk upgrade` at build time, rebuilt weekly |

`scripts/harden-dockerfile.py` makes these edits to upstream's `Dockerfile`. Every edit must match its anchor exactly
once. If upstream restructures the Dockerfile, the build fails rather than shipping an unhardened image.

kepubify stays on v4 because v5 changes koboSpan numbering, which can shift Kobo reading positions.

## Tags

- `latest-hardened`: newest successful build of the current `UPSTREAM_VERSION`
- `<upstream>-hardened`, e.g. `v3.5.0-hardened`
- `<upstream>-hardened-<YYYYMMDD>`: immutable, use this to pin or roll back

## Automation

- `build.yml`: runs on push/PR, manually, and weekly (Mon 05:17 UTC). It runs prepare, then build, then the Trivy
  gate (fixable CRITICAL/HIGH fail the build; exceptions go in `.trivyignore` with a reason and review date), then
  the smoke test (MariaDB 11.8, healthcheck, kepubify conversion, ffprobe), then pushes (on main only). The Trivy
  JSON/table output is kept as a build artifact. If the `HC_PING_URL` secret is set, a successful run pings it.
- `watch-upstream.yml`: runs daily. When grimmory publishes a new release, it opens a PR that bumps
  `UPSTREAM_VERSION` and dispatches the build on that branch. Merge it when it is green.

## Local build

```bash
scripts/prepare.sh                 # or: scripts/prepare.sh v3.5.0
docker build -t grimmory:hardened \
  --build-arg APP_VERSION=$(cat UPSTREAM_VERSION) \
  --build-arg HARDENED_VERSION=$(cat UPSTREAM_VERSION)-hardened build/src
scripts/smoke-test.sh grimmory:hardened      # DOCKER=podman for podman
```

## Maintenance

- When a floor in the init script is at or below what upstream ships, it becomes a no-op. Delete it.
- If Trivy flags a new fixable library, add a floor (Java), extend the `go get` list (kepubify), or bump an image
  tag in `harden-dockerfile.py`.
- If a patch anchor breaks after an upstream release, update the regex in `harden-dockerfile.py` and check the diff
  of the generated `build/src/Dockerfile`.
