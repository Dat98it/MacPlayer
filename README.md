# MacPlayer

Xem và chỉnh sửa **video lẫn ảnh**: cắt đoạn, ghép nhiều video, chỉnh màu chuyên nghiệp (đường cong, bánh xe màu, HSL, LUT), tách nền và mặt nạ, chuyển cảnh và keyframe, hiệu ứng giọng, chữ và hình dán, rồi xuất ngay trên Mac. Mọi xử lý diễn ra trên máy; không có tài khoản, không thu thập dữ liệu, không có tính năng trực tuyến.

> **Trạng thái: bản 0.14.4 miễn phí (MIT), ký ad-hoc, chưa notarize.** Cài đặt và chia sẻ: [MacPlayer-Cai-dat-va-chia-se.md](MacPlayer-Cai-dat-va-chia-se.md). Không có thanh toán/cấp phép/tự cập nhật. Xem [docs/bao-cao-ban-giao.md](docs/bao-cao-ban-giao.md) để biết chính xác cái gì đã làm, đã kiểm thử và chưa làm.

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
- **Test Core** (382 test): thời gian hữu tỉ, lưu bản sao an toàn, nâng cấp dự án cũ (kể cả chế độ nhanh), luật dự án video/ảnh, ghi file dự án an toàn, sổ đăng ký dự án, hàng đợi cũ có job "thay bản gốc", playlist, phụ đề, cài đặt.
- **Test Media** (223 test; có test điểm ảnh/mẫu âm thật cho màu, mặt nạ, chuyển cảnh, hiệu ứng giọng, logo trên ảnh): cắt đúng khung, đồng bộ tiếng/hình, hiệu ứng bằng pixel thật, khớp preview/xuất, hủy, không bao giờ ghi đè file có sẵn, nhúng ảnh bìa; nguồn HDR 10-bit; nhiều track âm thanh; file hỏng/cụt; tên file tiếng Việt; **ổ đĩa thật** tạo bằng `hdiutil` (đầy ổ, hết chỗ giữa chừng, chỉ-đọc, gỡ ổ khi đang xuất). Media thử được **sinh tự động** (mã vạch số khung hình + tiếng bíp), không dùng video cá nhân.
- **Tự kiểm thử trong app thật:** `MacPlayer.app/Contents/MacOS/MacPlayer --sandbox <thư-mục-tạm> --selftest <thư-mục-chứa-demo.mp4>` chạy các luồng A–N bằng đúng `EditorSession`, hàng đợi xuất và playlist của app, rồi in PASS/FAIL. Gồm cả phím tắt (bơm sự kiện phím thật, kể cả khi đang gõ trong ô văn bản), trạng thái menu, "luôn nổi", ba lượt xuất song song, chọn track âm thanh. `--sandbox` đưa dữ liệu vào thư mục tạm nên không đụng cài đặt thật.
- **Mở bằng Finder (Open With / bấm đúp):** `python3 -I Scripts/open_with_test.py build/MacPlayer.app .build/release/macplayer-probe <thư-mục-tạm>` mở file bằng `open -a` (cùng đường Launch Services mà Finder dùng) và đọc trạng thái app qua cờ phát triển `--report-session <json>`. Kiểm tra: mở khi app đóng/đang chạy (video mở để xem trong Danh sách phát), tên có dấu cách và chữ có dấu, thư mục → playlist, file `.macplayer` mở vào trình chỉnh sửa (mở lại lần nữa không mở trùng), file hỏng.
- **Giết tiến trình giữa lúc xuất:** `python3 -I Scripts/crash_test.py build/MacPlayer.app .build/release/macplayer-probe <video-dài.mp4> <số-lần> <hạt-giống>` chạy app thật ở chế độ `--crash-export` / `--crash-autosave`, `kill -9` ở thời điểm ngẫu nhiên (0,15–3 s) khi đang xuất bản sao, xuất hàng loạt, hoặc đang tự lưu dự án liên tục, rồi mở lại bằng `--recover-check` để xác nhận: nguồn không đổi một byte, file dự án luôn đọc được trọn vẹn, không còn file dở.
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
| `--crash-export <nguồn> <thư-mục-ra> <copy\|batch>` / `--crash-autosave <nguồn> <thư-mục>` / `--recover-check` | Dành cho `Scripts/crash_test.py` |
| `MACPLAYER_START_ROUTE=home\|playlist\|projects` | (sandbox) mở cửa sổ ở màn hình đó, để chụp giao diện |
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
| `CLAUDE.md` | Hướng dẫn cho AI agent / người mới: công nghệ, cấu trúc, quy tắc, cách thêm tính năng, cách phát hành. Đọc file này trước khi sửa code. |

