import Foundation

/// A numeric, five-field cron schedule translated into launchd calendar entries.
/// Calendar entries describe local wall-clock times; launchd owns wake behavior.
public struct CronSchedule: Sendable, Equatable {
    public let expression: String
    public let calendarIntervals: [[String: Int]]
    private let fields: [Field]
    private let daysUseIntersection: Bool

    public init(_ expression: String) throws {
        guard expression.utf8.count <= 512 else {
            throw CronScheduleError.invalidExpression("The cron expression is too long. Use a schedule of at most 512 bytes.")
        }
        let tokens = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count == 5 else {
            throw CronScheduleError.invalidExpression("Enter five cron fields: minute, hour, day of month, month, and weekday. Seconds and @ shortcuts are not supported.")
        }
        let specifications: [(String, ClosedRange<Int>)] = [
            ("Minute", 0...59), ("Hour", 0...23), ("Day of month", 1...31),
            ("Month", 1...12), ("Weekday", 0...7)
        ]
        let parsed = try zip(tokens, specifications).enumerated().map { index, item in
            try Field(item.0, name: item.1.0, range: item.1.1, isWeekday: index == 4)
        }
        self.expression = tokens.joined(separator: " ")
        fields = parsed
        // macOS cron uses AND when either day field begins with '*', including
        // stepped stars. Explicit numeric full ranges still participate in OR.
        daysUseIntersection = tokens[2].hasPrefix("*") || tokens[4].hasPrefix("*")
        let dayEntries = try Self.dayEntries(day: parsed[2], weekday: parsed[4], intersection: daysUseIntersection)
        let minutes = parsed[0].slots
        let hours = parsed[1].slots
        let months = parsed[3].slots
        let count = minutes.count * hours.count * months.count * dayEntries.count
        guard count <= 4_096 else {
            throw CronScheduleError.invalidExpression("This schedule expands to \(count) calendar entries; the limit is 4,096. Use a simpler schedule.")
        }
        var entries: [[String: Int]] = []
        entries.reserveCapacity(count)
        for minute in minutes {
            for hour in hours {
                for month in months {
                    for dayEntry in dayEntries {
                        var entry = dayEntry
                        entry["Minute"] = minute
                        entry["Hour"] = hour
                        entry["Month"] = month
                        entries.append(entry)
                    }
                }
            }
        }
        calendarIntervals = entries
    }

    public var summary: String {
        let minute = fields[0], hour = fields[1], month = fields[3]
        let noDayConstraint = calendarIntervals.allSatisfy { $0["Day"] == nil && $0["Weekday"] == nil }
        if minute.isFull && hour.isFull && month.isFull && noDayConstraint { return "Every minute" }
        if hour.isFull && month.isFull && noDayConstraint {
            if let step = minute.starStep, step > 1, step < 60, 60 % step == 0 {
                return "Every \(step) minutes"
            }
            if minute.values.count == 1 {
                return String(format: "Every hour at :%02d", minute.values[0])
            }
        }
        if minute.values.count == 1 && hour.values.count == 1 && month.isFull {
            let time = String(format: "%02d:%02d", hour.values[0], minute.values[0])
            if noDayConstraint { return "Daily at \(time)" }
            if fields[2].isFull && fields[4].values == [1, 2, 3, 4, 5] && daysUseIntersection {
                return "Weekdays at \(time)"
            }
            if fields[2].isFull && fields[4].values.count == 1 && daysUseIntersection {
                let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
                return "Every \(weekdays[fields[4].values[0]]) at \(time)"
            }
        }
        return "Cron: \(expression)"
    }

