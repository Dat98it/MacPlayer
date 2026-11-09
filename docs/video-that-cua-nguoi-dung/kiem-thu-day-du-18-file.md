# MacVideo: kiểm thử trên video thật

Chạy bằng `macvideo-probe realcheck`. Video thật (không do MacVideo sinh) nên **không có mã vạch**: chân lý lấy từ chính bảng khung hình, điểm ảnh và âm thanh đã giải mã của file. Một lần tua đúng khi khung trả về mang đúng thời điểm khung đã yêu cầu. Một lần cắt đúng khi file kết quả có đúng các khung của đoạn, liên tục, bắt đầu từ 0, giải mã ra cùng một hình (theo chiều hiển thị) với các khung nguồn tương ứng (sai khác độ sáng trung bình, thang 0–255), và âm thanh dài bằng đoạn cắt, có đường độ to khớp với nguồn.

Máy: Apple M4, macOS 27.0.1. 18 file.

## 1. Các file và việc nhận diện

| File | Định dạng | Khung hình | Loại | Hộp Dolby Vision | Âm thanh | Dung lượng |
|---|---|---|---|---|---|---|
| 1IJDIJSSS_87D28K.MP4 | avc1 8-bit 720×1280 | 19.95 fps, 302 khung, 15.0 s, VFR, cách khung 0.0–66.7 ms | SDR | — | aac 2 kênh 44100 Hz | 3.8 MB |
| 1IJL1VBDH_7DR920.MP4 | avc1 8-bit 856×480 | 30.00 fps, 15948 khung, 531.6 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | aac 2 kênh 48000 Hz | 47.9 MB |
| 1IKOTE83T_5411PF.MP4 | avc1 8-bit 720×1280, xoay 90° | 30.00 fps, 1265 khung, 42.1 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | aac 2 kênh 48000 Hz | 8.2 MB |
| 1ILQST8N3_87D28K.MP4 | avc1 8-bit 1280×720 | 30.00 fps, 671 khung, 22.3 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | không có | 5.4 MB |
| IMG_0014.MOV | hvc1 10-bit 1920×1080 | 59.91 fps, 1809 khung, 30.2 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 49.0 MB |
| IMG_0299.MOV | hvc1 8-bit 2160×3840, xoay 90° | 59.95 fps, 674 khung, 11.2 s, VFR, cách khung 0.0–18.3 ms | SDR | — | aac 2 kênh 44100 Hz | 64.9 MB |
| IMG_0510.mov | hvc1 10-bit 1080×1920, xoay 90° | 59.92 fps, 1742 khung, 29.0 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 32.3 MB |
| IMG_1082.MOV | hvc1 8-bit 1080×1920, xoay 270° | 29.97 fps, 818 khung, 27.3 s, cách khung không đều, cách khung 0.0–35.0 ms | SDR | — | aac 1 kênh 48000 Hz | 32.2 MB |
| IMG_2320.MOV | hvc1 10-bit 1080×1920, xoay 270° | 60.00 fps, 3045 khung, 50.7 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 155.1 MB |
| IMG_2612.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.96 fps, 7052 khung, 117.6 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 207.5 MB |
| IMG_2631.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 570 khung, 9.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 15.0 MB |
| IMG_2973.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.96 fps, 148 khung, 2.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 9.6 MB |
| IMG_3181.MOV | hvc1 8-bit 1920×1440 | 30.00 fps, 478 khung, 15.9 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 20.4 MB |
| IMG_3945.MOV | hvc1 10-bit 2160×3840, xoay 90° | 59.99 fps, 597 khung, 9.9 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 63.1 MB |
| IMG_8196.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 702 khung, 23.4 s, cách khung không đều, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 38.3 MB |
| IMG_8375.mov | avc1 8-bit 1920×1080 | 30.00 fps, 866 khung, 28.8 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | aac 2 kênh 44100 Hz | 52.1 MB |
| ScreenRecording_02-06-2025 15-18-41_1.MOV | hvc1 8-bit 888×1920 | 59.88 fps, 547 khung, 9.1 s, cách khung không đều, cách khung 0.0–18.3 ms | SDR | — | aac 2 kênh 44100 Hz | 17.6 MB |
| copy_B70C57A7-B4CC-4B2D-9DAC-1BE07DD6D762.mov | hvc1 8-bit 1080×1846 | 30.00 fps, 966 khung, 32.2 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | aac 2 kênh 44100 Hz | 43.1 MB |

## 2. Mở: thời gian tới khung hình đầu

| File | Trung vị | p95 | Có hình | p95 < 2 s |
|---|---|---|---|---|
| 1IJDIJSSS_87D28K.MP4 | 10 ms | 127 ms | 10/10 | Đạt |
| 1IJL1VBDH_7DR920.MP4 | 9 ms | 11 ms | 10/10 | Đạt |
| 1IKOTE83T_5411PF.MP4 | 10 ms | 12 ms | 10/10 | Đạt |
| 1ILQST8N3_87D28K.MP4 | 8 ms | 8 ms | 10/10 | Đạt |
| IMG_0014.MOV | 16 ms | 18 ms | 10/10 | Đạt |
| IMG_0299.MOV | 18 ms | 20 ms | 10/10 | Đạt |
| IMG_0510.mov | 15 ms | 16 ms | 10/10 | Đạt |
| IMG_1082.MOV | 14 ms | 15 ms | 10/10 | Đạt |
| IMG_2320.MOV | 14 ms | 16 ms | 10/10 | Đạt |
| IMG_2612.MOV | 15 ms | 17 ms | 10/10 | Đạt |
| IMG_2631.MOV | 15 ms | 18 ms | 10/10 | Đạt |
| IMG_2973.MOV | 15 ms | 16 ms | 10/10 | Đạt |
| IMG_3181.MOV | 13 ms | 15 ms | 10/10 | Đạt |
| IMG_3945.MOV | 21 ms | 23 ms | 10/10 | Đạt |
| IMG_8196.MOV | 16 ms | 16 ms | 10/10 | Đạt |
| IMG_8375.mov | 15 ms | 15 ms | 10/10 | Đạt |
| ScreenRecording_02-06-2025 15-18-41_1.MOV | 16 ms | 16 ms | 10/10 | Đạt |
| copy_B70C57A7-B4CC-4B2D-9DAC-1BE07DD6D762.mov | 13 ms | 16 ms | 10/10 | Đạt |

