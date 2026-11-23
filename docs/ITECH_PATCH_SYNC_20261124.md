# Đồng bộ luồng patch/restore iTech — build 54

Nguồn người dùng: C:/Users/Khai/Desktop/kk/itech/itech. Đã đối chiếu iTech/iOS và Nova IOS 27/NovaX; thư mục iOS ngoài không có source file được liệt kê. Baseline Aimlock d3df4a8.

## Phạm vi

Chỉ thay chính sách chọn provider cho phạm vi mới và bước xin quyền container dùng chung bởi patch/restore. Không thay giao diện, auth, crypto, server, catalog, cấu hình sản phẩm hoặc Bundle ID của payload.

| Nhánh | Đối chiếu và áp dụng |
| --- | --- |
| 3105 | iTech vẫn dùng resolve Bundle ID → container root → grant → backup/journal → ghi → read-back. Giữ routing hiện có và root do gói khai báo. Giữ kiểm identity/UUID mới của Aimlock. |
| worse_query cũ | Cùng API xin handle, App Group runtime, lỗi daemon và release. Giữ phạm vi 26.6.2–26.7.2 và 27.x tới 27.2.0 theo policy hiện tại; 3105 ưu tiên với các build tương ứng. |
| Cao hơn worse_query cũ | Ghép nguyên Viet99BQCore.m/.h và MIT notice từ iTech. Phạm vi ứng viên 27.2.1–27.3.x; cấp quyền class13 → class7 hiện có → class12. Chỉ exact application data root UUID; không ghi target trong adapter. Phải có App Group thực, chạy worker, tiêu thụ token và đọc directory thành công. |
| Apply/restore | Cả hai gọi WorseQueryHelper.acquireAccess trong preparation và giữ handle qua PreparedPatchAccess. Identity, dev/inode, exact root được kiểm trước commit. Không thay transaction core bằng bản iTech dùng đường dẫn FileManager. |
| Backup/restore | Giữ journal/hash/atomic I/O và final read-back. File do patch tạo mới được xóa khi OFF nếu không thuộc patch sau còn ON. Giữ bảo vệ lịch sử container cũ của build 53. |
| AirLift | Cả source Nova IOS 27 và Aimlock đều không có remote read/delete trong ABI. Không chuyển AirLift sang báo restore thành công giả. |

## Kiểm chứng

Test boundary matrix cập nhật 268 assertions; kiểm resolver bao gồm container chưa chuẩn bị bị chặn ở phạm vi mới. Thêm test dùng nguyên adapter Objective-C với native/filesystem giả lập, kiểm thứ tự chiến lược, scope, ownership và cleanup trên macOS. Wrapper fixture giữ kiểm release và lỗi của nhánh cũ.

Phạm vi 27.2.1–27.3.x được chính source iTech coi là candidate/thử nghiệm. Source và mock test không chứng minh daemon thực tế sẽ cấp quyền trên mọi build iOS; app chỉ tiếp tục sau khi preparation/read/identity thành công. Chưa thử iPhone thật trong lượt này.
