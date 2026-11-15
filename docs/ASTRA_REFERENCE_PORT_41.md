# Áp dụng luồng tham chiếu vào Aimlock Hzz — build 41

Nguồn tham chiếu do người dùng chọn: `Astra-Full-Source-2.4-38-20261115/Astra-Full-Source-2.4-38`, app tại `Astra-Fixed/Astra-Full-Source-1.2.10-16/client/NovaX`. README gói xác định commit tham chiếu `7f416a6c2733b1f053846f057fa86b8ebc05f406`. IPA trong gói có SHA-256 `7c58a0cd9cbf9150bc6d2c99001d4563339627fd620f42258589a526a30fa1cc`, đã đối chiếu khớp manifest. File tham chiếu được đọc, không sửa.

## Phần áp dụng

| Phần tham chiếu | Áp dụng vào Aimlock Hzz |
| --- | --- |
| Journal schema 3 | Journal prepared đầu tiên giữ provenance bất biến của engine/operation/targets. Đọc sidecar thiếu/cũ chỉ phục hồi từ journal đúng binding và predecessor đã kết thúc; lịch sử AirLift/mâu thuẫn vẫn bị chặn |
| Cap metadata | Reader/writer có chung giới hạn record/journal; kiểm trước backup hoặc ghi target để tránh tạo record mà chính reader không đọc được |
| Restore read-back | Xác minh hash target sau copy hoặc ENOENT thật sau xóa trước khi commit restored; rollback và backup còn khi verify lỗi |
| Bundle-ID lookup | Lazy target lookup tra đường dẫn đúng Bundle ID bằng API không activate extension legacy, rồi fresh worse_query grant và kiểm tra đọc. Thiếu xattr/metadata có thể dùng bằng chứng lookup hệ thống; định danh mâu thuẫn luôn bị từ chối |
| Anonymous/cache UUID | Vẫn cần identity độc lập; đường dẫn cũ không trở thành quyền hoặc bằng chứng game đích |
| Grant transaction | Kiểm target lại dưới grant của chính transaction; metadata thiếu phải có lookup hệ thống mới khớp root, không tin UUID cũ |
| Requested OFF | Lựa chọn gắn với journal/operation tương ứng; sửa sidecar của cùng journal không mất OFF, transaction mới không thừa kế OFF cũ |
| Startup probe | Bỏ tạo/xóa file thử trong Documents. Quyền ghi được kiểm khi transaction thực hiện |

Không copy đè toàn project: giữ các bảo vệ đang có của Aimlock Hzz như directory FD, prewrite marker, confirmation snapshot, permit/cancellation, ownership thư mục và intent theo phiên. Không thay Auth, domain, secret, RSA/TLS, SQL/server hoặc luồng recovery định danh bằng cấu hình của project tham chiếu.

## Yêu cầu giao diện được giữ

- Không đưa lại khối “Khôi phục dữ liệu” hoặc thêm mục giao diện mới.
- Quét worse_query ban đầu tổng quát, không yêu cầu game đã cài hoặc game identity. Target được xác minh khi thực sự dùng chức năng.
- Tắt lỗi báo lỗi và công tắc OFF; backup/journal không bị xóa. Lần bật sau xác minh lại receipt cũ hoặc phục hồi an toàn trước khi áp dụng mới; không lấy file đang patch làm backup mới.
- worse_query tiếp tục trước AirLift trong policy; danh sách version/build không mở rộng.
- Video nền, chất lượng file và phát lặp giữ nguyên.

## Tên và tương thích

Tên hiển thị, thông báo, DNS profile và pairing host dùng Aimlock Hzz. Product/executable bundle đổi thành `AimlockHzz`; display name là `Aimlock Hzz`.

Các định danh cũ nằm trong hợp đồng dữ liệu/giao thức cần giữ: key ID RSA, protocol/HMAC/AAD/version strings, header API, Keychain/HWID prefix, preference/history/notification keys, App Group đã được profile ký cấp quyền và native ABI symbol. Thay chúng riêng lẻ có thể làm Auth hoặc dữ liệu cũ không đọc được. Ghi công source gốc và tên tài liệu tham chiếu vẫn giữ đúng nguồn.

Danh sách rà soát và lý do giữ từng nhóm nằm ở `scratch/astra-reference-port-20261115/branding-report.json` trong workspace. Không dùng đổi tên toàn bộ văn bản để thay định danh giao thức hoặc native symbol.

## Kiểm chứng và giới hạn

Các regression sử dụng source transaction/preparation thật với filesystem tạm, SwiftCrypto/CryptoKit và boundary fixture cho API hệ điều hành; macOS CI tiếp tục chạy native bridge test và build Xcode. Không thực thi trên container game thật trong môi trường Windows.

Kết quả build không thay thế kiểm tra IPA sau ký trên iPhone. Phần lookup/grant phụ thuộc entitlement, App Group, daemon và OS/build thực tế; lời xác nhận của người dùng về bản tham chiếu được coi là nguồn lựa chọn triển khai, không biến mọi môi trường chưa thử thành đã được chứng nhận.
