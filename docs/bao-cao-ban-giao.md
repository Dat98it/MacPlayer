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


## Bản 0.17.3: không khựng khi phát; chạy bộ tự kiểm tra G1–G9 (13/11/2026)

**Yêu cầu:** chạy bộ tự kiểm tra G1–G9.

**Kết quả lần chạy đầu (bản 0.17.2):** 510 đạt, 2 lỗi. Một lỗi đã biết từ trước (menu hệ thống "Emoji & Symbols"/"Enter Full Screen" bị tính là trùng phím tắt). Lỗi còn lại là **lỗi mới do 0.17.2**: G9 "dự án phát trong cửa sổ" chỉ phát được 0,2 s trong 1 s. Nguyên nhân: cửa sổ vừa hiện (hoặc đổi cỡ) lúc đang phát thì khung xem bị dựng lại theo cỡ màn hình, làm hình dừng khoảng nửa giây. Đã xác nhận bằng cách tắt riêng việc dựng lại: phát 0,63 s, đạt.

**Sửa:** không dựng lại khi đang phát; giữ lại và dựng khi tạm dừng. G9 thêm kiểm tra: sau khi dừng, khung xem được dựng đúng cỡ cửa sổ (1356×762 cho vùng 1356×937).

**Kiểm thử:** G9 riêng 2 lần đạt hết; toàn bộ self-test 512 đạt, chỉ còn lỗi menu hệ thống đã biết; Core 423, Media 254 đạt.

## Bản 0.17.2: ảnh/chữ/hình/nhãn dán sắc nét hơn (13/11/2026)

**Yêu cầu:** ảnh, chữ, hình, nhãn dán kéo thả vào bị mờ, không sắc nét.

**Nguyên nhân tìm được (đo trên dự án thật "Đến khi nào remix"):**
1. Khung xem luôn dựng ở 1920×1080 rồi phóng/thu theo cửa sổ (0,7× ở cửa sổ nhỏ, 1,1× ở cửa sổ lớn). Nay dựng đúng số điểm ảnh của màn hình (ví dụ 1356×762, 2196×1236; tối đa cao 1800), dựng lại khi cửa sổ đổi cỡ quá 12%. Video xuất không đổi.
2. Nguyên nhân chính: chữ, hình, nhãn dán được vẽ ở cỡ gốc rồi **phóng to ảnh bitmap** khi người dùng kéo góc để phóng (tên bài trong dự án đang phóng 1,58×), cả lúc xem lẫn khi xuất. Nay vẽ thẳng ở cỡ đã phóng (tới 3×), chỉ thu nhỏ/xoay. Test: chữ phóng 2,5× trùng khớp với chữ được vẽ thẳng ở cỡ đó (trước đây số điểm ảnh viền nhoè gấp 3,5 lần).
3. Ảnh lớp to (vài nghìn điểm ảnh) thu nhỏ bằng nội suy đơn giản bị rỗ/răng cưa. Nay dùng Lanczos khi thu nhỏ dưới 0,75×. Test: bàn cờ 1 điểm ảnh 2000×2000 thu còn 200×150 ra màu xám đều.

**Kiểm chứng trên cửa sổ thật (dự án thật, đã sao lưu ngay trước và chép trả sau, mã băm khớp):** phóng to 5× vùng chữ "ĐẾN": viền chữ trước loang 2–3 điểm ảnh, nay khoảng 1. Ảnh nền gió (file JPG Facebook 2048×1892, vẽ gần 1:1) không đổi: độ mờ còn lại là của chính file ảnh đó (nén JPG), app không làm nét hơn được.

**Kiểm thử:** Core 423, Media 254 đạt (thêm `SharpnessTests`).

**Chưa kiểm chứng:** xem bằng mắt khi đang phát; ảnh động/video làm lớp (không đổi cách vẽ ngoài Lanczos khi thu nhỏ); self-test G1–G9 (sandbox) không chạy.

## Bản 0.17.1: thanh cài đặt bên phải chia tab (13/11/2026)

**Yêu cầu:** các mục chỉnh sửa ở thanh bên phải hiện theo tab, không phải cuộn dài.

**Đã làm:** thanh tab con (biểu tượng + tên ngắn, xuống dòng khi hẹp, chấm xanh ở nhóm đã chỉnh, nhớ tab đã chọn cho từng mục) cho: Chữ/Hình/Nhãn dán (8 tab, tách "Chữ" thành Chữ · Kiểu · Thời gian), Lớp ảnh (5), Cơ bản (6), Màu (6, biểu đồ thành một tab), Hiệu ứng (3), Tốc độ (4), Tách nền (4), Âm thanh (2–4). Một số tên dịch bị trùng/sai khi làm tab (Animation và Motion cùng thành "Chuyển động"; "Shape" thành "Tỷ lệ") đã có tên riêng: Vào/ra, Hình, Hình cắt, Ánh sáng.

**Kiểm thử:** Core 423, Media 252 đạt (không đổi logic). Chụp cửa sổ thật trên dự án thật khi chọn chữ (3 tab), nhãn dán (tab Chuyển động), ảnh, đoạn video (tab Màu): mỗi tab vừa một màn hình, không cần cuộn.

**Sự cố trong lúc test và cách xử lý:** trong lúc tôi đang thử, người bảo trì đã mở "Đến khi nào remix" bằng app thật và chỉnh sửa (thêm hình vuông, mũi nhọn, 😭, 💪, 🎁; xoá tên bài). Sau lần thử tiếp theo, tôi chép bản sao lưu lúc 08:28 đè lên file nên các chỉnh sửa đó bị mất. Tôi phát hiện vì lần chụp có 6 thứ trên hình thay vì 1, và đã khôi phục từ điểm khôi phục app tự giữ (`Recovery/55903E7F…/snapshots`, 09:06), bỏ đúng nhãn 🔥 do bài test thêm vào. Đã mở lại để kiểm tra: đủ 5 thứ ở 0:39. Từ nay sao lưu ngay trước mỗi lần thử và so mã băm trước khi chạy.

**Chưa kiểm chứng:** bấm chuột thật vào các tab; self-test G1–G9 (sandbox) không chạy.

## Bản 0.17.0: sửa lỗi trong suốt và gõ chữ; kéo giãn ảnh; Trang chủ, Quay lại/Tiến lên, Lịch sử; thêm mẫu; hiệu ứng chuyển động (13/11/2026)

**Cách kiểm thử lần này (theo yêu cầu):** dùng thẳng dự án thật của người bảo trì, app thật, không sandbox. Trước khi thử: sao lưu 12 file `.macplayer` (ổ Lexar) kèm mã SHA-256; sau mỗi lần thử chép bản sao lưu trở lại và so mã băm (đều khớp). Nhạc/video gốc chỉ được đọc. Một lần tôi đóng app thử bằng cách dừng tiến trình nên app để lại bản "khôi phục sau khi thoát đột ngột" trong thư mục Recovery thật; tôi đã chuyển đúng 2 file đó vào Thùng rác và thêm cách thoát êm cho các lần sau.

**Lỗi chữ/hình/nhãn dán/ảnh trong suốt khi thả** — tái hiện bằng ảnh chụp cửa sổ thật trên dự án "Đến khi nào remix":
1. Hiệu ứng xuất hiện (bật ra, mờ dần) bắt đầu đúng tại đầu phát; dừng ở đó thì khung hình vẽ với độ mờ 0. Sửa: khi dừng, vẽ ở trạng thái đã hiện xong; khi phát và khi xuất, hiệu ứng giữ nguyên.
2. (Đúng như người bảo trì nghi về lớp layer) Ảnh thả vào là một lớp bắt đầu đúng thời điểm đầu phát (21,487 s), nhưng khung đang hiện bắt đầu từ 21,467 s nên khung đó không có lớp này: chỉ thấy khung chọn. Sửa: mọi thứ thêm tại đầu phát bắt đầu từ đầu khung đang hiện. Ảnh chụp sau khi sửa: ảnh hiện.
Ghi nhận thêm: chữ luôn được vẽ trên mọi ảnh/lớp (thứ tự cố định), nên ảnh thả vào nằm dưới tên bài.

**Lỗi chữ đổ bóng, lệch khi gõ:** mỗi phím dựng lại toàn bộ khung xem; chữ cũ vẫn vẽ dưới ô gõ. Đo trên dự án thật: 0 lần dựng lại trong lúc gõ, 1 lần khi bấm Return; ảnh chụp khi đang gõ chỉ còn chữ trong ô. Thêm: ô gõ tự cao theo nội dung (lần chụp đầu thấy dòng trên bị cắt).

**Tính năng mới:** kéo giãn ảnh tự do (tay nắm giữa các cạnh, thanh Kéo giãn, nút Tỉ lệ gốc); nút Trang chủ; Quay lại/Tiến lên; danh sách Lịch sử để nhảy tới một bước; 35 kiểu chữ, 33 hình, hơn 120 nhãn dán; 13 hiệu ứng chuyển động liên tục cho chữ/hình/nhãn dán/ảnh.

**Kiểm thử:**
- Core thêm `EditorAdditionsTests` (vẽ đầy đủ khi dừng, chuyển động lặp đúng chu kỳ và trong giới hạn, kéo giãn từ cạnh, mở dự án cũ, ≥30 mẫu, lịch sử). Media thêm `EditorDrawingTests` (nhãn dán hiện khi dừng, ẩn ở khung đầu khi phát như video xuất; ảnh kéo giãn vẽ đúng 80×120; hiệu ứng Lắc ngang làm nhãn dán dịch qua lại trong video xuất; mọi hình vẽ được; mọi kiểu chữ có đúng phông trên máy). Cập nhật 2 test cũ (số hình = 16; 3 hình mới rỗng giữa theo thiết kế). Core 423, Media 252 đạt.
- Cửa sổ thật trên dự án thật: thả 🔥, chữ Neon, ngôi sao, ảnh (đều hiện); gõ tên bài; hiệu ứng Nảy khi phát (vị trí ngôi sao thay đổi giữa các khung 132–165 điểm ảnh); ảnh kéo giãn 1,6; lịch sử ghi đúng 5 bước.

**Chưa kiểm chứng / chưa chạy:**
- Self-test tự động G1–G9 (chạy trong sandbox) không chạy lần này theo yêu cầu không dùng sandbox; các luồng kéo-thả trên hình (G4–G7) vì vậy chưa được chạy lại tự động.
- Bấm chuột/bàn phím thật (các thao tác được gọi qua đúng hàm mà chuột/phím gọi, trong app thật).
- Dự án "Tư duy BĐ" không phát được vì 3 video của nó không còn ở chỗ cũ (Missing) — có sẵn từ trước, không liên quan bản này.

## Bản 0.16.4: xuất video nhanh hơn cho mọi dự án (12/11/2026)

**Yêu cầu:** xuất video (dự án từ mp3) rất lâu; tối ưu ngắn nhất có thể, cho cả dự án video nói chung.

**Đo trước (bản release, máy này):**
- Bài thật 3:42 → video 1080p: 29,4 giây. Thời gian tỉ lệ với số khung: 30 khung/giây → 29,4 s; 1 khung/giây → 1,2 s.
- Video thật 1080p 60 fps HDR 84 giây có chỉnh màu: 25,3 giây.
- Chỉ đọc và vẽ (không mã hoá): video 9,2 s, bài hát 12,0 s; phần còn lại là **bộ mã hoá**.

**Đã làm (áp dụng cho mọi dự án video):**
1. Khung giống hệt khung trước (cùng hình nguồn, cùng vị trí, độ mờ của mọi chữ và lớp) **không vẽ lại**.
2. Khung giống hệt từng byte với khung vừa ghi **không mã hoá lại**; khung trước được kéo dài, vẫn ghi ít nhất 1 khung mỗi giây, khung cuối luôn được ghi để hình kéo tới hết.
3. Dự án **không có gì chuyển động** (chỉ ảnh/ảnh bìa, chữ và logo không hiệu ứng, không chuyển cảnh): vẽ 4 khung/giây thay vì 30.
4. Bộ mã hoá phần cứng ở chế độ **ưu tiên tốc độ**, cùng tốc độ bit.

**Kết quả (qua hàng đợi xuất của app, bản release):** bài 3:42 **1,2 s** (trước 29,4 s); 3:35 1,2 s; 5:24 1,6 s; bản 79 phút **20,8 s** (trước ước ~10,5 phút); video thật 84 s **16,7 s** (trước 25,3 s); video dọc thật 32 s có chữ: 5,1 s.

