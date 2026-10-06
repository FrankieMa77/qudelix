import SwiftUI

struct DeviceSettingsView: View {
    @EnvironmentObject var controller: QudelixController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device settings")
                .font(.system(size: 12, weight: .semibold))

            channelTrim
            Divider()
            volumeLimit

            if controller.dacFilterType != nil {
                Divider()
                dacFilter
            }

            if hasReadOnlyFacts {
                Divider()
                readOnlyFacts
            }

            Text("Stored on the 5K, so they persist across apps and reboots.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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

            trimSlider("L", name: "Left channel trim", value: controller.trimLeftDb) {
                controller.setTrimLeft($0)
            }
            trimSlider("R", name: "Right channel trim", value: controller.trimRightDb) {
                controller.setTrimRight($0)
            }

            Text("Pull one side down to centre an off-centre image, or to "
                 + "match ears that aren't.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trimSlider(_ label: String, name: String, value: Double,
                            set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set),
                   in: controller.trimRange)
                .controlSize(.small)
                .accessibilityLabel(name)
            Text(value == 0 ? "0 dB" : String(format: "%.1f dB", value))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(value == 0 ? .tertiary : .secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .disabled(!controller.canWriteNow)
    }

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
                .accessibilityLabel("Volume limit")
                .disabled(!controller.canWriteNow)
            Text("The ceiling the volume slider can reach. Lower it and the "
                 + "whole range moves with it.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dacFilter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DAC filter")
                .font(.system(size: 11, weight: .medium))
            Picker("", selection: Binding(
                get: { controller.dacFilterType ?? 0 },
                set: { controller.setDacFilter($0) })) {
                ForEach(QxStatusParser.dacFilters.indices, id: \.self) { i in
                    Text(QxStatusParser.dacFilters[i]).tag(i)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel("DAC filter")
            .disabled(!controller.canWriteNow)
            Text("How the DAC reconstructs the signal between samples. The "
                 + "differences are subtle enough that most listeners won't "
                 + "hear them — this just names what's running.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasReadOnlyFacts: Bool {
        controller.chargeSummary != nil
            || controller.batteryCare != nil
            || controller.crossfeedLevel != nil
    }

    private var readOnlyFacts: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let summary = controller.chargeSummary {
                fact("Power", summary)
            }
            if let care = controller.batteryCare {
                fact("Battery care", care ? "On" : "Off")
            }
            if controller.batteryLow {
                fact("Battery", "the 5K reports it as low")
            }
            if let xfeed = controller.crossfeedLevel {
                fact("Crossfeed", xfeed == 0 ? "off" : "\(xfeed)")
            }
            if controller.batteryCare != nil {
                Text("Battery care stops the charge short of full. Charging "
                     + "to 100% and staying there is what wears a lithium "
                     + "cell, so it earns its keep on a 5K that lives on a "
                     + "USB port.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
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
