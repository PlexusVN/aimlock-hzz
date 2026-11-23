# Đối chiếu patch và bảo mật ngày 24/11/2026

Nguồn: Astra-Full-Source-2.4-38-20261115/Astra-Full-Source-2.4-38/Astra-Fixed/Astra-Full-Source-1.2.10-16/client/NovaX. PROJECT_STATUS của source này có cập nhật tới 2.4 (40), dù thư mục ngoài ghi 38. Baseline Aimlock: 55042b1, build 52.

## Kết quả đối chiếu

| Nhóm | Kết quả và quyết định |
| --- | --- |
| Package codec | PatchPackageCodec giống nguồn tham chiếu theo LF; giữ giải mã, kiểm package, path và giới hạn dữ liệu. |
| Giao dịch direct | Giữ validate → backup/hash → journal prepared → atomic write → read-back → applied. Aimlock bổ sung pinned directory descriptors, kiểm container, rollback và final restore read-back. |
| Restore độc lập | Giữ yêu cầu patch bật sau ghi đè, OFF trước không xóa file của patch sau. Khi tất cả OFF, truy ngược đến baseline ban đầu, xóa nếu trước đó không có file. |
| Bổ sung build 53 | Lịch sử để truy baseline phải cùng containerFingerprint. Bỏ journal rolledBack; dừng chuỗi khi payload của giao dịch xen giữa không khớp baseline. Tránh lấy lịch sử của container cũ có cùng Bundle ID/path/bytes để xóa file gốc trong container mới. |
| Executor và native access | Giữ timeout chuẩn bị, worker sống tới completion, commit gate, hạn ghi và rollback an toàn của Aimlock. ContainerStore hiện có thêm kiểm cache/UUID/grant so với source tham chiếu. |
| Signature, nonce, session, crypto | Giữ giao thức ký, ràng buộc recipient/session/nonce/artifact/grant, AEAD, hash/size và expiry. ProtectedArtifactDecoder khác ở capability generic theo backend Aimlock; NetworkAccessGate, AntiTamper, ReleaseIntegrity giữ logic nguồn tham chiếu. |
| Identity | Không nhập nhánh Astra tự resetIdentity khi enrollment conflict; Aimlock giữ khóa và quy trình recovery có quyền để tránh mất định danh. |
| Thời gian | Giữ HTTP Date từ TLS đã xác thực và uptime; không lấy issuedAt chưa xác minh làm đồng hồ fallback. |
| Cấu hình sản phẩm | Giữ domain, RSA public key và TLS pin của Aimlock. Giữ generic package nhiều target theo server đã triển khai; không chuyển sang bundle: đơn target của Astra. |
| Local integrity | Cả hai source đặt localIntegrityEnforced=false cho sideload. Đây không phải chứng nhận chống chỉnh sửa binary; server vẫn kiểm key/proof/session và dữ liệu mã hóa. Không tự bật để tránh đổi chính sách ký app. |
| AirLift | ABI hiện tại chỉ ghi, không có remote read/delete; giữ lỗi restore không hỗ trợ và không báo OFF giả. |
| Backend | Chạy 172 test contract/security hiện tại: tất cả pass, gồm chữ ký, AEAD, proof, grant, generic package, recovery, logout và hạn reset HWID. Không thay backend/VPS trong lượt này. |

## Kiểm chứng

Thêm test filesystem thật: lịch sử patch đã OFF trong container cũ có payload trùng original container mới không được dẫn tới xóa original của container mới. Các regression chồng patch và xóa file mới tiếp tục chạy trong CI macOS trước build IPA. Test fixture không chứng nhận quyền native hoặc hành vi trên iPhone thật.
