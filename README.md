# MacPlayer

Xem và chỉnh sửa **video lẫn ảnh**: cắt đoạn, ghép nhiều video, lọc màu, chữ và hình dán, rồi xuất ngay trên Mac. Mọi xử lý diễn ra trên máy; không có tài khoản, không thu thập dữ liệu, không có tính năng trực tuyến.

> **Trạng thái: bản 0.2.0 miễn phí (MIT), ký ad-hoc, chưa notarize.** Cài đặt và chia sẻ: [MacPlayer-Cai-dat-va-chia-se.md](MacPlayer-Cai-dat-va-chia-se.md). Không có thanh toán/cấp phép/tự cập nhật. Xem [docs/bao-cao-ban-giao.md](docs/bao-cao-ban-giao.md) để biết chính xác cái gì đã làm, đã kiểm thử và chưa làm.

## Yêu cầu

| | |
|---|---|
| macOS để chạy | 15.0 trở lên (cần API xuất async của AVFoundation) |
| Phần cứng đã kiểm thử | Apple Silicon (arm64) trên macOS 27.0.1. **Intel chưa được kiểm thử**, không công bố hỗ trợ. |
| Để build | Swift 6.x (bản có trong Xcode hoặc Command Line Tools). **Không cần Xcode đầy đủ.** |
| Thư viện ngoài | Không có. Chỉ dùng framework của Apple (AVFoundation, AVKit, CoreImage, SwiftUI, AppKit). |

## Build và chạy

```bash
Scripts/build_app.sh            # build/MacPlayer.app, ký ad-hoc (đủ để chạy trên máy build)
open build/MacPlayer.app
```

Lần đầu mở bản ký ad-hoc, macOS có thể chặn: vào Cài đặt hệ thống ▸ Quyền riêng tư & Bảo mật ▸ **Vẫn mở**.

```bash
swift build                     # build gỡ lỗi
Scripts/test.sh                 # toàn bộ test (xem ghi chú bên dưới)
swift Scripts/make_icon.swift   # vẽ lại Resources/AppIcon.icns
```

### Kiểm thử

- `Scripts/test.sh` chạy `swift test` kèm đường dẫn plugin Swift Testing, vì với Command Line Tools thì plugin `TestingMacros` không tự được tìm thấy.
- **Test Core** (321 test): thời gian hữu tỉ, lưu an toàn (kể cả máy chết ở mọi bước), vùng chọn, playlist, dự án, phụ đề, hàng đợi, cài đặt.
- **Test Media** (178 test): cắt đúng khung, đồng bộ tiếng/hình, hiệu ứng bằng pixel thật, khớp preview/xuất, hủy, thay thế bản gốc trên đĩa thật, nhúng ảnh bìa; nguồn HDR 10-bit; nhiều track âm thanh; file hỏng/cụt; tên file tiếng Việt; **ổ đĩa thật** tạo bằng `hdiutil` (đầy ổ, hết chỗ giữa chừng, chỉ-đọc, gỡ ổ khi đang xuất). Media thử được **sinh tự động** (mã vạch số khung hình + tiếng bíp), không dùng video cá nhân.
- **Tự kiểm thử trong app thật:** `MacPlayer.app/Contents/MacOS/MacPlayer --sandbox <thư-mục-tạm> --selftest <thư-mục-chứa-demo.mp4>` chạy các luồng A–J bằng đúng `EditorSession`, hàng đợi xuất và playlist của app, rồi in PASS/FAIL. Gồm cả phím tắt (bơm sự kiện phím thật, kể cả khi đang gõ trong ô văn bản), trạng thái menu, "luôn nổi", ba lượt xuất song song, chọn track âm thanh. `--sandbox` đưa dữ liệu vào thư mục tạm nên không đụng cài đặt thật.
- **Mở bằng Finder (Open With / bấm đúp):** `python3 -I Scripts/open_with_test.py build/MacPlayer.app .build/release/macplayer-probe <thư-mục-tạm>` mở file bằng `open -a` (cùng đường Launch Services mà Finder dùng) và đọc trạng thái app qua cờ phát triển `--report-session <json>`. Kiểm tra: mở khi app đóng/đang chạy, tên có dấu cách và chữ có dấu, thư mục → playlist, file `.macplayer`, file hỏng.
- **Giết tiến trình giữa lúc xuất:** `python3 -I Scripts/crash_test.py build/MacPlayer.app .build/release/macplayer-probe <video-dài.mp4> <số-lần> <hạt-giống>` chạy app thật ở chế độ `--crash-export`, `kill -9` ở thời điểm ngẫu nhiên (0,15–3 s) trong ba kiểu lưu (bản sao, thay bản gốc, hàng loạt), rồi mở lại bằng `--recover-check` để xác nhận: bản gốc luôn còn nguyên và đọc được, không còn file dở.
- **Video thật:** `macplayer-probe realcheck <thư-mục-video> <thư-mục-tạm> <out.md>` mở/tua/phát/xuất từng file thật rồi đọc lại kết quả (đếm khung, so điểm ảnh với nguồn, nhãn HDR/Dolby Vision, truy cập ngẫu nhiên từng khung). Trong app: thêm `--real-media <thư-mục-video>` vào lệnh `--selftest` (hoặc `--real-only` để chỉ chạy phần này). Kết quả và nguồn video đã dùng ở [docs/kiem-thu-video-that.md](docs/kiem-thu-video-that.md). Video thật không nằm trong repo.
- **Ma trận định dạng:** `.build/debug/macplayer-probe matrix <thư-mục-tạm> docs/format-matrix.md` chạy lại và sinh [docs/format-matrix.md](docs/format-matrix.md).
- **Đo hiệu năng (mục 16):** dùng bản **release** (`swift build -c release --product macplayer-probe`), rồi `.build/release/macplayer-probe bench <thư-mục-tạm> docs/benchmark.md` (thêm `--quick` để thử nhanh, số liệu không dùng). Kết quả đã chạy nằm ở [docs/benchmark.md](docs/benchmark.md).