**Lỗi tìm được trong lúc làm:** xuất một đoạn 2 giây ra file 2,5 giây khi có khung bị bỏ (khung cuối mang độ dài cũ) — sửa bằng cách kết thúc file đúng độ dài timeline. Một test đọc thời điểm khung trên dữ liệu nén báo "mất 1 giây đầu" trong khi file đúng (ffprobe xác nhận khung đầu ở 0:00): do khung bị sắp xếp lại (B-frame); test giờ đọc khung đã giải mã.

**Thay đổi về file xuất:** video có khung không đều (đoạn đứng yên chỉ 1 khung/giây; đoạn có chuyển động giữ nguyên tốc độ khung). Điện thoại, QuickTime, trình duyệt, YouTube đều phát loại file này (iPhone cũng quay ra loại này). Chữ/logo đứng yên trên dự án tĩnh xuất hiện/biến mất chính xác tới 1/4 giây.

**Kiểm thử:** Media thêm `FastExportTests` (nhận đúng khung trùng/khác kể cả khác 1 điểm ảnh; chữ hiện đúng 1–2 s trên ảnh tĩnh, không sớm/muộn; video chuyển động giữ đủ 90/90 khung; khi nào coi là "không gì chuyển động"). Cập nhật 3 test cũ đòi 30 khung/giây đều cho cả đoạn ảnh. G9 xuất trọn từng bài thật qua hàng đợi, kiểm độ dài, có hình và tiếng, chữ còn ở 0,5 s trước cuối. Core 417, Media 248 (chạy 2 lần) đạt; G9 95 đạt (2 lần); self-test đầy đủ 511 đạt, 1 lỗi đã biết.

**Chưa kiểm chứng:** tải video xuất ra lên YouTube/Facebook/TikTok thật (không làm vì cần đăng tải ra ngoài); xem bằng mắt chất lượng chế độ ưu tiên tốc độ trên video nhiều chuyển động (chỉ kiểm bằng các test so điểm ảnh sẵn có); dự án dài nhiều chuyển cảnh, hiệu ứng (vẫn phải vẽ và mã hoá từng khung, chỉ nhanh hơn nhờ bộ mã hoá).

## Bản 0.16.3: chữ tên bài trong suốt lúc mới tạo dự án; xuất đoạn cuối bài lỗi (12/11/2026)

**Người bảo trì báo:** tạo dự án từ mp3 thì dòng chữ không hiện (rê chuột vào vẫn thấy khung); xác nhận cả tên bài, nghệ sĩ, album đều trong suốt. Yêu cầu test bằng mp3 thật.

**Nguyên nhân (đã tái hiện bằng ảnh chụp cửa sổ thật ở 0:00):** chữ do 0.16.2 thêm có hiệu ứng hiện dần 0,3 giây bắt đầu đúng 0:00; dự án mới mở ở 0:00 nên khung hình đầu vẽ chữ với độ mờ 0 (trong suốt). Self-test 0.16.2 chỉ kiểm chữ có trong dự án và gõ được, không kiểm chữ có được *vẽ* ở 0:00 — lỗ hổng của tôi.

**Lỗi thứ hai tìm thấy khi viết test:** xuất đoạn cuối bài báo "no frame to compose": video bìa 5 giây một hình không có hình nào sau hình cuối cùng (tới 5 giây cuối bài).

**Sửa:**
- Chữ tên bài/nghệ sĩ không còn hiện dần: thấy ngay từ khung hình đầu.
- Video bìa có thêm một hình sát cuối bài.
- Dự án nhạc tạo bằng 0.16.0–0.16.2 được sửa khi mở: làm lại video bìa từ file nhạc; chữ của 0.16.2 bỏ hiện dần; dự án 0.16.0/0.16.1 (chữ vẽ chết trong ảnh) được thêm tên bài thành chữ chỉnh được nếu dự án chưa có chữ nào.

**Kiểm thử với nhạc thật** (bản sao của 3 bài trong `Lexar/Nhạc`, `Nhạc Truyền Động Lực…` — file duy nhất có thẻ tên bài — trong thư mục Nhạc, `_mau.m4a`, và bản 79 phút; 20 file thật được đọc thẻ: không file nào có nghệ sĩ/album/ảnh bìa): với mỗi bài, tạo dự án, xuất 1 giây đầu (đếm điểm ảnh trắng của chữ tên bài trong khung đầu tiên: 526–13.418, đều > 200) và 2 giây cuối (đều 2,00 s). File gốc không đổi (so từng byte).
- Media test mới `aSongsTitleIsDrawnFromTheVeryFirstFrame`: chữ có trong khung đầu; với hiện dần như 0.16.2 thì không có (test bắt được đúng lỗi). Test này cũng là thứ làm lộ lỗi xuất đoạn cuối.
- G9: dự án giả lập 0.16.2 mở ra được làm lại video bìa và chữ hết trong suốt. G9: 85 đạt. Core 417, Media 244 đạt. Self-test đầy đủ: 511 đạt, 1 lỗi đã biết.
- Chụp cửa sổ thật ở 00:00:00:00 (tiếng Việt): chữ hiện với bài thử và bài thật.

**Chưa kiểm chứng:** nhạc thật có nghệ sĩ/album/ảnh bìa (nhạc của bạn không có thẻ đó; dùng file tự tạo); xuất trọn một bài dài ra video (chỉ xuất 1 giây đầu và 2 giây cuối).

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


## Bản 0.17.4 — tỉ lệ riêng cho đoạn trên timeline (13/11/2026)

- Tái hiện từ dự án thật “Tập bóng đá” (4 đoạn, 2 nguồn): lệnh của bảng thuộc tính gọi `setFrame`, nên đổi đoạn 4 làm thay đổi cả 4 đoạn. Lặp lại hai lần cho cùng kết quả.
- Bảng **Cơ bản ▸ Khung hình** giờ chỉ chỉnh đoạn đang chọn; tỉ lệ riêng được lưu trong trường tùy chọn `VideoLook.clipCanvas`. Trình dựng hình đặt khung riêng của đoạn vào khung chung, nên đổi đoạn đầu cũng không làm hình các đoạn sau thay đổi. Thiết lập **Xuất** vẫn áp dụng khung chung khi người dùng chọn.
- Giữ cách dựng của dự án cũ khi chưa có trường mới; kiểm tra lưu/đọc lại và Hoàn tác/Làm lại.
- Kiểm thử: toàn bộ **680 bài** (425 Core + 255 Media) qua; bài hồi quy điểm ảnh cho đoạn đầu/cuối đã thất bại trước sửa và qua sau sửa, cả xem trước lẫn xuất. Kiểm tra bản dịch: 0 thiếu, 0 sai tham số.
- Luồng app G10 mở bản sao của dự án thật, dùng đúng binding của hai menu thuộc tính; đổi đoạn 4 và đoạn 1, đối chiếu ảnh từng đoạn, chuyển lựa chọn, Hoàn tác/Làm lại, lưu và giải mã. **23 kiểm tra qua**; file gốc được so từng byte với bản sao lưu và không thay đổi. Media gốc chỉ được đọc.
- Chưa chạy xuất toàn bộ dự án thật dài 5:46; kiểm tra xuất bằng video tổng hợp có bốn đoạn, cùng đường dựng hình. Chưa thử trên Intel.


## Bản 0.18.0 — tách lời để lấy nhạc nền (16/11/2026)

- Thêm **Tách lời** ở cửa sổ mở bài hát/video, **Tệp ▸ Tách lời…** và bảng **Âm thanh** của đoạn hoặc bài nhạc trong dự án. Chọn file và **Tách và lưu nhạc nền…** để tạo file `.m4a` mới (stereo AAC 256 kb/s), có tiến trình, nút Hủy, Mở và Hiện trong Finder. Không thay đổi project hay file gốc.
- UVR MDX-Net Inst HQ 3 chạy bằng Core ML; mô hình MIT khoảng 33 MB được đóng gói sẵn, kèm nguồn và giấy phép. Không tải mô hình khi sử dụng, không gửi âm thanh đi đâu, không cần Python hay thư viện Swift bên ngoài. Script build xác minh SHA-256 của mô hình rồi biên dịch vào app.
- Đọc và xử lý cửa sổ âm thanh cố định 44.1 kHz, stereo; có ngữ cảnh ở hai đầu và cắt bỏ ngữ cảnh khi ghép, không giữ cả bài dài trong RAM. STFT phức Hann định kỳ đúng cấu hình mô hình. Chạy cặp đầu vào thuận/nghịch dấu để loại nhiễu lệch của mô hình; bản đầu sinh tiếng nhỏ ở khoảng lặng đã được sửa và có kiểm thử.
- Kết quả qua SafeSaver: file tạm cạnh đích, kiểm tra track và thời lượng rồi mới đưa vào chỗ lưu. Refuse ghi đè nguồn/file có sẵn. Hủy hoặc đóng cửa sổ dọn file dở; thoát app đợi dọn xong. Tác vụ nền giữ UI đáp ứng. Thời lượng lấy theo track âm thanh, cho phép video có hình dài hơn phần nhạc.
- **Kiểm tra thực tế:** luồng app G11 chạy toàn bộ video bài hát 195,2 giây do người dùng chỉ định, tạo nhạc nền 195,193 giây. Bản debug mất 202,66 giây; đây không phải số đo hiệu năng release. 10 kiểm tra qua: UI đáp ứng, hủy, từ chối tác vụ trùng, dọn file tạm, lưu/đọc kết quả, giữ thời lượng và từ chối ghi đè. SHA-256, kích thước và thời điểm sửa của video gốc đều giữ nguyên. File thử và log nằm ngoài repo.
- **Chất lượng có mẫu chuẩn:** giọng tổng hợp + nhạc nền tự tạo 10 giây: hệ số phần giọng giảm 44,52 dB, mức nhạc nền giảm 0,33 dB, sai số so với nhạc nền chuẩn cải thiện 19,54 dB. Mẫu này không đại diện cho mọi bài hát. Test có giọng tổng hợp bốn giây riêng, không đưa bài hát người dùng vào repo.
- Media `VocalRemovalTests`: 8 bài về pha/biên/biên độ STFT, loại giọng giữ nhạc, khoảng lặng, mono/48 kHz/ranh giới cửa sổ, hủy, bảo vệ nguồn/đích, video không có âm thanh và audio ngắn hơn video.
- **Bản đóng gói release:** chạy lại G11 trên toàn bộ bài hát thật, 10/10 kiểm tra qua; 195,193 giây nhạc được xử lý trong 17,27 giây. Mô hình được nạp từ bundle (bản release không có đường dự phòng tới mã nguồn). Đã cài 0.18.0 (36) vào `/Applications/MacPlayer.app` và xác minh chữ ký, binary khớp gói ZIP.
- **Bộ kiểm thử đầy đủ:** 688 bài qua (425 Core, 255 Media khác và 8 tách lời). Nhóm Core ML chạy riêng vì dùng chung GPU làm bài đo xuất video tăng từ 0,32 lên 6,25 giây; không thay đổi ngưỡng hiệu năng hay bỏ bài nào. Kiểm tra bản dịch: 0 thiếu, 0 sai tham số.
- **Giới hạn:** chưa đánh giá nghe chủ quan trên nhiều thể loại hoặc thử trên Intel/macOS 15. Tùy bản phối có thể còn giọng hát hoặc giảm nhạc cụ; UI nói rõ điều này. Công cụ xử lý toàn bộ file nguồn, không tự thay âm thanh trong dự án.


## Bản 0.19.0 — Cắt nhanh trên timeline (16/11/2026)

**Yêu cầu:** tính năng biên tập hay dùng như CapCut/Final Cut, bắt đầu bằng "Cắt nhanh trên timeline".

**Đã làm:**
- **Q / W** (và nút **Bỏ trước / Bỏ sau**): bỏ phần của đoạn dưới đầu phát nằm trước/sau đầu phát, cắt đúng khung đang hiện như lệnh Tách (S). Sau Q, đầu phát nằm ở đầu đoạn, đúng khung hình vừa xem. Đầu phát sát mép đoạn (dưới 1 khung) thì báo, không cắt.
- **Kéo theo** (bật sẵn, nhớ giữa các lần mở): khi đoạn chính ngắn đi, dài ra hay bị xóa, chữ/hình/nhãn dán, lớp ảnh/video, âm thanh, điểm đánh dấu và phụ đề phía sau dịch theo. Thứ chạy ngang qua phần bị bỏ (ví dụ nhạc nền) ngắn lại và phát tiếp, không nhảy. Thứ bắt đầu trong phần bị bỏ bắt đầu ở chỗ cắt, bỏ phần đầu (âm thanh và lớp video tua tới đúng chỗ, keyframe và đường âm lượng dịch theo). Chữ, lớp, âm thanh nằm trọn trong phần bị bỏ **được giữ lại** ở chỗ cắt với độ dài cũ; riêng dòng phụ đề nằm trọn trong đó bị xóa (là lời của hình đã bỏ). Hoàn tác trả lại tất cả.
- **⇧-click** trên đoạn chính chọn mọi đoạn ở giữa; ⌫ xóa cùng lúc (một bước hoàn tác, "Xóa các đoạn").
- **Sửa lỗi cũ:** kéo mép trái của đoạn cộng dồn từng lần nhích chuột (kéo 1→2→3 giây cắt 6 giây). Nay mỗi lần kéo tính lại từ trạng thái lúc bấm chuột; kéo ra ngoài để lấy lại phần đầu cũng được.

