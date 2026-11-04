import FlockCore
import SwiftUI

/// The form behind FEATURES' Slack support row. It opens no chat itself:
/// Start types `/slack-support` into the pane, the only way a chat opens.
///
/// The list is fetched once per form and filtered here, because Slack limits
/// how often it can be read. With no list the box takes a typed name, and the
/// pane says if that name does not match.
struct ChatSlackSupportView: View {
    let theme: Theme
    let onBack: () -> Void
    let onClose: () -> Void
    let onStart: (_ person: String, _ problem: String) async -> Bool

    private enum PeopleState: Equatable {
        case loading
        case loaded([ChatSlackPerson])
        case unavailable
    }

    private enum Field { case person, problem }

    @Environment(ChatStore.self) private var chatStore
    @State private var peopleState: PeopleState
    @State private var entry: ChatSlackPersonEntry
    @State private var problem: String
    @State private var isStarting = false
    @FocusState private var focus: Field?

    /// The `preview` values exist only so a render test can draw each state
    /// without a live store; `.task` leaves a seeded list alone.
    init(
        theme: Theme, onBack: @escaping () -> Void, onClose: @escaping () -> Void,
        onStart: @escaping (_ person: String, _ problem: String) async -> Bool,
        previewPeople: [ChatSlackPerson]? = nil, previewUnavailable: Bool = false,
        previewQuery: String = "", previewPicked: ChatSlackPerson? = nil, previewProblem: String = ""
    ) {
        self.theme = theme
        self.onBack = onBack
        self.onClose = onClose
        self.onStart = onStart
        let seeded: PeopleState = previewUnavailable ? .unavailable : previewPeople.map(PeopleState.loaded) ?? .loading
        self._peopleState = State(initialValue: seeded)
        self._entry = State(initialValue: ChatSlackPersonEntry(query: previewQuery, picked: previewPicked))
        self._problem = State(initialValue: previewProblem)
    }

    private var results: [ChatSlackPerson] {
        guard case let .loaded(people) = peopleState, entry.picked == nil else { return [] }
        return ChatSlackPeopleSearch.matches(entry.query, in: people)
    }

    private var chosenPerson: String? {
        if let picked = entry.picked { return picked.person }
        return peopleState == .unavailable ? entry.query : nil
    }

