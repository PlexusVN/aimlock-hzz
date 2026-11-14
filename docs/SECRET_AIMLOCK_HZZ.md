# Secret sản phẩm của app Aimlock Hzz

Secret sản phẩm hiện tại là **`aimlock-hzz`**, khai báo một lần tại `ThreeOneOSFive/helpers/AppSecurityConfiguration.swift`.

`AuthManager` dùng cấu hình này cho cả đăng nhập và xác thực lại, bao gồm nội dung POST và HMAC kiểm tra phản hồi. `FeaturePatchService` cũng đọc cùng giá trị cho luồng danh mục/phân phối được bảo vệ. Không còn literal secret sản phẩm cũ trong Swift/C/Objective-C runtime của app.

Chỉ đổi giá trị cấu hình sản phẩm; giữ nguyên domain `https://aimlockhzz.site`, certificate pins đã xác minh, public RSA key của VPS, key ID, khóa P-256 thiết bị, HWID/dự phòng, định dạng request, nonce/counter, HMAC, chữ ký và quyền tải hiện có. Phía backend và sản phẩm trên database cần dùng cùng secret; kết quả kiểm tra key thật thuộc phần triển khai backend, không suy ra từ một bài kiểm tra app local.

**Cần build/ký IPA mới từ source hiện tại.** IPA cũ còn secret nhúng cũ, dù domain hoặc giao diện server đã thay đổi. Chưa chạy Xcode hoặc thử iPhone thật trong lượt cập nhật cấu hình này.

Snapshot và kết quả kiểm tra local được ghi tại `scratch/secret-aimlock-hzz/app-before` và `scratch/secret-aimlock-hzz/app-verification.json` trong thư mục gốc workspace. Các kiểm tra portable xác nhận cấu hình và builder request, không mô phỏng Apple Keychain/SecTrust hoặc thay thế kết quả trên thiết bị.

## Kết quả local

- Liên kết license3/3, security/build6/6 và security flow7/7 đều qua.
- Biên dịch/chạy `LicenseVerificationSelfCheck.swift` hiện có với source production thực trên Ubuntu: qua.
- Harness Swift dùng chính `AppSecurityConfiguration` và builder thật xác nhận JSON POST mang secret `aimlock-hzz`, giữ đúng key/HWID/deviceName và endpoint HTTPS: qua, không phát request mạng.
- Swift frontend parse và offline production configuration gate: qua.
- Diff runtime là đúng một dòng cấu hình secret; tất cả file Swift runtime khác và toàn bộ TLS/RSA public configuration giữ nguyên bytes.