## Hai khu: Danh sách phát và Chỉnh sửa (0.8.0)

Mở app là màn hình **Trang chủ** với hai nút lớn: **Danh sách phát** (⌘1) và **Chỉnh sửa** (⌘2). Mỗi cửa sổ có màn hình riêng (một cửa sổ xem danh sách phát, cửa sổ khác sửa dự án). ⇧⌘H về Trang chủ.

- **Danh sách phát:** giao diện danh sách phát như trước, nhưng **chỉ để xem**: phát, xem ảnh/trình chiếu, đổi tên, chuyển file vào Thùng rác. Không có bảng công cụ chỉnh sửa. Video/ảnh mở từ Finder ("Mở bằng", bấm đúp, kéo thả, dòng lệnh) mở ở đây, không cần tạo dự án.
- Đang xem mà muốn sửa: nút **Chỉnh sửa** (⌘E) → hỏi xác nhận → chọn nơi lưu → tạo **dự án mới có sẵn file đang xem** (video → dự án video, ảnh → dự án ảnh) và mở trình chỉnh sửa. Hủy ở bất kỳ bước nào thì không tạo gì, file vẫn đang phát như cũ.
- **Chỉnh sửa:** danh sách mọi dự án (thẻ có ảnh đại diện, nhãn **Video/Ảnh**, lọc, sắp xếp, tìm không dấu), nút **Dự án mới** (⌘N) chọn loại rồi **luôn hỏi nơi lưu** (không có thư mục mặc định; hộp thoại mở sẵn ở thư mục dùng lần trước). Chuột phải: Mở, **Đổi tên…** (đổi cả tên file `.macplayer`, không ghi đè, hoàn tác nếu lỗi), Hiện trong Finder, **Chuyển vào Thùng rác…** (hỏi trước, Hủy là mặc định; chỉ file dự án vào Thùng rác, video/ảnh không bị đụng; dữ liệu khôi phục của dự án cũng được dọn để dự án không "sống lại"), Bỏ khỏi danh sách.
- Danh sách dự án (sổ đăng ký trong `~/Library/Application Support/MacPlayer/Projects/registry.json`) theo dõi file dự án ở bất cứ đâu: file bị đổi tên/di chuyển ngoài app được tìm lại qua bookmark; ổ chưa cắm hiện "Ổ chưa kết nối" chứ không coi là mất; file bị xóa hiện "Không tìm thấy file" với **Tìm lại…** / **Bỏ khỏi danh sách**; file trong Thùng rác được ẩn. Lần đầu chạy, dự án cũ được nhập từ danh sách file gần đây và dữ liệu khôi phục (không quét ổ đĩa).
- **Tự lưu thẳng vào file dự án** vài giây sau mỗi chỉnh sửa (thanh trên hiện "Đã lưu 14:02" / "Đang lưu…" / "Chưa lưu được"). ⌘S = lưu ngay. Ghi theo thứ tự, một lần một, qua file tạm rồi đổi tên, đọc lại để kiểm tra; một bản khôi phục cũng được ghi trên máy trước. File dự án bị app khác sửa thì **không ghi đè**: thanh trên cho chọn giữ chỉnh sửa của bạn hay dùng file trên đĩa. Không ghi được (ổ bị gỡ, chỉ đọc) thì giữ bản khôi phục và thử lại; đóng cửa sổ khi đó sẽ hỏi Thử lại / Lưu vào chỗ khác / Vẫn đóng.
- **Hai loại dự án:** *dự án video* (timeline nhiều video, lớp phủ video/ảnh, âm thanh, phụ đề) và *dự án ảnh* (**đúng một ảnh**, cộng chữ/hình và **logo**). Thả sai loại bị chặn với lời giải thích; thả ảnh vào dự án video thì hỏi "Thêm làm lớp phủ?", thả ảnh thứ hai vào dự án ảnh thì hỏi "Thêm làm logo?". **Đổi ảnh…** giữ màu/hiệu ứng/chữ/logo, đặt lại khung cắt nếu ảnh mới khác tỉ lệ, hoàn tác được.
- **Chế độ nhanh đã bỏ**: dự án `.quick` cũ (`.macplayer`/`.macvideo`) được **nâng cấp khi mở**: video thành dự án video một đoạn mang đúng chỉnh sửa cũ, ảnh thành dự án ảnh; vùng chọn In–Out cũ vẫn giữ trong file. Trước lần ghi đầu, bản cũ của file dự án được chép vào thư mục khôi phục. Bản MacPlayer cũ không mở file định dạng mới (từ chối an toàn, không mất dữ liệu).

