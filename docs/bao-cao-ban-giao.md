# Báo cáo bàn giao MacPlayer

Ngày: 05/11/2026 (cập nhật lần cuối 11/11/2026, bản 0.8.2; xem "Bổ sung 0.3.0–0.7.0", "Bản 0.7.1", "Bản 0.8.0", "Bản 0.8.1" và "Bản 0.8.2" ở cuối) · Máy kiểm thử: Apple Silicon, macOS 27.0.1, Swift 6.4, chỉ có Command Line Tools.
Nguồn yêu cầu: `MacPlayer-Thiet-ke-san-pham.md`.

**Tóm tắt trung thực:** đây là một ứng dụng chạy được, với lõi lưu an toàn, cắt, render, playlist, dự án và hàng đợi đã kiểm thử kỹ. Nó **chưa phải bản thương mại hoàn chỉnh**: không có cấp phép, thanh toán, cập nhật, chữ ký phân phối; timeline nhiều nguồn/nhiều lớp và nhiều tính năng giai đoạn 3–4 chưa có giao diện hoặc chưa làm.

## 1. Quyết định kỹ thuật đã chốt

| Mục | Quyết định | Lý do / bằng chứng |
|---|---|---|
| Stack | Swift + SwiftPM; AppKit cho cửa sổ/timeline, SwiftUI cho panel | Không có Xcode đầy đủ; cùng họ với các app cũ |
| macOS tối thiểu | 15.0 | `AVAssetExportSession.export(to:as:)` async; API callback đã deprecated ở SDK 27 |
| Phần cứng | Chỉ Apple Silicon đã kiểm thử | Không có máy Intel |
| Media engine | Chỉ AVFoundation | Không ffmpeg/engine ngoài; MKV/WebM chưa hỗ trợ |
| Cắt chính xác | `AVAssetReader` → `AVAssetWriter` tự viết | Prototype cho thấy preset export có thể **âm thầm sao chép luồng** nên không đảm bảo mã hóa lại |
| Cắt nhanh | `AVAssetExportSession` passthrough | Cắt đúng ở mức trình chiếu nhờ edit list; file giữ khung dẫn đầu (xem mục 4) |
| Thời gian | Hữu tỉ `value/timescale`, tần số khung là phân số | Tránh trôi ở 29,97 fps |

## 2. Kết quả theo lát cắt

| Lát cắt | Trạng thái | Bằng chứng |
|---|---|---|
| **A** mở → phát/tua → chọn đoạn → xuất bản sao | Hoàn thành | Self-test trong app thật: phát 1,03 s/1 s, seek đúng khung 75, bước một khung, xuất ra đúng khung 75…149, nguồn không đổi từng byte |
| **B** playlist từ kéo thả/chọn thư mục → phát liên tục → lưu và mở lại | Hoàn thành (xem hạn chế) | Self-test: thứ tự tự nhiên `clip 1, 2, 10`, bỏ file trùng, tự chuyển video, dừng cuối danh sách, xóa danh sách không xóa video; 1.000 mục = 0,06 s; lưu/đọc JSON |
| **C** nhiều vùng → đặt tên → xuất hàng loạt | Hoàn thành | Self-test: 3 file đúng tên `demo - 01 - Intro`…, đúng số khung (75/30/30); lỗi một mục không ảnh hưởng mục khác (test hàng đợi) |
| **D** chỉnh hình/tiếng/phụ đề/thumbnail → xem trước → xuất đúng | Hoàn thành phần chính | Test pixel: xoay/lật/crop/canvas/màu/chữ/phụ đề/gain/mute/fade/tốc độ; **preview vs xuất lệch 0,75/255** (chỉ do nén); ba loại thumbnail có hành vi tách biệt |
| **E** lưu dự án → đóng/mở → phục hồi | Hoàn thành | Self-test: lưu, mở lại giữ nguyên clip/look/thời gian; tự lưu sau 2 s; bản tự lưu chứa chỉnh sửa chưa lưu; không chạm file video |
| **G** timeline nhiều nguồn | Hoàn thành ở mức một track video | Self-test trong app thật: chuyển thành dự án, tách đúng khung, thêm video thứ hai, đổi thứ tự, chỉnh riêng một đoạn, Undo/Redo, xuất đúng 660 khung (A 150 + B 60 + A 450), lưu/mở lại 2 nguồn, phát hiện thiếu media, chặn xuất khi thiếu, liên kết lại; test Media: look và tốc độ riêng từng đoạn, khớp kích thước canvas |
| **H** nhiều lớp video (lớp phủ) | Hoàn thành ở mức 3 dòng lớp, video/ảnh, keyframe tuyến tính | Test pixel: xuất hiện đúng thời gian/vị trí, độ mờ, viền, keyframe, ảnh PNG, thứ tự dòng, âm thanh lớp, khung chính không mất khung, khớp preview; self-test trong app: thêm video/ảnh, chọn dòng trống, từ chối chồng lấn, preset, keyframe + Undo, xuất đúng 180 khung, lưu định dạng 2, mở lại, chặn xuất khi thiếu file ảnh |
| **I** kéo lớp trên khung hình | Hoàn thành | Hình học thuần ở Core (di chuyển, đổi cỡ giữ góc đối diện, hít tâm/lề) có test; self-test trong app thật bơm sự kiện chuột thật vào view thao tác: kéo thân đúng khoảng cách chuột, một lần kéo = một bước Undo, kéo góc giữ góc đối diện, bấm chọn lớp khác, khung đang dừng được vẽ lại trong 150 ms (đọc pixel); test Media: preview theo thay đổi live còn bản xuất thì không |
| **F** phần còn lại | **Một phần** — xem mục 3 | |

## 3. Đối chiếu bản thiết kế

**Đã làm và kiểm chứng (tự động hoặc trong app thật)**

