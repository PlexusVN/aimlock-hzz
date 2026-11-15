# Hoàn tất các điểm so sánh — Aimlock Hzz 2.4 (42)

Baseline trước sửa là build 41, commit `1ede67da4dfb518d197e915554abea825bf93791`. Bản Astra tham chiếu do người dùng chọn nằm trong `Astra-Full-Source-2.4-38-20261115/Astra-Full-Source-2.4-38`. Source tham chiếu không bị sửa.

## Các điểm đã xử lý

| Mã báo cáo | Thay đổi |
| --- | --- |
| A01 | Ghép policy normalize/latch lỗi khóa Secure Enclave đã lưu đúng như reference. Chỉ corruption xác định mới vào recovery có quyền; locked, entitlement, communication và cancellation giữ nguyên nghĩa |
| A02 | Lỗi missing/invalid của archive legacy toàn cục không chặn scope license khác. Không xóa archive hoặc tự cấp quyền recovery |
| A03 | Lỗi identity local khi tải hủy cached session đúng context; lần thao tác rõ ràng tiếp theo mới bootstrap. Không tự replay grant/content một lần |
| A04 | Lần ON sau OFF lỗi có thể tới inspection và bảng xác nhận sẵn có qua chính công tắc. Xác nhận hợp lệ mới restore và bật lại trong cùng gate; hủy giữ OFF; không thêm panel/nút recovery |
| A05 | Migrate `_disabledBinding` của reference chỉ khi trùng active project+journal/operation, gồm legacy slug. Binding cũ không đổi OFF của transaction mới |
| A06 | Exact Bundle-ID lookup mới có ưu tiên hơn hint/cache vô danh; không bỏ qua identity mâu thuẫn hoặc hai exact target cùng root. General scan rỗng có thể chứng minh khả năng scoped-read qua UUID container của chính app bằng grant và directory read thật, không yêu cầu game |
| A07 | Journal mới lưu tập explicit directories và fingerprint; xác minh lại cả tập và loại/trạng thái directory. Legacy journal dùng provenance đúng binding để suy target set, không tự nhận directory mất là applied |
| A08 | Tách clock-not-yet-valid và grant-expired theo reference; điều kiện chữ ký, binding, nonce và hạn không nới lỏng |
| A09 | Fallback HWID riêng tương thích reference, chấp nhận prefixed identity cũ, giữ nguyên UUID hợp lệ đang lưu của Aimlock. Không đổi sang IDFV mới, không sinh identity khi chưa đọc rõ stores, identity hợp lệ mâu thuẫn vẫn chặn |
| A10 | Sửa UTF-8 của mô tả quyền Local Network; kiểm lại source/IPA |

## Đồng bộ và khác biệt được giữ

Các phương thức recovery identity/download quan trọng khớp reference; bảng OS/build và ưu tiên 3105 → worse_query → AirLift giữ nguyên. Không thay native primitive, kernel offset, server, SQL, domain, product secret, RSA/TLS hoặc giao thức mã hóa.

Giữ các yêu cầu riêng của Aimlock: giao diện hiện tại, không có khối recovery, initial scan không cần game và OFF lỗi báo lỗi + toggle OFF. Backup/journal không bị xóa khi công tắc tắt. Re-enable xác minh receipt cũ hoặc restore an toàn trước apply mới, không lấy payload đang patch làm baseline mới.

Core vẫn giữ pin directory FD, prewrite marker, permit/cancellation, ownership thư mục, snapshot confirmation và final read-back. Hệ thống không khóa được mọi thay đổi của tiến trình game bên ngoài; lịch sử/backup bị mất hoàn toàn không thể được tái tạo bằng đổi trạng thái công tắc.

## Tái so sánh và kiểm chứng

Các ca đã tìm thấy ở build 41 được chạy lại trên source sửa bằng production bodies, filesystem tạm và boundary fixture. Các trường hợp identity dùng reference policy, cùng các negative case locked/entitlement/transient/cancel; các migration gồm dữ liệu reference và UUID Aimlock hiện có. Các số assertion nằm trong các nhóm test, không cộng thành số unittest độc lập.

Bản tổng hợp và bằng chứng cuối ở `scratch/complete-reference-fix-20261115/` và báo cáo workspace. CI macOS kiểm tra Darwin/CryptoKit/Objective-C, workflow video simulator và build IPA. Kiểm tra này chưa thay thử IPA ký thật trên iPhone đại diện từng OS/SoC.