**Kiểm thử:**
- Core `TimelineCutsTests` (9 bài): bỏ trước/sau, đầu phát ở mép, tắt Kéo theo, xóa nhiều đoạn, âm thanh/lớp video bắt đầu trong phần bị bỏ, kéo mép ra/vào, ⇧-click. Toàn bộ: Core 434, Media 255, tách lời 8 — đều qua. Bản dịch: 0 thiếu.
- Cửa sổ thật trên dự án thật "TỔNG HỢP NHẠC REMIX HAY" (8 đoạn; sao lưu ngay trước, chép trả và so mã băm sau mỗi lần): phím Q ở 0:03 qua đúng đường xử lý phím của cửa sổ → đoạn 1 ngắn 3,00 s, chữ "Trích dẫn" 4,30–7,30 → 1,30–4,30; W ở 1:16:40 → đoạn 2 còn 58 s, các đoạn sau dồn lên; kéo mép trái 1→2→3 s → cắt đúng 3,00 s, 1 bước hoàn tác; kéo mép phải tới 4100 s → đúng 4100,00 s.

**Chưa làm/chưa kiểm chứng:** kéo nhiều đoạn đã chọn để đổi chỗ cùng lúc; đổi tốc độ đoạn hoặc đổi thứ tự đoạn chưa kéo theo chữ/lớp/âm thanh; nút "hút vào nhịp nhạc" thuộc tính năng "Theo nhịp nhạc" (chưa làm); bấm chuột thật vào các nút.


## Bản 0.20.0 — Thứ tự lớp, Theo nhịp nhạc, phụ đề kiểu TikTok (16/11/2026)

**Yêu cầu:** làm tiếp "Theo nhịp nhạc", "Phụ đề tự động kiểu TikTok", "Thứ tự lớp", và các mục còn lại của 0.19 (kéo nhiều đoạn, đổi tốc độ/thứ tự kéo theo, hút vào nhịp, bấm chuột thật).

