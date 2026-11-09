# MacPlayer: đo hiệu năng (mục 16 của thiết kế)

Chạy bằng `macplayer-probe bench` (bản release), 2026-11-05 17:23. Mọi con số dưới đây được đo trong lần chạy này, không ước lượng.

## Máy đo

- Máy: Mac16,10, chip Apple M4, 10 nhân, RAM 16 GB
- macOS 27.0.1 (26A434), ổ đo: ổ hệ thống
- Mẫu: video **tổng hợp** do MacPlayer tự sinh (hình đơn giản, bitrate cố định). Hình tổng hợp dễ mã hóa hơn cảnh quay thật, nên tốc độ xuất ở đây có thể **cao hơn** thực tế với video camera, còn bitrate thấp hơn thực tế sẽ làm giải mã nhẹ hơn. Cần đo lại với mẫu thật trước khi hứa con số nào.
- Bộ nhớ đệm của ổ đĩa đã nóng (file vừa tạo); không có quyền root để xóa cache, nên “mở lần đầu” là lần mở lần đầu của tiến trình, không phải lần đầu của ổ.

## 1. Mở nguồn: thời gian tới khung hình đầu

Mục tiêu (mục 16): khung hình đầu trong 2 giây ở ít nhất 95% lượt. Mỗi mẫu mở 20 lần (đối tượng mới mỗi lần), đo từ lúc tạo player tới lúc lấy được khung hình đầu; cột “đọc thông tin” là thời gian `MediaProbe` (phần ứng dụng làm song song để hiện thông tin).

| Mẫu | Trung vị | p95 | Chậm nhất | Đọc thông tin (trung vị) | Có hình | p95 < 2 s |
|---|---|---|---|---|---|---|
| 1080p30-h264 | 11 ms | 137 ms | 137 ms | 1 ms | 20/20 | Đạt |
| 1080p30-hevc | 13 ms | 17 ms | 17 ms | 4 ms | 20/20 | Đạt |
| 4k60-hevc | 16 ms | 17 ms | 17 ms | 3 ms | 20/20 | Đạt |
| 4k60-h264 | 18 ms | 23 ms | 23 ms | 1 ms | 20/20 | Đạt |

## 2. Tua: từ lúc ra lệnh tới lúc có đúng khung hình

30 lần tua ngẫu nhiên (cùng một hạt giống cho mọi mẫu). “Chính xác” = tua tới đúng khung hình (dung sai 0); “Thô” = chấp nhận khung gần nhất (cách thanh trượt phát hiện khi kéo). Cột “sai khung” đếm lần hình trả về lệch quá một khung so với đích (chỉ áp dụng cho tua chính xác).

| Mẫu | Kiểu tua | Trung vị | p95 | Chậm nhất | Sai khung | Không ra hình (4 s) |
|---|---|---|---|---|---|---|
| 1080p30-h264 | Chính xác | 11 ms | 25 ms | 26 ms | 0/30 | 0 |
| 1080p30-h264 | Thô | 4 ms | 5 ms | 5 ms | — | 0 |
| 1080p30-hevc | Chính xác | 10 ms | 23 ms | 25 ms | 0/30 | 0 |
| 1080p30-hevc | Thô | 3 ms | 3 ms | 3 ms | — | 0 |
| 4k60-hevc | Chính xác | 91 ms | 157 ms | 157 ms | 0/30 | 0 |
| 4k60-hevc | Thô | 6 ms | 8 ms | 10 ms | — | 0 |
| 4k60-h264 | Chính xác | 97 ms | 172 ms | 173 ms | 0/30 | 0 |
| 4k60-h264 | Thô | 10 ms | 13 ms | 13 ms | — | 0 |

## 3. Phát liên tục: khung hình bị rơi

Phát 10 giây ở tốc độ 1× (và 2× cho 1080p). Một vòng lặp 1 ms lấy khung hình mà player có sẵn cho thời điểm hiện tại, giống cách màn hình lấy. Một khung “rơi” là khung có trong file mà không bao giờ được giao. Không có cửa sổ thật, nên đây là khả năng giải mã/giao hình, không gồm vẽ lên màn hình.

