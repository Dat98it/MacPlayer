# MacPlayer 0.17.3: cài đặt và chia sẻ

**MacPlayer** (trước đây tên MacVideo) là app miễn phí cho macOS để xem và chỉnh sửa video lẫn ảnh: cắt, ghép, chỉnh màu chuyên nghiệp, tách nền và mặt nạ, chuyển cảnh, hiệu ứng giọng, chữ, hình dán, rồi xuất ngay trên Mac. Mọi thứ chạy trên máy bạn: không tài khoản, không kết nối mạng, không gửi video đi đâu, không thu thập dữ liệu.

Giấy phép MIT: dùng, sao chép và chia sẻ tự do (xem mục cuối).

## Yêu cầu
- macOS **15 trở lên**.
- Đã kiểm thử trên Mac chip Apple (M1 trở đi). **Mac Intel chưa được thử**, không cam kết chạy.

## Cài đặt
1. Tải `MacPlayer-0.17.3.dmg` (hoặc `.zip`) từ nơi người chia sẻ cho bạn.
2. Mở file `.dmg`, kéo **MacPlayer** vào thư mục **Applications**.
3. Lần đầu mở, macOS báo không xác minh được nhà phát triển. Đây là bình thường: app chưa được Apple công chứng vì việc đó cần tài khoản nhà phát triển trả phí. Chọn một cách:
   - Chuột phải vào MacPlayer trong Applications, chọn **Mở**, rồi bấm **Mở** lần nữa; hoặc
   - **Cài đặt hệ thống ▸ Quyền riêng tư & Bảo mật**, kéo xuống, bấm **Vẫn mở** cạnh MacPlayer; hoặc
   - Trong Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/MacPlayer.app
     ```
4. Từ lần sau mở như app bình thường.

### Kiểm tra file tải về (nên làm)
So mã SHA-256 của file với mã dưới đây. Khác nhau nghĩa là file đã bị đổi hoặc tải lỗi: đừng cài.

```bash
shasum -a 256 MacPlayer-0.17.3.dmg
```

```
e35f1cda37ec36ea678e1e3b87a5cca363d01b71a2bfd059b49b6c2ac612f4a6  MacPlayer-0.17.3.dmg
155461f97b83275a760bd63424556b691c3ac7dd526a58e1976681858e05ee9f  MacPlayer-0.17.3.zip
```

## Dùng nhanh
- **Mở video:** kéo file vào cửa sổ, hoặc bấm đúp / chuột phải ▸ Mở bằng ▸ MacPlayer. Thả một **thư mục** để tạo danh sách phát.
- **Cắt đoạn:** đặt điểm In và Out, rồi xuất. Bước từng khung bằng phím mũi tên.
- **Ghép nhiều video:** thêm video vào dòng thời gian, sắp xếp, xuất thành một file. Có thể đặt thêm video hoặc ảnh làm lớp phủ lên trên.
- **Chỉnh sửa:** cắt khung hình, xoay, lật, màu sắc, tốc độ, âm lượng, chữ và phụ đề.
- **Hai kiểu xuất:**
  - *Cắt nhanh*: chép nguyên dữ liệu, tức thì, không giảm chất lượng, nhưng điểm cắt phụ thuộc cấu trúc video.
  - *Chính xác*: mã hóa lại, cắt đúng từng khung và áp dụng chỉnh sửa. Video HDR vẫn xuất ra HDR 10-bit.
- **Vi/En:** giao diện tiếng Việt và tiếng Anh.

## An toàn cho video của bạn
- MacPlayer **không bao giờ sửa, ghi đè hay thay thế** video/ảnh gốc: mọi lần xuất là một **file mới**.
- Chỉnh sửa nằm trong **dự án** (file `.macplayer` bạn chọn nơi lưu), tự lưu khi làm việc. Mở app có hai khu: **Danh sách phát** (chỉ xem, đổi tên, chuyển vào Thùng rác) và **Chỉnh sửa** (danh sách dự án video và dự án ảnh).
- Nếu app hoặc máy bị tắt giữa lúc xuất, lần mở sau app khôi phục hàng đợi và không để lại file dở. Đã thử bằng cách ngắt đột ngột nhiều lần trên video thật.

## Đã kiểm thử
Chạy trên 111 video quay thật (iPhone, ghi màn hình; 1080p và 4K; SDR, HDR, Dolby Vision; có tiếng; quay dọc; tốc độ khung thay đổi) và hàng trăm kiểm tra tự động: mở, phát, tua chính xác, bước khung, cắt, ghép, xuất, lưu và mở lại dự án, thay bản gốc có sao lưu. Chi tiết: `docs/kiem-thu-video-that.md`.

## Giới hạn đã biết
- Xuất chính xác 4K 60 fps chạy khoảng 1 lần thời gian thực (giới hạn của bộ mã hóa phần cứng).
- Ghép video HDR với video SDR cho ra file SDR (app báo trước khi xuất).
- Video Dolby Vision: cắt nhanh giữ nguyên; mã hóa lại giữ ảnh HDR, còn dữ liệu Dolby Vision có thể không còn (tùy video).
- Tiếng của clip tăng tốc 2× dài hơn hình khoảng 0,1 s.
- Chưa kiểm thử: toàn màn hình, tháo ổ USB khi đang xuất, ngủ/thức máy, đổi thiết bị âm thanh, máy Intel, VoiceOver.

## Báo lỗi
Khi gặp lỗi, ghi lại: phiên bản macOS, loại video (codec, độ phân giải, quay bằng gì), các bước làm, và thông báo hiện ra. Đừng gửi video riêng tư nếu không cần.

## Chia sẻ cho người khác
- Gửi kèm **file `.dmg` và đoạn mã SHA-256** ở trên để người nhận kiểm tra.
- Gửi kèm file này để họ biết cách mở lần đầu.
- Bạn được phép đăng lại, tặng, sửa và phân phối miễn phí theo giấy phép MIT.

## Tự build từ mã nguồn
Cần Swift 6 (Command Line Tools là đủ, không cần Xcode):

```bash
Scripts/build_app.sh        # tạo build/MacPlayer.app
Scripts/make_release.sh     # tạo dist/MacPlayer-<phiên bản>.dmg, .zip và SHA256SUMS.txt
```

## Giấy phép
MIT License. Copyright (c) 2026 MacPlayer contributors. Phần mềm được cung cấp "nguyên trạng", không bảo hành. Toàn văn trong file `LICENSE`.
