import Foundation

enum EQFilterType: String, Codable, Equatable, Sendable {
    case peaking
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case notch
    case bandPass
    case allPass

    var usesGain: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf:
            return true
        case .lowPass, .highPass, .notch, .bandPass, .allPass:
            return false
        }
    }
}

struct EQBand: Codable, Equatable, Sendable {
    var enabled: Bool
    var type: EQFilterType
    var frequencyHz: Double
    var gainDB: Double
    var q: Double

    init(
        enabled: Bool = true,
        type: EQFilterType,
        frequencyHz: Double,
        gainDB: Double = 0.0,
        q: Double = 0.7071067811865476
    ) {
        self.enabled = enabled
        self.type = type
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
    }
}

struct EQProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var preampDB: Double
    var bands: [EQBand]

    init(
        id: UUID = UUID(),
        name: String,
        preampDB: Double = 0.0,
        bands: [EQBand]
    ) {
        self.id = id
        self.name = name
        self.preampDB = preampDB
        self.bands = bands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.preampDB = try container.decodeIfPresent(Double.self, forKey: .preampDB) ?? 0.0
        self.bands = try container.decodeIfPresent([EQBand].self, forKey: .bands) ?? []
    }

    var isActive: Bool {
        if abs(preampDB) >= 0.001 {
            return true
        }
        return bands.contains { band in
            band.enabled && (!band.type.usesGain || abs(band.gainDB) >= 0.001)
        }
    }

    var activeBandCount: Int {
        bands.filter { $0.enabled && (!$0.type.usesGain || abs($0.gainDB) >= 0.001) }.count
    }
}

struct BiquadCoefficients: Equatable, Sendable {
    var b0: Double = 1.0
    var b1: Double = 0.0
    var b2: Double = 0.0
    var a1: Double = 0.0
    var a2: Double = 0.0

    static let identity = BiquadCoefficients()

    /// Computes normalized Audio EQ Cookbook biquad coefficients for the given sample rate.
    /// Returns `nil` when the filter is invalid or degenerate at the target sample rate.
    static func design(band: EQBand, sampleRate: Double) -> BiquadCoefficients? {
        guard band.enabled, sampleRate > 1_000, band.frequencyHz > 1.0 else { return nil }
        if band.type.usesGain && abs(band.gainDB) < 0.001 {
            return nil
        }

        let clampedFreq = min(band.frequencyHz, sampleRate * 0.49)
        let q = max(0.05, min(50.0, band.q))
        let w0 = 2.0 * Double.pi * clampedFreq / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)

        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double

        switch band.type {
        case .peaking:
            let a = pow(10.0, band.gainDB / 40.0)
            b0 = 1.0 + alpha * a
            b1 = -2.0 * cosW0
            b2 = 1.0 - alpha * a
            a0 = 1.0 + alpha / a
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha / a

        case .lowShelf:
            let a = pow(10.0, band.gainDB / 40.0)
            let twoSqrtAAlpha = 2.0 * sqrt(a) * alpha
            b0 = a * ((a + 1.0) - (a - 1.0) * cosW0 + twoSqrtAAlpha)
            b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cosW0)
            b2 = a * ((a + 1.0) - (a - 1.0) * cosW0 - twoSqrtAAlpha)
            a0 = (a + 1.0) + (a - 1.0) * cosW0 + twoSqrtAAlpha
            a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cosW0)
            a2 = (a + 1.0) + (a - 1.0) * cosW0 - twoSqrtAAlpha

        case .highShelf:
            let a = pow(10.0, band.gainDB / 40.0)
            let twoSqrtAAlpha = 2.0 * sqrt(a) * alpha
            b0 = a * ((a + 1.0) + (a - 1.0) * cosW0 + twoSqrtAAlpha)
            b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cosW0)
            b2 = a * ((a + 1.0) + (a - 1.0) * cosW0 - twoSqrtAAlpha)
            a0 = (a + 1.0) - (a - 1.0) * cosW0 + twoSqrtAAlpha
            a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cosW0)
            a2 = (a + 1.0) - (a - 1.0) * cosW0 - twoSqrtAAlpha

        case .lowPass:
            b0 = (1.0 - cosW0) * 0.5
            b1 = 1.0 - cosW0
            b2 = (1.0 - cosW0) * 0.5
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha

        case .highPass:
            b0 = (1.0 + cosW0) * 0.5
            b1 = -(1.0 + cosW0)
            b2 = (1.0 + cosW0) * 0.5
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha

        case .notch:
            b0 = 1.0
            b1 = -2.0 * cosW0
            b2 = 1.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha

        case .bandPass:
            b0 = alpha
            b1 = 0.0
            b2 = -alpha
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha

        case .allPass:
            b0 = 1.0 - alpha
            b1 = -2.0 * cosW0
            b2 = 1.0 + alpha
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        }

        guard a0.isFinite, abs(a0) > 1e-12 else { return nil }
        let invA0 = 1.0 / a0
        return BiquadCoefficients(
            b0: b0 * invA0,
            b1: b1 * invA0,
            b2: b2 * invA0,
            a1: a1 * invA0,
            a2: a2 * invA0
        )
    }
}

struct CompiledEQChain: Equatable, Sendable {
    static let maxBands = 32

    let isActive: Bool
    let preampGain: Float
    let hasPositiveBoost: Bool
    let coefficients: [BiquadCoefficients]

    static let inactive = CompiledEQChain(
        isActive: false,
        preampGain: 1.0,
        hasPositiveBoost: false,
        coefficients: []
    )