## Trình chỉnh sửa video kiểu CapCut (0.9.0)

Mở một dự án video là thấy ngay bố cục quen thuộc của các app dựng phim:

- **Trái: Thư viện.** Gồm các tab **Media**, **Âm thanh**, **Chữ**, **Bộ lọc**, **Chuyển cảnh**.
  - Bấm **Nhập media** hoặc kéo file từ Finder vào. File chỉ được ghi nhớ đường dẫn, không bị sao chép hay thay đổi.
  - Dấu ✓ là file đang được dùng trong dự án.
- **Giữa:** khung xem và nút phát. **Phải: Thuộc tính** của thứ đang chọn:
  - đoạn video: Cơ bản, Màu, Hiệu ứng, Tốc độ, Âm thanh, Chuyển cảnh, Cắt nền;
  - lớp, chữ hoặc âm thanh: phần chỉnh của chính nó;
  - chưa chọn gì: Tổng quan dự án, Phụ đề, Xuất.
- **Dưới, kéo hết chiều ngang:** thanh công cụ (Hoàn tác/Làm lại, Tách, Nhân đôi, Xoá, Đánh dấu, Chữ, thu phóng) và timeline.
  - Timeline có các làn **Video** (kèm ảnh thu nhỏ), **Chữ**, **Lớp 1–3** và **Âm thanh**.
- **Kéo-thả:**
  - video thả vào đúng chỗ trên làn video;
  - ảnh thả lên làn lớp;
  - nhạc thả lên làn âm thanh;
  - **bộ lọc** thả lên một đoạn;
  - **chuyển cảnh** thả vào chỗ nối giữa hai đoạn;
  - **kiểu chữ** hoặc nhãn dán thả vào một thời điểm.
- **Chỉnh trên timeline:**
  - Kéo một mục để dời; mục bám vào đầu phát, chỗ nối và hai đầu timeline.
  - Kéo mép để đổi độ dài.
  - ⌫ xoá thứ đang chọn, Esc bỏ chọn.
- Nút **Xuất** ở góc trên bên phải.
- **Ảnh trên làn video chính (0.10.0):**
  - Thả ảnh lên làn video (hoặc bấm + trên ảnh) để ảnh thành một đoạn riêng, mặc định 5 giây.
  - Kéo mép để ảnh hiện tối đa 60 giây. Ghép nhiều ảnh thành trình chiếu, có chuyển cảnh và chữ như với video.
  - MacPlayer tạo một video ngắn của ảnh trong thư mục riêng của nó; ảnh gốc chỉ được đọc. Nếu video ngắn đó mất, MacPlayer tự tạo lại từ ảnh.
  - Thả ảnh lên làn **Lớp** thì ảnh vẫn thành lớp chồng lên video (logo, ảnh nhỏ).
- **Thao tác ngay trên khung hình (0.11.0):**
  - Kéo kiểu chữ, nhãn dán, **hình** (vuông, tròn, sao, mũi tên…) hoặc ảnh từ Thư viện (hay ảnh từ Finder) thả lên khung hình: nó nằm đúng chỗ thả.
  - Bấm vào chữ, nhãn dán, hình, lớp hay logo trên khung hình để chọn. Kéo để dời; kéo một góc để phóng to/thu nhỏ.
  - Đến gần giữa khung, nó tự bám vào giữa (đường gióng vàng); giữ ⌥ để thả tự do.
  - Khung hình đổi ngay khi kéo. Mỗi lần kéo là một bước Hoàn tác.
  - Dự án ảnh: khung cắt chỉ hiện khi bật "Chỉnh ngay trên ảnh" hoặc chọn một tỉ lệ.
- **Chọn nhiều, nhóm, khoá (0.12.0):**
  - ⇧-bấm (hoặc ⌘-bấm) để chọn thêm; kéo một khung trên vùng trống của khung hình để chọn mọi thứ bên trong (chữ, hình, nhãn dán, lớp, logo).
  - Kéo một mục thì cả nhóm đang chọn cùng di chuyển.
  - **⌘G** nhóm lại (bấm một mục là chọn cả nhóm), **⇧⌘G** bỏ nhóm, **⌘L** khoá/mở khoá. Mục đã khoá không bị dời hay xoá trên khung hình.
  - Các lệnh này có trong menu Sửa, chuột phải và đầu bảng Thuộc tính.