| Mẫu | Tốc độ | Giao / có trong file | Rơi | Khoảng cách lâu nhất giữa 2 khung | Tốc độ phát thực |
|---|---|---|---|---|---|
| 1080p30-h264 | 1× | 297 / 297 | 0 (0.00%) | 35 ms | 0.99× |
| 1080p30-h264 | 2× | 596 / 596 | 0 (0.00%) | 27 ms | 1.99× |
| 1080p30-hevc | 1× | 297 / 297 | 0 (0.00%) | 35 ms | 0.99× |
| 4k60-hevc | 1× | 587 / 587 | 0 (0.00%) | 25 ms | 0.98× |
| 4k60-h264 | 1× | 592 / 592 | 0 (0.00%) | 25 ms | 0.99× |

## 4. Tốc độ xuất và độ đúng của kết quả

Mỗi dòng cắt một đoạn 8 giây, rồi **đọc lại file kết quả**: đếm khung (phải đủ và liên tục) và đo lệch âm thanh–hình tại các mốc bíp. “Nhanh” = không mã hóa lại. “Hệ số” = giây video / giây thực. Không có hệ số chung: số này chỉ đúng cho máy và mẫu ở trên.

| Mẫu | Kiểu | Thời gian | Hệ số | Kích thước | Số khung | Lệch âm–hình tệ nhất |
|---|---|---|---|---|---|---|
| 1080p30-h264 | Nhanh | 0.04 s | 205.9× | 8.9 MB | 240/240 (từ 75, liên tục) | không áp dụng (giữ nguyên khung đầu trước điểm cắt) |
| 1080p30-h264 | Chính xác, giữ cỡ | 1.12 s | 7.1× | 4.7 MB | 240/240 đúng | 0.7 ms (khung = 33.3 ms) Đạt |
| 4k60-hevc | Nhanh | 0.04 s | 199.7× | 34.1 MB | 480/480 (từ 150, liên tục) | không áp dụng (giữ nguyên khung đầu trước điểm cắt) |
| 4k60-hevc | Chính xác, giữ cỡ | 8.37 s | 1.0× | 27.8 MB | 480/480 đúng | 0.3 ms (khung = 16.7 ms) Đạt |
| 4k60-h264 | Nhanh | 0.05 s | 173.0× | 43.7 MB | 480/480 (từ 150, liên tục) | không áp dụng (giữ nguyên khung đầu trước điểm cắt) |
| 4k60-h264 | Chính xác, giữ cỡ | 7.97 s | 1.0× | 42.5 MB | 480/480 đúng | 0.3 ms (khung = 16.7 ms) Đạt |
| 1080p30-h264 | Chính xác, HEVC | 1.18 s | 6.8× | 2.9 MB | 240/240 đúng | 0.7 ms (khung = 33.3 ms) Đạt |
| 1080p30-h264 | Chính xác + chỉnh màu | 1.16 s | 6.9× | 5.3 MB | 240/240 đúng | 17.3 ms (khung = 33.3 ms) Đạt |
| 4k60-hevc | Chính xác, 4K→1080p | 2.24 s | 3.6× | 12.1 MB | 480/480 (không đọc được mã vạch) | — |
| 4k60-hevc | Chính xác + chỉnh màu | 8.53 s | 0.9× | 32.4 MB | 480/480 đúng | 8.7 ms (khung = 16.7 ms) Đạt |

## 5. Hủy xuất

Mục tiêu: dừng worker và giải phóng tài nguyên trong 5 giây. Đo từ lúc gọi hủy (sau 1 giây xuất) tới lúc lệnh xuất trả về, rồi kiểm tra không còn file dở. 5 lần cho mỗi mẫu.

| Mẫu | Hủy giữa chừng | Trung vị | Chậm nhất | File dở sau hủy | < 5 s |
|---|---|---|---|---|---|
| 1080p30-h264 | 5/5 | 45 ms | 48 ms | không | Đạt |
| 4k60-hevc | 5/5 | 161 ms | 164 ms | không | Đạt |

## 6. Video dài (10 phút, 1080p30)

| Phép đo | Kết quả | Ghi chú |
|---|---|---|
| Đọc thông tin | 3 ms | thời lượng 600.0 s |
| Khung hình đầu | 17 ms | có hình |
| Dạng sóng toàn bộ | 97 ms | 1600 cột, đỉnh lớn nhất 1.0 |
| Tua chính xác tới 300 s | 6 ms | đúng khung |
| Tua chính xác tới 598 s | 4 ms | đúng khung |
| Tua chính xác tới 1 s | 14 ms | đúng khung |
| Cắt 8 s gần cuối (nhanh) | 267 ms | 240 khung (giữ khung trước điểm cắt) |
| Cắt 8 s gần cuối (chính xác) | 1453 ms | 240/240 khung đúng |
| Xuất cả video, nhanh | 0.3 s | 1988× thời gian thực, 428.0 MB |
| Bộ nhớ của tiến trình | đỉnh 103 MB (lúc bắt đầu 103 MB) | đo mỗi 50 ms suốt phần video dài, gồm cả cắt và xuất |

