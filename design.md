# Aimlock Hzz — giao diện app và web Auth

Thiết kế theo yêu cầu đổi nhận diện sang Aimlock Hzz, dùng ảnh `Aimlock-hzz.jpg` ở thư mục gốc. Phạm vi là phần trình bày của app SwiftUI, web Auth và bản HTML xem trước.

## Nhận diện và màu sắc

| Thành phần | Giá trị |
| --- | --- |
| Tên hiển thị | Aimlock Hzz |
| Tiêu đề splash/login | AIMLOCK HZZ |
| Nền | `#171819` |
| Thẻ | `#222426` |
| Input/nền phụ | `#1B1D1F` |
| Chữ chính | `#F5F5F4` |
| Chữ phụ | `#B6B8BC` |
| Viền | `#3A3D41` |
| Nút chính | Trắng bạc, chữ xám đậm |

Màu trạng thái xanh/đỏ/vàng chỉ dùng để phân biệt thành công, lỗi và cảnh báo. Không thêm các tuyên bố bảo mật hoặc hiệu năng từ ảnh tham khảo vào trạng thái thật của ứng dụng.

## Bố cục và chữ

- Thẻ chính bo 12 pt; nút chính/input bo nhẹ, khoảng 8 pt. Thanh tab bo 14 pt, mục đang chọn bo 8 pt.
- iOS dùng San Francisco mặc định; số liệu kỹ thuật dùng monospaced. Web dùng system font hỗ trợ tiếng Việt, không yêu cầu tải font từ dịch vụ ngoài.
- Splash đặt logo, tên và bảng tiến trình cùng một cụm trung tâm. Login giữ trường license, HWID, thông tin thiết bị và các thao tác hiện có.
- Màn hồ sơ đặt tên, phiên bản và trạng thái cùng cột để tên mới không bị ép trên điện thoại hẹp.
- Web Auth dùng cùng nền, màu, logo và nút; bảng rộng cuộn trong vùng bảng trên điện thoại.

## Logo và icon

- Logo trong app giữ asset key `NovaXLogo` để các tham chiếu hiện hữu tiếp tục hoạt động; hình ảnh của asset đã thay bằng logo Aimlock Hzz.
- `AppIcon.appiconset` chứa icon PNG RGB không trong suốt cho iPhone/iPad và bản 1024 px. iOS tự áp dụng mặt nạ ngoài màn hình chính.
- Web Auth dùng `aimlock-hzz.png`; bản HTML xem trước dùng `assets/app-icon.png` lấy từ cùng asset iOS.

## Chuyển động

- Dùng animation native của SwiftUI: spring nhẹ khi nhấn/chọn tab, opacity cho chuyển nội dung và reveal ngắn. Không thêm vòng lặp cập nhật theo frame.
- `CADisableMinimumFrameDurationOnPhone = true` cho phép hệ thống sử dụng tốc độ làm tươi cao trên iPhone hỗ trợ. Không ép tốc độ cố định; hệ thống vẫn quyết định theo thiết bị và chế độ nguồn.
- Respect Reduce Motion trong toàn bộ cây SwiftUI và `prefers-reduced-motion` trên web. Khi bật, tắt chuyển động dịch chuyển/phóng to và rút gọn hiệu ứng.
- Chưa đo FPS hoặc thử trên iPhone thật. Bản HTML không chứng minh hiệu năng SwiftUI.

## Ranh giới thay đổi

Giữ nguyên bundle identifier, phiên bản/build, storage key, notification name, API, endpoint, logic license/HWID, mã hóa, DB, engine, tác vụ ghi/khôi phục và điều kiện pairing. Những identifier chứa Astra/NovaX vẫn được giữ khi là hợp đồng nội bộ. Tên thiết bị được dịch vụ ghép đôi quảng bá vẫn là Astra; hướng dẫn `Pair with Astra` giữ đúng tên thật của dịch vụ.

`Aimlock Hzz-WebPreview/sync-source.py` đồng bộ thông tin và ảnh từ `Astra-Fixed/Aimlock Hzz`. Bản xem trước dùng dữ liệu minh họa, không xác thực hoặc thao tác với game thật.

## Kiểm chứng

Kết quả kiểm tra của lần thay đổi này được ghi trong `GIAO_DIEN_AIMLOCK_HZZ.md` tại thư mục gốc dự án. Windows hiện tại không có Xcode/SwiftUI toolchain; cần build và thử iPhone để xác nhận IPA và độ mượt thực tế.

## Bố cục cập nhật 14/11/2026

Tab Chức năng và thẻ chức năng dùng `AimlockReticleIcon`, tâm ngắm vector đồng nhất trên app và preview. Danh mục dùng ảnh game 44 pt, thẻ chọn rõ thứ bậc và số đếm lấy từ danh mục hiện tại. Hồ sơ dùng avatar 56 pt, tên 22 pt, cụm license/HWID và lưới thông tin hai cột, hàng cập nhật và đăng xuất gọn.

Đã gỡ dữ liệu và giao diện hai liên hệ quản trị viên cá nhân khỏi toàn app. Đã bỏ nút Cộng đồng cùng modal liên quan khỏi màn login theo yêu cầu mới. Web Auth gỡ tab Patch Android và Quản lý Mod khỏi điều hướng; backend/API của các phần đó không bị sửa.

## Sửa logo splash → login

Logo chuyển động dùng một overlay112pt tồn tại liên tục; hai slot112/92 được đo trước intro. Trong0.74giây sau lead-in0.08giây, một clock nội suy quartic in-out điều khiển cả tâm và scale, theo đúng preview GSAP power3.inOut. Chỉ hiện logo92 inline khi kết thúc, bàn giao không animation. Không dùng matchedGeometry giữa hai ảnh có frame cố định khác nhau. Task hủy khi view biến mất; Giảm chuyển động bỏ flight. Báo cáo đối chiếu nằm tại `scratch/splash-morph-fix/verification.json` ở gốc workspace. Chưa xác nhận render trên iPhone hoặc build Xcode.

## Video nền theo file gốc

Splash/login dùng `login-backgroud.mp4`; giao diện sau xác thực dùng `app-backgroud.mp4`. Một player native chung, muted/loop, pause khi app không active, Giảm chuyển động dùng poster nguồn. MP4 được giữ nguyên bytes/codec/độ phân giải/fps. Video và poster dùng aspect-fill/cover ở mức phóng nhỏ nhất đủ phủ kín màn hình, không thêm scale, không tạo hai dải trống trên/dưới và không kéo méo hình. Mép nguồn có thể bị cắt tùy tỷ lệ màn hình. Có lớp phủ tối cho chữ. Chi tiết metadata/hash và phạm vi kiểm tra xem `docs/VIDEO_BACKGROUNDS.md`. Nền video thay gradient tĩnh trước đó trong app thật; standalone preview của từng View vẫn có gradient dự phòng.
