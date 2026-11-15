#!/usr/bin/env bash
# Start the image with a throwaway MariaDB, wait for the app to become healthy
# (which means Flyway migrations ran), then exercise the bundled kepubify and ffprobe.
#
# Usage: scripts/smoke-test.sh <image>      (DOCKER=podman to use podman)
set -euo pipefail

image="${1:?usage: smoke-test.sh <image>}"
docker="${DOCKER:-docker}"
name="grimmory-smoke-$$"
net="$name-net"
timeout="${SMOKE_TIMEOUT:-300}"

cleanup() {
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "--- app logs (last 80 lines) ---"; $docker logs --tail 80 "$name-app" 2>&1 || true
  fi
  $docker rm -f "$name-app" "$name-db" >/dev/null 2>&1 || true
  $docker network rm "$net" >/dev/null 2>&1 || true
  exit $rc
}
trap cleanup EXIT

$docker network create "$net" >/dev/null
$docker run -d --name "$name-db" --network "$net" --network-alias mariadb \
  -e MARIADB_ROOT_PASSWORD=smoke -e MARIADB_DATABASE=grimmory \
  -e MARIADB_USER=grimmory -e MARIADB_PASSWORD=smoke \
  docker.io/library/mariadb:11.8 >/dev/null

echo "smoke: waiting for mariadb"
for _ in $(seq 60); do
  $docker exec "$name-db" mariadb-admin ping -h localhost -uroot -psmoke --silent >/dev/null 2>&1 && break
  sleep 2
done

$docker run -d --name "$name-app" --network "$net" \
  -e USER_ID=1000 -e GROUP_ID=1000 -e TZ=UTC \
  -e DATABASE_URL='jdbc:mariadb://mariadb:3306/grimmory' \
  -e DATABASE_USERNAME=grimmory -e DATABASE_PASSWORD=smoke \
  "$image" >/dev/null

echo "smoke: waiting up to ${timeout}s for /api/v1/healthcheck"
deadline=$((SECONDS + timeout))
until $docker exec "$name-app" wget -q -O - http://localhost:6060/api/v1/healthcheck >/dev/null 2>&1; do
  if [ "$($docker inspect -f '{{.State.Running}}' "$name-app")" != "true" ]; then
    echo "smoke: FAIL container exited"; exit 1
  fi
  [ $SECONDS -lt $deadline ] || { echo "smoke: FAIL healthcheck timeout"; exit 1; }
  sleep 5
done
echo "smoke: healthcheck OK after ${SECONDS}s"

echo "smoke: kepubify"
$docker exec "$name-app" kepubify --version
# Minimal EPUB 3, built on the host (the JRE image has no zip tool), converted inside the container.
work="$(mktemp -d)"
python3 -I "$(dirname "$0")/make-test-epub.py" "$work/smoke.epub"
# The output dir must already exist (as it does in KepubConversionService), otherwise
# kepubify treats -o as a file name and just copies the input.
$docker exec "$name-app" mkdir -p /tmp/smoke/out
$docker cp "$work/smoke.epub" "$name-app:/tmp/smoke/smoke.epub"
rm -rf "$work"
$docker exec "$name-app" sh -eu -c '
  kepubify -o /tmp/smoke/out /tmp/smoke/smoke.epub
  out=$(ls /tmp/smoke/out/*.kepub.epub)
  unzip -p "$out" OEBPS/c1.xhtml | grep -q "class=\"koboSpan\""
'
echo "smoke: kepubify conversion OK"

echo "smoke: ffprobe"
$docker exec "$name-app" ffprobe -version | sed -n 1p   # not head: SIGPIPE under pipefail

echo "smoke: PASS"