### Cờ dành cho phát triển (không dùng khi dùng bình thường)

| Cờ | Tác dụng |
|---|---|
| `--sandbox <thư-mục>` | Cài đặt, hàng đợi, bản phục hồi nằm trong thư mục tạm; không đụng dữ liệu thật |
| `--selftest <thư-mục-media>` | Chạy tự kiểm thử rồi thoát |
| `--real-media <thư-mục>` / `--real-only` | Chạy thêm luồng K trên video thật (kèm `--selftest`) |
| `--fullscreen-check <video>` | Mở video, vào toàn màn hình, phát, thoát, in kích thước từng bước (khởi chạy bằng `open -n --stdout log -a MacPlayer.app --args --sandbox <thư-mục> --fullscreen-check <video>` để app là app đang hoạt động; màn hình sẽ chuyển toàn màn hình vài giây) |
| `--report-session <json>` | Ghi trạng thái các cửa sổ ra file JSON mỗi 0,4 s (cho `Scripts/open_with_test.py`) |
| `--crash-export <nguồn> <thư-mục-ra> <copy\|replace\|batch>` / `--recover-check` | Dành cho `Scripts/crash_test.py` |
| `--snapshot <thư-mục>`, `--project-demo <video-2>` | Chụp giao diện (không chụp được lớp video) |

## Cấu trúc

| Thư mục | Vai trò |
|---|---|
| `Sources/MacPlayerCore` | Mọi quyết định: thời gian hữu tỉ, vùng chọn, playlist và bộ máy phát, lưu an toàn + phục hồi, dự án, phụ đề, hàng đợi, kế hoạch xuất. Chỉ dùng Foundation, không I/O trực tiếp (đi qua `FileSystem`). |
| `Sources/MacPlayerMedia` | AVFoundation: dò metadata, bộ render chung cho preview và xuất (`CompositionBuilder` + `RecipeCompositor`), xuất nhanh/chính xác, thumbnail, sóng âm, sinh media thử. |
| `Sources/MacPlayer` | App AppKit/SwiftUI: cửa sổ, player, timeline, playlist, inspector, hàng đợi. Lớp mỏng. |
| `Sources/macplayer-probe` | Công cụ dòng lệnh để đo và kiểm chứng media. Chỉ đọc file, ghi vào thư mục bạn chỉ định. |
| `Resources` | Info.plist, icon, bản địa hóa `en` và `vi`. |
| `docs` | Ma trận định dạng và báo cáo bàn giao. |

## Chế độ Dự án (timeline nhiều nguồn)

