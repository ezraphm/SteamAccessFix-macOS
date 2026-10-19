<h1 align="center">SteamAccessFix (SAF) cho macOS</h1>

<p align="center">Công cụ một file (<code>.command</code>) giúp vào lại Steam (Store, Community, CDN hình ảnh/tài nguyên) khi nhà mạng làm sai DNS hoặc chặn kết nối bằng cách đọc tên miền trong gói TLS.</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-Python%203-black?logo=apple" alt="macOS, Python 3">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue" alt="License: MIT"></a>
</p>

<hr>

> Bản macOS này dựa trên dự án [SteamAccessFix](https://gitlab.com/vuviett47/SteamAccessFix) cho Windows của `vuviett47` (tham chiếu v1.2.0) và được phát triển độc lập.

Tùy chọn dòng lệnh:

| Cờ | Tác dụng |
| :--- | :--- |
| `--nodns` | Giữ DNS hệ thống (máy IP tĩnh / LAN) |
| `--dns-only` | Chỉ đổi DNS, không chạy proxy |
| `--dns <tên>` | Chọn DNS: `google` (mặc định), `cloudflare`, `controld`, `quad9`, `opendns`, `adguard`, `nextdns`, `alidns`, `dnssb`, `comodo` |
| `--dns fastest` | Đo độ trễ song song cả 10 DNS rồi chọn cái nhanh nhất |
| `--mtu` | Dò MTU tối đa không bị phân mảnh (ping DF tới `1.1.1.1`) rồi đặt cho dịch vụ mạng. Tự khôi phục khi thoát |
| `--restore` | Khôi phục sau khi tiến trình bị tắt đột ngột |

Khi chạy, công cụ tự xoá cache DNS mỗi khi Steam hoặc Dota 2 khởi động (kiểm tra mỗi 5 giây).

## Vấn đề công cụ giải quyết

Một số nhà mạng làm hai việc với Steam:

* **DNS poisoning**: máy hỏi tên miền Steam, nhà mạng trả IP sai.
* **DPI (kiểm tra gói tin sâu)**: nhà mạng đọc tên miền (SNI) trong gói TLS đầu tiên rồi ngắt kết nối.

Công cụ chạy một proxy trên máy bạn, chỉ cho lưu lượng Steam đi qua. Proxy hỏi IP qua Google DNS và cắt gói TLS đầu tiên làm hai phần để bộ lọc không đọc được tên miền. Lưu lượng khác đi thẳng như cũ.

## Yêu cầu

* macOS có `python3` (3.8 trở lên). Chỉ dùng thư viện chuẩn, không cài gói nào.
* Quyền `sudo`, vì công cụ đổi DNS và Proxy của dịch vụ mạng đang dùng.
* Cổng `31627` trên `127.0.0.1` phải trống.

## Cách sử dụng

```sh
git clone https://github.com/ezraphm/SteamAccessFix-macOS.git
cd SteamAccessFix-macOS
./SteamAccessFix.command
```

1. Nhập mật khẩu `sudo` khi được hỏi.
2. Chờ dòng `on: ...` (xem bên dưới). Mở Steam. Tải Store hoặc game bình thường.
3. Khi xong, nhấn `Ctrl-C` trong Terminal. Công cụ trả DNS và Proxy về như cũ rồi in `restored <dịch vụ mạng>`.

Có thể nhấp đúp `SteamAccessFix.command` trong Finder. Nếu macOS chặn, chuột phải chọn **Open**. Nếu báo thiếu quyền chạy: `chmod +x SteamAccessFix.command`.

Khi chạy, Terminal hiển thị:

```
on: Wi-Fi. DNS=google, PAC+proxy=127.0.0.1:31627. Ctrl-C to restore.
CONNECT store.steampowered.com:443 -> 23.15.142.182
CONNECT shared.fastly.steamstatic.com:443 -> 199.232.211.52
CONNECT api.steampowered.com:443 -> 23.200.229.164
```

Mỗi kết nối Steam in một dòng `CONNECT host:443 -> IP`. Lỗi in thành `fail <Loại lỗi>: <nội dung>`.

## Cách hoạt động

```
Steam -> PAC (127.0.0.1:31627) -> tên miền Steam? -> proxy CONNECT (cùng cổng 31627)
      -> hỏi IP qua UDP tới 8.8.8.8 -> mở TCP tới IP thật
      -> tách gói TLS ClientHello sau 5 byte đầu -> chuyển tiếp hai chiều
      tên miền khác -> DIRECT
```

1. **Đổi DNS**: đặt DNS của dịch vụ mạng đang dùng thành Google (`8.8.8.8`, `8.8.4.4`) và xóa cache DNS.
2. **PAC chọn lọc**: chỉ `steampowered.com`, `steamcommunity.com`, `steamstatic.com`, `steamusercontent.com` đi qua proxy.
3. **Phân mảnh ClientHello**: gói đầu của TLS bị cắt làm hai phần, cách nhau 50 ms.
4. **Khôi phục**: DNS, URL PAC và trạng thái PAC cũ lưu ở `/var/tmp/saf-state.json`, và được trả lại khi thoát.

> [!NOTE]
> Điểm cắt là byte thứ 5 (ngay sau header của TLS record). Cắt giữa tên miền SNI bị reset trên mạng đã thử, nên không dùng.

## Giới hạn

* Chỉ IPv4. Chỉ xử lý một dịch vụ mạng: dịch vụ chứa đường mặc định tại thời điểm chạy.
* Luôn đổi DNS và bật proxy, kể cả khi mạng vào Steam được bình thường. Không có chế độ tự dò.
* Phải giữ Terminal mở khi dùng Steam.
* Không có cơ chế tự cập nhật.
* Điểm cắt gói cố định. Nhà mạng chặn theo cách khác có thể vẫn không vào được.

## Xử lý sự cố

| Triệu chứng | Cách xử lý |
| :--- | :--- |
| `address already in use` | Có bản khác đang chạy. Tìm bằng `sudo lsof -nP -iTCP:31627 -sTCP:LISTEN`, rồi `sudo kill -TERM <PID>`. `SIGTERM` làm công cụ tự khôi phục trước khi thoát. |
| Mất mạng sau khi bị tắt đột ngột (ví dụ `kill -9`) | Chạy `./SteamAccessFix.command --restore`. Nếu vẫn lỗi: `sudo networksetup -setdnsservers Wi-Fi Empty` và `sudo networksetup -setautoproxystate Wi-Fi off` (thay `Wi-Fi` bằng tên dịch vụ của bạn). |
| Steam báo lỗi `-105` | Xác nhận Terminal đã in dòng `on: ...`. Nếu vẫn lỗi, thoát hẳn Steam (`Cmd+Q`) rồi mở lại. Xem Terminal có dòng `CONNECT` cho `store.steampowered.com` không. |
| Có dòng `fail ...` | Gửi nội dung dòng đó khi báo lỗi. |

Báo lỗi tại [Issues](https://github.com/ezraphm/SteamAccessFix-macOS/issues).

## Giấy phép

[MIT](LICENSE).

---

<p align="center">
  <b>Phiên bản hiện tại:</b> 0.1.2 &bull; <b>Gốc (Windows):</b> <a href="https://gitlab.com/vuviett47/SteamAccessFix">vuviett47</a> &bull; <b>Bản macOS:</b> <a href="https://github.com/ezraphm">ezraphm</a>
</p>
