# Kiểm thử MacPlayer trên video thật

> Ghi chú 0.8.0: tính năng "thay bản gốc" đã được gỡ khỏi MacPlayer. Các dòng nói về "thay bản gốc" bên dưới là nhật ký kiểm thử của các bản 0.2–0.7, giữ lại để tra cứu.


Ngày 05/11/2026. Nguồn video: **Jellyfin test videos** (https://repo.jellyfin.org/test-videos/), giấy phép CC BY-SA 4.0, tải về thư mục tạm (không nằm trong repo), đã đối chiếu md5 với file `.md5sum` của nguồn:

| File dùng | Tên gốc trên nguồn | Dung lượng |
|---|---|---|
| sdr-1080-avc.mp4 | SDR/AVC/Test Jellyfin 1080p AVC 10M.mp4 | 37,6 MB |
| sdr-4k-avc.mp4 | SDR/AVC/Test Jellyfin 4K AVC 40M.mp4 | 147 MB |
| sdr-4k-hevc.mp4 | SDR/HEVC 8bit/Test Jellyfin 4K HEVC 8bit 40M.mp4 | 147 MB |
| hdr10-1080-hevc.mp4 | HDR/HDR10/HEVC/Test Jellyfin 1080p HEVC HDR10 10M.mp4 | 36,9 MB |
| hdr10-4k-hevc.mp4 | HDR/HDR10/HEVC/Test Jellyfin 4K HEVC HDR10 40M.mp4 | 147 MB |
| dv-4k-p81.mp4 | HDR/Dolby Vision/Test Jellyfin 4K DV P8.1.mp4 | 125 MB |

**Giới hạn của bộ mẫu này (đọc trước):** đây là video thật đã mã hóa (không phải do MacPlayer sinh) nhưng là *clip thử nghiệm của một dự án phần mềm*, không phải cảnh quay từ iPhone/camera. Cả 6 file đều 60 fps cố định, 30 s, **không có âm thanh, không xoay, không VFR**. Vì vậy: đồng bộ âm–hình, video xoay, VFR, và đặc thù file quay từ điện thoại **vẫn chưa được kiểm thử trên video thật**.

## Kết quả tóm tắt

- **Mở, phát, tua, xuất trên cả 6 file đều đúng**, riêng Dolby Vision có một giới hạn thật (bên dưới).
- Mọi ca xuất (21 ca): đủ 240 khung, từ thời điểm 0, đọc lại giống nguồn: cắt nhanh lệch hình **0,00**, mã hóa lại **0,15–0,37** trên thang 255. Cắt nhanh giữ hộp Dolby Vision; mã hóa lại bỏ hộp đó nhưng giữ ảnh HDR10 (10-bit, PQ/BT.2020).
- Phát 10 s: không rơi khung nào ở cả 6 file (kể cả 4K/60 HDR và Dolby Vision).
- Khung hình đầu: p95 ≤ 222 ms (mục tiêu < 2 s).
- Trong app thật (`--selftest --real-media`): mở, phát đúng tốc độ, tua đúng thời điểm khung, bước một khung tới/lui, xuất bản sao, **thay bản gốc có sao lưu** (bản sao lưu giống từng byte), lưu và mở lại dự án: đạt trên 3 file (SDR 1080p, HDR10 4K, Dolby Vision 4K).
- Mở bằng `open -a` (Launch Services) với 3 file thật: đạt. `kill -9` giữa lúc xuất file 4K HDR10 và 1080p thật: đạt (bản gốc nguyên vẹn).
- Xuất chính xác 4K/60 chỉ ~1× thời gian thực: giới hạn bộ mã hóa phần cứng (xem benchmark.md, mục 8).

## Phát hiện thật

1. **Dolby Vision: 4,9% khung không giải mã được khi nhảy thẳng tới** (88/1799; luôn là 3 khung cuối của mỗi nhóm 60 khung). Hệ thống (`AVAssetImageGenerator`: "Cannot Decode") và `AVPlayer` không đưa khung đó ra: khi tua hoặc bước tới đúng khung đó, hình **đứng yên ở khung cũ**. Đọc tuần tự (phát, xuất) vẫn đúng. Hai file HDR10/SDR HEVC cùng nguồn không bị (0 khung). Nguyên nhân chưa xác định được (nghi cấu trúc GOP hở của file thử Dolby Vision này); chưa biết video quay từ iPhone có bị không. **Chưa có cách sửa trong app**; cần thử với video Dolby Vision quay bằng iPhone trước khi kết luận mức độ ảnh hưởng.
2. **Mốc thời gian của file cắt (đường copy thẳng, và mã hóa lại không chỉnh hình) lệch nửa khung:** khung đầu nằm ở 0 nhưng chỉ hiển thị 8,3 ms, các khung sau nằm trên lưới trễ nửa khung (nội dung và số khung đúng). Đây là hệ quả của quy tắc "dời nửa khung" đã chọn cho đường này; vô hại khi xem nhưng không phải lưới thời gian sạch. Đường có chỉnh hình (compositor) thì lưới sạch (khoảng cách đầu 16,7 ms). Chưa sửa vì quy tắc này được chọn có chủ đích cho nguồn 29,97 fps và đã có test; đổi nó cần đo lại toàn bộ.
3. **Nguồn Dolby Vision nay có cảnh báo khi xuất mã hóa lại** ("giữ ảnh HDR nhưng bỏ dữ liệu Dolby Vision; cắt nhanh thì giữ nguyên"). Trước đây app không nói gì. Đã sửa, có test.
4. **Toàn màn hình chưa kiểm thử được.** macOS không cho tiến trình chạy nền tự giành quyền active, mà chuyển toàn màn hình cần app đang active (đã thử `activate`, `open`, `osascript`). Selftest in `SKIP ... Not verified`. Đã thêm `collectionBehavior = .fullScreenPrimary` cho cửa sổ (cần cho nút xanh và phím F) nhưng **cần người bấm thử tay**.

## Số liệu chi tiết (`macplayer-probe realcheck`)


Chạy bằng `macplayer-probe realcheck`. Video thật (không do MacPlayer sinh) nên **không có mã vạch**: chân lý lấy từ chính bảng khung hình và điểm ảnh đã giải mã của file. Một lần tua đúng khi khung trả về mang đúng thời điểm khung đã yêu cầu. Một lần cắt đúng khi file kết quả có đúng các khung của đoạn, liên tục, bắt đầu từ 0, và giải mã ra cùng một hình với các khung nguồn tương ứng (sai khác độ sáng trung bình, thang 0–255).

Máy: Apple M4, macOS 27.0.1. Các file thật đều **60 fps, 30 s, không có âm thanh**: phần đồng bộ âm–hình vẫn chỉ được kiểm bằng media tổng hợp.

## 1. Các file và việc nhận diện

| File | Định dạng | Khung hình | Loại | Hộp Dolby Vision | Dung lượng |
|---|---|---|---|---|---|
| dv-4k-p81.mp4 | hvc1 10-bit 3840×2160 | 60.00 fps, 1799 khung, CÓ khung thiếu/trùng | HDR (SMPTE_ST_2084_PQ) | dvvC | 119.3 MB |
| hdr10-1080-hevc.mp4 | hvc1 10-bit 1920×1080 | 60.00 fps, 1799 khung, CÓ khung thiếu/trùng | HDR (SMPTE_ST_2084_PQ) | — | 35.1 MB |
| hdr10-4k-hevc.mp4 | hvc1 10-bit 3840×2160 | 60.00 fps, 1799 khung, CÓ khung thiếu/trùng | HDR (SMPTE_ST_2084_PQ) | — | 140.6 MB |
| sdr-1080-avc.mp4 | avc1 8-bit 1920×1080 | 60.00 fps, 1799 khung, CÓ khung thiếu/trùng | SDR | — | 35.8 MB |
| sdr-4k-avc.mp4 | avc1 8-bit 3840×2160 | 60.00 fps, 1799 khung, CÓ khung thiếu/trùng | SDR | — | 140.6 MB |
| sdr-4k-hevc.mp4 | hvc1 8-bit 3840×2160 | 60.00 fps, 1799 khung, CÓ khung thiếu/trùng | SDR | — | 140.6 MB |

## 2. Mở: thời gian tới khung hình đầu

| File | Trung vị | p95 | Có hình | p95 < 2 s |
|---|---|---|---|---|
| dv-4k-p81.mp4 | 29 ms | 151 ms | 20/20 | Đạt |
| hdr10-1080-hevc.mp4 | 16 ms | 32 ms | 20/20 | Đạt |
| hdr10-4k-hevc.mp4 | 29 ms | 34 ms | 20/20 | Đạt |
| sdr-1080-avc.mp4 | 14 ms | 29 ms | 20/20 | Đạt |
| sdr-4k-avc.mp4 | 33 ms | 35 ms | 20/20 | Đạt |
| sdr-4k-hevc.mp4 | 30 ms | 35 ms | 20/20 | Đạt |

## 3. Tua chính xác tới một khung bất kỳ

30 khung ngẫu nhiên mỗi file; thời điểm yêu cầu là thời điểm thật của khung trong bảng mẫu. “Sai” = khung trả về có thời điểm khác khung yêu cầu.

| File | Trung vị | p95 | Chậm nhất | Sai |
|---|---|---|---|---|
| dv-4k-p81.mp4 | 60 ms | 4008 ms | 4008 ms | 3/30 |
| hdr10-1080-hevc.mp4 | 5 ms | 7 ms | 7 ms | 0/30 |
| hdr10-4k-hevc.mp4 | 12 ms | 21 ms | 22 ms | 0/30 |
| sdr-1080-avc.mp4 | 6 ms | 8 ms | 8 ms | 0/30 |
| sdr-4k-avc.mp4 | 16 ms | 25 ms | 26 ms | 0/30 |
| sdr-4k-hevc.mp4 | 13 ms | 21 ms | 23 ms | 0/30 |

## 4. Phát liên tục 10 s (1×)

| File | Giao / có trong file | Rơi | Khoảng cách lâu nhất | Tốc độ phát thực |
|---|---|---|---|---|
| dv-4k-p81.mp4 | 593 / 593 | 0 | 18 ms | 0.99× |
| hdr10-1080-hevc.mp4 | 597 / 597 | 0 | 19 ms | 1.00× |
| hdr10-4k-hevc.mp4 | 594 / 594 | 0 | 18 ms | 0.99× |
| sdr-1080-avc.mp4 | 598 / 598 | 0 | 18 ms | 1.00× |
| sdr-4k-avc.mp4 | 592 / 592 | 0 | 28 ms | 0.99× |
| sdr-4k-hevc.mp4 | 595 / 595 | 0 | 22 ms | 0.99× |

## 4b. Truy cập ngẫu nhiên: khung nào hệ thống giải mã được khi nhảy thẳng tới nó

Mọi khung của mỗi file được yêu cầu riêng bằng `AVAssetImageGenerator` (dung sai 0). Khung không giải mã được sẽ không hiện khi tua/bước tới đó (xem hình đứng yên ở khung cũ), dù phát tuần tự và xuất vẫn đúng.

| File | Giải mã được | Không giải mã được |
|---|---|---|
| dv-4k-p81.mp4 | 1711/1799 | 88 khung, 30 nhóm; nhóm đầu: 56…58, cách 60 khung |
| hdr10-1080-hevc.mp4 | 1799/1799 | — |
| hdr10-4k-hevc.mp4 | 1799/1799 | — |
| sdr-1080-avc.mp4 | 1799/1799 | — |
| sdr-4k-avc.mp4 | 1799/1799 | — |
| sdr-4k-hevc.mp4 | 1799/1799 | — |

## 5. Xuất và đọc lại kết quả

Đoạn xuất: 240 khung (4 s) bắt đầu từ khung 300 (giây thứ 5). “Lệch hình” là sai khác độ sáng trung bình giữa khung kết quả và khung nguồn tương ứng, đo ở khung đầu, giữa và cuối đoạn (thang 0–255); cắt nhanh phải gần 0, mã hóa lại phải nhỏ.

| File | Kiểu | Thời gian (hệ số) | Kích thước | Số khung | Lệch hình | Ghi chú | Kết quả |
|---|---|---|---|---|---|---|---|
| dv-4k-p81.mp4 | Cắt nhanh | 0.04 s (104.0×) | 17.8 MB | 240/240, khoảng cách đầu 8.3 ms | 0.00 | hvc1 10-bit, giữ HDR SMPTE_ST_2084_PQ, còn hộp dvvC | Đạt |
| dv-4k-p81.mp4 | Chính xác, giữ cỡ | 4.24 s (0.9×) | 7.9 MB | 240/240, khoảng cách đầu 8.3 ms | 0.15 | hvc1 10-bit, giữ HDR SMPTE_ST_2084_PQ, mất hộp Dolby Vision | Đạt |
| dv-4k-p81.mp4 | Chính xác, 4K→1080p | 1.18 s (3.4×) | 3.2 MB | 240/240, khoảng cách đầu 8.3 ms | — | hvc1 10-bit, giữ HDR SMPTE_ST_2084_PQ, mất hộp Dolby Vision, 1920×1080 | Đạt |
| dv-4k-p81.mp4 | Chính xác, chọn H.264 | 4.11 s (1.0×) | 7.9 MB | 240/240, khoảng cách đầu 8.3 ms | 0.15 | hvc1 10-bit, giữ HDR SMPTE_ST_2084_PQ, mất hộp Dolby Vision | Đạt |
| hdr10-1080-hevc.mp4 | Cắt nhanh | 0.01 s (289.1×) | 5.0 MB | 240/240, khoảng cách đầu 8.3 ms | 0.00 | hvc1 10-bit, giữ HDR SMPTE_ST_2084_PQ | Đạt |
| hdr10-1080-hevc.mp4 | Chính xác, giữ cỡ | 1.16 s (3.5×) | 3.3 MB | 240/240, khoảng cách đầu 8.3 ms | 0.32 | hvc1 10-bit, giữ HDR SMPTE_ST_2084_PQ | Đạt |
| hdr10-1080-hevc.mp4 | Chính xác, chọn H.264 | 1.16 s (3.5×) | 3.3 MB | 240/240, khoảng cách đầu 8.3 ms | 0.32 | hvc1 10-bit, giữ HDR SMPTE_ST_2084_PQ | Đạt |
| hdr10-4k-hevc.mp4 | Cắt nhanh | 0.03 s (119.8×) | 19.9 MB | 240/240, khoảng cách đầu 8.3 ms | 0.00 | hvc1 10-bit, giữ HDR SMPTE_ST_2084_PQ | Đạt |
| hdr10-4k-hevc.mp4 | Chính xác, giữ cỡ | 4.14 s (1.0×) | 8.4 MB | 240/240, khoảng cách đầu 8.3 ms | 0.16 | hvc1 10-bit, giữ HDR SMPTE_ST_2084_PQ | Đạt |
| hdr10-4k-hevc.mp4 | Chính xác, 4K→1080p | 1.20 s (3.3×) | 3.3 MB | 240/240, khoảng cách đầu 8.3 ms | — | hvc1 10-bit, giữ HDR SMPTE_ST_2084_PQ, 1920×1080 | Đạt |
| hdr10-4k-hevc.mp4 | Chính xác, chọn H.264 | 4.13 s (1.0×) | 8.4 MB | 240/240, khoảng cách đầu 8.3 ms | 0.16 | hvc1 10-bit, giữ HDR SMPTE_ST_2084_PQ | Đạt |
| sdr-1080-avc.mp4 | Cắt nhanh | 0.01 s (401.0×) | 5.0 MB | 240/240, khoảng cách đầu 8.3 ms | 0.00 | avc1 8-bit | Đạt |
| sdr-1080-avc.mp4 | Chính xác, giữ cỡ | 1.11 s (3.6×) | 6.6 MB | 240/240, khoảng cách đầu 8.3 ms | 0.37 | avc1 8-bit | Đạt |
| sdr-1080-avc.mp4 | Chính xác, đổi sang HEVC | 1.16 s (3.5×) | 4.5 MB | 240/240, khoảng cách đầu 8.3 ms | 0.35 | hvc1 8-bit | Đạt |
| sdr-1080-avc.mp4 | Chính xác + tăng sáng 0,15 | 1.13 s (3.5×) | 6.7 MB | 240/240, khoảng cách đầu 16.7 ms | sáng hơn 15.4 | avc1 8-bit | Đạt |
| sdr-4k-avc.mp4 | Cắt nhanh | 0.03 s (122.6×) | 19.3 MB | 240/240, khoảng cách đầu 8.3 ms | 0.00 | avc1 8-bit | Đạt |
| sdr-4k-avc.mp4 | Chính xác, giữ cỡ | 4.01 s (1.0×) | 19.1 MB | 240/240, khoảng cách đầu 8.3 ms | 0.17 | avc1 8-bit | Đạt |
| sdr-4k-avc.mp4 | Chính xác, 4K→1080p | 1.14 s (3.5×) | 6.7 MB | 240/240, khoảng cách đầu 8.3 ms | — | avc1 8-bit, 1920×1080 | Đạt |
| sdr-4k-hevc.mp4 | Cắt nhanh | 0.04 s (107.3×) | 19.7 MB | 240/240, khoảng cách đầu 8.3 ms | 0.00 | hvc1 8-bit | Đạt |
| sdr-4k-hevc.mp4 | Chính xác, giữ cỡ | 4.18 s (1.0×) | 13.9 MB | 240/240, khoảng cách đầu 8.3 ms | 0.18 | hvc1 8-bit | Đạt |
| sdr-4k-hevc.mp4 | Chính xác, 4K→1080p | 1.14 s (3.5×) | 6.7 MB | 240/240, khoảng cách đầu 8.3 ms | — | avc1 8-bit, 1920×1080 | Đạt |


---

# Phần 2: video quay thật của người dùng (iPhone, màn hình, tải về)

Thư mục thử: 111 file (5,3 GB, 1 giờ), mở **chỉ đọc**; mọi lần xuất/thay thế chạy trên bản sao ở thư mục tạm. Sau khi chạy xong, danh sách 112 file (kích thước + thời gian sửa) giống hệt trước khi chạy, và 18 bản sao khớp SHA-256.

| Đặc điểm | Số file |
|---|---|
| HEVC / H.264 | 101 / 10 |
| HDR Dolby Vision (HLG, profile 8.4) | 71 |
| Quay dọc (xoay 90°/270°) | 85 |
| Tốc độ khung thay đổi (VFR) | 32 |
| Có tiếng / không tiếng | 110 / 1 |
| 4K | 4 |
| edit list lệch khỏi 0 (video đã cắt trong Photos) | 15 |
| Dài nhất / ngắn nhất | 531 s / 2,5 s |

## Ba lượt kiểm thử
1. **Quét nhẹ toàn bộ 111 file** (`macplayer-probe realcheck <thư mục> <work> <out.md> --light`): mở, khung đầu, tua chính xác 8 điểm/file. Kết quả: 111/111 có hình, p95 khung đầu tối đa 135 ms, 0/888 lần tua sai. File: `docs/video-that-cua-nguoi-dung/quet-nhe-111-file.md`.
2. **Kiểm thử đầy đủ trên 18 file đại diện** (`realcheck` không `--light`): phát 10 s, giải mã ngẫu nhiên từng khung (tối đa 1800 khung/file), 65 ca xuất (cắt nhanh, chính xác, đổi codec, 4K→1080p, tăng sáng), so hình, so tiếng, kiểm HDR/Dolby Vision. File: `.../kiem-thu-day-du-18-file.md`.
3. **Luồng thật trong app** (`MacPlayer --selftest <dir> --library <thư mục> --real-only`): mở, phát, tua, bước 1 và 5 khung (đối chiếu khung người dùng thấy), xuất cắt nhanh/chính xác/hình bị lật (qua compositor), khung đầu và cuối của file xuất có đúng là khung của điểm In/Out không, tiếng, lưu và mở lại dự án, thay bản gốc có sao lưu, thả cả thư mục thành danh sách phát, ghép 5 video khác loại lên một timeline rồi thêm lớp phủ. Nhật ký: `.../luong-trong-app.log` (572 PASS).

Cũng chạy: `crash_test.py` (kill -9 giữa lúc xuất) trên file 218 MB: đạt; `open_with_test.py`: đạt; Core 165 test, Media 86 test, selftest tổng hợp 103 kiểm tra đều đạt.

## Lỗi thật tìm được và đã sửa
1. **Thêm nhiều video cùng lúc vào timeline khi đang chọn một clip thì thứ tự bị đảo ngược** (`EditorSession.addVideos`: vị trí chèn tính lại từ clip đang chọn ban đầu). Sửa; thêm test hồi quy trong selftest (luồng G).
2. **Xuất có chỉnh hình dư 1 khung** với file có mốc thời gian làm tròn (29,97/30 fps của điện thoại): `CutPlanning.centerSampled` đếm khung lẻ như khung đủ. Nay làm tròn tới số khung nguyên; có test đơn vị mới.
3. **Lưới khung của compositor sai ở 29,97 và 59,94 fps**: `frameDuration` tính bằng `CMTime(seconds:, 6000)` nên rơi về 30 và 60 fps. Nay dùng phân số chính xác (`FrameRate.frameDuration`).
4. **Cảnh báo Dolby Vision sai**: app nói mã hóa lại "bỏ dữ liệu Dolby Vision", nhưng với video iPhone (profile 8.4) file xuất vẫn còn hộp `dvvC` và RPU ở 150/150 khung đầu; chỉ mẫu Jellyfin (profile 8.1) mất. Câu cảnh báo nay nói đúng: "có thể không còn (tùy video): hãy kiểm tra kết quả". Đổi tên `.dolbyVisionDropped` thành `.dolbyVisionMayBeLost`.
5. Thông báo lỗi xuất nay kèm mã lỗi hệ thống (trước đây chỉ có "không thể hoàn thành thao tác này").

## Lỗi chưa sửa / hạn chế đã đo
- **Ghép nhiều clip: file xuất ngắn hơn bản xem trước khoảng 1 khung mỗi clip** (5 clip: 14,89 s so với 15,00 s; tiếng của clip sau sớm hơn nguồn tới 107 ms tích lũy, tiếng và hình của từng clip vẫn khớp nhau trong ±35 ms). Chưa tìm nguyên nhân gốc.
- **Chất lượng xuất chính xác ở mức "Cao" thấp hơn nguồn iPhone**: bitrate theo công thức 0,12 bit/điểm ảnh (HEVC ×0,65), khoảng 10–12 Mb/s so với 32 Mb/s của nguồn; hai clip nhiều chi tiết lệch độ sáng trung bình 6,5/255 (các clip khác 0,7–3). Là quyết định sản phẩm; chưa đổi.
- **Xuất hình bị lật (qua compositor): độ chính xác khung chỉ kiểm được tới ±1 khung** (±3 ở 60 fps hoặc VFR), vì compositor vẽ lại mỗi khung (sai khoảng 3/255) nên khung kề nhau khó phân biệt. Số khung thì đúng. Một ca (IMG_1082, khung cuối) lệch 3 khung theo phép so hình, chưa rõ là lỗi thật hay giới hạn phép đo.
- **Cắt nhanh một clip ngắn 0,73 s: gói tiếng không phải bản sao byte** (IMG_2973), dù tiếng vẫn khớp (lệch −8,6 ms, khớp sóng 0,84). Chưa tìm nguyên nhân.
- Cắt nhanh luôn đặt biên cách khung nửa khung mỗi đầu (quy tắc `guarded`): tiếng ngắn hơn đoạn khoảng 1 khung và lệch −10…−20 ms. Đã biết, có chủ đích.
- Một clip VFR (IMG_0510) rơi 1 khung/595 khi phát 10 s (khoảng cách 101 ms). Clip Dolby Vision profile 8.4 của iPhone giải mã ngẫu nhiên được 100% khung (lỗi ở mẫu profile 8.1 không xảy ra ở đây).
- Xuất VFR: cắt nhanh giữ nguyên, xuất chính xác thành tốc độ khung cố định (CFR).

## Điều chỉnh công cụ (để lần sau đo đúng)
Bảng khung của file đã cắt trong Photos phải trừ điểm bắt đầu của edit list (nếu không, 6 file bị báo sai khi tua); hình được so theo chiều hiển thị (xoay); tiếng được so bằng dạng sóng (cắt nhanh: so từng byte gói AAC). `realcheck --light`, lệnh probe mới: `rpu`, `cut`, `cutframes`.

---

# Phần 3: vòng sửa tiếp theo (cùng bộ video thật)

## Đã sửa thêm
6. **Ghép nhiều clip ngắn hơn bản xem trước** (5 clip: 14,89 s so với 15,00 s). Nguyên nhân: xuất chính xác không có chỉnh sửa dùng đường "sao chép từng đoạn" (`guarded`), mỗi đoạn giữ khung đầu và khung cuối chỉ nửa khung, nên mỗi đoạn ngắn đi 1 khung. Nay mọi lần ghép xuất chính xác đi qua compositor trên lưới khung cố định (`fixedGrid`): mỗi đoạn là số khung nguyên, file dài 15,03 s so với 15,00 s xem trước, tiếng từng đoạn lệch ≤ 18 ms so với nguồn (trước đây dồn tới 107 ms). Đo trên máy: compositor không làm giảm chất lượng hình so với đường thường (lệch 0,76–1,98, bằng nhau).
7. **Ghép video khác kích thước/chiều quay hiển thị sai** khi không có chỉnh sửa (đường không qua compositor không co lại cho vừa khung; clip ngang bị phóng to lấn khung dọc). Đã hết lỗi này cùng với mục 6 (xem ảnh ghép thử: clip ngang nằm giữa khung dọc, có viền đen).
8. **Chỉnh sửa hình trên video HDR cho ra hình sai** (độ sáng lệch 17–32/255 so với nguồn, nhãn vẫn ghi HDR): compositor nhận ảnh HDR đã bị hạ thành SDR 8-bit rồi gắn lại nhãn HDR. Nay xuất toàn HDR đi qua compositor 10-bit và báo cho hệ thống không gian màu HDR (`colorPrimaries/TransferFunction/YCbCrMatrix`): lệch còn 0,7–2,8 (bằng đường thường). Ghép lẫn HDR và SDR cho ra file SDR đúng nhãn (trước đây ghi nhãn HDR trên hình SDR) và có cảnh báo `.hdrMixedToSDR`.
9. **Mức "Cao" thấp hơn nhiều so với nguồn iPhone**: nay không thấp hơn bitrate của nguồn (quy theo kích thước và codec, nhân 0,9, tối đa bằng nguồn và 80 Mb/s). Lệch hình trung bình của hai clip kém nhất giảm từ 6,45 và 6,59 xuống 3,29 và 4,28. Mức Vừa/Nhỏ không đổi. Ước lượng dung lượng trong màn hình xuất dùng cùng công thức.
10. Tiếng của clip tăng/giảm tốc không còn chạy quá cuối đoạn: người đọc của bộ xuất bị giới hạn trong độ dài của composition. (Phép đo cho thấy tiếng ở 2× vẫn dài hơn hình khoảng 0,1 s; còn lại là hạn chế đã biết.)

## Còn mở sau vòng này
- Tiếng của clip tăng tốc 2× dài hơn hình khoảng 0,1 s (đo bằng test `muteSilencesTheSoundAndSpeedChangesLength`, dung sai nới tới 0,2 s).
- Cắt nhanh clip rất ngắn (0,73 s, IMG_2973): gói tiếng không phải bản sao nguyên byte (vẫn khớp nội dung, lệch −8,6 ms). Bài kiểm tra chấp nhận khi dạng sóng khớp.
- Các phép đo độ chính xác khung qua compositor nay làm theo từng điểm ảnh (`realcheck`, ca "lật ngang") thay cho ảnh thu nhỏ; kết quả ghi trong bảng 18 file.
