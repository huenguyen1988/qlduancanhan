# Triển khai lên CapRover

## Kiến trúc

- **Một app Docker**: nginx (cổng **80**) phục vụ Flutter web + reverse proxy `/api/*` sang Shelf backend (cổng nội bộ **8080**).
- **MongoDB**: dùng app **MongoDB** trên CapRover (hoặc dịch vụ ngoài), rồi set biến môi trường `MONGO_URI`.

## Chuẩn bị

1. Trong CapRover tạo app **MongoDB** (hoặc lấy URI sẵn có).
2. Tạo app mới kiểu **Dockerfile** (hoặc deploy từ Git với `captain-definition` ở root repo).

## Biến môi trường (App Configs)

| Biến | Mô tả |
|------|--------|
| `MONGO_URI` | Bắt buộc. Ví dụ: `mongodb://srv-captain--ten-mongo:27017/duan1` (tên host đúng theo app Mongo trên CapRover). |
| `BACKEND_PORT` | Tuỳ chọn. Mặc định `8080` (cổng nội bộ của API, không đổi trừ khi bạn sửa `start.sh` / nginx). |

**Không** cần set `PORT` cho backend: script `start.sh` cố định backend qua `BACKEND_PORT`.

## Cổng HTTP

- Dockerfile **EXPOSE 80** → trong CapRover để app listen **80** (mặc định thường đúng).

## Deploy

- **Git**: push repo, trong CapRover bật deploy từ branch, đảm bảo root có `Dockerfile` + `captain-definition`.
- **CLI**: `caprover deploy` (theo hướng dẫn CapRover).

## Flutter web gọi API

Trên web, `apiBaseUrl` = **cùng origin** với trang (ví dụ `https://ten-app.captain.domain`), request tới `/api/...` qua nginx tới backend.

## Gỡ lỗi

- **502 / không vào được API**: kiểm tra `MONGO_URI`, log container (`duan1-server` có kết nối Mongo không).
- **Trắng trang**: mở console trình duyệt, kiểm tra `index.html` và đường dẫn assets.
