# HWID dự phòng khi iOS chưa trả IDFV

App đọc IDFV qua `UIDevice.current.identifierForVendor`. IDFV và HWID ứng dụng không phải UDID phần cứng của iPhone.

Luồng hiện tại:

1. Dùng UUID đã lưu hợp lệ trong Keychain.
2. Nếu bản Keychain không dùng được, dùng UUID hợp lệ còn lại trong bản lưu local được bảo vệ.
3. Khi cả hai kho đã đọc thành công và xác nhận chưa có định danh, dùng IDFV hợp lệ nếu iOS trả về.
4. Nếu lần khởi tạo mới này chưa có IDFV, tạo một UUID dự phòng, lưu và đọc kiểm chứng trước khi trả cho luồng đăng nhập.

UUID dự phòng chỉ được tạo trong trường hợp khởi tạo mới. Những lần mở sau dùng đúng UUID đã lưu, kể cả IDFV xuất hiện sau đó hoặc khác với lần trước. Không sinh một HWID khác mỗi lần mở app. Nếu Keychain không ghi được nhưng vẫn xác nhận chưa có dữ liệu, app có thể dùng bản local đã ghi và đọc kiểm chứng thành công.

Không có UUID nào được tạo để thay thế dữ liệu đã tồn tại nhưng hỏng, hai bản UUID khác nhau hoặc trạng thái kho không thể xác định do lỗi đọc. Các trường hợp này giữ cách báo lỗi/khôi phục hiện có. Khi một UUID cũ hợp lệ còn tồn tại, ưu tiên UUID đó và giữ đúng biểu diễn đã đăng ký.

Chỉ phần định danh công khai có dự phòng local. Khóa riêng P-256, phiên và chữ ký yêu cầu vẫn dùng cơ chế bảo vệ/xác thực hiện có. Không bỏ qua lỗi khóa riêng hoặc điều kiện recovery trên server. Nếu xóa toàn bộ dữ liệu định danh của app và Keychain, không thể hứa khôi phục cùng mã dự phòng chỉ từ thông tin model máy; cần xử lý quyền thiết bị theo luồng hiện có.

Thay đổi nằm trong `views/SecurityUtils.swift`, enum `StableDeviceHWID` và lời gọi `DeviceUtils.resolveHWID`. Không đổi endpoint, schema SQLite, storage tag `deviceHwid`, nội dung key hoặc các bước enrollment.

Kiểm tra dùng chính policy Swift production được trích và biên dịch trên Ubuntu, boundary Keychain được giả lập, có tình huống lưu file local thật và mở lại. Điều này kiểm chứng thuật toán và luồng retry; chưa thay cho build Xcode và thử quyền Keychain trên iPhone thật.

## Kết quả kiểm tra

Đã biên dịch và chạy policy Swift thật trên Ubuntu: **123 assertions PASS**, gồm 16 tác vụ đồng thời chỉ cấp một UUID, lưu file thật/mở lại, dữ liệu hỏng/xung đột, lỗi đọc/ghi và IDFV xuất hiện muộn. Python runner 2/2 bài qua; kiểm tra liên kết license 3/3 và cấu hình bảo mật 6/6 qua; Swift frontend parse qua. Chỉ một file runtime Swift được sửa. Báo cáo local nằm tại `scratch/hwid-fallback/verification.json` trong thư mục gốc workspace. Chưa build IPA hoặc xác nhận Keychain trên iPhone thật.
