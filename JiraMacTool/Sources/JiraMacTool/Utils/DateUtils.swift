import Foundation

enum DateUtils {
    static func formatDate(_ date: Date, format: String = "yyyy-MM-dd") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func parseDate(_ string: String, format: String = "yyyy-MM-dd") -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.date(from: string)
    }

    static func formateStringToDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    static func formatDateToString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func getWeek(_ date: Date) -> Int {
        let calendar = Calendar.current
        var weekday = calendar.component(.weekday, from: date) - 1
        if weekday == 0 { weekday = 7 }
        return weekday
    }

    static func daysBetween(_ from: Date, _ to: Date) -> Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to))
        return components.day ?? 0
    }

    static func addDate(_ date: Date, day: Int) -> Date {
        return Calendar.current.date(byAdding: .day, value: day, to: date) ?? date
    }

    static func getYesterday() -> String {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return formatDate(yesterday)
    }

    static func getCurrentDateTime() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    static func getMonthBetween(minDate: String, maxDate: String) -> [String] {
        guard let min = parseDate(minDate, format: "yyyy-MM"),
              let max = parseDate(maxDate, format: "yyyy-MM") else { return [] }
        var result: [String] = []
        var current = min
        let calendar = Calendar.current
        while current < max {
            result.append(formatDate(current, format: "yyyy-MM"))
            current = calendar.date(byAdding: .month, value: 1, to: current) ?? current
        }
        return result
    }
}
