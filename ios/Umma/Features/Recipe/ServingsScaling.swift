import Foundation

/// Servings scaling for the live dial (brief 020, PRD §12.2). Pure: no I/O.
///
/// A port of the backend's `app/domains/recipes/scaling.py`, which computes pantry fit, sessions
/// and the coach. Both are tested against the same `servings_scaling.json`, so the amounts on the
/// recipe page are the amounts the cook screen shows. Change the two together.
///
/// - At the recipe's own servings every amount is exactly what the creator wrote.
/// - No quantity ("to taste") stays no quantity.
/// - `g` and `ml` round to whole numbers (to 5 from 100 up), never below 1.
/// - Other measured units round to kitchen fractions (¼, ⅓, ½, ⅔, ¾; ⅛ for spoons under 1).
/// - Counts and unknown units round to the nearest half, never below ½.
enum ServingsScaling {
    static let minServings = 1
    static let maxDialServings = 6

    /// Servings the dial offers: 1 to 6, plus the recipe's own when it is larger.
    static func dialStops(originalServings: Int) -> [Int] {
        var stops = Array(minServings...maxDialServings)
        if originalServings > maxDialServings { stops.append(originalServings) }
        return stops
    }

    static func isValid(servings: Int, originalServings: Int) -> Bool {
        dialStops(originalServings: originalServings).contains(servings)
    }

    /// `quantity` of `unit` for `servings` instead of `originalServings`.
    static func scale(_ quantity: Double?, unit: String?, originalServings: Int, servings: Int) -> Double? {
        guard let quantity, originalServings >= 1, servings >= 1, servings != originalServings, quantity > 0 else {
            return quantity
        }
        let raw = quantity * Double(servings) / Double(originalServings)
        switch UnitKind(unit) {
        case .metricSmall: return roundMetric(raw)
        case .spoon: return roundFraction(raw, allowEighth: true)
        case .fractional: return roundFraction(raw, allowEighth: false)
        case .count: return roundHalf(raw)
        }
    }

    // MARK: Rounding

    private static let fractions: [Double] = [0, 1.0 / 4, 1.0 / 3, 1.0 / 2, 2.0 / 3, 3.0 / 4, 1]

    private static func roundMetric(_ raw: Double) -> Double {
        let step = raw >= 100 ? 5 : 1
        return Double(max(1, halfUp(raw / Double(step)) * step))
    }

    private static func roundHalf(_ raw: Double) -> Double {
        max(0.5, Double(halfUp(raw * 2)) / 2)
    }

    /// Nearest non-zero kitchen amount. Ties go up: a little more is the safer side of "never zero".
    private static func roundFraction(_ raw: Double, allowEighth: Bool) -> Double {
        let whole = raw.rounded(.towardZero)
        var candidates = fractions.map { whole + $0 }
        if allowEighth, whole == 0 { candidates.append(1.0 / 8) }
        var best: (distance: Double, value: Double)?
        for candidate in candidates where candidate > 0 {
            let distance = (abs(candidate - raw) * 1e9).rounded(.toNearestOrEven) / 1e9
            if let current = best, current.distance < distance || (current.distance == distance && current.value >= candidate) {
                continue
            }
            best = (distance, candidate)
        }
        // Three decimals, like the backend's quantity columns: ⅓ and ⅔ travel as 0.333 and 0.667.
        return ((best?.value ?? raw) * 1000).rounded(.toNearestOrEven) / 1000
    }

    /// Round half up, the same way the backend does (not banker's rounding).
    private static func halfUp(_ value: Double) -> Int {
        Int(value + 0.5 + 1e-9)
    }

    // MARK: Units

    private enum UnitKind {
        case metricSmall, spoon, fractional, count

        /// Mirrors the backend's `canonical_unit`: trimmed, case-folded, trailing dots dropped.
        /// Anything not listed ("clove", "sheet", a bare "3 eggs") is a count.
        init(_ raw: String?) {
            var value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while value.hasSuffix(".") { value.removeLast() }
            self = Self.kinds[value] ?? .count
        }

        private static let kinds: [String: UnitKind] = {
            var kinds: [String: UnitKind] = [:]
            for name in ["g", "gram", "grams", "gr", "ml", "milliliter", "milliliters", "millilitre", "millilitres"] {
                kinds[name] = .metricSmall
            }
            for name in ["tsp", "teaspoon", "teaspoons", "tbsp", "tbs", "tablespoon", "tablespoons"] {
                kinds[name] = .spoon
            }
            for name in ["cup", "cups", "c", "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds",
                         "kg", "kilo", "kilos", "kilogram", "kilograms", "l", "liter", "liters", "litre", "litres",
                         "fl_oz", "fl oz", "fl. oz", "fluid ounce", "fluid ounces"] {
                kinds[name] = .fractional
            }
            return kinds
        }()
    }
}

extension Ingredient {
    /// This ingredient with its amount for `servings`. Everything else is the creator's.
    func scaled(originalServings: Int, servings: Int) -> Ingredient {
        Ingredient(id: id, name: name,
                   quantity: ServingsScaling.scale(quantity, unit: unit, originalServings: originalServings, servings: servings),
                   unit: unit, optional: optional, preparation: preparation, notes: notes, evidenceOrigin: evidenceOrigin)
    }
}

/// What the cook chose on the dial, carried to pantry fit and the start of a cook.
struct ServingsChoice: Equatable, Hashable, Sendable {
    let servings: Int
    let original: Int

    var isScaled: Bool { servings != original }
}

/// The servings control on the recipe page: 1 to 6 (plus the recipe's own when larger), the
/// "Scaled from N" label and the notice about what does not scale.
struct ServingsDial: Equatable, Sendable {
    let original: Int
    let servings: Int
    let stops: [Int]

    /// `chosen` nil, or not a stop on this recipe's dial, means the recipe's own servings.
    init?(original: Int, chosen: Int? = nil) {
        guard original >= 1 else { return nil }
        self.original = original
        let stops = ServingsScaling.dialStops(originalServings: original)
        self.stops = stops
        if let chosen, stops.contains(chosen) {
            servings = chosen
        } else {
            servings = original
        }
    }

    var choice: ServingsChoice { ServingsChoice(servings: servings, original: original) }
    var isScaled: Bool { servings != original }
    var label: String { "Serves \(servings)" }
    /// The stops either side of the current value; nil at the ends.
    var lower: Int? { stops.last { $0 < servings } }
    var higher: Int? { stops.first { $0 > servings } }

    var scaledFromText: String? { isScaled ? Self.scaledFrom(original) : nil }
    var notice: String? { isScaled ? Self.notice : nil }
    var resetTitle: String? { isScaled ? "Reset to \(original)" : nil }

    let accessibilityLabel = "Servings"
    var accessibilityValue: String {
        isScaled ? "\(Self.count(servings)), scaled from \(original)" : Self.count(servings)
    }

    static func scaledFrom(_ original: Int) -> String { "Scaled from \(original)" }
    static let notice = "Cooking times, pan sizes and step text aren’t scaled. Taste as you go."
    static func count(_ servings: Int) -> String { servings == 1 ? "1 serving" : "\(servings) servings" }
}
