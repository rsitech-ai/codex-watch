import Foundation
import SwiftUI
import WatchKit

@MainActor
protocol WatchBackgroundRefreshTask: AnyObject {
    var isApplicationRefresh: Bool { get }
    var expirationHandler: (() -> Void)? { get set }

    func complete()
}

extension WKRefreshBackgroundTask: WatchBackgroundRefreshTask {
    var isApplicationRefresh: Bool {
        self is WKApplicationRefreshBackgroundTask
    }

    func complete() {
        setTaskCompletedWithSnapshot(false)
    }
}

@MainActor
final class WatchBackgroundRefreshCoordinator {
    private let interval: TimeInterval
    private let clock: () -> Date
    private let work: () async -> Void
    private let cancelWork: () -> Void
    private let schedule: (Date) -> Void
    private var activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(
        interval: TimeInterval = 15 * 60,
        clock: @escaping () -> Date = Date.init,
        work: @escaping () async -> Void,
        cancelWork: @escaping () -> Void = {},
        schedule: @escaping (Date) -> Void
    ) {
        self.interval = max(60, interval)
        self.clock = clock
        self.work = work
        self.cancelWork = cancelWork
        self.schedule = schedule
    }

    func scheduleNext() {
        schedule(clock().addingTimeInterval(interval))
    }

    func handle(_ tasks: [any WatchBackgroundRefreshTask]) {
        for task in tasks {
            guard task.isApplicationRefresh else {
                task.expirationHandler = nil
                task.complete()
                continue
            }

            let identifier = ObjectIdentifier(task)
            let taskBox = WatchBackgroundRefreshTaskBox(task)
            let operation = Task { @MainActor [weak self, taskBox] in
                guard let self else { return }
                await work()
                guard activeTasks[identifier] != nil else { return }
                if !Task.isCancelled {
                    scheduleNext()
                }
                complete(taskBox.task)
            }
            activeTasks[identifier] = operation
            task.expirationHandler = { [weak self, taskBox] in
                Task { @MainActor [weak self, taskBox] in
                    guard let self else { return }
                    self.activeTasks[identifier]?.cancel()
                    self.cancelWork()
                    self.complete(taskBox.task)
                }
            }
        }
    }

    private func complete(_ task: any WatchBackgroundRefreshTask) {
        let identifier = ObjectIdentifier(task)
        guard activeTasks.removeValue(forKey: identifier) != nil else { return }
        task.expirationHandler = nil
        task.complete()
    }
}

private final class WatchBackgroundRefreshTaskBox: @unchecked Sendable {
    let task: any WatchBackgroundRefreshTask

    init(_ task: any WatchBackgroundRefreshTask) {
        self.task = task
    }
}

@MainActor
final class CodexWatchApplicationDelegate: NSObject, WKApplicationDelegate {
    let model: VoiceCaptureModel
    private let backgroundRefresh: WatchBackgroundRefreshCoordinator

    override init() {
        let model = VoiceCaptureModel()
        self.model = model
        backgroundRefresh = WatchBackgroundRefreshCoordinator(
            work: { [weak model] in
                await model?.handleBackgroundRefresh()
            },
            cancelWork: { [weak model] in
                model?.cancelBackgroundRefresh()
            },
            schedule: { preferredDate in
                WKApplication.shared().scheduleBackgroundRefresh(
                    withPreferredDate: preferredDate,
                    userInfo: nil
                ) { _ in }
            }
        )
        super.init()
    }

    func applicationDidFinishLaunching() {
        backgroundRefresh.scheduleNext()
    }

    func applicationDidEnterBackground() {
        backgroundRefresh.scheduleNext()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        backgroundRefresh.handle(Array(backgroundTasks))
    }
}

@main
struct CodexWatchApp: App {
    @WKApplicationDelegateAdaptor(CodexWatchApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                rootView
            }
            .environmentObject(appDelegate.model)
        }
    }

    @ViewBuilder
    private var rootView: some View {
#if DEBUG
        if let scenario = WatchRenderScenario.parse(
            environment: ProcessInfo.processInfo.environment
        ) {
            WatchRenderScenarioRoot(scenario: scenario)
        } else {
            ContentView()
        }
#else
        ContentView()
#endif
    }
}
