# Bảo toàn patch / restore — build 39

Build 39 sửa các tình huống mất liên kết backup, baseline sai, restore ghi đè thay đổi và thao tác cũ chạy qua phiên mới đã tìm thấy khi rà soát build 38. Không thay bảng OS/build hoặc thứ tự 3105 → worse_query → AirLift; không thay native primitive, server, SQL, key, TLS hoặc định dạng tải patch.

## Lịch sử giao dịch

Trước apply, journal và provenance phải nhất quán. Journal hỏng/mất trong một lịch sử chưa xử lý không được coi là OFF. App giữ backup và chuyển trạng thái cần khôi phục, thay vì sao lưu chính dữ liệu đã patch làm baseline mới.

Transaction mới có marker trước mutation để phân biệt một thư mục staging còn an toàn với lịch sử không rõ. Marker bị bỏ sau khi journal/provenance đã lưu và trước lần ghi target đầu tiên. Một thư mục transaction legacy không có journal và không có marker hợp lệ phải được xem là không rõ trạng thái, kể cả thư mục rỗng của private patch chỉ tạo file mới. App không tự xóa bằng chứng để bỏ chặn.

Các lần lưu journal/provenance/marker và commit entry có đồng bộ file/thư mục; không suy điều này thành bảo đảm phục hồi mọi trường hợp mất điện hoặc dữ liệu bị xóa từ bên ngoài.

## Catalog và liên kết backup

Service xác định lịch sử active trước khi nhận project mới. Sau một OFF lỗi, ON có thể xác minh lại đúng project/payload đang có và dùng tiếp receipt cũ; nếu là revision/project khác thì phải khôi phục lịch sử cũ an toàn trong cùng gate trước khi apply mới. Không lấy dữ liệu đang patch làm baseline mới. Mất preference vẫn đối chiếu với metadata identity đã lưu; lỗi trước khi có journal mới không chiếm association cũ.

Metadata recovery chỉ chứa project ID, tên hiển thị và catalog identity; không chứa payload, mật khẩu, key hoặc URL. Đọc danh sách từ journal/provenance và metadata local, độc lập catalog tải về. Lỗi catalog/gỡ item/mất preference không làm mất đường nhìn thấy transaction. Tên metadata hỏng có thể hiện bằng project ID; storage tạm khóa giữ danh sách đang thấy và báo lỗi.

## Restore có xác nhận

OFF luôn kiểm tra tình trạng file. File đã thay đổi cần người dùng xem danh sách và xác nhận trước khi thay bằng backup. Xác nhận gắn với project, receipt, auth revision, snapshot hash dữ liệu và thời điểm kiểm tra; giới hạn năm phút. Transaction kiểm snapshot lại, không chỉ dựa vào chuỗi đường dẫn trên màn hình. Dữ liệu hoặc phiên đổi tiếp thì cần kiểm tra/xác nhận mới.

Trong giao dịch dở dang, các target còn đúng trạng thái trước apply hoặc payload đã biết có thể phục hồi; bytes thứ ba do game/tiến trình khác ghi phải được cảnh báo trước khi đè. Restore trả dữ liệu trước lần áp dụng đó, không chứng nhận đây là file game nguyên bản từ nhà phát hành.

## Phiên, cancellation và đường dẫn

- Capture auth revision trước khi chờ filesystem gate, truyền nguyên revision qua các ranh giới async; thao tác cũ không được nhận phiên đăng nhập mới.
- Permit được kiểm trước từng forward write và trước hoàn tất, gồm reset-to-applied. Rollback được tiếp tục để trả trạng thái nhất quán.
- Giữ directory descriptor của root đã xác minh và các thư mục con; thao tác ghi/đọc/xóa dùng đường tương đối với descriptor và từ chối symlink. Thay đường dẫn cha giữa chừng không chuyển commit sang thư mục mới.
- Root được mở trực tiếp theo grant của chính nó; không yêu cầu quyền đọc/list các ancestor hệ thống bên trên. Sau đó chỉ đi vào các descendant tương đối.
- Chỉ thư mục do giao dịch thực sự tạo mới được ghi nhận ownership theo device/inode. Cleanup không xóa đệ quy; identity thiếu/đổi hoặc journal legacy chưa có bằng chứng ownership thì giữ thư mục rỗng, vẫn khôi phục file. POSIX không có unlink điều kiện inode nguyên tử, nên không tuyên bố khóa được mọi race của tiến trình khác.
- worse_query đọc lại identity đích dưới grant của transaction; mismatch/unreadable bị chặn và cache session bị vô hiệu hóa. Không tự AirLift.
- Startup chờ probe direct hoàn tất trước auto-run native, thay vì chạy hai đường trong lúc probe còn pending.

## Giao diện

Tab Chức năng có mục Khôi phục dữ liệu độc lập với danh mục và lỗi tải. Mọi card dùng trạng thái bận chung; thay category/card không tạo nút enabled trong khi yêu cầu cũ còn chạy. Sheet xác nhận liệt kê file đổi, có lựa chọn hủy rõ ràng; hủy không ghi và giữ ý định ON trước đó. Theo yêu cầu mới, OFF lỗi (kể cả inspection lỗi, trừ cancellation/phiên đã đổi) báo lỗi và đưa toggle về OFF. Ý định OFF được lưu riêng; journal và backup vẫn active/recovery, hiển thị “Chưa khôi phục”. Lần ON sau có thể retry theo receipt cũ, không bỏ qua các kiểm tra lịch sử hoặc force restore âm thầm.

Danh sách local có thể hiển thị khi catalog không có; thao tác restore vẫn tuân theo auth/network/integrity hiện có. Build này không mở đường bypass license hoặc restore tùy ý qua AirLift. Không thể dựng lại backup/journal đã mất hoàn toàn.

## Kiểm chứng

Các test mới chạy thân hàm production và filesystem tạm để tái hiện lỗi cũ rồi xác nhận hành vi mới. Boundary network/native trong test catalog là fixture; test direct trên macOS dùng Darwin/CryptoKit. Có thêm kiểm tra parent swap ở apply/restore/reset, search-only ancestor, stale confirmation, lịch sử hỏng và session xếp hàng.

Kết quả cuối, commit GitHub, workflow và IPA được tổng hợp tại `KE_HOACH_VA_KET_QUA_SUA_PATCH_RESTORE_2026-11-15.md` ở workspace và artifact `scratch/patch-restore-fix-20261115/`.

Để xác nhận quyền sandbox/daemon, metadata Darwin trên thiết bị, engine và độ ổn định từng OS/SoC vẫn cần thử IPA đã ký trên iPhone thật. File game do tiến trình khác sửa sau khi giao dịch đã hoàn tất không thể bị khóa vĩnh viễn bởi gate nội bộ app.

## Chuẩn bị tổng quát worse_query

Bước vào app quét tổng quát cửa sổ inode ước lượng của vùng Application container, không lọc game, không cần game được cài hoặc đọc được bundle identifier. Chỉ cần App Group hợp lệ và ít nhất một container nhận quyền/đọc được. Session không tự gán UUID chưa xác minh thành game. Khi thao tác cần ghi, app mới tìm và kiểm đúng target, rồi xác minh identity lại dưới grant transaction. Không mở rộng native scope, không tuyên bố quét mọi file hệ thống của iPhone.