    private var canStart: Bool {
        guard !isStarting, let chosenPerson else { return false }
        return ChatSlackCommand.line(person: chosenPerson, problem: problem) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChatSubviewHeader(theme: theme, title: "Slack support", width: ChromeMetrics.ChatSlack.width, onBack: onBack, onClose: onClose)
            personBand
                .zIndex(1)
            problemBand
        }
        .frame(width: ChromeMetrics.ChatSlack.width)
        .onAppear { focus = entry.picked == nil ? .person : .problem }
        .task {
            guard peopleState == .loading else { return }
            let people = await chatStore.slackPeople()
            peopleState = people.map(PeopleState.loaded) ?? .unavailable
        }
    }

    var personBand: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.ChatSlack.PersonBand.gap) {
            label("PERSON")
            personField
                .overlay(alignment: .topLeading) { resultsList }
            if peopleState == .unavailable {
                Text("Can't check names right now. Enter the full name")
                    .font(ChromeType.chatComposeFooterHint)
                    .foregroundStyle(theme.overlay0)
            }
        }
        .padding(.top, ChromeMetrics.ChatSlack.PersonBand.topPadding)
        .padding(.horizontal, ChromeMetrics.ChatSlack.horizontalPadding)
        .padding(.bottom, ChromeMetrics.ChatSlack.PersonBand.bottomPadding)
        .frame(width: ChromeMetrics.ChatSlack.width, alignment: .topLeading)
    }

    private var personField: some View {
        HStack(spacing: ChromeMetrics.ChatSlack.PersonBand.fieldGap) {
            TextField(
                "", text: Binding(get: { entry.query }, set: { entry.type($0) }),
                prompt: Text(personPrompt).foregroundStyle(theme.overlay0)
            )
                .textFieldStyle(.plain)
                .font(ChromeType.chatComposeFieldText)
                .foregroundStyle(theme.text)
                .focused($focus, equals: .person)
                .onSubmit(pickHighlighted)
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
            personFieldStatus
        }
        .padding(.horizontal, ChromeMetrics.ChatSlack.PersonBand.fieldHorizontalPadding)
        .frame(width: ChromeMetrics.ChatSlack.fieldWidth, height: ChromeMetrics.ChatSlack.PersonBand.fieldHeight)
        .background(RoundedRectangle(cornerRadius: ChromeMetrics.ChatSlack.fieldCornerRadius).fill(Color(theme.palette.surface0)))
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.ChatSlack.fieldCornerRadius)
                .strokeBorder(focus == .person ? theme.accent : Color(theme.palette.surface1), lineWidth: 1)
        )
    }

    private var personPrompt: String {
        peopleState == .unavailable ? "Full name" : "Search Slack"
    }

    @ViewBuilder
    private var personFieldStatus: some View {
        if entry.picked != nil {
            Image(systemName: "checkmark")
                .font(.system(size: ChromeMetrics.ChatSlack.PersonBand.statusIconSize, weight: .semibold))
                .foregroundStyle(theme.green)
        } else if peopleState == .loading {
            ChatSpinner(color: theme.overlay0, size: ChromeMetrics.ChatSlack.PersonBand.statusIconSize)
        } else if peopleState != .unavailable {
            Image(systemName: "magnifyingglass")
                .font(.system(size: ChromeMetrics.ChatSlack.PersonBand.statusIconSize))
                .foregroundStyle(theme.overlay0)
        }
    }

    /// Floats over Problem, so a search never changes the form's height.
    @ViewBuilder
    private var resultsList: some View {
        if !results.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, person in
                    resultRow(person, isHighlighted: index == entry.highlighted)
                }
            }
            .padding(ChromeMetrics.ChatSlack.Results.padding)
            .frame(width: ChromeMetrics.ChatSlack.fieldWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ChromeMetrics.ChatSlack.fieldCornerRadius).fill(Color(theme.palette.surface0)))
            .overlay(
                RoundedRectangle(cornerRadius: ChromeMetrics.ChatSlack.fieldCornerRadius)
                    .strokeBorder(Color(theme.palette.surface1), lineWidth: 1)
            )
            .offset(y: ChromeMetrics.ChatSlack.PersonBand.fieldHeight + ChromeMetrics.ChatSlack.Results.gap)
        }
    }

    private func resultRow(_ person: ChatSlackPerson, isHighlighted: Bool) -> some View {
        Button(action: { pick(person) }) {
            HStack(spacing: ChromeMetrics.ChatSlack.Results.rowGap) {
                Text(person.name)
                    .font(ChromeType.chatComposeFieldText)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let title = ChatSlackPeopleSearch.titleToShow(for: person, among: results) {
                    Text(title)
                        .font(ChromeType.chatComposeFooterHint)
                        .foregroundStyle(theme.subtext0)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, ChromeMetrics.ChatSlack.Results.rowHorizontalPadding)
            .frame(height: ChromeMetrics.ChatSlack.Results.rowHeight)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: ChromeMetrics.ChatSlack.Results.rowCornerRadius)
                        .fill(Color(theme.palette.selectionBg))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var problemBand: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.ChatSlack.ProblemBand.gap) {
            label("PROBLEM")
            ChatComposeField(
                theme: theme, text: $problem, size: ChromeMetrics.ChatSlack.ProblemBand.fieldSize,
                cornerRadius: ChromeMetrics.ChatSlack.fieldCornerRadius,
                verticalPadding: ChromeMetrics.ChatQuickSend.FieldBand.fieldVerticalPadding,
                horizontalPadding: ChromeMetrics.ChatQuickSend.FieldBand.fieldHorizontalPadding,
                stroke: focus == .problem ? theme.accent : Color(theme.palette.surface1)
            )
            .focused($focus, equals: .problem)
            HStack(spacing: 0) {
                Text("This pane talks to them on Slack")
                    .font(ChromeType.chatComposeFooterHint)
                    .foregroundStyle(theme.overlay0)
                Spacer(minLength: 0)
                ChatComposeSendButton(
                    theme: theme, title: "Start", fill: canStart ? theme.accent : Color(theme.palette.surface0),
                    size: ChromeMetrics.ChatQuickSend.FieldBand.sendButtonSize,
                    cornerRadius: ChromeMetrics.ChatQuickSend.FieldBand.sendButtonCornerRadius,
                    verticalPadding: ChromeMetrics.ChatQuickSend.FieldBand.sendButtonVerticalPadding,
                    horizontalPadding: ChromeMetrics.ChatQuickSend.FieldBand.sendButtonHorizontalPadding,
                    gap: ChromeMetrics.ChatQuickSend.FieldBand.sendButtonGap,
                    labelColor: canStart ? nil : theme.overlay0, action: start
                )
                .disabled(!canStart)
            }
            .frame(height: ChromeMetrics.ChatQuickSend.FieldBand.footerHeight)
        }
        .padding(.top, ChromeMetrics.ChatSlack.ProblemBand.topPadding)
        .padding(.horizontal, ChromeMetrics.ChatSlack.horizontalPadding)
        .padding(.bottom, ChromeMetrics.ChatSlack.ProblemBand.bottomPadding)
        .frame(width: ChromeMetrics.ChatSlack.width, alignment: .topLeading)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(ChromeType.chatPopoverSectionLabel).foregroundStyle(theme.overlay0)
    }

    private func pick(_ person: ChatSlackPerson) {
        entry.pick(person)
        focus = .problem
    }

    private func pickHighlighted() {
        guard results.indices.contains(entry.highlighted) else { return }
        pick(results[entry.highlighted])
    }

    private func moveHighlight(by step: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        entry.moveHighlight(by: step, among: results.count)
        return .handled
    }

    private func start() {
        guard let chosenPerson else { return }
        isStarting = true
        Task {
            let started = await onStart(chosenPerson, problem)
            isStarting = false
            if started { onBack() }
        }
    }
}

/// `ProgressView` draws in the system's colour, which all but vanishes on a
/// themed popover, and these waits are the only sign a chat is on its way.
struct ChatSpinner: View {
    let color: Color
    let size: CGFloat

    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.2, to: 1)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
            .onAppear { isSpinning = true }
    }
}
