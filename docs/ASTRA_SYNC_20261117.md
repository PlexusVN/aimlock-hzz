# Đồng bộ sửa lỗi Astra vào Aimlock Hzz

Ngày 17/11/2026. Mốc Aimlock trước đồng bộ: 2.4 build 43. Bản phát hành sau đồng bộ: 2.4 build 44.

## Kết quả đối chiếu

Aimlock đã có các hardening transaction và recovery lớn của Astra: journal/provenance schema 3, backup trước ghi, FD/ownership, final read-back, snapshot confirmation, catalog association, HWID/identity recovery và target generic. Những file này không bị thay toàn bộ từ Astra để tránh làm mất branding, SQLite/Auth riêng và các bảo vệ bổ sung đã có.

Hai khoảng cách có bằng chứng được đồng bộ:

1. **Thời gian grant tải.** Thêm `ProtectedResponseTime`: chỉ nhận HTTP `Date` từ phản hồi đã qua system trust/TLS pin, cộng RTT và một giây độ phân giải header theo hướng bảo thủ, rồi dùng system uptime để tính ngày xác minh. Grant không được gia hạn; lỗi clock tương ứng chỉ bớt false negative khi iPhone lệch vài giây.
2. **Bật lại sau OFF lỗi.** Thêm `disabledPendingRestore` và `requirePatchEnableAllowed`. Khi restore OFF thất bại, lần ON tiếp theo bị chặn trước tải/ghi/adopt receipt. Người dùng vẫn dùng existing restore review để kiểm snapshot và xác nhận. Confirmation hợp lệ đi qua bước này rồi tiếp tục các guard receipt/auth/bytes hiện có.

Các sửa đã giữ nguyên auth revision, grant/session/nonce, chữ ký RSA, ECDH/HKDF/AES-GCM, hash, TLS pins, server/domain/product secret và thứ tự 3105 → worse_query → AirLift. Không copy cấu hình Astra hoặc namespace kỹ thuật mù quáng.

Package target tùy ý của Astra build 39 đã có trong Aimlock build 43 dưới contract `generic` của Auth, gồm nhiều application Bundle ID và lưu giữ recovery alias. Không đổi sang tên variant `bundle:<BundleID>` của Astra để giữ đồng bộ với backend SQLite đã triển khai.

Astra còn có một mô hình progress/cancel theo từng stage cho catalog và patch. Aimlock đang dùng operation state/action task riêng của giao diện hiện tại; luồng busy, cancellation và auth revision đã được kiểm tra trong suite build 43. Phần này không được thay wholesale vì sẽ đổi UI/interaction của Aimlock.

## Kiểm thử

- Catalog recovery sau thêm guard: chạy production body trên filesystem tạm; test ON sau OFF lỗi phải bị chặn, restore rõ ràng rồi ON mới được phép.
- `ProtectedResponseTime` kiểm ngày HTTP hợp lệ, ngày hỏng, ngày quá dài, RTT và tiến trình theo uptime. CryptoKit fixture legacy/generic vẫn dùng schema/keys hiện tại.
- Các nhóm transaction 122 filesystem, 83 provenance, catalog/target generic và identity/session vẫn giữ kết quả của build 43. Đây là dữ liệu kiểm trước đồng bộ; build 44 sẽ chạy lại toàn bộ trên CI.

## Giới hạn

Chưa có iPhone thật trong phiên này để chạy Secure Enclave/Keychain/containermanagerd hoặc patch/restore game thật. CI macOS và fixture filesystem kiểm control flow, không chứng nhận mọi iOS/SoC/profile.

