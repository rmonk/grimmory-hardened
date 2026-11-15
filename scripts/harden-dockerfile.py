#!/usr/bin/env python3
"""Rewrite upstream grimmory's Dockerfile with the hardening changes.

Every edit is anchored on a regex and must match exactly once. If upstream
restructures its Dockerfile so an anchor no longer matches, this script exits
non-zero instead of silently producing an unhardened image.

Usage: harden-dockerfile.py <path/to/Dockerfile>   (edited in place)
"""
import re
import sys

GO_IMAGE = "golang:1.27-alpine"

KEPUBIFY_STAGE = """\
# --- grimmory-hardened: build kepubify from source with a current Go toolchain ---
# Upstream downloads a 2022 release binary built with go1.17.8 (hundreds of stdlib CVEs).
FROM --platform=$BUILDPLATFORM {go_image} AS kepubify-layer

ARG TARGETARCH
ARG KEPUBIFY_VERSION="{version}"

WORKDIR /src
RUN set -eux; \\
    apk add --no-cache git; \\
    git clone --depth 1 --branch "v${{KEPUBIFY_VERSION}}" https://github.com/pgaskin/kepubify.git .; \\
    go get golang.org/x/text@latest golang.org/x/sync@latest; \\
    CGO_ENABLED=0 GOOS=linux GOARCH="$TARGETARCH" go build -trimpath \\
        -ldflags "-s -w -X main.version=v${{KEPUBIFY_VERSION}}" -o /kepubify ./cmd/kepubify; \\
    go version -m /kepubify | head -n 20
"""


def sub_once(text, pattern, repl, what, flags=re.M):
    new, n = re.subn(pattern, repl, text, count=0, flags=flags)
    if n != 1:
        sys.exit(f"harden-dockerfile: anchor for '{what}' matched {n} times (expected 1); "
                 "upstream Dockerfile changed, update scripts/harden-dockerfile.py")
    return new


def main(path):
    with open(path) as f:
        text = f.read()

    # 1. kepubify: replace the prebuilt-binary scratch stages with a source build.
    m = re.search(r'^ARG KEPUBIFY_VERSION="([^"]+)"', text, re.M)
    if not m:
        sys.exit("harden-dockerfile: could not find ARG KEPUBIFY_VERSION")
    version = m.group(1)
    stage = KEPUBIFY_STAGE.format(go_image=GO_IMAGE, version=version)
    text = sub_once(
        text,
        r'^FROM scratch AS kepubify-layer-amd64\n.*?^FROM kepubify-layer-\$\{TARGETARCH\} AS kepubify-layer\n',
        lambda _: stage,
        "kepubify stages",
        flags=re.M | re.S,
    )

    # 2. Gradle: apply the security-floor init script and rewrite the lockfile.
    #    --write-locks is needed on both runs because `COPY backend/ ./` restores
    #    upstream's gradle.lockfile between them.
    init = "--init-script /workspace/hardening/security-overrides.init.gradle.kts"
    text = sub_once(
        text,
        r'^(COPY backend/gradlew [^\n]*\n)',
        r'\1COPY hardening/security-overrides.init.gradle.kts /workspace/hardening/\n',
        "copy init script",
    )
    text = sub_once(
        text,
        r'\./gradlew --no-daemon dependencies\b',
        f"./gradlew --no-daemon {init} dependencies --write-locks",
        "gradle dependencies",
    )
    text = sub_once(
        text,
        r'\./gradlew --no-daemon (-PfrontendDistDir=\S+) bootJar\b',
        rf"./gradlew --no-daemon {init} \1 bootJar --write-locks",
        "gradle bootJar",
    )

    # 3. Runtime stage: pull in current Alpine security fixes.
    text = sub_once(
        text,
        r'^RUN apk add --no-cache (su-exec\b)',
        r'RUN apk upgrade --no-cache && \\\n    apk add --no-cache \1',
        "apk add",
    )

    # 4. Labels identifying the hardened build (later LABELs override earlier ones).
    text = sub_once(
        text,
        r'^(EXPOSE \d+)',
        'ARG HARDENED_VERSION=unknown\n'
        'ARG HARDENED_SOURCE=unknown\n'
        'LABEL org.opencontainers.image.version=$HARDENED_VERSION \\\n'
        '    org.grimmory-hardened.source=$HARDENED_SOURCE \\\n'
        '    org.grimmory-hardened.upstream-version=$APP_VERSION\n\n'
        r'\1',
        "labels",
    )

    with open(path, "w") as f:
        f.write(text)
    print(f"harden-dockerfile: patched {path} (kepubify v{version}, {GO_IMAGE})")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