- **Phím tắt trên khung hình (0.12.0):**
  - **⌫** xoá; **← → ↑ ↓** dời 1 điểm (**⇧**: 10 điểm); **Esc** bỏ chọn; **⌘D** nhân đôi.
  - Khi không chọn gì trên khung hình, mũi tên vẫn tua video như trước.
- **0.13.0:**
  - Chữ, hình, nhãn dán **chỉ thêm từ tab Chữ của Thư viện bên trái**. Bảng phải chỉ để chỉnh mục đang chọn (menu **Kiểu** đổi kiểu chữ).
  - Kéo một kiểu chữ thả đè lên chữ có sẵn thì chữ đó đổi kiểu.
  - **Báo căn giữa:** khi kéo, tâm của vật bám vào giữa khung hình hoặc giữa vật nằm dưới nó (chữ trên hình, nhãn dán trên logo), hiện đường hồng kèm nhãn "Đã căn giữa: …".
  - **Bấm đúp vào chữ** trên khung hình để gõ ngay: Return xong, ⌥Return xuống dòng, Esc huỷ.
- **0.14.0:**
  - **Mẫu mới:** 17 kiểu chữ; nhóm **Mẫu có sẵn** (Đăng ký, Trực tiếp, Mới, Giảm 50%, Thích & chia sẻ, Theo dõi, Sắp ra mắt, Cảm ơn đã xem, Địa điểm, Tin nóng); 16 hình (thêm thoi, ngũ giác, lục giác, bong bóng thoại, nhãn nổ, dấu tích, dấu cộng, vòng tròn); hơn 60 nhãn dán.
  - Hình vuông/tròn luôn đúng tỉ lệ trên mọi khung hình.
  - **Xuất:**
    - chỉ một nút ở góc trên bên phải, mở cửa sổ Xuất;
    - chọn **khung hình** theo nền tảng (Gốc, 16:9 YouTube, 9:16 TikTok/Reels/Shorts, 1:1, 4:5 Instagram dọc, 4:3) và cách lấp (viền đen, cắt mép, viền mờ);
    - **một** lựa chọn chất lượng (Tốt nhất, 4K, Full HD, HD, Nhẹ) thay cho "Chất lượng" và "Cỡ".
    - Video dọc 1080p là 1080 × 1920.
  - Ô Thư viện không còn nhấp nháy khi phát video.
- **0.14.4:** nhãn dán, chữ, hình, logo trên khung hình không còn bị viền nét đứt bao quanh khi viền đang tắt: khung nét đứt chỉ hiện khi rê chuột lên đối tượng, và không bao giờ có trong video/ảnh xuất ra.
- **0.14.3:** kéo chữ, hình, nhãn dán, logo trên khung hình giờ đi liền theo chuột: trong lúc kéo app tự vẽ đối tượng nổi trên khung hình, trình phát chỉ vẽ lại khi bắt đầu và khi thả. Sửa lỗi sập khi mở dự án mà mọi video đều đã bị dời đi.
- **0.14.2:** kéo chữ, hình, nhãn dán, lớp trên khung hình mượt hơn: khung chọn và hình đi đúng theo chuột; các bảng bên không vẽ lại trong lúc kéo, dự án chỉ ghi một lần khi thả.
- **0.14.1:** tab Chữ của Thư viện chia thành 4 tab con: **Kiểu chữ · Mẫu sẵn · Hình · Nhãn dán**. Mỗi lần hiện một nhóm, không phải cuộn dài; hình và nhãn dán hiện to hơn, hình có tên.
- **Dự án ảnh (0.10.0)** dùng cùng bố cục:
  - Thư viện bên trái có các tab **Ảnh** (ảnh đầu tiên là ảnh chính, các ảnh sau thành logo), **Chữ** và **Bộ lọc**. Kéo thả thẳng lên ảnh.
  - Bên phải là mọi công cụ chỉnh ảnh, kèm nút Xuất.

## Dự án video (timeline nhiều nguồn)

Trong một dự án video: **Tệp ▸ Thêm video vào dự án…** (⌥⌘A, hoặc kéo video thả vào cửa sổ). Timeline một track gồm các đoạn lấy từ nhiều video.

