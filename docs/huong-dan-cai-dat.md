# Cài MacPlayer (bản miễn phí)

MacPlayer là app chỉnh video cho macOS 15 trở lên, chạy hoàn toàn trên máy bạn: không tài khoản, không mạng, không gửi video đi đâu.

## Cài đặt
1. Mở file `MacPlayer-x.y.z.dmg`, kéo **MacPlayer** vào thư mục **Applications**.
2. Lần đầu mở, macOS sẽ báo không xác minh được nhà phát triển (app chưa được Apple công chứng vì việc đó cần tài khoản nhà phát triển trả phí). Cách mở:
   - Chuột phải vào MacPlayer trong Applications, chọn **Mở**, rồi bấm **Mở** lần nữa; hoặc
   - Vào **Cài đặt hệ thống → Quyền riêng tư & Bảo mật**, kéo xuống, bấm **Vẫn mở** cạnh MacPlayer; hoặc
   - Trong Terminal: `xattr -dr com.apple.quarantine /Applications/MacPlayer.app`
3. Từ lần sau mở như app bình thường.

Kiểm tra file tải về: so mã SHA-256 (`shasum -a 256 MacPlayer-x.y.z.dmg`) với dòng tương ứng trong `SHA256SUMS.txt` đi kèm.

## An toàn cho video của bạn
- MacPlayer **không bao giờ sửa, ghi đè hay thay thế** video/ảnh gốc: mọi lần xuất là file mới, ghi ra file tạm rồi kiểm tra trước khi đặt vào chỗ.
- Nếu app bị tắt giữa chừng, lần mở sau sẽ khôi phục danh sách xuất và không để lại file dở.

## Đã kiểm thử và chưa kiểm thử
Xem `docs/bao-cao-ban-giao.md` và `docs/kiem-thu-video-that.md`. Chỉ kiểm thử trên chip Apple Silicon; bản Intel chưa chạy thử.

Giấy phép: MIT (file `LICENSE`).
