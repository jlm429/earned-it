import Foundation

struct DailyQuote: Identifiable, Equatable {
    let id: String
    let text: String
}

enum QuoteService {
    static let quotes: [DailyQuote] = [
        DailyQuote(id: "start-small", text: "Start with one small task."),
        DailyQuote(id: "effort-adds-up", text: "A little effort adds up."),
        DailyQuote(id: "next-step", text: "Choose the next helpful step."),
        DailyQuote(id: "steady-work", text: "Steady work moves things forward."),
        DailyQuote(id: "care-counts", text: "Doing a small thing with care counts."),
        DailyQuote(id: "try-again", text: "A new try can change the day."),
        DailyQuote(id: "finish-one", text: "Finish one thing, then choose another."),
        DailyQuote(id: "help-family", text: "Your help makes a difference at home."),
        DailyQuote(id: "practice", text: "Practice makes a task feel easier."),
        DailyQuote(id: "notice-progress", text: "Notice the progress you made today."),
        DailyQuote(id: "patient", text: "Take your time and do it well."),
        DailyQuote(id: "keep-going", text: "Keep going, one task at a time."),
        DailyQuote(id: "fresh-start", text: "Today is a fresh place to begin."),
        DailyQuote(id: "ask-help", text: "Asking for help is part of learning."),
        DailyQuote(id: "teamwork", text: "Families work best when everyone helps."),
        DailyQuote(id: "honest-effort", text: "Give today's work your honest effort."),
        DailyQuote(id: "ready", text: "Getting ready is a useful first step."),
        DailyQuote(id: "learn", text: "Every finished task teaches you something."),
        DailyQuote(id: "thoughtful", text: "Thoughtful work is worth the time."),
        DailyQuote(id: "today", text: "Take care of today's work today.")
    ]

    static func quote(for date: Date, calendar: Calendar = AppCalendar.current) -> DailyQuote {
        let day = calendar.startOfDay(for: date)
        let ordinal = calendar.ordinality(of: .day, in: .era, for: day) ?? 0
        return quotes[ordinal % quotes.count]
    }
}