## 3. Tua chính xác tới một khung bất kỳ

30 khung ngẫu nhiên mỗi file; thời điểm yêu cầu là thời điểm thật của khung trong bảng mẫu. “Sai” = khung trả về có thời điểm khác khung yêu cầu quá nửa khoảng cách tới khung kề (với VFR, khoảng cách thật của khung đó).

| File | Trung vị | p95 | Chậm nhất | Sai |
|---|---|---|---|---|
| 1IJDIJSSS_87D28K.MP4 | 8 ms | 17 ms | 19 ms | 0/30 |
| 1IJL1VBDH_7DR920.MP4 | 9 ms | 12 ms | 12 ms | 0/30 |
| 1IKOTE83T_5411PF.MP4 | 8 ms | 22 ms | 24 ms | 0/30 |
| 1ILQST8N3_87D28K.MP4 | 14 ms | 22 ms | 23 ms | 0/30 |
| IMG_0014.MOV | 12 ms | 16 ms | 19 ms | 0/30 |
| IMG_0299.MOV | 34 ms | 53 ms | 55 ms | 0/30 |
| IMG_0510.mov | 11 ms | 16 ms | 16 ms | 0/30 |
| IMG_1082.MOV | 6 ms | 9 ms | 10 ms | 0/30 |
| IMG_2320.MOV | 8 ms | 15 ms | 21 ms | 0/30 |
| IMG_2612.MOV | 8 ms | 13 ms | 14 ms | 0/30 |
| IMG_2631.MOV | 10 ms | 15 ms | 15 ms | 0/30 |
| IMG_2973.MOV | 9 ms | 14 ms | 16 ms | 0/30 |
| IMG_3181.MOV | 10 ms | 14 ms | 14 ms | 0/30 |
| IMG_3945.MOV | 27 ms | 37 ms | 41 ms | 0/30 |
| IMG_8196.MOV | 8 ms | 14 ms | 15 ms | 0/30 |
| IMG_8375.mov | 11 ms | 15 ms | 16 ms | 0/30 |
| ScreenRecording_02-06-2025 15-18-41_1.MOV | 9 ms | 15 ms | 17 ms | 0/30 |
| copy_B70C57A7-B4CC-4B2D-9DAC-1BE07DD6D762.mov | 8 ms | 12 ms | 12 ms | 0/30 |

## 4. Phát liên tục (1×), tối đa 10 s từ đầu file

“Rơi” đếm số khung CÓ trong bảng mẫu của file mà không bao giờ được giao (tính theo khung thật của file, nên đúng cả với VFR).

| File | Phát | Giao / có trong file | Rơi | Khoảng cách lâu nhất | Tốc độ phát thực |
|---|---|---|---|---|---|
| 1IJDIJSSS_87D28K.MP4 | 10.0 s | 198 / 198 | 0 | 68 ms | 0.99× |
| 1IJL1VBDH_7DR920.MP4 | 10.0 s | 297 / 297 | 0 | 35 ms | 0.99× |
| 1IKOTE83T_5411PF.MP4 | 10.0 s | 297 / 297 | 0 | 35 ms | 0.99× |
| 1ILQST8N3_87D28K.MP4 | 10.0 s | 299 / 299 | 0 | 35 ms | 1.00× |
| IMG_0014.MOV | 10.0 s | 592 / 592 | 0 | 20 ms | 0.99× |
| IMG_0299.MOV | 10.0 s | 589 / 589 | 0 | 18 ms | 0.98× |
| IMG_0510.mov | 10.0 s | 595 / 596 | 1 | 92 ms | 0.99× |
| IMG_1082.MOV | 10.0 s | 297 / 297 | 0 | 36 ms | 0.99× |
| IMG_2320.MOV | 10.0 s | 594 / 594 | 0 | 18 ms | 0.99× |
| IMG_2612.MOV | 10.0 s | 593 / 593 | 0 | 18 ms | 0.99× |
| IMG_2631.MOV | 8.7 s | 514 / 514 | 0 | 18 ms | 0.99× |
| IMG_2973.MOV | 1.6 s | 92 / 92 | 0 | 18 ms | 0.94× |
| IMG_3181.MOV | 10.0 s | 297 / 297 | 0 | 36 ms | 0.99× |
| IMG_3945.MOV | 9.1 s | 536 / 536 | 0 | 19 ms | 0.98× |
| IMG_8196.MOV | 10.0 s | 297 / 297 | 0 | 35 ms | 0.99× |
| IMG_8375.mov | 10.0 s | 297 / 297 | 0 | 35 ms | 0.99× |
| ScreenRecording_02-06-2025 15-18-41_1.MOV | 7.8 s | 461 / 461 | 0 | 103 ms | 0.99× |
| copy_B70C57A7-B4CC-4B2D-9DAC-1BE07DD6D762.mov | 10.0 s | 297 / 297 | 0 | 35 ms | 0.99× |

## 4b. Truy cập ngẫu nhiên: khung nào hệ thống giải mã được khi nhảy thẳng tới nó

Mọi khung (tối đa 1800 khung đầu của mỗi file) được yêu cầu riêng bằng `AVAssetImageGenerator` (dung sai 0). Khung không giải mã được sẽ không hiện khi tua/bước tới đó (xem hình đứng yên ở khung cũ), dù phát tuần tự và xuất vẫn đúng.