Từ một video đang mở, chọn **Đoạn ▸ Dự án ▸ Từ các đoạn này / Từ toàn bộ video**, hoặc **Tệp ▸ Thêm video vào dự án…** (⌥⌘A, hoặc kéo video thả vào cửa sổ). Timeline một track gồm các đoạn lấy từ nhiều video.

- **Tách** tại vị trí phát (S, đúng khung), **nhân đôi**, **xóa có dồn khoảng trống**, **kéo đoạn để đổi thứ tự**, **kéo cạnh để cắt gọn**, nút ↑↓ trong panel.
- Công cụ **Hình ảnh** và **Âm thanh** chỉnh riêng **đoạn đang chọn**; mỗi đoạn có **tốc độ** riêng (0,25–4×). Chữ và phụ đề tính theo thời gian của dự án.
- **Xuất** cả timeline thành **một file mới** (chế độ chính xác). Không thay được bản gốc khi nhiều nguồn.
- Video bị mất được cảnh báo, xem trước và xuất chờ cho tới khi **liên kết lại** (Tệp ▸ Liên kết lại video…). File di chuyển/đổi tên được tìm lại qua bookmark.
- Undo/redo, lưu dự án, tự lưu và phục hồi sau sự cố hoạt động như chế độ nhanh.

### Lớp phủ (nhiều lớp video)

Trong dự án có **ba dòng lớp** L1–L3 dưới track chính (L3 nằm trên cùng). Mỗi lớp là một **video** (Picture in Picture) hoặc một **ảnh** (logo, watermark): **Tệp ▸ Thêm video phủ…** (⌥⌘V) / **Thêm ảnh phủ…** (⌥⌘P), hoặc tab **Lớp**.

- Lớp xuất hiện tại vị trí phát, trên dòng trống đầu tiên. Kéo lớp trên timeline để đổi thời điểm hoặc dòng (chồng lấn trong cùng một dòng bị từ chối), kéo cạnh để cắt gọn.
- Mỗi lớp có: vị trí, kích thước, độ mờ, viền (màu, độ dày), fade vào/ra, âm thanh riêng (tắt tiếng, gain), và nút vị trí nhanh (4 góc, giữa, phủ kín).
- **Keyframe cơ bản** cho vị trí, kích thước và độ mờ, nội suy tuyến tính. Khi lớp đã có keyframe, đổi một giá trị tại vị trí phát sẽ đặt keyframe ở đó.
- **Kéo trực tiếp trên khung hình:** lớp đang chọn có khung viền và 4 tay nắm. Kéo thân để di chuyển, kéo góc để đổi kích thước (góc đối diện và tỷ lệ giữ nguyên), bấm vào lớp khác để chọn nó. Lớp hít vào tâm và các lề (đường gióng màu vàng); giữ ⌥ để tắt hít. Một lần kéo là một bước Undo. Khi đang kéo, xem trước đi theo ngay không cần dựng lại; bản xuất không bao giờ bị ảnh hưởng bởi thao tác kéo dở. Cần đưa vị trí phát vào trong khoảng thời gian của lớp.
- Xem trước và xuất dùng chung một bộ render. Lớp vượt quá cuối timeline chính bị cắt. Dự án có lớp không dùng được cắt nhanh.
- Dự án cũ (định dạng 1) vẫn mở được: được nâng lên định dạng 2 khi mở.

## Nguyên tắc lưu video (đã được test)

- **Lưu thành bản sao mới** là mặc định; nguồn không đổi một byte.
- **Áp dụng thay đổi vào bản gốc** luôn hỏi xác nhận file, mặc định có sao lưu, chỉ thay sau khi file mới được xuất **và kiểm tra** (mở được, đúng thời lượng, đủ track, giải mã được khung đầu). Chặn nếu nguồn đã bị ứng dụng khác sửa, nếu đổi phần mở rộng, nếu thiếu dung lượng hoặc dự án nhiều nguồn.
- Luôn xuất vào file tạm cạnh đích rồi đổi tên; có nhật ký giao dịch để khôi phục khi app hoặc máy bị gián đoạn giữa chừng.
- Tự lưu chỉ ghi trạng thái chỉnh sửa, không bao giờ chạm vào file video.
- Undo chỉ hoàn tác chỉnh sửa. Sau khi thay bản gốc, Undo **không** đem file cũ trở lại; hãy dùng bản sao lưu.

## Phím tắt

