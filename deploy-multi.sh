#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Optional helper — deploy this panel to several locations
#  in one command. NOT required: the dashboard flow works
#  without any terminal usage (see README).
#
#  Locations: sweden, germany, usa, singapore
#  (Railway has no dedicated Sweden/Germany region — both use
#   EU West / Amsterdam, the closest region. Each service
#   still gets its own independent domain.)
#
#  Prereqs:
#    railway CLI   ->  npm i -g @railway/cli   (or railway.com/install.sh)
#    logged in     ->  railway login
#    a project     ->  export RAILWAY_PROJECT_ID=...   (or railway init)
#
#  Usage:
#    ./deploy-multi.sh
#    LOCATIONS="usa|us-west2,singapore|asia-southeast1-eqsg3a" ./deploy-multi.sh
#    PREFIX=vpn ./deploy-multi.sh
#
#  Note: the CLI cannot choose a region. After the first
#  deploy, set each service's region once from the dashboard
#  (Service -> Settings -> Deploy -> Region) using the list
#  printed below. TCP proxy domains come from railway.toml.
# ============================================================

PROJECT_ID="${RAILWAY_PROJECT_ID:-}"
# friendly-name|region-id  (region id is only a hint for the dashboard step)
LOCATIONS="${LOCATIONS:-sweden|europe-west4-drams3a,germany|europe-west4-drams3a,usa|us-west2,singapore|asia-southeast1-eqsg3a}"
PREFIX="${PREFIX:-panel}"
ENV_NAME="${ENV_NAME:-production}"

if ! command -v railway >/dev/null 2>&1; then
  echo "[!] railway CLI not found. Install: npm i -g @railway/cli" >&2
  exit 1
fi

if [ -z "${PROJECT_ID}" ]; then
  echo "[!] Set RAILWAY_PROJECT_ID first (or run: railway init)." >&2
  exit 1
fi

echo "==> linking project ${PROJECT_ID} / ${ENV_NAME}"
railway link --project "${PROJECT_ID}" --environment "${ENV_NAME}"

IFS=',' read -r -a items <<< "${LOCATIONS}"
for item in "${items[@]}"; do
  name="${item%%|*}"
  region="${item##*|}"
  svc="${PREFIX}-${name}"
  echo ""
  echo "==> [${name}] (region hint: ${region}) service: ${svc}"

  if railway service list --json 2>/dev/null \
       | grep -qE "\"name\"[[:space:]]*:[[:space:]]*\"${svc}\""; then
    echo "    service exists -> update LOCATION var"
    railway variable set "LOCATION=${name}" --service "${svc}" || true
  else
    echo "    creating service..."
    railway add --service "${svc}" --variables "LOCATION=${name}" --json >/dev/null || {
      echo "[!] could not create ${svc} (already exists?)" >&2
      continue
    }
  fi

  echo "    deploying (detached)..."
  railway up --service "${svc}" --environment "${ENV_NAME}" --detach || {
    echo "[!] deploy failed for ${name}" >&2
    continue
  }
done

echo ""
echo "Done. Set region per service in the dashboard, then read the 'panel:' line:"
for item in "${items[@]}"; do
  name="${item%%|*}"
  region="${item##*|}"
  echo "  - ${PREFIX}-${name}  (${region})  ->  railway logs --service ${PREFIX}-${name} --lines 50"
done
