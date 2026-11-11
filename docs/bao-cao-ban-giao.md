# Báo cáo bàn giao MacPlayer

Ngày: 05/11/2026 (cập nhật lần cuối 11/11/2026, bản 0.8.1; xem "Bổ sung 0.3.0–0.7.0", "Bản 0.7.1", "Bản 0.8.0" và "Bản 0.8.1" ở cuối) · Máy kiểm thử: Apple Silicon, macOS 27.0.1, Swift 6.4, chỉ có Command Line Tools.
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