- **Tách** tại vị trí phát (S, đúng khung), **nhân đôi**, **xóa có dồn khoảng trống**, **kéo đoạn để đổi thứ tự**, **kéo cạnh để cắt gọn**, nút ↑↓ trong panel.
- Công cụ **Hình ảnh** và **Âm thanh** chỉnh riêng **đoạn đang chọn**; mỗi đoạn có **tốc độ** riêng (0,25–4×). Chữ và phụ đề tính theo thời gian của dự án. Phụ đề tự động nghe lời nói của đoạn đang chọn.
- **Xuất** cả timeline thành **một file mới** (chế độ chính xác).
- Video bị mất được cảnh báo, xem trước và xuất chờ cho tới khi **liên kết lại** (Tệp ▸ Liên kết lại…). File di chuyển/đổi tên được tìm lại qua bookmark.

### Lớp phủ (nhiều lớp video)

Trong dự án có **ba dòng lớp** L1–L3 dưới track chính (L3 nằm trên cùng). Mỗi lớp là một **video** (Picture in Picture) hoặc một **ảnh** (logo, watermark): **Tệp ▸ Thêm video phủ…** (⌥⌘V) / **Thêm ảnh phủ…** (⌥⌘P), hoặc tab **Lớp**.

- Lớp xuất hiện tại vị trí phát, trên dòng trống đầu tiên. Kéo lớp trên timeline để đổi thời điểm hoặc dòng (chồng lấn trong cùng một dòng bị từ chối), kéo cạnh để cắt gọn.
- Mỗi lớp có: vị trí, kích thước, độ mờ, viền (màu, độ dày), fade vào/ra, âm thanh riêng (tắt tiếng, gain), và nút vị trí nhanh (4 góc, giữa, phủ kín).
- **Keyframe cơ bản** cho vị trí, kích thước và độ mờ, nội suy tuyến tính. Khi lớp đã có keyframe, đổi một giá trị tại vị trí phát sẽ đặt keyframe ở đó.
- **Kéo trực tiếp trên khung hình:** lớp đang chọn có khung viền và 4 tay nắm. Kéo thân để di chuyển, kéo góc để đổi kích thước (góc đối diện và tỷ lệ giữ nguyên), bấm vào lớp khác để chọn nó. Lớp hít vào tâm và các lề (đường gióng màu vàng); giữ ⌥ để tắt hít. Một lần kéo là một bước Undo. Khi đang kéo, xem trước đi theo ngay không cần dựng lại; bản xuất không bao giờ bị ảnh hưởng bởi thao tác kéo dở. Cần đưa vị trí phát vào trong khoảng thời gian của lớp.
- Xem trước và xuất dùng chung một bộ render. Lớp vượt quá cuối timeline chính bị cắt. Dự án có lớp không dùng được cắt nhanh.
- Dự án cũ (định dạng 1, 2) vẫn mở được: được nâng lên định dạng 3 khi mở.

## Nguyên tắc: không bao giờ sửa file gốc (đã được test)

- MacPlayer **không bao giờ sửa, ghi đè hay thay thế** file video/ảnh gốc. Tính năng "thay bản gốc" đã được **gỡ hẳn** (0.8.0). Mọi kết quả xuất luôn là **file mới**; tên đã có thì thêm số, không ghi đè.
- Xuất vào file tạm cạnh đích rồi đổi tên, sau khi kiểm tra (mở được, đúng thời lượng, đủ track, giải mã được khung đầu).
- Lưu khung hình, xuất âm thanh, xuất phụ đề/mốc: không bao giờ ghi đè video, ảnh hay âm thanh có sẵn, kể cả khi hộp thoại hỏi "Thay thế?".
- Tự lưu chỉ ghi file dự án (`.macplayer`/`.macvideo`) và dữ liệu khôi phục của app.
- Nếu bản 0.7 cũ bị tắt ngang giữa lúc thay bản gốc, bản mới vẫn đặt bản gốc về chỗ cũ khi khởi động. Job "thay bản gốc" còn sót trong hàng đợi cũ được đánh dấu thất bại, không bao giờ chạy; các job khác giữ nguyên.
- Ngoại lệ duy nhất có chủ ý: trong **Danh sách phát**, khi bạn yêu cầu, file được **đổi tên** hoặc chuyển vào **Thùng rác** (có hỏi trước, đặt lại được).

## Phím tắt

