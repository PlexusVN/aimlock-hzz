# Video nền — bản sửa build 38

Hai lỗi được báo trên app cài thật: nền chính chỉ lóe khi đổi tab, và nền login xuất hiện khoảng đen trước khi phát lại. Preview web và kết quả build 37 chưa đủ để xác nhận compositing UIKit hoặc nội dung từng frame của nguồn.

## Nền chính

Ba tab có `NavigationStack` độc lập. Nền SwiftUI trong suốt chưa loại bỏ lớp hosting/transition đặc của UIKit; khi crossfade, lớp này mờ đi rồi che lại video. `appVideoNavigationSurface()` làm trong suốt đúng đường ancestor của nội dung đến NavigationStack/SplitView sở hữu nó, khi có nền video ở root. Helper cập nhật khi attach, appear và layout, không sửa UIWindow, global appearance hoặc duyệt sibling/subview để đổi nền card, navbar, sheet. Các tab giữ nguyên navigation, trạng thái và hành động.

## Đoạn đen trong video login gốc

Đã decode cả 750 frame của nguồn login 30 giây/25fps. Frame 0–289 còn hình; frame 290–749 là đen hoàn toàn, bắt đầu tại PTS 11,60 giây. File main 10 giây không có khoảng đen hoàn toàn tương tự. Bằng chứng decode và ảnh frame 289/290 nằm trong `scratch/video-native-fix/source-loop-audit.json` ở workspace.

Native giữ `AVPlayerLooper`, dùng `CMTimeRange(start: .zero, duration: CMTime(value: 290, timescale: 25))` cho login, tức `[0, 11.60)` giây. Main tiếp tục phát toàn clip. Preview lấy cùng khoảng phát từ source Swift qua `sync-source.py`, dùng callback frame để quay về đầu ở frame cuối có hình; poster che lúc seek và chỉ nhường lại khi frame đầu đã được trình bày. Đây là giới hạn đoạn phát, không cắt, nén hay ghi lại file MP4.

## Phạm vi

Giữ phiên bản 2.4 và tăng build lên 38 để phân biệt IPA sửa lỗi. Không thay Auth, HWID, API, dữ liệu, engine, bitrate, độ phân giải hoặc chính sách phủ kín màn hình. Source, bundle và preview vẫn giữ nguyên SHA-256 của video và poster.

Kiểm tra bổ sung native simulator dùng chính source player và helper navigation, với màn minh họa riêng để không gọi Auth. Kết quả simulator chỉ xác nhận đường render được kiểm tra; vẫn cần mở IPA build 38 trên iPhone người dùng để xác nhận trường hợp thực tế.
