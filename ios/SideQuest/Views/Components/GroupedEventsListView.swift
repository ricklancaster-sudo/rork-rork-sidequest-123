import SwiftUI

struct GroupedEventsWrapper: Identifiable {
    let id: String = UUID().uuidString
    let events: [ExternalEvent]
}

struct GroupedEventsListView: View {
    let events: [ExternalEvent]
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEvent: ExternalEvent?

    private var venueName: String {
        events.first?.venueName ?? events.first?.title ?? "Events"
    }

    var body: some View {
        List {
            ForEach(events) { event in
                Button {
                    selectedEvent = event
                } label: {
                    eventRow(event)
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(venueName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(item: $selectedEvent) { event in
            NavigationStack {
                ExternalEventDetailView(event: event, appState: appState)
            }
        }
    }

    private func eventRow(_ event: ExternalEvent) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let start = event.startAtUTC {
                    Text(start, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let venue = event.venueName, venue != event.title {
                    Text(venue)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
