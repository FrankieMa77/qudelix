import SwiftUI

/// Hardware settings that live on the 5K rather than in this app.
///
/// These sit in a popover rather than a pane for two reasons: the main window
/// is a fixed height and has no room left, and these are set-once settings
/// that don't belong in the daily path. A popover floats, so opening it costs
/// the window nothing.
struct DeviceSettingsView: View {
    @EnvironmentObject var controller: QudelixController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device settings")
                .font(.system(size: 12, weight: .semibold))

            channelTrim
            Divider()
            volumeLimit

            if controller.dacFilterLabel != nil || controller.crossfeedLevel != nil {
                Divider()
                readOnlyFacts
            }

            Text("Stored on the 5K, so they persist across apps and reboots.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: - Channel trim

    private var trimmed: Bool {
        controller.trimLeftDb != 0 || controller.trimRightDb != 0
    }

    private var channelTrim: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Channel trim")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if trimmed {
                    Button("Centre") {
                        controller.setTrimLeft(0)
                        controller.setTrimRight(0)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }
            }

            // Attenuation only — the device has no way to make a channel
            // louder, so centring the image means pulling the stronger side
            // down rather than lifting the weaker one.
            trimSlider("L", value: controller.trimLeftDb) { controller.setTrimLeft($0) }
            trimSlider("R", value: controller.trimRightDb) { controller.setTrimRight($0) }

            Text("Pull one side down to centre an off-centre image, or to "
                 + "match ears that aren't.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trimSlider(_ label: String, value: Double,
                            set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set),
                   in: controller.trimRange)
                .controlSize(.small)
            Text(value == 0 ? "0 dB" : String(format: "%.1f dB", value))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(value == 0 ? .tertiary : .secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .disabled(!controller.canWriteNow)
    }

    // MARK: - Volume limit

    private var volumeLimit: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Volume limit")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(String(format: "%.0f dB", controller.volumeLimitDb))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { controller.volumeLimitDb },
                                  set: { controller.setVolumeLimit($0.rounded()) }),
                   in: controller.volumeLimitRange)
                .controlSize(.small)
                .disabled(!controller.canWriteNow)
            Text("The ceiling the volume slider can reach. Lower it and the "
                 + "whole range moves with it.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Read-only

    /// Settings the device reports but this app doesn't write yet. Shown
    /// because knowing the current value is useful on its own, and because a
    /// wrong guess at one of these commands is what makes the 5K stop
    /// responding — so they stay read-only until each is verified.
    private var readOnlyFacts: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let filter = controller.dacFilterLabel {
                fact("DAC filter", filter)
            }
            if let xfeed = controller.crossfeedLevel {
                fact("Crossfeed", xfeed == 0 ? "off" : "\(xfeed)")
            }
            Text("Set these in the official app for now.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: value)
                .font(.system(size: 10))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}
