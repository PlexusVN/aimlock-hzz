# Video nền Aimlock Hzz

App dùng `login-backgroud.mp4` cho splash/login và `app-backgroud.mp4` khi đã xác thực, gồm các màn chuẩn bị và giao diện chính. Hai file gốc ở thư mục workspace được copy nguyên bytes vào `ThreeOneOSFive/Resources/Backgrounds` và `Aimlock Hzz-WebPreview/dist/assets`.

| Video nguồn | Độ phân giải | Tốc độ nguồn | Thời lượng | Kích thước |
| --- | --- | --- | --- | --- |
| login-backgroud.mp4 | 234×416 | 25 fps | 30 giây | 377115 bytes |
| app-backgroud.mp4 | 720×1080 | 30 fps | 10 giây | 1513007 bytes |

Cả hai là H.264 High. Login có audio AAC; app tắt tiếng khi dùng làm nền, không loại bỏ hoặc chuyển mã audio/video trong file. Main không có audio.

## Chất lượng và tài nguyên

MP4 được đọc trực tiếp từ bundle, không export/transcode, đổi codec, bitrate, độ phân giải hoặc frame rate. SHA-256 của nguồn, bản bundle và preview giống nhau:

- Login: `abe5468b94e81082ae207632d18d66e51aae9c8791c907526028ebe395d17b00`.
- Main: `55896c63bb9c7cc871278e393d706059395d54439b506b7ffefba8da846f0bdd`.

Giữ chất lượng gốc không thể tạo thêm chi tiết vượt nguồn. Video login 234×416 được scale giữ tỷ lệ trong màn hình iPhone, nên không thể hứa độ nét HD. Theo yêu cầu phủ kín màn hình, `resizeAspectFill`/`object-fit:cover` dùng mức phóng nhỏ nhất đủ lấp đầy viewport, căn giữa và không cộng thêm scale. Không có hai dải trống trên/dưới; mép nguồn có thể bị cắt khi tỷ lệ video khác màn hình. Không kéo méo hoặc ghi lại file. Không ép video 25/30fps thành 60/120fps; SwiftUI vẫn dùng nhịp màn hình của thiết bị cho giao diện.

Hai poster `*-poster.png` là PNG lossless của khung hình đầu tại nguyên kích thước nguồn, dùng trước khi decoder có hình hoặc khi cần nền tĩnh. Poster không thay thế hoặc sửa video. Folder reference `Backgrounds` trong Resources build phase chép nguyên các file vào bundle; `VideoBackground.swift` đã được thêm vào Sources.

## Cách phát native

Một `AVQueuePlayer`/`AVPlayerLooper` ở gốc app phát nền lặp, muted và volume0; các tab con chỉ trong suốt phần nền nên không tạo decoder mới hoặc reset video khi chuyển tab. Không thay AVAudioSession, tránh viết lại chính sách audio keepalive hiện có.

Khi app inactive/background, player pause; khi active tiếp tục. Giảm chuyển động dùng poster tĩnh. Khi thiếu resource/decoder lỗi, app giữ poster hoặc màu xám than. Khi UIView bị tháo, dừng queue/looper và hủy KVO/notification. Nền có lớp phủ đen25% và gradient tối dần40% ở dưới; các thẻ giữ bề mặt rõ để đọc chữ và thao tác.

## Preview và kiểm chứng

Preview dùng một video element, cùng file nguồn, poster, tỷ lệ, lớp phủ và chính sách pause. `sync-source.py` copy file nguyên bytes, xác nhận SHA-256 và ghi manifest; không chuyển mã.

Đã kiểm tra hash nguồn/bundle/preview và đăng ký Xcode, Swift frontend parse,3/3license wiring,13/13iOS16compatibility và6/6security build wiring. Diff App.swift xác nhận chỉ thêm nền và cờ trình bày, không đổi nhánh auth/navigation/scene handlers. Các handler preview cũ giữ nguyên sau khi tách phần controller video mới.

Kết quả browser thực, ảnh login/main và đo playback nằm tại `scratch/app-video-background/browser-verification.json` cùng `media-report.json` ở gốc workspace. Đây là HTML/Chrome trên Windows; không thay kiểm tra Apple AVFoundation, NavigationStack transparency, pin/Keychain hoặc FPS trên iPhone thật. Chưa build/link Xcode hay IPA mới trong lượt này.

## Phủ kín màn hình và xác nhận loop

Player native dùng `resizeAspectFill`, poster `scaleAspectFill`; preview dùng cover cho cả video và poster. Đây là cùng chính sách giữ tỷ lệ và phủ kín màn hình với mức phóng tối thiểu. AVPlayerLayer bám `bounds` của view; video preview được đặt absolute trong khung màn hình, không lấy chiều cao nội dung cuộn và không có transform phóng thêm. Giữ nguyên tỷ lệ nguồn và phủ kín đồng thời có thể cắt mép, nhất là clip main 720×1080 trên màn iPhone cao.

Cơ chế lặp vẫn là `AVPlayerLooper` được giữ trong coordinator với `AVQueuePlayer`; không thêm observer kết thúc cạnh tranh looper. `actionAtItemEnd` đặt `.advance` trước khi tạo looper để queue tiến đến lượt tiếp đã xếp sẵn. Đây là cấu hình rõ hành động cuối item, không phải bằng chứng `.none` trước đó đã gây lỗi trên iPhone. Preview giữ thuộc tính `loop`; kiểm tra browser đã quan sát cả hai clip chạy hết ở tốc độ thường, tự quay về đầu và tiếp tục có frame mới, đồng thời thử tua sát cuối. Báo cáo tại `scratch/video-fit-fix/verification.json` và `browser-verification.json` ở workspace. Phép thử browser không thay xác nhận AVFoundation trên iPhone thật.

Server preview hiện dùng `serve-preview.py` với phản hồi HTTP206 byte-range; server static Python cơ bản trước đó không quảng bá hỗ trợ Range và làm Chrome báo seekable0, nên phép tua gần cuối không đi đến vị trí yêu cầu. Đã kiểm tra suffix/middle/open byte-range và phản hồi416 ngoài phạm vi trên cả hai MP4; dữ liệu từng đoạn và toàn file trùng bản gốc. Đây là sửa transport local của preview, không đổi codec hoặc cách AVPlayer đọc bundle.

## Thích ứng các màn hình iPhone

Nền native luôn theo `bounds` hiện tại của view, không chọn độ phân giải bằng tên iPhone. Đã đối chiếu tài liệu Apple theo point/pixel và mở rộng kiểm tra browser theo các nhóm màn hình, DPR, viewport thay đổi và màn rộng. Preview dùng toàn viewport trên thiết bị cảm ứng kể cả rộng hơn 520px; desktop giữ khung mô phỏng. Bảng thông số, nguồn và giới hạn kiểm chứng nằm trong [IPHONE_BACKGROUND_LAYOUT.md](IPHONE_BACKGROUND_LAYOUT.md).
