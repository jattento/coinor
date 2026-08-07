import SwiftUI

enum ProjectIconChoice: String, CaseIterable, Identifiable {
    case folder
    case finance
    case book
    case education
    case pencil
    case writing
    case code
    case terminal
    case music
    case popcorn
    case paintbrush
    case palette
    case health
    case operations
    case nature
    case work
    case analytics
    case sports
    case fitness
    case notes
    case legal
    case broadcast
    case travel
    case globe
    case tools
    case pet
    case science
    case ideas
    case favorite
    case garden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: "Folder"
        case .finance: "Finance"
        case .book: "Book"
        case .education: "Education"
        case .pencil: "Pencil"
        case .writing: "Writing"
        case .code: "Code"
        case .terminal: "Terminal"
        case .music: "Music"
        case .popcorn: "Media"
        case .paintbrush: "Design"
        case .palette: "Art"
        case .health: "Health"
        case .operations: "Operations"
        case .nature: "Nature"
        case .work: "Work"
        case .analytics: "Analytics"
        case .sports: "Sports"
        case .fitness: "Fitness"
        case .notes: "Notes"
        case .legal: "Legal"
        case .broadcast: "Broadcast"
        case .travel: "Travel"
        case .globe: "Global"
        case .tools: "Tools"
        case .pet: "Pet"
        case .science: "Science"
        case .ideas: "Ideas"
        case .favorite: "Favorite"
        case .garden: "Garden"
        }
    }

    var systemName: String {
        switch self {
        case .folder: "folder"
        case .finance: "dollarsign.circle"
        case .book: "book.closed"
        case .education: "graduationcap"
        case .pencil: "pencil"
        case .writing: "pencil.tip"
        case .code: "curlybraces"
        case .terminal: "terminal"
        case .music: "music.note"
        case .popcorn: "popcorn"
        case .paintbrush: "paintbrush"
        case .palette: "paintpalette"
        case .health: "stethoscope"
        case .operations: "asterisk"
        case .nature: "camera.macro"
        case .work: "briefcase"
        case .analytics: "chart.bar"
        case .sports: "basketball"
        case .fitness: "dumbbell"
        case .notes: "list.bullet.rectangle.portrait"
        case .legal: "scalemass"
        case .broadcast: "globe.desk"
        case .travel: "airplane"
        case .globe: "globe"
        case .tools: "wrench"
        case .pet: "pawprint"
        case .science: "testtube.2"
        case .ideas: "brain"
        case .favorite: "heart"
        case .garden: "leaf"
        }
    }

    var persistedName: String? {
        self == .folder ? nil : systemName
    }

    static let supportedSystemNames = Set(
        allCases.map(\.systemName)
    )

    static func choice(for systemName: String) -> ProjectIconChoice {
        switch systemName {
        case "app":
            return .work
        case "cloud":
            return .globe
        case "cylinder":
            return .analytics
        case "server.rack":
            return .terminal
        case "wrench.and.screwdriver":
            return .tools
        default:
            break
        }
        return allCases.first { $0.systemName == systemName } ?? .folder
    }
}

enum ProjectIconColorChoice: String, CaseIterable, Identifiable {
    case standard
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink

    var id: String { rawValue }

    var persistedName: String? {
        self == .standard ? nil : rawValue
    }

    var color: Color {
        switch self {
        case .standard: Color(nsColor: .systemGray)
        case .red: Color(nsColor: .systemRed)
        case .orange: Color(nsColor: .systemOrange)
        case .yellow: Color(nsColor: .systemYellow)
        case .green: Color(nsColor: .systemGreen)
        case .blue: Color(nsColor: .systemBlue)
        case .purple: Color(nsColor: .systemPurple)
        case .pink: Color(nsColor: .systemPink)
        }
    }

    var title: String {
        rawValue.capitalized
    }

    static func choice(for persistedName: String?) -> ProjectIconColorChoice {
        persistedName.flatMap(ProjectIconColorChoice.init(rawValue:))
            ?? .standard
    }
}
