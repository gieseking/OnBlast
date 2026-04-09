import Foundation

protocol MicMuteControlling: AnyObject {
    func currentState() -> MicState
    func setMuted(_ muted: Bool) throws
    @discardableResult
    func toggleMute() throws -> Bool
}
