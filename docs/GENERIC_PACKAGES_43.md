# Aimlock Hzz 2.4 (43): đồng bộ package tổng quát

Backend hiện nhận package `.3105` có Bundle ID hợp lệ ngoài ba ứng dụng legacy. Build 43 bổ sung phần client tương ứng để gói mới xuất hiện trong danh mục, tải qua giao thức bảo vệ và được kiểm tra trước khi áp dụng.

## Hành vi

- Request sync đã ký gửi `package_targets: "bundle-identifiers-v1"`, gồm cả lần retry phiên hết hạn được phép. Backend chỉ trả package generic cho client khai báo capability này.
- Manifest/descriptor nhận variant `generic` khi kind là `package`. Native `mod/original` vẫn theo contract riêng; generic không được diễn giải thành native codepatch.
- Ứng dụng đích lấy từ project đã giải mã và xác minh; gói legacy vẫn phải khớp variant legacy. Package tổng quát kiểm Bundle ID, tập target và application container theo contract backend.
- Các kiểm tra chữ ký, hash, recipient, session, nonce, hạn grant, auth revision và network gate tiếp tục được thực hiện.
- Luồng chuẩn bị quyền và patch/restore hiện có tiếp tục xử lý từng container đích. Việc đọc được metadata hoặc nhận được package không chứng minh thiết bị có quyền truy cập file đó.
- Khi cùng mục catalog chuyển từ variant legacy sang generic, app chỉ tìm lại lịch sử của variant đã bị thay thế dựa trên catalog vừa đồng bộ có xác thực. Một lịch sử phù hợp được dùng cho restore/retry; nhiều lịch sử cạnh tranh phải dừng trước khi áp dụng. Các variant còn được publish không bị lấy nhầm backup.

## Phạm vi

Không thay native engine, bảng OS/build, App Group entitlement, key/HWID, domain, TLS pin, khóa xác minh server hoặc nội dung video. Không thêm giao diện mới. WQ04 do không ghi được App Group vẫn là điều kiện quyền thực tế của bản cài.

Các package cũ vẫn hoạt động với backend hiện tại. Build 42 cũ không khai báo capability, do đó backend tiếp tục lọc package generic khỏi danh mục của client đó.

## Kiểm chứng

Kiểm thử dùng production methods cho đồng bộ/retry và xác minh target, cùng fixture được ký/mã hóa bởi implementation backend hiện tại. CI macOS chạy cả fixture legacy và generic qua CryptoKit decoder. Các fixture filesystem dùng dữ liệu thử trong thư mục tạm; kết quả CI không thay cho chạy patch/restore trên iPhone thật.

Báo cáo cuối cùng và log build nằm trong workspace `scratch/app-generic-sync-20261116/`.
