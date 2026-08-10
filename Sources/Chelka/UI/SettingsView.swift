import AppKit
import SwiftUI
import ChelkaCore

/// Окно настроек.
struct SettingsView: View {
    @ObservedObject var theme: ThemeController
    @ObservedObject var widgetSize: WidgetSizeController
    @ObservedObject var clipboard: ClipboardService
    @ObservedObject var permissions: PermissionsService

    var body: some View {
        TabView {
            GeneralSettings(theme: theme, widgetSize: widgetSize)
                .tabItem { Label(T("settings.tab.general", "Основные"), systemImage: "gearshape") }

            ClipboardSettingsView(clipboard: clipboard)
                .tabItem { Label(T("settings.tab.clipboard", "Буфер"), systemImage: "doc.on.clipboard") }

            PermissionsSettings(permissions: permissions)
                .tabItem { Label(T("settings.tab.permissions", "Разрешения"), systemImage: "lock.shield") }

            AboutSettings()
                .tabItem { Label(T("settings.tab.about", "О программе"), systemImage: "info.circle") }
        }
        .frame(width: 460, height: 400)
    }
}

// MARK: - Основные

private struct GeneralSettings: View {
    @ObservedObject var theme: ThemeController
    @ObservedObject var widgetSize: WidgetSizeController
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Picker(T("settings.theme", "Тема:"), selection: themeBinding) {
                ForEach(AppTheme.allCases, id: \.self) { option in
                    Text(option.localizedTitle).tag(option)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent(T("settings.widgetSize", "Размер виджета:")) {
                HStack(spacing: 8) {
                    Slider(value: sizeBinding, in: WidgetSizeController.range)
                    Text(sizePercentText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Button(T("settings.widgetSize.reset", "Сбросить")) { widgetSize.reset() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            Toggle(T("settings.launchAtLogin", "Запускать при входе в систему"), isOn: launchBinding)

            if let launchError {
                Text(launchError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Section {
                LabeledContent(T("settings.hotkey", "Открыть виджет:")) {
                    Text("⌥⌘V")
                        .font(.body.monospaced())
                }
                Text(T("settings.hotkey.hint", "Пока виджет открыт сочетанием, цифры 1…9 выбирают запись, Esc закрывает."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(get: { theme.theme }, set: { theme.set($0) })
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { widgetSize.scale }, set: { widgetSize.set($0) })
    }

    private var sizePercentText: String {
        "\(Int((widgetSize.scale * 100).rounded()))%"
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                launchAtLogin = newValue
                guard !LaunchAtLogin.setEnabled(newValue) else {
                    launchError = nil
                    return
                }
                // Система могла запретить автозапуск — галочка сама по себе
                // ничего не изменит, нужно объяснить куда идти.
                launchAtLogin = LaunchAtLogin.isEnabled
                launchError = LaunchAtLogin.isBlockedBySystem
                    ? T("settings.launchBlocked", "Автозапуск запрещён в Системных настройках → Объекты входа.")
                    : T("settings.launchFailed", "Не удалось переключить автозапуск.")
            }
        )
    }
}

// MARK: - Буфер

private struct ClipboardSettingsView: View {
    @ObservedObject var clipboard: ClipboardService
    @State private var isConfirmingClear = false

    var body: some View {
        Form {
            Section(T("settings.capture", "Что сохранять")) {
                Toggle(T("settings.captureScreenshots", "Снимки экрана из папки снимков"), isOn: screenshotsBinding)
                Toggle(T("settings.skipConcealed", "Пропускать содержимое менеджеров паролей"), isOn: concealedBinding)
                Toggle(T("settings.browserArtwork", "Подтягивать обложку из браузера"), isOn: artworkBinding)
                Text(T("settings.browserArtwork.hint", "Единственное место, где приложение обращается к сети: по адресу открытой вкладки запрашивается картинка ролика или трека."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(T("settings.capture.hint", "По умолчанию сохраняется всё, что копируется, включая пароли. История шифруется на диске, но менеджеры паролей помечают своё содержимое — этот переключатель заставляет виджет такие записи игнорировать."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(T("settings.blacklist", "Чёрный список приложений")) {
                if clipboard.settings.blacklist.isEmpty {
                    Text(T("settings.blacklist.empty", "Пусто. Добавь приложение, чтобы скопированное при нём не сохранялось."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(clipboard.settings.blacklist).sorted(), id: \.self) { bundleID in
                        HStack {
                            Text(clipboard.appName(for: bundleID))
                            Spacer()
                            Button(T("settings.blacklist.remove", "Убрать")) {
                                clipboard.settings.removeFromBlacklist(bundleID)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }

                Button(T("settings.blacklist.add", "Добавить активное приложение…")) {
                    addFrontmostApp()
                }
            }

            Section {
                LabeledContent(T("settings.entries", "Записей:")) {
                    Text(String(format: T("settings.entries.value", "%1$d из %2$d, закреплено %3$d из %4$d"), clipboard.history.regular.count, ClipboardHistory.regularLimit, clipboard.history.pinned.count, ClipboardHistory.pinnedLimit))
                }

                Button(T("settings.clear", "Очистить историю"), role: .destructive) {
                    isConfirmingClear = true
                }
                .confirmationDialog(
                    T("settings.clear.confirm", "Очистить историю буфера?"),
                    isPresented: $isConfirmingClear
                ) {
                    Button(T("settings.clear.keepPinned", "Очистить, оставить закреплённые")) { clipboard.clear(keepPinned: true) }
                    Button(T("settings.clear.all", "Очистить всё"), role: .destructive) { clipboard.clear(keepPinned: false) }
                    Button(T("settings.cancel", "Отмена"), role: .cancel) {}
                }
            }
        }
        .formStyle(.grouped)
    }

    private var screenshotsBinding: Binding<Bool> {
        Binding(
            get: { clipboard.settings.captureScreenshots },
            set: { clipboard.settings.captureScreenshots = $0 }
        )
    }

    private var artworkBinding: Binding<Bool> {
        Binding(
            get: { clipboard.settings.fetchBrowserArtwork },
            set: { clipboard.settings.fetchBrowserArtwork = $0 }
        )
    }

    private var concealedBinding: Binding<Bool> {
        Binding(
            get: { clipboard.settings.skipConcealed },
            set: { clipboard.settings.skipConcealed = $0 }
        )
    }

    /// Добавляем приложение, которое было активным до открытия настроек:
    /// сейчас активны сами настройки, и от них толку нет.
    private func addFrontmostApp() {
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }

        guard let bundleID = candidates.first?.bundleIdentifier else { return }
        clipboard.settings.addToBlacklist(bundleID)
    }
}

// MARK: - Разрешения

private struct PermissionsSettings: View {
    @ObservedObject var permissions: PermissionsService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(permissions.items) { item in
                    PermissionRow(item: item, permissions: permissions)
                }
            }
            .padding(16)
        }
        .onAppear { permissions.refresh() }
    }
}

private struct PermissionRow: View {
    let item: PermissionsService.Item
    let permissions: PermissionsService

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if item.state != .granted, let url = item.settingsURL {
                    Button(T("settings.configure", "Настроить")) { permissions.open(url) }
                        .buttonStyle(.link)
                }
            }

            Text(item.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            if item.state != .granted {
                Text(item.cost)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch item.state {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch item.state {
        case .granted: return .green
        case .denied: return .orange
        case .unknown: return .secondary
        }
    }
}

// MARK: - О программе

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.topthird.inset.filled")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Chelka")
                .font(.title2.weight(.semibold))
            Text(AppInfo.versionString)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(T("settings.about.tagline", "Виджет для выреза MacBook: буфер обмена, музыка и состояние системы по наведению курсора."))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)

            Spacer()
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
