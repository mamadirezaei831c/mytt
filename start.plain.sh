#!/bin/bash
set -euo pipefail

#  Master source — edit here, then regenerate start.sh:
#    base64 -w0 start.plain.sh
#  (start.sh is the obfuscated copy; do not push this file:
#   it is listed in .gitignore)

# --- port (fixed) -----------------------------------------
WEB_PORT="${WEB_PORT:-2053}"                          # public web port (nginx)
XUI_INTERNAL_PORT="${XUI_INTERNAL_PORT:-2080}"        # panel port inside (behind nginx)

# --- location ---------------------------------------------
LOCATION="${LOCATION:-${RAILWAY_REPLICA_REGION:-${RAILWAY_SERVICE_NAME:-unknown}}}"

# --- stealth panel path ------------------------------------
if [ -z "${WEB_PATH+x}" ]; then
  WEB_PATH="$(head -c6 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c8)"
  [ -n "${WEB_PATH}" ] || WEB_PATH="panel"
fi
WEB_PATH="${WEB_PATH#/}"
WEB_PATH="${WEB_PATH%/}"

if [ -n "${WEB_PATH}" ]; then
  WEB_BASE="/${WEB_PATH}"
  URL_PATH="/${WEB_PATH}"
else
  WEB_BASE="/"
  URL_PATH=""
fi

# --- decoy process name ------------------------------------
APP_NAME="${APP_NAME:-webapp}"

CONFIG_DIR="${CONFIG_DIR:-/etc/x-ui}"
mkdir -p "${CONFIG_DIR}"

# --- print & save panel info -------------------------------
PANEL_URL=""
PROXY_ADDR=""
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  PANEL_URL="https://${RAILWAY_PUBLIC_DOMAIN}${URL_PATH}"
fi
if [ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ]; then
  PROXY_ADDR="${RAILWAY_TCP_PROXY_DOMAIN}:${RAILWAY_TCP_PROXY_PORT:-443}"
fi

{
  echo "=============================================="
  echo "  location : ${LOCATION}"
  echo "  login    : admin / admin"
  if [ -n "${PANEL_URL}" ]; then
    echo "  panel    : ${PANEL_URL}"
  fi
  if [ -n "${PROXY_ADDR}" ]; then
    echo "  proxy    : ${PROXY_ADDR}"
    echo "             (use THIS in your client config, not port 443)"
  fi
  echo "=============================================="
} | tee "${CONFIG_DIR}/panel-info.txt"

# --- custom UI: nginx in front of the panel ---------------
WEB_DIR="/srv/web"
HAS_UI=0
if command -v nginx >/dev/null 2>&1 && [ -d "${WEB_DIR}" ]; then
  HAS_UI=1
fi

if [ "${HAS_UI}" -eq 1 ]; then
  # expose panel/proxy addresses to the landing page
  {
    echo "window.PANEL = {"
    echo "  path: \"${WEB_BASE}\","
    echo "  url: \"${PANEL_URL}\","
    echo "  proxy: \"${PROXY_ADDR}\","
    echo "  location: \"${LOCATION}\""
    echo "};"
  } > "${WEB_DIR}/config.js"

  if [ -n "${WEB_PATH}" ]; then
    # panel on a sub-path -> custom pages at "/" (try_files -> proxy)
    cat > /etc/nginx/nginx.conf <<EOF
worker_processes 1;
pid /var/run/nginx.pid;
events { worker_connections 256; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log off;
  server {
    listen ${WEB_PORT};
    server_name _;
    root ${WEB_DIR};
    index index.html;
    location / {
      try_files \$uri \$uri/ @panel;
    }
    location @panel {
      proxy_pass http://127.0.0.1:${XUI_INTERNAL_PORT}\$request_uri;
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
    }
  }
}
EOF
  else
    # panel at "/" -> proxy everything (no custom pages)
    cat > /etc/nginx/nginx.conf <<EOF
worker_processes 1;
pid /var/run/nginx.pid;
events { worker_connections 256; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log off;
  server {
    listen ${WEB_PORT};
    server_name _;
    location / {
      proxy_pass http://127.0.0.1:${XUI_INTERNAL_PORT}\$request_uri;
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
    }
  }
}
EOF
  fi

  nginx 2>/dev/null || true
  # did nginx actually come up? (safety net: if not, panel runs on WEB_PORT directly)
  NGINX_OK=0
  if [ -f /var/run/nginx.pid ] && kill -0 "$(cat /var/run/nginx.pid 2>/dev/null)" 2>/dev/null; then
    NGINX_OK=1
  fi
fi

# --- write panel config ------------------------------------
if [ "${HAS_UI}" -eq 1 ] && [ "${NGINX_OK}" -eq 1 ]; then
  cat > "${CONFIG_DIR}/config.json" <<EOF
{
  "webPort": ${XUI_INTERNAL_PORT},
  "webBasePath": "${WEB_BASE}",
  "webListen": "127.0.0.1",
  "logLevel": "info"
}
EOF
else
  # fallback (no nginx, or nginx failed): panel directly on the public port
  cat > "${CONFIG_DIR}/config.json" <<EOF
{
  "webPort": ${WEB_PORT},
  "webBasePath": "${WEB_BASE}",
  "webListen": "0.0.0.0",
  "logLevel": "info"
}
EOF
fi

# --- run, with a neutral process name ----------------------
cd /opt/app
exec -a "${APP_NAME}" ./x-ui
