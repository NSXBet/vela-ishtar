// Sources/App/AppCoordinator.swift
// WP-06 06.1: the single owner of the live pipeline. Instantiates
// CredentialController + PollCoordinator (WP-03) and HistoryRepository
// (WP-02), consumes PollCoordinator.onOutcome, and routes every committed
// UsageSnapshot into (a) the burn buffer and (b) the history repository —
// BOTH keyed by `credentials.scope`, the persisted token_id→opaque-UUID
// mapping. The placeholder machine-level scope from the legacy
// PollStateMachine path is retired with it.
// Why: BASELINE.md's mandatory WP-06 gate. The scope mapping was unit-
// tested but never live; without this routing, history and burn data would
// keep partitioning under a random per-process UUID and orphan on restart.
// The coordinator also owns SummaryPresenter and hands the app layer one
// observation point (delegate) instead of N callbacks.
// RELEVANT FILES: Sources/App/PollCoordinator.swift, Sources/App/CredentialController.swift,
// Sources/VelaCore/HistoryRepository.swift, Sources/VelaCore/SummaryDisplayState.swift,
// Sources/App/SummaryPresenter.swift

import Foundation
import OSLog

private let coordinatorLog = Logger(subsystem: "com.nsxbet.velaishtar", category: "AppCoordinator")

/// What the app layer observes from the pipeline. Delivered on the main
/// actor after every outcome: the committed display state (or nil while
/// nothing has ever committed), the connection state, and the last good
/// response the v1 views (curve, day strip, pill) still render from.
public struct CoordinatorUpdate: Sendable {
    public let displayState: SummaryDisplayState?
    public let connection: ConnectionState
    /// The last good committed snapshot's response, retained across
    /// failures so a stale reading still renders.
    public let lastGoodResponse: UsageResponse?
    public let lastGoodReceivedAt: Date?
    /// The last committed snapshot this coordinator fed to burn/history.
    public let lastSnapshot: UsageSnapshot?
    /// True the FIRST time this failure episode moved to authenticationRequired.
    public let authJustRequired: Bool

    public init(
        displayState: SummaryDisplayState?,
        connection: ConnectionState,
        lastGoodResponse: UsageResponse?,
        lastGoodReceivedAt: Date?,
        lastSnapshot: UsageSnapshot?,
        authJustRequired: Bool = false
    ) {
        self.displayState = displayState
        self.connection = connection
        self.lastGoodResponse = lastGoodResponse
        self.lastGoodReceivedAt = lastGoodReceivedAt
        self.lastSnapshot = lastSnapshot
        self.authJustRequired = authJustRequired
    }
}

/// The central state application point. One per process.
@MainActor
public final class AppCoordinator {

    /// The sink the app layer (main.swift) observes.
    public var onUpdate: ((CoordinatorUpdate) -> Void)?

    public let credentials: CredentialController
    public let polls: PollCoordinator
    public let repository: HistoryRepository

    /// The v1 presentation buffer the pill renders from. Kept in the
    /// coordinator (not the retired PollStateMachine) and fed from the
    /// committed snapshot's scoped observation — the scope gate below.
    public private(set) var burnBuffer = BurnBuffer()
    /// Last committed response/receipt/snapshot, retained across failures
    /// so a stale reading still renders. Exposed read-only to the app layer.
    public private(set) var lastGoodResponse: UsageResponse?
    public private(set) var lastGoodReceivedAt: Date?
    public private(set) var lastSnapshot: UsageSnapshot?
    /// The period the UI has selected ("today"/"month"); re-derives the
    /// display state on change without a new poll.
    private let presenter = SummaryPresenter()
    private var selectedPeriod = "today"
    private var connection: ConnectionState = .noCredential
    /// Set when the poll coordinator reports authJustRequired; consumed by
    /// the next delivered update, then cleared.
    private var pendingAuthJustRequired = false

    public init(
        transport: any UsageTransport,
        store: any CredentialStoring,
        repository: HistoryRepository,
        scheduler: any PollScheduling = OneShotPollScheduler(),
        clock: any PollClock = SystemPollClock(),
        scopeMappingStore: UserDefaults = .standard,
        gatewayOrigin: String = "https://ai-llm-gateway.fbr.land"
    ) {
        self.repository = repository
        self.credentials = CredentialController(
            transport: transport,
            store: store,
            gatewayOrigin: gatewayOrigin,
            scopeMappingStore: scopeMappingStore
        )
        self.polls = PollCoordinator(
            transport: transport,
            credentials: credentials,
            scheduler: scheduler,
            clock: clock
        )
        self.polls.onOutcome = { [weak self] outcome in
            self?.handle(outcome)
        }
    }