## 7. HDR

Mẫu HDR ở đây **chỉ mang cờ HDR** (HEVC 10-bit, màu BT.2020, truyền HLG hoặc PQ), hình vẫn là hình thử nghiệm đơn giản; chưa có video HDR thật từ camera/iPhone (Dolby Vision cũng chưa thử). Phần này kiểm tra ứng dụng có **nhận ra** HDR, **cảnh báo** đúng, và file xuất ra mang nhãn màu gì; nó không đánh giá màu có đẹp hay không.

| Mẫu | Giai đoạn | Codec / độ sâu / truyền / màu | Nhận định | Ghi chú |
|---|---|---|---|---|
| hdr-hlg | nguồn | hvc1 10-bit ITU_R_2100_HLG / ITU_R_2020 | nhận ra HDR | xuất chính xác: báo “giữ HDR”; cắt nhanh: không báo |
| hdr-hlg | kết quả cắt nhanh | hvc1 10-bit ITU_R_2100_HLG / ITU_R_2020 | vẫn là HDR 10-bit | 0.9 MB |
| hdr-hlg | kết quả chính xác | hvc1 10-bit ITU_R_2100_HLG / ITU_R_2020 | vẫn là HDR 10-bit | 0.4 MB |
| hdr-pq | nguồn | hvc1 10-bit SMPTE_ST_2084_PQ / ITU_R_2020 | nhận ra HDR | xuất chính xác: báo “giữ HDR”; cắt nhanh: không báo |
| hdr-pq | kết quả cắt nhanh | hvc1 10-bit SMPTE_ST_2084_PQ / ITU_R_2020 | vẫn là HDR 10-bit | 0.4 MB |
| hdr-pq | kết quả chính xác | hvc1 10-bit SMPTE_ST_2084_PQ / ITU_R_2020 | vẫn là HDR 10-bit | 0.3 MB |
| hdr-hlg | kết quả chính xác, chọn H.264 | hvc1 10-bit ITU_R_2100_HLG / ITU_R_2020 | vẫn là HDR 10-bit | 0.4 MB |
| hdr-hlg | kết quả chính xác + chỉnh màu | hvc1 10-bit ITU_R_2100_HLG / ITU_R_2020 | vẫn là HDR 10-bit | 0.4 MB |

## 8. Vì sao xuất chính xác 4K/60 chỉ khoảng 1× (đã điều tra)

Đo riêng từng giai đoạn bằng một chương trình tối giản dùng đúng pipeline đọc→ghi của app (4K/60, 8 s):

| Phép đo | Kết quả |
|---|---|
| Chỉ giải mã (420v, không ghi) | ~10–11× thời gian thực |
| Giải mã + mã hóa H.264 60 Mbit/s | 1,01× |
| Giải mã + mã hóa H.264 15 Mbit/s | 1,01× |
| Giải mã + mã hóa HEVC 40 Mbit/s / 15 Mbit/s | 0,96× / 0,96× |
| Hai lượt mã hóa HEVC chạy cùng lúc | 0,48× mỗi lượt, **tổng vẫn 0,96×** |

Kết luận: nút cổ chai là **bộ mã hóa phần cứng của máy đo**, không phải giải mã, bitrate, codec hay mã của MacPlayer. Tốc độ mã hóa gần như không đổi theo số điểm ảnh mỗi giây (~440–500 triệu điểm ảnh/s: 1080p30 ≈ 7×, 4K/60 ≈ 1×, 4K→1080p ≈ 3,6× đều ứng với ~210–215 khung/s ở 1080p), và chạy song song không tăng tổng tốc độ. Hệ quả cho người dùng:

- Xuất chính xác video 4K/60 sẽ mất bằng thời lượng video (trên M4 cơ bản). Muốn nhanh hơn: dùng **cắt nhanh** (không mã hóa lại, ~170–200×), hoặc xuất ra 1080p.
- Tăng "số lượt xuất song song" **không** làm tổng thời gian ngắn đi khi các lượt đều mã hóa lại; chỉ có ích cho lượt cắt nhanh hoặc khi bộ mã hóa chưa bị chiếm hết.
- Máy có nhiều bộ mã hóa (dòng Pro/Max/Ultra) có thể khác; chưa đo.

