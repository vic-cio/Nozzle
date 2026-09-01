import SwiftUI
import Charts
import NozzleCore

/// The last few minutes of both heaters, actual against target.
///
/// The point of the graph is not decoration: it is the fastest way to see the things a
/// pair of numbers hides. A hotend that cannot hold its target, a bed that stalls ten
/// degrees short, an overshoot on the way up, or a reading that has stopped changing
/// because the link has quietly gone — all of them are a shape, and none of them are
/// obvious from "198 / 210 °C".
///
/// Solid lines are what the printer reports; dashed lines are what it was asked for.
struct TemperatureGraph: View {
    let samples: [TemperatureSample]
    /// How much history to show. Ten minutes covers a heat-up and settle without
    /// squashing it into the left edge of an hour-long print.
    var window: TimeInterval = 600
    var height: CGFloat = 170

    var body: some View {
        Group {
            if visible.count < 2 {
                placeholder
            } else {
                chart
            }
        }
        .frame(height: height)
    }

    // MARK: - The chart

    private var chart: some View {
        Chart {
            ForEach(visible) { sample in
                if let value = sample.hotend {
                    LineMark(
                        x: .value("Time", sample.time),
                        y: .value("°C", value),
                        series: .value("Series", "Nozzle")
                    )
                    .foregroundStyle(by: .value("Series", "Nozzle"))
                    .interpolationMethod(.monotone)
                }
                if let value = sample.bed {
                    LineMark(
                        x: .value("Time", sample.time),
                        y: .value("°C", value),
                        series: .value("Series", "Bed")
                    )
                    .foregroundStyle(by: .value("Series", "Bed"))
                    .interpolationMethod(.monotone)
                }
                // Targets, dashed. Drawn only when something is actually switched on,
                // so a heater that is off does not draw a distracting line along zero.
                if let target = sample.hotendTarget, target > 0 {
                    LineMark(
                        x: .value("Time", sample.time),
                        y: .value("°C", target),
                        series: .value("Series", "Nozzle target")
                    )
                    .foregroundStyle(by: .value("Series", "Nozzle"))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                if let target = sample.bedTarget, target > 0 {
                    LineMark(
                        x: .value("Time", sample.time),
                        y: .value("°C", target),
                        series: .value("Series", "Bed target")
                    )
                    .foregroundStyle(by: .value("Series", "Bed"))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
        }
        .chartForegroundStyleScale([
            "Nozzle": Color.orange,
            "Bed": Color.blue,
        ])
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let celsius = value.as(Double.self) {
                        Text("\(Int(celsius))°")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let time = value.as(Date.self) {
                        Text(agoLabel(for: time))
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading, spacing: 8)
        .accessibilityLabel("Temperature history for the nozzle and the bed")
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text("Waiting for readings")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Scales

    private var visible: [TemperatureSample] {
        guard let newest = samples.last?.time else { return [] }
        let cutoff = newest.addingTimeInterval(-window)
        return samples.filter { $0.time >= cutoff }
    }

    /// Always starts at zero — a graph that crops the bottom makes a 5 °C wobble look
    /// like a crisis — and leaves headroom above the highest target so an overshoot has
    /// somewhere to be drawn rather than being clipped flat against the top.
    private var yDomain: ClosedRange<Double> {
        let values = visible.flatMap { [$0.hotend, $0.bed, $0.hotendTarget, $0.bedTarget].compactMap { $0 } }
        let peak = values.max() ?? 100
        return 0...(max(60, peak * 1.15))
    }

    /// "now", "−2 min". Relative labels beat clock times here: what matters is how long
    /// ago something happened, not that it was 14:37.
    private func agoLabel(for time: Date) -> String {
        guard let newest = samples.last?.time else { return "" }
        let seconds = newest.timeIntervalSince(time)
        if seconds < 30 { return "now" }
        return "−\(Int((seconds / 60).rounded())) min"
    }
}
