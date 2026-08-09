import Foundation

struct DailyQuote: Identifiable, Equatable {
    let id: String
    let text: String
    let attribution: String
}

enum QuoteService {
    static let quotes: [DailyQuote] = [
        DailyQuote(id: "aurelius-start", text: "Begin the work in front of you.", attribution: "Inspired by Marcus Aurelius"),
        DailyQuote(id: "aesop-small", text: "Small steps can finish a big job.", attribution: "Inspired by Aesop"),
        DailyQuote(id: "confucius-steady", text: "Moving steadily still moves you forward.", attribution: "Inspired by Confucius"),
        DailyQuote(id: "seneca-ready", text: "Good results grow where effort meets readiness.", attribution: "Inspired by Seneca"),
        DailyQuote(id: "aristotle-habit", text: "What we practice helps shape who we become.", attribution: "Inspired by Aristotle"),
        DailyQuote(id: "epictetus-choice", text: "Your next choice is yours to make.", attribution: "Inspired by Epictetus"),
        DailyQuote(id: "franklin-action", text: "Well done matters more than well said.", attribution: "Benjamin Franklin"),
        DailyQuote(id: "douglass-work", text: "Progress asks us to keep working.", attribution: "Inspired by Frederick Douglass"),
        DailyQuote(id: "nightingale-begin", text: "A worthwhile task begins with a first step.", attribution: "Inspired by Florence Nightingale"),
        DailyQuote(id: "alalcott-cloud", text: "A little determination can clear a cloudy moment.", attribution: "Inspired by Louisa May Alcott"),
        DailyQuote(id: "emerson-finish", text: "Give today your honest effort.", attribution: "Inspired by Ralph Waldo Emerson"),
        DailyQuote(id: "thoreau-direction", text: "Go confidently in a thoughtful direction.", attribution: "Inspired by Henry David Thoreau"),
        DailyQuote(id: "teresa-small", text: "Small things can be done with great care.", attribution: "Inspired by Teresa of Ávila"),
        DailyQuote(id: "plutarch-mind", text: "Learning grows when we kindle curiosity.", attribution: "Inspired by Plutarch"),
        DailyQuote(id: "socrates-wonder", text: "Wonder is a good place to begin.", attribution: "Inspired by Socrates"),
        DailyQuote(id: "laozi-journey", text: "Every long journey starts where you are.", attribution: "Inspired by Laozi"),
        DailyQuote(id: "shakespeare-ready", text: "Readiness helps us meet the moment.", attribution: "Inspired by William Shakespeare"),
        DailyQuote(id: "newton-patience", text: "Patience and attention make a strong team.", attribution: "Inspired by Isaac Newton"),
        DailyQuote(id: "curie-understand", text: "Understanding can make a challenge feel smaller.", attribution: "Inspired by Marie Curie"),
        DailyQuote(id: "proverb-today", text: "Take care of today's work today.", attribution: "Traditional proverb")
    ]

    static func quote(for date: Date, calendar: Calendar = AppCalendar.current) -> DailyQuote {
        let day = calendar.startOfDay(for: date)
        let ordinal = calendar.ordinality(of: .day, in: .era, for: day) ?? 0
        return quotes[ordinal % quotes.count]
    }
}