Space phát/dừng · ← → tua · ⇧← ⇧→ tua dài · `,` `.` lùi/tiến một khung · I / O điểm vào/ra · Return thêm đoạn · M marker · `{` `}` marker trước/sau · `-` `=` chậm/nhanh · F toàn màn hình · Delete xóa đoạn · ⌘Z / ⇧⌘Z · ⌘S · ⌥⌘S lưu video · ⌥⌘E hàng đợi. Các phím một chữ chỉ hoạt động khi bạn không đang gõ trong ô nhập. **Chưa cho tùy chỉnh phím tắt.**

## Giấy phép và nguồn gốc mã

Mã MacPlayer là mã mới. Một số mẫu cấu trúc (script build `.app`, cách chạy test với Command Line Tools, ghi chú về `@State` và macro) được kế thừa từ các ứng dụng cùng tác giả (Mac Clean, App Clean, giấy phép MIT); không mang theo định danh, icon, chuỗi giao diện hay cấu hình ký của app khác. Không dùng thư viện hay codec bên thứ ba. Biểu tượng do `Scripts/make_icon.swift` tự vẽ.

Tên "MacPlayer" **chưa được kiểm tra** về nhãn hiệu, tên miền và khả năng dùng trên App Store.

### Kiểm thử trên video của bạn
- `macplayer-probe realcheck <thư mục> <work> <out.md> [--light]`: đo mở, tua, phát, xuất trên một thư mục video thật (chỉ đọc).
- `MacPlayer --sandbox <dir> --selftest <media> --library <thư mục> --real-only`: toàn bộ luồng trong app trên thư mục đó (biến môi trường `MACPLAYER_LIBRARY_ONLY=mixed`, `MACPLAYER_KEEP_OUTPUT=1`, `MACPLAYER_DEBUG_IDENTITY=1`).
- `macplayer-probe rpu|cut|cutframes`: kiểm RPU Dolby Vision, xuất thử một đoạn, đếm khung xuất. Kết quả: `docs/kiem-thu-video-that.md` (Phần 2).

## Giấy phép
MIT, xem file `LICENSE`. MacPlayer miễn phí, dùng và chia sẻ tự do.

## Ảnh

MacPlayer mở cả ảnh (JPEG, PNG, HEIC, TIFF, GIF, WebP, AVIF, ảnh RAW của máy ảnh…): kéo vào cửa sổ, mở từ menu, hoặc thêm vào danh sách phát chung với video.

- **Xem:** vừa khung, thu phóng (kẹp hai ngón, ⌘ + cuộn, nút), kéo để di chuyển, nhấp đúp để phóng to 100%. Mũi tên trái/phải chuyển ảnh trong danh sách phát; Space bắt đầu/dừng trình chiếu (thời gian mỗi ảnh đặt trong Cài đặt). GIF, PNG động và WebP động được phát (có nút tạm dừng).
- **Cắt:** khung cắt kéo trực tiếp trên ảnh (góc, cạnh, kéo bên trong để di chuyển, đường chia ba, hiện kích thước ảnh sẽ lưu), giữ tỉ lệ 1:1, 3:2, 4:5, 16:9…; khung luôn vẽ trên ảnh như đang hiển thị, kể cả khi đã xoay hoặc lật. Giá trị chính xác nằm trong mục "Giá trị chính xác".
- **Chỉnh:** xoay, lật, khung, màu, 11 bộ lọc, làm nét/mờ/tối viền, chữ, hình khối và hình dán. Dùng chung bộ vẽ với video nên ảnh trên màn hình và ảnh lưu ra giống hệt nhau. Ảnh động: cùng một chỉnh sửa áp lên mọi khung.
- **Lưu:** JPEG / PNG / HEIC / TIFF (và GIF cho ảnh động), chất lượng, giới hạn cạnh dài, tùy chọn bỏ vị trí GPS và thông tin máy ảnh. Mặc định lưu thành ảnh mới, không bao giờ ghi đè file có sẵn. "Thay ảnh gốc" hỏi xác nhận, giữ định dạng cũ và tạo bản sao lưu trước. Ảnh được kiểm tra đọc lại được, đúng kích thước rồi mới đặt vào chỗ cũ. Kích thước hiện trên màn hình đúng từng điểm ảnh với file được ghi.
- **Dự án và khôi phục:** chỉnh sửa ảnh lưu được thành dự án (⌘S, đuôi `.macplayer`) và được tự động lưu bản khôi phục như video; nếu app tắt đột ngột sẽ được hỏi khôi phục.
- Ảnh mở bằng ứng dụng không bị sửa cho đến khi bạn bấm lưu/thay. Kiểm thử trên thư mục ảnh thật (2.542 ảnh JPEG/HEIC/PNG/WebP/AVIF): chỉ đọc, kiểm tra từng file và ngày giờ của cả thư mục trước/sau.