**Đã làm:**
- **Thứ tự lớp:** chữ/hình/nhãn dán và ảnh/video lớp chung một chồng (trước đây chữ luôn nằm trên mọi ảnh lớp). 4 lệnh ở menu Sửa, menu chuột phải trên hình, thẻ Vị trí và kích thước; phím ⌥⌘] ⌥⌘[ (thêm ⇧: lên/xuống hẳn). Chỉ tính những thứ hiện cùng lúc. Thứ thêm sau luôn nằm trên. Bấm chuột trên hình chọn thứ nằm trên cùng. Ảnh (dự án ảnh) cũng theo thứ tự này.
- **Theo nhịp nhạc (Âm thanh ▸ Nhịp):** tìm nhịp ngay trên máy (bài 3 phút ~0,7 s), vạch nhịp trên bài nhạc ở timeline, kéo thả và kéo mép bám vào nhịp và điểm đánh dấu, **Cắt khớp nhịp** (mỗi 1/2/4/8 nhịp; chỉ dời một chỗ cắt về nhịp cách nó không quá một nhịp; chỉ kéo dài đoạn nếu video còn hình), **Đánh dấu nhịp**, **Bỏ nhịp**. Bài nhạc giữ nguyên độ dài.
- **Phụ đề kiểu TikTok (Phụ đề ▸ Kiểu phụ đề):** Nổi bật, Hộp màu, Nảy, Từng từ, Chữ đậm; màu từ, chữ in hoa, phông (có đủ dấu tiếng Việt), cỡ, độ cao; chọn kiểu thì bật in vào hình khi xuất. Tạo phụ đề từ giọng nói (tiếng Việt chạy được trên máy) cho câu ngắn ≤3 từ, giữ thời điểm từng từ; dòng gõ tay/nhập file chia theo độ dài từ; nút chia dòng dài thành câu ngắn. Cắt bỏ phần đầu một dòng thì bỏ cả các từ nói trong đó.
- **Kéo nhiều đoạn đã chọn** (⌘/⇧-click) để đổi chỗ cùng lúc, giữ thứ tự; bấm không kéo thì chỉ chọn đoạn đó.
- **Kéo theo khi đổi thứ tự:** chữ, lớp, âm thanh, điểm đánh dấu, phụ đề nằm trọn trên một đoạn đi cùng đoạn đó; nhạc chạy qua nhiều đoạn đứng yên. **Khi đổi tốc độ:** thứ nằm trên đoạn co giãn theo hình, thứ phía sau dịch theo độ dài mới; kéo thanh trượt tốc độ là một bước hoàn tác.

**Kiểm thử:**
- Test mới: Core `LayerOrderTests` (7), `BeatSyncTests` (9, có trường hợp đoạn 1 giờ dưới bài 2 phút), `CaptionTests` (5), `TimelineCutsTests` +3 (đổi thứ tự, nhiều đoạn, tốc độ); Media `BeatDetectorTests` (vòng trống 128 và 100 bpm tạo sẵn: đúng tempo, mọi nhịp lệch < 30 ms; âm đơn không có nhịp), `CaptionRenderTests` (4, đo điểm ảnh), `PhotoLogoTests` +1 (hình nằm trên/dưới logo). Toàn bộ: Core 457, Media 264, tách lời 8 — đều qua. Bản dịch 0 thiếu.
- Bài thật (chỉ đọc): "Đến khi nào remix - Nhạc nền" 69,8 nhịp/phút (bằng một nửa nhịp thật ~140: vạch vẫn trúng nhịp nhưng thưa gấp đôi), "Liên khúc… cỏ 3 lá" 139,5, "Vết Thương Remix" 138,2 (video 36 phút, 3,4 s).
- Cửa sổ thật, trên **bản sao** của dự án "TỔNG HỢP NHẠC REMIX HAY" (MacPlayer của người bảo trì đang mở nên không chạm file gốc), thêm bài nhạc thật, một ảnh thật làm lớp và 3 dòng phụ đề: **bấm chuột thật** (sự kiện chuột hệ thống) vào tab Nhịp, Tìm nhịp (140 nhịp trong 2 phút), Cắt khớp nhịp, Hoàn tác, kéo thanh thu phóng. Lần bấm Cắt khớp nhịp đầu tiên **lộ lỗi**: đoạn 1 giờ 15 phút bị cắt còn 2 phút (dời về nhịp cuối của bài) — đã sửa và thêm test. Sau đó các bước còn lại chạy qua hook debug `MACPLAYER_DEV_DO` trên bản sao mới (4 lần tách ở 10–55 s): cắt khớp nhịp dời 4 chỗ cắt, phụ đề trong đoạn dịch theo; tốc độ 2× đoạn 2: 15,42 → 7,71 s, phụ đề 11,10 → 10,60; dời đoạn 3–4 lên đầu: chữ 4,30 → 34,30, lớp 4,00 → 34,00, nhạc đứng yên; hoàn tác trả lại; đưa ảnh lớp lên/xuống: ảnh chụp cửa sổ cho thấy ảnh che chữ "Trích dẫn" rồi chữ nằm trên ảnh; phụ đề Hộp màu tô đúng từ "CÁC" ở 9,2 s.

**Sự cố khi kiểm thử:** để đóng bản thử, một phím ⌘Q được gửi bằng sự kiện bàn phím hệ thống; bản thử không nhận, và MacPlayer của người bảo trì (đang mở) đã không còn chạy sau đó — rất có thể phím đã tới nó. Thoát bình thường, dự án tự lưu. Từ đó chỉ bấm chuột vào cửa sổ bản thử và dừng bản thử bằng tiến trình của nó.

**Chưa làm/chưa kiểm chứng:** bấm chuột thật vào nút thứ tự lớp, kiểu phụ đề và ⇧/⌘-click kéo nhiều đoạn (máy đang được dùng, Chrome ở trước, nên dừng bấm chuột tự động; các lệnh này đã chạy qua hook debug và test); nghe bằng tai độ khớp nhịp; nhịp với bài đổi tempo; phụ đề cắt ngang ranh giới hai đoạn không đi theo khi đổi thứ tự (đứng yên như nhạc nền); "Nổi bật" dùng chung chữ dịch với nút cũ.


## Bản 0.20.1 — làm nốt phần "chưa kiểm chứng" của 0.20.0 (16/11/2026)

**Đã làm:**
- **Bấm chuột thật** (sự kiện chuột hệ thống, cửa sổ bản thử nổi trên các app khác bằng `MACPLAYER_DEV_FLOAT`, công cụ bấm từ chối mọi điểm có cửa sổ khác che và không gửi phím), trên bản sao mới của dự án "TỔNG HỢP NHẠC REMIX HAY" (thêm bài nhạc thật, một ảnh thật làm lớp, 3 dòng phụ đề; tách 3 lần ở 10–40 s):
  - chuột phải lên ảnh lớp → menu có 4 lệnh thứ tự (Xuống một lớp/Dưới cùng mờ đúng vì ảnh đang dưới cùng) → **Đưa lên trên cùng**: ảnh che chữ "Trích dẫn";
  - nút **Xuống một lớp** trong thẻ Vị trí: chữ lại nằm trên ảnh; hai nút dưới mờ, hai nút trên sáng;
  - Phụ đề ▸ Kiểu phụ đề ▸ **Tô từ**, nhảy tới dòng đầu (8 s): "XIN" tô vàng, "CHÀO CÁC" trắng;
  - bấm đoạn 3, **⌘-click** đoạn 4, kéo cả hai lên trước đoạn 2: thứ tự lưu trong file thành 1, 3, 4, 2, cả hai vẫn được chọn.
- **Thay cho nghe bằng tai:** đo trên 3 bài thật xem nhịp có rơi vào tiếng gõ mạnh (trong 40 ms): 581/666, 2631/2767, 227/227; cùng lưới dời nửa nhịp chỉ 450, 2257, 184.
- **Bài đổi tempo:** nhịp tìm lại theo từng đoạn 12 s; test 100 → 130 nhịp/phút: mọi nhịp trước và sau chỗ đổi đều trúng.
- **Nhịp gấp đôi:** khi phách giữa mạnh gần bằng phách chính thì lấy gấp đôi. "Đến khi nào remix" vẫn 70 nhịp/phút vì phách giữa chỉ mạnh bằng 30 % (trống chính thật sự ở 70); thêm **Mỗi nửa nhịp** để có lưới 140.
- **Đổi thứ tự đoạn:** chữ và phụ đề nằm ít nhất 60 % trên một đoạn đi theo đoạn đó (cắt gọn theo đoạn); tiêu đề trải nhiều đoạn và nhạc nền đứng yên.
- Kiểu phụ đề "Nổi bật" có chữ riêng: **Tô từ**.

- **Chọn ngôn ngữ** (yêu cầu thêm trong lúc làm): MacPlayer ▸ **Ngôn ngữ · Language** (Theo máy Mac / English / Tiếng Việt) và mục đầu tiên của Cài đặt. Đổi là có hiệu lực ngay: thanh menu, tiêu đề, mọi bảng, thanh công cụ timeline, cửa sổ Cài đặt/Hàng đợi/Xuất/Mở liên kết/Tách lời. Tên mục có cả hai thứ tiếng để luôn tìm thấy.
  - Lỗi tìm ra khi thử: đổi ngôn ngữ làm app sập vài giây sau (bộ hẹn giờ tự lưu). Nguyên nhân: dựng lại thanh menu chuyển menu "Mở gần đây" dùng chung sang menu mới rồi bỏ menu đó đi. Đã sửa (giữ menu đang dùng, chỉ đổi chữ); 3 lần chạy đổi en → vi → en liên tiếp không còn sập.
  - Ảnh chụp cửa sổ bản thử sau khi đổi sang Tiếng Việt khi đang mở dự án: toàn bộ bảng, thanh công cụ, tab, timeline ("Lớp 2", "Đoạn 2") đều tiếng Việt; phụ đề Tô từ vẫn hiện đúng.

**Kiểm thử:** Core 459, Media 264, tách lời 8 — đều qua; bản dịch 0 thiếu.

**Bổ sung sau (cùng ngày):**
- **Bấm chuột thật** (bản debug đóng trong một gói app, mở bằng Launch Services để nó thật sự đứng trước; công cụ bấm tìm vị trí mục menu qua Trợ năng rồi bấm bằng chuột hệ thống, và dừng nếu app khác lên trước): MacPlayer ▸ **Language · Ngôn ngữ ▸ Tiếng Việt** → thanh menu thành "Tệp Sửa Phát Đoạn Xem Cửa sổ Trợ giúp", bảng bên phải thành "Cắt khung / Trái / Trên…"; MacPlayer ▸ **Cài đặt…** → ô **Ngôn ngữ · Language** → **English**: cửa sổ Cài đặt (cả tiêu đề), thanh menu và cửa sổ chính chuyển sang tiếng Anh ngay. Giá trị ngôn ngữ mà lần thử ghi vào cài đặt của app thật đã được xoá.
- **Nghe bằng tai:** máy không nghe được. Đã làm 3 file 1 phút (bài thật, chỉ đọc) có tiếng "tách" đặt đúng các nhịp tìm được (tiếng cao hơn ở mỗi nhịp thứ 4) trong `build/nghe-thu-nhip/` để người bảo trì nghe: "Đến khi nào remix" 70, "Liên khúc… cỏ 3 lá" 140, "Vết Thương Remix" 138 nhịp/phút.

**Người bảo trì đã nghe 3 file trên: khớp nhịp.** (chỉ đo); menu Sửa trên thanh menu (chỉ bấm menu chuột phải và nút trong bảng); phụ đề 16:9 mặc định nằm ở 80 % chiều cao nên có thể đè chữ có sẵn trong video (chỉnh bằng "Độ cao trên khung hình").


## Bản 0.21.0 — Theo người, chép kiểu, cắt khoảng lặng (16/11/2026)

**Yêu cầu:** Nhóm 2 "tạo khác biệt": (5) tự đổi khung theo người, (6) sao chép và dán kiểu cho nhiều đoạn và cho chữ, (7) tự cắt khoảng lặng có xem trước danh sách.

**Đã làm:**
- **Theo người** (Cơ bản ▸ Theo người): chọn khung mới (9:16, 16:9, 1:1, 4:5) ▸ **Đổi khung, theo người**. Cả video lấy khung mới ở chế độ lấp đầy; đoạn nào có hình khác khung (lệch >4 %) được Vision tìm người ngay trên máy (vài lần mỗi giây), rồi khung đi theo: làm mượt ~1 giây, đứng yên khi người chỉ nhích trong vùng giữa, không chạy nhanh quá, không bao giờ lộ mép đen. Đường đi lưu theo thời gian của video gốc nên tách/cắt/đổi tốc độ vẫn đúng. Có tiến trình, nút Dừng, **Về giữa**, chỉ áp cho các đoạn đang chọn.
- **Chép kiểu** (Cơ bản ▸ Chép kiểu; Sửa ▸ Chép kiểu ⌥⇧⌘C / Dán kiểu ⌥⇧⌘V): chép màu, hiệu ứng, khung, tốc độ, chuyển cảnh, thu phóng của một đoạn; chọn phần muốn dán; dán cho các đoạn đang chọn hoặc **Dán cho tất cả**. Dán tốc độ thì chữ/lớp/âm thanh đi theo như khi đổi tốc độ tay. Chữ: thẻ Kiểu của chữ có **Chép kiểu / Dán / Dán cho tất cả** (phông, cỡ, màu, nền, kiểu viền/bóng, hiệu ứng vào/ra); hình sang hình chép màu tô/viền; không bao giờ đổi nội dung hay vị trí.
- **Cắt khoảng lặng** (Âm thanh ▸ Khoảng lặng): chỉnh độ dài ngắn nhất và độ nhạy ▸ **Tìm khoảng lặng** ▸ danh sách (giờ bắt đầu–kết thúc, độ dài, ô chọn, nút nghe từ ngay trước) và tổng thời gian sẽ bớt ▸ **Cắt**. Mỗi khoảng giữ lại 0,15 s hai bên để không cụt chữ; âm thanh đều đều (nhạc) không bị coi là lặng. Một bước hoàn tác.

**Kiểm thử:**
- Test mới: Core `ReframeTests` (5), `StyleCopyTests` (2), `SilenceTests` (2); Media `ReframeRenderTests` (5: khung đến đúng chỗ, thời gian theo nguồn và tốc độ, không lộ mép, tìm người bằng detector giả). Toàn bộ: Core 468, Media 270, tách lời 8 — đều qua (3 lần). Bản dịch 0 thiếu.
- Vision trên video thật (chỉ đọc): "Tập cảm giác bóng" thấy người 80/80 lần nhìn (1,6 s cho 40 s video), "Các bài khởi động" 79/80, "Cẩm nang sân 7" 0/80 — đúng vì đoạn đó là sơ đồ chiến thuật, không có người.
- Cửa sổ thật, **bấm chuột thật**, trên bản sao dự án "Tập bóng đá" (nguồn thiếu nối tạm sang "Tập cảm giác bóng.mp4"): **Theo người ▸ Đổi khung, theo người** → 3 đoạn 16:9 được theo người, khung 9:16 đầy hình, cầu thủ ở giữa, không còn viền đen; **Chép kiểu** sau khi kéo Độ bão hòa của đoạn 1 về −1 ▸ **Dán cho tất cả** → cả 4 đoạn bão hòa −1, đường theo người giữ nguyên; **Khoảng lặng ▸ Tìm** → 15 khoảng (0,4–5,4 s), nút nghe phát từ trước khoảng 3:18, bỏ chọn khoảng đầu → **Cắt 14** → video 346,3 → 331,7 s. Hoàn tác trả lại đủ (kiểm qua hook debug: 25 đoạn 320,75 s → 18 đoạn 331,7 s).
- Sửa thêm: bộ tạo video giả của test thỉnh thoảng làm sập tiến trình test (khối ghi được gọi thêm một lần sau khi xong).

**Chưa làm/chưa kiểm chứng:** video nằm ngang có người chạy ngang thật (các video bóng đá của người bảo trì đều dọc; chỉ thử bằng bản xuất 16:9 có viền và bằng test điểm ảnh); theo người cho ảnh trên timeline (bỏ qua); xuất video 9:16 đã theo người rồi xem lại; cắt khoảng lặng trên video nói chuyện thật (dự án thật toàn nhạc nền).


## Bản 0.21.1 — làm nốt phần "chưa kiểm chứng" của 0.21.0 (16/11/2026)

**Video quay ngang thật có người di chuyển** (video gia đình/sự kiện của người bảo trì trên ổ Lexar, chỉ đọc; chỉ đo bằng số, xem rất ít khung hình):
- Đo: với khung 9:16 cắt từ hình 16:9, tỉ lệ lần nhìn mà **người lớn nhất nằm trong khung**: khung đứng giữa 128/338 (38 %), khung theo người **257/338 (76 %)** trên 7 video.
- Lỗi tìm ra và đã sửa: khung **nhảy qua lại giữa nhiều người** (cách cũ lấy giữa của 3 người lớn nhất, đổi người liên tục, ví dụ 0,40 → 0,64 → 0,41 → 0,55). Nay bám một người (người gần chỗ đang theo; mất người đó mới chuyển sang người lớn nhất), bỏ qua một lần nhìn nhầm (lấy trung vị 5 lần nhìn), và vùng đứng yên tính theo phần khung đang thấy (trước đây 6 % bề ngang hình = gần 1/5 khung 9:16 nên người có thể nằm sát mép khung). Thêm test cho cả hai.

**Xuất file 9:16 đã theo người rồi xem lại:** dự án thử từ 30 giây đầu một video sự kiện quay ngang 1920×1080 ▸ Đổi khung, theo người ▸ xuất qua hàng đợi thật → file 1080×1920, 30,0 s. Vision trên chính file xuất thấy người ở 39/60 lần nhìn, phần lớn ở 0,36–0,50 bề ngang (gần giữa); xem 3 khung hình: người chính nằm trong khung.

**Cắt khoảng lặng trên giọng nói thật:**
- Không có video nói chuyện có sẵn, nên tạo một bài nói tiếng Việt bằng giọng Linh của macOS (7 câu hướng dẫn tập bóng) nối bằng các khoảng nghỉ biết trước (0,35–3 s) và tiếng ồn phòng nhỏ: tìm đúng 6 khoảng lặng dài (đầu, 1,6 s, 2,4 s, 1,2 s, 3,0 s, cuối), **không cắt** hai khoảng nghỉ ngắn 0,35 s và 0,5 s, không có khoảng nào nằm trong câu nói.
- Trên 5 video gia đình thật: 0–25 khoảng (0–8 % thời lượng), phần bị cắt nhỏ hơn mức trung bình 10–11 dB.
- Đối chiếu từng từ bằng nhận dạng giọng nói (bước debug `wordcheck:` trong bản thử đóng gói có dòng mô tả quyền): người bảo trì đã bấm **Cho phép** quyền Nhận dạng giọng nói, nhưng macOS vẫn từ chối mọi lần với "Siri and Dictation are disabled" — máy này đang tắt Đọc chính tả (`com.apple.assistant.support` không có "Dictation Enabled", dù mô hình tiếng Việt ngoại tuyến đã cài). Chạy lại sau khi người bảo trì bật Đọc chính tả: vẫn bị từ chối (có thể máy bị khoá tính năng). Bộ nhận dạng mới của macOS 26+ (SpeechAnalyzer, không phụ thuộc Đọc chính tả) không có tiếng Việt, nên với sự đồng ý của người bảo trì đã tải gói tiếng Anh chính thức của Apple và đối chiếu trên một bài nói tiếng Anh (giọng Samantha, 7 câu, khoảng nghỉ biết trước): với lề 0,15 s mỗi bên, **3 khoảng cắt lấn 0,04–0,08 s vào đầu từ** ("Then", "Start", "Do" — phụ âm đầu nhẹ dưới ngưỡng). **Đã sửa:** giữ 0,2 s sau lời trước và 0,3 s trước lời sau. Đối chiếu lại: **0/61 từ chạm khoảng cắt**, và mọi khoảng nghỉ ≥ 0,7 s giữa các từ (5 khoảng, cộng đầu và cuối) đều được tìm thấy; bài tiếng Việt vẫn tìm đủ 6 khoảng, giữ hai khoảng nghỉ ngắn. Phát hiện kèm theo: nút "Tạo phụ đề từ giọng nói" cũng hỏng như vậy trên máy tắt Đọc chính tả và trước đây chỉ báo câu tiếng Anh khó hiểu; nay app báo "Nhận dạng giọng nói cần bật Đọc chính tả… Cài đặt hệ thống ▸ Bàn phím ▸ Đọc chính tả", và các lỗi nhận dạng giọng nói khác hiện bằng tiếng Việt.

**Kiểm thử:** toàn bộ Core 469, Media 272, tách lời 8 — đều qua.


## Bản 0.22.0 — Pha hay: tự dựng highlight video bóng đá (17/11/2026)

**Yêu cầu:** người bảo trì hay phải cắt highlight video bóng đá: làm tính năng tự tìm pha hay trước.

**Đã làm:**
- **Cơ bản ▸ Pha hay**: chọn **Độ dài highlight** (15 s, 30 s, 1 phút, 1:30, 3 phút, Mọi pha tìm được), **Giây giữ trước / sau pha bóng** (mặc định 2,5 / 2) ▸ **Tìm pha hay** (thanh tiến trình, Dừng; tick **Chỉ các đoạn đang chọn** khi chọn nhiều đoạn) ▸ danh sách pha theo thời gian: giờ bắt đầu, độ dài, thanh cam độ sôi động so với pha hay nhất, nút ▶ xem thử, ô tick; các pha hay nhất vừa đủ độ dài được tick sẵn; dòng tóm tắt "Chọn x trên y pha: highlight sẽ dài …".
- **Dựng highlight**: giữ đúng các pha đã tick (cắt bỏ phần còn lại của các đoạn đã xem, đoạn không xem giữ nguyên), một bước hoàn tác; nếu đã tìm nhịp bài nhạc và tick **Sau đó cắt theo nhịp nhạc** thì đưa chỗ cắt vào nhịp trong cùng bước. **Chỉ đánh dấu**: đặt điểm đánh dấu xanh "Pha n" ở mỗi pha, không cắt.
- Cách chấm (Core `Highlights.swift`, Media `HighlightAnalyzer.swift`): đọc hình nhỏ (512 px) 5 lần/giây, đo độ thay đổi độ sáng giữa hai lần; Vision tìm người mỗi giây (diện tích người, tốc độ di chuyển của người); độ to của tiếng so với 8 giây xung quanh. Mỗi thước đo được chuẩn hoá theo chính đoạn đó (trung vị và độ lệch, giới hạn −2…4) rồi cộng 0,45 hình + 0,3 người + 0,25 tiếng, làm mượt 1 giây. Chỗ chuyển cảnh (một lần đổi hình lớn hơn hẳn trước và sau nó) không tính là chuyển động và pha không vượt qua nó. Không có người trong ±1 giây thì điểm chỉ còn 30 %. Pha dài 2,5–10 giây, không chồng nhau, chỉ lấy đỉnh cao nhất trong ±2 giây. Chọn theo điểm đến khi đủ độ dài, lệch không quá 10 %.

**Kiểm thử:**
- Test mới: Core `HighlightTests` (9: chuyển cảnh, có thời gian trước/sau pha, pha lớn hơn đứng đầu và không chồng nhau, không vượt chuyển cảnh, hình không người bị tính ít, video đều đều không có pha, chọn theo độ dài, giữ pha cắt phần còn lại, đoạn chạy nhanh); Media `HighlightMediaTests` (2: chuyển động đo đúng chỗ trên video giả có khối chạy, Dừng dừng thật). Toàn bộ: Core 478, Media 275, tách lời 8 — đều qua.
- Trên video thật (chỉ đọc, ổ Lexar): "Tư duy chơi bóng" 110 s (cảnh tập + sơ đồ chiến thuật): 6 pha cao nhất đều là cầu thủ có bóng, cao nhất là cú sút vào khung thành; đoạn sơ đồ thấp nhất (kiểm bằng ảnh). "Tập cảm giác bóng" 346 s: xem trong 5,5 s, 31 chỗ chuyển cảnh, có người 344/347 lần nhìn. "Tập thể lực" 163 s: 1,5 s; "Các bài khởi động" 158 s: 2,1 s.
- Bản sao dự án thật "Tập bóng đá" (nguồn thiếu nối tạm sang "Tập cảm giác bóng.mp4"): chọn 15 s → 15,3 s (2 đoạn), 30 s → 32,4 s (5 đoạn), 1 phút → 56,0 s (8 đoạn); hoàn tác trả lại 4 đoạn 346,3 s.
- Cửa sổ thật, **bấm chuột thật**: tab Pha hay hiện đúng tiếng Việt ▸ **Tìm pha hay** → "Chọn 6 trên 40 pha: highlight sẽ dài 0:30" ▸ ▶ của một pha phát từ 01:09.97 ▸ **Dựng highlight** → 5 đoạn, 0:29,5, thông báo "Đã dựng highlight: 6 pha, 0:30" ▸ **Hoàn tác** → 4 đoạn 05:46.302.

**Chưa làm/chưa kiểm chứng:**
- Video trận đấu quay thô dài (máy quay lia theo bóng, khán giả): người bảo trì chưa có video loại này trên máy; chỉ thử trên video tập và video đã dựng sẵn. Máy quay lia liên tục có thể làm cả trận "chuyển động" đều nhau (khi đó tiếng reo và người chạy quyết định).
- Không nhận ra bàn thắng hay quả bóng (Vision không có bộ tìm bóng); chỉ dựa vào chuyển động, người và tiếng.
- Số pha tìm được có thể khác 1 giữa hai lần chạy trên cùng video (37 và 38 trên "Tập bóng đá": thời điểm đọc hình lệch rất nhỏ).
- **Cắt theo nhịp nhạc** sau khi dựng chỉ được kiểm bằng code dùng chung với Âm thanh ▸ Nhịp (đã có test), chưa thử trên dự án có bài nhạc thật.


## Bản 0.22.1 — Pha hay trên trận đấu thật: bàn thắng và đoạn chiếu lại (17/11/2026)

**Yêu cầu:** tạo dự án từ "Full trận FC98 -FC 2K3.mp4" (ổ Lexar, 86 phút, livestream ban đêm, 1920×1080) và kiểm tra tính năng highlight.

**Lỗi tìm ra và đã sửa:**
- **Video dài báo lỗi -11841, không phân tích được:** cuối đoạn (độ dài file làm tròn theo thang thời gian) lệch quá đuôi file ~1/1000 s, AVAssetReader từ chối đọc. Đoạn đọc nay luôn nằm trong độ dài file (test mới với đoạn dài hơn file 0,0017 s).
- **Bàn thắng không chắc vào highlight:** bản 0.22.0 chỉ dựa vào chuyển động, người, tiếng. Đối chiếu với 7 lần đổi tỉ số (đọc bằng mắt trên bảng tỉ số): highlight 3 phút có pha gần 6/7 lần đổi số nhưng cú ghi bàn thật nhiều khi lọt (bàn 0-1 hạng 131, bàn 0-3 hạng 106 trên 614 pha).

**Đã làm:**
- Core `ScoreReader`: đọc tỉ số từ chữ trên hình (Vision, khổ 960 px, 10 s một lần): cặp số "0 1", "2-5", "1:0" (không nhận đồng hồ "11:16"), theo chỗ trên hình đọc được nhiều nhất; bàn thắng = một bên tăng 1 (hoặc 2 khi lỡ một lần đọc) và đọc lại giống nhau lần sau (đọc nhầm một lần không tính). Ở 512 và 768 px Vision không đọc được chữ số trên nền đỏ; ở 960 px đọc đúng (≈90 ms một khung).
- Core `HighlightFinder.replays`: tìm hình chuyển cảnh lặp lại (ảnh nhỏ 16×9 màu của mỗi khung; khung có thay đổi lớn, giống nhau ở ≥ 4 lần, mỗi lần < 2,5 s — góc máy lặp lại nhưng kéo dài thì không tính); hai lần cách 4–40 s là một đoạn chiếu lại.
- `moments`: bàn thắng trước tiên = 18 s ngay trước đoạn chiếu lại gần lúc tỉ số mới được đọc nhất (không có đoạn chiếu lại thì lấy lúc sôi động nhất trong 90 s trước); pha được chiếu lại = 12 s trước đoạn chiếu lại; pha thường không lấy phần chiếu lại. `choose` luôn chọn bàn thắng. Danh sách: nhãn xanh "Bàn thắng 0-1", biểu tượng ↺ cho pha được chiếu lại.
- Hook debug `MACPLAYER_DEV_NEWPROJECT="<video>|<file mới>"`: tạo dự án đúng như Tệp ▸ Mới (không qua hộp lưu).

**Kết quả trên trận thật (chỉ đọc video):**
- 86 phút phân tích trong ≈105–130 s. Đọc tỉ số: đúng **7/7** bàn (0-1, 0-2, 0-3, 0-4, 0-5, 1-5, 2-5), không bàn giả. Đoạn chiếu lại: 22 (7 dài 15,4 s đúng 7 bàn, 15 dài 8,2 s là các pha khác).
- Kiểm bằng ảnh 7 pha bàn thắng: 5 thấy rõ cú dứt điểm rồi thủ môn nhặt bóng/cầu thủ ăn mừng; 2 (0-3, 2-5) quay rất xa, ảnh nhỏ không xác nhận được bằng mắt (thứ tự hình hợp lý).
- Dự án tạo cho người bảo trì: `~/Movies/Full trận FC98 - FC 2K3.macplayer` (nguyên trận, chưa cắt). Trên bản sao: Pha hay 3 phút → 10 pha (7 bàn thắng + 3 pha được chiếu lại), dựng và xuất qua hàng đợi thật → `~/Movies/Highlight FC98 - FC 2K3 (3 phút).mp4`, 1920×1080, 162,0 s, có tiếng.

**Kiểm thử:** test mới `ScoreReaderTests` (3), `ReplayTests` (3), `aSpanEndingAHairAfterTheFileStillReads`. Toàn bộ: Core 484, Media 276, tách lời 8 — đều qua (một lần chạy `FastExportTests` quá 5 s khi app thử đang xuất video cùng lúc; chạy lại 3 lần riêng: đều qua ≈1,5 s).

**Chưa làm/chưa kiểm chứng:**
- Chỉ thử trên một trận, một đài livestream. Bảng tỉ số kiểu khác (chữ số tách rời hai ô, tỉ số dạng "1 : 0" có khoảng trắng lạ) và đài không có đoạn chiếu lại chưa thử.
- Video quay bằng điện thoại không có bảng tỉ số: vẫn dùng cách chấm cũ (chuyển động, người, tiếng), không nhận ra bàn thắng.
- Highlight 3 phút có 7 bàn × 18 s = 126 s; trận nhiều bàn hơn với độ dài ngắn sẽ dài hơn độ dài đã chọn (bàn thắng luôn được giữ).
- Chưa xem lại file xuất bằng mắt từ đầu đến cuối (chỉ xem ảnh 3 giây một khung).


## Bản 0.22.2 — Các mốc của trận trong highlight bóng đá (17/11/2026)

**Yêu cầu:** highlight phải có: trọng tài dẫn hai đội ra sân, đọc đội hình, còi bắt đầu và kết thúc, thẻ vàng/đỏ, tình huống dẫn tới bàn thắng, check VAR. Người bảo trì nhắc: trận FC98–FC 2K3 chỉ là ví dụ, **không được cố định mốc thời gian** — mọi mốc phải tìm từ chính video.

**Đã làm (mọi mốc lấy từ tín hiệu của video, không có thời điểm nào viết sẵn):**
- **Bắt đầu hiệp / Hết hiệp / Hết trận:** Core `ClockReader` đọc đồng hồ trận "mm:ss" trên hình (cùng lần đọc chữ 10 s một lần với tỉ số): đồng hồ chạy theo video (±2 s) là đang đá; đứng yên (00:00 trước trận, nghỉ giữa hiệp, sau trận) là không. Bắt đầu hiệp tính ngược từ giây đồng hồ đã đếm.
- **Ra sân / Xếp hàng, đội hình:** lượt xem thứ hai, ngắn: 10 phút trước còi đầu (lấy từ đồng hồ), 2 s một hình 960 px, Vision tìm người trên 6 phần chồng nhau của hình rồi đếm người đứng cùng một hàng (`peopleInARow`). ≥ 7 người cùng hàng = hai đội xếp hàng. Đợt xếp hàng đầu = ra sân, đợt sau = xếp hàng trên sân (chào nhau, đọc đội hình). Đo trên trận ví dụ: cả hình một lần Vision thấy 0 người lúc hai đội xếp hàng ban đêm; chia 6 phần thấy 9–10 người cùng hàng; lúc đang đá chỉ 3–4.
- **Thẻ vàng / Thẻ đỏ / Kiểm tra VAR:** `WordSpotter` tìm chữ trên hình (THẺ VÀNG, YELLOW CARD, THẺ ĐỎ, RED CARD, VAR, CHECK VAR, bỏ dấu khi so); pha = 15 s trước chữ hiện ra đến 5 s sau.
- **Tình huống dẫn tới bàn thắng:** pha bàn thắng dài 25 s (trước 18 s), kết thúc 1,2 s trước hình chuyển cảnh của đoạn chiếu lại (hình này mờ dần vào sớm hơn lúc nhận ra ~0,5 s: bản trước còn dính khung đầu của nó).
- Mọi mốc luôn được chọn; danh sách có nhãn màu (Ra sân, Xếp hàng/đội hình, Bắt đầu hiệp, Bàn thắng 0-1, Thẻ vàng, Thẻ đỏ, Kiểm tra VAR, Hết hiệp, Hết trận, Chào sau trận).

**Góp ý của người bảo trì sau khi xem bản xuất, đã sửa:**
- *Âm thanh đầu video nhiễu, rè:* đo bằng ffmpeg: tiếng **trong video gốc** đã vỡ ở đoạn ra sân (loa sân): 25 s có ~10 000 mẫu sát mức tối đa, đỉnh 0 dB, trung bình −12 dB (lúc đá: đỉnh −8 dB, trung bình −16 dB). Bản xuất không thêm mẫu chạm đỉnh nhưng đỉnh vẫn sát 0 dB. Sửa: khi dựng highlight, mỗi pha được đặt âm lượng để mức trung bình về −20 dB (`HighlightFinder.evenGain`, −9…+4 dB) và nhỏ dần/to dần 0,12 s ở mỗi chỗ nối. Tiếng vỡ sẵn trong gốc không khôi phục được.
- *Đoạn chiếu lại ngắn, người xem chưa kịp theo dõi:* bàn thắng nay = 25 s trước đoạn chiếu lại **+ cả đoạn chiếu lại của đài** (≈15 s, gồm hình chuyển cảnh mở/đóng); pha khác được chiếu lại = 12 s + đoạn chiếu lại (≈8 s). Ô **Kèm đoạn chiếu lại sau bàn thắng** (bật sẵn) để tắt.

- *Phần giới thiệu đội hình bị cắt, mới đọc hết một đội:* đoạn "Xếp hàng, đội hình" nay kéo từ lúc hai đội xếp hàng trên sân đến khi **loa sân lặng hẳn** (≥ 6 s, nhỏ hơn mức lúc giới thiệu ≥ 20 dB; người đọc ngừng 2–4 s giữa các tên/hai đội nên ngưỡng 2 s trước đó cắt sau đội thứ nhất), không thấy lúc lặng thì 60 s sau lần cuối thấy hàng, luôn trước còi bắt đầu. Trận ví dụ: 11:57–13:18 (81 s; bản trước 37 s).
- *Hết hiệp 1 bị cắt khi bình luận viên chưa nói xong; sau đó người bảo trì đổi ý: hết hiệp 1 chỉ cần còi và câu thông báo hết hiệp, không cần đọc tỉ số:* đoạn hết hiệp kết thúc ở chỗ ngừng nói đầu tiên (≥ 0,4 s, nhỏ hơn tiếng nói quanh còi ≥ 20 dB) sau khi đồng hồ dừng, tối đa 15 s (trận ví dụ: 44:50–45:04; bình luận viên nói 44:57–45:03, ngừng, rồi đọc tỉ số đến 45:13).
- *Hết trận quá dài, chỉ cần đến khi bình luận viên đọc xong kết quả:* đoạn hết trận kéo đến lúc ngừng nói ≥ 2 s (tối đa 40 s); bỏ hẳn mốc "Chào sau trận" và lượt tìm hai đội xếp hàng sau trận. Trận ví dụ: 85:20–85:52.
- *Chưa bắt được thay người:* thêm mốc **Thay người** khi đài hiện chữ THAY NGƯỜI / SUBSTITUTION (8 s trước đến 10 s sau). Quét chữ cả trận ví dụ 10 s một khung: đài này **không hiện chữ thay người** (chỉ tên giải, tỉ số, đồng hồ, quảng cáo) — thay người chỉ có trong lời bình luận, cần nhận dạng tiếng Việt (máy này đang chặn), nên trận này chưa có mốc thay người.
- *Trận đặc biệt (video không có đoạn chào sân, bắt đầu từ còi, hoặc live sập):* không phải lỗi, highlight vẫn tạo bình thường. Còi bắt đầu chỉ ghi khi thấy đồng hồ đứng trước đó hoặc mới chạy từ một mốc tròn (00:00, 30:00, 35:00, 45:00…; ở lần nhìn đầu tiên của video chỉ khi chạy chưa quá 15 s từ mốc 5 phút ≥ 20:00) — video vào giữa trận không bị gán còi bắt đầu; ra sân/đội hình chỉ tìm trước một còi bắt đầu có trong video; hết trận/chào sau trận chỉ khi video còn tiếp ≥ 20 s sau khi đồng hồ dừng (live sập giữa trận thì không có); tỉ số đầu video (2-1) là mốc ban đầu, không phải bàn thắng. Thử trên trận thật cắt còn 13:40→hết (không ra sân/đội hình, đủ 7 bàn, hết trận) và 33:20→66:40 (2 bàn, hết hiệp, không còi bắt đầu/hết trận giả). Hiệp 2 của giải này đếm từ 30:00 (bảng hiện "HIỆP 1" lúc nghỉ): nhận đúng còi hiệp 2 (≈52:03).

**Kết quả trên trận ví dụ (chỉ đọc video):** 2 hiệp đọc từ đồng hồ (bắt đầu 13:44 — bằng mắt 13:41 — đến 45:00; 52:10 đến 85:30); ra sân 11:31–11:56 (bằng mắt 11:32–11:56); xếp hàng trên sân 11:57–12:29; 7 bàn; không có thẻ/VAR (giải phong trào, không có chữ báo trên hình). Lượt xem thêm tốn ≈11 s. Highlight "3 phút" (bản cuối) thành 13 đoạn, 472,3 s (gồm đoạn chiếu lại sau 7 bàn): các mốc luôn được giữ nên dài hơn độ dài đã chọn. File: `~/Movies/Highlight FC98 - FC 2K3.mp4`.

**Kiểm thử:** test mới `MatchReadingTests` (4), `EvenSoundTests`, `PartialMatchTests` (2: vào giữa trận và live sập; bắt đầu đúng còi), `SecondHalfClockTests`. Toàn bộ: Core 494, Media 276, tách lời 8 — đều qua.

**Chưa làm / chưa kiểm chứng:**
- **Đọc đội hình bằng giọng nói:** cần nhận dạng tiếng Việt, máy này đang chặn (Đọc chính tả). App chỉ lấy lúc hai đội xếp hàng trên sân (thường là lúc đọc đội hình); bảng đội hình hiện bằng chữ trên hình chưa được nhận riêng.
- **Thẻ phạt, VAR không có chữ trên hình** (trọng tài rút thẻ bằng tay): không nhận ra. Trận ví dụ không có thẻ/VAR nên phần đọc chữ chỉ được kiểm bằng test.
- Video không có bảng tỉ số/đồng hồ (quay điện thoại): không có các mốc hiệp, ra sân (vì ra sân tìm theo giờ bắt đầu hiệp); vẫn có pha hay theo chuyển động, người, tiếng.
- Chỉ thử trên một trận, một kiểu bảng tỉ số.


## Bản 0.22.3 — Highlight tự động, danh sách gọn (17/11/2026)

**Yêu cầu:** đổi chữ "Pha hay" thành "Highlight" (tiếng Anh và tiếng Việt); độ dài highlight và số giây giữ trước/sau tự tính theo diễn biến trận, người dùng không phải chỉnh; "Tìm pha hay" cho hơn 300 tình huống, phải tick lại từng đoạn — cần chính xác, thân thiện hơn.

**Đã làm:**
- Tab **Cơ bản ▸ Highlight**, thẻ **Highlight**, nút **Tìm highlight** / **Tìm lại** (cả hai ngôn ngữ). Bỏ ô **Độ dài highlight** và hai thanh trượt **Giây giữ trước/sau pha bóng**.
- Core `HighlightFinder.autoChoose`: mọi mốc của trận luôn chọn; tổng highlight ≈ 10 % thời lượng đã xem (30 s–8 phút); phần còn lại cho pha hay (ít nhất 2 % video, tối đa 1 phút, khi các mốc đã gần đầy): trước hết pha đài chiếu lại, rồi pha có điểm ≥ ½ pha hay nhất, tốt nhất trước. `shortlist`: chỉ các đoạn đã chọn + tối đa 15 gợi ý, theo thời gian.
- Phần trước/sau mỗi pha: lùi về lúc pha bóng còn đang dâng (> 15 % đỉnh, ≤ 6 s) thêm 2 s, kéo tới lúc lắng (> 20 % đỉnh, ≤ 4 s) thêm 1 s; ít nhất 1,5 s quanh đỉnh; pha 2,5–12 s.
- Danh sách: dòng tóm tắt "%d đoạn: highlight sẽ dài …", Dựng highlight / Chỉ đánh dấu, các đoạn đã chọn, mục **Gợi ý thêm (n)** gập sẵn; bỏ thanh điểm và nút Chọn hết/Bỏ chọn hết.

**Kiểm thử:**
- Test mới `AutoChooseTests` (2: trận giữ mốc → pha chiếu lại → pha rõ, tổng ≈ 8 phút, trận đầy mốc vẫn có ≈ 1 phút pha; video tập ngắn ≈ 1/10). Toàn bộ: Core 496, Media 276, tách lời 8 — đều qua.
- Trận ví dụ (dự án mới tạo trong thư mục tạm; dự án ở ~/Movies người bảo trì đã chuyển vào Thùng rác lúc 13:11, không khôi phục): danh sách 31 dòng (16 chọn + 15 gợi ý; trước: 500+), 16 đoạn, 8:58; dựng → 16 đoạn 537,5 s, hoàn tác về nguyên trận. Dự án tập "Tập bóng đá" (bản sao): 20 dòng, 5 pha, 36,5 s.
- Cửa sổ thật, **bấm chuột thật**: tab hiện "Highlight", không còn ô độ dài/thanh trượt ▸ **Tìm highlight** → "Đã chọn xong highlight: 16 đoạn, 8:58", danh sách có nhãn Ra sân, Xếp hàng/đội hình, Bắt đầu hiệp, ↺, Bàn thắng 0-1…2-5, Hết hiệp, Hết trận, "Gợi ý thêm (15)".



## Bản 0.22.4 — Làm nốt phần chưa kiểm chứng của 0.22.3 (17/11/2026)

**Kiểm bằng chuột thật** trên cửa sổ thử (bản sao dự án "Tập bóng đá"; kết quả đọc từ cây giao diện và từ nội dung file dự án sau mỗi bước, vì ảnh chụp một cửa sổ đang bị cửa sổ khác che không cập nhật):
- **Dựng highlight** → thông báo "Đã dựng highlight: 5 pha, 0:37", file dự án 4 đoạn 346,3 s → **5 đoạn 36,5 s**; **Hoàn tác** → 4 đoạn 346,3 s.
- **Gợi ý thêm** → 15 dòng gợi ý hiện ra (nút ▶ từ 5 lên 20), chưa tick; tick một gợi ý → tóm tắt "6 đoạn: highlight sẽ dài 0:47"; Dựng highlight → **6 đoạn 47,3 s** (gợi ý vào đúng highlight); Hoàn tác → 4 đoạn.

**Lỗi tìm ra và đã sửa:** bấm vào chữ "Gợi ý thêm (15)" không mở danh sách — trên macOS chỉ mũi tên nhỏ của DisclosureGroup nhận bấm. Nay chữ là một nút mở/đóng: bấm chữ → 20 dòng, bấm lần nữa → 5 dòng (kiểm bằng chuột thật).

**Ghi chú khi kiểm:** cây giao diện vẫn báo vị trí của phần tử đã bị khung cuộn che; hai lần bấm theo vị trí đó rơi xuống thước thời gian bên dưới (chỉ dời đầu phát, file không đổi). Công cụ bấm nay chỉ bấm khi điểm nằm trong vùng nhìn thấy của bảng.


## Bản 0.22.5 — Đá phạt nguy hiểm và tên từng đoạn (17/11/2026)

**Yêu cầu:** highlight không bắt được tình huống đá phạt cố định, nhất là đá phạt nguy hiểm; khi dựng, các đoạn vẫn mang tên file gốc — cần tên riêng theo tình huống.

**Đã làm:**
- Core `HighlightFinder.setPieceKicks`: hình gần đứng yên (< 60 % mức thay đổi thường của đoạn) ít nhất 6 s, có người trong hình, rồi trong 4 s có một giây thay đổi ≥ 1,8 lần mức thường = cú đá. Chỉ trong lúc đang đá (theo đồng hồ trận), bỏ cú giao bóng lại trong 90 s sau một bàn thắng. Pha = 6 s trước cú đá đến 9 s sau.
- Pha nguy hiểm: Media `HighlightAnalyzer.crowds` nhìn kỹ 3 s và 1,5 s trước mỗi cú đá (960 px, Vision trên 6 phần của hình) đếm người; ≥ 7 người = nguy hiểm (luôn chọn, `MatchEventKind.setPiece`, tối đa 6, đông người trước); ít hơn = gợi ý (nhãn "Đá phạt" cam). Đo trên trận ví dụ: hai pha phát bóng lên 3 và 5 người; đá phạt trước khung thành/hàng rào/phạt góc 7–11 người. Bản đầu (chọn theo độ sôi động sau cú đá) chọn nhầm hai pha phát bóng lên (máy quay lia theo bóng dài) — đã bỏ.
- Bàn thắng không có đoạn chiếu lại: lấy lúc sôi động **sau cùng** trong số các lúc ≥ 90 % mức cao nhất trong 90 s trước khi bảng đổi số (bàn thắng kết thúc pha bóng; trước đây lấy lúc đầu tiên, có thể là một pha đá phạt trước đó).
- Tên đoạn: `TimelineCuts.keepHighlights(names:)` tách các tình huống liền nhau thành đoạn riêng và đặt tên; app đặt tên theo loại, đánh số theo thời gian: Ra sân, Đội hình hai đội, Bắt đầu hiệp n, Bàn thắng a-b, Đá phạt n, Thẻ vàng/đỏ n, Kiểm tra VAR n, Thay người n, Hết hiệp n, Hết trận, Pha nguy hiểm n (đài chiếu lại), Pha bóng hay n. Điểm đánh dấu (Chỉ đánh dấu) dùng cùng tên.

**Kiểm thử:**
- Test mới `SetPieceTests` (3: dừng 9 s rồi đá là pha cố định, dừng 3 s thì không; pha nguy hiểm được giữ, giao bóng lại sau bàn thắng không tính, pha yếu chỉ là gợi ý; tình huống liền nhau thành hai đoạn có tên), `SetPieceCrowdTests` (đông người = nguy hiểm, phát bóng lên = gợi ý). Toàn bộ: Core 500, Media 276, tách lời 8 — đều qua.
- **Trên dự án thật của người bảo trì** "highlight FC98 - FC 2K3.macplayer" (ổ Lexar, không sandbox; MacPlayer của người bảo trì đã đóng dự án; sao lưu ngay trước khi chạy, kiểm SHA-256, trả lại sau khi kiểm — mã băm khớp, 1 đoạn nguyên trận): Tìm highlight → 34 dòng, chọn 19; Dựng highlight → 19 đoạn 582,5 s, tên trong file: Ra sân, Đội hình hai đội, Bắt đầu hiệp 1, Pha nguy hiểm 1–3, Bàn thắng 0-1, **Đá phạt 1** (28:20), Bàn thắng 0-2, Bàn thắng 0-3, **Đá phạt 2** (43:40), Hết hiệp 1, Bắt đầu hiệp 2, **Đá phạt 3** (56:53), Bàn thắng 0-4…2-5, Hết trận. Xem ảnh: cả ba là đá phạt có hàng rào/cầu thủ chờ trước khung thành; Đá phạt 1 dẫn tới bàn 0-2.

**Ghi chú:** các bản sao thử trước đó (chạy không sandbox) hiện trong danh sách dự án của app và người bảo trì đã xoá; từ nay chỉ chạy trên dự án thật khi được yêu cầu (sao lưu trước), còn thử nghiệm thì dùng `--sandbox`.

**Chưa làm/chưa kiểm chứng:** không phân biệt đá phạt / phạt góc / phạt đền (cùng nhãn "Đá phạt"); một số pha đá phạt có hàng rào trùng với đoạn đài đã chiếu lại nên mang tên "Pha nguy hiểm"; chỉ thử trên một trận.


## Bản 0.22.6 — Pha đá phạt được đài chiếu lại mang tên "Đá phạt" (17/11/2026)

**Vấn đề:** ở 0.22.5, pha đá phạt nào đài đã chiếu lại thì đã nằm trong đoạn "Pha nguy hiểm" (12 s trước đoạn chiếu lại + đoạn chiếu lại), nên không được nhận là đá phạt: tên là "Pha nguy hiểm n" và có thể thiếu phần chuẩn bị (đặt bóng, xếp hàng rào).

**Đã làm:** khi có cú đá phạt trong khoảng từ 2 s trước đầu đoạn "12 s trước đoạn chiếu lại" đến ngay trước đoạn chiếu lại, đoạn đó là pha đá phạt (`setPiece`, `event` `.setPiece`, luôn chọn), tên "Đá phạt n", bắt đầu từ lúc sớm hơn trong hai mốc (12 s trước đoạn chiếu lại hoặc 6 s trước cú đá), không lấn sang đoạn trước; đoạn chiếu lại vẫn ở sau. Cú đá đó không tạo thêm đoạn đá phạt thứ hai.

**Kiểm thử:** test mới `ReplayedSetPieceTests` (pha đá phạt được chiếu lại mang nhãn đá phạt, có phần chuẩn bị; pha chiếu lại không có đá phạt vẫn là pha nguy hiểm; không lặp). Toàn bộ: Core 501, Media 276, tách lời 8 — đều qua. **Trên dự án thật** "highlight FC98 - FC 2K3" (sao lưu ngay trước, trả lại sau, mã băm khớp): 22 đoạn, 668,3 s (11:08); "Đá phạt 1" 19:58 (trước là Pha nguy hiểm 3), "Đá phạt 5" 57:14, "Đá phạt 6" 64:20. Xem ảnh: Đá phạt 5 là đá phạt trước khung thành có trọng tài rồi đoạn chiếu lại; Đá phạt 6 là phạt góc; Đá phạt 1 ảnh nhỏ, chưa xác nhận được bằng mắt.

**Lưu ý:** vì pha đá phạt được chiếu lại nay luôn được chọn, highlight trận ví dụ dài hơn (11:08, trước 9:42).


## Bản 0.22.7 — Bắt đá phạt nguy hiểm quay từ xa (17/11/2026)

**Người bảo trì báo:** pha đá phạt nguy hiểm ở khoảng 15:56.924 của video gốc không được bắt.

**Tái hiện (đo trên video, chỉ đọc):** 15:42–15:56 cầu thủ vàng xếp hàng rào trước khung thành bên trái, trọng tài đứng gần, cầu thủ đỏ đá phạt ≈15:57. Mức thay đổi hình mỗi giây (mức thường của trận ≈0,031): lúc chuẩn bị 0,008–0,031, nhưng cầu thủ đi lại và máy quay nhích làm vài giây vượt ngưỡng "đứng yên" (0,6 × thường), nên không có 6 giây yên liền nhau; cú đá quay từ xa chỉ đẩy lên 0,050 (1,6 × thường, dưới ngưỡng 1,8). Cả hai điều kiện cũ đều trượt.

**Đã sửa (`setPieceKicks`):** yên = trung bình 8 s dưới 0,6 × mức thường, cho phép tối đa 2 giây nhích lên (> 0,9 × thường), có người trong hình; cú đá = trung bình 3 s sau ≥ 2,5 × lúc yên và ≥ mức thường, giây đầu > 1,5 × lúc yên. Pha bắt đầu 8 s trước cú đá (thấy lúc xếp hàng rào). Số người đếm được gắn với chính thời điểm cú đá.

**Kiểm thử:** test mới `FarFreeKickTests` dùng đúng số đo 937–962 s của trận. Toàn bộ: Core 502, Media 276, tách lời 8 — đều qua. Cả trận: 30 cú đá dò được; đông người (≥ 7) trong lúc đang đá: 15:60 (9 người), 25:63 (12), 28:26 (11), 33:16 (10), 56:58 (11), 57:20 (10), 64:26 (5, phạt góc được chiếu lại); 51:46 (8, trước còi hiệp 2) và 62:38 (8, giao bóng lại sau bàn 0-4) bị loại đúng. Xem ảnh 15:52, 25:55, 33:08: đều là đá phạt (hàng rào/cầu thủ chờ trước khung thành, đá phạt bên cánh). **Trên dự án thật** "highlight FC98 - FC 2K3" (sao lưu ngay trước, trả lại sau, mã băm khớp — bản người bảo trì vừa sửa): 23 đoạn, 11:24; Đá phạt 1 = 15:52 (pha được báo), thêm Đá phạt 2 (25:55) và Đá phạt 4 (33:08).

**Chưa kiểm chứng:** pha "Đá phạt 1" 19:58 của 0.22.6 (chưa xác nhận bằng mắt) nay là "Pha nguy hiểm 3" vì cú đá dò được ở 19:26 nằm ngoài đoạn chiếu lại đó; chưa xem lại bằng mắt.


## Bản 0.22.8 — Phạt góc 19:58 và mọi pha đá phạt đông người (18/11/2026)

**Người bảo trì báo:** pha 19:58 là phạt góc, cần mang tên "Đá phạt" (0.22.7 gọi là "Pha nguy hiểm 3").

**Tái hiện:** 19:43–19:53 đài chiếu lại pha trước; 19:54–20:03 máy quay đứng yên ở góc khung thành, hai đội chờ phạt góc (thay đổi hình 0,007–0,012); phạt góc ≈ 20:03–20:04. Bộ dò thỏa mọi điều kiện chuyển động nhưng bị loại vì điều kiện "có người trong hình": Vision nhìn cả hình ban đêm, máy quay xa, không thấy ai trong suốt lúc chuẩn bị.

**Đã sửa:**
- `setPieceKicks` không đòi "có người" nữa (cảnh không phải trận đấu đã bị loại theo đồng hồ trận; pha nguy hiểm do bước đếm người kỹ — 6 phần của hình — quyết định). Cả trận: 38 cú đá dò được (trước 30); các cú đá mới ngoài giờ thi đấu bị loại theo đồng hồ.
- Bỏ giới hạn 6 pha đá phạt nguy hiểm: lần chạy đầu sau khi sửa, thêm pha phạt góc làm số pha đông người vượt 6 và **mất pha đá phạt 15:52** của 0.22.7. Nay mọi pha đông người (≥ 7) trong lúc đang đá đều được giữ.

**Kiểm thử:** test mới `FarCornerTests` (số đo thật 1186–1215 s, không ai được thấy trong cả hình) và `ManySetPiecesTests` (9 pha đông người đều được giữ). Toàn bộ: Core 504, Media 276, tách lời 8 — đều qua. **Trên dự án thật** "highlight FC98 - FC 2K3" (người bảo trì đóng dự án trước; sao lưu ngay trước, trả lại sau, mã băm khớp): 28 đoạn, 13:03; Đá phạt 1 = 15:52 (giữ), Đá phạt 3 = 19:56–20:26 (phạt góc 19:58 + đoạn chiếu lại); 12 pha đá phạt. Xem ảnh các pha mới: 17:23 phạt góc, 26:25 đá phạt trước khung thành; 31:55 và 35:09 giống đá phạt (cầu thủ chờ quanh bóng rồi cú đá), ảnh nhỏ, chưa chắc chắn.

**Lưu ý:** highlight trận ví dụ dài hơn (13:03) vì mọi pha đá phạt đông người đều được giữ; có thể bỏ tick trong danh sách trước khi dựng.


## Bản 0.22.9 — Highlight cho trận truyền hình chuyên nghiệp (18/11/2026)

**Người bảo trì báo:** với "Dự án video VSC" (full trận Cúp 7 người Quốc gia Hyundai Thành Công Cup 2026, 28 SPORT – Đại Nam FC, 113 phút, 1080p60, truyền hình nhiều máy quay) highlight bắt chưa chuẩn.

**Tái hiện (đáp án tự đọc từ bảng tỉ số 10 s một lần, chỉ đọc video):** 4 bàn — bảng đổi 0-1 lúc 37:50, 0-2 lúc 44:30, 1-2 lúc 81:20, 1-3 lúc 83:40; hiệp 1 từ 23:30 (đồng hồ 00:00) đến ≈59:10 (35:00), hiệp 2 từ ≈70:10 (35:00) đến ≈107:00. Highlight cũ (25 đoạn): **0 bàn thắng**; "Hết hiệp 1" lúc 25:15, "Hết hiệp 2" lúc 59:10; 9 "Đá phạt" mà xem ảnh là đá biên, thay người, ăn mừng sau bàn 0-2.

**Nguyên nhân và cách sửa:**
1. *Tỉ số không đọc được:* mỗi chữ số nằm riêng trong một ô trắng; Vision đọc tên đội và đồng hồ nhưng bỏ qua chữ số đứng một mình (thử nhiều cấu hình, ảnh phóng to, đều không ổn định). Core `BoardWatch`: tìm cặp tên đội cùng hàng, lặp lại ở một chỗ; vị trí chốt theo trung vị của 5 lần thấy đầu; chụp khoảng giữa hai tên 48×12; tìm cột có nét (độ sáng đổi mạnh theo chiều dọc), lấy hai cụm cột rộng nhất làm hai chữ số; mỗi bên: hình (sáng/tối theo điểm giữa mức 10 % và 90 %) đổi hẳn, giữ ở 3/4 lần đọc sau và hình cũ không quay lại 2 lần liền trong 5 phút = bàn thắng của đội bên đó. Tỉ số tính từ 0-0 khi video có còi bắt đầu; nếu không, nhãn là tên đội ghi bàn. Chỉ dùng khi đọc chữ không ra bàn nào. Các bước sai trên đường: khoảng giữa khung chữ tên đội gồm cả nền xanh có hiệu ứng (13 "bàn"); chia đôi theo khoảng trống rộng nhất rơi vào lòng chữ 0 (đội ghi bàn bị đảo); chia sáng/tối theo trung vị làm chữ 1 mảnh "đổi" giữa các lần đọc — đã sửa từng điểm. Kết quả: VSC 4/4 bàn đúng đội đúng lúc (37:50, 44:30, 81:30, 83:50); FC98 7/7 bàn khớp phần đọc chữ.
2. *Hiệp bị cắt đôi:* bảng bị che/đọc nhầm vài lần làm đồng hồ "dừng". `ClockReader.periods` nay nối các đoạn mà đồng hồ chạy tiếp đúng bằng thời gian đã trôi (±10 s). Số đọc thật: 2 hiệp 23:30–59:20 và 70:15–107:10.
3. *Định vị bàn thắng:* đài chuyên nghiệp: bóng vào lưới → cận cảnh ăn mừng → logo "VSC-S6" mở đoạn chiếu lại → chữ "GOAL" kèm âm thanh rất to khi tỉ số đổi (5–40 s sau bàn thắng). Chỉ đoạn chiếu lại có đủ cặp mở/đóng mới dùng để định vị bàn thắng; nếu không, `HighlightFinder.loudestCall`: 2 s to nhất trong 2 phút trước khi tỉ số đổi, to hơn mức giữa ≥ 12 dB (bàn VSC: −3 đến −5 dB so với −20…−30 dB); pha = 40 s trước đến 8 s sau (có cú ghi bàn trực tiếp, ăn mừng, đoạn chiếu lại, chữ GOAL).
4. *Đá phạt nhầm:* video nhiều máy quay (≥ 30 lần chuyển cảnh/giờ; VSC 102 lần/113 phút, FC98 10 lần/86 phút) cắt sang cận cảnh mỗi khi trận dừng và máy toàn cảnh luôn thấy đủ cầu thủ — đếm người không phân biệt được (đo: đá biên/thay người VSC 7–10 người, tụ 5–7 trong ¼ khung, như đá phạt thật FC98). Ở loại video này pha cố định chỉ là "nguy hiểm" khi đài chiếu lại nó (≤ 45 s sau cú đá) hoặc có bàn thắng ≤ 90 s sau; còn lại là gợi ý. Video một máy quay giữ cách đếm người.

**Kiểm thử:**
- Test mới: `ClockPiecesTests`, `GoalCallTests`, `ManyCamerasTests`, cùng các bước đo thật `RealClockLooksTests` (`MACPLAYER_CLOCK_LOOKS`) và `boardGoalsInARealVideo` (`MACPLAYER_BOARD_FILE`, `MACPLAYER_BOARD_SPAN`, `MACPLAYER_BOARD_TRACE`).
- **Trên dự án thật "Dự án video VSC"** (MacPlayer của người bảo trì không chạy; sao lưu, tạm đưa timeline về nguyên trận như lúc bắt đầu, Tìm highlight + Dựng highlight, đọc file, trả lại bản sao lưu — mã băm khớp, vẫn là highlight 25 đoạn của người bảo trì): 17 đoạn, 7:52 — Ra sân, Đội hình hai đội, Bắt đầu hiệp 1 (23:30), Pha nguy hiểm 1–2, **Bàn thắng 0-1** (36:54–37:42), Pha nguy hiểm 3, Pha bóng hay 1–2, **Bàn thắng 0-2** (43:44–44:32), Hết hiệp 1 (59:10), Bắt đầu hiệp 2 (70:15), Pha nguy hiểm 4, **Bàn thắng 1-2** (80:40–81:28), **Bàn thắng 1-3** (82:58–83:46), Pha nguy hiểm 5, Hết trận (107:10). Không còn "Đá phạt" nhầm.
- Trận FC98 chạy lại: giữ nguyên (7 bàn, 2 hiệp, các pha đá phạt 15:52, 19:56…).
- Toàn bộ: Core 508, Media 277, tách lời 8 — đều qua.

**Chưa kiểm chứng:** chưa xem bằng mắt từng giây của 4 pha bàn thắng VSC (đã xem ảnh 2,5 s một khung: có cú ghi bàn/đoạn chiếu lại); các "Pha nguy hiểm" VSC (12 s trước logo VSC-S6) chưa xem lại; đá phạt nguy hiểm thật ở trận VSC (nếu có, mà đài không chiếu lại) sẽ chỉ nằm trong gợi ý.


## Bản 0.22.10 — Kiểm chứng nốt trận VSC (18/11/2026)

**Xem lại từng giây (ảnh 1 s/khung) 4 bàn thắng VSC của bản 0.22.9:**
- 0-2 (43:44–44:32), 1-2 (80:40–81:28), 1-3 (82:58–83:46): đúng — có pha tấn công, cú ghi bàn, ăn mừng, đoạn chiếu lại, chữ GOAL.
- **0-1 (36:54–37:42): thiếu cú ghi bàn trực tiếp.** Bóng vào lưới ≈36:45, logo chiếu lại 36:52, nhưng chữ GOAL và tiếng hô to nhất đến ≈37:34 (đài cập nhật tỉ số muộn ≈50 s), nên clip "40 s trước tiếng hô" chỉ có bàn thắng qua đoạn chiếu lại. Sửa: bàn thắng định vị bằng tiếng hô lấy **60 s trước** đến 8 s sau.

**Các "Pha nguy hiểm" VSC:** đều là pha đài chiếu lại thật (dứt điểm, phạm lỗi), nhưng logo "VSC-S6" nhỏ ở góc nên thường chỉ thấy một lần; khi lần thấy đó là logo *đóng* đoạn chiếu lại, clip "12 s trước logo" bắt đầu từ lúc đang chiếu lại/ăn mừng, thiếu pha trực tiếp (ví dụ 40:36, pha thật ≈40:30). Sửa: logo chỉ thấy một lần → pha = **24 s trước đến 4 s sau** logo. Logo thấy đủ cặp mở/đóng giữ như cũ.

**Đá phạt nguy hiểm VSC mà đài không chiếu lại:** xem ảnh mọi cú đá sau lúc dừng trong 2 hiệp: gần hết là đá biên, thay người, quảng cáo giữa giờ, cận cảnh. Một pha phạt góc thật lúc 97:24 không được chiếu lại → chỉ nằm trong **Gợi ý thêm**. Đo thử tiếng khán giả sau cú đá: phạt góc này tăng 0,7 dB, đá biên tăng tới 18 dB — âm thanh không phân biệt được, nên giữ quy tắc "đài chiếu lại hoặc dẫn tới bàn thắng".

**Kiểm thử:**
- Test mới `GoalCallTests.aLateCallStillHasTheLiveGoal` (GOAL 50 s sau bàn thắng) và `aLoneReplayGraphicKeepsTheLiveActionBeforeIt`; `dangerousSetPiecesAreKeptAndTheRestartAfterAGoalIsNot` dời pha đá phạt giả lập sớm hơn (ở 68 s nó nằm trong clip bàn thắng 60 s trước tiếng hô).
- **Trên dự án thật "Dự án video VSC"** (MacPlayer không chạy; sao lưu ngay trước, tạm đưa timeline về nguyên trận, Tìm + Dựng highlight, đọc file, trả lại bản sao lưu — mã băm khớp e90901ef…): 12 đoạn, 8:43 — Ra sân 20:22, Đội hình hai đội 20:54–21:59, Bắt đầu hiệp 1 23:30, Pha nguy hiểm 1 24:44–25:12, Pha nguy hiểm 2 30:20–30:48, **Bàn thắng 0-1 36:34–37:42** (nay có cú ghi bàn 36:45), Bàn thắng 0-2 43:24–44:32, Hết hiệp 1 59:10, Bắt đầu hiệp 2 70:15, Bàn thắng 1-2 80:20–81:28, Bàn thắng 1-3 82:38–83:46, Hết trận 107:10–108:00. Xem ảnh 2 s/khung hai pha nguy hiểm: có pha tấn công/dứt điểm trực tiếp rồi logo VSC-S6 và đoạn chiếu lại.
- Trận FC98 chạy lại: 7 bàn (khung không đổi — đều có cặp chiếu lại), 2 hiệp, đá phạt 15:52 và phạt góc 19:56 vẫn có.
- Toàn bộ: Core 510, Media 277, tách lời 8 — đều qua.

**Chưa kiểm chứng:** chưa nghe/xem bằng app bản dựng cuối (chỉ đọc file dự án và xem ảnh từ video gốc); các pha chiếu lại khác ngoài 2 pha được chọn chỉ nằm trong gợi ý, chưa xem lại hết.


## Bản 0.22.11 — Xem và đo bản highlight dựng xong; xem các pha chiếu lại trong gợi ý (18/11/2026)

**Cách làm:** trên dự án thật "Dự án video VSC" (MacPlayer không chạy; sao lưu ngay trước, tạm đưa timeline về nguyên trận), bản debug của app tự Tìm highlight → Dựng highlight → **Xuất** (chính bộ dựng hình/tiếng của app, như khi xem) ra `vsc-highlight.mp4` trong thư mục tạm, rồi thoát; trả lại bản sao lưu — mã băm khớp e90901ef… (cả 3 lần chạy). File xuất: 1920×1080 60 fps H.264, AAC stereo 44,1 kHz, 8:42,6; giải mã trọn file không lỗi.

**Lỗi tìm ra — vỡ tiếng:** đo tiếng bản xuất: 466 mẫu chạm 0 dBFS, đoạn "Pha nguy hiểm 2" lên +6 dB (đo trên bản trộn mono). Nguyên nhân: cân bằng âm lượng nâng đoạn nhỏ tới +4 dB mà không xét tiếng to nhất của đoạn (gốc có tiếng nổ −0,5 dBFS). **Sửa:** khi đọc tiếng, app ghi thêm đỉnh của từng 0,05 s; mức tăng không bao giờ làm đỉnh của đoạn vượt −2 dBFS. Lần sửa đầu đo đỉnh trên bản trộn mono của AVFoundation, nhưng bản trộn đó là (L+R)/√2, đọc tiếng giống nhau ở hai kênh cao hơn đỉnh thật 3 dB (đo bằng âm thử và trên đoạn bàn 0-1: mono +3,3 dB, hai kênh +0,3 dB, ffmpeg 0,0 dB), nên các đoạn bị hạ oan. Bản cuối đọc hai kênh: độ to tính như cũ (khớp bản mono cũ trong 0,08 dB), đỉnh là đỉnh thật từng kênh.

**Kết quả bản xuất cuối:** 0 mẫu chạm 0 dBFS; đỉnh từng đoạn −0,8 đến −6 dB; độ to trung bình mỗi đoạn −21,5 đến −23,3 dB (đo trên hai kênh), riêng "Pha nguy hiểm 2" −26,8 dB (đoạn có tiếng nổ chạm 0 dBFS nên không được nâng). Chỗ nối 11 chỗ: không có bước nhảy mẫu (có fade 0,12 s). Hình đầu/cuối mỗi đoạn đúng tên: Ra sân, tung đồng xu cuối Đội hình, bảng "HIỆP 1 0-0"/"HIỆP 2 0-2" cuối Bắt đầu hiệp, các bàn từ pha tấn công tới ăn mừng, bảng "KẾT THÚC 1-3" cuối Hết trận. Hai pha nguy hiểm (24:44, 30:20) xem 2 s/khung: pha tấn công/dứt điểm trực tiếp rồi logo và chiếu lại.

**Các pha chiếu lại trong "Gợi ý thêm"** (xem 1 s/khung): 40:25–40:53 pha dứt điểm trước khung thành + chiếu lại; 77:36–78:04 pha tấn công dài + chiếu lại đường chuyền, dứt điểm; 102:15–102:43 cầu thủ trắng bị phạm lỗi nằm sân, trọng tài cầm thẻ tiến tới, rồi chiếu lại. Cả ba đúng là pha đài chiếu lại, khung đúng (có diễn biến trực tiếp). Chúng là gợi ý vì phần dành cho pha bóng (sau các mốc và 4 bàn) còn khoảng 1 phút = 2 pha. Thẻ ở pha 102:15 chỉ thấy trên tay trọng tài, không có chữ trên hình, nên app không đặt nhãn thẻ (giới hạn đã biết).

**Kiểm thử:** test mới `EvenSoundTests.aRaisedClipNeverClips`, `SoundClipBuildTests.eachFrameKeepsItsLoudestSample`, `aStereoSoundsPeaksAreItsOwnNotTheMonoMixs`. Toàn bộ: Core 511, Media 279, tách lời 8 — đều qua. Trận FC98 chạy lại: 7 bàn, đá phạt 15:52/19:56 như cũ; "Hết hiệp 1" kết thúc 2704 thay vì 2709 s — khoảng nghỉ ≈0,35 s giữa hai chữ ở 2703,8 s nằm sát ngưỡng 0,4 s, lưới 0,2 s lúc tính thành lặng lúc không (dump cũ ngày 17/11 cũng thấy 2 bước lặng ở đó), không do bản này.

**Chưa kiểm chứng:** tai người nghe bản xuất (máy chỉ đo được mức, đỉnh, chỗ nối); nội dung lời bình luận viên ở 2704–2709 s trận FC98 (nhận dạng giọng tiếng Việt bị chặn trên máy này).