| File | Giải mã được | Không giải mã được |
|---|---|---|
| 1IJDIJSSS_87D28K.MP4 | 302/302 | — |
| 1IJL1VBDH_7DR920.MP4 | 1800/1800 | — |
| 1IKOTE83T_5411PF.MP4 | 1265/1265 | — |
| 1ILQST8N3_87D28K.MP4 | 671/671 | — |
| IMG_0014.MOV | 1800/1800 | — |
| IMG_0299.MOV | 674/674 | — |
| IMG_0510.mov | 1742/1742 | — |
| IMG_1082.MOV | 818/818 | — |
| IMG_2320.MOV | 1800/1800 | — |
| IMG_2612.MOV | 1800/1800 | — |
| IMG_2631.MOV | 570/570 | — |
| IMG_2973.MOV | 148/148 | — |
| IMG_3181.MOV | 478/478 | — |
| IMG_3945.MOV | 597/597 | — |
| IMG_8196.MOV | 702/702 | — |
| IMG_8375.mov | 866/866 | — |
| ScreenRecording_02-06-2025 15-18-41_1.MOV | 547/547 | — |
| copy_B70C57A7-B4CC-4B2D-9DAC-1BE07DD6D762.mov | 966/966 | — |

## 5. Xuất và đọc lại kết quả

Đoạn xuất: tối đa 240 khung bắt đầu từ khung 300 (hoặc từ một phần tư file nếu file ngắn). “Lệch hình” là sai khác độ sáng trung bình giữa khung kết quả và khung nguồn tương ứng, đo ở khung đầu, giữa và cuối đoạn trên hình **như hiển thị** (thang 0–255); cắt nhanh phải gần 0, mã hóa lại phải nhỏ. “Tiếng” là độ dài tiếng so với đoạn, độ lệch giữa đường độ to của kết quả và của nguồn (ms), và hệ số tương quan của hai đường đó. Với VFR, số khung kỳ vọng của xuất chính xác là độ dài đoạn nhân tốc độ khung của file kết quả.

