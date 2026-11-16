import Foundation
import Network
import UIKit

/// 与 Photoshop「远程连接」(端口 49494) 通信。
/// 协议（已在本机对 PS 2017 实测通过）：
///   帧 = [UInt32 BE: 4 + len(cipher)] [UInt32 BE: commStatus] [cipher]
///   明文 = [UInt32: version=1] [UInt32: id] [UInt32: type=2(JS)] [script utf8]
@MainActor
final class PSClient: ObservableObject {
    @Published var image: UIImage?
    @Published var statusText: String = "未连接"
    @Published var isConnected: Bool = false
    @Published var lastUpdate: Date?
    @Published var lastError: String?

    private var connection: NWConnection?
    private var crypto: PSCrypto?
    private var buffer = Data()
    private var nextId: UInt32 = 1
    private var autoTimer: Timer?
    private var isRequesting = false

    // MARK: - 连接

    func connect(host: String, port: UInt16, password: String) {
        disconnect()
        do {
            crypto = try PSCrypto(password: password)
        } catch {
            statusText = "密码初始化失败"
            lastError = "密钥派生错误: \(error)"
            return
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            statusText = "端口无效"
            return
        }

        statusText = "连接中…"
        lastError = nil
        buffer.removeAll(keepingCapacity: true)

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.statusText = "已连接"
                    self.receiveLoop()
                case .failed(let err):
                    self.isConnected = false
                    self.statusText = "连接失败"
                    self.lastError = err.localizedDescription
                case .cancelled:
                    self.isConnected = false
                    self.statusText = "已断开"
                case .waiting(let err):
                    self.statusText = "等待网络"
                    self.lastError = err.localizedDescription
                default:
                    break
                }
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    func disconnect() {
        autoTimer?.invalidate()
        autoTimer = nil
        connection?.cancel()
        connection = nil
        isConnected = false
        isRequesting = false
        statusText = "未连接"
    }

    // MARK: - 接收与分帧

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.consume(data)
                }
                if let error {
                    self.isConnected = false
                    self.lastError = error.localizedDescription
                    return
                }
                if isComplete {
                    self.isConnected = false
                    return
                }
                self.receiveLoop()
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 8 {
            let declared = Self.be32(buffer, 0)
            guard declared >= 4 else {
                buffer.removeAll(keepingCapacity: true)
                return
            }
            let encLen = Int(declared) - 4
            let total = 8 + encLen
            guard buffer.count >= total else { return }

            let commStatus = Self.be32(buffer, 4)
            let body = buffer.subdata(in: 8..<total)
            buffer.removeFirst(total)

            handleFrame(commStatus: commStatus, body: body)
        }
    }

    private func handleFrame(commStatus: UInt32, body: Data) {
        if commStatus != 0 {
            let msg = String(data: body, encoding: .utf8) ?? "未知通信错误"
            isRequesting = false
            lastError = msg
            statusText = "PS 报错"
            return
        }
        guard let crypto,
              let plain = try? crypto.decrypt(body),
              plain.count >= 12 else {
            isRequesting = false
            lastError = "解密失败 —— 密码可能不对"
            return
        }

        let type = Self.be32(plain, 8)
        let payload = plain.subdata(in: 12..<plain.count)

        switch type {
        case 2:
            let text = String(data: payload, encoding: .utf8) ?? ""
            if let r = text.range(of: "\r") {
                handleJS(String(text[r.upperBound...]))
            } else {
                handleJS(text)
            }
        case 1:
            isRequesting = false
            lastError = String(data: payload, encoding: .utf8)
        default:
            break
        }
    }

    private func handleJS(_ raw: String) {
        isRequesting = false
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if value == "NODOC" {
            statusText = "PS 里没有打开的文档"
            return
        }
        guard value.hasPrefix("OK|") else {
            if !value.isEmpty { lastError = value }
            return
        }

        let parts = value.components(separatedBy: "|")
        guard parts.count >= 4 else {
            lastError = "返回格式异常"
            return
        }
        let dims = parts[1]
        let b64 = parts[3...].joined(separator: "|")

        guard let data = Data(base64Encoded: b64), let img = UIImage(data: data) else {
            lastError = "图片解码失败"
            return
        }
        image = img
        lastUpdate = Date()
        lastError = nil
        statusText = "已更新 \(dims)"
    }

    // MARK: - 发送

    private func send(script: String) {
        guard let crypto, let conn = connection, isConnected else { return }

        var plain = Data()
        plain.append(Self.be32Data(1))
        plain.append(Self.be32Data(nextId))
        plain.append(Self.be32Data(2))
        plain.append(contentsOf: Array(script.utf8))
        nextId &+= 1

        guard let enc = try? crypto.encrypt(plain) else {
            lastError = "加密失败"
            return
        }
        var frame = Data()
        frame.append(Self.be32Data(UInt32(enc.count + 4)))
        frame.append(Self.be32Data(0))
        frame.append(enc)

        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: - 请求画面

    func requestFrame() {
        guard isConnected, !isRequesting else { return }
        isRequesting = true
        send(script: Self.captureScript)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if let self, self.isRequesting {
                self.isRequesting = false
                self.lastError = "请求超时（PS 可能正忙）"
            }
        }
    }

    func startAuto(interval: TimeInterval) {
        stopAuto()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestFrame() }
        }
        RunLoop.main.add(t, forMode: .common)
        autoTimer = t
        requestFrame()
    }

    func stopAuto() {
        autoTimer?.invalidate()
        autoTimer = nil
    }

    // MARK: - 工具

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        let b0 = UInt32(data[base])
        let b1 = UInt32(data[base + 1])
        let b2 = UInt32(data[base + 2])
        let b3 = UInt32(data[base + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func be32Data(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }

    /// 在 PS 里执行：另存 JPEG（必要时先缩到 1200px）→ 读回 → base64
    static let captureScript = """
    (function () {
      var d = app.activeDocument;
      if (!d) { return "NODOC"; }
      var w = d.width.as("px"), h = d.height.as("px");
      var t = null;
      if (w > 1200) {
        t = d.duplicate();
        t.resizeImage(1200, null, null, ResampleMethod.BICUBIC);
      }
      var src = t || d;
      var f = new File(Folder.temp.fsName + "/psm_ios.jpg");
      var o = new JPEGSaveOptions();
      o.quality = 7;
      o.embedColorProfile = false;
      src.saveAs(f, o, true, Extension.LOWERCASE);
      if (t) { t.close(SaveOptions.DONOTSAVECHANGES); }
      f.encoding = "BINARY";
      f.open("r");
      var data = f.read();
      f.close();
      var b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      var parts = [], chunk = [], len = data.length;
      for (var i = 0; i < len; i += 3) {
        var c1 = data.charCodeAt(i) & 255;
        var c2 = (i + 1 < len) ? data.charCodeAt(i + 1) & 255 : 0;
        var c3 = (i + 2 < len) ? data.charCodeAt(i + 2) & 255 : 0;
        chunk.push(b64.charAt(c1 >> 2));
        chunk.push(b64.charAt(((c1 & 3) << 4) | (c2 >> 4)));
        chunk.push((i + 1 < len) ? b64.charAt(((c2 & 15) << 2) | (c3 >> 6)) : "=");
        chunk.push((i + 2 < len) ? b64.charAt(c3 & 63) : "=");
        if (chunk.length >= 12000) { parts.push(chunk.join("")); chunk = []; }
      }
      if (chunk.length) { parts.push(chunk.join("")); }
      return "OK|" + Math.round(w) + "x" + Math.round(h) + "|" + len + "|" + parts.join("");
    })();
    """
}
