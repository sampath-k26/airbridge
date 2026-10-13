import os

/// Minimal mutex usable from async code. Callers must never hold it across an `await`
/// (every critical section in AirBridgeCore is synchronous).
public final class ABLock: @unchecked Sendable {
    private let m: UnsafeMutablePointer<os_unfair_lock>
    public init() { m = .allocate(capacity: 1); m.initialize(to: os_unfair_lock()) }
    deinit { m.deinitialize(count: 1); m.deallocate() }
    public func lock() { os_unfair_lock_lock(m) }
    public func unlock() { os_unfair_lock_unlock(m) }
}
