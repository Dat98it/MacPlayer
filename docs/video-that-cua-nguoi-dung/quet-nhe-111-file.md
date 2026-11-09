# MacVideo: kiểm thử trên video thật

Chạy bằng `macvideo-probe realcheck` với `--light` (không phát, không xuất, không quét mọi khung). Video thật (không do MacVideo sinh) nên **không có mã vạch**: chân lý lấy từ chính bảng khung hình, điểm ảnh và âm thanh đã giải mã của file. Một lần tua đúng khi khung trả về mang đúng thời điểm khung đã yêu cầu. Một lần cắt đúng khi file kết quả có đúng các khung của đoạn, liên tục, bắt đầu từ 0, giải mã ra cùng một hình (theo chiều hiển thị) với các khung nguồn tương ứng (sai khác độ sáng trung bình, thang 0–255), và âm thanh dài bằng đoạn cắt, có đường độ to khớp với nguồn.

Máy: Apple M4, macOS 27.0.1. 111 file.

## 1. Các file và việc nhận diện

| File | Định dạng | Khung hình | Loại | Hộp Dolby Vision | Âm thanh | Dung lượng |
|---|---|---|---|---|---|---|
| 1681044598354.MP4 | avc1 8-bit 480×854 | 29.92 fps, 386 khung, 12.9 s, cách khung không đều, cách khung 0.0–66.7 ms | SDR | — | aac 2 kênh 44100 Hz | 1.7 MB |
| 1IJDIJSSS_87D28K.MP4 | avc1 8-bit 720×1280 | 19.95 fps, 302 khung, 15.0 s, VFR, cách khung 0.0–66.7 ms | SDR | — | aac 2 kênh 44100 Hz | 3.8 MB |
| 1IJL1VBDH_7DR920.MP4 | avc1 8-bit 856×480 | 30.00 fps, 15948 khung, 531.6 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | aac 2 kênh 48000 Hz | 47.9 MB |
| 1IJL1VBFM_7DR920.MP4 | avc1 8-bit 856×480 | 30.00 fps, 5306 khung, 176.8 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | aac 2 kênh 48000 Hz | 12.1 MB |
| 1IKOTE83T_5411PF.MP4 | avc1 8-bit 720×1280, xoay 90° | 30.00 fps, 1265 khung, 42.1 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | aac 2 kênh 48000 Hz | 8.2 MB |
| 1IKOVC944_6C2D1L.MP4 | avc1 8-bit 720×1280 | 29.97 fps, 874 khung, 29.1 s, cách khung không đều, cách khung 0.0–66.7 ms | SDR | — | aac 2 kênh 44100 Hz | 7.4 MB |
| 1ILQST8N3_87D28K.MP4 | avc1 8-bit 1280×720 | 30.00 fps, 671 khung, 22.3 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | không có | 5.4 MB |
| 7F332863-4A93-487E-BE04-3F4255DCCFEA.MOV | avc1 8-bit 1024×576 | 30.00 fps, 696 khung, 23.1 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | aac 2 kênh 44100 Hz | 5.0 MB |
| F54C9873-B51A-41D4-93FA-B86ACA7B005D.MOV | avc1 8-bit 576×1024 | 30.00 fps, 135 khung, 4.4 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | aac 2 kênh 44100 Hz | 0.9 MB |
| IMG_0014.MOV | hvc1 10-bit 1920×1080 | 59.91 fps, 1809 khung, 30.2 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 49.0 MB |
| IMG_0025.MOV | hvc1 10-bit 1920×1080 | 59.94 fps, 1931 khung, 32.2 s, cách khung không đều, cách khung 5.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 83.6 MB |
| IMG_0173.MOV | hvc1 10-bit 1920×1080 | 59.94 fps, 1412 khung, 23.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 37.5 MB |
| IMG_0298.MOV | hvc1 8-bit 2160×3840, xoay 90° | 59.96 fps, 412 khung, 6.9 s, cách khung không đều, cách khung 0.0–18.3 ms | SDR | — | aac 2 kênh 44100 Hz | 39.5 MB |
| IMG_0299.MOV | hvc1 8-bit 2160×3840, xoay 90° | 59.95 fps, 674 khung, 11.2 s, VFR, cách khung 0.0–18.3 ms | SDR | — | aac 2 kênh 44100 Hz | 64.9 MB |
| IMG_0510.mov | hvc1 10-bit 1080×1920, xoay 90° | 59.92 fps, 1742 khung, 29.0 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 32.3 MB |
| IMG_0555.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.95 fps, 2726 khung, 45.5 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 77.8 MB |
| IMG_0881.mov | hvc1 10-bit 726×1290, xoay 90° | 59.91 fps, 573 khung, 9.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 24.3 MB |
| IMG_1020.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 345 khung, 5.7 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 9.5 MB |
| IMG_1082.MOV | hvc1 8-bit 1080×1920, xoay 270° | 29.97 fps, 818 khung, 27.3 s, cách khung không đều, cách khung 0.0–35.0 ms | SDR | — | aac 1 kênh 48000 Hz | 32.2 MB |
| IMG_1566.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.92 fps, 1696 khung, 28.3 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 45.2 MB |
| IMG_1955.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 1776 khung, 29.6 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 47.1 MB |
| IMG_1957.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 1498 khung, 25.0 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 39.7 MB |
| IMG_2320.MOV | hvc1 10-bit 1080×1920, xoay 270° | 60.00 fps, 3045 khung, 50.7 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 155.1 MB |
| IMG_2321.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 3465 khung, 57.8 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 146.1 MB |
| IMG_2549.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.92 fps, 1793 khung, 29.9 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 94.2 MB |
| IMG_2612.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.96 fps, 7052 khung, 117.6 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 207.5 MB |
| IMG_2617.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.92 fps, 4774 khung, 79.7 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 247.4 MB |
| IMG_2629.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 1407 khung, 23.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 39.5 MB |
| IMG_2631.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 570 khung, 9.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 15.0 MB |
| IMG_2632.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 3270 khung, 54.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 88.6 MB |
| IMG_2633.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 641 khung, 10.7 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 17.1 MB |
| IMG_2637.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 674 khung, 11.2 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 18.2 MB |
| IMG_2640.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 444 khung, 7.4 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 12.1 MB |
| IMG_2641.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 1275 khung, 21.3 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 34.4 MB |
| IMG_2642.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 1099 khung, 18.3 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 31.2 MB |
| IMG_2647.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 1224 khung, 20.4 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 32.4 MB |
| IMG_2649.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 1031 khung, 17.2 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 27.5 MB |
| IMG_2650.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.92 fps, 2427 khung, 40.5 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 64.8 MB |
| IMG_2663.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 891 khung, 14.8 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 24.0 MB |
| IMG_2664.mov | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 9334 khung, 155.8 s, cách khung không đều, cách khung 1.7–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 261.9 MB |
| IMG_2665.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 4277 khung, 71.4 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 114.9 MB |
| IMG_2681.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 5040 khung, 84.1 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 139.5 MB |
| IMG_2684.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 1333 khung, 22.2 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 36.2 MB |
| IMG_2759.MOV | hvc1 10-bit 1920×1080 | 59.94 fps, 8615 khung, 143.7 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 229.3 MB |
| IMG_2760.MOV | hvc1 10-bit 1920×1080 | 59.94 fps, 1047 khung, 17.4 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 27.8 MB |
| IMG_2761.MOV | hvc1 10-bit 1920×1080 | 59.91 fps, 1290 khung, 21.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 34.3 MB |
| IMG_2763.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 692 khung, 11.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 18.2 MB |
| IMG_2764.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 2667 khung, 44.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 70.7 MB |
| IMG_2766.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 633 khung, 10.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 16.8 MB |
| IMG_2778.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 460 khung, 7.7 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 12.5 MB |
| IMG_2838.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 1096 khung, 18.3 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 29.0 MB |
| IMG_2841.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.96 fps, 439 khung, 7.3 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 15.9 MB |
| IMG_2842.mov | hvc1 10-bit 1080×1920, xoay 90° | 59.96 fps, 645 khung, 10.7 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 26.7 MB |
| IMG_2845.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.96 fps, 3967 khung, 66.1 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 157.6 MB |
| IMG_2888.MOV | hvc1 10-bit 1920×1080 | 59.96 fps, 1651 khung, 27.5 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 86.4 MB |
| IMG_2889.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.96 fps, 1645 khung, 27.4 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 82.6 MB |
| IMG_2892.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.96 fps, 2486 khung, 41.4 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 116.2 MB |
| IMG_2917.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.90 fps, 1000 khung, 16.7 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 26.7 MB |
| IMG_2920.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.92 fps, 1233 khung, 20.6 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 34.2 MB |
| IMG_2929.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 5792 khung, 96.6 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 235.3 MB |
| IMG_2930.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 1923 khung, 32.1 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 64.1 MB |
| IMG_2934.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 2843 khung, 47.4 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 141.5 MB |
| IMG_2973.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.96 fps, 148 khung, 2.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 9.6 MB |
| IMG_2974.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 1486 khung, 24.8 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 66.7 MB |
| IMG_3011.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 812 khung, 13.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 39.3 MB |
| IMG_3027.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.95 fps, 403 khung, 6.7 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 16.9 MB |
| IMG_3181.MOV | hvc1 8-bit 1920×1440 | 30.00 fps, 478 khung, 15.9 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 20.4 MB |
| IMG_3188.mov | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 442 khung, 14.7 s, cách khung không đều, cách khung 1.7–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 19.3 MB |
| IMG_3945.MOV | hvc1 10-bit 2160×3840, xoay 90° | 59.99 fps, 597 khung, 9.9 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 63.1 MB |
| IMG_3947.MOV | hvc1 10-bit 2160×3840, xoay 90° | 59.99 fps, 559 khung, 9.3 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 59.3 MB |
| IMG_4627.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.96 fps, 2178 khung, 36.3 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 86.3 MB |
| IMG_7745.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 893 khung, 14.9 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 24.4 MB |
| IMG_7836.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 482 khung, 16.0 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 20.6 MB |
| IMG_7837.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 1383 khung, 46.1 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 62.8 MB |
| IMG_7838.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 790 khung, 26.3 s, cách khung không đều, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 36.0 MB |
| IMG_7949.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 417 khung, 13.9 s, cách khung không đều, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 17.7 MB |
| IMG_7955.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 899 khung, 29.9 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 39.1 MB |
| IMG_8034.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 860 khung, 28.6 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 36.7 MB |
| IMG_8058.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 294 khung, 9.8 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 18.1 MB |
| IMG_8059.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 163 khung, 5.4 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | lpcm 1 kênh 44100 Hz | 7.0 MB |
| IMG_8060.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 334 khung, 11.1 s, cách khung không đều, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 14.3 MB |
| IMG_8088.MOV | hvc1 10-bit 1920×1080 | 59.96 fps, 451 khung, 7.5 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 17.9 MB |
| IMG_8154.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 90 khung, 3.0 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | lpcm 1 kênh 44100 Hz | 3.9 MB |
| IMG_8163.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 428 khung, 14.2 s, cách khung không đều, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 27.1 MB |
| IMG_8164.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 395 khung, 13.1 s, cách khung không đều, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 16.8 MB |
| IMG_8165.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 290 khung, 9.6 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 12.2 MB |
| IMG_8193.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 945 khung, 31.5 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 44.4 MB |
| IMG_8195.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 1155 khung, 38.5 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 59.4 MB |
| IMG_8196.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 702 khung, 23.4 s, cách khung không đều, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 38.3 MB |
| IMG_8197.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 199 khung, 6.6 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 11.6 MB |
| IMG_8198.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 357 khung, 11.9 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 22.4 MB |
| IMG_8205.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 717 khung, 23.9 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 30.5 MB |
| IMG_8259.MOV | hvc1 10-bit 1920×1080 | 59.91 fps, 1128 khung, 18.8 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 30.2 MB |
| IMG_8285.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 165 khung, 5.5 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | lpcm 1 kênh 44100 Hz | 7.1 MB |
| IMG_8363.MOV | hvc1 8-bit 1440×1920, xoay 90° | 30.00 fps, 187 khung, 6.2 s, VFR, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 8.0 MB |
| IMG_8373.mov | hvc1 8-bit 1920×1440 | 30.00 fps, 236 khung, 7.8 s, VFR, cách khung 3.3–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 10.8 MB |
| IMG_8374.MOV | hvc1 8-bit 1920×1440 | 30.00 fps, 384 khung, 12.8 s, cách khung không đều, cách khung 0.0–35.0 ms | SDR | — | lpcm 1 kênh 44100 Hz | 16.4 MB |
| IMG_8375.mov | avc1 8-bit 1920×1080 | 30.00 fps, 866 khung, 28.8 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | aac 2 kênh 44100 Hz | 52.1 MB |
| IMG_9019.MOV | hvc1 10-bit 1920×1080 | 59.94 fps, 437 khung, 7.3 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 11.9 MB |
| IMG_9022.MOV | hvc1 10-bit 1920×1080 | 59.93 fps, 656 khung, 10.9 s, VFR, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 17.5 MB |
| IMG_9074.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 479 khung, 8.0 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 13.9 MB |
| IMG_9119.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.92 fps, 804 khung, 13.4 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 42.2 MB |
| IMG_9120.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.92 fps, 1009 khung, 16.8 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 53.2 MB |
| IMG_9142.mov | hvc1 10-bit 1920×1080 | 59.92 fps, 637 khung, 10.6 s, cách khung không đều, cách khung 8.3–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 17.9 MB |
| IMG_9573.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 2518 khung, 42.0 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 79.5 MB |
| IMG_9576.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 1423 khung, 23.7 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 37.7 MB |
| IMG_9577.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.94 fps, 1935 khung, 32.3 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 59.7 MB |
| IMG_9589.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 1082 khung, 18.0 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 28.7 MB |
| IMG_9664.MOV | hvc1 10-bit 1080×1920, xoay 90° | 59.91 fps, 911 khung, 15.2 s, cách khung không đều, cách khung 0.0–18.3 ms | HDR (ITU_R_2100_HLG) | dvvC | aac 2 kênh 44100 Hz | 29.6 MB |
| ScreenRecording_02-06-2025 15-18-41_1.MOV | hvc1 8-bit 888×1920 | 59.88 fps, 547 khung, 9.1 s, cách khung không đều, cách khung 0.0–18.3 ms | SDR | — | aac 2 kênh 44100 Hz | 17.6 MB |
| copy_B70C57A7-B4CC-4B2D-9DAC-1BE07DD6D762.mov | hvc1 8-bit 1080×1846 | 30.00 fps, 966 khung, 32.2 s, cách khung không đều, cách khung 0.0–33.3 ms | SDR | — | aac 2 kênh 44100 Hz | 43.1 MB |

