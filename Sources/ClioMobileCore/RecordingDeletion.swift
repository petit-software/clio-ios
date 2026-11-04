import Foundation

/// The one confirmation for deleting recordings, wherever it is asked
/// from: the row's swipe, the Delete bar over picked rows, the menu on a
/// recording's own page. Same words, same two buttons, same result —
/// `RecordingStore.delete`, which takes every part's audio with the entry.
public enum RecordingDeletion {
    public static let confirm = "Delete"
    public static let cancel = "Cancel"

    public static func title(count: Int) -> String {
        count == 1 ? "Delete this recording?" : "Delete \(count) recordings?"
    }

    /// What goes, said once. A recording of several parts says how many,
    /// so nobody is surprised that the merge is gone with it.
    public static func message(for recordings: [Recording]) -> String {
        let ending = "This cannot be undone."
        guard recordings.count == 1, let recording = recordings.first else {
            return "Their audio and transcripts are removed from this phone. " + ending
        }
        if recording.parts.count > 1 {
            return "All \(recording.parts.count) parts, audio and transcripts, "
                + "are removed from this phone. " + ending
        }
        return "The audio and its transcript are removed from this phone. " + ending
    }
}
