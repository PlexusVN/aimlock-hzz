# Nền video thích ứng màn hình iPhone

Đối chiếu tài liệu Apple ngày 14/11/2026. Phạm vi là cách bố trí nền trong app đang target iOS 16+; đây không phải chứng nhận đã chạy tất cả model hoặc phiên bản iOS.

## Chính sách bố trí

App lấy kích thước hiện tại của view/window bằng point. `AppVideoBackdrop` nằm ở ZStack gốc, ngoài nội dung cuộn, và chỉ nền bỏ giới hạn safe area. Mỗi lần UIKit layout, `playerLayer.frame` và `poster.frame` đều được cập nhật bằng `bounds`. Không lưu kích thước của một iPhone khi khởi động và không chọn kích thước theo tên model.

Video dùng `resizeAspectFill`, poster dùng `scaleAspectFill`. Với viewport W×H và nguồn w×h, hệ số phủ tối thiểu là `max(W/w, H/h)`: cả hai chiều đều đủ lớn, ít nhất một chiều vừa khít. Giữ tỷ lệ, không thêm zoom; chỉ cắt mép dư để không tạo hai dải trống. Cơ chế này tiếp tục làm việc với kích thước mới, Display Zoom hoặc cửa sổ thay đổi, không cần bổ sung hằng số model.

