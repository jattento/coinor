import Foundation
import Testing

@Suite
struct LocalNetworkProbeTests {
    private func attempt(_ label: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        let e = Pipe(); p.standardError = e; p.standardOutput = FileHandle.nullDevice
        try? p.run()
        let d = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        print("\(label)_STATUS=\(p.terminationStatus) \(label)_ERR=\(String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\n", with: " | "))")
    }

    @Test func lanByIP() {
        attempt("IP", ["-o","BatchMode=yes","-o","ConnectTimeout=8","-T","jattentom2@192.168.1.74","true"])
    }

    @Test func lanByMDNS() {
        attempt("MDNS", ["-o","BatchMode=yes","-o","ConnectTimeout=8","-T","jattentom2-home","true"])
    }

    @Test func rawSocketToLAN() {
        // A direct TCP connect from the app itself, with no ssh involved.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(22).bigEndian
        inet_pton(AF_INET, "192.168.1.74", &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        print("RAWSOCKET_RESULT=\(result) RAWSOCKET_ERRNO=\(errno) (\(String(cString: strerror(errno))))")
        close(fd)
    }
}
