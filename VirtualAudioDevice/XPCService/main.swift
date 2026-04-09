import Dispatch
import Foundation

@objc protocol MediaButtonVirtualAudioXPCProtocol {
    func updateMuteState(isMuted: Bool, withReply reply: @escaping (Bool) -> Void)
    func updateSourceDevice(uid: String, withReply reply: @escaping (Bool) -> Void)
}

final class MediaButtonVirtualAudioXPCService: NSObject, MediaButtonVirtualAudioXPCProtocol {
    func updateMuteState(isMuted: Bool, withReply reply: @escaping (Bool) -> Void) {
        _ = isMuted
        reply(false)
    }

    func updateSourceDevice(uid: String, withReply reply: @escaping (Bool) -> Void) {
        _ = uid
        reply(false)
    }
}

final class MediaButtonVirtualAudioXPCDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: MediaButtonVirtualAudioXPCProtocol.self)
        newConnection.exportedObject = MediaButtonVirtualAudioXPCService()
        newConnection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: "com.gieseking.MediaButtonInterceptor.VirtualAudioXPC")
let delegate = MediaButtonVirtualAudioXPCDelegate()
listener.delegate = delegate
listener.resume()
dispatchMain()