- Phát: tua/bước khung theo PTS thật, tốc độ 0,25–4×, lặp video/A–B, nhớ vị trí (có tắt/xóa), metadata, thông báo lỗi rõ khi file không mở được.
- Playlist: tạo/đổi tên/nhân đôi/xóa, kéo thả file & thư mục, thêm thư mục có **xem trước trước khi thêm**, thư mục con (tùy chọn), file trùng, thứ tự tự nhiên/ngày/thời lượng, tuần tự/trộn theo lượt/lặp một/lặp cả danh sách/tự phát, quay lại theo lịch sử, bỏ qua mục lỗi không lặp vô hạn, xóa mục đang phát không dừng, nhớ vị trí, tìm kiếm không phân biệt dấu, theo dõi thư mục (quét lại mỗi 20 s, thêm cuối, đánh dấu mất, không xóa).
- Vùng chọn: nhiều vùng trên một video, đặt tên/nhân đôi/xóa, kéo cạnh trên timeline, chính sách chồng lấn tường minh (giữ riêng/gộp), xem trước liên tiếp, marker có tên/màu, xuất CSV/JSON.
- Lưu video: hai lựa chọn đúng đặc tả; xác nhận file; sao lưu mặc định bật; file tạm + kiểm tra; phát hiện nguồn bị sửa; hủy/lỗi/hết dung lượng/mất quyền không làm mất bản gốc; khôi phục khi gián đoạn giữa lúc thay; phân biệt Undo với khôi phục file.
- Xuất: nhanh và chính xác, MP4/MOV/M4V, H.264/HEVC, chất lượng, giới hạn độ phân giải (không phóng to), ước tính dung lượng, cảnh báo (mã hóa lại, giữ HDR 10-bit, VFR, đổi container), hàng đợi có tiến trình/hủy/chạy lại/khôi phục sau crash, đồng thời 1–4.
- Hình: crop, xoay, lật, canvas 16:9/9:16/1:1/4:3, vừa/lấp đầy, sáng/tương phản/bão hòa/nhiệt độ màu.
- Chữ: tiêu đề/chú thích/lower-third, font/cỡ/màu/nền/căn lề/vị trí/fade.
- Phụ đề: nhập/xuất SRT & WebVTT, tiếng Việt qua UTF-8/UTF-16/**Windows-1258**, sửa/tách/gộp/tìm-thay, dời toàn bộ, cảnh báo chồng lấn/ngoài thời lượng, kiểu chữ + mẫu video dọc, xuất `.srt` kèm theo hoặc ghi cứng.
- Âm thanh: gain, tắt tiếng, fade vào/ra (đã test).
- Thumbnail: ba chức năng **tách biệt** (ảnh trong thư viện / xuất PNG-JPEG / nhúng ảnh bìa), hiển thị giới hạn từng loại; nhúng ảnh bìa đọc lại được ở MP4/M4V/MOV.
- Dự án: định dạng JSON có phiên bản schema và chuỗi migration, tự lưu, điểm khôi phục theo thời gian/dung lượng, phục hồi sau crash, relink video.
- Riêng tư: không có kết nối mạng nào trong mã; không có telemetry.
- Bản địa hóa: 537 chuỗi, tiếng Việt và tiếng Anh; nhãn VoiceOver trên các điều khiển chính.

**Từng ở danh sách "chưa kiểm thử", nay đã kiểm thử (đợt "Kiểm thử còn thiếu")**

- Làm trễ/lệch tiếng, thay âm thanh bằng file ngoài, xuất riêng `.m4a`, xuất ảnh thumbnail có cắt theo tỷ lệ: có test bằng dữ liệu thật (đo thời điểm tiếng bíp, đọc pixel ảnh).
- Chọn track âm thanh khi phát và khi xuất: test trên file có hai track thay thế nhau; **tìm ra lỗi thật** (mục 5, số 14).
- Phím tắt (Space, ←/→, ⇧←/⇧→, `,` `.`, I, O, M, Return, Delete, `-`, `=`): selftest trong app thật bơm sự kiện phím thật vào cửa sổ; kiểm cả hai chiều: **không kích hoạt khi đang gõ trong ô văn bản** và **⌘M không bị lấy làm phím M**.
- Menu: mọi mục đều có nơi nhận lệnh, không hai mục nào trùng phím tắt, Lưu/Hoàn tác bật-tắt đúng và Hoàn tác nêu tên thao tác.
- "Luôn nổi": mức cửa sổ đổi sang `floating` rồi về `normal`.
- Hàng đợi chạy song song: với giới hạn 1 thì đỉnh thấy 1 lượt chạy, với giới hạn 3 thì đỉnh đúng 3; cả 6 lượt đều thành công.
- Mở bằng Finder: `Scripts/open_with_test.py` dùng `open -a` (đường Launch Services mà Finder dùng) với app thật: mở khi app đóng, mở thêm khi đang chạy (cửa sổ thứ hai, cửa sổ cũ giữ nguyên), tên có dấu cách và chữ "é", thư mục → playlist 3 video, file `.macplayer` (mở thành dự án đúng đường dẫn và đúng số đoạn), file hỏng (app không crash, không mở). 13/13 đạt.
- Giao diện không bị khóa khi xuất: trong khi xuất bốn đoạn có chỉnh màu, vòng lặp chính chưa bao giờ bị giữ quá **2 ms**.
- Ổ đĩa thật (`hdiutil`): ổ đầy, hết chỗ giữa lúc ghi, ổ chỉ-đọc, gỡ ổ cưỡng bức khi đang xuất, ổ hỏng giữa chừng. Bản gốc luôn còn nguyên; không để lại file dở.
- File hỏng/cụt/không phải video, tên file tiếng Việt/độ dài tối đa/ký tự đặc biệt.
- **Giết tiến trình (`kill -9`) trên app thật giữa lúc xuất:** 54 lượt ngẫu nhiên (bản sao, thay bản gốc, hàng loạt) đều đạt: bản gốc luôn đọc được và nguyên vẹn, file dở được dọn khi mở lại.
- HDR (HLG/PQ): nhận diện, cảnh báo, và giữ 10-bit khi xuất; **tìm ra lỗi thật** (mục 5, số 16).
- Đo hiệu năng theo mục 16: xem [benchmark.md](benchmark.md).

**Đã kiểm thử trên video thật** (6 clip thật SDR/HDR10/Dolby Vision, 1080p và 4K/60; xem [kiem-thu-video-that.md](kiem-thu-video-that.md)): mở, phát (0 khung rơi), tua chính xác, xuất 21 ca đọc lại và so điểm ảnh với nguồn, thay bản gốc có sao lưu, lưu/mở lại dự án, Open With, `kill -9`. Tìm ra: Dolby Vision có 4,9% khung không giải mã được khi nhảy thẳng tới (mục 5, số 20); mốc thời gian file cắt lệch nửa khung (số 21). Bộ mẫu thật **không có âm thanh, xoay hay VFR**.

**Vẫn chưa kiểm thử** (không có công cụ/dữ liệu/phần cứng để làm trung thực)

- **Toàn màn hình**: macOS không cho tiến trình nền tự giành quyền active nên không tự kiểm được (selftest in SKIP); cần người bấm thử tay. Picture-in-Picture của cửa sổ phát (chưa có).
- Finder thật (menu chuột phải ▸ Mở bằng): đã thử qua `open -a`, chưa bấm trong Finder.
- Tháo ổ ngoài thật, ngủ/thức máy, đổi thiết bị âm thanh giữa chừng (đã thử gỡ ổ ảnh đĩa cưỡng bức, nhưng không phải ổ USB thật).
- Video **quay từ iPhone/camera** (VFR thật, xoay, có âm thanh và đồng bộ âm–hình trên cảnh quay thật, Dolby Vision từ iPhone). Bộ video thật đã dùng là clip thử của một dự án phần mềm: 60 fps cố định, không âm thanh.
- Máy Intel, macOS cũ hơn 15; chỉ chạy trên một máy Apple Silicon (M4, macOS 27).
- Mục tiêu "99,5% phiên không crash" cần dữ liệu từ người dùng beta; không thể tự đo.
- Kiểm toán VoiceOver và Reduce Motion.

**Chưa làm hoặc chưa có giao diện**

_(Danh sách này đã được viết lại ngày 09/11/2026 cho khớp bản 0.7.0; các mục từng nằm ở đây như nhiều track âm thanh, thu giọng, giảm ồn, ducking, chuyển cảnh, freeze frame, đảo chiều, nền mờ, easing, xoay, chế độ hòa trộn nay đã có, xem mục "Bổ sung 0.3.0–0.7.0".)_

- **Keyframe** cho màu và crop của đoạn chính; kéo khung crop trực tiếp trên **video** (ảnh thì có); snap khi kéo đoạn trên timeline.
- Lớp phủ chỉ có trong chế độ Dự án; bo góc riêng, tốc độ riêng của lớp, lớp tạo bằng văn bản (chữ dùng công cụ Chữ).
- Hiệu ứng giọng (EQ, cao độ, phòng, dội) áp lên **bản sao** âm thanh nên chỉ nghe sau khi bấm Áp dụng, không nghe tức thời khi kéo thanh trượt.
- Phiên âm/dịch bằng cloud (không làm: app không dùng mạng). Phiên âm tại máy đã có.
- Thư viện nâng cao: tag, bộ sưu tập, yêu thích, tìm theo metadata; sao chép nguồn vào gói dự án; proxy cho nguồn nặng. Ảnh đại diện "trong MacPlayer" được lưu vào dự án nhưng chưa dùng để hiển thị trong danh sách/thư viện.
- Picture-in-Picture của cửa sổ phát; tùy chỉnh phím tắt (có bảng phím tắt chỉ-đọc).
- Undo cho thao tác playlist (Undo chỉ áp dụng chỉnh sửa video/dự án).
- Đánh dấu "nguồn đã thay đổi" cho **các dự án khác** dùng cùng nguồn: hiện chỉ có cờ trong phiên hiện tại.
- Cấp phép, thanh toán, kích hoạt, khôi phục mua hàng, cập nhật có chữ ký, trang bán hàng, FAQ, hỗ trợ, chữ ký Developer ID + notarization. **Cần thông tin/tài khoản bên ngoài; không tự tạo hay giả lập.**
- Kiểm toán khả năng truy cập thật bằng VoiceOver và Reduce Motion; kiểm tra thương hiệu tên "MacPlayer"; máy Intel; trình phát khác đọc file cắt nhanh.

## 4. Giới hạn thực tế đã đo (đọc kỹ)

- **Cắt nhanh:** file kết quả chứa các khung từ keyframe trước điểm cắt (ví dụ 94 mẫu cho 75 khung hiển thị), được ẩn bằng edit list. AVFoundation đọc lại đúng, **nhưng chưa thử với trình phát khác** (VLC, ffmpeg…) nên chưa biết chúng có tôn trọng edit list không. Giao diện nêu rõ điều này.
- **Cắt chính xác** mất một chút chất lượng (mã hóa lại); không gọi là "lossless".
- **Tốc độ khung hình cố định khi có hiệu ứng:** khi dùng compositor (crop, chữ…), video VFR được ghi ở tốc độ danh nghĩa cố định.
- **Một track âm thanh được dùng khi xuất**: track đang bật (mặc định của nhóm thay thế, như ngôn ngữ), hoặc track đầu nếu không phải nhóm thay thế. Không trộn nhiều track. Âm thanh xuất luôn là AAC.
- **Bước khung** dùng bảng mẫu của file (`AVSampleCursor`); `AVPlayerItem.step(byCount:)` không dùng được vì chỉ bước theo từng khung khi có view đang hiển thị (đo được: bước 0,25 s khi không có view).
- **Theo dõi thư mục** dùng quét định kỳ 20 s, chưa dùng FSEvents.
- Màn hình video không chụp được bằng cơ chế chụp view, nên **tôi chưa tự nhìn thấy khung hình video hiển thị trong cửa sổ** (chỉ xác nhận gián tiếp qua test render, seek và player). Phần giao diện còn lại đã được chụp và xem.
- **Hiệu năng (đo bằng `macplayer-probe bench`, chi tiết ở [benchmark.md](benchmark.md)):** máy Apple M4, 16 GB, macOS 27.0.1, media tổng hợp.
  - Khung hình đầu: 11–18 ms trung vị, p95 ≤ 137 ms trên 20 lượt cho mỗi mẫu (mục tiêu < 2 s ở 95%). Đây là **bộ nhớ đệm ổ đĩa đã nóng**, nên chưa phải lần mở đầu tiên sau khi khởi động máy.
  - Tua chính xác: 10–11 ms (1080p) và 91–97 ms (4K/60, p95 ≤ 173 ms); 0/120 lần sai khung.
  - Phát 10 s: **không rơi khung nào** ở 1080p30 (1× và 2×), 4K/60 H.264 và HEVC. Chưa đo vẽ lên màn hình thật.
  - Xuất: cắt nhanh 170–206× thời gian thực; chính xác 1080p khoảng 7×; **4K/60 chính xác chỉ khoảng 1× (8 s video mất ~8 s), có chỉnh màu 0,9×**; 4K→1080p 3,6×. Mọi kết quả đều đúng số khung và lệch tiếng–hình ≤ 17,3 ms (nhỏ hơn một khung). **Đã điều tra** (benchmark.md, mục 8): giải mã chạy ~10×, nút cổ chai là bộ mã hóa phần cứng của máy đo (hai lượt song song chia đôi tốc độ, tổng vẫn ~1×), không phải lỗi của MacPlayer. Muốn nhanh hơn: cắt nhanh hoặc xuất 1080p. Chưa đo máy có nhiều bộ mã hóa và video thật.
  - Hủy xuất: 45 ms (1080p), tệ nhất 164 ms (4K); không để lại file dở. Mục tiêu < 5 s.
  - Video 10 phút: mở 3 ms, khung đầu 17 ms, sóng âm 97 ms, tua xa 4–14 ms, cắt 8 s gần cuối 0,27 s (nhanh) và 1,45 s (chính xác, đúng 240/240 khung); bộ nhớ tiến trình thử không vượt 103 MB.
  - Tự lưu 2 s; playlist 1.000 mục 0,06 s.
  - Số liệu đo trên media tổng hợp dễ mã hóa hơn cảnh quay thật: tốc độ xuất thực tế có thể **thấp hơn**.

## 5. Lỗi thật đã tìm ra và sửa trong quá trình làm (đều có test hồi quy)

1. Preset export của AVFoundation có thể sao chép luồng thay vì mã hóa lại → thay bằng pipeline đọc/ghi riêng.
2. PTS bị làm tròn theo timescale 600 → điểm cắt thừa/thiếu một khung ở 29,97 fps → dùng PTS thật + dời nửa khung theo quy tắc "khoảng hiển thị giao vùng cắt".
3. Phục hồi sau gián đoạn có thể **làm mất file gốc** nếu máy chết giữa hai lần đổi tên → nhật ký ghi trước, phục hồi theo trạng thái đĩa.
4. Buffer màu không gắn thẻ → preview và bản xuất lệch tới 13/255 → gắn thẻ màu theo nguồn.
5. Bấm Hủy đúng lúc vừa bắt đầu xuất làm **crash** trong MediaToolbox, và một dạng hủy khác làm treo → máy trạng thái hủy + đánh thức cổng.
6. Trộn playlist 1.000 mục mất 24 s → 0,06 s.
7. Video **không có âm thanh** không cắt nhanh được → bỏ track âm thanh rỗng.
8. **Đường compositor mất khung cuối mỗi đoạn** (đoạn 30…70 ra 30…68; ghép nhiều đoạn mất một khung ở mỗi chỗ nối) vì cắt hai đầu nửa khung chỉ đúng cho đường copy thẳng → lấy mẫu giữa khung trên lưới cố định; thêm test đếm khung và đồng bộ tiếng/hình cho đường này.
9. `PlayerController.load` ghi đè lệnh seek đến trong lúc đang tải (đặt lại thời gian sau các `await`).
10. Khi chỉ có lớp phủ (không chỉnh hình nào khác), builder vẫn coi hình chính là copy thẳng và cắt hai đầu nửa khung nên mất khung cuối. Lỗi do chính đợt này thêm vào, bị che bởi các test dùng thêm bộ lọc màu; self-test trong app bắt được, sau đó tái hiện và có test hồi quy.
11. Preset vị trí góc của lớp phủ đặt lớp ra ngoài khung (sai công thức chiều cao theo tỷ lệ khung); ghi keyframe trùng thời điểm làm trôi mốc thời gian.
12. **Nhóm race giữa tua và dựng lại preview** (phát hiện khi viết test kéo): (a) `currentTime` nháy về 0 khi dựng lại, (b) tua trong lúc dựng bị ghi đè bằng vị trí cũ vì vị trí được ghi nhớ ở đầu việc dựng, (c) lệnh tua bị cắt giữa chừng khi item bị thay vẫn công bố thời gian của item mới. Nay: giữ playhead tại đích, nhớ số lần tua ở đầu và cuối việc dựng, và không công bố khi item đã bị thay. Selftest chạy 6 lần liên tiếp đều qua.
13. Làm tròn kích thước chẵn (852 thay vì 854); ép bảng mã phụ đề âm thầm chuyển sang bảng mã khác; bước khung sai khi không có view.

14. **Nhiều track âm thanh:** khi file có hai track thay thế nhau (ngôn ngữ), preview và bản xuất có thể chọn khác track. Test dùng file có track 440 Hz đứng trước track mặc định 1 kHz nên lộ ra việc "track đầu" không phải "track mặc định" → dùng track đang bật (`isEnabled`).
15. **Dọn file dở không bao giờ được gọi:** `cleanStalePartials` có sẵn nhưng không có chỗ nào gọi; sau crash giữa lúc xuất, file `.partial` nằm lại. Nay được gọi khi khôi phục hàng đợi; kiểm chứng bằng 54 lượt `kill -9` trên app thật.
16. **HDR xuất ra sai bản chất:** nguồn HDR (HLG/PQ, 10-bit) xuất chính xác ra **HEVC 8-bit** mang nhãn HDR (dễ vỡ dải màu), trong khi giao diện báo "HDR sẽ chuyển sang SDR" (sai cả hai chiều). Do bench đọc lại profile HEVC của file kết quả. Nay đọc 10-bit và ghi HEVC Main10 giữ nhãn màu; chọn H.264 thì tự chuyển sang HEVC và cảnh báo nói đúng điều đó. Có 5 test hồi quy.
17. Công cụ đo tự mắc lỗi (không phải lỗi app, ghi lại để khỏi lặp lại): `AVPlayerItemVideoOutput` sau khi tua vẫn trả khung cũ cho tới khi khung mới giải mã xong, và tua tới thời điểm làm tròn theo timescale 6000 đáp xuống khung trước ở 4K/60 (app dùng thời điểm hữu tỉ của khung nên không dính). Ngoài ra helper lấp đầy ổ trong test làm tràn do đọc dung lượng trống đã bị lưu đệm.
19. **Cảnh báo Dolby Vision:** nguồn Dolby Vision xuất mã hóa lại mất dữ liệu Dolby Vision mà app không nói; nay nhận diện hộp `dvvC`/`dvcC` và cảnh báo (cắt nhanh giữ nguyên). Tìm ra nhờ video thật.
20. **Dolby Vision, truy cập ngẫu nhiên:** 88/1799 khung của file Dolby Vision thử (3 khung cuối mỗi nhóm 60 khung) không giải mã được khi nhảy thẳng tới (hệ thống báo "Cannot Decode"): tua/bước tới đó thì hình đứng yên ở khung cũ; phát tuần tự và xuất vẫn đúng. **Chưa sửa**, chưa rõ nguyên nhân hay có gặp ở video iPhone không.
21. Mốc thời gian của file cắt (đường copy thẳng / mã hóa lại không chỉnh hình) lệch nửa khung: khung đầu hiển thị 8,3 ms, nội dung và số khung đúng. **Chưa sửa** (quy tắc có chủ đích, có test).
22. Selftest: đóng/ẩn cửa sổ cuối làm chính app thoát im lặng giữa chừng; thêm cờ để selftest không tự thoát.
18. `activeSession` rơi về cửa sổ trống khi không có cửa sổ chính; nay ưu tiên cửa sổ đang có video.

## 6. Tệp bàn giao

- Mã nguồn: toàn bộ thư mục này. Mở bằng `swift build`/SwiftPM (không có `.xcodeproj`; không cần Xcode).
- `.app` chạy thử: `Scripts/build_app.sh` → `build/MacPlayer.app` (ký ad-hoc).
- `docs/format-matrix.md`: ma trận định dạng đã chạy thật. `docs/benchmark.md`: số đo hiệu năng. `docs/kiem-thu-video-that.md`: kiểm thử trên video thật.
- `CLAUDE.md`: hướng dẫn cho AI agent/người mới (công nghệ, cấu trúc, quy tắc, cách thêm tính năng, cách phát hành). Cập nhật cùng mỗi thay đổi lớn.
- Công cụ kiểm thử: `Scripts/test.sh`, `Scripts/crash_test.py`, `Scripts/open_with_test.py`, `Scripts/check_localization.py`; cách chạy trong README.
- Không sửa git config, không thay đổi ứng dụng khác, không gửi dữ liệu ra ngoài.


## Bổ sung: kiểm thử trên 111 video thật của người dùng
Xem `docs/kiem-thu-video-that.md` Phần 2. Lỗi 23–26 đã sửa: thứ tự khi thêm nhiều video, dư 1 khung khi xuất có chỉnh hình, lưới khung compositor ở 29,97/59,94 fps, cảnh báo Dolby Vision sai. Còn mở: độ dài khi ghép nhiều clip, bitrate mức Cao, hai ca nhỏ nêu trong tài liệu đó.

## Bổ sung lần 2: vòng sửa sau khi thử trên video thật (xem `docs/kiem-thu-video-that.md` Phần 3)
Đã sửa: độ dài khi ghép nhiều clip và việc ghép video khác kích thước/chiều quay; hình sai khi chỉnh sửa video HDR (compositor 10-bit); mức chất lượng "Cao" theo bitrate nguồn; cảnh báo khi ghép lẫn HDR và SDR. Kiểm thử cuối: Core 171, Media 88, selftest tổng hợp 103, luồng thật trong app 538, `realcheck` 83 ca xuất đều đạt, kill -9 và Open With đạt. Còn mở: tiếng ở tốc độ 2× dài hơn hình ~0,1 s; cắt nhanh clip 0,73 s không sao chép nguyên byte gói tiếng; toàn màn hình, USB, ngủ/thức, Intel, VoiceOver chưa kiểm thử được.

## Phát hành miễn phí
- `Scripts/make_release.sh` tạo `dist/MacPlayer-<phiên bản>.dmg`, `.zip` và `SHA256SUMS.txt` (đã chạy thử, đã kiểm checksum). Chữ ký ad-hoc, **chưa công chứng** (cần tài khoản Apple Developer trả phí); người dùng làm theo `docs/huong-dan-cai-dat.md` ở lần mở đầu.
- App không có mã nào dùng mạng; không thu thập dữ liệu.
- Giấy phép MIT đã thêm (`LICENSE`, tên bản quyền "MacPlayer contributors", có thể sửa). Còn cần quyết định: bundle id (hiện `local.macplayer.app`), tên hiển thị, nơi đăng tải.

## Bổ sung 0.3.0–0.7.0 (09/11/2026)

Mỗi nhóm tính năng ra một phiên bản mới (quy tắc của người bảo trì: sửa app thì phải ra phiên bản mới và cài lại vào `/Applications`).

| Bản | Nội dung | Kiểm chứng |
|---|---|---|
| 0.2.1 / 0.3.0 | Cây thư mục: file trong thư mục hiện dạng danh sách hoặc lưới (nhớ lựa chọn); thanh trượt cỡ ảnh xem trước (nhớ giá trị); viền **xanh lá** cho file đang mở, viền **màu nhấn + dấu tích** cho file đang chọn (đổi tên/Thùng rác/gỡ). Trước đó: chọn nhiều file, đổi tên hàng loạt, chuyển nhiều file vào Thùng rác, cây thư mục, hỏi tên khi tạo danh sách mới | Test Core (`FolderTree`, `PreviewSize`, `TreeFiles`, `BatchRename`), chụp cửa sổ app thật ở 4 chế độ; ổ ảnh thật không gắn lúc kiểm nên dùng thư mục ảnh mẫu 50 ảnh |
| 0.4.0 | **Chỉnh màu chuyên nghiệp**: phơi sáng, vùng sáng/tối, rực màu, sắc thái, đường cong (sáng + R/G/B), 3 bánh xe màu, HSL 8 màu, nạp `.cube`, histogram, so sánh/sao chép/dán/áp cho mọi đoạn | `ColorGradingTests` (toán), `ColorGradeTests` (điểm ảnh thật, kể cả **video xuất ra** và file `.cube` đọc từ đĩa), chụp giao diện |
| 0.5.0 | **Tách nền**: xóa nền người/chủ thể (Vision, trên máy), phông xanh cho video chính, mặt nạ 6 hình (mềm viền, đảo), màu/bản sao mờ thay thế, 10 chế độ hòa trộn cho lớp phủ | `MaskTests` (hình học, điểm ảnh, lớp phủ, tương thích dự án cũ); Vision chỉ kiểm bằng mask giả (`SubjectMasker.provider`) và gọi thật trên ảnh phẳng không lỗi — **chưa thử trên người thật** |
| 0.6.0 | 8 chuyển cảnh mới (tổng 17), 6 easing cho keyframe (lớp phủ, chữ/hình dán, "phóng to và dời"), xoay cho lớp phủ và "phóng to và dời", hoạt ảnh xuất hiện/biến mất cho lớp phủ | `EasingAnimationTests`, `MoreTransitionAndTurnTests` (điểm ảnh: mọi chuyển cảnh bắt đầu ở hình cũ và kết thúc ở hình mới, quét/vòng tròn, lớp xoay đứng, zoom-and-move xoay) |
| 0.7.0 | **Giọng và hiệu ứng âm thanh**: 8 mẫu một chạm + tự chỉnh (trầm/trung/cao, cao độ, phòng, dội) qua AVAudioEngine chạy offline trên bản sao; **đường âm lượng vẽ tay** cho từng âm thanh | `SoundFXTests` (âm thuần: cao độ gấp đôi, EQ đổi mức, dội xuất hiện trong khoảng lặng, bộ nhớ đệm, xuất video mang âm đã đổi), `VolumeCurveTests` |

Tổng số test sau đợt này: Core 360, Media 214 (đều đạt, ngoại trừ test ổn định hình bên dưới).

**Chưa kiểm chứng / lưu ý trung thực**

- Chưa thao tác bằng chuột thật trên các giao diện mới (bánh xe, đường cong, vẽ âm lượng, kéo thanh trượt trong tab Lớp); mới chụp cửa sổ app thật và kiểm logic bằng test. Các giao diện của tab Lớp và bảng Chuyển cảnh mới **chưa chụp được** (cần chế độ Dự án).
- Vision (xóa nền) chưa thử trên người thật; xem trước video dùng chế độ nhanh nên thô hơn bản xuất.
- `StabilizerTests.anExportedVideoIsSteadierThanTheOneItCameFrom` chập chờn (hỏng khoảng một nửa số lần chạy, cả ở commit cũ trước các thay đổi này). Self-test trong app còn 2 kiểm tra hỏng từ trước (cỡ cửa sổ sau slideshow ảnh; trùng phím tắt do mục hệ thống "Emoji & Symbols", "Enter Full Screen") và không được chạy lại ở các bản 0.4–0.7.
- Video HDR: màu áp lên giá trị HDR đang lưu, không chuyển tông (app cảnh báo).
- Đã tham khảo **ý tưởng** tính năng từ một ứng dụng chỉnh sửa video phổ biến để xếp thứ tự ưu tiên; không sao chép mã, tài nguyên hay hiệu ứng, và bỏ qua phần cần mạng/AI đám mây.


## Bản 0.7.1: sửa lỗi tìm ra khi chạy trên video và ảnh thật (10/11/2026)

Chạy self-test của app trên 8 video thật (bản sao) và 2.703 ảnh thật (chỉ đọc) cho thấy cắt chính xác thất bại trên 6 video nhỏ; kiểm chứng thêm 11 điểm nghi lỗi từ việc đọc mã. Tất cả đã được tái hiện bằng test hoặc đọc mã trước khi sửa.

| # | Lỗi | Sửa | Kiểm chứng |
|---|---|---|---|
| 1 | Cắt chính xác lỗi `-12651 "Tham số mã hóa không được hỗ trợ"` với video có âm thanh 22,05/24 kHz (bộ mã hóa AAC luôn đặt 160 kb/s stereo) | `AACSettings.bitRate(sampleRate:channels:)` chọn mức hợp lệ theo tần số lấy mẫu | Test `AVAssetWriter.canApply` cho 8 tần số × mono/stereo; xuất thử video 22,05 kHz; lượt self-test thật trên 8 video: các lỗi `-12651` biến mất |
| 2 | Bảng Xuất báo "cắt nhanh được" trong khi kế hoạch xuất từ chối (hai điều kiện khác nhau, một bên bỏ qua âm thanh thêm vào và tốc độ) | Một điều kiện duy nhất `Project.allowsFastCut` | Test Core |
| 3 | Ghép nhiều đoạn vẫn ghi cứng phụ đề dù đã tắt "ghi cứng" (`joinedRecipe` bỏ qua tham số) | Truyền `burnIn` đúng | Test Core |
| 4 | Tách/cắt animation "phóng to và dời" làm mất góc xoay (và kiểu easing) của keyframe đầu | `Motion.shifted` giữ cả hai | Test Core |
| 5 | Freeze frame lâu hơn ~3,3 s ở 30 fps bị rút ngắn (tốc độ bị kẹp ở 0,01 ở chỗ này nhưng không kẹp ở chỗ khác) | `VideoLook.minimumSpeed` dùng chung mọi nơi | Test Core (0,5–10 s) và test Media đo độ dài thật của timeline dựng |
| 6 | Thông báo lỗi nhận dạng giọng nói hiện nguyên `\(l)`, tên file tạm trùng nhau | Sửa chuỗi, tên file tạm có UUID | Test Media |
| 7 | Mặt nạ hình và mặt nạ chủ thể bị lệch khi hình có viền đen (fit trong canvas khác tỷ lệ) | Mặt nạ hình làm bằng kích thước hình đã đặt; mặt nạ chủ thể không bị tịnh tiến hai lần | Test Media bằng điểm ảnh (viền trên/dưới và hai bên, chủ thể giả); trên ảnh thật 3024×4032 vào canvas vuông có Vision thật |
| 8 | Âm thanh trễ kết hợp tốc độ khác 1×: một phần phát đúng tốc độ, phần cuối phát 1× và kéo dài quá hình; âm trễ của đoạn này đẩy âm của đoạn sau | Độ trễ làm sau khi áp tốc độ, phần đuôi bị cắt; số giây tính theo thời gian của hình xuất | Test Media (4 cặp tốc độ/độ lệch + hai đoạn liền nhau); trên clip `.mov` thật có âm thanh |
| 9 | Bấm "Chạy lại" lần đầu sau sự cố không làm gì; việc mới bị chặn bởi việc khôi phục | Việc khôi phục không chiếm chỗ của việc mới; "Chạy lại" thả chúng ra | Test Core (`nextToStart(includeRestored:)`, `releaseRestored`); luồng giao diện chỉ được đọc mã và biên dịch, **chưa bấm thật** |
| 10 | Bộ chọn track âm thanh luôn hiện lựa chọn đầu | `PlayerController.audioSelectionIndex` | Chỉ biên dịch và đọc mã, chưa kiểm bằng giao diện thật |
| 11 | Tên Hoàn tác/Làm lại không được dịch ("Hoàn tác Add clip") | Dịch qua `L()`, thêm 59 tên vào `vi.lproj` | `check_localization.py`: 0 thiếu; chỉ kiểm bằng đọc mã, chưa nhìn thực tế menu |
| 12 | Self-test khẳng định sai danh sách tab của ảnh | Cập nhật khẳng định | Chưa chạy lại self-test đầy đủ |
| – | `AudioSettings` mở file thiếu khóa lỗi (rủi ro, chưa phải lỗi đã gặp) | Bộ giải mã tùy chỉnh `decodeIfPresent` | Test Core |

Test sau đợt này: Core 366 + 6 mới đều đạt; Media 223 (gồm 12 mới), chỉ `StabilizerTests.anExportedVideoIsSteadierThanTheOneItCameFrom` chập chờn như đã ghi.

**Còn mở:** cắt chính xác `cam-nang-san-9.mp4` (88 phút) lệch 2 khung ở khung cuối trong self-test thật (chưa tìm ra nguyên nhân; `cam-nang-san-7.mp4` đạt); các kiểu dữ liệu khác (`SoundClip`, `OverlayClip`, `ExportOptions`…) vẫn giải mã nghiêm ngặt, thêm trường không tùy chọn sẽ làm file cũ không mở được (nên làm như `AudioSettings`); mặt nạ chủ thể trên người thật mới thử qua một ảnh thật.


## Bản 0.8.0: tách Danh sách phát và Chỉnh sửa, bỏ chế độ nhanh và "thay bản gốc" (11/11/2026)

**Đã làm**

| Phần | Nội dung |
|---|---|
| Điều hướng | Trang chủ 2 nút (Danh sách phát ⌘1, Chỉnh sửa ⌘2, ⇧⌘H về Trang chủ). Mỗi cửa sổ có màn hình riêng (`WindowRoute`). Danh sách phát chỉ xem/đổi tên/Thùng rác, không có bảng công cụ. File từ Finder/kéo thả/dòng lệnh mở để xem; file `.macplayer` mở vào trình chỉnh sửa; mở lại một dự án đang mở thì đưa cửa sổ đó lên. |
| Chỉnh sửa từ lúc xem | Nút Chỉnh sửa (⌘E) → hỏi → chọn nơi lưu → dự án mới có sẵn file đang xem. Hủy ở mọi bước không tạo gì. |
| Hai loại dự án | `Project.kind` video/ảnh, schema 3. Dự án ảnh đúng một ảnh (+ chữ, hình, **logo**); thả/thêm sai loại bị chặn bằng `ProjectRules`. Đổi ảnh giữ chỉnh sửa, đặt lại khung cắt nếu khác tỉ lệ, hoàn tác được. |
| Danh sách dự án | Sổ đăng ký (`Projects/registry.json`): thẻ có ảnh đại diện, nhãn Video/Ảnh, lọc, sắp xếp, tìm không dấu (kể cả "đ"). Theo dấu file bị đổi tên/di chuyển qua bookmark; ổ chưa cắm, file mất, file trong Thùng rác được phân biệt; không bao giờ tự bỏ mục. Đổi tên (đổi file, không ghi đè, hoàn tác nếu ghi sổ lỗi), Thùng rác (hỏi, Hủy mặc định, chỉ file dự án, dọn dữ liệu khôi phục), Bỏ khỏi danh sách, Tìm lại. |
| Tự lưu | Ghi thẳng file dự án qua `ProjectFileWriter` (tuần tự, bỏ bản cũ hơn, bản khôi phục trước, so dấu vân tay để không đè thay đổi từ nơi khác, đọc lại kiểm tra). ⌘S = lưu ngay; bỏ "Lưu thành"; đóng cửa sổ/thoát app ghi trước, lỗi thì hỏi Thử lại / Lưu vào chỗ khác / Vẫn đóng. Snapshot giờ được cắt tỉa (trước đây `pruneSnapshots` không được gọi). |
| Bỏ chế độ nhanh | Dự án `.quick` cũ nâng cấp khi mở (video → một đoạn mang chỉnh sửa; âm thanh/mốc theo tốc độ như bản xuất cũ; vùng In–Out giữ trong file; ảnh → dự án ảnh); bản cũ chép vào Recovery trước lần ghi đầu. Bỏ In/Out, xuất từng đoạn, cắt nhanh trong giao diện, tab Ảnh bìa. |
| Bỏ "thay bản gốc" | Gỡ `replaceOriginal`, `ReplacePlan`, ghi nhật ký, sao lưu, phát hiện nguồn bị đổi, lựa chọn trong bảng Xuất video/ảnh và Cài đặt, test/self-test/script/chuỗi liên quan. Giữ đọc nhật ký cũ (`recoverLegacyReplaceJournals`) và đọc job cũ trong hàng đợi (đánh dấu thất bại, không chạy). |
| Chặn ghi đè | Lưu khung hình không bao giờ ghi đè file có sẵn; xuất âm thanh/CSV/SRT/VTT qua `OriginalGuard`; so đường dẫn bằng `PathUtil.same` (tên tiếng Việt có hai dạng Unicode). |

**Đã kiểm thử (chạy thật)**
- `Scripts/test.sh`: Core 378, Media 223 đều đạt (kể cả `StabilizerTests` lần này). Test mới: nâng cấp dự án cũ, luật dự án, ghi file dự án an toàn, sổ đăng ký, hàng đợi cũ có job thay bản gốc, logo trên ảnh (điểm ảnh).
- Self-test trong app thật (`--selftest`, media tổng hợp): 292 PASS, 1 FAIL là lỗi đã biết trước (menu hệ thống "Emoji & Symbols"/"Enter Full Screen" trùng phím).
- `open_with_test.py`: 15/15 đạt (video mở để xem, `.macplayer` mở vào trình chỉnh sửa, mở lại không trùng cửa sổ).
- `crash_test.py`: 18 lần `kill -9` (bản sao, hàng loạt, **đang tự lưu liên tục**) đều đạt: nguồn không đổi, file dự án luôn đọc được.
- App thật trên bản sao: file `.quick` cũ (schema 2) mở thành dự án video schema 3, giữ góc xoay, có bản cũ trong Recovery; nhật ký thay bản gốc của bản 0.7 (tự tạo) được khôi phục đúng từng byte; SHA của video/ảnh nguồn không đổi sau mọi lần chạy.
- Ảnh chụp cửa sổ: Trang chủ, Danh sách phát, Danh sách dự án (trống và có thẻ), trình chỉnh sửa video, trình chỉnh sửa ảnh, xem video. Nhờ chạy thật đã sửa: một dự án bị liệt kê 2 lần (tên NFC/NFD), chạy sandbox nhập nhầm danh sách gần đây thật, thẻ dự án ảnh rộng quá cột.

**Chưa kiểm thử / chưa làm**
- Chưa thao tác chuột thật: hộp chọn loại dự án, hộp chọn nơi lưu, đổi tên/Thùng rác từ danh sách dự án, kéo thả vào từng màn hình (chỉ kiểm qua mã và self-test gọi hàm).
- Lưu dự án trên ổ mạng/exFAT/iCloud, gỡ ổ khi đang tự lưu: chưa thử thật. Danh sách "gần đây" của macOS có tự theo file đổi tên hay không: chưa kiểm.
- Hàng đợi cũ (định dạng thật của 0.7) có job thay bản gốc: kiểm bằng test Core, chưa bằng app với file do 0.7 ghi.
- Logo trên ảnh chỉ đặt bằng nút/thanh trượt (chưa kéo trực tiếp trên ảnh). Danh sách dự án chưa có phím Return/⌘⌫ cho thẻ đang chọn.
- Ngoài phạm vi (đã chốt): xuất từng đoạn thành file riêng, nhân bản dự án, lớp phủ video trong dự án ảnh.


## Bản 0.8.1: timeline đứng yên và nhấp nháy ở dự án video mới (11/11/2026)

**Lỗi người bảo trì gặp:** tạo dự án video rồi thêm 3 video dọc (1080×1918/1920, 14–51 s); bấm phát thì thanh timeline "không chạy" và nhấp nháy, dù nội dung và tổng thời lượng đúng.

**Nguyên nhân (đã tái hiện trong cửa sổ thật, chụp riêng cửa sổ MacPlayer):** thanh timeline tính vùng hiển thị một lần khi mở, lúc dự án còn **trống** (độ dài 0 → vùng nhìn ~0,001 s), và không tính lại khi video được thêm vào. Kết quả: thanh chỉ hiện vài khung quanh đầu phát; khi phát nó cuộn theo ở mỗi khung nên đầu phát trông đứng yên và nội dung bên dưới nhấp nháy. Trình phát vẫn chạy đúng (đã đo: 3 s chạy 3 s, không dựng lại preview). Lỗi lộ ra ở 0.8.0 vì mọi dự án mới đều bắt đầu trống.

**Sửa:** vùng nhìn tách thành `TimelineViewport` (Core, thuần): khi độ dài dự án đổi, nếu đang xem toàn bộ (hoặc chưa có gì) thì xem lại toàn bộ; nếu đang phóng to một đoạn thì giữ đoạn đó trong độ dài mới. Phóng/cuộn/bám đầu phát dùng chung các quy tắc này.

**Kiểm thử:** 4 test Core mới (`TimelineViewportTests`); luồng self-test mới G0 tạo dự án trống trong cửa sổ thật, thêm 3 video khác loại, phát và kiểm: thanh hiện toàn bộ dự án, không cuộn khi đang xem toàn bộ, đầu phát chạy, preview không bị dựng lại, khung hình không bị bố trí lại, giao diện không nghẽn. Chụp cửa sổ thật trước/sau khi sửa với 3 video dọc tổng hợp cùng kích thước và thời lượng của bạn. **Chưa thử trên chính 3 file thật của bạn** (không mở media của bạn khi chưa được phép).


## Bản 0.8.2: giao diện khựng khi chuyển qua lại bộ lọc màu và chuyển cảnh (11/11/2026)

**Lỗi người bảo trì gặp:** trong trình chỉnh sửa video, chuyển qua lại giữa các bộ lọc màu và các kiểu chuyển cảnh thì giao diện bị đơ.

**Nguyên nhân (tìm bằng đọc mã và đo; chưa bắt được trên máy và video thật của người bảo trì):**
- Biểu đồ màu ở tab Màu làm mới theo vị trí đầu phát (làm tròn 0,25 s). Khi đang phát, nó đọc **chính xác** một khung **4 lần mỗi giây**, lại đọc từ **video nguồn đầu tiên tại thời điểm của timeline** (sai video, sai thời điểm). Với video keyframe thưa, mỗi lần mất 130–165 ms (đo trên video 1080×1920 keyframe mỗi 15 s), tức bộ giải mã bận khoảng một nửa thời gian, tranh với trình phát.
- Ảnh xem trước của 11 bộ lọc và 18 chuyển cảnh được đọc và vẽ lại **mỗi lần mở tab** (chuyển tab làm mất ảnh đã vẽ), và phần vẽ chạy trên luồng giao diện.

**Sửa:** `EditorSession+ToolFrames.swift`: một chỗ lấy khung cho công cụ: đúng đoạn tại đầu phát, đọc nhanh (khung gần nhất), mỗi khung một lần đọc, có bộ nhớ đệm; khi đang phát dùng lại khung gần nhất của cùng video. Biểu đồ màu không làm mới khi đang phát. Ô xem trước vẽ ở luồng nền và được giữ lại khi chuyển tab.

**Kiểm thử:** self-test luồng G1 (dự án 3 video dọc keyframe thưa trong cửa sổ thật, đang phát và đang dừng): mở tab Màu khi đang phát đọc 0 khung (mã cũ: ~8 lần đọc chính xác trong 2 s); 18 lần chuyển tab + 12 lần chọn chỉ đọc 2 khung; giao diện nghẽn tối đa ~55 ms. Test Core 382, Media 223 đạt.

**Chưa kiểm chứng:** chưa chạy trên chính video và ổ USB của người bảo trì; chưa thao tác chuột thật trên các ô. Mỗi lần chọn chuyển cảnh vẫn dựng lại preview (cần thiết vì cách vẽ thay đổi), nên hình có thể dừng một nhịp ngắn.



## Bản 0.8.3: vẫn khựng khi chọn chuyển cảnh/bộ lọc trên dự án thật; con trỏ bàn tay (11/11/2026)

**Người bảo trì báo:** với dự án `Bài tập cảm giác bóng.macplayer` (ổ Lexar), chọn qua lại giữa các chuyển cảnh/bộ lọc vẫn bị đơ. Yêu cầu thêm: mọi chỗ bấm được đổi con trỏ thành bàn tay.

**Đã làm với dự án thật (chỉ trên bản sao file dự án; video trên ổ Lexar chỉ được đọc, mã băm không đổi):** dự án có 2 đoạn từ cùng một video 716×1276 dài 5:46, đoạn 2 có chuyển cảnh "Trượt trái" và bộ lọc "Kịch tính". Luồng G1 mở bản sao này trong cửa sổ thật, chọn 6 bộ lọc và 6 chuyển cảnh xen kẽ, khi dừng và khi đang phát.

**Nguyên nhân còn lại tìm được:** mỗi lần chọn một kiểu chuyển cảnh khác, preview bị **dựng lại toàn bộ** (thay item của trình phát): hình đứng/đen một nhịp, nếu đang phát thì khựng. Bộ lọc thì đã đổi trực tiếp từ 0.7.

**Sửa:** đổi kiểu chuyển cảnh (cùng độ dài, preview đã có bộ vẽ) được đưa thẳng cho bộ vẽ (`TransitionLive`, giống cách bộ lọc làm), không dựng lại preview. Thêm/bỏ chuyển cảnh hoặc đổi độ dài vẫn dựng lại vì đoạn phim dùng thay đổi.

**Con trỏ bàn tay:** mọi nút, công tắc, menu chọn, ô chọn màu, thẻ và dòng bấm được (thẻ dự án, dòng danh sách phát, ô bộ lọc/chuyển cảnh, mã thời gian, nút tắt tiếng…) hiện bàn tay khi rê chuột (`PointerControls.swift`).

**Kiểm thử:** test Media mới (kiểu chuyển cảnh mới được vẽ ngay, không dựng lại; xoá thì về như lúc dựng). G1 trên bản sao dự án thật, bản release: 12 lần chọn, **0 lần dựng lại preview** (trước: mỗi lần chọn chuyển cảnh một lần), giao diện nghẽn tối đa 58–80 ms, cả khi dừng và khi đang phát. Một lần build release trước đó đếm được 2 lần dựng lại, không rõ nguồn (khi ấy chưa ghi lý do); 6 lần chạy sau, có ghi lý do, đều là 0. Test Core 382 đạt; Media 224, trong đó `anExportedVideoIsSteadierThanTheOneItCameFrom` (chống rung) **lúc đạt lúc trượt**: mã 0.8.1 đã commit cũng trượt 1/3 lần, không do bản này. Self-test toàn bộ: 304 đạt, 1 lỗi đã biết (phím tắt menu hệ thống trùng). `check_localization`: 0 thiếu.

**Chưa kiểm chứng (nói thẳng):** chưa bấm chuột thật trên các ô. Phép bấm tự động qua cửa sổ không chạy được vì app chạy nền không được macOS cho làm app đang dùng. **Con trỏ bàn tay chưa được nhìn thấy:** ảnh chụp cửa sổ không có con trỏ, mới chỉ build được. Không bắt được tình trạng "đơ" hàng giây nào: nhật ký hệ thống không có báo cáo treo của MacPlayer. Nếu bản 0.8.3 vẫn đơ, cần lấy mẫu (`sample`) đúng tiến trình đang chạy trong lúc tái hiện.


## Bản 0.9.0: trình chỉnh sửa video kiểu CapCut, kéo-thả trong app (11/11/2026)

**Yêu cầu:** chế độ chỉnh sửa khó dùng, chưa kéo-thả được trong app, giao diện chưa hợp lý. Người chưa biết dựng phim cũng phải dùng được; lấy CapCut (`/Volumes/Lexar 256GB/Applications/CapCut.app`) làm mẫu.

**Cách tham khảo CapCut:** chỉ lấy **cách bố trí** quen thuộc của CapCut và các app dựng phim (thư viện bên trái, khung xem ở giữa, thuộc tính bên phải, timeline nhiều làn ở dưới, kéo-thả). Không mở CapCut, không đọc hay chép mã, ảnh, hiệu ứng hay chữ của nó; chỉ xem danh sách thư mục trong gói app.

**Đã làm:**
- **Bố cục mới cho dự án video.**
  - Thư viện | Khung xem | Thuộc tính, ba bảng kéo đổi rộng được.
  - Bên dưới, kéo hết chiều ngang: thanh công cụ và timeline.
  - Nút Xuất ở góc trên bên phải. Bảng Thuộc tính đóng/mở bằng mục menu "Hiện/Ẩn công cụ" như trước.
- **Thư viện:**
  - **Media:** nhập file hoặc kéo từ Finder; thư mục được bung ra; file không phải media bị bỏ qua và có thông báo. Mỗi ô có ảnh nhỏ, độ dài, dấu ✓ khi đang dùng, nút + và menu chuột phải.
  - **Âm thanh:** nhập nhạc, ghi âm giọng, hiệu ứng âm thanh.
  - **Chữ:** 8 kiểu chữ và nhãn dán.
  - **Bộ lọc:** 11 ô, xem trước trên chính khung hình của đoạn.
  - **Chuyển cảnh:** 17 ô có hình minh hoạ.
  - Dự án chỉ ghi nhớ **đường dẫn**: không chép, không sửa, và "Bỏ khỏi Thư viện" không đụng tới file.
- **Timeline vẽ lại:**
  - Ảnh thu nhỏ trên từng đoạn, sóng âm, nhãn tốc độ/bộ lọc/tắt tiếng, huy hiệu chuyển cảnh.
  - Thêm làn **Chữ** và làn **Âm thanh**: trước đây chữ và nhạc không hiện trên timeline.
  - Bấm để chọn; bấm chỗ trống để bỏ chọn và dời đầu phát. Kéo để dời, có bám dính. Kéo mép để đổi độ dài.
  - Con trỏ đổi theo việc sẽ làm (↔ ở mép, bàn tay trên mục). Menu chuột phải theo thứ đang chọn.
- **Âm thanh trên timeline:** kéo để dời, kéo mép để đổi độ dài (không vượt quá độ dài file).
- **Thả vào timeline:**
  - video chèn đúng vị trí, thả trên làn lớp thì thành lớp;
  - ảnh thành lớp, nhạc vào làn âm thanh;
  - bộ lọc lên đoạn, chuyển cảnh vào chỗ nối gần nhất;
  - kiểu chữ hoặc nhãn dán vào một thời điểm.
  - Khi đang kéo, chỗ sẽ thả được tô sáng.
- **Thuộc tính theo thứ đang chọn:**
  - đoạn video: Cơ bản, Màu, Hiệu ứng, Tốc độ, Âm thanh, Chuyển cảnh, Cắt nền;
  - lớp, chữ, âm thanh: phần chỉnh tương ứng;
  - chưa chọn gì: Tổng quan (có hướng dẫn 4 bước khi dự án trống), Phụ đề, Xuất.
  - Đầu bảng có nút Nhân đôi, Xoá, Bỏ chọn.
- **Phím:** ⌫ xoá thứ đang chọn (đoạn, lớp, chữ hoặc âm thanh), Esc bỏ chọn.

**Kiểm thử:**
- Test Core mới `MediaBinTests` (4). Tổng: Core 386, Media 224, đều đạt.
- Luồng self-test mới **G2**: 34 kiểm tra trong cửa sổ thật. Các lần thả đi qua đúng mã nhận thả của timeline với pasteboard thật, gồm:
  - bố cục và timeline kéo hết chiều ngang;
  - nhập Thư viện, chặn trùng, bỏ file lạ;
  - thả video, ảnh, nhạc, bộ lọc, chuyển cảnh, kiểu chữ;
  - chọn, nhân đôi, xoá, hoàn tác, dời chữ và âm thanh, kéo mép âm thanh;
  - Xuất, đóng/mở bảng Thuộc tính;
  - lưu rồi mở lại; file gốc không đổi một byte.
- Chụp cửa sổ thật với bản sao dự án của người bảo trì và với dự án thử.

**Chưa kiểm chứng / chưa làm (nói thẳng):**
- **Chưa kéo bằng chuột thật.** Kéo-thả SwiftUI từ Thư viện sang timeline (`onDrag`) và kéo từ Finder chưa được thử bằng tay; mã nhận thả thì đã được thử như trên.
- **Dự án ảnh vẫn dùng bố cục cũ** (lưới công cụ bên phải).
- **Ảnh chưa đặt được trên làn video chính:** ảnh luôn thành lớp chồng lên video. Muốn có trình chiếu ảnh như CapCut cần chuyển ảnh thành đoạn video; chưa làm.
- Self-test toàn bộ (trước khi thêm kéo mép âm thanh): 335 đạt, 1 lỗi đã biết (phím tắt menu hệ thống trùng).


## Bản 0.10.0: làm nốt các mục còn thiếu của 0.9.0 (11/11/2026)

**1. Ảnh trên làn video chính. Đã làm.**
- **Cách hoạt động:**
  - Thả ảnh lên làn video (hoặc bấm + trên ảnh trong Thư viện) thì ảnh thành một đoạn riêng, mặc định 5 giây, kéo mép tới 60 giây.
  - MacPlayer tạo một video ngắn không tiếng của ảnh (1 khung/giây) trong thư mục riêng của nó (`Stills`); ảnh gốc chỉ được đọc.
  - Nếu video ngắn đó mất (máy khác, thư mục bị dọn), mở dự án thì nó được tạo lại từ ảnh. Ảnh gốc bị dời chỗ thì "Liên kết lại…" cho chọn ảnh.
  - Thả lên làn Lớp thì ảnh vẫn là lớp chồng lên video như trước.
- **Lỗi thật tìm ra khi thử:** video xuất có đoạn ảnh chỉ còn **15 khung/giây** (thay đổi khung/giây), vì phần ảnh chỉ có 1 khung/giây. Đã sửa ba chỗ:
  - bộ vẽ nay vẽ đủ mọi khung (`containsTweening`); cũng nhờ vậy chữ động trên nền ảnh không còn bị đứng;
  - đoạn ảnh không được quyết định nhịp khung của cả video;
  - bộ xuất lấy nhịp theo bộ vẽ.
  - Đã đo trên file xuất: 30 khung/giây đều, không còn khoảng hở 1 giây.

**2. Dự án ảnh dùng bố cục mới. Đã làm.**
- Thư viện bên trái có các tab:
  - **Ảnh:** ảnh đầu tiên là ảnh chính, các ảnh sau thành logo; chỉ nhận ảnh.
  - **Chữ:** kiểu chữ và nhãn dán.
  - **Bộ lọc:** xem trước trên chính ảnh.
- Kéo bộ lọc, kiểu chữ, nhãn dán thả thẳng lên ảnh. Thả chuyển cảnh thì có thông báo vì ảnh không có chỗ nối.
- Bên phải là mọi công cụ ảnh (Cơ bản, Màu, Cắt nền, Hiệu ứng, Lớp, Chữ, Xuất); nút Xuất ở góc trên.

**3. Kéo bằng chuột thật. Làm được phần máy tự kiểm được; phần còn lại cần người bấm.**
- **Đã kiểm:** self-test dùng đúng `NSItemProvider` mà các ô Thư viện giao cho hệ thống khi kéo (file video/âm thanh, bộ lọc, kiểu chữ), đổ vào pasteboard theo từng kiểu dữ liệu như hệ thống làm, rồi thả vào timeline và lên ảnh qua đúng mã nhận thả.
- **Phát hiện:** khi kéo một chuỗi văn bản, hệ thống còn gắn thêm kiểu `public.url`. Timeline chỉ nhận URL **file** nên không bị nhầm (đã kiểm).
- **Chưa làm được:** một lần kéo bằng con trỏ thật. Kéo-thả của macOS đi theo con trỏ thật trên màn hình, mà quy tắc của dự án là không điều khiển chuột trên màn hình của người dùng; app chạy nền cũng không được macOS cho làm app đang dùng. Cách thử bằng tay (khoảng 1 phút):
  1. Mở một dự án video. Kéo một video từ Finder vào Thư viện, rồi từ Thư viện xuống làn video.
  2. Kéo một ảnh xuống làn video, rồi kéo một ảnh khác lên làn Lớp 1.
  3. Kéo bộ lọc "Đơn sắc" thả lên một đoạn; kéo chuyển cảnh thả vào chỗ nối; kéo kiểu chữ "Neon" xuống làn Chữ.
  4. Mở một dự án ảnh, kéo bộ lọc và kiểu chữ thả lên ảnh.

**Kiểm thử 0.10.0:**
- Core 387 (thêm test đoạn ảnh), đạt hết.
- Media 227 (thêm `StillClipTests`: ảnh thành video tĩnh, ảnh gốc không đổi; video + ảnh xuất 150 khung đều 30/giây; chữ mờ dần trên nền ảnh thật sự đổi độ sáng). 226 đạt. Test chống rung lại trượt một lần trong cả bộ, rồi đạt 4/4 khi chạy riêng (đã biết là lúc đạt lúc trượt).
- Self-test toàn bộ: 361 đạt, 1 lỗi đã biết (phím tắt menu hệ thống trùng). Gồm G2 (thêm: ảnh lên làn chính, kéo dài, xuất 30 khung/giây có đúng màu ảnh, tạo lại video tạm, kéo qua dữ liệu kéo thật của các ô) và G3 mới (dự án ảnh, 13 kiểm tra).
- Chụp cửa sổ thật: dự án ảnh có Thư viện/Thuộc tính; dự án video có đoạn ảnh trên timeline.


## Bản 0.11.0: thêm và dời chữ, nhãn dán, hình, ảnh ngay trên khung hình (11/11/2026)

**Yêu cầu:** muốn thêm hay đổi vị trí chữ, nhãn dán, hình… mà không phải chọn qua hai bảng trái/phải; kéo-thả vào bất kỳ chỗ nào trên khung hình.

**Đã làm:**
- **Thả đúng chỗ:**
  - Kéo kiểu chữ, nhãn dán, **hình** (nhóm mới trong tab Chữ: vuông, bo góc, tròn, tam giác, sao, tim, mũi tên, đường kẻ) từ Thư viện thả lên khung hình: phần tử nằm đúng điểm thả.
  - Kéo một ảnh (từ Thư viện hoặc Finder) thả lên khung hình: ảnh thành lớp (video) hay logo (dự án ảnh) có tâm tại điểm thả.
  - Làm được ở cả dự án video lẫn dự án ảnh.
- **Kéo trên khung hình:**
  - Mỗi chữ, nhãn dán, hình đang hiện có khung nét đứt. Bấm để chọn (bảng phải mở phần Chữ); thứ đang chọn có khung trắng và 4 núm tròn.
  - Kéo thân để dời, kéo núm góc để phóng to/thu nhỏ.
  - Gần giữa khung thì tự bám vào giữa, có đường gióng vàng; giữ ⌥ để thả tự do.
  - Phần tử có keyframe thì được thêm keyframe tại đầu phát.
  - Logo trong dự án ảnh nay cũng kéo, đổi cỡ ngay trên ảnh (trước chỉ chỉnh bằng thanh trượt).
- **Hình đổi ngay khi kéo:** dự án video không phải dựng lại preview (`ElementLive`, giống cách bộ lọc và lớp làm). Mỗi lần kéo là một bước Hoàn tác.
- **Dự án ảnh:** khung cắt không còn tự hiện khi mở công cụ Cơ bản. Bật "Chỉnh ngay trên ảnh" hoặc bấm một tỉ lệ để cắt; khi khung cắt hiện, các khung chữ và logo tạm nhường chỗ.

**Lỗi thật tìm ra khi thử:** khi có thông báo dưới khung hình (ví dụ "Đã thêm vào Thư viện…"), thanh thông báo đòi tới khoảng 690 điểm chiều cao và **bóp khung hình còn 0**. Người dùng sẽ thấy hình biến mất lúc có thông báo. Đã sửa ở mọi bố cục: thông báo tối đa 2 dòng (rê chuột xem đủ), khung hình luôn giữ ít nhất 160 điểm.

**Kiểm thử:**
- Media: thêm `CanvasElementTests`.
  - Preview đi theo lúc kéo ngay, còn bản xuất luôn vẽ đúng giá trị đã lưu.
  - Khung tính ra khớp chỗ chữ thật sự được vẽ.
- Tổng: Core 387 và Media 229, đều đạt.
- Self-test toàn bộ: 380 đạt, 1 lỗi đã biết (phím tắt menu hệ thống trùng).
- Self-test mới **G4** (18 kiểm tra). Thả đi qua đúng mã nhận thả của khung hình với dữ liệu kéo thật của các ô; kéo gửi sự kiện chuột vào chính các khung. Kiểm:
  - thả chữ, hình, nhãn dán, ảnh vào đúng chỗ;
  - khung vẽ đúng vị trí; chỗ trống để chuột đi xuống dưới;
  - kéo dời, preview theo ngay, một lần Hoàn tác trả về chỗ cũ; kéo góc ×2; bám giữa;
  - **bản xuất có hình ở chỗ mới và to gấp đôi** (đo điểm ảnh);
  - dự án ảnh: thả hình và logo đúng chỗ, kéo hình (ảnh hiển thị đổi đúng điểm ảnh), kéo logo, khung nhường chỗ khi đang cắt;
  - khung hình không bị bóp khi có thông báo.
- Luồng N (cắt ảnh) được cập nhật theo cách bật khung cắt mới.

**Chưa kiểm chứng:**
- Chưa kéo bằng chuột thật trên màn hình (lý do như các bản trước). Các thao tác trên đi qua đúng mã xử lý chuột và thả của app, nhưng không qua phiên kéo của macOS.
- Chưa có núm xoay trên khung (xoay vẫn chỉnh ở bảng Chữ).


## Bản 0.12.0: kéo từ Thư viện, phím tắt, chọn nhiều/nhóm/khoá, và nguyên nhân thật của "UI đơ" (11/11/2026)

**Yêu cầu:**
1. Kéo thả Chữ, Hình, Nhãn dán… từ Thư viện vào khung hình chính.
2. Phím tắt xoá (⌫) và dời bằng phím mũi tên.
3. Chọn nhiều, nhóm, khoá như các app chuyên nghiệp.
4. Dứt điểm bug UI đơ khi chuyển bộ lọc/chuyển cảnh. Người bảo trì nói thêm: bấm xong thì video ở giữa rất lâu mới đổi, và kiểu "đang chọn" ở bảng phải cũng rất lâu mới đổi.

**4. Đơ UI: nguyên nhân thật, đã đo trên bản sao dự án "Bài tập cảm giác bóng":**
- **Nguyên nhân chính:**
  - Khi video đang dừng, mỗi lần đổi bộ lọc (cũng như màu, chuyển cảnh, lớp, chữ đang kéo) app "tua về đúng chỗ đang đứng" để vẽ lại khung hình.
  - AVPlayer bỏ qua lần tua không đổi chỗ, nên khung hình **không được vẽ lại**. Đo được: không có khung mới nào trong 5 giây; hình chỉ đổi khi có thao tác khác làm đầu phát dịch chuyển.
  - Nay app gán lại bộ vẽ cho video, buộc vẽ lại khung hiện tại ngay. Đo lại: bộ lọc và chuyển cảnh tới khung hình sau **1–2 ms**.
- **Phụ:**
  - Khi phát, mỗi khung hình (30 lần/giây) đều báo cho toàn bộ bảng bên vẽ lại. Nay chỉ 4 lần/giây: 80 → 13 lần trong 3 giây.
  - Timeline vẽ lại toàn bộ (ảnh nhỏ, sóng âm) ở mỗi khung chỉ để dời vạch đầu phát. Nay vạch đầu phát là một view riêng: ~90 → 12 lần vẽ trong 3 giây.
  - Phần luồng giao diện bận thêm khi phát (so với lúc đứng yên) còn khoảng 100 ms trên 3 giây (bản release).
- **Về "kiểu đang chọn ở bảng phải lâu mới đổi":** đo được luồng giao diện không bị chặn quá 82–150 ms mỗi lần chọn. Phần nghẽn khi đang phát đã giảm như trên. **Chưa đo được trên đúng máy và màn hình 5K của người bảo trì.**

**1. Kéo từ Thư viện:**
- Các ô trong Thư viện nay dùng cơ chế kéo của AppKit (như Finder) thay cho `onDrag` của SwiftUI. Bấm là thêm, nhấn rồi kéo là thả vào chỗ muốn.
- Khi kéo chữ, hình, nhãn dán hoặc ảnh qua khung hình, có vòng tròn đánh dấu và hai đường gióng tại chỗ sẽ thả.
- Đã kiểm tra AVPlayerView không giành chỗ thả.
- Nút + trên ô media nay luôn hiện, không chỉ khi rê chuột.

**2. Phím tắt** (khi đang chọn chữ, hình, nhãn dán, lớp hay logo trên khung hình):
- ⌫/⌦ xoá; ← → ↑ ↓ dời 1 điểm, ⇧ dời 10 điểm (nhấn liên tiếp tính một bước Hoàn tác); Esc bỏ chọn; ⌘D nhân đôi.
- Bấm vào khung hình thì phím đi tới khung hình chứ không vào ô gõ chữ bên phải.
- Không chọn gì trên khung hình thì mũi tên vẫn tua như cũ.

**3. Chọn nhiều, nhóm, khoá:**
- ⇧/⌘-bấm để chọn thêm hoặc bỏ bớt; kéo khung chọn trên vùng trống, khung bắt cả lớp/logo; bấm vùng trống để bỏ chọn.
- Kéo một mục là dời cả nhóm đang chọn (một bước Hoàn tác).
- ⌘G nhóm (bấm một mục là chọn cả nhóm), ⇧⌘G bỏ nhóm, ⌘L khoá/mở khoá. Mục khoá có biểu tượng 🔒, không dời và không xoá được trên khung hình.
- Nhân đôi nhiều mục thì bản sao thành một nhóm riêng.
- Các lệnh có ở menu Sửa, chuột phải và đầu bảng Thuộc tính ("Đã chọn N").
- Làn Chữ trên timeline xếp các mục trùng thời gian thành nhiều hàng và ghi đúng tên hình.

**Kiểm thử:**
- Core 391 (thêm `CanvasSelectionTests`) và Media 229, đều đạt trong 3 lần chạy đủ bộ gần nhất.
- Một lần trước đó, tiến trình test Media bị macOS dừng (SIGBUS) bên trong `CIContext.init` của hệ thống, khi test màu cũ chạy song song. Không lặp lại; đã ghi vào CLAUDE.md.
- Self-test toàn bộ: 405 đạt, 1 lỗi đã biết (phím tắt menu hệ thống trùng).
- Luồng mới **G5** (21 kiểm tra): ⇧-bấm, kéo cả hai, hoàn tác; khung chọn bắt cả lớp; phím mũi tên 1/10 điểm và hoàn tác một bước; nhóm; khoá chặn kéo/phím/xoá; ⌘D thành nhóm mới; ⌫, Esc; mũi tên vẫn tua khi không chọn gì; ô Thư viện bấm/rung nhẹ vẫn là bấm; dữ liệu kéo của ô thả đúng chỗ.
- G1 thêm các phép đo ở mục 4.

**Chưa kiểm chứng:**
- Kéo bằng chuột thật, bao gồm phiên kéo của macOS từ Thư viện sang khung hình. Mã nguồn kéo là AppKit chuẩn, nhưng self-test không khởi động được một phiên kéo thật.
- Hiệu ứng rê chuột trên ô media khi có lớp kéo AppKit phủ lên. Vì vậy nút + được để luôn hiện.


## Bản 0.13.0: một chỗ để thêm chữ, báo căn giữa, gõ chữ ngay trên khung hình (11/11/2026)

**Người bảo trì báo:** đã kéo được bằng chuột từ Thư viện sang khung hình. Cần thêm:
1. Phần thêm chữ/hình/nhãn dán đang bị lặp ở cả hai bảng; đã hỏi lại và chốt **chỉ để ở Thư viện bên trái**.
2. Báo cho người dùng biết khi đang căn giữa (giữa khung hình, hoặc giữa vật bao quanh).
3. Bấm đúp vào chữ để gõ ngay, không phải gõ ở ô bên phải.

**Đã làm:**
1. **Bảng phải (tab Chữ)** bỏ các thẻ "Thêm", "Kiểu chữ", "Hình và nhãn dán".
   - Còn lại: dòng hướng dẫn (khi chưa chọn gì), danh sách những gì trên khung hình, và phần chỉnh mục đang chọn.
   - Phần chỉnh có menu **Kiểu** gọn để đổi kiểu cho chữ đang chọn.
   - Kéo một kiểu chữ từ Thư viện thả **đè lên chữ có sẵn** thì chữ đó đổi kiểu (giữ nội dung); thả chỗ trống thì thêm chữ mới.
2. **Căn giữa:**
   - Khi kéo chữ, hình, nhãn dán, nhiều mục cùng lúc hoặc lớp/logo, tâm của nó bám vào giữa khung hình, hoặc vào giữa vật mà nó đang nằm trên (chữ trên hình, nhãn dán trên logo).
   - Gần cả hai thì ưu tiên vật nhỏ hơn.
   - Có đường gióng hồng và nhãn "Đã căn giữa: Giữa khung hình", "Đã căn giữa: Giữa Rectangle"…
   - Vị trí được đặt đúng chính giữa (làm tròn tới một phần triệu). Giữ ⌥ để không bám.
3. **Bấm đúp vào chữ** trên khung hình mở ô gõ ngay tại chỗ, đúng font, cỡ, màu, chữ cũ được chọn sẵn.
   - Gõ tới đâu hình đổi tới đó; cả lần gõ là một bước Hoàn tác.
   - Return là xong, ⌥Return xuống dòng, Esc trả lại chữ cũ.
   - Hình (không phải chữ) không mở ô gõ.

**Kiểm thử:**
- Self-test mới **G6** (12 kiểm tra), tất cả đạt:
  - căn giữa khung hình kèm nhãn; căn giữa hình bên dưới kèm nhãn; lớp căn giữa kèm nhãn;
  - bấm đúp mở ô gõ; gõ hiện ngay; ⌥Return/Return; một lần Hoàn tác; Esc; hình không mở ô;
  - thả kiểu chữ đè lên chữ thì đổi kiểu, thả chỗ trống thì thêm chữ.
- G4 + G5 + G6: 50 kiểm tra đạt. Self-test toàn bộ: 416 đạt, 1 lỗi đã biết (phím tắt menu hệ thống trùng). Core 391 và Media 229 đạt.
- Trong ngày, 2/8 lần chạy cả bộ test Media bị macOS dừng (SIGBUS) bên trong framework hệ thống (Metal khi tạo `CIContext`; ImageIO khi đọc GIF) ở các test cũ chạy song song. Chạy lại thì đạt; sáng cùng ngày, trước các thay đổi này, cũng có một lần tương tự. Chưa tìm được cách tái hiện chắc chắn.
- Chụp cửa sổ: bảng phải tab Chữ chỉ còn hướng dẫn và danh sách.

**Chưa kiểm chứng:** bấm đúp và gõ bằng chuột và bàn phím thật; nhãn căn giữa trên màn hình 5K của người bảo trì.


## Bản 0.14.0: Thư viện hết nhấp nháy, mẫu chữ/hình/nhãn dán mới, cửa sổ Xuất cho mạng xã hội (11/11/2026)

**1. Ô Thư viện nhấp nháy khi phát video. Đã sửa.**
- **Nguyên nhân:** file đang dùng trong dự án nhưng chưa nằm trong kho Thư viện (dự án cũ) được gán mã nhận diện **mới** mỗi lần giao diện vẽ lại. Khi phát (4 lần/giây), các ô bị tạo lại, ảnh nhỏ mất rồi tải lại, gây nhấp nháy.
- **Sửa:** mã cố định theo đường dẫn file; ô lấy ảnh nhỏ từ bộ nhớ đệm ngay khi được tạo.
- **Đo trong self-test G2:** trước khi sửa, 33 lần tạo lại ô trong 2,5 giây phát; sau khi sửa, 0. Mình đã tạm bỏ phần sửa để xác nhận phép thử bắt được lỗi.

**2. Mẫu chữ, hình, nhãn dán; hình vuông thành chữ nhật.**
- **Lỗi:** kích thước hình tính theo phần trăm chiều rộng và chiều cao khung, nên "vuông 18% × 18%" trên khung 16:9 thành chữ nhật ngang. Nay chiều cao tính theo tỉ lệ khung. Self-test G4 đo trên khung hình: 125 × 125 điểm.
- **Mới:**
  - 9 kiểu chữ: Tiêu đề lớn, Phụ đề nền, Trích dẫn, Cổ điển, Sang trọng, Viết tay, Hashtag, Khuyến mãi, Tối giản.
  - 10 **mẫu có sẵn**, chữ theo ngôn ngữ của người dùng: Nút đăng ký, Trực tiếp, Mới, Giảm 50%, Thích & chia sẻ, Theo dõi @…, Sắp ra mắt, Cảm ơn đã xem, Địa điểm, Tin nóng.
  - 8 hình: thoi, ngũ giác, lục giác, bong bóng thoại, nhãn nổ, dấu tích, dấu cộng, vòng tròn rỗng.
  - Nhãn dán: từ 24 lên hơn 60 (mũi tên, dấu, đánh dấu, bóng đá…).
- Tất cả bấm hoặc kéo được như trước. Mẫu có sẵn bấm đúp để sửa chữ.

**3. Xuất.**
- Nút Xuất chỉ còn ở góc trên bên phải; bấm mở **cửa sổ Xuất**. Tab Xuất trong bảng phải đã bỏ (cả với dự án ảnh).
- Gộp "Chất lượng" và "Cỡ" thành **một** lựa chọn có giải thích: Tốt nhất (như bản gốc) · 4K · Full HD 1080p (khuyên dùng) · HD 720p · Nhẹ 480p.
- **Khung hình** cho mạng xã hội: Gốc, 16:9 YouTube, 9:16 TikTok/Reels/Shorts, 1:1 Instagram/Facebook, 4:5 Instagram dọc (mới), 4:3.
  - Cách lấp: đủ hình viền đen, lấp đầy cắt mép, hoặc đủ hình viền mờ.
  - Áp cho cả dự án; khung xem phía sau đổi ngay; có báo trước cỡ video sẽ xuất.
- Định dạng, codec, âm thanh vào mục "Nâng cao" (thu gọn). Nút Huỷ / Xuất video ghim ở đáy.
- **Sửa thêm:** cỡ xuất ra giới hạn theo **cạnh ngắn**. Video dọc 1080p nay là 1080 × 1920 thay vì 608 × 1080 (preview vẫn giới hạn chiều cao cho nhẹ).

**Sửa lại thông tin sai ở báo cáo 0.12/0.13:** các lần tiến trình test Media bị dừng (SIGBUS) **không phải do hệ thống**.
- Nguyên nhân là chính các test mình viết từ 0.11: chúng đưa con trỏ mảng `&array` cho `CGContext` rồi vẽ sau đó, nên ghi vào vùng nhớ không còn thuộc về chúng.
- Đã sửa cả 5 chỗ (3 test, 2 hàm đọc điểm ảnh của self-test). Sau đó chạy cả bộ 3 lần liền, cả 3 sạch. Đã ghi quy tắc vào CLAUDE.md.

**Kiểm thử:**
- Core: thêm `ExportPresetTests` (chất lượng+cỡ, khung cho mọi đoạn, 4:5, hình vuông đúng tỉ lệ, video dọc theo cạnh ngắn) và một test mã nhận diện ổn định.
- Media: hình vuông vẽ ra đúng 80 × 80 điểm ảnh trên khung 320 × 180; mọi hình mới đều vẽ được; vòng tròn rỗng ruột.
- Self-test:
  - G2: bấm Xuất mở cửa sổ, Huỷ đóng, không còn tab Xuất thứ hai; xuất khung 9:16 ra video dọc; Thư viện không bị tạo lại khi phát.
  - G4: hình vuông vuông trên khung hình.
- Chụp cửa sổ Xuất bằng `screencapture -l` (chỉ cửa sổ MacPlayer).

**Chưa kiểm chứng:**
- Xuất thật một video 9:16/1:1 từ video của người bảo trì rồi đăng lên mạng xã hội.
- Font của một số kiểu chữ mới (Didot, Bradley Hand, Impact, Helvetica Neue Condensed) lấy từ macOS: nếu máy thiếu font, macOS tự dùng font thay thế.
- Self-test toàn bộ: 420 đạt; 1 lỗi đã biết (phím tắt menu hệ thống trùng) và 1 lỗi của chính phép thử G1: lần chọn bộ lọc đầu tiên trên video chưa có hiệu ứng bị tính là chậm, trong khi nó dựng lại preview theo thiết kế. Đã sửa phép thử để chỉ đo khi bộ vẽ đã bật; chạy lại G1 trên video thử và trên bản sao dự án của người bảo trì: các lần chọn bộ lọc lên hình sau 0–1 ms, chuyển cảnh 1–2 ms.
- Test Core 396 và Media 231 đạt trong 3 lần chạy liền.


## Bản 0.14.1: tab Chữ chia thành tab con (11/11/2026)

**Yêu cầu:** phần Chữ, Hình, Nhãn dán phải cuộn rất dài; chuyển sang dạng tab.

**Đã làm:**
- Tab Chữ của Thư viện có 4 tab con: **Kiểu chữ · Mẫu sẵn · Hình · Nhãn dán**. Nút "Thêm chữ" vẫn ở trên cùng.
- Mỗi tab có dòng hướng dẫn riêng. Hình hiện to hơn, kèm tên và màu thật; nhãn dán to hơn. Tab đang mở được nhớ trong lúc app chạy.
- **Lỗi tìm ra khi chụp màn hình:** thanh tab kiểu "segmented" của macOS đòi bề rộng tối thiểu lớn hơn bảng, đẩy cả cột ra ngoài và bị cắt hai mép. Đã thay bằng thanh tab tự vẽ co giãn theo bảng.

**Kiểm thử:**
- Chụp cửa sổ từng tab con (4 ảnh): không bị cắt, đủ nội dung.
- Self-test G2 (80) và G4/G5/G6 (51) đạt. Không đổi gì ở phần lõi.

**Chưa kiểm chứng:** bấm các tab bằng chuột thật.


## Bản 0.14.2: kéo đối tượng trên khung hình mượt, khung chọn theo kịp (11/11/2026)

**Người bảo trì báo:** kéo, rê đối tượng trong vùng chỉnh sửa khá đơ; viền chọn không theo kịp đối tượng.

**Nguyên nhân (đọc mã, rồi đo):** mỗi sự kiện chuột khi kéo (60–120 lần/giây) đều:
- ghi một bước sửa vào dự án, khiến mọi bảng SwiftUI (Thư viện, Thuộc tính, thanh công cụ) và cả timeline vẽ lại;
- yêu cầu trình phát vẽ lại khung hình; các yêu cầu dồn hàng nên hình chạy sau viền;
- tính lại bố cục chữ (CoreText) của mọi mục trên khung hình ở mỗi lần vẽ khung và mỗi lần dò chuột.

Với dự án ảnh, mỗi sự kiện còn vẽ lại cả tấm ảnh.

**Sửa:**
- Trong lúc kéo, khung chọn và hình chạy theo một "bản nháp", **không ghi vào dự án**. Khi thả chuột mới ghi một lần (một bước Hoàn tác).
- Trình phát vẽ lại khung hình tối đa một lần mỗi khung màn hình (1/60 giây). Dự án ảnh vẽ lại tối đa 30 lần/giây, không chồng việc.
- Khung của chữ được nhớ sẵn, không tính lại bố cục mỗi lần.
- Áp dụng cho kéo chữ/hình/nhãn dán, kéo góc đổi cỡ, kéo nhiều mục và kéo lớp/logo.

**Kiểm thử:**
- Self-test mới **G7**: 90 lần dời, mỗi lần một khung màn hình, trên video thử và trên bản sao dự án "Bài tập cảm giác bóng" (có 4 chữ, 3 hình và 1 logo trên khung). Kết quả:
  - các bảng vẽ lại **0 lần**, timeline 1 lần;
  - trình phát vẽ lại 86–88 khung;
  - mỗi lần dời tốn 0,1 ms trên luồng giao diện;
  - khung chọn **trùng vị trí chuột ở mọi lần** (lệch 0 điểm);
  - thả xong đúng chỗ, và cả lần kéo là một bước Hoàn tác.
- G2/G4/G5/G6 đạt (80 + 51). Core 396, Media 231 đạt. Self-test toàn bộ: 427 đạt, 1 lỗi đã biết (phím tắt menu hệ thống trùng).

**Chưa kiểm chứng:**
- Kéo bằng chuột hoặc trackpad thật trên màn hình 5K.
- Chưa có số đo "trước khi sửa" bằng chính G7: nó được viết cùng lúc với phần sửa. Nhận định "mỗi lần dời một lần ghi dự án" ở trên lấy từ đọc mã.


## Bản 0.16.2: tên bài trong dự án nhạc chỉnh sửa được (12/11/2026)

**Người bảo trì báo:** mở mp3, bấm "Sửa" tạo dự án video thì không chỉnh được chữ ở khung giữa; chữ là tên lấy từ file.

**Nguyên nhân:** 0.16.0/0.16.1 vẽ tên bài, nghệ sĩ, album thẳng vào ảnh của video bìa, nên chúng là một phần của hình chứ không phải chữ của dự án.

**Sửa:**
- Video bìa chỉ còn ảnh bìa (hoặc thẻ màu), đặt giữa khung, hơi cao.
- Tên bài và "nghệ sĩ · album" được thêm thành **chữ thường của dự án** dưới ảnh bìa, kéo dài suốt bài. Có thể bấm đúp để gõ lại ngay trên khung hình, kéo, đổi kiểu, xoá; hiện trên dải Chữ của timeline.
- File không có thẻ thì chữ là tên file.
- Video bìa mới có tên mới trong thư mục tạm, nên không dùng lại bản cũ có chữ. Dự án đã tạo bằng 0.16.0/0.16.1 vẫn giữ video bìa cũ (có chữ vẽ sẵn) chừng nào file tạm đó còn.

**Kiểm thử:**
- Core thêm `aSongsTitleAndArtistAreTextsThatCanBeChanged`; Media thêm `aProjectsCoverHasNoWordsAndItsTileInTheMiddle` (ảnh bìa ở giữa, vùng dưới không có chữ). Core 417, Media 243 đạt.
- G9: dự án từ `song.mp3` có đúng 2 chữ (tên bài, "Nghệ sĩ Thử · Album 0.16"), dài bằng bài; **gõ đè tên bài ngay trên khung hình** qua ô nhập thật rồi Hoàn tác: đạt. Bài thật không có thẻ: chữ là tên file. G9: 64 đạt. Self-test đầy đủ: 509 đạt, 1 lỗi đã biết.
- Chụp cửa sổ thật (tiếng Việt) dự án từ bài nhạc thật tên dài: ảnh bìa giữa khung, tên bài 2 dòng bên dưới, dải Chữ trên timeline.

**Chưa kiểm chứng:** gõ bằng bàn phím thật; chuyển dự án 0.16.0/0.16.1 cũ sang kiểu mới (không làm tự động, để khỏi đổi dự án của bạn mà không hỏi).

## Bản 0.16.1: kiểm chứng tiếp trên nhạc thật, sửa lỗi, tự phát khi mở từ Finder (12/11/2026)

**Yêu cầu:** làm tiếp các mục "chưa kiểm chứng" của 0.16.0; nút "Sửa" bị cắt khi tên file dài và cần biểu tượng hợp hơn; file mở từ Finder phải tự phát.

**Nhạc thật:** chép (không đụng bản gốc) 3 bài từ `/Volumes/Lexar 256GB/Nhạc` (3:42, 3:35 và bản nonstop 79 phút, 107 MB) và `_mau.m4a` từ thư mục Nhạc; so từng byte trước/sau: không đổi.
- Phát lẻ, phát gần cuối bài, tạo dự án, phát dự án gần cuối: đạt cả 4 file. Các file này không có ảnh bìa và thẻ tên, nên app dùng tên file (dài, có dấu) trên thẻ màu.
- **Vấn đề tìm thấy:** bài 79 phút tạo dự án mất 21 giây và tạo file tạm 596 MB, vì MP3 bị giải mã thành Apple Lossless và ảnh bìa ghi mỗi giây một hình.
- **Sửa:** MP3 được chép nguyên vẹn như AAC; ảnh bìa ghi 5 giây một hình. Kết quả còn 4,3 giây và 113 MB. Âm thanh giải mã từ video phụ được so với bản gốc ở 5 vị trí: lệch 0 mẫu, sai khác 0.
- **Lỗi sập tìm thấy khi chụp cửa sổ thật:** dự án nhạc mở trong cửa sổ bị sập ngay (đồng hồ thời gian chia cho 0, vì video bìa chỉ 0,2 hình/giây). Self-test trước đó không mở dự án trong cửa sổ nên không thấy. Đã sửa ở gốc (tốc độ khung dưới 1 hình/giây không còn làm tròn về 0), G9 giờ mở dự án trong cửa sổ, và đã xác nhận bước test mới **sập** khi tạm bỏ phần sửa.

**Ogg/Opus/WMA:** thử thật trên macOS 27: Ogg Opus và Ogg Vorbis **phát được** (trước đó tôi ghi nhầm là không), nên đã thêm vào danh sách; WMA và WebM không đọc được, app báo rõ.

**Ảnh động làm lớp phủ:** trước đây đứng yên. Nay app làm video có nền trong suốt (HEVC kèm kênh alpha). Test pixel: khung 1 đỏ, khung 2 xanh đúng thời điểm; quanh hình vẫn thấy video bên dưới.

**Link nhạc** qua máy chủ thử: MP3, Opus, và FLAC không đuôi (máy chủ báo "dữ liệu nhị phân", app nhận ra từ vài byte đầu) đều phát kèm thẻ bìa.

**Nút "Sửa":** trước đây bị cắt còn "E" khi tên file dài; nay giữ đủ chiều rộng. Biểu tượng: kéo (video, nhạc), đũa phép (ảnh), nền màu nhấn. Lần đầu tôi dùng biểu tượng `pencil.and.scissors` không có trên macOS này nên nút không có hình; đã thay và thêm kiểm tra biểu tượng có tồn tại.

**Tự phát khi mở lẻ:** video và nhạc mở từ Finder, Tệp ▸ Mở…, Mở gần đây tự phát ngay (ảnh động và link vốn đã tự chạy). "Mở" bản đã tải từ link vẫn giữ trạng thái như lúc xem link.

**Khác:** đổi tên video đang xem: cửa sổ mở lại đúng thời điểm trước khi hiện (trước đó hiện ở 0:00 một chút rồi mới tua; self-test bắt được một lần).

**Kiểm thử:** Core 416, Media 242 đạt. G9 (nhạc, ảnh động, nhạc thật): 60 đạt. G8 với máy chủ thử (gồm link nhạc): 77 đạt. Self-test đầy đủ: 505 đạt, 1 lỗi đã biết (phím tắt hệ thống trùng). Chụp cửa sổ thật (`screencapture -l`, bản sandbox, tiếng Việt): nút Sửa đủ chữ với tên file dài, video tự phát (00:00:03:09 sau 4 giây), dự án nhạc 79 phút phát và hiện ảnh bìa.

**Chưa kiểm chứng:** nghe bằng tai; nhạc thật có ảnh bìa nhúng (nhạc của bạn không có); mở bằng Finder thật (`open_with_test.py`) chưa chạy vì MacPlayer thật của bạn đang mở; nhấp chuột thật.

## Bản 0.16.0: phát nhạc, ảnh động; dự án từ nhạc và ảnh động (12/11/2026)

**Yêu cầu:** phát được file nhạc (mp3, m4a…) và tạo dự án chỉnh sửa từ chúng; phát được ảnh động (.gif, .apng, .webp…) và tạo dự án chỉnh sửa.

**Hiện trạng trước khi làm:**
- File nhạc không nằm trong danh sách đuôi file của app: không mở, không vào danh sách phát được. Phần dựng hình bắt buộc mọi clip phải có hình nên không tạo được dự án từ nhạc.
- Ảnh động đã phát được và có dự án ảnh (lưu GIF), nhưng: lưu PNG chỉ ra khung đầu; đặt GIF lên timeline video thì đứng hình ở khung đầu.

**Đã làm:**
- *Phát âm thanh:* loại media mới "âm thanh" (mp3, m4a, m4b, aac, wav, aiff, caf, flac, ac3…). Mở lẻ có cửa sổ riêng (800 × 450) hiện ảnh bìa, tên bài, nghệ sĩ, album đọc từ thẻ; file không bìa thì có thẻ màu cố định theo tên bài. Vào danh sách phát cùng video và ảnh, ô danh sách hiện ảnh bìa. Link âm thanh (kể cả link không đuôi: nhận biết FLAC/WAV/AIFF/CAF/M4A từ vài byte đầu) cũng hiện như vậy.
- *Dự án từ âm thanh:* app làm một video phụ trong thư mục tạm riêng: ảnh bìa 1920 × 1080, mỗi giây một hình, kèm **nguyên âm thanh** (AAC/Apple Lossless chép thẳng; MP3, FLAC, WAV… giải mã rồi ghi Apple Lossless, không mất dữ liệu; đã kiểm bằng so mẫu âm thanh). Clip trên timeline là cả bài, dùng được mọi công cụ clip. Tách clip không bị làm tròn về giây (đã sửa: trước đó lệnh tách dò khung hình của video phụ, mỗi giây chỉ một khung). Video phụ mất thì tự làm lại khi mở dự án. Cửa sổ Xuất có thêm **Chỉ âm thanh (.m4a)**: lưu âm thanh cả timeline kèm fade, hiệu ứng, nhạc nền, theo đúng quy tắc lưu an toàn.
- *Ảnh động:* đặt lên timeline dự án video thì chạy thật (video phụ giữ đúng thời gian từng khung, lặp đủ 60 giây; clip mặc định dài một vòng, vòng ngắn thì lặp tới khoảng 3 giây). Nút Chỉnh sửa hỏi **Dự án ảnh** hay **Dự án video**. Dự án ảnh lưu PNG thì ra **PNG động** (mặc định cho nguồn APNG). WebP động lưu ra GIF hoặc PNG động vì macOS không ghi được WebP.

**Kiểm thử:**
- Test Media mới: video bìa từ WAV (lossless, 2 kênh riêng, dài đúng, file gốc không đổi), từ AAC (chép thẳng), file không có tiếng bị từ chối, ảnh bìa (có ảnh và không có ảnh), xuất timeline có clip âm thanh (30 fps, không bị 1 fps), xuất riêng âm thanh cả timeline (có fade, không ghi đè), GIF/APNG thành video chuyển động đúng thời gian, APNG lưu ra APNG.
- Test Core mới `SoundMediaTests`. Toàn bộ: Core 414, Media 241 đạt.
- Self-test G9 trong app thật (sandbox) với MP3 có thẻ và bìa, M4A, FLAC 96 kHz, MP3 3 phút, GIF, APNG, WebP do ffmpeg/gif2webp tạo: 34 mục đạt (gồm cả G8 phần cửa sổ riêng: 25 đạt). Self-test đầy đủ: 495 đạt, 1 lỗi đã biết (phím tắt hệ thống trùng). File âm thanh và ảnh dùng trong test được so từng byte trước/sau: không đổi.

**Chưa kiểm chứng:**
- Nhạc thật của người dùng (thẻ lạ, bìa lớn, file rất dài như podcast 2–3 giờ: video phụ khi đó chiếm chỗ bằng bản Apple Lossless).
- OGG, Opus, WMA: macOS không phát được nên app báo không mở được.
- Ảnh động đặt làm *lớp phủ* (không phải dải chính) vẫn là ảnh tĩnh.
- Nghe bằng tai và nhìn trên màn hình thật: chỉ kiểm qua ảnh chụp cửa sổ và số liệu.

## Bản 0.15.2: sửa ⌘V/⌘C/⌘X/⌘A không hoạt động (12/11/2026)

**Người bảo trì báo:** copy link `.mp4`, bấm vào ô nhập rồi ấn ⌘V nhưng không dán được (bản 0.15.1).

**Nguyên nhân thật:**
- Hàm dựng menu biến `target: nil` (nghĩa là "gửi cho ô hoặc cửa sổ đang có bàn phím") thành "gửi cho AppDelegate".
- AppDelegate không có lệnh dán, nên các mục Cắt, Sao chép, Dán, Chọn tất cả, Đóng cửa sổ, Thu nhỏ **không làm gì ở bất kỳ đâu trong app**.
- Lỗi có từ rất lâu trước 0.15.

**Sai sót trong kiểm thử của tôi:**
- Bài test của 0.15.1 gọi thẳng lệnh dán của ô nhập, bỏ qua menu ⌘V, nên báo "đạt" dù người dùng không dán được.
- Mục test cũ "mỗi mục menu đều có thứ để tác động" chỉ xem mục có đích hay không, không xem đích đó có làm được lệnh không.

**Sửa:**
- 6 mục trên giờ gửi cho đúng ô hoặc cửa sổ đang có bàn phím. ⌘W đóng cửa sổ và ⌘M thu nhỏ giờ cũng hoạt động.
- Mục test menu giờ kiểm tra đích thật sự làm được lệnh.
- G8 gửi ⌘V và ⌘A qua menu chính như phím bấm thật. Khi app chạy nền không có cửa sổ nhận bàn phím, test gửi qua chuỗi phản hồi của chính cửa sổ đó và ghi rõ điều này.

**Kiểm thử:**
- Đã xác nhận bài test mới **hỏng** khi tạm đưa mục Dán về lỗi cũ (4 mục báo lỗi), và **đạt** khi đã sửa.
- G8 chạy riêng: 26 mục đạt. Self-test đầy đủ: 461 đạt, 1 lỗi đã biết (phím tắt hệ thống trùng).
- Bộ nhớ tạm của người dùng được trả lại nguyên vẹn sau test.

**Chưa kiểm chứng:** bấm ⌘V bằng bàn phím thật. Test gửi phím qua menu chính trong app, không đi qua phần cứng hay hệ thống.

## Bản 0.15.1: dán link thẳng vào ô nhập (12/11/2026)

**Người bảo trì yêu cầu:** cho phép dán link thẳng vào ô nhập thay vì dùng nút "Dán".

**Đã làm:**
- Bỏ nút "Dán". Ô nhập giờ rộng hết hàng.
- Ô nhập nhận bàn phím ngay khi hộp thoại mở. ⌘V hoặc chuột phải ▸ Dán sẽ dán thẳng vào ô; nếu ô đã có link thì link đó được chọn sẵn, dán là thay.
- Chữ gợi ý: "Dán hoặc gõ link vào đây (⌘V), ví dụ https://example.com/video.mp4".
- Khi dán, dấu cách và xuống dòng thừa được bỏ, chỉ giữ dòng đầu.

**Kiểm thử:**
- G8 thêm 5 mục: ô có bàn phím khi mở, ⌘V dán vào ô (qua đúng bộ soạn chữ của ô), làm sạch chuỗi dán, dán đè link đang chọn, ô trống khi bộ nhớ tạm không phải link.
- Bộ nhớ tạm của người dùng được lưu lại trước test và trả lại sau test (đã kiểm tra).
- G8 với máy chủ thử: 68 mục đạt.

**Chưa kiểm chứng:** gõ ⌘V bằng bàn phím thật. Test gọi lệnh dán của ô trực tiếp, không bơm phím.

## Bản 0.15.0: cửa sổ phát riêng, mở video/ảnh từ link (12/11/2026)

**Người bảo trì yêu cầu:**
1. File lẻ mở nhanh qua Finder phải ra một màn hình phát riêng, không có giao diện danh sách phát.
2. Phát video/ảnh qua link trực tiếp (`.mp4`, `.mov`, `.m3u8`, `.jpg`, `.png`…). Giao diện đẹp, khoa học; test và sửa lỗi kỹ trước khi bàn giao.

**Đã làm: cửa sổ phát riêng**
- Một video hoặc ảnh mở lẻ (bấm đúp, Mở bằng, Tệp ▸ Mở…, Mở gần đây, dòng lệnh) phát trong cửa sổ chỉ có hình và nút điều khiển. Không có thanh danh sách phát; nút trước/sau và trình chiếu ở thanh ảnh cũng ẩn.
- Thanh trên cùng hiển thị:
  - tên file và thông số (độ phân giải, fps, thời lượng, dung lượng);
  - nút **Chỉnh sửa**;
  - menu **⋯** gồm Hiện trong Finder, Sao chép đường dẫn, Đổi tên, Chuyển vào Thùng rác.
- Cỡ cửa sổ:
  - cửa sổ tự canh theo tỉ lệ video;
  - video nhỏ mở đúng cỡ gốc như QuickTime, video rất nhỏ được phóng lên 640 điểm, video lớn vừa 80% màn hình;
  - cửa sổ được canh cỡ trước rồi mới hiện, nên không bị nhảy cỡ.
- Đóng file thì đóng luôn cửa sổ. Cửa sổ danh sách phát và dự án khác không bị đụng. Mở file thứ hai sẽ ra cửa sổ thứ hai.
- Mở từ Finder khi app đang tắt: không hiện màn hình Trang chủ trước.
- Cửa sổ hẹp: thanh điều khiển tự gọn lại, tổng thời lượng không bị cắt.
- Nhiều file hoặc một thư mục vẫn thành danh sách phát như trước.

**Đã làm: mở từ link**
- Mở ở Tệp ▸ **Mở link…** (⌘U), hoặc từ nút ở Trang chủ và màn hình Danh sách phát.
- Link được kiểm tra ngay khi gõ, chưa cần mạng:
  - nhận ra link trang xem YouTube, Facebook, TikTok, Instagram, X, Vimeo, Google Drive, OneDrive (báo rõ đó là trang, không phải file);
  - báo MKV/WebM/AVI không phát được;
  - link chưa có `https://` được tự thêm;
  - link chia sẻ Dropbox được tự đổi sang dạng tải thẳng;
  - link `http://` được ghi chú là không mã hoá.
- Khi bấm Mở, app hỏi máy chủ (HEAD). Máy chủ chặn HEAD thì xin byte đầu. Máy chủ chỉ trả "application/octet-stream" thì đọc 512 byte đầu để nhận dạng file.
- Lỗi 401/403/404/429/5xx, không có mạng, không tìm thấy máy chủ, chứng chỉ hỏng, trang web giả đuôi `.mp4`: hiện thành câu tiếng Việt ngay trong hộp thoại, hộp thoại vẫn mở để sửa link.
- Video và luồng HLS phát ngay khi có dữ liệu:
  - vòng xoay "Đang kết nối…/Đang chờ dữ liệu…";
  - luồng trực tiếp có nhãn **TRỰC TIẾP**, không có timeline, không tua;
  - lỗi phát hiện thành thẻ có **Thử lại** và **Sao chép link**.
- **Tải về…**:
  - lưu file về máy (mặc định thư mục Tải về), có phần trăm tiến trình, huỷ được;
  - ghi vào tên tạm rồi mới đổi tên, nên dừng giữa chừng không để lại nửa file;
  - file trùng tên được chuyển vào Thùng rác, không xoá;
  - xong thì **Mở** để xem bản trên máy, khi đó chỉnh sửa được;
  - luồng HLS không tải về được (ghi rõ trong app).
- Ảnh từ link được tải vào bộ nhớ đệm riêng của app. Đóng cửa sổ hoặc mở lại app là xoá.
- Link không bị coi là file của bạn: không đổi tên, không vào Thùng rác, không nhớ vị trí đang xem, không báo "file không còn ở vị trí cũ".
- **Link gần đây** chỉ lưu trên máy, xoá được từng link hoặc cả danh sách.
- Mạng: app chỉ kết nối khi bạn mở link; không gửi gì khác (phiên mạng "ephemeral", không cookie, không cache). Info.plist cho phép `http://` để mở được camera hoặc máy chủ trong mạng nội bộ.

**Lỗi tìm ra khi test và đã sửa:**
- Cửa sổ ra sai tỉ lệ (3,05 thay vì 1,78): chiều cao các thanh được đo khi khung hình chưa dàn trang, và video bị chia cho hệ số Retina.
- Với link, cửa sổ hiện ở cỡ to rồi mới co lại. Giờ cửa sổ chờ tối đa 1,2 giây để biết cỡ video.
- Luồng trực tiếp hiện nhầm cảnh báo "index.m3u8 không còn ở vị trí cũ", và hiện "225 bytes" (cỡ file danh sách chứ không phải video).
- Danh sách link gần đây bị ép còn 1 dòng. Hộp thoại Mở link bị cắt đầu và cuối khi nội dung dài ra.
- Link mà máy chủ chỉ báo "octet-stream" không phát được. Giờ app đọc byte đầu để nhận dạng.
- **Máy chủ ngừng gửi dữ liệu: hộp thoại kẹt mãi ở "Đang mở…"**, vì trình phát chờ danh sách track mà dữ liệu không tới. Giờ không chờ mạng ở bước mở.
- **Máy chủ ngừng gửi dữ liệu giữa chừng: vòng xoay quay mãi.** Giờ sau 20 giây không có tiến triển thì dừng và báo, kèm Thử lại.
- Thẻ báo lỗi kéo dài cửa sổ thành 640×1369.
- Cửa sổ phát riêng nhỏ, bấm về Trang chủ: cửa sổ nhỏ hơn mức tối thiểu của Trang chủ.
- **Lỗi có sẵn từ trước, tìm ra nhờ chạy test nhiều lần:**
  - chống rung khi xuất đôi khi áp phần bù vào khung kế bên (tra khung bằng làm tròn thay vì khung đang hiện), nên video xuất còn giật hơn video gốc;
  - trên commit cũ test hỏng 2/9 lần; sau khi sửa, đạt 9/9.

**Kiểm thử:**
- Máy chủ thử cục bộ `Scripts/link_test_server.py` hỗ trợ Range và HEAD, có các route lỗi (404, 403, chặn HEAD, trang web, octet-stream, chậm, ngắt kết nối, treo hẳn). Kèm luồng HLS thường và HLS trực tiếp do ffmpeg tạo.
- Self-test **G8**: 67 mục đạt, chạy cả giao diện tiếng Anh và tiếng Việt (bản `.app`).
- Test Core 408 (thêm `MediaLinkTests`: 12 test về link, nhận dạng byte đầu, cỡ cửa sổ) và Media 231 đều đạt.
- Self-test đầy đủ: 503 đạt, 1 lỗi đã biết (phím tắt hệ thống trùng).
- `Scripts/open_with_test.py` (mở bằng `open -a`, đúng đường Finder dùng): 15/15 đạt. Đã sửa script để chờ route `solo`.
- Ảnh chụp cửa sổ thật (có hình video) bằng `screencapture -l`, chạy trong sandbox.

**Chưa kiểm chứng:**
- Link trên máy chủ và CDN thật ngoài Internet: chỉ test với máy chủ cục bộ, kể cả HTTPS thật.
- Mạng chậm thật hoặc Wi-Fi rớt.
- Video rất lớn qua link.
- Rê, bấm bằng chuột thật trên các cửa sổ mới.
- Kéo link từ trình duyệt thả vào cửa sổ: chưa làm, hiện chỉ dán được.

## Bản 0.14.4: bỏ viền nét đứt quanh nhãn dán (12/11/2026)

**Người bảo trì báo:** nhãn dán kéo thả vào khung hình bị thêm viền nét đứt, dù ở bảng thuộc tính viền đang tắt.

**Nguyên nhân:**
- Nhãn dán không có viền thật: nó được tạo với độ dày viền bằng 0 và ảnh xuất ra không có viền.
- Viền nét đứt là khung gợi ý của vùng chỉnh sửa. Khung này được vẽ quanh *mọi* chữ, hình, nhãn dán, logo chưa được chọn, lúc nào cũng hiện, nên trông như viền của chính nhãn dán.

**Sửa:**
- Khung nét đứt giờ chỉ hiện quanh đối tượng nằm trên cùng dưới con trỏ chuột, và biến mất khi chuột rời đi hoặc đang kéo.
- Đối tượng đang chọn vẫn giữ khung liền và các núm góc như cũ.
- Áp dụng cho cả chữ/hình/nhãn dán lẫn logo/ảnh lớp.

**Kiểm thử:**
- G4 thêm 4 mục: không đối tượng nào có khung nét đứt khi chuột không ở trên; nhãn dán dưới chuột có khung; khung biến mất khi chuột rời đi; logo dưới chuột có khung.
- G4/G5/G6: 55 đạt, 0 lỗi. G2/G3: 84 đạt, 0 lỗi.

**Chưa kiểm chứng:** rê chuột thật trên màn hình. Bài thử đặt vị trí chuột trực tiếp vào view, không qua sự kiện chuột của hệ thống.

## Bản 0.14.3: kéo đối tượng đi liền theo chuột (11/11/2026)

**Người bảo trì báo:** sau bản 0.14.2, kéo đối tượng trên khung hình vẫn rất giật.

**Nguyên nhân thật (bản 0.14.2 chưa xử lý):**
- Bản 0.14.2 đã bỏ việc ghi dự án ở mỗi lần nhích chuột, nhưng vẫn bắt trình phát (AVPlayer) dựng lại khung hình đến 60 lần/giây.
- Đường này có độ trễ và nhịp không đều, nên chữ, hình chạy sau viền chọn.
- Bài đo G7 của bản 0.14.2 chỉ đếm số lần *yêu cầu* vẽ, không đo hình *thực sự* nằm đâu trên màn hình. Vì vậy nó báo "mượt" trong khi người dùng thấy giật. Đây là sai sót trong cách đo của tôi.

**Sửa:**
- Ở lần nhích chuột đầu tiên, app "nhấc" đối tượng ra. App vẽ đối tượng một lần thành ảnh, bằng chính mã vẽ của trình phát nên trông y hệt. Ảnh đặt nổi trên khung hình, và trình phát bỏ đối tượng đó ra khỏi khung.
- Mỗi lần nhích chuột chỉ dời hoặc phóng ảnh nổi; màn hình tự làm việc này ở tốc độ của nó.
- Khi thả: ghi vào dự án một lần, trình phát vẽ lại một lần. Ảnh nổi chỉ được gỡ sau khi trình phát đã vẽ đối tượng ở chỗ mới, nên không nháy.
- Áp dụng cho: chữ, hình, nhãn dán, kéo góc đổi cỡ, kéo nhiều đối tượng, logo hoặc ảnh lớp, ở dự án video và dự án ảnh.
- Vẫn theo cách cũ: lớp video, lớp có chế độ hoà trộn hoặc tách nền, và khi video đang phát.

**Lỗi sập phát hiện thêm khi thử trên dự án "Tư duy BĐ":**
- Cả 3 video của dự án không còn ở đường dẫn cũ, nên lần tua đầu tiên làm app sập.
- Đã sửa: thời gian không hợp lệ giờ được hiểu là 0.

**Kiểm thử:**
- G7 chạy trên video thử và trên bản sao 3 dự án thật: "Bài tập cảm giác bóng", "Tập thể lực", "Tư duy BĐ". File gốc không bị mở.
- Kết quả: ảnh đang kéo lệch chuột **0 điểm** ở cả 90 lần nhích. Trình phát vẽ **0 khung** trong lúc kéo; nhấc ra 1 lần.
- Sau khi thả khoảng 100 ms, trình phát đã tự vẽ đối tượng ở chỗ mới và ảnh nổi được gỡ.
- Kéo logo: lệch 0 điểm, 0 khung.
- "Tư duy BĐ" thiếu video nên không đo kéo được; chỉ xác nhận app không còn sập.
- G4/G5/G6: 51 đạt; G2/G3: 80 đạt. Core 396, Media 231 đạt.
- Self-test toàn bộ: 432 đạt, 1 lỗi đã biết (phím tắt menu hệ thống trùng).

**Chưa kiểm chứng:**
- Kéo bằng chuột hoặc trackpad thật trên màn hình 5K. Sự kiện chuột trong bài đo được gửi thẳng tới view, không qua hệ thống.
- Kéo trên dự án ảnh chỉ được G4 kiểm tra về vị trí, chưa đo độ mượt.
