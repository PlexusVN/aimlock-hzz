# Đồng bộ vòng đời thao tác và chẩn đoán từ Astra

Ngày 21/11/2026. Baseline Aimlock Hzz 2.4 (44), commit `a64c7a0fb6ec2a3873c8770430fcd735cdd61d30`. Bản mới: 2.4 (45).

Nguồn đối chiếu là project người dùng chỉ định trong `Astra-Full-Source-2.4-38-20261115`. Phần sửa được ghép theo logic tương ứng với Aimlock, giữ contract package generic của backend hiện tại.

## Lỗi công tắc sau OFF thất bại

Bản 44 có guard chặn nhận lại receipt khi còn nghĩa vụ restore. Tuy nhiên UI chỉ mở review khi inspection có `changedPaths`. Nếu target chưa đổi hoặc transaction đang prepared mà inspection trả danh sách rỗng, người dùng mắc ở OFF với lỗi lặp lại và không gọi được restore qua công tắc.

Đã tái hiện bằng thân hàm production: ba lần ON đều không mở review, không restore và giữ receipt. Bản sửa mở sheet xác nhận hiện có khi inspection thành công, kể cả không có changed paths. Sheet có lời giải thích riêng cho lần OFF chưa hoàn tất. Sau xác nhận, service kiểm receipt/snapshot/auth như trước, restore bình thường rồi apply. Hủy không ghi; thiếu receipt vẫn báo lỗi, không tạo baseline giả.

Regression lấy nguyên các action UI và service, có đối chứng âm dùng thân `togglePatch` cũ. Không thêm panel hoặc nút recovery riêng.

## Worker, progress và cancellation

- Service giữ task và trạng thái busy cho đến khi worker thực sự kết thúc.
- Card hiển thị bước thực: waiting, download, decode, target, access, write hoặc restore. Không tính phần trăm giả.
- Hủy trước commit giữ busy trong lúc worker dừng; thao tác thứ hai không được nhận khi worker trước còn sống.
- Cancellation được phân xử đồng bộ với commit reservation. Sau commit đầu tiên, quyền hủy không mở lại giữa restore và bước apply tiếp theo.
- Callback hủy gắn cả identity và operation UUID; callback của thao tác cũ không hủy thao tác mới trên cùng card.
- Cancellation có kiểu được giữ qua lỗi bọc; không chuyển thành chuỗi lỗi recovery hoặc thông báo OFF thành công.

## Chẩn đoán và thời gian tải

Ghép mã tĩnh DLxx để phân biệt JSON, metadata, grant, content envelope, base64, hash/size và descriptor mismatch. Mã không chứa key, token, ID hay path của người dùng.

`signed_manifest` và `signed_grant` phải là dictionary trước JSON serialization. Missing identity/context có nhóm lỗi riêng. `acceptSession` dùng thời gian HTTP Date + uptime đã được pinning xác thực, như phần grant đã có từ build 44. Không nới expiry, chữ ký, recipient/session/nonce hoặc retry content/grant một lần.

## Các phần được giữ theo Aimlock

Domain, product secret, public RSA key, TLS pin, Keychain/HWID và ticket recovery giữ cấu hình hiện tại. Core transaction, native engine, phạm vi quyền, OS/build routing, App Group entitlement và video không thay đổi.

Astra dùng variant `bundle:<BundleID>` cho một ứng dụng; Aimlock tiếp tục dùng `generic` và nhiều application target theo backend đã triển khai. Không thay contract này bằng cấu hình Astra.

## Kiểm chứng

Các nhóm mới chạy production bodies với boundary transport/OS cô lập: download diagnostics, trusted response time, worker/progress/cancellation và đường UI OFF → review → confirm. CI macOS chạy thêm CryptoKit, codec và filesystem tạm trước khi build IPA.

Chưa thử các thay đổi trên iPhone thật trong phiên này. Fixture và simulator không chứng nhận quyền App Group của IPA sau ký hoặc hành vi của mọi thiết bị. Không thể bảo đảm mọi lỗi đã hết chỉ bằng đồng bộ source.