Apple hướng dẫn thích ứng theo vùng hiển thị có sẵn, safe area và Display Zoom: [HIG Layout](https://developer.apple.com/design/human-interface-guidelines/layout). Apple phân biệt [bounds theo point](https://developer.apple.com/documentation/uikit/uiscreen/bounds) và [nativeBounds theo pixel](https://developer.apple.com/documentation/uikit/uiscreen/nativebounds). Trong mã sản phẩm dùng bounds của view sở hữu nền, không dùng ảnh chụp `UIScreen.main` cố định.

## Độ phân giải panel đã đối chiếu

Đã đọc 40 trang thông số Apple, gồm 41 panel và 15 nhóm hình chữ nhật pixel. Bảng này chỉ là dữ liệu đối chiếu tỷ lệ; KHÔNG được dùng như bảng chọn kích thước runtime và KHÔNG đồng nghĩa với kích thước bố cục point. Dữ liệu panel có góc bo được ghi theo hình chữ nhật chuẩn do Apple công bố.

| Pixel dọc, rộng × cao | Model / màn hình và nguồn Apple |
| --- | --- |
| 750 × 1334 | [iPhone SE (3rd generation)](https://support.apple.com/en-us/111866), [iPhone SE (2nd generation)](https://support.apple.com/en-us/111882), [iPhone 8](https://support.apple.com/en-us/111976) |
| 828 × 1792 | [iPhone 11](https://support.apple.com/en-us/111865), [iPhone XR](https://support.apple.com/en-us/111868) |
| 1080 × 1920 | [iPhone 8 Plus](https://support.apple.com/en-us/111950) |
| 1080 × 2340 | [iPhone 13 mini](https://support.apple.com/en-us/111873), [iPhone 12 mini](https://support.apple.com/en-us/111877) |
| 1125 × 2436 | [iPhone 11 Pro](https://support.apple.com/en-us/111879), [iPhone XS](https://support.apple.com/en-us/111881), [iPhone X](https://support.apple.com/en-us/111864) |
| 1170 × 2532 | [iPhone 17e](https://support.apple.com/en-us/126470), [iPhone 16e](https://support.apple.com/en-us/122208), [iPhone 14](https://support.apple.com/en-us/111850), [iPhone 13 Pro](https://support.apple.com/en-us/111871), [iPhone 13](https://support.apple.com/en-us/111872), [iPhone 12 Pro](https://support.apple.com/en-us/111875), [iPhone 12](https://support.apple.com/en-us/111876) |
| 1179 × 2556 | [iPhone 16](https://support.apple.com/en-us/121029), [iPhone 15 Pro](https://support.apple.com/en-us/111829), [iPhone 15](https://support.apple.com/en-us/111831), [iPhone 14 Pro](https://support.apple.com/en-us/111849) |
| 1206 × 2622 | [iPhone 18 Pro](https://support.apple.com/en-us/148590), [iPhone 17 Pro](https://support.apple.com/en-us/125090), [iPhone 17](https://support.apple.com/en-us/125089), [iPhone 16 Pro](https://support.apple.com/en-us/121031) |
| 1242 × 2688 | [iPhone 11 Pro Max](https://support.apple.com/en-us/111878), [iPhone XS Max](https://support.apple.com/en-us/111880) |
| 1260 × 2736 | [iPhone Air](https://support.apple.com/en-us/125092) |
| 1284 × 2778 | [iPhone 14 Plus](https://support.apple.com/en-us/111854), [iPhone 13 Pro Max](https://support.apple.com/en-us/111870), [iPhone 12 Pro Max](https://support.apple.com/en-us/111874) |
| 1290 × 2796 | [iPhone 16 Plus](https://support.apple.com/en-us/121030), [iPhone 15 Pro Max](https://support.apple.com/en-us/111828), [iPhone 15 Plus](https://support.apple.com/en-us/111830), [iPhone 14 Pro Max](https://support.apple.com/en-us/111846) |
| 1320 × 2868 | [iPhone 18 Pro Max](https://support.apple.com/en-us/148591), [iPhone 17 Pro Max](https://support.apple.com/en-us/125091), [iPhone 16 Pro Max](https://support.apple.com/en-us/121032) |
| 1398 × 2034 | [iPhone Duo (outer)](https://support.apple.com/en-us/148588) |
| 1878 × 2670 | [iPhone Duo (inner)](https://support.apple.com/en-us/148588) |

## Viewport theo point và các phép thử bổ sung

Apple [HIG Widgets — Specifications](https://developer.apple.com/design/human-interface-guidelines/widgets#Specifications) công bố 10 kích thước dọc theo point dưới đây. Bảng hiện tại không gắn tên model cho từng hàng; không tự suy diễn mapping model từ bảng này.

| Point, rộng × cao |
| --- |
| 320 × 568 |
| 360 × 780 |
| 375 × 667 |
| 375 × 812 |
| 390 × 844 |
| 393 × 852 |
| 414 × 736 |
| 414 × 896 |
| 428 × 926 |
| 430 × 932 |

Bổ sung các viewport kỹ thuật 402×874, 420×912, 440×956 và tỷ lệ màn rộng tương ứng panel đã công bố. Đây là fixture thử bố cục; không nhận là thông số UIKit mặc định chính thức của từng model mới. Các phép thử tỷ lệ panel riêng cũng không nhận pixel là point.

Ví dụ vì sao không chia pixel cho DPR theo giả định: Apple ghi iPhone 8 Plus có bố cục 414×736 point, panel 1080×1920 pixel, UIKit scale 3 nhưng native scale khoảng 2,608. Nguồn: [Apple Displays, tài liệu lưu trữ](https://developer.apple.com/library/archive/documentation/DeviceInformation/Reference/iOSDeviceCompatibility/Displays/Displays.html).

## Preview

Video và poster bám `.screen` bằng absolute inset 0, cover ở giữa; không lấy chiều cao nội dung cuộn. Thiết bị cảm ứng có `(hover: none) and (pointer: coarse)` dùng toàn bộ viewport, kể cả chiều rộng lớn hơn 520px; dùng `100dvh` để cập nhật theo chiều cao hiển thị. Desktop có con trỏ chính xác giữ khung điện thoại mô phỏng. Đây là thay đổi responsive của preview; cấu hình orientation native không đổi: iPhone portrait, iPad có landscape.

## Bằng chứng và giới hạn

- `scratch/iphone-background-layout/apple-display-references.json`: URL, SHA-256 tài liệu Apple, bảng panel, point và phân biệt suy luận kỹ thuật.
- `scratch/iphone-background-layout/native-audit.json`: vị trí root, safe area, cập nhật bounds, cấu hình iOS/orientation và source hash; không thay mã Swift.
- `scratch/iphone-background-layout/browser-matrix.json`: kết quả browser cho cả hai clip, thay đổi viewport trên cùng video, DPR, Reduced Motion, scroll, màn rộng và desktop control.
- `scratch/iphone-background-layout/panel-aspect-matrix.json`: 15 nhóm tỷ lệ panel theo Apple × 2 clip, thử bằng 30 lần resize browser thực; đây là cửa sổ thử theo tỷ lệ, không phải kích thước UIKit chính thức của các model.
- `scratch/iphone-background-layout/verify-iphone-backgrounds.cjs`: harness đo browser local, không gọi Auth hoặc ghi dữ liệu backend.
- `scratch/iphone-background-layout/verify-panel-aspects.cjs`: harness bổ sung cho các tỷ lệ panel từ bảng tham chiếu.

Kết quả cuối: cả hai pha browser PASS, gồm 52 + 30 = 82 lần resize, 6 trường hợp DPR, poster Giảm chuyển động và 4 phép đo frame tiếp tục tăng; không lỗi JavaScript hoặc tải tài nguyên. Các phép thử bao phủ đủ 10 kích thước point Apple công bố và các viewport kỹ thuật bổ sung. SHA-256 file MP4 nguồn/bundle/preview trùng nhau; native source giữ nguyên hash của bản đã audit.

Browser đo HTML/Chrome với các viewport và thao tác resize mô phỏng; không thực thi SwiftUI/AVFoundation hoặc Display Zoom trên iPhone. Native source xác nhận chính sách adaptive; để xác nhận render, keyboard, hiệu năng và phát video trên thiết bị, vẫn cần build IPA và kiểm thử iPhone thật. Không suy từ kết quả browser thành chứng nhận mọi phần cứng hoặc FPS 60/120Hz.

Các file MP4 gốc, bundle và preview giữ nguyên bytes; không thay codec, độ phân giải, bitrate hoặc logic xác thực.