## Tạo danh sách phát mới

Mọi lệnh **Danh sách phát mới** (nút "Mới", nút ở màn hình trống, nút trong bảng chọn danh sách, menu ⇧⌘N) đều hỏi tên trước khi tạo: tên để trống thì app nhắc và hỏi lại, bấm Hủy thì không tạo gì. Danh sách tự sinh khi thả file hoặc thư mục vào lúc chưa có danh sách nào vẫn lấy tên thư mục như trước.

## Chọn nhiều file, đổi tên, Thùng rác và cây thư mục

- **Chọn nhiều file:** ⌘-nhấp để thêm/bớt, ⇧-nhấp để chọn một dải, hoặc "Chọn tất cả". Khi có file được chọn, một thanh hiện ra với số file đã chọn và ba nút: **Đổi tên**, **Thùng rác**, **Gỡ bỏ** (chỉ gỡ khỏi danh sách, file vẫn còn). Chuột phải vào một file đang được chọn cũng áp dụng cho cả nhóm.
- **Đổi tên hàng loạt:** hộp thoại có ba cách: *Đánh số* (tên + số theo thứ tự trong danh sách), *Tìm và thay thế*, *Thêm chữ* trước/sau tên. Mọi tên cũ → tên mới hiện sẵn để xem trước; tên trùng, tên không hợp lệ hoặc file không còn tồn tại được tô đỏ và **không file nào bị đổi cho đến khi sửa xong**. Mỗi file giữ phần mở rộng; không bao giờ ghi đè file khác. Việc đổi tên "tất cả hoặc không có gì": nếu ổ đĩa từ chối một file, các file đã đổi được trả về tên cũ. Có thể đổi chéo tên (1→2, 2→3) nhờ tên tạm. File đang xuất hoặc đang mở với chỉnh sửa chưa lưu bị bỏ qua và được ghi rõ.
- **Chuyển vào Thùng rác:** hỏi trước (nút mặc định là Hủy), nêu số file, tổng dung lượng và vài tên đầu; file đi vào Thùng rác của macOS (đặt lại được) và biến mất khỏi mọi danh sách phát. Một file Thùng rác từ chối không làm dừng các file còn lại; app báo rõ file nào không chuyển được. Không bao giờ xóa vĩnh viễn.
- **Cây thư mục:** nút thứ ba cạnh "Danh sách / Lưới" hiển thị danh sách như cây: thư mục cha ở trên, thư mục con và file thụt vào, mỗi thư mục có số file bên trong, có thể mở/đóng từng thư mục hoặc "Mở tất cả / Đóng tất cả". Thư mục chỉ chứa một thư mục con được gộp thành một hàng ("2024/Hè/Biển"). Trong cây, nhấp vào một file để chọn riêng file đó, ⌘-nhấp để thêm/bớt, ⇧-nhấp để chọn một dải; nhấp đúp để phát. Ô tròn cuối hàng thư mục chọn (hoặc bỏ chọn) mọi file bên trong, kể cả thư mục con. Khi tìm kiếm, mọi thư mục có kết quả tự mở. Cây được vẽ bằng danh sách cuộn lười (chỉ vẽ các dòng đang thấy) nên mượt với thư viện hàng nghìn file (thử trên 2.713 ảnh/video thật: dựng cây 23 ms). Cách sắp xếp mới **Thư mục** (rồi theo tên) làm thứ tự phát đi đúng từ trên xuống dưới của cây; app nhắc điều này bằng một dòng ghi chú khi thứ tự khác.

## Đổi tên từ MacVideo

App trước đây tên MacVideo. Lần đầu MacPlayer chạy, nó **chép** (không di chuyển) dữ liệu của MacVideo sang: danh sách phát, vị trí đã xem, bản khôi phục, bản ghi giọng, cài đặt (kể cả cỡ và vị trí cửa sổ). Thư mục và cài đặt cũ giữ nguyên. File dự án cũ đuôi `.macvideo` vẫn mở được; dự án mới lưu đuôi `.macplayer`.
