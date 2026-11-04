import ClioMobileCore
import SwiftUI

/// What is about to be deleted, while the confirmation is up.
struct DeletionRequest: Identifiable, Equatable {
    var ids: [Recording.ID]
    var id: [Recording.ID] { ids }
}

extension View {
    /// The one deletion confirmation — the words are `RecordingDeletion`'s,
    /// the deletion is the store's — as an alert over whatever asked for
    /// it: a swiped row, the Delete bar over picked rows, a recording's own
    /// menu. The alert is up while `request` is set. Confirmed, every
    /// recording in it goes, audio and all, and `onDeleted` is told;
    /// cancelled, nothing changes.
    ///
    /// An alert rather than a confirmation dialog: there is one thing to
    /// say yes or no to, and a dialog anchors itself to the control it
    /// came from — a popover with a tail pointing at a menu that is no
    /// longer there.
    func confirmDeletion(_ request: Binding<DeletionRequest?>,
                         library: RecordingStore,
                         onDeleted: @escaping () -> Void = {}) -> some View {
        alert(RecordingDeletion.title(count: request.wrappedValue?.ids.count ?? 1),
              isPresented: Binding(get: { request.wrappedValue != nil },
                                   set: { if !$0 { request.wrappedValue = nil } }),
              presenting: request.wrappedValue) { pending in
            Button(RecordingDeletion.cancel, role: .cancel) {}
            Button(RecordingDeletion.confirm, role: .destructive) {
                for id in pending.ids { library.delete(id) }
                onDeleted()
            }
        } message: { pending in
            Text(RecordingDeletion.message(for: pending.ids.compactMap { library[$0] }))
        }
    }
}
