import SwiftUI
import AppKit

/// Emoji set designed for notes: status, priority, work, home… plus your own set and recent ones.
enum EmojiSets {
    static let categories: [(name: String, icon: String, emoji: String)] = [
        (L("Status"), "checkmark.circle", "✅☑️✔️❌⭕️⏳⌛️🔄⏸️▶️⏹️🚧🆗🆕🔜🔚💤🤔👀🙋"),
        (L("Priority"), "exclamationmark.triangle", "❗️‼️⁉️❓⚠️🔥⭐️🌟💥🚨🔴🟠🟡🟢🔵🟣⚫️⚪️🏁🎯📌📍"),
        (L("Work"), "briefcase", "💼📅📆🗓️⏰⏱️📞☎️📧✉️📨📝✏️🖊️📎📁📂🗂️📊📈📉💻🖥️🖨️🔑🔒🗝️🧾💡🔍📢"),
        (L("Home"), "house", "🏠🛒🧺🧹🧼🧽🪴🛏️🛁🚿🔧🔨🪛🧰🔌💡🗑️📦🚗⛽️🚲🚌✈️🧳💊🩺🏥🐶🐱👶"),
        (L("Food"), "fork.knife", "🍎🍌🍇🍓🍋🥑🥕🥦🍅🥔🍞🥐🧀🥚🥓🍗🍝🍕🍔🌮🍣🍰🍪🍫☕️🍵🥛🍷🍺💧"),
        (L("People"), "face.smiling", "😀😃😄😁😆😅😂🙂😉😊😍🥰😘😎🤓🥳😴😢😭😡🤯😱🤗👍👎👏🙌🙏💪👋✌️🤞"),
        (L("Hearts"), "heart", "❤️🧡💛💚💙💜🖤🤍🤎💖💗💕💞💯✨🎉🎊🎁🎈🎂"),
        (L("Symbols"), "number", "➡️⬅️⬆️⬇️↗️↘️↩️🔁🔂➕➖✖️➗🟰💲€💶🔢#️⃣*️⃣0️⃣1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣🔟"),
    ]

    private static let recentKey = "recentEmoji"

    static var recent: [String] {
        UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    static func remember(_ e: String) {
        var r = recent.filter { $0 != e }
        r.insert(e, at: 0)
        UserDefaults.standard.set(Array(r.prefix(24)), forKey: recentKey)
    }

    static func split(_ s: String) -> [String] {
        s.filter { !$0.isWhitespace && $0 != "," }.map(String.init)
    }
}

struct EmojiPicker: View {
    @EnvironmentObject var store: NoteStore
    let onPick: (String) -> Void
    @Local private var tab = 0          // 0 = favorites/recent, then the categories

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 2), count: 9)

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                tabButton(0, "star", L("Favorites and recent"))
                ForEach(EmojiSets.categories.indices, id: \.self) { i in
                    tabButton(i + 1, EmojiSets.categories[i].icon, EmojiSets.categories[i].name)
                }
            }
            Divider()
            ScrollView {
                if tab == 0 {
                    section(L("My set"), EmojiSets.split(store.settings.emojiFavorites))
                    let rec = EmojiSets.recent
                    if !rec.isEmpty { section(L("Recent"), rec) }
                } else {
                    let c = EmojiSets.categories[tab - 1]
                    section(c.name, EmojiSets.split(c.emoji))
                }
            }
            .frame(height: 210)
            Divider()
            HStack {
                Text(L("Click to insert · change the set in Settings")).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(L("All emoji…")) { NSApp.orderFrontCharacterPalette(nil) }
                    .font(.caption)
            }
        }
        .padding(10)
        .frame(width: 300)
    }

    private func tabButton(_ i: Int, _ icon: String, _ help: String) -> some View {
        Button { tab = i } label: {
            Image(systemName: icon)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(tab == i ? Color.accentColor.opacity(0.25) : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder private func section(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, e in
                    Button {
                        EmojiSets.remember(e)
                        onPick(e)
                    } label: {
                        Text(e).font(.system(size: 20)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }
}

/// Concrete container for the popover (a named type is needed to recognize it).
struct EmojiPickerHost: View {
    let store: NoteStore
    let onPick: (String) -> Void
    var body: some View { EmojiPicker(onPick: onPick).environmentObject(store) }
}
