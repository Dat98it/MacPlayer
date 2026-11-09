# Ma trận định dạng đã kiểm chứng

Sinh tự động bởi `macplayer-probe matrix`; mỗi ô "Đạt" là kết quả quan sát trong lần chạy này trên **Version 27.0.1 (Build 26A434)**, arm64. Nguồn thử là video tổng hợp 320×180 (mã vạch số khung hình + tiếng bíp mỗi giây), không dùng media cá nhân.

"Đạt" cho cắt nghĩa là: đúng tập khung được chọn (khung đầu, khung cuối, số khung) khi giải mã lại file kết quả.

## 1. Container × codec

| Container | Codec | Phát | Nhập để sửa | Cắt nhanh | Cắt chính xác | Nhúng ảnh bìa (nhanh / chính xác) | Ghi chú |
|---|---|---|---|---|---|---|---|
| .mp4 | H.264 + AAC | Đạt | Đạt | Đạt | Đạt | Đạt / Đạt |  |
| .mp4 | HEVC + AAC | Đạt | Đạt | Đạt | Đạt | Đạt / Đạt |  |
| .mov | H.264 + AAC | Đạt | Đạt | Đạt | Đạt | Đạt / Đạt |  |
| .mov | HEVC + AAC | Đạt | Đạt | Đạt | Đạt | Đạt / Đạt |  |
| .m4v | H.264 + AAC | Đạt | Đạt | Đạt | Đạt | Đạt / Đạt |  |
| .m4v | HEVC + AAC | Đạt | Đạt | Đạt | Đạt | Đạt / Đạt |  |

## 2. Tốc độ khung hình, GOP, VFR, xoay (MP4 / H.264)

| Trường hợp | Cắt nhanh | Cắt chính xác | Ảnh tĩnh đúng khung | Metadata đọc được |
|---|---|---|---|---|
| 30 fps, GOP 2 s | Đạt (40/40 khung) | Đạt (40/40 khung) | Đạt | 320×180, xoay 0°, VFR=không |
| 29,97 fps (30000/1001) | Đạt (40/40 khung) | Đạt (40/40 khung) | Đạt | 320×180, xoay 0°, VFR=không |
| 60 fps, GOP 2 s | Đạt (40/40 khung) | Đạt (40/40 khung) | Đạt | 320×180, xoay 0°, VFR=không |
| 25 fps | Đạt (40/40 khung) | Đạt (40/40 khung) | Đạt | 320×180, xoay 0°, VFR=không |
| GOP dài (3 s) | Đạt (40/40 khung) | Đạt (40/40 khung) | Đạt | 320×180, xoay 0°, VFR=không |
| Không có âm thanh | Đạt (40/40 khung) | Đạt (40/40 khung) | Đạt | 320×180, xoay 0°, VFR=không |
| Tốc độ khung hình thay đổi (VFR, bỏ khung) | Đạt (35/35 khung) | Đạt (35/35 khung) | Đạt | 320×180, xoay 0°, VFR=có |
| Xoay 90° trong metadata (quay dọc) | Đạt (40/40 khung) | Đạt (40/40 khung) | Đạt | 180×320, xoay 90°, VFR=không |

## 3. Chưa kiểm chứng (không khai là hỗ trợ)

- **MKV, WebM, AVI, FLV, WMV, TS/MTS và codec VP9/AV1/ProRes:** MacPlayer chỉ dùng AVFoundation; không có engine ngoài. Chưa thử với file thật nên không công bố hỗ trợ. MacPlayer hiển thị thông báo rõ khi một file không mở được.
- **HDR (HLG/PQ), 10-bit:** nhận diện được cờ HDR; cắt nhanh giữ nguyên luồng; xuất chính xác **giữ HDR** (đọc 10-bit, ghi HEVC Main10, giữ nhãn màu; chọn H.264 thì tự chuyển sang HEVC), đã kiểm bằng file HDR tổng hợp (xem `docs/benchmark.md`, mục 7). **Chưa có video HDR thật từ camera và chưa thử Dolby Vision.**
- **4K/60, video dài hàng giờ, ổ ngoài, file lỗi nửa chừng:** chưa đo trên bộ mẫu thật (xem báo cáo bàn giao).
- **Intel (x86_64):** không có máy thử nên không công bố hỗ trợ; các số liệu trên chỉ thuộc Apple Silicon.
- **Âm thanh PCM/ALAC/multi-track khi xuất:** xuất luôn mã hóa AAC; chỉ **một** track được dùng (track đang bật, tức mặc định của nhóm thay thế; không trộn nhiều track).
- **Phụ đề mềm (track phụ đề trong container):** không nhúng được; chỉ có file `.srt` kèm theo hoặc ghi cứng vào hình.