## 2. Mở: thời gian tới khung hình đầu

| File | Trung vị | p95 | Có hình | p95 < 2 s |
|---|---|---|---|---|
| 1681044598354.MP4 | 14 ms | 135 ms | 3/3 | Đạt |
| 1IJDIJSSS_87D28K.MP4 | 14 ms | 16 ms | 3/3 | Đạt |
| 1IJL1VBDH_7DR920.MP4 | 17 ms | 17 ms | 3/3 | Đạt |
| 1IJL1VBFM_7DR920.MP4 | 16 ms | 20 ms | 3/3 | Đạt |
| 1IKOTE83T_5411PF.MP4 | 13 ms | 16 ms | 3/3 | Đạt |
| 1IKOVC944_6C2D1L.MP4 | 14 ms | 16 ms | 3/3 | Đạt |
| 1ILQST8N3_87D28K.MP4 | 11 ms | 13 ms | 3/3 | Đạt |
| 7F332863-4A93-487E-BE04-3F4255DCCFEA.MOV | 11 ms | 17 ms | 3/3 | Đạt |
| F54C9873-B51A-41D4-93FA-B86ACA7B005D.MOV | 13 ms | 14 ms | 3/3 | Đạt |
| IMG_0014.MOV | 20 ms | 23 ms | 3/3 | Đạt |
| IMG_0025.MOV | 26 ms | 31 ms | 3/3 | Đạt |
| IMG_0173.MOV | 18 ms | 23 ms | 3/3 | Đạt |
| IMG_0298.MOV | 27 ms | 33 ms | 3/3 | Đạt |
| IMG_0299.MOV | 28 ms | 28 ms | 3/3 | Đạt |
| IMG_0510.mov | 17 ms | 20 ms | 3/3 | Đạt |
| IMG_0555.MOV | 21 ms | 27 ms | 3/3 | Đạt |
| IMG_0881.mov | 17 ms | 17 ms | 3/3 | Đạt |
| IMG_1020.MOV | 23 ms | 24 ms | 3/3 | Đạt |
| IMG_1082.MOV | 16 ms | 19 ms | 3/3 | Đạt |
| IMG_1566.MOV | 20 ms | 23 ms | 3/3 | Đạt |
| IMG_1955.MOV | 20 ms | 25 ms | 3/3 | Đạt |
| IMG_1957.MOV | 18 ms | 18 ms | 3/3 | Đạt |
| IMG_2320.MOV | 15 ms | 19 ms | 3/3 | Đạt |
| IMG_2321.MOV | 17 ms | 19 ms | 3/3 | Đạt |
| IMG_2549.MOV | 17 ms | 20 ms | 3/3 | Đạt |
| IMG_2612.MOV | 29 ms | 32 ms | 3/3 | Đạt |
| IMG_2617.MOV | 24 ms | 27 ms | 3/3 | Đạt |
| IMG_2629.MOV | 22 ms | 23 ms | 3/3 | Đạt |
| IMG_2631.MOV | 22 ms | 26 ms | 3/3 | Đạt |
| IMG_2632.MOV | 27 ms | 30 ms | 3/3 | Đạt |
| IMG_2633.MOV | 20 ms | 31 ms | 3/3 | Đạt |
| IMG_2637.MOV | 21 ms | 26 ms | 3/3 | Đạt |
| IMG_2640.MOV | 18 ms | 20 ms | 3/3 | Đạt |
| IMG_2641.MOV | 20 ms | 22 ms | 3/3 | Đạt |
| IMG_2642.MOV | 25 ms | 25 ms | 3/3 | Đạt |
| IMG_2647.MOV | 23 ms | 25 ms | 3/3 | Đạt |
| IMG_2649.MOV | 23 ms | 24 ms | 3/3 | Đạt |
| IMG_2650.MOV | 19 ms | 20 ms | 3/3 | Đạt |
| IMG_2663.MOV | 19 ms | 23 ms | 3/3 | Đạt |
| IMG_2664.mov | 28 ms | 29 ms | 3/3 | Đạt |
| IMG_2665.MOV | 22 ms | 23 ms | 3/3 | Đạt |
| IMG_2681.MOV | 25 ms | 26 ms | 3/3 | Đạt |
| IMG_2684.MOV | 22 ms | 25 ms | 3/3 | Đạt |
| IMG_2759.MOV | 29 ms | 30 ms | 3/3 | Đạt |
| IMG_2760.MOV | 21 ms | 23 ms | 3/3 | Đạt |
| IMG_2761.MOV | 19 ms | 20 ms | 3/3 | Đạt |
| IMG_2763.MOV | 21 ms | 23 ms | 3/3 | Đạt |
| IMG_2764.MOV | 20 ms | 22 ms | 3/3 | Đạt |
| IMG_2766.MOV | 16 ms | 20 ms | 3/3 | Đạt |
| IMG_2778.MOV | 18 ms | 20 ms | 3/3 | Đạt |
| IMG_2838.MOV | 22 ms | 24 ms | 3/3 | Đạt |
| IMG_2841.MOV | 21 ms | 24 ms | 3/3 | Đạt |
| IMG_2842.mov | 18 ms | 20 ms | 3/3 | Đạt |
| IMG_2845.MOV | 22 ms | 28 ms | 3/3 | Đạt |
| IMG_2888.MOV | 21 ms | 23 ms | 3/3 | Đạt |
| IMG_2889.MOV | 22 ms | 28 ms | 3/3 | Đạt |
| IMG_2892.MOV | 19 ms | 29 ms | 3/3 | Đạt |
| IMG_2917.MOV | 20 ms | 26 ms | 3/3 | Đạt |
| IMG_2920.MOV | 16 ms | 20 ms | 3/3 | Đạt |
| IMG_2929.MOV | 16 ms | 17 ms | 3/3 | Đạt |
| IMG_2930.MOV | 17 ms | 17 ms | 3/3 | Đạt |
| IMG_2934.MOV | 19 ms | 19 ms | 3/3 | Đạt |
| IMG_2973.MOV | 17 ms | 20 ms | 3/3 | Đạt |
| IMG_2974.MOV | 17 ms | 18 ms | 3/3 | Đạt |
| IMG_3011.MOV | 16 ms | 16 ms | 3/3 | Đạt |
| IMG_3027.MOV | 16 ms | 18 ms | 3/3 | Đạt |
| IMG_3181.MOV | 18 ms | 18 ms | 3/3 | Đạt |
| IMG_3188.mov | 17 ms | 21 ms | 3/3 | Đạt |
| IMG_3945.MOV | 33 ms | 34 ms | 3/3 | Đạt |
| IMG_3947.MOV | 29 ms | 31 ms | 3/3 | Đạt |
| IMG_4627.MOV | 19 ms | 41 ms | 3/3 | Đạt |
| IMG_7745.MOV | 16 ms | 20 ms | 3/3 | Đạt |
| IMG_7836.MOV | 15 ms | 18 ms | 3/3 | Đạt |
| IMG_7837.MOV | 16 ms | 19 ms | 3/3 | Đạt |
| IMG_7838.MOV | 17 ms | 19 ms | 3/3 | Đạt |
| IMG_7949.MOV | 16 ms | 18 ms | 3/3 | Đạt |
| IMG_7955.MOV | 15 ms | 17 ms | 3/3 | Đạt |
| IMG_8034.MOV | 16 ms | 18 ms | 3/3 | Đạt |
| IMG_8058.MOV | 17 ms | 18 ms | 3/3 | Đạt |
| IMG_8059.MOV | 17 ms | 17 ms | 3/3 | Đạt |
| IMG_8060.MOV | 16 ms | 17 ms | 3/3 | Đạt |
| IMG_8088.MOV | 16 ms | 20 ms | 3/3 | Đạt |
| IMG_8154.MOV | 17 ms | 19 ms | 3/3 | Đạt |
| IMG_8163.MOV | 15 ms | 17 ms | 3/3 | Đạt |
| IMG_8164.MOV | 17 ms | 19 ms | 3/3 | Đạt |
| IMG_8165.MOV | 17 ms | 17 ms | 3/3 | Đạt |
| IMG_8193.MOV | 16 ms | 18 ms | 3/3 | Đạt |
| IMG_8195.MOV | 17 ms | 20 ms | 3/3 | Đạt |
| IMG_8196.MOV | 15 ms | 19 ms | 3/3 | Đạt |
| IMG_8197.MOV | 16 ms | 21 ms | 3/3 | Đạt |
| IMG_8198.MOV | 15 ms | 17 ms | 3/3 | Đạt |
| IMG_8205.MOV | 16 ms | 20 ms | 3/3 | Đạt |
| IMG_8259.MOV | 15 ms | 21 ms | 3/3 | Đạt |
| IMG_8285.MOV | 17 ms | 18 ms | 3/3 | Đạt |
| IMG_8363.MOV | 17 ms | 19 ms | 3/3 | Đạt |
| IMG_8373.mov | 16 ms | 19 ms | 3/3 | Đạt |
| IMG_8374.MOV | 16 ms | 20 ms | 3/3 | Đạt |
| IMG_8375.mov | 19 ms | 19 ms | 3/3 | Đạt |
| IMG_9019.MOV | 20 ms | 25 ms | 3/3 | Đạt |
| IMG_9022.MOV | 14 ms | 19 ms | 3/3 | Đạt |
| IMG_9074.MOV | 15 ms | 20 ms | 3/3 | Đạt |
| IMG_9119.MOV | 19 ms | 20 ms | 3/3 | Đạt |
| IMG_9120.MOV | 16 ms | 17 ms | 3/3 | Đạt |
| IMG_9142.mov | 18 ms | 20 ms | 3/3 | Đạt |
| IMG_9573.MOV | 15 ms | 16 ms | 3/3 | Đạt |
| IMG_9576.MOV | 18 ms | 19 ms | 3/3 | Đạt |
| IMG_9577.MOV | 17 ms | 19 ms | 3/3 | Đạt |
| IMG_9589.MOV | 16 ms | 18 ms | 3/3 | Đạt |
| IMG_9664.MOV | 19 ms | 19 ms | 3/3 | Đạt |
| ScreenRecording_02-06-2025 15-18-41_1.MOV | 16 ms | 18 ms | 3/3 | Đạt |
| copy_B70C57A7-B4CC-4B2D-9DAC-1BE07DD6D762.mov | 16 ms | 17 ms | 3/3 | Đạt |

