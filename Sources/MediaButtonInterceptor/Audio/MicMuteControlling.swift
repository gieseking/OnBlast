import Foundation

protocol MicMuteControlling: AnyObject {
    func currentState() -> MicState
    @discardableResult
    func toggleMute() throws -> Bool
}