⌘1 Danh sách phát · ⌘2 Dự án · ⇧⌘H Trang chủ · ⌘N dự án mới (khi ở Chỉnh sửa; ⌥⌘N cửa sổ mới) · ⌘E chỉnh sửa file đang xem · Space phát/dừng · ← → tua · ⇧← ⇧→ tua dài · `,` `.` lùi/tiến một khung · S tách đoạn · M marker · `{` `}` marker trước/sau · `-` `=` chậm/nhanh · F toàn màn hình · Delete xóa đoạn · ⌘Z / ⇧⌘Z · ⌘S lưu ngay · ⌥⌘S xuất video · ⌥⌘E hàng đợi. Các phím một chữ chỉ hoạt động khi bạn không đang gõ trong ô nhập. **Chưa cho tùy chỉnh phím tắt.**

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
- **Lưu:** JPEG / PNG / HEIC / TIFF (và GIF cho ảnh động), chất lượng, giới hạn cạnh dài, tùy chọn bỏ vị trí GPS và thông tin máy ảnh. Luôn lưu thành ảnh mới, không bao giờ ghi đè file có sẵn và không bao giờ thay ảnh gốc. Ảnh được kiểm tra đọc lại được, đúng kích thước rồi mới đặt vào chỗ. Kích thước hiện trên màn hình đúng từng điểm ảnh với file được ghi.
- **Dự án ảnh:** mọi chỉnh sửa ảnh nằm trong một dự án ảnh (một ảnh) tự lưu vào file `.macplayer`; có thể thêm **logo** (hình đặt lên ảnh, vẽ giống nhau trên màn hình và file lưu, kể cả mọi khung GIF). Nếu app tắt đột ngột sẽ được hỏi khôi phục.
- Ảnh gốc không bao giờ bị sửa. Kiểm thử trên thư mục ảnh thật (2.542 ảnh JPEG/HEIC/PNG/WebP/AVIF): chỉ đọc, kiểm tra từng file và ngày giờ của cả thư mục trước/sau.


## Tạo danh sách phát mới

Mọi lệnh **Danh sách phát mới** (nút "Mới", nút ở màn hình trống, nút trong bảng chọn danh sách, menu ⇧⌘N) đều hỏi tên trước khi tạo: tên để trống thì app nhắc và hỏi lại, bấm Hủy thì không tạo gì. Danh sách tự sinh khi thả file hoặc thư mục vào lúc chưa có danh sách nào vẫn lấy tên thư mục như trước.

## Giọng và hiệu ứng âm thanh (0.7.0)

Trong công cụ **Âm thanh**, cho cả tiếng của video lẫn từng nhạc/giọng đọc trên timeline:

- **Giọng và hiệu ứng:** một chạm cho *Giọng rõ, Ấm, Giọng trầm, Giọng cao, Sóc chuột, Điện thoại, Phòng lớn, Vang dội*; hoặc **Tự chỉnh**: âm trầm / trung / cao (±12 dB), cao độ (±12 nửa cung, độ dài không đổi), tiếng phòng, tiếng dội. Việc xử lý chạy một lần (nhanh hơn thời gian thực) trên một bản sao âm thanh bằng audio unit của Apple; file gốc không bị đổi; cùng thiết lập thì dùng lại bản đã làm. Dùng chung cho xem trước và xuất, và nối được sau bước giảm ồn.
- **Âm lượng theo thời gian:** vẽ đường âm lượng cho từng âm thanh: nhấp vào đường để thêm điểm, kéo lên/xuống để to/nhỏ hơn ở đó, nhấp đúp để xóa. Nhân với tăng giảm âm, fade và tự hạ nhạc khi có người nói.

Dự án cũ mở bình thường, các tính năng mới ở trạng thái tắt.

## Chuyển cảnh, keyframe và hoạt ảnh (0.6.0)

- **8 kiểu chuyển cảnh mới** giữa các đoạn của dự án (tổng 17): quét trái / lên / xuống, mở vòng tròn, mờ nhòe, xoay, lóe sáng, vỡ ô. Mỗi kiểu có hình xem trước trên khung hình thật.
- **Kiểu chuyển động giữa các keyframe (easing):** đều, chậm lúc đầu, chậm lúc cuối, chậm hai đầu, vọt rồi về, nảy. Chọn bằng menu nhỏ trên từng keyframe, cho lớp phủ, chữ/hình dán và "Phóng to và dời" của hình chính.
- **Xoay:** lớp phủ có thanh trượt xoay (và keyframe xoay), "Phóng to và dời" của hình chính cũng xoay được và có keyframe xoay.
- **Xuất hiện và biến mất** cho lớp phủ (trượt 4 hướng, mờ, bật ra, phóng to) với thời gian chỉnh được, cộng thêm vào keyframe, giống cách chữ vẫn làm.

Dự án cũ mở bình thường: keyframe cũ vẫn chuyển động đều và không xoay.

