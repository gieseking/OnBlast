import Dispatch
import Foundation

@objc protocol OnBlastVirtualAudioXPCProtocol {
    func updateMuteState(isMuted: Bool, withReply reply: @escaping (Bool) -> Void)
    func updateSourceDevice(uid: String, withReply reply: @escaping (Bool) -> Void)
}

final class OnBlastVirtualAudioXPCService: NSObject, OnBlastVirtualAudioXPCProtocol {
    func updateMuteState(isMuted: Bool, withReply reply: @escaping (Bool) -> Void) {
        _ = isMuted
        reply(false)
    }

    func updateSourceDevice(uid: String, withReply reply: @escaping (Bool) -> Void) {
        _ = uid
        reply(false)
    }
}

final class OnBlastVirtualAudioXPCDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: OnBlastVirtualAudioXPCProtocol.self)
        newConnection.exportedObject = OnBlastVirtualAudioXPCService()
        newConnection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: "com.gieseking.OnBlast.VirtualAudioXPC")
let delegate = OnBlastVirtualAudioXPCDelegate()
listener.delegate = delegate
listener.resume()
dispatchMain()
