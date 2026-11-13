import Foundation

/// Undo/redo of editing steps, by snapshots of the project state. Projects are small value types, so a
/// snapshot per step is simple and cannot get out of step with the model.
///
/// This is Undo of *edits*. It says nothing about files: once an original video has been replaced, undo does not
/// bring the old file back; that is what the backup copy is for (design section 6).
public struct History<State: Equatable> {
    public struct Entry { public var label: String; public var state: State }

    public private(set) var present: State
    private var past: [Entry] = []
    private var future: [Entry] = []
    private var lastCoalesceKey: String?
    public let limit: Int

    public init(_ initial: State, limit: Int = 200) {
        present = initial
        self.limit = limit
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var undoLabel: String? { past.last?.label }
    public var redoLabel: String? { future.last?.label }

    /// Records a change. Steps with the same `coalesce` key in a row (dragging a slider, typing) become one undo step.
    public mutating func commit(_ newState: State, label: String, coalesce: String? = nil) {
        guard newState != present else { return }
        if let key = coalesce, key == lastCoalesceKey, !past.isEmpty {
            present = newState
        } else {
            past.append(Entry(label: label, state: present))
            if past.count > limit { past.removeFirst(past.count - limit) }
            present = newState
        }
        lastCoalesceKey = coalesce
        future.removeAll()
    }

    /// The names of the steps that can be undone, the most recent first (for a history list, 0.16.5).
    public var undoLabels: [String] { past.reversed().map(\.label) }
    /// The names of the steps that can be redone, the next one first.
    public var redoLabels: [String] { future.reversed().map(\.label) }

    /// Ends a run of coalesced steps (mouse up), so the next change starts a new undo step.
    public mutating func endCoalescing() { lastCoalesceKey = nil }

    @discardableResult
    public mutating func undo() -> String? {
        guard let e = past.popLast() else { return nil }
        future.append(Entry(label: e.label, state: present))
        present = e.state
        lastCoalesceKey = nil
        return e.label
    }

    @discardableResult
    public mutating func redo() -> String? {
        guard let e = future.popLast() else { return nil }
        past.append(Entry(label: e.label, state: present))
        present = e.state
        lastCoalesceKey = nil
        return e.label
    }

    /// Updates the present state in place, keeping the undo and redo steps. For view state that is saved with the
    /// project but is not an edit (which clip is selected), so choosing a clip never clears Undo.
    public mutating func amend(_ state: State) { present = state }

    /// Replaces the present state without making an undo step (loading a file, restoring a recovery copy).
    public mutating func reset(_ state: State) {
        present = state; past.removeAll(); future.removeAll(); lastCoalesceKey = nil
    }
}