    static func compile(profiles: [EQProfile], sampleRate: Double) -> CompiledEQChain {
        let activeProfiles = profiles.filter(\.isActive)
        guard !activeProfiles.isEmpty else { return .inactive }

        var totalPreampDB = 0.0
        var coeffs: [BiquadCoefficients] = []
        coeffs.reserveCapacity(min(maxBands, activeProfiles.reduce(0) { $0 + $1.bands.count }))
        var peakBandGainDB = 0.0

        for profile in activeProfiles {
            totalPreampDB += profile.preampDB
            for band in profile.bands {
                guard coeffs.count < maxBands else { break }
                if let designed = BiquadCoefficients.design(band: band, sampleRate: sampleRate) {
                    coeffs.append(designed)
                    if band.type.usesGain && band.gainDB > 0 {
                        peakBandGainDB += band.gainDB
                    }
                }
            }
        }

        let clampedPreampDB = max(-36.0, min(24.0, totalPreampDB))
        let preampGain = Float(pow(10.0, clampedPreampDB / 20.0))
        let hasActivePreamp = abs(preampGain - 1.0) >= 0.0005
        guard !coeffs.isEmpty || hasActivePreamp else { return .inactive }

        return CompiledEQChain(
            isActive: true,
            preampGain: preampGain,
            hasPositiveBoost: clampedPreampDB > 0.01 || (peakBandGainDB + clampedPreampDB) > 0.01,
            coefficients: coeffs
        )
    }
}

enum ParametricEQParseError: LocalizedError, Equatable {
    case noValidFilters

    var errorDescription: String? {
        switch self {
        case .noValidFilters:
            return L10n.tr(
                "eq.import.error.no_filters",
                defaultValue: "No valid parametric EQ filters or preamp settings were found in this file."
            )
        }
    }
}

enum ParametricEQParser {
    private static let butterworthQ = 1.0 / sqrt(2.0)

    static func parse(_ text: String, name: String) throws -> EQProfile {
        var preampDB = 0.0
        var hasPreamp = false
        var bands: [EQBand] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let stripped = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let line = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let parsedPreamp = parsePreampLine(line) {
                preampDB = parsedPreamp
                hasPreamp = true
                continue
            }

            if let band = parseFilterLine(line) {
                bands.append(band)
            }
        }

        guard hasPreamp || !bands.isEmpty else {
            throw ParametricEQParseError.noValidFilters
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return EQProfile(
            name: trimmedName.isEmpty ? "EQ" : trimmedName,
            preampDB: preampDB,
            bands: bands
        )
    }

    private static func parsePreampLine(_ line: String) -> Double? {
        let pattern = #"(?i)^Preamp\s*:\s*([+-]?\d+(?:\.\d+)?)\s*(?:dB)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return Double(line[range])
    }

    private static func parseFilterLine(_ line: String) -> EQBand? {
        // Examples:
        // Filter 1: ON PK Fc 105 Hz Gain 3.4 dB Q 0.70
        // Filter 2: OFF LSC Fc 105 Hz Gain 2.0 dB Q 0.71
        // Filter: ON LS 6dB Fc 80 Hz Gain 4.0 dB
        let headerPattern = #"(?i)^Filter(?:\s+\d+)?\s*:\s*(ON|OFF)\s+([A-Za-z0-9]+)(.*)$"#
        guard let headerRegex = try? NSRegularExpression(pattern: headerPattern),
              let match = headerRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let stateRange = Range(match.range(at: 1), in: line),
              let typeRange = Range(match.range(at: 2), in: line),
              let tailRange = Range(match.range(at: 3), in: line) else {
            return nil
        }

        let enabled = line[stateRange].uppercased() == "ON"
        guard let filterType = mapFilterType(String(line[typeRange])) else {
            return nil
        }

        let tail = String(line[tailRange])
        guard let freq = extractNumber(pattern: #"(?i)\bFc\s+([+-]?\d+(?:\.\d+)?)\s*(?:Hz)?"#, in: tail),
              freq > 0 else {
            return nil
        }

        let gain = extractNumber(pattern: #"(?i)\bGain\s+([+-]?\d+(?:\.\d+)?)\s*(?:dB)?"#, in: tail) ?? 0.0
        let q: Double
        if let explicitQ = extractNumber(pattern: #"(?i)\bQ\s+([+-]?\d+(?:\.\d+)?)"#, in: tail), explicitQ > 0 {
            q = explicitQ
        } else if let bwOct = extractNumber(pattern: #"(?i)\bBW\s+Oct\s+([+-]?\d+(?:\.\d+)?)"#, in: tail), bwOct > 0 {
            let pow2 = pow(2.0, bwOct)
            let denom = pow2 - 1.0
            q = denom > 1e-6 ? (sqrt(pow2) / denom) : butterworthQ
        } else {
            q = butterworthQ
        }

        return EQBand(
            enabled: enabled,
            type: filterType,
            frequencyHz: freq,
            gainDB: gain,
            q: q
        )
    }

    private static func mapFilterType(_ token: String) -> EQFilterType? {
        switch token.uppercased() {
        case "PK", "PEQ":
            return .peaking
        case "LS", "LSC", "LOWSHELF":
            return .lowShelf
        case "HS", "HSC", "HIGHSHELF":
            return .highShelf
        case "LP", "LPQ", "LOWPASS":
            return .lowPass
        case "HP", "HPQ", "HIGHPASS":
            return .highPass
        case "NO", "NOTCH":
            return .notch
        case "BP", "BANDPASS":
            return .bandPass
        case "AP", "ALLPASS":
            return .allPass
        default:
            return nil
        }
    }

    private static func extractNumber(pattern: String, in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[range])
    }
}