## Tách nền, mặt nạ và hòa trộn (0.5.0)

Công cụ **Tách nền** (video và ảnh) và các điều khiển mới trong **Lớp**:

- **Xóa nền:** chỉ giữ người (video) hoặc chủ thể chính (ảnh), dùng Vision chạy ngay trên máy, không cần mạng. Video: xem trước dùng chế độ nhanh, xuất dùng chế độ chính xác. Hình không tìm thấy ai thì được giữ nguyên.
- **Phông xanh (chroma key) cho video chính**, không chỉ cho lớp phủ: chọn màu, độ dung sai, độ mềm viền.
- **Mặt nạ hình:** tròn, chữ nhật, bo góc, trái tim, ngôi sao, nửa hình; chỉnh rộng/cao, vị trí, xoay, viền mềm và đảo (ẩn phần bên trong). Dùng được cho hình chính lẫn từng lớp phủ.
- **Hiện gì thay vào** phần bị bỏ đi: màu tự chọn (đen, trắng hoặc bất kỳ), hoặc bản sao mờ của chính hình.
- **Hòa trộn lớp phủ** (Multiply, Screen, Overlay, Soft/Hard light, Darken, Lighten, Difference, Add) cho kết cấu, hiệu ứng rò sáng, logo.

Mọi thứ đi qua cùng bộ render của xem trước và xuất. Dự án cũ mở bình thường, các tính năng mới ở trạng thái tắt.

## Chỉnh màu chuyên nghiệp (0.4.0)

Công cụ **Màu** (cho cả video lẫn ảnh) nằm cạnh Hình ảnh và Hiệu ứng. Mỗi nhóm là một thẻ có thể thu gọn, có dấu chấm xanh khi đã chỉnh và nút Đặt lại riêng; thay đổi hiện ngay trên khung hình đang phát.

- **Ánh sáng và màu:** độ phơi sáng, độ sáng, tương phản, vùng sáng, vùng tối, bão hòa, độ rực màu (vibrance), nhiệt độ, sắc thái lục–tím.
- **Đường cong:** đường cong ánh sáng và từng kênh đỏ/lục/lam. Nhấp vào đường để thêm điểm, kéo để uốn, nhấp đúp vào điểm để xóa; đường cong không bao giờ đi ngược nên không sinh dải màu lạ.
- **Bánh xe màu:** nhuộm riêng vùng tối, vùng giữa, vùng sáng bằng cách kéo chấm về phía một màu; thanh trượt dưới mỗi bánh làm phần đó sáng/tối hơn; nhấp đúp để đặt lại.
- **Từng màu (HSL):** chọn một trong 8 màu (đỏ, cam, vàng, lục, lục lam, lam, tím, tím hồng) rồi chỉ đổi sắc độ, bão hòa, độ sáng của màu đó, ví dụ làm trời xanh hơn mà không đụng tới da.
- **File màu (LUT .cube):** nạp file `.cube` 3D của phim/máy ảnh, chỉnh cường độ; file chỉ được đọc, không bị sửa; nếu mất file app báo rõ và bỏ qua thay vì lỗi.
- **Biểu đồ sáng tối:** histogram của khung hình sau khi chỉnh, cảnh báo khi một phần hình cháy trắng hoặc đen kịt (mất chi tiết).
- **Nút nhanh:** *So sánh* (giữ để xem hình trước khi chỉnh), *Sao chép/Dán* màu giữa các đoạn hoặc ảnh, *Mọi đoạn* (dự án: áp cùng một màu cho cả timeline), *Đặt lại tất cả*.

Tất cả đi qua cùng một bộ render của xem trước và xuất, nên màu bạn thấy là màu nhận được (đã kiểm thử bằng điểm ảnh thật trên video xuất ra và ảnh). Dự án cũ mở bình thường, các công cụ mới ở trạng thái tắt. Video HDR: màu áp lên hình HDR như đang lưu, không chuyển tông (app cảnh báo).

## Chọn nhiều file, đổi tên, Thùng rác và cây thư mục

