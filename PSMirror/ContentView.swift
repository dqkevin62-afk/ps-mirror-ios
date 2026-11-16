import SwiftUI

struct ContentView: View {
    @StateObject private var client = PSClient()

    @AppStorage("ps.host") private var host = ""
    @AppStorage("ps.port") private var port = "49494"
    @AppStorage("ps.password") private var password = ""
    @AppStorage("ps.auto") private var autoRefresh = false

    @State private var zoomed = false

    private let bg = Color(white: 0.07)
    private let panel = Color(white: 0.13)
    private let line = Color(white: 0.26)

    var body: some View {
        VStack(spacing: 0) {
            settingsPanel
            Divider().overlay(line)
            imageArea
            Divider().overlay(line)
            statusBar
        }
        .background(bg)
        .preferredColorScheme(.dark)
        .onDisappear { client.stopAuto() }
    }

    // MARK: - 设置

    private var settingsPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                field("电脑 IP", text: $host, width: nil)
                field("端口", text: $port, width: 74)
            }

            HStack(spacing: 8) {
                SecureField("远程连接密码", text: $password)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(panel)
                    .overlay(Rectangle().stroke(line, lineWidth: 1))

                Button {
                    toggleConnect()
                } label: {
                    Text(client.isConnected ? "断开" : "连接")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 62)
                        .padding(.vertical, 9)
                        .background(client.isConnected ? Color(white: 0.3) : Color(red: 0.18, green: 0.45, blue: 0.85))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Button {
                    client.requestFrame()
                } label: {
                    Text("刷新画面")
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(panel)
                        .overlay(Rectangle().stroke(line, lineWidth: 1))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(!client.isConnected)

                Toggle("自动刷新", isOn: $autoRefresh)
                    .font(.system(size: 14))
                    .toggleStyle(.switch)
                    .fixedSize()
                    .onChange(of: autoRefresh) { on in
                        if on {
                            client.startAuto(interval: 3.0)
                        } else {
                            client.stopAuto()
                        }
                    }
            }
        }
        .padding(12)
    }

    private func field(_ title: String, text: Binding<String>, width: CGFloat?) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .keyboardType(.numbersAndPunctuation)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(panel)
            .overlay(Rectangle().stroke(line, lineWidth: 1))
    }

    // MARK: - 画面

    private var imageArea: some View {
        ZStack {
            Color(white: 0.04)

            if let img = client.image {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: zoomed ? .fill : .fit)
                    .padding(zoomed ? 0 : 8)
                    .onTapGesture { zoomed.toggle() }
            } else {
                VStack(spacing: 10) {
                    Text("还没有画面")
                        .font(.system(size: 15))
                        .foregroundColor(.gray)
                    Text("1. 电脑上打开 PS 并打开一个文档\n2. 填好 IP 和密码\n3. 点「连接」")
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .foregroundColor(Color(white: 0.45))
                }
                .padding(24)
            }
        }
        .clipped()
    }

    // MARK: - 状态

    private var statusBar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(client.isConnected ? Color(red: 0.24, green: 0.86, blue: 0.52) : Color(red: 1.0, green: 0.37, blue: 0.34))
                    .frame(width: 7, height: 7)
                Text(client.statusText)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.8))
                Spacer()
                if let t = client.lastUpdate {
                    Text(t, style: .time)
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.5))
                }
            }
            if let err = client.lastError, !err.isEmpty {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 1.0, green: 0.55, blue: 0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 动作

    private func toggleConnect() {
        if client.isConnected {
            autoRefresh = false
            client.stopAuto()
            client.disconnect()
        } else {
            let p = UInt16(port) ?? 49494
            client.connect(host: host.trimmingCharacters(in: .whitespaces), port: p, password: password)
        }
    }
}

#Preview {
    ContentView()
}
