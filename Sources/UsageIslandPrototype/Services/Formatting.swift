import Foundation

public enum UsageFormatting {
    public static func windowDuration(_ durationMinutes: Int) -> String {
        switch durationMinutes {
        case 300:
            return "Cinco horas"
        case 10_080:
            return "Semana"
        case 1_440:
            return "1 día"
        case let minutes where minutes.isMultiple(of: 1_440):
            return "\(minutes / 1_440) días"
        case 60:
            return "1 hora"
        case let minutes where minutes.isMultiple(of: 60):
            return "\(minutes / 60) horas"
        case 1:
            return "1 minuto"
        default:
            return "\(durationMinutes) minutos"
        }
    }

    public static func resetText(until date: Date?, now: Date = .now) -> String {
        guard let date else { return "—" }
        return resetText(until: date, now: now)
    }

    public static func resetText(until date: Date, now: Date = .now) -> String {
        let remaining = max(0, date.timeIntervalSince(now))
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    public static func currency(_ value: Decimal?) -> String? {
        guard let value else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber)
    }

    public static func secondaryWeeklyRemainingPercent(
        for snapshot: UsageSnapshot
    ) -> Int? {
        guard let weeklyWindow = snapshot.weeklyWindow,
              weeklyWindow.durationMinutes
                != snapshot.preferredWindow.durationMinutes else {
            return nil
        }
        return weeklyWindow.remainingPercent
    }
}