    // MARK: - Lifecycle

    /// Boots the pipeline: adopt the stored credential (installing its
    /// persisted scope), load history, start the poll cadence.
    public func start() async {
        await credentials.refreshStatus()
        await credentials.adoptStoredCredential()
        await repository.load()
        polls.start()
    }

    public func stop() {
        polls.stop()
    }

    /// User-opened popover / wake / manual triggers — forwarded to the
    /// poll coordinator (coalescing, debounce, backoff are its policy).
    public func refresh(reason: RefreshReason) {
        polls.refresh(reason: reason)
    }

    /// The UI selected a model period. Re-derives the display state from
    /// already-committed data — no poll, no data wait (B10).
    public func setSelectedPeriod(_ period: String) {
        guard selectedPeriod != period else { return }
        selectedPeriod = period
        deliverUpdate()
    }

    /// The most recently delivered display state (nil before any committed
    /// outcome has been applied).
    public private(set) var latestDisplayState: SummaryDisplayState?

    /// A replacement token was accepted: refresh the poll generation so
    /// only the new credential's results commit, and re-derive state.
    public func credentialChanged() async {
        polls.setCredentialGeneration(credentials.generation &+ 1)
        connection = .connecting
        deliverUpdate()
        polls.refresh(reason: .credentialChanged)
    }

    // MARK: - Outcome handling (THE SCOPE GATE)

    /// The single commit path. Success outcomes carry a validated scoped
    /// snapshot; burn + history are fed from `snapshot.scope` — which is
    /// `credentials.scope` by construction (PollCoordinator refuses to
    /// commit a snapshot whose scope isn't the controller's live mapping).
    func handle(_ outcome: PollOutcome) {
        connection = outcome.state
        if outcome.authJustRequired { pendingAuthJustRequired = true }

        if let snapshot = outcome.snapshot {
            // MANDATORY GATE (docs/v2/BASELINE.md): the observation is
            // built with the credential-mapped scope, then routed to both
            // burn buffer and repository. Never the placeholder pollScope.
            let observation = Self.observation(from: snapshot)
            burnBuffer.record(observation)
            Task { [repository] in
                await repository.append(observation)
            }
            lastGoodResponse = snapshot.response
            lastGoodReceivedAt = snapshot.receivedAt
            lastSnapshot = snapshot
        }

        deliverUpdate()
    }

    /// Builds the Observation an accepted snapshot commits. Scope comes
    /// from the snapshot itself (credentials.scope at commit time); the
    /// gateway day and limit policy ride on the validated response.
    nonisolated static func observation(from snapshot: UsageSnapshot) -> Observation {
        Observation(
            id: UUID(),
            scope: snapshot.scope,
            gatewayDay: snapshot.gatewayDay,
            receivedAt: snapshot.receivedAt,
            cumulativeAmount: snapshot.response.dailyBudget.spentUSD,
            limitEnabled: snapshot.response.dailyBudget.limitEnabled,
            limitUSD: snapshot.response.dailyBudget.limitUSD,
            precision: .exactReceipt
        )
    }

    // MARK: - Delivery

    /// Re-derives the display state from committed data and notifies the
    /// app layer. No I/O: everything here is already in memory.
    private func deliverUpdate() {
        let context = SummaryPresenter.Context(
            snapshot: lastSnapshot,
            connection: connection,
            repository: repository
        )
        let state = presenter.displayState(
            from: context,
            selectedPeriod: selectedPeriod,
            now: Date()
        )
        latestDisplayState = state
        let authJust = pendingAuthJustRequired
        pendingAuthJustRequired = false
        onUpdate?(CoordinatorUpdate(
            displayState: state,
            connection: connection,
            lastGoodResponse: lastGoodResponse,
            lastGoodReceivedAt: lastGoodReceivedAt,
            lastSnapshot: lastSnapshot,
            authJustRequired: authJust
        ))
    }
}
