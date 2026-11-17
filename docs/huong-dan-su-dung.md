# Hướng dẫn sử dụng MacPlayer 0.21

MacPlayer là ứng dụng xem và chỉnh sửa **video, ảnh và nhạc** trên Mac. Mọi việc đều chạy ngay trên máy: không cần tài khoản, không gửi video, ảnh hay giọng nói của bạn đi đâu. App chỉ dùng mạng khi bạn tự dán một link video/ảnh để xem.

Tài liệu này đi theo thứ tự bạn thường dùng: mở app → xem → tạo dự án → dựng video → xuất. Cuối tài liệu có bảng phím tắt và mục xử lý sự cố.

---

## Mục lục

1. [Cài đặt và mở app lần đầu](#1-cài-đặt-và-mở-app-lần-đầu)
2. [Trang chủ, ngôn ngữ và cài đặt](#2-trang-chủ-ngôn-ngữ-và-cài-đặt)
3. [Xem video, ảnh, nhạc và link](#3-xem-video-ảnh-nhạc-và-link)
4. [Danh sách phát](#4-danh-sách-phát)
5. [Dự án: tạo, lưu, mở lại](#5-dự-án-tạo-lưu-mở-lại)
6. [Màn hình dựng video](#6-màn-hình-dựng-video)
7. [Timeline: cắt, tách, sắp xếp](#7-timeline-cắt-tách-sắp-xếp)
8. [Chỉnh từng đoạn video](#8-chỉnh-từng-đoạn-video)
9. [Chữ, hình và nhãn dán](#9-chữ-hình-và-nhãn-dán)
10. [Lớp ảnh và lớp video (logo, hình trong hình)](#10-lớp-ảnh-và-lớp-video-logo-hình-trong-hình)
11. [Âm thanh, nhạc và giọng đọc](#11-âm-thanh-nhạc-và-giọng-đọc)
12. [Phụ đề](#12-phụ-đề)
13. [Xuất video](#13-xuất-video)
14. [Dự án ảnh](#14-dự-án-ảnh)
15. [Phím tắt](#15-phím-tắt)
16. [An toàn dữ liệu và xử lý sự cố](#16-an-toàn-dữ-liệu-và-xử-lý-sự-cố)

---

## 1. Cài đặt và mở app lần đầu

**Yêu cầu:** macOS 15 trở lên. App mới được kiểm thử trên máy Apple Silicon (M1, M2, M3…); máy Intel chưa được thử.

1. Mở file `MacPlayer-0.21.1.dmg` (hoặc giải nén file `.zip`).
2. Kéo **MacPlayer** vào thư mục **Applications**.
3. Lần đầu mở, macOS có thể chặn vì app chưa được Apple kiểm duyệt (notarize). Chuột phải vào MacPlayer ▸ **Mở**, hoặc vào **Cài đặt hệ thống ▸ Quyền riêng tư & Bảo mật ▸ Vẫn mở**.

Muốn chắc file tải về không bị đổi, so mã SHA-256 theo hướng dẫn trong [MacPlayer-Cai-dat-va-chia-se.md](../MacPlayer-Cai-dat-va-chia-se.md).

**Cập nhật lên bản mới:** thoát hẳn MacPlayer (⌘Q), thay app trong Applications bằng bản mới rồi mở lại. Dự án, danh sách phát và cài đặt được giữ nguyên.

---

## 2. Trang chủ, ngôn ngữ và cài đặt

### Trang chủ

Mở app là thấy **Trang chủ** với hai nút lớn:

| Nút | Phím | Dùng để |
|---|---|---|
| **Danh sách phát** | ⌘1 | Xem video, ảnh, nhạc. Không có công cụ chỉnh sửa. |
| **Chỉnh sửa** | ⌘2 | Xem danh sách dự án, tạo dự án mới, dựng video/ảnh. |

Về Trang chủ bất cứ lúc nào: ⇧⌘H hoặc nút 🏠 ở góc trên. Mỗi cửa sổ có màn hình riêng: một cửa sổ có thể đang xem danh sách phát trong khi cửa sổ khác dựng video (⌥⌘N mở cửa sổ mới).

### Đổi ngôn ngữ

**MacPlayer ▸ Ngôn ngữ · Language**, hoặc mục đầu tiên trong **Cài đặt** (⌘,):

- **Theo máy Mac**: theo ngôn ngữ của macOS.
- **English** hoặc **Tiếng Việt**: chọn cố định.

Đổi là có hiệu lực ngay: menu, cửa sổ, mọi bảng đều chuyển, không cần mở lại app. Tên mục ghi cả hai thứ tiếng nên lúc nào cũng tìm thấy.

### Cài đặt (⌘,)

- **Phát:** số giây mỗi lần tua bằng mũi tên (và ⇧ + mũi tên), số giây mỗi ảnh khi trình chiếu, giữ cao độ giọng khi đổi tốc độ, giữ cửa sổ luôn nằm trên, nhớ vị trí đã xem từng video và cách mở lại (hỏi / luôn xem tiếp / luôn xem từ đầu), xoá lịch sử vị trí.
- **Lưu trữ:** chữ thêm vào tên bản sao.
- **Bộ nhớ:** số lượt xuất chạy cùng lúc, dung lượng dữ liệu khôi phục và nút xoá dữ liệu khôi phục.
- **Quyền riêng tư** và **Phím tắt**.

---

## 3. Xem video, ảnh, nhạc và link

### Mở một file

Bấm đúp file trong Finder, chuột phải ▸ **Mở bằng ▸ MacPlayer**, hoặc **Tệp ▸ Mở…** (⌘O). Một file mở lẻ phát trong **cửa sổ phát riêng**: chỉ có hình và nút điều khiển, cửa sổ tự canh theo tỉ lệ video. Thanh trên ghi tên file, độ phân giải, fps, thời lượng, dung lượng; có nút **Chỉnh sửa** và menu **⋯** (Hiện trong Finder, Sao chép đường dẫn, Đổi tên, Chuyển vào Thùng rác).

Định dạng mở được là những gì macOS hỗ trợ: video MP4/MOV (H.264, HEVC, kể cả HDR); nhạc MP3, M4A/AAC, ALAC, FLAC, WAV, AIFF, CAF, Ogg; ảnh JPEG, PNG, HEIC, TIFF, GIF, WebP, AVIF, ảnh RAW. **MKV, WebM, AVI, WMA chưa hỗ trợ** (app báo rõ).

### Điều khiển khi phát

Space phát/dừng · ← → tua (⇧ để tua dài) · `,` `.` lùi/tiến một khung · `-` `=` chậm/nhanh hơn · F toàn màn hình · J lùi, K dừng, L tiến. Có nút chọn tốc độ, lặp lại và âm lượng.

### Nhạc

File nhạc mở lẻ hiện **ảnh bìa**, tên bài, nghệ sĩ, album (đọc từ thẻ của file) trên nền mờ, với dạng sóng để tua.

### Ảnh và ảnh động

Ảnh hiện vừa khung. Thu phóng bằng hai ngón, ⌘ + cuộn hoặc nút; kéo để di chuyển; bấm đúp để xem 100 %. GIF, PNG động, WebP động được phát (có nút tạm dừng).

### Mở link (⌘U)

**Tệp ▸ Mở link…** rồi dán link **trực tiếp tới file** (`.mp4`, `.mov`, `.mp3`, `.m3u8` kể cả phát trực tiếp, `.jpg`, `.png`, `.gif`…). App kiểm tra link ngay khi dán:

- Link trang xem của YouTube, Facebook, TikTok, Instagram, Google Drive không phải là file, app sẽ báo.
- Link chia sẻ Dropbox được tự đổi sang dạng tải thẳng.
- Lỗi 404/403, máy chủ không có… hiện thành câu dễ hiểu.

Khi đang phát link: **Tải về…** để lưu file về máy (mặc định thư mục Tải về, có tiến trình, huỷ được), xong bấm **Mở** để xem bản trên máy (khi đó mới chỉnh sửa được). Luồng phát trực tiếp có nhãn **TRỰC TIẾP**, không tua được. Danh sách **Link gần đây** chỉ lưu trên máy.

### Từ đang xem sang chỉnh sửa

Nút **Chỉnh sửa** (⌘E) trên file đang xem → xác nhận → chọn nơi lưu → app tạo **dự án mới có sẵn file đó** (video → dự án video, ảnh → dự án ảnh, nhạc → dự án video có ảnh bìa) và mở màn hình dựng. Huỷ ở bất kỳ bước nào thì không tạo gì.

---

## 4. Danh sách phát

Vào bằng **Danh sách phát** (⌘1). Thanh bên trái chứa danh sách phát và các file của nó.

- **Tạo:** **Danh sách phát mới** (⇧⌘N) hỏi tên trước. Kéo file hoặc thư mục vào cửa sổ để thêm. **Tệp ▸ Mở thư mục thành danh sách phát…** (⇧⌘O).
- **Cách hiển thị:** Danh sách / Lưới / **Cây thư mục** (thư mục cha ở trên, con thụt vào, mỗi thư mục có số file, mở/đóng từng thư mục). Trong cây, file của mỗi thư mục hiện dạng danh sách hoặc lưới ảnh.
- **Cỡ ảnh xem trước:** thanh trượt dưới hàng sắp xếp (10 mức, được nhớ).
- **Sắp xếp** theo tên, ngày, cỡ, thời lượng, hoặc **Thư mục** (phát đúng thứ tự từ trên xuống của cây). Tìm kiếm không cần gõ dấu.
- **Viền màu:** file đang phát có viền **xanh lá** và biểu tượng loa; file đang được chọn có viền **màu nhấn** và dấu tích.
- **Chọn nhiều:** ⌘-bấm để thêm/bớt, ⇧-bấm để chọn một dải, hoặc Chọn tất cả. Thanh chọn hiện ba nút:
  - **Đổi tên** hàng loạt: đánh số, tìm và thay thế, thêm chữ trước/sau. Xem trước tên cũ → tên mới; tên trùng hoặc không hợp lệ được tô đỏ và **không file nào bị đổi cho đến khi sửa xong**. Nếu ổ đĩa từ chối một file, mọi file đã đổi được trả lại tên cũ.
  - **Thùng rác**: hỏi trước (mặc định là Huỷ), file vào Thùng rác của macOS và lấy lại được. Không bao giờ xoá vĩnh viễn.
  - **Gỡ bỏ**: chỉ bỏ khỏi danh sách, file vẫn còn.
- **Trình chiếu ảnh:** mũi tên trái/phải chuyển ảnh, Space bắt đầu/dừng trình chiếu.
- Danh sách phát **chỉ để xem**. Muốn chỉnh thì dùng nút **Chỉnh sửa** (⌘E).

---

## 5. Dự án: tạo, lưu, mở lại

Vào **Chỉnh sửa** (⌘2) để thấy mọi dự án: thẻ có ảnh đại diện, nhãn **Video/Ảnh**, lọc, sắp xếp, tìm.

### Hai loại dự án

| Loại | Gồm |
|---|---|
| **Dự án video** | Timeline nhiều video và ảnh, lớp phủ, chữ, nhạc, giọng đọc, phụ đề. |
| **Dự án ảnh** | Đúng một ảnh, cộng chữ, hình, nhãn dán và logo. |

**Dự án mới** (⌘N) hỏi loại rồi **luôn hỏi nơi lưu**. Thả sai loại bị chặn kèm lời giải thích (ví dụ thả ảnh vào dự án video thì hỏi "Thêm làm lớp phủ?").

### Tự lưu

Dự án **tự lưu thẳng vào file `.macplayer`** vài giây sau mỗi chỉnh sửa. Thanh trên ghi "Đã lưu 14:02", "Đang lưu…" hoặc "Chưa lưu được". ⌘S lưu ngay.

- File dự án bị app khác sửa thì MacPlayer **không ghi đè**: thanh trên cho chọn giữ chỉnh sửa của bạn hay dùng file trên đĩa.
- Không ghi được (ổ bị rút, chỉ đọc) thì app giữ bản khôi phục trên máy và thử lại; đóng cửa sổ lúc đó sẽ hỏi Thử lại / Lưu vào chỗ khác / Vẫn đóng.
- App tắt đột ngột thì lần mở sau được hỏi khôi phục.

### Quản lý dự án (chuột phải trên thẻ)

Mở · **Đổi tên…** (đổi cả tên file) · Hiện trong Finder · **Chuyển vào Thùng rác…** (chỉ file dự án, video/ảnh không bị đụng) · Bỏ khỏi danh sách.

Dự án bị dời hoặc đổi tên ngoài app vẫn được tìm lại. Ổ chưa cắm hiện "Ổ chưa kết nối"; file đã bị xoá hiện "Không tìm thấy file" kèm **Tìm lại…**.

### Video bị mất

Nếu một video của dự án bị dời hay xoá, app cảnh báo và chờ bạn **Tệp ▸ Liên kết lại…** tới file mới. Xem trước và xuất chờ cho tới khi đủ file.

---

## 6. Màn hình dựng video

```
┌─────────────┬──────────────────────────┬──────────────┐
│  Thư viện   │       Khung xem          │  Thuộc tính  │
│ (bên trái)  │  + nút phát, tốc độ…     │ (bên phải)   │
├─────────────┴──────────────────────────┴──────────────┤
│ Thanh công cụ: Hoàn tác · Làm lại · Tách · Bỏ trước · Bỏ sau · Kéo theo · Nhân đôi · Xóa · Đánh dấu · Chữ · thu phóng │
│ Timeline: Video · Chữ · Lớp 1–3 · Âm thanh                                           │
└───────────────────────────────────────────────────────┘
```

**Thanh trên cùng:** 🏠 Trang chủ · ‹ Dự án · **Quay lại / Tiến lên** (ghi rõ bước sẽ hoàn tác/làm lại) · **Lịch sử** (danh sách các bước, bấm một bước để nhảy thẳng tới đó) · tên dự án (bút chì để đổi tên) · trạng thái lưu · nút **Xuất**.

### Thư viện (bên trái)

| Tab | Có gì | Cách dùng |
|---|---|---|
| **Media** | Video, ảnh, nhạc của dự án | **Nhập media** hoặc kéo từ Finder. Dấu ✓ là file đang được dùng. Bấm **+** để thêm vào cuối timeline. |
| **Âm thanh** | Nhạc và hiệu ứng âm | Kéo xuống làn âm thanh. |
| **Chữ** | 4 nhóm: **Kiểu chữ** (35 kiểu), **Mẫu sẵn** (Đăng ký, Trực tiếp, Giảm 50 %, Cảm ơn đã xem…), **Hình** (33 hình), **Nhãn dán** (hơn 120) | Bấm để thêm tại đầu phát, hoặc kéo thả đúng chỗ trên khung hình hay timeline. Thả một kiểu chữ đè lên chữ có sẵn để đổi kiểu. |
| **Bộ lọc** | Các bộ lọc màu | Kéo thả lên một đoạn trên timeline. |
| **Chuyển cảnh** | 17 kiểu chuyển cảnh | Kéo thả vào chỗ nối giữa hai đoạn. |

File chỉ được **ghi nhớ đường dẫn**, không bị sao chép hay thay đổi.

### Thuộc tính (bên phải)

Hiện công cụ của thứ đang chọn:

- **Đoạn video:** Cơ bản · Màu sắc · Hiệu ứng · Tốc độ · Âm thanh · Chuyển cảnh · Tách nền.
- **Chữ / hình / nhãn dán**, **lớp ảnh/video**, **âm thanh:** công cụ riêng của nó.
- **Chưa chọn gì** (bấm ⓧ hoặc Esc): **Tổng quan** dự án và **Phụ đề**.

Mỗi nhóm công cụ chia thành tab con có biểu tượng; tab có chỉnh sửa có **chấm xanh**. Đa số nhóm có nút **Đặt lại**.

---

## 7. Timeline: cắt, tách, sắp xếp

### Các làn

**Video** (làn chính, có ảnh thu nhỏ và dạng sóng âm) · **Chữ** · **Lớp 1, 2, 3** (lớp 3 nằm trên cùng) · **Âm thanh**. Làn video chính là "từ tính": các đoạn luôn nối liền nhau.

### Thao tác cơ bản

- **Bấm** một mục để chọn; bấm chỗ trống để bỏ chọn và đưa đầu phát tới đó.
- **Kéo** một mục để dời. Mục **bám** vào đầu phát, chỗ nối, hai đầu timeline, điểm đánh dấu và **nhịp nhạc**.
- **Kéo mép** để cắt bớt hoặc kéo dài. Mỗi lần kéo là một bước hoàn tác.
- **Kéo một đoạn video** sang chỗ khác để đổi thứ tự. **Chọn nhiều đoạn** (⌘-bấm hoặc ⇧-bấm) rồi kéo một đoạn trong số đó: cả nhóm cùng đi, giữ thứ tự.
- ⌫ xoá thứ đang chọn · Esc bỏ chọn · ⌘D nhân đôi.
- **Thu phóng timeline:** ⌘+ / ⌘−, thanh trượt ở góc phải, kẹp hai ngón trên bàn di chuột; nút ⇔ để xem cả timeline.

### Cắt nhanh

| Lệnh | Phím | Làm gì |
|---|---|---|
| **Tách** | S | Tách đoạn dưới đầu phát làm hai, đúng khung đang hiện. |
| **Bỏ trước** | Q | Bỏ phần của đoạn nằm **trước** đầu phát. |
| **Bỏ sau** | W | Bỏ phần của đoạn nằm **sau** đầu phát. |
| **Xoá nhiều đoạn** | ⇧-bấm rồi ⌫ | ⇧-bấm chọn mọi đoạn giữa đoạn đầu và đoạn vừa bấm; xoá cùng lúc trong một bước hoàn tác. |

### Kéo theo (nút mắt xích, bật sẵn)

Khi một đoạn bị cắt ngắn, kéo dài, xoá, **đổi tốc độ** hoặc **đổi chỗ**, mọi thứ nằm trên nó (chữ, lớp, âm thanh, điểm đánh dấu, phụ đề) **đi theo** để vẫn khớp với hình:

- Nhạc nền chạy ngang qua chỗ cắt thì ngắn lại và phát tiếp, không bị nhảy.
- Chữ hay âm thanh nằm trọn trong phần bị bỏ vẫn được giữ lại ở chỗ cắt.
- Dòng phụ đề nằm trọn trong phần bị bỏ thì bị xoá (đó là lời của hình đã bỏ).
- Khi đổi chỗ đoạn: chữ và phụ đề nằm phần lớn trên một đoạn đi cùng đoạn đó; tiêu đề trải qua nhiều đoạn và nhạc nền đứng yên.

Tắt **Kéo theo** thì chỉ đoạn chính thay đổi.

### Điểm đánh dấu

M thêm điểm đánh dấu tại đầu phát · `[` `]` (hoặc `{` `}`) nhảy tới điểm trước/sau · bảng Tổng quan có **Xuất marker ra CSV…**.

### Hoàn tác

⌘Z / ⇧⌘Z, nút Quay lại / Tiến lên, hoặc **Lịch sử** để nhảy thẳng về một bước. Tên của từng bước được ghi rõ (ví dụ "Hoàn tác Bỏ phần trước đầu phát").

---

## 8. Chỉnh từng đoạn video

Chọn một đoạn trên timeline rồi dùng bảng bên phải. Mọi chỉnh sửa chỉ áp cho **đoạn đang chọn** (trừ khi ghi khác). Xem trước và video xuất dùng chung một bộ vẽ, nên **thấy gì xuất nấy**.

### 8.1 Cơ bản

| Tab con | Làm gì |
|---|---|
| **Cắt khung** | Cắt bớt mép (Trái, Trên, Rộng, Cao) hoặc theo tỉ lệ 16:9, 9:16, 1:1, 4:3. |
| **Xoay** | Xoay 90°, lật ngang, lật dọc. |
| **Khung hình** | Khung riêng của đoạn (Theo video, 16:9, 9:16, 1:1, 4:5, 4:3) và cách đặt hình: **Vừa khung (có viền đen)** hoặc **Lấp đầy (cắt phần thừa)**. Khung của cả video đặt trong **Xuất**. |
| **Thu phóng** | Phóng to và dời hình theo thời gian: mẫu có sẵn (phóng vào, phóng ra, lia trái/phải, phóng và lia, giật vào) hoặc tự đặt keyframe, có xoay và kiểu chuyển động (đều, chậm đầu, chậm cuối, nảy…). |
| **Ổn định hình** | Giảm rung cho video quay tay. |
| **Theo người** | Đổi video sang khung khác, khung tự đi theo người (xem 8.9). |
| **Màu sắc** | Độ sáng, tương phản, bão hoà, nhiệt độ màu nhanh. |
| **Chép kiểu** | Chép kiểu đoạn này dán cho đoạn khác (xem 8.8). |

### 8.2 Màu sắc (chỉnh màu chuyên nghiệp)

- **Ánh sáng:** phơi sáng, độ sáng, tương phản, vùng sáng, vùng tối, bão hoà, độ rực, nhiệt độ, sắc thái lục–tím.
- **Đường cong:** đường cong chung và từng kênh đỏ/lục/lam. Bấm lên đường để thêm điểm, kéo để uốn, bấm đúp vào điểm để xoá.
- **Bánh xe:** nhuộm riêng vùng tối, vùng giữa, vùng sáng; thanh dưới mỗi bánh làm vùng đó sáng/tối hơn.
- **Từng màu (HSL):** chọn 1 trong 8 màu rồi chỉ đổi sắc độ, bão hoà, độ sáng của màu đó (ví dụ làm trời xanh hơn mà không đụng tới da).
- **File màu (LUT):** nạp file `.cube`, chỉnh cường độ.
- **Biểu đồ sáng tối:** cảnh báo khi hình cháy trắng hoặc đen kịt.
- Nút nhanh: **So sánh** (giữ để xem hình trước khi chỉnh), **Sao chép / Dán** màu giữa các đoạn, **Mọi đoạn** (áp màu này cho cả timeline), **Đặt lại tất cả**.

Video HDR: màu được áp lên hình HDR như đang lưu (app có cảnh báo).

### 8.3 Hiệu ứng

- **Bộ lọc:** chọn một kiểu màu sẵn (có hình xem trước trên khung hình thật), chỉnh độ mạnh.
- **Điều chỉnh:** làm nét, làm mờ, tối viền.
- **Nền mờ:** lấp dải đen (khi video không lấp đầy khung) bằng chính video đã làm mờ.

### 8.4 Tốc độ

- **Tốc độ:** 0,25× đến 4×, có các nút nhanh. Cài đặt có tuỳ chọn giữ cao độ giọng khi đổi tốc độ.
- **Đường cong tốc độ:** nhanh chậm theo thời gian trong cùng một đoạn.
- **Dừng hình:** đứng hình tại vị trí phát, độ dài tuỳ chọn.
- **Đảo ngược:** phát ngược đoạn này.

### 8.5 Âm thanh của đoạn

Xem phần [11. Âm thanh](#11-âm-thanh-nhạc-và-giọng-đọc).

### 8.6 Chuyển cảnh

17 kiểu: tan dần, chuyển qua màn đen, chuyển qua màn trắng, trượt (trái, phải, lên, xuống), quét (trái, phải, lên, xuống), phóng to, mở vòng tròn, mờ nhoè, xoay, loé sáng, vỡ ô. Mỗi kiểu có hình xem trước trên khung hình thật. Chỉnh độ dài. Cũng có thể kéo từ tab **Chuyển cảnh** của Thư viện thả vào chỗ nối.

### 8.7 Tách nền

- **Người:** **Xóa nền**, chỉ giữ người hoặc chủ thể (Vision chạy trên máy).
- **Phông xanh:** làm một màu trong suốt (xanh lá, xanh dương hoặc màu tự chọn), chỉnh dung sai và độ mềm viền.
- **Hình cắt:** mặt nạ tròn, chữ nhật, bo góc, trái tim, ngôi sao, nửa hình; chỉnh cỡ, vị trí, xoay, viền mềm; có thể đảo (ẩn phần bên trong).
- **Nền thay:** phần bị bỏ đi hiện màu đen, trắng, màu tự chọn hoặc bản sao mờ của hình.

### 8.8 Chép và dán kiểu cho nhiều đoạn

1. Chọn đoạn có kiểu đẹp ▸ **Cơ bản ▸ Chép kiểu ▸ Chép kiểu** (hoặc **Sửa ▸ Chép kiểu**, ⌥⇧⌘C).
2. Tick các phần muốn dán: **Màu sắc, Hiệu ứng, Khung, Tốc độ, Chuyển cảnh, Thu phóng và dịch**. App tự tick sẵn những phần đoạn gốc đã chỉnh.
3. Chọn các đoạn đích (⌘-bấm / ⇧-bấm trên timeline) ▸ **Dán** (⌥⇧⌘V), hoặc **Dán cho tất cả**.

Dán tốc độ thì chữ, lớp, âm thanh đi theo hình như khi đổi tốc độ bằng tay. Một bước hoàn tác.

### 8.9 Theo người: đổi khung tự động (16:9 ↔ 9:16)

Dùng khi cần đăng TikTok/Reels (khung dọc) từ video quay ngang, hoặc ngược lại, mà không cắt mất người.

1. **Cơ bản ▸ Theo người**.
2. Chọn **Khung mới**: 9:16 (TikTok, Reels), 16:9 (YouTube), 1:1 hoặc 4:5.
3. Bấm **Đổi khung, theo người**.

App làm gì:

- Cả video lấy khung mới ở chế độ lấp đầy.
- Đoạn nào có hình khác khung thì Vision **tìm người ngay trên máy** (vài lần mỗi giây), rồi khung **đi theo người**: chuyển động mượt, đứng yên khi người chỉ nhích nhẹ ở giữa, không chạy giật, **không bao giờ lộ viền đen**. Không thấy ai thì khung đứng giữa.
- Đoạn đã đúng khung thì giữ nguyên.
- Có thanh tiến trình và nút **Dừng**. Nếu đang chọn nhiều đoạn, có thể tick **Chỉ các đoạn đang chọn**.
- Đường đi của khung gắn với hình gốc, nên tách, cắt hay đổi tốc độ đoạn sau đó vẫn đúng.
- **Về giữa** để bỏ theo người (khung mới vẫn giữ).

---

## 9. Chữ, hình và nhãn dán

### Thêm

Từ tab **Chữ** của Thư viện: bấm (thêm tại đầu phát) hoặc kéo thả thẳng lên khung hình đúng chỗ muốn đặt, hay lên làn Chữ của timeline. Nút **Chữ** trên thanh công cụ timeline thêm nhanh một chữ.

### Chỉnh ngay trên khung hình

- **Bấm** để chọn; **kéo** để dời; **kéo góc** để phóng to/thu nhỏ.
- Khi kéo, vật **bám vào giữa** khung hình hoặc giữa vật nằm dưới nó (đường hồng và nhãn "Đã căn giữa…"). Giữ ⌥ để thả tự do.
- **Bấm đúp vào chữ** để gõ ngay trên hình: Return xong, ⌥Return xuống dòng, Esc huỷ.
- **Chọn nhiều:** ⇧-bấm hoặc ⌘-bấm, hoặc kéo một khung trên vùng trống của hình.
- Mũi tên dời 1 điểm (⇧: 10 điểm) · ⌫ xoá · ⌘D nhân đôi · Esc bỏ chọn.
- **Nhóm** ⌘G / **Bỏ nhóm** ⇧⌘G / **Khoá** ⌘L (vật đã khoá không bị dời hay xoá trên hình).
- Chuột phải trên hình để có các lệnh trên cùng **Thứ tự lớp**.

### Bảng bên phải (khi chọn chữ/hình/nhãn dán)

| Tab | Làm gì |
|---|---|
| **Chữ** / **Hình** | Nội dung, phông, cỡ, màu, nền, căn lề; hình: màu tô, viền. Menu **Kiểu** đổi sang kiểu khác. |
| **Kiểu chữ** | Viền (màu, độ dày), bóng hoặc phát sáng, khoảng cách chữ, in hoa toàn bộ. Cuối thẻ có **Chép kiểu / Dán / Dán cho tất cả** cho chữ khác. |
| **Thời gian** | Bắt đầu, kết thúc (nút Bắt đầu tại đây / Kết thúc tại đây). |
| **Vị trí** | Vị trí và kích thước bằng số, kèm **Thứ tự lớp**. |
| **Vào/ra** | Hiệu ứng xuất hiện và biến mất (hiện mờ dần, trượt lên/xuống/trái/phải, bật ra, phóng to, đánh máy), độ dài. |
| **Chuyển động** | 13 kiểu chạy liên tục khi đang hiện: Nhịp đập, Tim đập, Thở, Nảy, Lơ lửng, Lắc ngang, Đung đưa, Lắc lư, Xoay, Rung, Nhấp nháy, Chớp, Tada; chỉnh tốc độ, độ mạnh, nút Xem thử. |
| **Keyframe** | Đặt keyframe vị trí, cỡ, xoay, độ mờ theo thời gian, chọn kiểu chuyển động giữa các keyframe. |
| **Tất cả** | Danh sách mọi chữ/hình/nhãn dán trên hình. |

### Thứ tự lớp

Chữ, hình, nhãn dán và ảnh/video lớp **xếp chung một chồng**, nên chữ có thể nằm dưới ảnh và ngược lại. Có 4 lệnh, chỉ tính những thứ hiện cùng lúc:

| Lệnh | Phím |
|---|---|
| Đưa lên trên cùng | ⌥⇧⌘] |
| Đưa lên một lớp | ⌥⌘] |
| Đưa xuống một lớp | ⌥⌘[ |
| Đưa xuống dưới cùng | ⌥⇧⌘[ |

Có trong menu **Sửa**, menu chuột phải trên hình và cuối thẻ **Vị trí**. Thứ thêm sau luôn nằm trên.

---

## 10. Lớp ảnh và lớp video (logo, hình trong hình)

Lớp là ảnh (logo, watermark) hoặc video (hình trong hình) đặt trên video chính, trên 3 làn **Lớp 1–3**.

- **Thêm:** **Tệp ▸ Thêm video phủ…** (⌥⌘V), **Thêm ảnh phủ…** (⌥⌘P), kéo ảnh từ Finder/Thư viện thả lên khung hình hoặc lên làn Lớp. Ảnh động (GIF, APNG, WebP) chuyển động và giữ nền trong suốt.
- **Trên khung hình:** kéo để dời, kéo góc để đổi cỡ (giữ tỉ lệ), kéo **giữa cạnh** để kéo giãn một chiều; bám vào giữa và lề (giữ ⌥ để tắt).
- **Vị trí:** nút nhanh 4 góc / giữa / phủ kín, cỡ, kéo giãn, vị trí ngang/dọc, độ mờ, xoay, **Tỉ lệ gốc**, Thứ tự lớp.
- **Diện mạo:** viền (màu, độ dày); **phông xanh**; **tách nền và hoà trộn** (chỉ giữ người, mặt nạ hình, 10 kiểu hoà trộn: Multiply, Screen, Overlay…).
- **Âm thanh của lớp** (lớp video): tắt tiếng, âm lượng.
- **Vào/ra**, **Chuyển động** lặp, **Keyframe** vị trí/cỡ/độ mờ/xoay.
- Trên timeline: kéo để đổi thời điểm hoặc làn, kéo mép để cắt gọn.

---

## 11. Âm thanh, nhạc và giọng đọc

Chọn một đoạn ▸ **Âm thanh**. Các tab con:

### Tiếng đoạn (tiếng của video)

- Tắt tiếng, âm lượng (dB), làm to dần/nhỏ dần, dời tiếng cho khớp hình.
- **Cân bằng âm lượng** tự đưa về mức nghe vừa.
- **Giảm tiếng ồn nền** (chỉnh độ mạnh).
- **Giọng và hiệu ứng:** một chạm cho Giọng rõ, Ấm, Giọng trầm, Giọng cao, Sóc chuột, Điện thoại, Phòng lớn, Vang dội; hoặc tự chỉnh âm trầm/trung/cao, cao độ (giữ độ dài), tiếng phòng, tiếng dội.
- **Đường âm lượng:** bấm lên đường để thêm điểm, kéo lên/xuống, bấm đúp để xoá.
- Thay tiếng của đoạn bằng file âm thanh khác (**Thay…**).

### Nhạc

**Thêm nhạc** (bắt đầu tại đầu phát) hoặc **Thêm hiệu ứng âm**; hay kéo file nhạc xuống làn Âm thanh. Mỗi âm thanh có: âm lượng, fade, tắt tiếng, đường âm lượng, giảm ồn, hiệu ứng giọng, nhân đôi, xoá, và **Hạ nhỏ khi có người nói** (nhạc tự nhỏ xuống khi video hoặc giọng đọc có lời).

### Nhịp (cắt theo nhịp nhạc)

1. Thêm một bài nhạc ▸ **Nhịp ▸ Tìm nhịp**. App nghe bài nhạc ngay trên máy (bài 3 phút mất khoảng 1 giây) và cho biết số nhịp/phút.
2. Nhịp hiện thành **vạch nhỏ trên bài nhạc** ở timeline. Khi kéo thả hoặc kéo mép, mọi thứ **bám vào nhịp**.
3. Chọn **Dùng**: mỗi nửa nhịp, mỗi nhịp, mỗi 2, 4 hoặc 8 nhịp.
4. **Cắt khớp nhịp:** dời mọi chỗ nối giữa các đoạn về nhịp gần nhất (chỉ các đoạn đang chọn nếu chọn nhiều). Chỉ dời khi có nhịp ở gần; video chỉ được kéo dài nếu còn hình, ảnh thì dài bao nhiêu cũng được. Bài nhạc giữ nguyên độ dài.
5. **Đánh dấu nhịp:** đặt điểm đánh dấu ở các nhịp để tự cắt; `[` `]` nhảy giữa các điểm.
6. **Bỏ nhịp** để quên nhịp của bài.

Bài đổi tempo giữa chừng vẫn được theo. Bài remix "nửa nhịp" (trống chính 70 nhịp/phút cho bài 140) thì dùng **Mỗi nửa nhịp**.

### Khoảng lặng (tự cắt chỗ không có tiếng)

Dùng cho video nói chuyện, hướng dẫn.

1. **Âm thanh ▸ Khoảng lặng**. Chỉnh **Khoảng lặng ngắn nhất** (giây) và **Độ nhạy** (cao thì cắt nhiều hơn).
2. **Tìm khoảng lặng** (chỉ các đoạn đang chọn nếu chọn nhiều). App hiện **danh sách** các khoảng (giờ bắt đầu–kết thúc, độ dài) và tổng thời gian sẽ bớt.
3. Bấm ▶ ở một dòng để **nghe** từ ngay trước khoảng đó; bỏ tick những khoảng muốn giữ (có **Chọn hết / Bỏ chọn hết**).
4. **Cắt** để bỏ các khoảng đã chọn trong một bước hoàn tác.

Khoảng cắt chừa 0,2 giây sau lời trước và 0,3 giây trước lời sau để không cụt chữ. Nhạc phát đều đều không bị coi là lặng.

### Giọng đọc

Thu giọng bằng micro ngay trong app (có thể vừa phát video vừa thu). Bản thu thành một âm thanh trên timeline, chỉnh như nhạc.

### Lưu tiếng

**Xuất riêng âm thanh (.m4a)…** của đoạn đang chọn thành file mới.

### Tách lời lấy nhạc nền

**Tệp ▸ Tách lời…** (hoặc nút trong bảng Âm thanh, hay khi đang mở một bài hát/video) ▸ **Tách và lưu nhạc nền…** → file `.m4a` mới không có giọng hát. Chạy trên máy bằng mô hình đi kèm app; có tiến trình, huỷ được; file gốc không bị đổi. Tuỳ bản phối, có thể còn chút giọng hoặc giảm một số nhạc cụ.

---

## 12. Phụ đề

Bỏ chọn mọi thứ (Esc) ▸ bảng bên phải ▸ **Phụ đề**.

- **Thêm tại vị trí phát**, sửa chữ trong danh sách; mỗi dòng có Bắt đầu tại đây / Kết thúc tại đây / Tách tại đây; chọn nhiều dòng để gộp.
- **Nhập…** file SRT/VTT (nhận đúng tiếng Việt, kể cả mã Windows-1258), **Xuất SRT…**, **Xuất VTT…**.
- **Phụ đề tự động:** chọn ngôn ngữ (tiếng Việt chạy được trên máy) ▸ **Tạo phụ đề từ giọng nói** cho đoạn đang chọn. Nhận dạng chạy ngay trên Mac, không gửi đi đâu; lần đầu macOS hỏi quyền Nhận dạng giọng nói.
- **Tìm / Thay tất cả**, cảnh báo dòng chồng nhau, rỗng hoặc ra ngoài video.
- **Khi xuất:** **Lưu thành file .srt riêng** hoặc **Ghi cứng vào hình**; chỉnh lệch thời gian, **Dời tất cả theo vị trí phát…**.
- **Kiểu (cổ điển):** cỡ, khoảng cách tới đáy, màu, nền; **Mẫu cho video dọc (9:16)**.

### Kiểu phụ đề TikTok

**Kiểu phụ đề** có 6 lựa chọn: **Cổ điển**, **Tô từ** (từ đang nói đổi màu), **Hộp màu** (từ đang nói nằm trên hộp màu), **Nảy** (từ đang nói to hơn, mỗi câu nảy vào), **Từng từ** (mỗi lần một từ thật to), **Chữ đậm**.

- Chữ to, in hoa, viền dày; chọn **màu từ đang nói**, **chữ in hoa**, **phông** (đều có đủ dấu tiếng Việt), **cỡ**, **độ cao trên khung hình**.
- Phụ đề tạo từ giọng nói được chia câu ngắn 3 từ và giữ đúng thời điểm từng từ; dòng gõ tay hay nhập file được chia thời gian theo độ dài từ.
- **Chia … dòng phụ đề dài thành câu ngắn** khi có dòng dài.
- Chọn một kiểu TikTok thì phụ đề được bật **ghi cứng vào hình** khi xuất.

---

## 13. Xuất video

Bấm **Xuất** ở góc trên bên phải (⌥⌘S).

- **Khung** theo nền tảng: Gốc, 16:9 (YouTube), 9:16 (TikTok, Reels, Shorts), 1:1, 4:5 (Instagram dọc), 4:3; và cách lấp: viền đen, cắt mép, hoặc viền mờ.
- **Chất lượng:** Tốt nhất, 4K, Full HD, HD, File nhỏ (video dọc Full HD là 1080 × 1920). Có ước lượng dung lượng.
- **Kèm âm thanh**, chọn thư mục lưu, phần **Nâng cao**.
- Video được xuất thành **file mới** qua **hàng đợi**; tiếp tục làm việc trong lúc xuất. **Hàng đợi xuất** (⌥⌘E) cho xem tiến trình, huỷ, mở file xong.
- Video giống hệt khung trước (ảnh bìa, ảnh tĩnh) được xuất rất nhanh.

Dự án tạo từ nhạc có thể xuất **chỉ âm thanh (.m4a)** (Âm thanh ▸ Lưu tiếng).

---

## 14. Dự án ảnh

Dùng để chỉnh một ảnh (kể cả ảnh động) với chữ và logo.

- **Thư viện:** tab **Ảnh** (ảnh đầu là ảnh chính, các ảnh sau thành logo), **Chữ**, **Bộ lọc**. Kéo thả thẳng lên ảnh.
- **Cắt:** khung cắt kéo ngay trên ảnh (bật "Chỉnh ngay trên ảnh" hoặc chọn một tỉ lệ: 1:1, 3:2, 2:3, 4:5, 16:9, 4:3), có đường chia ba và kích thước ảnh sẽ lưu.
- **Chỉnh:** xoay, lật, màu (đủ bộ chỉnh màu chuyên nghiệp), bộ lọc, làm nét/mờ/tối viền, tách nền, chữ, hình, nhãn dán, **logo** (kéo, đổi cỡ, viền, độ mờ).
- **Đổi ảnh…** giữ nguyên màu, hiệu ứng, chữ, logo.
- **Lưu:** JPEG, PNG, HEIC, TIFF (ảnh động: GIF hoặc PNG động), chất lượng, giới hạn cạnh dài, tuỳ chọn **bỏ thông tin nơi chụp** và thông tin máy ảnh. Luôn lưu thành ảnh mới.

Ảnh động: cùng một chỉnh sửa áp lên mọi khung. Muốn ảnh động chạy trong video thì tạo **dự án video** từ nó.

---

## 15. Phím tắt

Các phím một chữ chỉ hoạt động khi bạn không đang gõ trong ô nhập.

### Chung

| Phím | Lệnh |
|---|---|
| ⌘1 / ⌘2 | Danh sách phát / Dự án |
| ⇧⌘H | Trang chủ |
| ⌘N | Dự án mới (ở màn hình Chỉnh sửa) |
| ⌥⌘N | Cửa sổ mới |
| ⇧⌘N | Danh sách phát mới |
| ⌘O / ⇧⌘O | Mở… / Mở thư mục thành danh sách phát |
| ⌘U | Mở link… |
| ⌘E | Chỉnh sửa file đang xem |
| ⌘S | Lưu ngay |
| ⌥⌘S | Xuất video |
| ⌥⌘E | Hàng đợi xuất |
| ⇧⌘W / ⌘W | Đóng video / Đóng cửa sổ |
| ⌘, | Cài đặt |
| ⌃⌘1 / ⌃⌘2 | Hiện/ẩn danh sách phát / công cụ |
| ⌃⌘F hoặc F | Toàn màn hình |

### Phát

| Phím | Lệnh |
|---|---|
| Space | Phát / dừng |
| ← → | Tua (⇧: tua dài) |
| `,` `.` | Lùi / tiến một khung |
| `-` `=` | Chậm / nhanh hơn |
| ⌘[ ⌘] | Video trước / sau trong danh sách phát |

### Dựng video

| Phím | Lệnh |
|---|---|
| S | Tách đoạn tại đầu phát |
| Q / W | Bỏ phần trước / sau đầu phát |
| M | Thêm điểm đánh dấu |
| `[` `]` | Điểm đánh dấu trước / sau |
| ⌫ | Xoá thứ đang chọn |
| Esc | Bỏ chọn |
| ⌘Z / ⇧⌘Z | Hoàn tác / Làm lại |
| ⌘D | Nhân đôi |
| ⌘G / ⇧⌘G | Nhóm / Bỏ nhóm |
| ⌘L | Khoá / Mở khoá |
| ⌥⇧⌘C / ⌥⇧⌘V | Chép kiểu / Dán kiểu |
| ⌥⇧⌘] / ⌥⌘] | Đưa lên trên cùng / lên một lớp |
| ⌥⌘[ / ⌥⇧⌘[ | Đưa xuống một lớp / xuống dưới cùng |
| ⌥⌘A | Thêm video vào dự án |
| ⌥⌘V / ⌥⌘P | Thêm video phủ / ảnh phủ |
| ⌘+ / ⌘− | Phóng to / thu nhỏ timeline |
| Mũi tên | Dời vật đang chọn trên hình 1 điểm (⇧: 10 điểm) |

Chưa cho tuỳ chỉnh phím tắt.

---

## 16. An toàn dữ liệu và xử lý sự cố

### MacPlayer không bao giờ sửa file gốc

- Video, ảnh, nhạc gốc **không bao giờ bị sửa, ghi đè hay thay thế**. Mọi kết quả xuất là **file mới**; tên đã có thì thêm số.
- Xuất ra file tạm cạnh nơi lưu, kiểm tra (mở được, đúng thời lượng, đủ track, giải mã được) rồi mới đặt vào chỗ.
- Tự lưu chỉ ghi file dự án và dữ liệu khôi phục của app.
- Ngoại lệ duy nhất, chỉ khi bạn yêu cầu: trong **Danh sách phát**, đổi tên file hoặc chuyển file vào Thùng rác (có hỏi trước, lấy lại được).

### Quyền riêng tư

Tìm người, tách nền, nhận dạng giọng nói, dò nhịp, tách lời đều chạy **ngay trên máy**. App không có tài khoản, không thu thập dữ liệu. Ảnh lưu ra có tuỳ chọn bỏ thông tin nơi chụp.

### Sự cố thường gặp

| Hiện tượng | Cách xử lý |
|---|---|
| macOS không cho mở app | Chuột phải ▸ Mở, hoặc Cài đặt hệ thống ▸ Quyền riêng tư & Bảo mật ▸ Vẫn mở. |
| Dự án báo thiếu video | **Tệp ▸ Liên kết lại…** và chọn file ở chỗ mới. |
| Danh sách dự án ghi "Ổ chưa kết nối" | Cắm lại ổ chứa dự án. |
| "Không tìm thấy file" ở thẻ dự án | **Tìm lại…** tới file đã dời, hoặc **Bỏ khỏi danh sách**. |
| Tạo phụ đề từ giọng nói báo không có quyền | Cài đặt hệ thống ▸ Quyền riêng tư & Bảo mật ▸ Nhận dạng giọng nói ▸ bật cho MacPlayer. |
| Ngôn ngữ phụ đề không có trong danh sách | Ngôn ngữ đó không nhận dạng được trên máy; MacPlayer không gửi giọng nói lên mạng nên không dùng. |
| Tìm nhịp báo "không tìm thấy nhịp đều" | Bài không có nhịp rõ (nói chuyện, nhạc tự do). Dùng điểm đánh dấu để tự cắt. |
| Theo người: khung đứng giữa | Vision không thấy người trong đoạn đó (ví dụ sơ đồ, cảnh xa). |
| Không tìm thấy khoảng lặng | Tăng **Độ nhạy** hoặc giảm **Khoảng lặng ngắn nhất**. Âm thanh toàn nhạc nền sẽ không có khoảng lặng. |
| Phụ đề 16:9 đè lên chữ có sẵn trong video | Chỉnh **Độ cao trên khung hình** trong Kiểu phụ đề. |
| App tắt đột ngột | Mở lại: app hỏi khôi phục dự án từ bản lưu trên máy. |
| File MKV, WebM, AVI, WMA không mở được | macOS không hỗ trợ các định dạng này; chuyển sang MP4/MOV/M4A bằng công cụ khác. |