| File | Kiểu | Thời gian (hệ số) | Kích thước | Số khung | Lệch hình | Tiếng | Ghi chú | Kết quả |
|---|---|---|---|---|---|---|---|---|
| 1IJDIJSSS_87D28K.MP4 | Cắt nhanh | 0.01 s (544.6×) | 2.2 MB | 113/113, khoảng cách đầu 8.3 ms | 0.00 | dài 5.58 s (đoạn 5.63 s, -52 ms), lệch -25.5 ms (1 khung = 50.1 ms), khớp sóng 0.85, gói tiếng sao chép nguyên byte | avc1 8-bit, VFR→VFR | Đạt |
| 1IJDIJSSS_87D28K.MP4 | Chính xác, giữ cỡ | 0.34 s (16.7×) | 1.6 MB | 113/113, khoảng cách đầu 8.3 ms | 2.47 | dài 5.58 s (đoạn 5.63 s, -51 ms), lệch -25.4 ms (1 khung = 50.1 ms), khớp sóng 0.85 | avc1 8-bit, VFR→VFR | Đạt |
| 1IJDIJSSS_87D28K.MP4 | Chính xác, đổi sang HEVC | 0.35 s (16.3×) | 1.2 MB | 113/113, khoảng cách đầu 8.3 ms | 2.82 | dài 5.58 s (đoạn 5.63 s, -51 ms), lệch -25.5 ms (1 khung = 50.1 ms), khớp sóng 0.87 | hvc1 8-bit, VFR→VFR | Đạt |
| 1IJDIJSSS_87D28K.MP4 | Chính xác + tăng sáng 0,15 | 0.26 s (21.3×) | 1.7 MB | 93/94, khoảng cách đầu 50.0 ms | sáng hơn 16.0 | dài 5.61 s (đoạn 5.63 s, -21 ms), lệch -25.5 ms (1 khung = 50.1 ms), khớp sóng 0.89 | avc1 8-bit, VFR→VFR | Đạt |
| 1IJDIJSSS_87D28K.MP4 | Chính xác, lật ngang (qua compositor) | 0.25 s (22.4×) | 1.7 MB | 93/94, khoảng cách đầu 50.0 ms | nan | dài 5.61 s (đoạn 5.63 s, -21 ms), lệch -25.4 ms (1 khung = 50.1 ms), khớp sóng 0.86 | avc1 8-bit, khung đầu/giữa/cuối lệch so với nguồn: [0] khung, VFR→VFR | Đạt |
| 1IJL1VBDH_7DR920.MP4 | Cắt nhanh | 0.01 s (891.4×) | 1.0 MB | 240/240, khoảng cách đầu 16.7 ms | 0.00 | dài 7.97 s (đoạn 8.00 s, -34 ms), lệch -17.2 ms (1 khung = 33.3 ms), khớp sóng 0.97, gói tiếng sao chép nguyên byte | avc1 8-bit | Đạt |
| 1IJL1VBDH_7DR920.MP4 | Chính xác, giữ cỡ | 0.32 s (25.0×) | 1.6 MB | 240/240, khoảng cách đầu 16.7 ms | 1.96 | dài 7.97 s (đoạn 8.00 s, -35 ms), lệch -17.6 ms (1 khung = 33.3 ms), khớp sóng 0.82 | avc1 8-bit | Đạt |
| 1IJL1VBDH_7DR920.MP4 | Chính xác, đổi sang HEVC | 0.38 s (20.9×) | 1.1 MB | 240/240, khoảng cách đầu 16.7 ms | 2.19 | dài 7.97 s (đoạn 8.00 s, -35 ms), lệch -17.6 ms (1 khung = 33.3 ms), khớp sóng 0.78 | hvc1 8-bit | Đạt |
| 1IJL1VBDH_7DR920.MP4 | Chính xác + tăng sáng 0,15 | 0.32 s (24.7×) | 1.6 MB | 240/240, khoảng cách đầu 33.3 ms | sáng hơn 15.9 | dài 8.00 s (đoạn 8.00 s, -1 ms), lệch -17.6 ms (1 khung = 33.3 ms), khớp sóng 0.80 | avc1 8-bit | Đạt |
| 1IJL1VBDH_7DR920.MP4 | Chính xác, lật ngang (qua compositor) | 0.33 s (24.6×) | 1.6 MB | 240/240, khoảng cách đầu 33.3 ms | nan | dài 8.00 s (đoạn 8.00 s, -1 ms), lệch -17.8 ms (1 khung = 33.3 ms), khớp sóng 0.78 | avc1 8-bit, khung đầu/giữa/cuối lệch so với nguồn: [0, 0, 0] khung | Đạt |
| 1IKOTE83T_5411PF.MP4 | Cắt nhanh | 0.01 s (992.9×) | 1.6 MB | 240/240, khoảng cách đầu 16.7 ms | 0.00 | dài 7.97 s (đoạn 8.00 s, -34 ms), lệch -17.1 ms (1 khung = 33.3 ms), khớp sóng 0.97, gói tiếng sao chép nguyên byte | avc1 8-bit | Đạt |
| 1IKOTE83T_5411PF.MP4 | Chính xác, giữ cỡ | 0.57 s (13.9×) | 3.4 MB | 240/240, khoảng cách đầu 16.7 ms | 1.27 | dài 7.97 s (đoạn 8.00 s, -34 ms), lệch -17.4 ms (1 khung = 33.3 ms), khớp sóng 0.78 | avc1 8-bit | Đạt |
| 1IKOTE83T_5411PF.MP4 | Chính xác, đổi sang HEVC | 0.69 s (11.5×) | 2.2 MB | 240/240, khoảng cách đầu 16.7 ms | 1.31 | dài 7.97 s (đoạn 8.00 s, -34 ms), lệch -17.4 ms (1 khung = 33.3 ms), khớp sóng 0.82 | hvc1 8-bit | Đạt |
| 1IKOTE83T_5411PF.MP4 | Chính xác + tăng sáng 0,15 | 0.57 s (14.1×) | 3.4 MB | 240/240, khoảng cách đầu 33.3 ms | sáng hơn 15.8 | dài 8.00 s (đoạn 8.00 s, -1 ms), lệch -17.4 ms (1 khung = 33.3 ms), khớp sóng 0.78 | avc1 8-bit, xoay 90°→0° (hiển thị vẫn 720×1280) | Đạt |
| 1IKOTE83T_5411PF.MP4 | Chính xác, lật ngang (qua compositor) | 0.57 s (14.1×) | 3.4 MB | 240/240, khoảng cách đầu 33.3 ms | nan | dài 8.00 s (đoạn 8.00 s, -1 ms), lệch -17.4 ms (1 khung = 33.3 ms), khớp sóng 0.75 | avc1 8-bit, khung đầu/giữa/cuối lệch so với nguồn: [0, 0, 0] khung, xoay 90°→0° (hiển thị vẫn 720×1280) | Đạt |
| 1ILQST8N3_87D28K.MP4 | Cắt nhanh | 0.01 s (1005.7×) | 2.0 MB | 240/240, khoảng cách đầu 16.7 ms | 0.00 | (nguồn không có tiếng) | avc1 8-bit | Đạt |
| 1ILQST8N3_87D28K.MP4 | Chính xác, giữ cỡ | 0.56 s (14.3×) | 3.1 MB | 240/240, khoảng cách đầu 16.7 ms | 0.67 | (nguồn không có tiếng) | avc1 8-bit | Đạt |
| 1ILQST8N3_87D28K.MP4 | Chính xác, đổi sang HEVC | 0.68 s (11.8×) | 2.1 MB | 240/240, khoảng cách đầu 16.7 ms | 1.01 | (nguồn không có tiếng) | hvc1 8-bit | Đạt |
| 1ILQST8N3_87D28K.MP4 | Chính xác + tăng sáng 0,15 | 0.57 s (14.0×) | 3.2 MB | 240/240, khoảng cách đầu 33.3 ms | sáng hơn 11.1 | (nguồn không có tiếng) | avc1 8-bit | Đạt |
| 1ILQST8N3_87D28K.MP4 | Chính xác, lật ngang (qua compositor) | 0.57 s (14.0×) | 3.2 MB | 240/240, khoảng cách đầu 33.3 ms | nan | (nguồn không có tiếng) | avc1 8-bit, khung đầu/giữa/cuối lệch so với nguồn: [0, 0, 0] khung | Đạt |
| IMG_0014.MOV | Cắt nhanh | 0.02 s (243.1×) | 7.9 MB | 240/240, khoảng cách đầu 8.3 ms | 0.00 | dài 3.98 s (đoạn 4.01 s, -27 ms), lệch -8.4 ms (1 khung = 16.7 ms), khớp sóng 0.26, gói tiếng sao chép nguyên byte | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung) | Đạt |
| IMG_0014.MOV | Chính xác, giữ cỡ | 1.19 s (3.4×) | 6.2 MB | 240/240, khoảng cách đầu 8.3 ms | 2.82 | dài 3.96 s (đoạn 4.01 s, -44 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.88 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung) | Đạt |
| IMG_0014.MOV | Chính xác, chọn H.264 | 1.19 s (3.4×) | 6.2 MB | 240/240, khoảng cách đầu 8.3 ms | 2.82 | dài 3.96 s (đoạn 4.01 s, -44 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.87 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung) | Đạt |
| IMG_0014.MOV | Chính xác, lật ngang (qua compositor) | 1.19 s (3.4×) | 6.2 MB | 240/240, khoảng cách đầu 16.7 ms | nan | dài 4.01 s (đoạn 4.01 s, +1 ms), lệch -8.6 ms (1 khung = 16.7 ms), khớp sóng 0.87 | hvc1 10-bit, khung đầu/giữa/cuối lệch so với nguồn: [0, 0, 0] khung, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung) | Đạt |
| IMG_0299.MOV | Cắt nhanh | 0.04 s (101.1×) | 26.5 MB | 240/240, khoảng cách đầu 8.3 ms | 0.00 | dài 3.98 s (đoạn 4.00 s, -19 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.94, gói tiếng sao chép nguyên byte | hvc1 8-bit, VFR→VFR | Đạt |
| IMG_0299.MOV | Chính xác, giữ cỡ | 4.10 s (1.0×) | 20.5 MB | 240/241, khoảng cách đầu 8.3 ms | 0.76 | dài 3.99 s (đoạn 4.00 s, -17 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.95 | hvc1 8-bit, VFR→VFR | Đạt |
| IMG_0299.MOV | Chính xác, 4K→1080p | 0.93 s (4.3×) | 2.6 MB | 240/241, khoảng cách đầu 8.3 ms | — | dài 3.99 s (đoạn 4.00 s, -17 ms), lệch -8.6 ms (1 khung = 16.7 ms), khớp sóng 0.86 | avc1 8-bit, 608×1080, VFR→VFR | Đạt |
| IMG_0299.MOV | Chính xác, lật ngang (qua compositor) | 4.16 s (1.0×) | 20.2 MB | 240/240, khoảng cách đầu 16.7 ms | nan | dài 4.00 s (đoạn 4.00 s, -0 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.92 | hvc1 8-bit, khung đầu/giữa/cuối lệch so với nguồn: [0] khung, xoay 90°→0° (hiển thị vẫn 2160×3840), VFR→CFR 59.94 fps | Đạt |
| IMG_0510.mov | Cắt nhanh | 0.01 s (300.6×) | 4.9 MB | 240/240, khoảng cách đầu 8.3 ms | 0.00 | dài 3.98 s (đoạn 4.00 s, -19 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 1.00, gói tiếng sao chép nguyên byte | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), VFR→CFR 59.94 fps | Đạt |
| IMG_0510.mov | Chính xác, giữ cỡ | 1.17 s (3.4×) | 4.1 MB | 240/241, khoảng cách đầu 8.3 ms | 0.67 | dài 3.99 s (đoạn 4.00 s, -17 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.99 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), VFR→VFR | Đạt |
| IMG_0510.mov | Chính xác, chọn H.264 | 1.17 s (3.4×) | 4.1 MB | 240/241, khoảng cách đầu 8.3 ms | 0.67 | dài 3.99 s (đoạn 4.00 s, -17 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.99 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), VFR→VFR | Đạt |
| IMG_0510.mov | Chính xác, lật ngang (qua compositor) | 1.16 s (3.4×) | 4.0 MB | 240/240, khoảng cách đầu 16.7 ms | nan | dài 4.00 s (đoạn 4.00 s, +2 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 1.00 | hvc1 10-bit, khung đầu/giữa/cuối lệch so với nguồn: [0] khung, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), xoay 90°→0° (hiển thị vẫn 1080×1920), VFR→CFR 59.92 fps | Đạt |
| IMG_1082.MOV | Cắt nhanh | 0.02 s (445.9×) | 9.6 MB | 240/240, khoảng cách đầu 16.7 ms | 0.00 | dài 7.97 s (đoạn 8.01 s, -36 ms), lệch -17.4 ms (1 khung = 33.4 ms), khớp sóng 0.98, gói tiếng sao chép nguyên byte | hvc1 8-bit | Đạt |
| IMG_1082.MOV | Chính xác, giữ cỡ | 1.11 s (7.2×) | 8.4 MB | 240/240, khoảng cách đầu 16.7 ms | 0.95 | dài 7.97 s (đoạn 8.01 s, -34 ms), lệch -17.5 ms (1 khung = 33.4 ms), khớp sóng 0.85 | hvc1 8-bit | Đạt |
| IMG_1082.MOV | Chính xác, đổi sang HEVC | 1.12 s (7.2×) | 8.4 MB | 240/240, khoảng cách đầu 16.7 ms | 0.95 | dài 7.97 s (đoạn 8.01 s, -34 ms), lệch -17.4 ms (1 khung = 33.4 ms), khớp sóng 0.90 | hvc1 8-bit | Đạt |
| IMG_1082.MOV | Chính xác + tăng sáng 0,15 | 1.12 s (7.2×) | 9.5 MB | 240/240, khoảng cách đầu 33.3 ms | sáng hơn 16.1 | dài 8.01 s (đoạn 8.01 s, -1 ms), lệch -17.4 ms (1 khung = 33.4 ms), khớp sóng 0.90 | avc1 8-bit, xoay 270°→0° (hiển thị vẫn 1080×1920) | Đạt |
| IMG_1082.MOV | Chính xác, lật ngang (qua compositor) | 1.13 s (7.1×) | 8.4 MB | 240/240, khoảng cách đầu 33.3 ms | nan | dài 8.01 s (đoạn 8.01 s, -1 ms), lệch -17.6 ms (1 khung = 33.4 ms), khớp sóng 0.81 | hvc1 8-bit, khung đầu/giữa/cuối lệch so với nguồn: [0, 0, 0] khung, xoay 270°→0° (hiển thị vẫn 1080×1920) | Đạt |
| IMG_2320.MOV | Cắt nhanh | 0.02 s (215.8×) | 11.6 MB | 240/240, khoảng cách đầu 8.3 ms | 0.00 | dài 3.98 s (đoạn 4.00 s, -17 ms), lệch -8.9 ms (1 khung = 16.7 ms), khớp sóng 0.98, gói tiếng sao chép nguyên byte | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), VFR→CFR 60.00 fps | Đạt |
| IMG_2320.MOV | Chính xác, giữ cỡ | 1.17 s (3.4×) | 11.2 MB | 240/240, khoảng cách đầu 8.3 ms | 0.68 | dài 3.98 s (đoạn 4.00 s, -17 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.98 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), VFR→VFR | Đạt |
| IMG_2320.MOV | Chính xác, chọn H.264 | 1.18 s (3.4×) | 11.2 MB | 240/240, khoảng cách đầu 8.3 ms | 0.68 | dài 3.98 s (đoạn 4.00 s, -17 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.98 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), VFR→VFR | Đạt |
| IMG_2320.MOV | Chính xác, lật ngang (qua compositor) | 1.17 s (3.4×) | 11.0 MB | 240/240, khoảng cách đầu 16.7 ms | nan | dài 4.00 s (đoạn 4.00 s, -0 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.98 | hvc1 10-bit, khung đầu/giữa/cuối lệch so với nguồn: [0] khung, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), xoay 270°→0° (hiển thị vẫn 1080×1920), VFR→CFR 60.00 fps | Đạt |
| IMG_2612.MOV | Cắt nhanh | 0.02 s (193.7×) | 13.1 MB | 240/240, khoảng cách đầu 8.3 ms | 0.00 | dài 3.97 s (đoạn 4.00 s, -27 ms), lệch -8.4 ms (1 khung = 16.7 ms), khớp sóng 0.28, gói tiếng sao chép nguyên byte | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung) | Đạt |
| IMG_2612.MOV | Chính xác, giữ cỡ | 1.16 s (3.4×) | 6.3 MB | 240/240, khoảng cách đầu 8.3 ms | 0.77 | dài 3.97 s (đoạn 4.00 s, -36 ms), lệch -8.6 ms (1 khung = 16.7 ms), khớp sóng 0.99 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung) | Đạt |
| IMG_2612.MOV | Chính xác, chọn H.264 | 1.17 s (3.4×) | 6.3 MB | 240/240, khoảng cách đầu 8.3 ms | 0.77 | dài 3.97 s (đoạn 4.00 s, -36 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.99 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung) | Đạt |
| IMG_2612.MOV | Chính xác, lật ngang (qua compositor) | 1.17 s (3.4×) | 6.3 MB | 240/240, khoảng cách đầu 16.7 ms | nan | dài 4.00 s (đoạn 4.00 s, +0 ms), lệch -8.6 ms (1 khung = 16.7 ms), khớp sóng 0.99 | hvc1 10-bit, khung đầu/giữa/cuối lệch so với nguồn: [0, 0, 0] khung, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), xoay 90°→0° (hiển thị vẫn 1080×1920) | Đạt |
| IMG_2631.MOV | Cắt nhanh | 0.01 s (249.7×) | 5.4 MB | 213/213, khoảng cách đầu 8.3 ms | 0.00 | dài 3.53 s (đoạn 3.55 s, -19 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.99, gói tiếng sao chép nguyên byte | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung) | Đạt |
| IMG_2631.MOV | Chính xác, giữ cỡ | 1.05 s (3.4×) | 4.9 MB | 213/213, khoảng cách đầu 8.3 ms | 1.45 | dài 3.54 s (đoạn 3.55 s, -17 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.99 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung) | Đạt |
| IMG_2631.MOV | Chính xác, chọn H.264 | 1.05 s (3.4×) | 4.9 MB | 213/213, khoảng cách đầu 8.3 ms | 1.45 | dài 3.54 s (đoạn 3.55 s, -17 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.99 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung) | Đạt |
| IMG_2631.MOV | Chính xác, lật ngang (qua compositor) | 1.05 s (3.4×) | 4.8 MB | 213/213, khoảng cách đầu 16.7 ms | nan | dài 3.55 s (đoạn 3.55 s, +0 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.99 | hvc1 10-bit, khung đầu/giữa/cuối lệch so với nguồn: [0, 0, 0] khung, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), xoay 90°→0° (hiển thị vẫn 1080×1920) | Đạt |
| IMG_2973.MOV | Cắt nhanh | 0.01 s (69.7×) | 5.3 MB | 55/55, khoảng cách đầu 8.3 ms | 0.00 | dài 0.90 s (đoạn 0.92 s, -18 ms), lệch -8.5 ms (1 khung = 16.7 ms), khớp sóng 0.81, gói tiếng sao chép nguyên byte | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 74/74 khung) | Đạt |
| IMG_2973.MOV | Chính xác, giữ cỡ | 0.31 s (2.9×) | 3.6 MB | 55/55, khoảng cách đầu 8.3 ms | 3.29 | dài 0.90 s (đoạn 0.92 s, -17 ms), lệch -8.5 ms (1 khung = 16.7 ms), khớp sóng 0.80 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 55/55 khung) | Đạt |
| IMG_2973.MOV | Chính xác, chọn H.264 | 0.32 s (2.9×) | 3.6 MB | 55/55, khoảng cách đầu 8.3 ms | 3.29 | dài 0.90 s (đoạn 0.92 s, -17 ms), lệch -8.5 ms (1 khung = 16.7 ms), khớp sóng 0.80 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 55/55 khung) | Đạt |
| IMG_2973.MOV | Chính xác, lật ngang (qua compositor) | 0.32 s (2.9×) | 3.6 MB | 55/55, khoảng cách đầu 16.7 ms | nan | dài 0.92 s (đoạn 0.92 s, -2 ms), lệch -8.6 ms (1 khung = 16.7 ms), khớp sóng 0.79 | hvc1 10-bit, khung đầu/giữa/cuối lệch so với nguồn: [0, 0, 0] khung, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 55/55 khung), xoay 90°→0° (hiển thị vẫn 1080×1920) | Đạt |
| IMG_3181.MOV | Cắt nhanh | 0.02 s (278.7×) | 8.1 MB | 179/179, khoảng cách đầu 16.7 ms | 0.00 | dài 5.93 s (đoạn 5.97 s, -34 ms), lệch -17.1 ms (1 khung = 33.3 ms), khớp sóng 0.74, gói tiếng sao chép nguyên byte | hvc1 8-bit, VFR→VFR | Đạt |
| IMG_3181.MOV | Chính xác, giữ cỡ | 1.11 s (5.4×) | 6.4 MB | 179/180, khoảng cách đầu 16.7 ms | 1.18 | dài 5.93 s (đoạn 5.97 s, -34 ms), lệch -17.1 ms (1 khung = 33.3 ms), khớp sóng 0.69 | hvc1 8-bit, VFR→VFR | Đạt |
| IMG_3181.MOV | Chính xác, đổi sang HEVC | 1.12 s (5.3×) | 6.4 MB | 179/180, khoảng cách đầu 16.7 ms | 1.18 | dài 5.93 s (đoạn 5.97 s, -34 ms), lệch -17.1 ms (1 khung = 33.3 ms), khớp sóng 0.76 | hvc1 8-bit, VFR→VFR | Đạt |
| IMG_3181.MOV | Chính xác + tăng sáng 0,15 | 1.12 s (5.3×) | 7.1 MB | 179/179, khoảng cách đầu 33.3 ms | sáng hơn 15.8 | dài 5.97 s (đoạn 5.97 s, -3 ms), lệch -17.1 ms (1 khung = 33.3 ms), khớp sóng 0.72 | avc1 8-bit, VFR→CFR 30.00 fps | Đạt |
| IMG_3181.MOV | Chính xác, lật ngang (qua compositor) | 1.13 s (5.3×) | 6.5 MB | 179/179, khoảng cách đầu 33.3 ms | nan | dài 5.97 s (đoạn 5.97 s, -2 ms), lệch -17.1 ms (1 khung = 33.3 ms), khớp sóng 0.70 | hvc1 8-bit, khung đầu/giữa/cuối lệch so với nguồn: [0] khung, VFR→CFR 30.00 fps | Đạt |
| IMG_3945.MOV | Cắt nhanh | 0.03 s (112.7×) | 26.4 MB | 223/223, khoảng cách đầu 8.3 ms | 0.00 | dài 3.70 s (đoạn 3.72 s, -19 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.98, gói tiếng sao chép nguyên byte | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), VFR→CFR 59.45 fps | Đạt |
| IMG_3945.MOV | Chính xác, giữ cỡ | 3.89 s (1.0×) | 21.2 MB | 223/224, khoảng cách đầu 8.3 ms | 0.85 | dài 3.70 s (đoạn 3.72 s, -17 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.98 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), VFR→VFR | Đạt |
| IMG_3945.MOV | Chính xác, 4K→1080p | 0.86 s (4.3×) | 1.9 MB | 223/224, khoảng cách đầu 8.3 ms | — | dài 3.70 s (đoạn 3.72 s, -17 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.98 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), 608×1080, VFR→VFR | Đạt |
| IMG_3945.MOV | Chính xác, chọn H.264 | 3.86 s (1.0×) | 21.2 MB | 223/224, khoảng cách đầu 8.3 ms | 0.85 | dài 3.70 s (đoạn 3.72 s, -17 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.98 | hvc1 10-bit, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), VFR→VFR | Đạt |
| IMG_3945.MOV | Chính xác, lật ngang (qua compositor) | 3.85 s (1.0×) | 21.2 MB | 223/223, khoảng cách đầu 16.7 ms | nan | dài 3.72 s (đoạn 3.72 s, +0 ms), lệch -8.8 ms (1 khung = 16.7 ms), khớp sóng 0.98 | hvc1 10-bit, khung đầu/giữa/cuối lệch so với nguồn: [0] khung, giữ HDR ITU_R_2100_HLG, còn hộp dvvC (RPU 150/150 khung), xoay 90°→0° (hiển thị vẫn 2160×3840), VFR→CFR 60.00 fps | Đạt |
| IMG_8196.MOV | Cắt nhanh | 0.03 s (297.1×) | 12.9 MB | 240/240, khoảng cách đầu 16.7 ms | 0.00 | dài 7.97 s (đoạn 8.00 s, -34 ms), lệch -17.2 ms (1 khung = 33.3 ms), khớp sóng 0.98, gói tiếng sao chép nguyên byte | hvc1 8-bit | Đạt |
| IMG_8196.MOV | Chính xác, giữ cỡ | 1.45 s (5.5×) | 11.3 MB | 240/240, khoảng cách đầu 16.7 ms | 4.28 | dài 7.97 s (đoạn 8.00 s, -34 ms), lệch -17.2 ms (1 khung = 33.3 ms), khớp sóng 0.98 | hvc1 8-bit, CHẤT LƯỢNG GIẢM RÕ: 11.8 Mb/s so với 13.0 Mb/s của nguồn | Đạt |
| IMG_8196.MOV | Chính xác, đổi sang HEVC | 1.45 s (5.5×) | 11.3 MB | 240/240, khoảng cách đầu 16.7 ms | 4.28 | dài 7.97 s (đoạn 8.00 s, -34 ms), lệch -17.2 ms (1 khung = 33.3 ms), khớp sóng 0.98 | hvc1 8-bit, CHẤT LƯỢNG GIẢM RÕ: 11.8 Mb/s so với 13.0 Mb/s của nguồn | Đạt |
| IMG_8196.MOV | Chính xác + tăng sáng 0,15 | 1.45 s (5.5×) | 12.7 MB | 240/240, khoảng cách đầu 33.3 ms | sáng hơn 16.1 | dài 8.00 s (đoạn 8.00 s, -1 ms), lệch -17.2 ms (1 khung = 33.3 ms), khớp sóng 0.98 | avc1 8-bit, xoay 90°→0° (hiển thị vẫn 1440×1920) | Đạt |
| IMG_8196.MOV | Chính xác, lật ngang (qua compositor) | 1.45 s (5.5×) | 11.3 MB | 240/240, khoảng cách đầu 33.3 ms | nan | dài 8.00 s (đoạn 8.00 s, -1 ms), lệch -17.2 ms (1 khung = 33.3 ms), khớp sóng 0.98 | hvc1 8-bit, khung đầu/giữa/cuối lệch so với nguồn: [0, 0, 0] khung, xoay 90°→0° (hiển thị vẫn 1440×1920) | Đạt |
| IMG_8375.mov | Cắt nhanh | 0.02 s (466.2×) | 14.8 MB | 240/240, khoảng cách đầu 16.7 ms | 0.00 | dài 7.97 s (đoạn 8.00 s, -34 ms), lệch -17.2 ms (1 khung = 33.3 ms), khớp sóng 1.00, gói tiếng sao chép nguyên byte | avc1 8-bit | Đạt |
| IMG_8375.mov | Chính xác, giữ cỡ | 1.12 s (7.1×) | 13.1 MB | 240/240, khoảng cách đầu 16.7 ms | 1.26 | dài 7.97 s (đoạn 8.00 s, -34 ms), lệch -17.2 ms (1 khung = 33.3 ms), khớp sóng 0.99 | avc1 8-bit | Đạt |
| IMG_8375.mov | Chính xác, đổi sang HEVC | 1.15 s (7.0×) | 8.5 MB | 240/240, khoảng cách đầu 16.7 ms | 1.06 | dài 7.97 s (đoạn 8.00 s, -34 ms), lệch -17.4 ms (1 khung = 33.3 ms), khớp sóng 0.99 | hvc1 8-bit | Đạt |
| IMG_8375.mov | Chính xác + tăng sáng 0,15 | 1.13 s (7.1×) | 13.1 MB | 240/240, khoảng cách đầu 33.3 ms | sáng hơn 16.2 | dài 8.00 s (đoạn 8.00 s, -1 ms), lệch -17.2 ms (1 khung = 33.3 ms), khớp sóng 0.99 | avc1 8-bit | Đạt |
| IMG_8375.mov | Chính xác, lật ngang (qua compositor) | 1.14 s (7.0×) | 13.1 MB | 240/240, khoảng cách đầu 33.3 ms | nan | dài 8.00 s (đoạn 8.00 s, -1 ms), lệch -17.4 ms (1 khung = 33.3 ms), khớp sóng 0.99 | avc1 8-bit, khung đầu/giữa/cuối lệch so với nguồn: [0, 0, 0] khung | Đạt |
| ScreenRecording_02-06-2025 15-18-41_1.MOV | Cắt nhanh | 0.02 s (205.8×) | 7.8 MB | 205/205, khoảng cách đầu 8.3 ms | 0.00 | dài 3.39 s (đoạn 3.42 s, -25 ms), im lặng nên không đo được độ lệch, gói tiếng KHÔNG phải bản sao | hvc1 8-bit | Đạt |
| ScreenRecording_02-06-2025 15-18-41_1.MOV | Chính xác, giữ cỡ | 0.84 s (4.1×) | 5.8 MB | 205/205, khoảng cách đầu 8.3 ms | 0.95 | dài 3.40 s (đoạn 3.42 s, -17 ms), im lặng nên không đo được độ lệch | hvc1 8-bit | Đạt |
| ScreenRecording_02-06-2025 15-18-41_1.MOV | Chính xác, đổi sang HEVC | 0.84 s (4.1×) | 5.8 MB | 205/205, khoảng cách đầu 8.3 ms | 0.95 | dài 3.40 s (đoạn 3.42 s, -17 ms), im lặng nên không đo được độ lệch | hvc1 8-bit | Đạt |
| ScreenRecording_02-06-2025 15-18-41_1.MOV | Chính xác + tăng sáng 0,15 | 0.83 s (4.1×) | 6.5 MB | 205/205, khoảng cách đầu 16.7 ms | sáng hơn 16.3 | dài 3.42 s (đoạn 3.42 s, +5 ms), im lặng nên không đo được độ lệch | avc1 8-bit | Đạt |
| ScreenRecording_02-06-2025 15-18-41_1.MOV | Chính xác, lật ngang (qua compositor) | 0.86 s (4.0×) | 5.8 MB | 205/205, khoảng cách đầu 16.7 ms | nan | dài 3.42 s (đoạn 3.42 s, +5 ms), im lặng nên không đo được độ lệch | hvc1 8-bit, khung đầu/giữa/cuối lệch so với nguồn: [0, 0, 0] khung | Đạt |
| copy_B70C57A7-B4CC-4B2D-9DAC-1BE07DD6D762.mov | Cắt nhanh | 0.02 s (390.1×) | 11.7 MB | 240/240, khoảng cách đầu 16.7 ms | 0.00 | dài 7.97 s (đoạn 8.00 s, -33 ms), lệch -16.8 ms (1 khung = 33.3 ms), khớp sóng 0.95, gói tiếng sao chép nguyên byte | hvc1 8-bit | Đạt |
| copy_B70C57A7-B4CC-4B2D-9DAC-1BE07DD6D762.mov | Chính xác, giữ cỡ | 1.12 s (7.2×) | 8.5 MB | 240/240, khoảng cách đầu 16.7 ms | 0.97 | dài 7.97 s (đoạn 8.00 s, -34 ms), lệch -16.6 ms (1 khung = 33.3 ms), khớp sóng 0.94 | hvc1 8-bit | Đạt |
| copy_B70C57A7-B4CC-4B2D-9DAC-1BE07DD6D762.mov | Chính xác, đổi sang HEVC | 1.12 s (7.1×) | 8.5 MB | 240/240, khoảng cách đầu 16.7 ms | 0.97 | dài 7.97 s (đoạn 8.00 s, -34 ms), lệch -16.8 ms (1 khung = 33.3 ms), khớp sóng 0.89 | hvc1 8-bit | Đạt |
| copy_B70C57A7-B4CC-4B2D-9DAC-1BE07DD6D762.mov | Chính xác + tăng sáng 0,15 | 1.09 s (7.3×) | 9.5 MB | 240/240, khoảng cách đầu 33.3 ms | sáng hơn 16.4 | dài 8.00 s (đoạn 8.00 s, +0 ms), lệch -16.6 ms (1 khung = 33.3 ms), khớp sóng 0.92 | avc1 8-bit | Đạt |
| copy_B70C57A7-B4CC-4B2D-9DAC-1BE07DD6D762.mov | Chính xác, lật ngang (qua compositor) | 1.14 s (7.0×) | 8.5 MB | 240/240, khoảng cách đầu 33.3 ms | nan | dài 8.00 s (đoạn 8.00 s, +0 ms), lệch -16.8 ms (1 khung = 33.3 ms), khớp sóng 0.93 | hvc1 8-bit, khung đầu/giữa/cuối lệch so với nguồn: [0, 0, 0] khung | Đạt |

