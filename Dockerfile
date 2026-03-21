# --- Flutter web ---
FROM ghcr.io/cirruslabs/flutter:stable AS flutter-build

WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .
RUN flutter build web --release --no-wasm-dry-run

# --- Dart API (binary) ---
FROM dart:stable AS dart-build

WORKDIR /server
COPY server/pubspec.yaml server/pubspec.lock ./
RUN dart pub get

COPY server/ ./
RUN dart compile exe bin/server.dart -o /server/duan1-server

# --- Runtime: nginx + API ---
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default

COPY --from=flutter-build /app/build/web /var/www/html
COPY --from=dart-build /server/duan1-server /usr/local/bin/duan1-server
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY deploy/start.sh /start.sh
RUN chmod +x /start.sh /usr/local/bin/duan1-server

EXPOSE 80

ENV BACKEND_PORT=8080
# Không cố định host MongoDB trong Dockerfile.
# Trên CapRover, bạn cần set `MONGO_URI` theo đúng tên service nội bộ của app MongoDB.
# Nếu không set, server sẽ fallback về `mongodb://localhost:27017/duan1`.

CMD ["/start.sh"]