## 3. Tua chính xác tới một khung bất kỳ

8 khung ngẫu nhiên mỗi file; thời điểm yêu cầu là thời điểm thật của khung trong bảng mẫu. “Sai” = khung trả về có thời điểm khác khung yêu cầu quá nửa khoảng cách tới khung kề (với VFR, khoảng cách thật của khung đó).

| File | Trung vị | p95 | Chậm nhất | Sai |
|---|---|---|---|---|
| 1681044598354.MP4 | 7 ms | 10 ms | 10 ms | 0/8 |
| 1IJDIJSSS_87D28K.MP4 | 7 ms | 16 ms | 16 ms | 0/8 |
| 1IJL1VBDH_7DR920.MP4 | 7 ms | 10 ms | 10 ms | 0/8 |
| 1IJL1VBFM_7DR920.MP4 | 7 ms | 10 ms | 10 ms | 0/8 |
| 1IKOTE83T_5411PF.MP4 | 9 ms | 19 ms | 19 ms | 0/8 |
| 1IKOVC944_6C2D1L.MP4 | 6 ms | 14 ms | 14 ms | 0/8 |
| 1ILQST8N3_87D28K.MP4 | 18 ms | 22 ms | 22 ms | 0/8 |
| 7F332863-4A93-487E-BE04-3F4255DCCFEA.MOV | 5 ms | 8 ms | 8 ms | 0/8 |
| F54C9873-B51A-41D4-93FA-B86ACA7B005D.MOV | 4 ms | 5 ms | 5 ms | 0/8 |
| IMG_0014.MOV | 10 ms | 16 ms | 16 ms | 0/8 |
| IMG_0025.MOV | 13 ms | 16 ms | 16 ms | 0/8 |
| IMG_0173.MOV | 10 ms | 12 ms | 12 ms | 0/8 |
| IMG_0298.MOV | 29 ms | 40 ms | 40 ms | 0/8 |
| IMG_0299.MOV | 31 ms | 47 ms | 47 ms | 0/8 |
| IMG_0510.mov | 13 ms | 14 ms | 14 ms | 0/8 |
| IMG_0555.MOV | 12 ms | 18 ms | 18 ms | 0/8 |
| IMG_0881.mov | 6 ms | 7 ms | 7 ms | 0/8 |
| IMG_1020.MOV | 9 ms | 14 ms | 14 ms | 0/8 |
| IMG_1082.MOV | 6 ms | 7 ms | 7 ms | 0/8 |
| IMG_1566.MOV | 12 ms | 14 ms | 14 ms | 0/8 |
| IMG_1955.MOV | 11 ms | 13 ms | 13 ms | 0/8 |
| IMG_1957.MOV | 9 ms | 11 ms | 11 ms | 0/8 |
| IMG_2320.MOV | 11 ms | 12 ms | 12 ms | 0/8 |
| IMG_2321.MOV | 9 ms | 14 ms | 14 ms | 0/8 |
| IMG_2549.MOV | 10 ms | 12 ms | 12 ms | 0/8 |
| IMG_2612.MOV | 7 ms | 11 ms | 11 ms | 0/8 |
| IMG_2617.MOV | 10 ms | 13 ms | 13 ms | 0/8 |
| IMG_2629.MOV | 10 ms | 13 ms | 13 ms | 0/8 |
| IMG_2631.MOV | 10 ms | 14 ms | 14 ms | 0/8 |
| IMG_2632.MOV | 11 ms | 14 ms | 14 ms | 0/8 |
| IMG_2633.MOV | 10 ms | 15 ms | 15 ms | 0/8 |
| IMG_2637.MOV | 10 ms | 15 ms | 15 ms | 0/8 |
| IMG_2640.MOV | 8 ms | 12 ms | 12 ms | 0/8 |
| IMG_2641.MOV | 12 ms | 15 ms | 15 ms | 0/8 |
| IMG_2642.MOV | 9 ms | 12 ms | 12 ms | 0/8 |
| IMG_2647.MOV | 9 ms | 15 ms | 15 ms | 0/8 |
| IMG_2649.MOV | 10 ms | 15 ms | 15 ms | 0/8 |
| IMG_2650.MOV | 11 ms | 13 ms | 13 ms | 0/8 |
| IMG_2663.MOV | 8 ms | 13 ms | 13 ms | 0/8 |
| IMG_2664.mov | 10 ms | 12 ms | 12 ms | 0/8 |
| IMG_2665.MOV | 10 ms | 15 ms | 15 ms | 0/8 |
| IMG_2681.MOV | 11 ms | 13 ms | 13 ms | 0/8 |
| IMG_2684.MOV | 10 ms | 15 ms | 15 ms | 0/8 |
| IMG_2759.MOV | 8 ms | 15 ms | 15 ms | 0/8 |
| IMG_2760.MOV | 7 ms | 14 ms | 14 ms | 0/8 |
| IMG_2761.MOV | 8 ms | 13 ms | 13 ms | 0/8 |
| IMG_2763.MOV | 8 ms | 11 ms | 11 ms | 0/8 |
| IMG_2764.MOV | 8 ms | 13 ms | 13 ms | 0/8 |
| IMG_2766.MOV | 8 ms | 15 ms | 15 ms | 0/8 |
| IMG_2778.MOV | 8 ms | 11 ms | 11 ms | 0/8 |
| IMG_2838.MOV | 9 ms | 14 ms | 14 ms | 0/8 |
| IMG_2841.MOV | 7 ms | 12 ms | 12 ms | 0/8 |
| IMG_2842.mov | 5 ms | 9 ms | 9 ms | 0/8 |
| IMG_2845.MOV | 8 ms | 13 ms | 13 ms | 0/8 |
| IMG_2888.MOV | 11 ms | 12 ms | 12 ms | 0/8 |
| IMG_2889.MOV | 9 ms | 10 ms | 10 ms | 0/8 |
| IMG_2892.MOV | 10 ms | 12 ms | 12 ms | 0/8 |
| IMG_2917.MOV | 6 ms | 12 ms | 12 ms | 0/8 |
| IMG_2920.MOV | 8 ms | 13 ms | 13 ms | 0/8 |
| IMG_2929.MOV | 9 ms | 12 ms | 12 ms | 0/8 |
| IMG_2930.MOV | 7 ms | 12 ms | 12 ms | 0/8 |
| IMG_2934.MOV | 11 ms | 14 ms | 14 ms | 0/8 |
| IMG_2973.MOV | 7 ms | 10 ms | 10 ms | 0/8 |
| IMG_2974.MOV | 10 ms | 12 ms | 12 ms | 0/8 |
| IMG_3011.MOV | 11 ms | 13 ms | 13 ms | 0/8 |
| IMG_3027.MOV | 9 ms | 13 ms | 13 ms | 0/8 |
| IMG_3181.MOV | 9 ms | 10 ms | 10 ms | 0/8 |
| IMG_3188.mov | 9 ms | 14 ms | 14 ms | 0/8 |
| IMG_3945.MOV | 25 ms | 36 ms | 36 ms | 0/8 |
| IMG_3947.MOV | 25 ms | 35 ms | 35 ms | 0/8 |
| IMG_4627.MOV | 8 ms | 13 ms | 13 ms | 0/8 |
| IMG_7745.MOV | 13 ms | 16 ms | 16 ms | 0/8 |
| IMG_7836.MOV | 7 ms | 12 ms | 12 ms | 0/8 |
| IMG_7837.MOV | 9 ms | 11 ms | 11 ms | 0/8 |
| IMG_7838.MOV | 10 ms | 12 ms | 12 ms | 0/8 |
| IMG_7949.MOV | 7 ms | 14 ms | 14 ms | 0/8 |
| IMG_7955.MOV | 9 ms | 10 ms | 10 ms | 0/8 |
| IMG_8034.MOV | 7 ms | 9 ms | 9 ms | 0/8 |
| IMG_8058.MOV | 7 ms | 8 ms | 8 ms | 0/8 |
| IMG_8059.MOV | 10 ms | 16 ms | 16 ms | 0/8 |
| IMG_8060.MOV | 10 ms | 16 ms | 16 ms | 0/8 |
| IMG_8088.MOV | 8 ms | 15 ms | 15 ms | 0/8 |
| IMG_8154.MOV | 7 ms | 9 ms | 9 ms | 0/8 |
| IMG_8163.MOV | 8 ms | 12 ms | 12 ms | 0/8 |
| IMG_8164.MOV | 8 ms | 12 ms | 12 ms | 0/8 |
| IMG_8165.MOV | 7 ms | 11 ms | 11 ms | 0/8 |
| IMG_8193.MOV | 8 ms | 14 ms | 14 ms | 0/8 |
| IMG_8195.MOV | 10 ms | 12 ms | 12 ms | 0/8 |
| IMG_8196.MOV | 8 ms | 13 ms | 13 ms | 0/8 |
| IMG_8197.MOV | 10 ms | 13 ms | 13 ms | 0/8 |
| IMG_8198.MOV | 10 ms | 13 ms | 13 ms | 0/8 |
| IMG_8205.MOV | 8 ms | 11 ms | 11 ms | 0/8 |
| IMG_8259.MOV | 7 ms | 12 ms | 12 ms | 0/8 |
| IMG_8285.MOV | 9 ms | 13 ms | 13 ms | 0/8 |
| IMG_8363.MOV | 7 ms | 14 ms | 14 ms | 0/8 |
| IMG_8373.mov | 10 ms | 13 ms | 13 ms | 0/8 |
| IMG_8374.MOV | 8 ms | 10 ms | 10 ms | 0/8 |
| IMG_8375.mov | 8 ms | 14 ms | 14 ms | 0/8 |
| IMG_9019.MOV | 12 ms | 16 ms | 16 ms | 0/8 |
| IMG_9022.MOV | 8 ms | 17 ms | 17 ms | 0/8 |
| IMG_9074.MOV | 10 ms | 13 ms | 13 ms | 0/8 |
| IMG_9119.MOV | 12 ms | 15 ms | 15 ms | 0/8 |
| IMG_9120.MOV | 8 ms | 14 ms | 14 ms | 0/8 |
| IMG_9142.mov | 10 ms | 14 ms | 14 ms | 0/8 |
| IMG_9573.MOV | 9 ms | 13 ms | 13 ms | 0/8 |
| IMG_9576.MOV | 10 ms | 13 ms | 13 ms | 0/8 |
| IMG_9577.MOV | 11 ms | 14 ms | 14 ms | 0/8 |
| IMG_9589.MOV | 7 ms | 16 ms | 16 ms | 0/8 |
| IMG_9664.MOV | 9 ms | 15 ms | 15 ms | 0/8 |
| ScreenRecording_02-06-2025 15-18-41_1.MOV | 7 ms | 9 ms | 9 ms | 0/8 |
| copy_B70C57A7-B4CC-4B2D-9DAC-1BE07DD6D762.mov | 7 ms | 10 ms | 10 ms | 0/8 |

