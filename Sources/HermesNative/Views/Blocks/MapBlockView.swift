import SwiftUI
import MapKit

/// JSON contract for ```map fenced blocks — point maps rendered with MapKit:
/// ```json
/// {
///   "id": "bkk-apartments",              // optional: living artifact id
///   "title": "BKK Apartment Hunt",
///   "markers": [
///     {"lat": 13.7248, "lon": 100.5847, "label": "Ekkamai loft",
///      "group": "shortlist", "note": "฿38k/mo, 2BR, near BTS"}
///   ]
/// }
/// ```
/// Groups color pins from the shared categorical palette; tap a pin for its
/// note. `id` makes it a living artifact: re-emitted blocks with the same id
/// merge markers by label (see ArtifactMerge.mergeMap).
struct MapSpec: Decodable {
    struct Marker: Decodable, Identifiable {
        let lat: Double
        let lon: Double
        let label: String
        let group: String?
        let note: String?

        var id: String { label }
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    let id: String?
    let title: String?
    let markers: [Marker]

    /// Distinct groups in first-appearance order.
    var groups: [String] {
        var seen = Set<String>()
        return markers.compactMap(\.group).filter { seen.insert($0).inserted }
    }

    static func parse(_ json: String) -> MapSpec? {
        guard let data = json.data(using: .utf8),
              let spec = try? JSONDecoder().decode(MapSpec.self, from: data),
              !spec.markers.isEmpty else { return nil }
        return spec
    }
}

/// Renders a ```map block. Region auto-fits the markers with padding.
struct MapBlockView: View {
    let json: String
    let isStreaming: Bool

    @State private var selectedMarkerID: String?

    /// Shared categorical palette (chart/graph parity).
    private static let palette: [Color] = [
        "#3987e5", "#008300", "#d55181", "#c98500",
        "#199e70", "#d95926", "#9085e9", "#e66767",
    ].compactMap { Color(hex: $0) }

    var body: some View {
        if let spec = MapSpec.parse(json) {
            MapCard(spec: spec, selectedMarkerID: $selectedMarkerID)
        } else if isStreaming {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't parse map block")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                Text(json)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    static func color(forGroupIndex index: Int) -> Color {
        palette[index % palette.count]
    }
}

private struct MapCard: View {
    let spec: MapSpec
    @Binding var selectedMarkerID: String?
    @State private var cameraPosition: MapCameraPosition = .automatic

    private var groupColors: [String: Color] {
        Dictionary(uniqueKeysWithValues: spec.groups.enumerated().map { index, group in
            (group, MapBlockView.color(forGroupIndex: index))
        })
    }

    private var selectedMarker: MapSpec.Marker? {
        spec.markers.first { $0.id == selectedMarkerID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
            }

            Map(position: $cameraPosition) {
                ForEach(spec.markers) { marker in
                    Annotation(marker.label, coordinate: marker.coordinate) {
                        pin(for: marker)
                    }
                }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear { cameraPosition = .automatic }

            if let selected = selectedMarker {
                markerDetail(selected)
            }

            if !spec.groups.isEmpty {
                legend
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    private func pin(for marker: MapSpec.Marker) -> some View {
        let color = marker.group.flatMap { groupColors[$0] } ?? Theme.accent
        let isSelected = selectedMarkerID == marker.id
        return Circle()
            .fill(color)
            .frame(width: isSelected ? 18 : 13, height: isSelected ? 18 : 13)
            .overlay(Circle().stroke(.white, lineWidth: isSelected ? 2.5 : 1.5))
            .shadow(radius: 2)
            .onTapGesture {
                selectedMarkerID = isSelected ? nil : marker.id
            }
    }

    private func markerDetail(_ marker: MapSpec.Marker) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(marker.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                if let group = marker.group {
                    Text(group)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Theme.surfaceHover, in: Capsule())
                }
                Spacer()
            }
            if let note = marker.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private var legend: some View {
        HStack(spacing: 6) {
            ForEach(spec.groups, id: \.self) { group in
                HStack(spacing: 5) {
                    Circle()
                        .fill(groupColors[group] ?? Theme.accent)
                        .frame(width: 8, height: 8)
                    Text(group)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.surfaceHover.opacity(0.6), in: Capsule())
            }
        }
    }
}
