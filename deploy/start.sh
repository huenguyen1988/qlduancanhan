#!/bin/sh
set -e
# Backend nội bộ cố định 8080; CapRover có thể set PORT=80 cho nginx — không dùng cho Shelf.
export PORT="${BACKEND_PORT:-8080}"
/usr/local/bin/duan1-server &
exec nginx -g "daemon off;"