    /// Evaluates the source cron semantics, independently of the launchd expansion.
    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = components.minute, let hour = components.hour,
              let day = components.day, let month = components.month, let weekday = components.weekday,
              fields[0].values.contains(minute), fields[1].values.contains(hour), fields[3].values.contains(month) else { return false }
        let dayMatches = fields[2].values.contains(day)
        let weekdayMatches = fields[4].values.contains(weekday - 1)
        return daysUseIntersection ? dayMatches && weekdayMatches : dayMatches || weekdayMatches
    }

    private static func dayEntries(day: Field, weekday: Field, intersection: Bool) throws -> [[String: Int]] {
        if day.isFull && weekday.isFull { return [[:]] }
        if intersection {
            if day.isFull { return weekday.values.map { ["Weekday": $0] } }
            if weekday.isFull { return day.values.map { ["Day": $0] } }
            throw CronScheduleError.invalidExpression("This stepped day/weekday combination cannot be represented exactly by launchd. Set either day of month or weekday to *.")
        }
        // Under OR semantics, a full numeric range makes every date eligible.
        if day.isFull || weekday.isFull { return [[:]] }
        return day.values.map { ["Day": $0] } + weekday.values.map { ["Weekday": $0] }
    }

    private struct Field: Sendable, Equatable {
        let values: [Int]
        let isFull: Bool
        let starStep: Int?

        var slots: [Int?] { isFull ? [nil] : values.map { Optional($0) } }

        init(_ token: String, name: String, range: ClosedRange<Int>, isWeekday: Bool) throws {
            let members = token.split(separator: ",", omittingEmptySubsequences: false)
            var selected: Set<Int> = []
            for member in members {
                guard !member.isEmpty else { throw Self.invalid(name, "lists cannot contain an empty item.") }
                let parts = member.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count <= 2 else { throw Self.invalid(name, "an item can contain only one step separator (/).") }
                let base = parts[0]
                let step: Int
                if parts.count == 2 {
                    step = try Self.number(parts[1], name: name, description: "step")
                    guard step > 0 else { throw Self.invalid(name, "the step must be greater than zero.") }
                } else { step = 1 }
                let lower: Int, upper: Int
                if base == "*" {
                    lower = range.lowerBound
                    upper = range.upperBound
                } else {
                    let bounds = base.split(separator: "-", omittingEmptySubsequences: false)
                    guard bounds.count == 1 || bounds.count == 2 else { throw Self.invalid(name, "use an inclusive range such as 1-5.") }
                    lower = try Self.number(bounds[0], name: name, description: "value")
                    if bounds.count == 2 {
                        upper = try Self.number(bounds[1], name: name, description: "range end")
                        guard lower <= upper else { throw Self.invalid(name, "ranges must be ascending; wrapping ranges are not supported.") }
                    } else {
                        guard parts.count == 1 else { throw Self.invalid(name, "steps must follow * or a range, such as */5 or 1-9/2.") }
                        upper = lower
                    }
                    guard range.contains(lower) && range.contains(upper) else {
                        throw Self.invalid(name, "values must be between \(range.lowerBound) and \(range.upperBound).")
                    }
                }
                var value = lower
                while true {
                    selected.insert(isWeekday && value == 7 ? 0 : value)
                    // Avoid overflow even when a valid positive step is Int.max.
                    if step > upper - value { break }
                    value += step
                }
            }
            values = selected.sorted()
            let full = isWeekday ? Set(0...6) : Set(range)
            isFull = selected == full
            if token.hasPrefix("*/"), !token.contains(",") { starStep = Int(token.dropFirst(2)) }
            else { starStep = nil }
        }

        private static func number(_ text: Substring, name: String, description: String) throws -> Int {
            guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
                throw invalid(name, "\(description) must be an unsigned number. Names and cron extensions are not supported.")
            }
            guard let value = Int(text) else { throw invalid(name, "\(description) is too large.") }
            return value
        }

        private static func invalid(_ name: String, _ message: String) -> CronScheduleError {
            .invalidExpression("\(name): \(message)")
        }
    }
}

public enum CronScheduleError: LocalizedError, Sendable, Equatable {
    case invalidExpression(String)

    public var errorDescription: String? {
        switch self { case .invalidExpression(let message): return message }
    }
}