**Cỡ ảnh xem trước và viền màu (0.3.0).** Thanh trượt ngay dưới hàng "sắp xếp / danh sách-lưới-cây" làm ảnh xem trước của các file trong danh sách phát nhỏ hơn hoặc to hơn (10 mức, áp dụng cho cả ba cách hiển thị); mức đã chọn được nhớ qua các lần mở app, mặc định lớn hơn bản cũ. Khi ảnh to mà sidebar hẹp, tên file tự xuống dưới ảnh; kéo sidebar rộng ra thì thêm cột (lưới) hoặc tên nằm cạnh ảnh. Hai trạng thái giờ có viền khác màu: **file đang mở** có viền **xanh lá** quanh ảnh và biểu tượng loa xanh lá; **file đang được chọn** (để đổi tên / Thùng rác / gỡ khỏi danh sách) có viền **màu nhấn của hệ thống** quanh cả ô hoặc cả hàng cùng dấu tích, nên một file vừa mở vừa được chọn vẫn thấy cả hai.

- **Chọn nhiều file:** ⌘-nhấp để thêm/bớt, ⇧-nhấp để chọn một dải, hoặc "Chọn tất cả". Khi có file được chọn, một thanh hiện ra với số file đã chọn và ba nút: **Đổi tên**, **Thùng rác**, **Gỡ bỏ** (chỉ gỡ khỏi danh sách, file vẫn còn). Chuột phải vào một file đang được chọn cũng áp dụng cho cả nhóm.
- **Đổi tên hàng loạt:** hộp thoại có ba cách: *Đánh số* (tên + số theo thứ tự trong danh sách), *Tìm và thay thế*, *Thêm chữ* trước/sau tên. Mọi tên cũ → tên mới hiện sẵn để xem trước; tên trùng, tên không hợp lệ hoặc file không còn tồn tại được tô đỏ và **không file nào bị đổi cho đến khi sửa xong**. Mỗi file giữ phần mở rộng; không bao giờ ghi đè file khác. Việc đổi tên "tất cả hoặc không có gì": nếu ổ đĩa từ chối một file, các file đã đổi được trả về tên cũ. Có thể đổi chéo tên (1→2, 2→3) nhờ tên tạm. File đang xuất hoặc đang mở với chỉnh sửa chưa lưu bị bỏ qua và được ghi rõ.
- **Chuyển vào Thùng rác:** hỏi trước (nút mặc định là Hủy), nêu số file, tổng dung lượng và vài tên đầu; file đi vào Thùng rác của macOS (đặt lại được) và biến mất khỏi mọi danh sách phát. Một file Thùng rác từ chối không làm dừng các file còn lại; app báo rõ file nào không chuyển được. Không bao giờ xóa vĩnh viễn.
- **Cây thư mục:** nút thứ ba cạnh "Danh sách / Lưới" hiển thị danh sách như cây: thư mục cha ở trên, thư mục con và file thụt vào, mỗi thư mục có số file bên trong, có thể mở/đóng từng thư mục hoặc "Mở tất cả / Đóng tất cả". Thư mục chỉ chứa một thư mục con được gộp thành một hàng ("2024/Hè/Biển"). Trong cây, nhấp vào một file để chọn riêng file đó, ⌘-nhấp để thêm/bớt, ⇧-nhấp để chọn một dải; nhấp đúp để phát. Thanh phía trên cây có hai nút nhỏ để chọn cách hiện **file trong mỗi thư mục**: dạng danh sách (mặc định) hoặc dạng **lưới ảnh** (nhiều cột, mỗi thư mục là một khối thụt vào dưới tên thư mục) — thư mục có hàng trăm file khi đó đỡ phải cuộn rất dài; lựa chọn được nhớ cho lần mở sau, và cách chọn file (nhấp, ⌘, ⇧, nhấp đúp) vẫn như cũ. Ô tròn cuối hàng thư mục chọn (hoặc bỏ chọn) mọi file bên trong, kể cả thư mục con. Khi tìm kiếm, mọi thư mục có kết quả tự mở. Cây được vẽ bằng danh sách cuộn lười (chỉ vẽ các dòng đang thấy) nên mượt với thư viện hàng nghìn file (thử trên 2.713 ảnh/video thật: dựng cây 23 ms). Cách sắp xếp mới **Thư mục** (rồi theo tên) làm thứ tự phát đi đúng từ trên xuống dưới của cây; app nhắc điều này bằng một dòng ghi chú khi thứ tự khác.

## Đổi tên từ MacVideo

App trước đây tên MacVideo. Lần đầu MacPlayer chạy, nó **chép** (không di chuyển) dữ liệu của MacVideo sang: danh sách phát, vị trí đã xem, bản khôi phục, bản ghi giọng, cài đặt (kể cả cỡ và vị trí cửa sổ). Thư mục và cài đặt cũ giữ nguyên. File dự án cũ đuôi `.macvideo` vẫn mở được; dự án mới lưu đuôi `.macplayer`.
