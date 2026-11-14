# Aimlock Hzz — tên miền Auth và trust của app

Source app đã được đồng bộ sang `https://aimlockhzz.site`, VPS người dùng chỉ định là `130.94.8.45`. Trạng thái triển khai origin/backend được kiểm tra riêng; báo cáo này mô tả chính xác phần app và chứng chỉ public đã xác minh.

Secret sản phẩm hiện đã cập nhật tiếp sang **`aimlock-hzz`** theo yêu cầu riêng sau lượt triển khai domain. Xem `SECRET_AIMLOCK_HZZ.md`; ghi chú giữ nguyên product secret bên dưới mô tả riêng lượt đổi tên miền trước đó.

## Địa chỉ sử dụng

`AppSecurityConfiguration.apiOrigin` và `apiHost` là nguồn cấu hình cho API. Auth, danh mục/patch, hướng dẫn, cấu hình NextDNS/cập nhật và probe kết nối đều lấy origin/host từ cùng cấu hình. `Nova-logo.png` giữ nguyên đường dẫn để probe HEAD không thay hợp đồng server. Swift runtime không còn API/hướng dẫn/config/probe trỏ `zynox.click`.

Không đổi bundle identifier, storage tag, HWID đã lưu/dự phòng, khóa riêng P-256 trên thiết bị, product secret, signed request, quyền tải patch hoặc engine trong lượt đổi tên miền.

## Chứng chỉ TLS public đã xác minh

Ngày 14/11/2026, script `scratch/domain-aimlockhzz/app/verify_public_tls.py` kết nối `aimlockhzz.site:443` bằng `ssl.create_default_context`, xác minh hệ thống và hostname bình thường, không dùng insecure context hoặc chấp nhận chứng chỉ tùy ý.

- Leaf CN `aimlockhzz.site`, SAN gồm apex và `*.aimlockhzz.site`, issuer Let's Encrypt YE2, hạn `Feb 12 09:25:48 2027 GMT`.
- Leaf DER SHA-256 Base64: `SjzSZU44vxnR21HP6KwHfgfMQGx76tNxVt9eliXroMk=`.
- Intermediate YE2 DER SHA-256 Base64: `l2WN6MaN+pis4eUCimPVShqukRs+IUcQdsaFDNCMurQ=`.
- Các certificate Root YE/X2 cross-signed xuất hiện trong chain không được đưa vào allowlist.
- TLS1.3 mặc định và TLS1.2 ECDSA đều được xác minh với cùng chain. RSA-only TLS1.2 handshake không được edge hỗ trợ trong lần đo; không thêm pin dự phòng chưa xác minh.

Pin là hash của toàn bộ certificate DER, **không phải SPKI**. App vẫn yêu cầu cả xác minh hệ thống/hostname và ít nhất một pin trong allowlist. Không thêm fallback bỏ qua pin. Khi Cloudflare đổi issuer/chain, cần xác minh chain mới và cập nhật app theo quy trình phát hành.

Certificate public/chain JSON được lưu tại `scratch/domain-aimlockhzz/app/tls`; đó là dữ liệu public, không chứa private key. Xác minh public Cloudflare edge không tự chứng minh HTTPS từ Cloudflare tới origin VPS; phần đó được kiểm tra trong triển khai server.

## Khóa ký phản hồi mới trên VPS mới

VPS mới không có private RSA key tương ứng public key app cũ. Trong lượt triển khai mới, root tạo một khóa RSA bền vững riêng trên VPS tại `/opt/aimlock-hzz-auth/keys/rsa_private.pem`, không ghi đè khóa cũ và không tải private key xuống workspace.

Public key kiểm chứng từ `scratch/domain-aimlockhzz/signing-public.json` đã được cập nhật vào `AppSecurityConfiguration`; `ServerSignatureVerifier` dùng cùng cấu hình để không giữ keyring cũ riêng. Fingerprint SHA-256(PKCS#1 DER) là:

`d54126c8056e968935e0269624a6c53dc1ed345e5a0c62bfeb9dfaea3040bfe4`

Key ID giữ `astra-rsa-2026-01` theo hợp đồng giao thức hiện có. Backend pin kiểm tra startup được root cập nhật đồng bộ. Các public golden fixture mã hóa có signer test riêng giữ nguyên; chúng không được dùng làm trust runtime. Release offline/seal defaults được cập nhật theo public fingerprint mới.

**Cần build/ký IPA mới từ source hiện tại.** IPA cũ vẫn trỏ domain/trust cũ, không được coi là tương thích với server mới chỉ nhờ thay DNS. Không có private key nào được đưa vào app hoặc source.

## Kiểm tra local

- Liên kết bảo mật/build: 6/6 qua.
- Liên kết xác thực/license: 3/3 qua.
- Security flow wiring: 7/7 qua.
- Policy HWID production được biên dịch/chạy trên Ubuntu: 123 assertions qua, bytes phần policy giữ nguyên.
- Swift frontend parse các file cấu hình/transport liên quan: qua.
- Certificate pin self-check Swift: leaf/YE2 được chấp nhận, pin user/unknown/root-only/domain cũ bị từ chối.
- Offline production configuration gate: qua với origin, signer và pin mới.

Các kiểm tra portable không phải build Xcode, không thực thi Apple SecTrust/Keychain thật và không thay việc chạy IPA trên iPhone. Chưa build IPA hoặc kiểm tra thiết bị thật trong phần công việc này. Snapshot/diff/hash và báo cáo `verification.json` nằm tại `scratch/domain-aimlockhzz/app`.
