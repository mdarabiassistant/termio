import AppKit
import Foundation
import GhosttyKit
import GhosttyTerminal
import TermioShared
import os

/// Handles `termio sessions …` requests from `SessionControlListener`. Every
/// operation is scoped to the caller's own project (resolved from the caller's
/// `TERMIO_SESSION` or, failing that, its working directory) so an agent can only
/// see and drive its siblings, never sessions in unrelated projects — unpeel's
/// "project-scoped by default" rule.
///
/// Sessions are addressed by their id: canonically a deep link
/// (`termio://session/<uuid>`, see docs/design/20260801-session-deep-link.md), or a bare
/// id/prefix. The address names the pane, never its mutable contents, so any
/// copied address survives the session promoting or demoting. `send` with *no*
/// target starts a fresh agent session — targeting an existing sibling is
/// always an explicit act.
extension TermioStore {
    /// Per-op enter/exit timing for control requests, readable via
    /// `log stream --predicate 'category == "session-control"'`. The exit line's
    /// elapsed time is how long the op occupied the request path — the number
    /// that catches head-of-line blocking on the main actor (design doc §4.2).
    private static let controlTiming = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "sh.termio.app", category: "session-control")

    func handleSessionControl(_ request: ControlRequest) async -> Data {
        let entered = ContinuousClock.now
        Self.controlTiming.info("enter op=\(request.op, privacy: .public)")
        defer {
            let elapsed = entered.duration(to: .now)
            Self.controlTiming.info(
                "exit op=\(request.op, privacy: .public) elapsed_ms=\(Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000), privacy: .public)")
        }
        guard settings.sessionControlEnabled else {
            return controlError(request, "disabled",
                "Session control is off. Enable it in Termio ▸ Settings ▸ Agents.")
        }
        guard let scope = callerScope(session: request.callerSession, cwd: request.callerCwd) else {
            return controlError(request, "no_scope",
                "Couldn’t tell which project you’re in. Run this from inside a Termio session.")
        }
        // In a turn the user didn't start, the Chief of Staff can read and speak
        // but not act: an event produces a notice, never an action
        // (docs/design/20261019-chief-of-staff.md §7.7).
        if scope.isFleet, ChiefOfStaffGuard.refuses(op: request.op, origin: chiefOfStaff.origin) {
            return controlError(request, "not_user_turn", """
                This turn began with a [termio] event, not with the user. Events produce \
                notices, never actions: tell the user what happened, and act once they answer.
                """)
        }

        switch request.op {
        case "list": return listSessions(in: scope, request: request)
        case "send", "answer": return await sendText(request, in: scope)
        case "close": return closeTab(request, in: scope)
        case "focus": return focusSession(request, in: scope)
        case "read": return await readScreen(request, in: scope)
        case "notify": return notify(request, in: scope)
        default:
            return controlError(request, "bad_op", "Unknown op '\(request.op)'.")
        }
    }

    /// `termio notify` — post a macOS notification on the agent's explicit request
    /// ("I’m done", "I need input"). Unlike the automatic task-completion banner,
    /// this carries no policy gate: the agent asked for it, so it fires whether or
    /// not termio is frontmost and regardless of turn length. The calling session
    /// rides in the banner so a click focuses it, and the project supplies the
    /// subtitle. The body is the only required argument.
    private func notify(_ request: ControlRequest, in scope: ControlScope) -> Data {
        let body = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return controlError(request, "empty_body",
                "notify needs a message, e.g. `termio notify \"tests passed\"`.")
        }
        // The calling session, when there is one, makes the banner clickable back to
        // the agent that posted it. A plain-shell caller simply posts an unlinked one.
        let caller = request.callerSession
            .flatMap { UUID(uuidString: $0) }
            .flatMap { session($0) }
        // `--session`: the session the notice is about, so a click opens that one
        // instead of the caller. Resolved in the caller's own scope.
        var about: Session?
        if let token = request.about?.trimmingCharacters(in: .whitespaces), !token.isEmpty {
            switch resolveTarget(token, in: scope) {
            case .found(let session):
                about = session
            case .notFound:
                return controlError(request, "not_found", targetNotFoundMessage(request.about))
            case .ambiguous:
                return controlError(request, "ambiguous",
                    "'\(token)' matches more than one session; use a longer id.")
            }
        }
        if scope.isFleet {
            // The Chief of Staff's voice: kept for its row and the phone, and a
            // banner only when its pane isn't already in front of you.
            let title = localized("Chief of Staff")
            noteChiefOfStaffNotice(body, about: about?.id)
            if !chiefOfStaffIsInView() {
                TaskNotificationCenter.shared.postManual(
                    title: title, body: body,
                    project: about.flatMap { project(for: $0.id) }, session: about ?? caller)
            }
            return control(request, ok: true, text: "notified", json: ["notified": true, "title": title])
        }
        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false)
            ? title!
            : caller.map { effectiveAgent(for: $0).displayName } ?? "Termio"
        TaskNotificationCenter.shared.postManual(
            title: resolvedTitle, body: body, project: scope.project, session: about ?? caller)
        publishCompanionNotice(from: caller?.id, about: about?.id, title: resolvedTitle, body: body)
        return control(request, ok: true, text: "notified",
                       json: ["notified": true, "title": resolvedTitle])
    }

    /// Validates a `watch` subscription and returns the caller's project id to scope
    /// the stream to plus the initial status snapshot (one event per scoped session,
    /// unless the client opted out), or an error payload to write back before hanging
    /// up. The same gating as any control op (session control enabled, caller
    /// resolves to a project); the streaming itself is `SessionWatchHub`'s job.
    func resolveWatchScope(_ request: ControlRequest) -> (UUID?, Data?, [SessionWatchEvent]) {
        guard settings.sessionControlEnabled else {
            return (nil, controlError(request, "disabled",
                "Session control is off. Enable it in Termio ▸ Settings ▸ Agents."), [])
        }
        guard let scope = callerScope(session: request.callerSession, cwd: request.callerCwd) else {
            return (nil, controlError(request, "no_scope",
                "Couldn’t tell which project you’re in. Run this from inside a Termio session."), [])
        }
        guard request.snapshot != false else { return (scope.id, nil, []) }
        let snapshot = scope.sessions.map { session -> SessionWatchEvent in
            var event = SessionWatchEvent(
                projectID: scope.id,
                link: sessionLink(for: session),
                status: Self.statusToken(status(for: session.id)),
                title: displayTitle(for: session),
                cwd: runtimes[session.id]?.workingDirectory ?? "",
                snapshot: true)
            attachActionablePayload(to: &event, for: session.id)
            return event
        }
        return (scope.id, nil, snapshot)
    }

    /// Fills in what makes an event actionable without a second round-trip (design
    /// doc §4.3): the on-screen question for `needs-you`, the transcript address +
    /// current length for `done`. Shared by the watch snapshot and the live
    /// `setStatus` broadcast.
    func attachActionablePayload(to event: inout SessionWatchEvent, for id: Session.ID) {
        switch event.status {
        case "needs-you":
            event.prompt = promptExcerpt(for: id)
        case "done":
            // Only the transcript address; `cursorEnd` is filled off the main
            // thread where the event is written (SessionWatchHub), because the
            // line count is an O(file) read and this runs on the main actor.
            event.transcript = transcriptPaths[id]
        default:
            break
        }
    }

    /// The canonical deep link for a session (docs/design/20260801-session-deep-link.md):
    /// full UUID so a link written down anywhere stays unambiguous, channel
    /// scheme so dev and release never claim each other's links.
    func sessionLink(for session: Session) -> String {
        "\(AppChannel.urlScheme)://session/\(session.id.uuidString.lowercased())"
    }

    /// The inverse of `sessionLink`: the session id a canonical link names, or
    /// `nil` for anything else. Exact full-UUID match only (no prefix search) —
    /// this is the machine-to-machine reading, used where a link arrives as an
    /// identifier rather than as something a human typed.
    nonisolated static func sessionID(fromLink link: String) -> UUID? {
        let prefix = "\(AppChannel.urlScheme)://session/"
        guard link.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(link.dropFirst(prefix.count)))
    }

    /// Opens a session deep link. The local form (`termio://session/<id>`)
    /// focuses that session; an endpoint form belongs to the termiod attach
    /// client and is ignored until that lands.
    func openSessionLink(_ url: URL) {
        guard let host = url.host?.lowercased() else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        let idToken: String
        if host == "session", let id = parts.first {
            idToken = id.lowercased()
        } else {
            if parts.first == "session" {
                Log.app.info("session link for endpoint \(host, privacy: .public) ignored — remote attach not wired yet")
            }
            return
        }
        let matches = allSessions.filter {
            $0.id.uuidString.lowercased().hasPrefix(idToken)
        }
        guard matches.count == 1, let session = matches.first else { return }
        revealSession(session.id)
    }

    private func listSessions(in scope: ControlScope, request: ControlRequest) -> Data {
        let machines = fleetMachines()
        let entries = scope.sessions.map { session -> [String: Any] in
            var entry: [String: Any] = [
                "link": sessionLink(for: session),
                "id": Self.shortID(session.id),
                "title": displayTitle(for: session),
                // The *effective* agent, so a plain terminal running a hand-started
                // `claude` reports as Claude to a sibling — the same upgrade the
                // sidebar row shows (see `effectiveAgent`).
                "agent": effectiveAgent(for: session).displayName,
                "status": Self.statusToken(status(for: session.id)),
                "description": statusDescription(for: session.id),
            ]
            // The transcript address, so a caller who wasn't the one to `send`
            // (or who spawned this session before its first hook report) can
            // still find the reply log.
            if let transcript = transcriptPaths[session.id] {
                entry["transcript"] = transcript
            }
            // A spawn whose prompt never appeared on screen looks identical to
            // one working quietly. Saying so here is the only way a caller that
            // already got its "queued" reply can find out.
            if undeliveredPrompts.contains(session.id) {
                entry["prompt_undelivered"] = true
            }
            // What routing by machine and folder needs (docs/design/
            // 20261019-chief-of-staff.md §7.4). Additive, so every caller gets it.
            entry.merge(routingFields(for: session, machines: machines)) { current, _ in current }
            return entry
        }
        // Text output is a column table, the deep link first: the link IS the
        // address (every verb takes it, and it stays self-describing pasted
        // anywhere), while agent and status are display state and must never
        // ride inside the address. The last column is unpadded so long titles
        // never push a ragged right edge into every row.
        let header = "\(scope.name) — \(scope.sessions.count) session(s)"
        var text = header
        if !scope.sessions.isEmpty {
            let titles = ["LINK", "AGENT", "STATUS", "TITLE"]
            let rows = scope.sessions.map { session -> [String] in
                let description = statusDescription(for: session.id)
                // Across machines a title alone is ambiguous; the fleet's rows
                // say where each session runs.
                let title = scope.isFleet
                    ? "\(displayTitle(for: session)) (\(placeLabel(for: session, machines: machines)))"
                    : displayTitle(for: session)
                return [
                    sessionLink(for: session),
                    effectiveAgent(for: session).wireName.lowercased(),
                    Self.statusToken(status(for: session.id)),
                    undeliveredPrompts.contains(session.id)
                        ? "\(title) — prompt may not have been received"
                        : (description.isEmpty ? title : "\(title) — \(description)"),
                ]
            }
            let widths = (0 ..< 3).map { col in
                max(titles[col].count, rows.map { $0[col].count }.max() ?? 0)
            }
            let render: ([String]) -> String = { row in
                (0 ..< 3).map { row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
                    .joined(separator: "  ") + "  " + row[3]
            }
            text = ([header, render(titles)] + rows.map(render)).joined(separator: "\n")
        }
        var json: [String: Any] = ["project": scope.name, "sessions": entries]
        if scope.isFleet { json["devices"] = fleetDevices(machines) }
        return control(request, ok: true, text: text, json: json)
    }

    /// Where a session runs, as the fleet names it: the machine (`local` for
    /// this Mac), the workspace and section it is filed in, its folder, the
    /// branch when Termio already tracks that folder, the name it was given,
    /// whether it is in front of you, and when its status last changed.
    private func routingFields(for session: Session, machines: FleetMachines) -> [String: Any] {
        var fields: [String: Any] = [
            "device": machines.name(forAlias: machineAlias(of: session)) ?? "local",
        ]
        if let workspace = workspace(for: session.id) { fields["workspace"] = workspace.name }
        switch locate(session.id) {
        case .project?:
            fields["section"] = "project"
            if let project = project(for: session.id) { fields["project_name"] = project.name }
        case .terminals?: fields["section"] = "terminals"
        case .chats?: fields["section"] = "chats"
        case nil: break
        }
        let folder = sessionFolder(session)
        if !folder.isEmpty {
            fields["cwd"] = folder
            // Only a branch Termio already watches: reading git per row here would
            // put a process spawn on the request path for every session listed.
            if session.termiodRemoteHost == nil, let branch = branch(forFolder: folder) {
                fields["branch"] = branch
            }
        }
        if let given = session.givenTitle { fields["custom_name"] = given }
        if selectedSessionID == session.id { fields["focused"] = true }
        if let since = runtimes[session.id]?.statusSince {
            fields["status_since"] = Self.isoTimestamp.string(from: since)
        }
        return fields
    }

    /// `this Mac ~/src/termio`, or `devbox ~/src/api`: the machine and folder a
    /// fleet row names.
    private func placeLabel(for session: Session, machines: FleetMachines) -> String {
        let machine = machines.name(forAlias: machineAlias(of: session))
        let folder = sessionFolder(session)
        guard let machine else {
            let local = ChiefOfStaffFeed.abbreviated(folder, home: NSHomeDirectory())
            return local.isEmpty ? Self.thisMacLabel : "\(Self.thisMacLabel) \(local)"
        }
        return folder.isEmpty ? machine : "\(machine) \(folder)"
    }

    /// Every machine Termio knows, once each, so "the devbox is offline" is an
    /// answer the Chief of Staff can give instead of a timeout it has to explain.
    private func fleetDevices(_ machines: FleetMachines) -> [[String: Any]] {
        let remote = machines.machines.map { machine -> [String: Any] in
            var entry: [String: Any] = ["device": machine.name]
            if !machine.aliases.isEmpty { entry["aliases"] = machine.aliases }
            let seen = ([machine.name] + machine.aliases)
                .compactMap { TermiodDeviceRegistry.shared.device(for: TermiodRoute(sshAlias: $0))?.lastSeen }
                .max()
            if let seen { entry["last_seen"] = Self.isoTimestamp.string(from: seen) }
            return entry
        }
        return [["device": "local"]] + remote
    }

    private static let isoTimestamp = ISO8601DateFormatter()

    private func sendText(_ request: ControlRequest, in scope: ControlScope) async -> Data {
        let payload = request.text ?? ""
        // Named keys resolve before anything is typed: a bad name must cost the
        // caller an error, never half a delivery. An unknown name is never sent as
        // literal text — silently typing "escpae" into an agent is the failure mode
        // this whole option exists to remove.
        var keys: [SessionKeyPress] = []
        for name in request.namedKeys {
            guard let press = SessionKeyPress.parse(name) else {
                return controlError(request, "bad_key",
                    "Unknown key '\(name)'. Valid keys: \(SessionKeyPress.vocabulary).")
            }
            // A key this terminal cannot actually send is refused for the same
            // reason a misspelled one is: the alternative is a call that reports
            // success and delivers nothing.
            if let reason = press.undeliverableReason {
                return controlError(request, "bad_key", "'\(name)' can't be pressed. \(reason)")
            }
            keys.append(press)
        }
        guard !payload.isEmpty || !keys.isEmpty else {
            return controlError(request, "no_text", "\(request.op) needs text or a --key to send.")
        }
        let token = request.target?.trimmingCharacters(in: .whitespaces) ?? ""
        if token.isEmpty {
            // A spawn types its prompt into an agent that is still booting; there is
            // no menu there to answer, and no way to time a keypress against a TUI
            // that hasn't drawn yet. Keys address a session that already exists.
            guard keys.isEmpty else {
                return controlError(request, "no_target",
                    "--key needs a session to press it in — run `termio sessions list`.")
            }
            // A bare `send` addresses nobody: it starts a fresh agent session for
            // the prompt. `answer` has no such reading — a menu choice without its
            // session is a mistake, never a spawn.
            guard request.op == "send" else {
                return controlError(request, "no_target",
                    "answer needs a session address — run `termio sessions list`.")
            }
            return await spawnAndSend(request, in: scope, payload: payload)
        }
        switch resolveTarget(token, in: scope) {
        case .found(let session):
            // One writer at a time holds between you and your own Chief of Staff
            // too: its text landing mid-sentence would garble both.
            if scope.isFleet, userTypedRecently(in: session.id, within: Self.userTypingWindow) {
                return controlError(request, "user_typing", """
                    The user is typing in \(sessionLink(for: session)) right now. Tell them, and \
                    send this once they're done.
                    """)
            }
            let state = surface(for: session)
            return await deliver(payload, keys: keys, to: session, state: state, request: request)
        case .notFound:
            return controlError(request, "not_found", targetNotFoundMessage(request.target))
        case .ambiguous:
            return controlError(request, "ambiguous",
                "'\(request.target ?? "")' matches more than one session; use a longer id.")
        }
    }

    /// The no-target `send` path: start a fresh agent session and hand it the
    /// prompt. The agent defaults to the caller's own kind (a Claude asking for
    /// help gets a Claude), then to the user's preferred chat agent; `--agent`
    /// overrides both.
    private func spawnAndSend(_ request: ControlRequest, in scope: ControlScope, payload: String) async -> Data {
        // A place outside the caller's own project is the Chief of Staff's to
        // name, and the Chief of Staff always names one: it has no project of
        // its own for a session to default into.
        if scope.isFleet {
            return await spawnInPlace(request, payload: payload)
        }
        guard request.placeCwd == nil, request.placeProject == nil else {
            return controlError(request, "bad_place", """
                --cwd and --project start a session outside your own project, which only \
                the Chief of Staff may do.
                """)
        }
        // Who is asking, resolved against this project's roster: a sibling agent
        // spawning from inside termio, or nil for a spawn from an outside shell.
        // Drives both defaults below — the new agent's kind and where its pane lands.
        let caller = request.callerSession
            .flatMap(UUID.init(uuidString:))
            .flatMap { id in scope.sessions.first { $0.id == id } }

        let preset: AgentDefinition
        if let name = request.agent, !name.isEmpty {
            // An explicit name may be the plain shell — that is `run`, a terminal
            // session typing a command. Only the *defaults* below are agent-only:
            // nobody asks for a shell by omission.
            guard let resolved = AgentPreset.resolve(name) else {
                let names = AgentPreset.codingAgents.map(\.rawValue).joined(separator: ", ")
                return controlError(request, "bad_agent",
                    "Unknown agent '\(name)'. Try one of: \(names), or terminal.")
            }
            preset = resolved
        } else if let caller, !effectiveAgent(for: caller).isShell {
            preset = effectiveAgent(for: caller)
        } else if let fallback = defaultChatAgent() {
            preset = fallback
        } else {
            return controlError(request, "no_agent",
                "No coding agent is enabled — pass --agent <name>.")
        }

        // Placement requests are validated before anything is created, so a
        // typo'd flag fails the call instead of spawning a session it then
        // places wrong.
        let direction: SplitDirection?
        switch request.direction {
        case nil: direction = nil
        case "right": direction = .horizontal
        case "down": direction = .vertical
        case let other?:
            return controlError(request, "bad_direction",
                "Unknown direction '\(other)'. Use right or down.")
        }
        if let ratio = request.ratio, !(0 < ratio && ratio < 1) {
            return controlError(request, "bad_ratio",
                "--ratio is the new pane's fraction of the split — a number between 0 and 1.")
        }

        // Beside the caller's pane as a split, not a full-screen swap — the whole
        // reason to spawn a sibling is to see them side by side. Anchoring and
        // focus policy are documented on `addSplitSession`; the selection only
        // moves when the caller is the pane the user is already watching.
        let freshID = addSplitSession(
            in: scope, agent: preset, anchor: caller?.id,
            takeFocus: caller == nil || caller?.id == selectedSessionID,
            direction: direction, ratio: request.ratio)
        guard let freshID, let fresh = session(freshID) else {
            return controlError(request, "start_failed", "Couldn’t start the session.")
        }
        // The envelope is agent guidance — typed into a shell it would *execute*
        // as commands, so a `run` session gets the bare command line only.
        let delivered = preset.isShell
            ? payload
            : (callerEnvelope(for: request) ?? "") + payload
        return await deliverToFreshSession(request, fresh: fresh, payload: delivered)
    }

    /// Hands a spawn's prompt (or a `run`'s command line) to the session just
    /// created for it. Shared by a sibling's spawn and the Chief of Staff's.
    private func deliverToFreshSession(
        _ request: ControlRequest, fresh: Session, payload delivered: String
    ) async -> Data {
        // An agent that takes its prompt on its command line gets it there, so no
        // key is typed that a question it asks at startup — a folder-trust prompt,
        // whose first choice is "No, exit" — could take as its answer. Registered
        // before the surface exists, because creating the surface is the launch
        // that reads it.
        if fresh.agent.promptArgument != nil {
            launchPrompts[fresh.id] = delivered
            _ = surface(for: fresh)
            watchLaunchedPrompt(fresh.id)
            guard request.wantsWait else { return spawnQueuedReply(request, fresh) }
            return await waitForReply(request, session: fresh, cursorAtSend: nil,
                                      created: true, launching: true)
        }
        let state = surface(for: fresh)
        // With `--wait`, the caller opted back into blocking — but for the *outcome*
        // (§4.4), never just the plumbing: boot-settle, deliver, then hold the reply
        // until the spawned agent's first turn settles.
        if request.wantsWait {
            await waitForBootSettle(of: state)
            guard await performDelivery(delivered, to: fresh, state: state) else {
                return controlError(request, "not_live",
                    "\(displayTitle(for: fresh)) has no live terminal yet — open it once in Termio.")
            }
            let cursorAtSend: Int?
            if let sendPath = transcriptPaths[fresh.id] {
                cursorAtSend = await Self.lineCountOffMain(of: sendPath)
            } else {
                cursorAtSend = nil
            }
            return await waitForReply(request, session: fresh,
                                      cursorAtSend: cursorAtSend, created: true)
        }
        // Reply with the address now; boot-settle + prompt delivery continue off the
        // reply path so no verb silently blocks (§4.2). A delivery failure has no
        // caller left to tell — it surfaces through the session's own status and
        // its visibly broken pane, which the caller is about to watch anyway.
        let link = sessionLink(for: fresh)
        Task { [weak self] in
            guard let self else { return }
            await self.waitForBootSettle(of: state)
            let before = self.viewportText(for: fresh.id)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if await !self.performDelivery(delivered, to: fresh, state: state) {
                FileHandle.standardError.write(Data(
                    "termio: session control could not deliver the queued prompt to \(link)\n".utf8))
                return
            }
            // Writing the bytes is not the same as the agent receiving them: a
            // startup gate consumes typed text as its own answer, silently. The
            // caller already has its reply and its address, so this is the only
            // place the discrepancy can be recorded at all.
            if await !self.payloadVisiblyLanded(for: fresh.id, before: before) {
                self.noteUndeliveredPrompt(for: fresh.id)
                FileHandle.standardError.write(Data((
                    "termio: the prompt for \(link) was written but the screen did not change — "
                    + "the agent is probably still on a startup prompt and swallowed it. "
                    + "Check the pane, then resend with `termio sessions send`.\n").utf8))
            }
        }
        return spawnQueuedReply(request, fresh)
    }

    /// How long an agent launched with its prompt has to show it started before
    /// its session counts as waiting on the user. Starting takes a few seconds;
    /// the margin is for slow startup hooks.
    static let launchStartWindow: TimeInterval = 20

    /// Watches an agent launched with its prompt on its command line. One that
    /// hasn't shown it started within `launchStartWindow` is held by a question of
    /// its own — a folder-trust prompt, a hooks review — and nothing reports that:
    /// the agent runs no hook until the user answers. So the session is marked as
    /// waiting on the user (`heldAtStartup`), which puts the question in front of
    /// them the way any other is: an amber row, a Chief of Staff event carrying
    /// the screen, a `--wait` that returns it. Someone looking at the session
    /// already sees the question, so the mark goes up when they look away. What
    /// counts as started is decided where reports arrive (`applyTermiodStatus`),
    /// which drops the session from `launchesAwaitingStart` and ends the watch.
    private func watchLaunchedPrompt(_ id: Session.ID) {
        let watching = launchesAwaitingStart[id] != nil
        launchesAwaitingStart[id] = Date().addingTimeInterval(Self.launchStartWindow)
        // One watch per session; calling again only moves its deadline.
        guard !watching else { return }
        Task { [weak self] in
            while let self, let deadline = self.launchesAwaitingStart[id] {
                if deadline.timeIntervalSinceNow > 0 {
                    try? await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
                    continue
                }
                if self.isViewing(id) {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                self.launchesAwaitingStart.removeValue(forKey: id)
                guard let session = self.session(id), self.processEnd(for: session) == nil,
                      self.status(for: id) != .needsAttention
                else { return }
                Log.termiod.notice("""
                \(self.sessionLink(for: session), privacy: .public) hasn't started its prompt \
                after \(Int(Self.launchStartWindow))s; showing it as waiting on you
                """)
                self.heldAtStartup.insert(id)
                self.flagBlockingAttention(for: id)
                return
            }
        }
    }

    /// Whether `id` is an agent launched with its prompt that hasn't yet shown it
    /// started: still being watched, or already marked as waiting on you.
    func isStartingUp(_ id: Session.ID) -> Bool {
        launchesAwaitingStart[id] != nil || heldAtStartup.contains(id)
    }

    /// Input reached an agent that hasn't started yet. Into one marked as waiting
    /// on you, it is the answer: nothing else clears that mark until the agent
    /// reports, and an agent told "No, exit" never does, so it is cleared here.
    /// Either way the watch starts over, in case the agent asks something else
    /// before it starts.
    func noteInputBeforeStart(_ id: Session.ID) {
        if heldAtStartup.remove(id) != nil {
            setStatus(.idle, for: id)
        } else if launchesAwaitingStart[id] == nil {
            return
        }
        watchLaunchedPrompt(id)
    }

    /// `setStatus` kept a held launch waiting on you over another write. Nothing
    /// should make one: the three ways a mark ends each drop it before writing.
    /// So the refusal is recorded with what was attempted, and in a dev build with
    /// the caller, to find whoever tried.
    func refuseStatusOverHeldLaunch(_ status: SessionStatus, for id: Session.ID) {
        let link = session(id).map { sessionLink(for: $0) } ?? id.uuidString
        let caller = AppChannel.isDev
            ? Thread.callStackSymbols.dropFirst(2).prefix(4).joined(separator: " | ") : ""
        Log.termiod.notice("""
        \(link, privacy: .public) is waiting on you before it starts; kept that over \
        \(Self.statusToken(status), privacy: .public) \(caller, privacy: .public)
        """)
    }

    /// How a session's process ended, as a person reads it ("exit 1"), or nil
    /// while it runs. The exit this app saw comes first; a tombstone says the same
    /// only once the next roster sweep brings it.
    func processEnd(for session: Session) -> String? {
        if let code = parkedExits[session.id] { return "exit \(code)" }
        guard let tombstone = termiodEndReason(for: session) else { return nil }
        return tombstone.exitStatus.map { "exit \($0)" } ?? tombstone.reason
    }

    /// The provenance envelope prepended to a spawned session's prompt when the
    /// spawner is itself a termio session (design doc §4.6) — without it the new
    /// agent has no idea who spawned it and can only stop as `needs-you` and hope.
    /// It opens exactly one back-channel: a mid-task question, or a one-line
    /// completion ping, via `sessions send` to the caller. The hard limits ride in
    /// the envelope text itself because agent↔agent messaging invites loops and
    /// injection — no conversation, no delegating work back, and completion stays
    /// transcript-as-truth (the supervisor's `watch`/transcript path remains the
    /// reliable backstop). A plain-shell caller resolves no session → no envelope.
    private func callerEnvelope(for request: ControlRequest) -> String? {
        guard let callerID = request.callerSession, let uuid = UUID(uuidString: callerID),
              let caller = session(uuid) else { return nil }
        let callerLink = sessionLink(for: caller)
        return """
        [termio] You were spawned by the sibling agent session \(callerLink). \
        If you hit a question only they can answer, ask it mid-task with: \
        termio sessions send \(callerLink) "QUESTION: <your question>" — and when \
        you finish you may send at most one line: \
        termio sessions send \(callerLink) "DONE: <one line>". \
        Use this channel for nothing else: no conversation, no status updates, and \
        never delegate tasks back to them. They read your actual results from your \
        transcript, so put everything that matters in your normal replies. \
        Your task follows.

        """
    }

    /// How long a keystroke in a session holds the Chief of Staff's sends off it.
    static let userTypingWindow: TimeInterval = 4

    /// The Chief of Staff's spawn and run (docs/design/20261019-chief-of-staff.md
    /// §7.4): a session started where it names — a folder on this Mac,
    /// `machine:path` on another one, or a project — in a tab of its own that
    /// never takes focus. No provenance envelope: a session it starts reaches it
    /// through the event feed, not by sending back.
    private func spawnInPlace(_ request: ControlRequest, payload: String) async -> Data {
        let preset: AgentDefinition
        if let name = request.agent, !name.isEmpty {
            guard let resolved = AgentPreset.resolve(name) else {
                let names = AgentPreset.codingAgents.map(\.rawValue).joined(separator: ", ")
                return controlError(request, "bad_agent",
                    "Unknown agent '\(name)'. Try one of: \(names), or terminal.")
            }
            preset = resolved
        } else if let fallback = chiefOfStaffAgent() {
            preset = fallback
        } else {
            return controlError(request, "no_agent", "No coding agent is enabled — pass --agent <name>.")
        }

        let fresh: Session
        if let token = request.placeProject?.trimmingCharacters(in: .whitespaces), !token.isEmpty {
            guard request.placeCwd == nil else {
                return controlError(request, "bad_place", "Name one place: --cwd or --project, not both.")
            }
            let matches = projects.filter {
                $0.name.lowercased() == token.lowercased() || $0.path == token
            }
            guard let project = matches.first, matches.count == 1 else {
                return controlError(request, matches.isEmpty ? "not_found" : "ambiguous",
                    matches.isEmpty
                        ? "No project named '\(token)'. `--cwd` takes any folder."
                        : "'\(token)' names more than one project; pass its path.")
            }
            guard !isOnAnotherDevice(project) else {
                return controlError(request, "bad_place", """
                    \(project.name) is on another machine. Name its folder there instead: \
                    --cwd <machine>:<path>.
                    """)
            }
            guard let id = addSession(to: project.id, agent: preset, takeFocus: false),
                  let created = session(id) else {
                return controlError(request, "start_failed", "Couldn’t start the session.")
            }
            fresh = created
        } else if let raw = request.placeCwd {
            let devices = DeviceRoster.known(in: self).compactMap(\.alias)
            switch SpawnPlace.parse(raw, knownDevices: Set(devices)) {
            case .failure(.empty):
                return controlError(request, "no_place", "--cwd needs a folder: [machine:]path.")
            case .failure(.unknownDevice(let alias)):
                let known = devices.isEmpty ? "only this Mac" : devices.joined(separator: ", ")
                return controlError(request, "unknown_device",
                    "No machine called '\(alias)'. Termio knows \(known).")
            case .success(let place):
                if let host = place.device {
                    guard let created = await addRemoteSession(host: host, path: place.path, agent: preset) else {
                        return controlError(request, "start_failed",
                            "Couldn’t start a session on \(host). Is it reachable, with termiod set up?")
                    }
                    fresh = created
                } else {
                    let path = SpawnPlace.expanding(place.path, home: NSHomeDirectory())
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                          isDirectory.boolValue else {
                        return controlError(request, "no_folder", "There is no folder at \(path) on this Mac.")
                    }
                    guard let id = addLooseSession(agent: preset, in: path), let created = session(id) else {
                        return controlError(request, "start_failed", "Couldn’t start the session.")
                    }
                    fresh = created
                }
            }
        } else {
            return controlError(request, "no_place",
                "Name where it starts: --cwd [machine:]path, or --project <name>.")
        }
        activateInBackground(fresh.id)
        return await deliverToFreshSession(request, fresh: fresh, payload: payload)
    }

    /// A session on another machine, in `path` there. `~` means that account's
    /// home, which only the machine itself can say.
    private func addRemoteSession(host: String, path: String, agent: AgentPreset) async -> Session? {
        var resolved = path
        if path == "~" || path.hasPrefix("~/") {
            let route = TermiodRoute(sshAlias: host)
            let home: String? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try Termiod.deviceHome(route: route))
                    } catch {
                        Log.termiod.error("""
                        chief of staff: \(host, privacy: .public) did not say where home is: \
                        \(error.localizedDescription, privacy: .public)
                        """)
                        continuation.resume(returning: nil)
                    }
                }
            }
            guard let home else { return nil }
            resolved = SpawnPlace.expanding(path, home: home)
        }
        let id: Session.ID? = await withCheckedContinuation { continuation in
            addRemoteTerminal(host: host, agent: agent, cwd: resolved, inBackground: true) { id in
                continuation.resume(returning: id)
            }
        }
        return id.flatMap { session($0) }
    }

    func companionSendToChief(sessionID: String, text: String) async -> CompanionControl {
        guard let id = UUID(uuidString: sessionID), isChiefOfStaff(id),
              settings.chiefOfStaffEnabled, let chief = session(id) else {
            return .error(message: "The Chief of Staff is no longer available. Refresh the session list.",
                          code: "not_chief")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(message: "There’s no text to send.", code: "no_text")
        }
        guard chiefOfStaff.agentReady, processEnd(for: chief) == nil else {
            return .error(message: "Open the Chief of Staff to finish startup. If it’s ready, send one message there.",
                          code: "not_ready")
        }
        guard !chiefOfStaff.delivering else {
            return .error(message: "The Chief of Staff is receiving a message. Try again.", code: "busy")
        }
        guard !userTypedRecently(in: id, within: Self.userTypingWindow) else {
            return .error(message: "You’re typing in the Chief of Staff on your Mac. Finish that message first.",
                          code: "user_typing")
        }
        chiefOfStaff.delivering = true
        defer { chiefOfStaff.delivering = false }
        guard await refreshChiefOfStaffReadiness() else {
            return .error(message: "Open the Chief of Staff to finish startup.", code: "not_ready")
        }
        let delivered = await performDelivery(text, to: chief, state: surface(for: chief),
            canDeliver: {
                guard await self.refreshChiefOfStaffReadiness() else { return false }
                return self.settings.chiefOfStaffEnabled && self.isChiefOfStaff(id)
                    && self.chiefOfStaff.agentReady && self.processEnd(for: chief) == nil
                    && !self.userTypedRecently(in: id, within: Self.userTypingWindow)
            }, onDelivery: {
                self.noteChiefOfStaffUserInput()
            })
        guard delivered else {
            return .error(message: "The Chief of Staff couldn’t receive the message. Open it on your Mac.",
                          code: "not_live")
        }
        lastUserInputAt[id] = Date()
        return .sent(sessionID: id.uuidString)
    }

    /// Types `payload` into an existing sibling's surface and builds the reply.
    /// Without `--wait` the reply is the send acknowledgement (the transcript path
    /// + a cursor to read the response from); with it, the call blocks until the
    /// turn settles and reports the outcome plus the transcript range it landed in.
    private func deliver(
        _ payload: String, keys: [SessionKeyPress] = [], to session: Session,
        state: TerminalViewState, request: ControlRequest
    ) async -> Data {
        guard await performDelivery(payload, keys: keys, to: session, state: state,
                                    submit: request.wantsEnter) else {
            return controlError(request, "not_live",
                "\(displayTitle(for: session)) has no live terminal yet — open it once in Termio.")
        }
        guard request.wantsWait else { return await sentReply(request, session) }
        // The cursor to read the reply from: wherever the transcript stands right
        // after submitting. A session's transcript often isn't known until a hook
        // fires mid-turn, so this can be nil and is re-read after the wait.
        let cursorAtSend: Int?
        if let sendPath = transcriptPaths[session.id] {
            cursorAtSend = await Self.lineCountOffMain(of: sendPath)
        } else {
            cursorAtSend = nil
        }
        // Answering an agent's startup question starts it, so the wait is the
        // launch's: its boot is not the reply.
        return await waitForReply(request, session: session,
                                  cursorAtSend: cursorAtSend, created: false,
                                  launching: isStartingUp(session.id))
    }

    /// Types `payload` into a session's live surface and submits it. Shared by
    /// the existing-sibling reply path and the fresh-spawn detached delivery.
    /// `submit` is false for `--no-enter`, where the payload *is* the keypress a
    /// prompt is waiting on and a Return would answer a second question.
    /// `keys` are the `--key` presses, fired after the text in the order named;
    /// naming any of them also turns `submit` off, so nothing is pressed that the
    /// caller did not ask for.
    func performDelivery(
        _ payload: String, keys: [SessionKeyPress] = [], to session: Session,
        state: TerminalViewState, submit: Bool = true,
        canDeliver: () async -> Bool = { true }, onDelivery: () -> Void = {}
    ) async -> Bool {
        // The libghostty surface attaches lazily on the pane's first render, so a
        // session never shown in the UI has no surface yet. A background mount adds
        // it to the mounted set *without* moving the user's selection (a sibling
        // driving a pane the user isn't watching must stay silent), then poll for
        // the attach rather than betting on one render cycle: right after app
        // launch several panes render at once and one cycle isn't enough — a `run`
        // session's near-instant boot-settle hit that window as a spurious
        // not_live. (A session mounted even once stays mounted, so this only fires
        // on the very first drive.)
        if state.surface == nil { activateInBackground(session.id) }
        let attachDeadline = Date().addingTimeInterval(3)
        while state.surface == nil, Date() < attachDeadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard await canDeliver(), let surfaceHandle = Self.rawSurface(from: state) else { return false }
        onDelivery()
        noteInputBeforeStart(session.id)

        // Write the payload as raw PTY bytes, then submit with a real Return *key
        // event* — `pressReturn` leaves the encoding to Ghostty, which emits what
        // the program's keyboard mode expects, and a "\r" appended to the payload
        // cannot (an agent TUI reads one inside a paste as a newline, never a
        // submit). `ghostty_surface_key` drives the surface directly, with no focus
        // or first-responder needed; this is exactly how Ghostty's own AppleScript
        // `send key` submits Enter.
        if !payload.isEmpty { Self.writeRaw(payload, to: state) }
        // Named keys ride the same encoder as the Return above, for the same reason:
        // only Ghostty knows whether this program wants `ESC [ A` or `ESC O A`. They
        // fire in the order named, each after the same settle the submit takes, so a
        // TUI that redraws between keystrokes keeps up.
        for press in keys {
            try? await Task.sleep(for: .milliseconds(40))
            Self.pressKey(press, on: surfaceHandle)
        }
        guard submit else {
            undeliveredPrompts.remove(session.id)
            return true
        }
        try? await Task.sleep(for: .milliseconds(40))
        guard await canDeliver(), Self.rawSurface(from: state) == surfaceHandle else { return false }
        Self.pressReturn(on: surfaceHandle)
        // Whatever went wrong with the spawn prompt, someone has since driven
        // this session by hand; the warning has served its purpose.
        undeliveredPrompts.remove(session.id)
        return true
    }

    /// Records that a spawned session's prompt was written but never showed up
    /// on its screen. Cleared the moment anything is delivered to that session
    /// again, so it describes the present rather than accumulating history.
    func noteUndeliveredPrompt(for id: Session.ID) {
        undeliveredPrompts.insert(id)
    }

    /// Whether the payload visibly reached the program, checked by watching the
    /// screen rather than by understanding the program.
    ///
    /// `performDelivery` reports whether the bytes could be *written*, which is a
    /// weaker claim than it looks: an agent still on a startup gate — Codex's
    /// hook-trust prompt, a usage notice, a first-run dialog — consumes typed
    /// text as an answer to its own question and shows nothing. The write
    /// succeeds and the prompt is gone.
    ///
    /// That gate also defeats `waitForBootSettle`, whose readiness test is two
    /// identical frames: a program waiting for a keypress is *perfectly* still.
    /// So readiness cannot be established before typing; it can only be
    /// confirmed after. Text entering a composer always redraws it — no TUI
    /// accepts input invisibly — so an unchanged screen means the payload went
    /// somewhere this caller did not intend.
    ///
    /// Deliberately advisory: it reports, and never retypes. A second attempt
    /// against a dialog that swallowed the first is how one stray prompt becomes
    /// two menu answers.
    private func payloadVisiblyLanded(
        for id: Session.ID, before: String?
    ) async -> Bool {
        // Long enough for a composer to repaint, short enough that a caller
        // watching the reply does not notice. A TUI that redraws slower than this
        // reports a false negative, which costs a log line and nothing else.
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(120))
            let now = viewportText(for: id)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if now != before { return true }
        }
        return false
    }

    /// Puts `payload` into the session's PTY as raw bytes, NOT through
    /// `state.send`: that routes into `ghostty_surface_text`, whose input encoder
    /// re-encodes a hand-written ESC as an escape KEYPRESS (CSI 27u under the
    /// kitty keyboard protocol agents enable) and frames everything as a paste.
    /// A `send` could therefore only ever deliver *text* — never the bare `t` a
    /// Codex trust gate is waiting on, never an `esc` to back out of a menu. Raw
    /// input is the same path the file tree's "Add to Chat" takes
    /// (`addSnippetToSelectedSessionPrompt`), for the same reason.
    ///
    /// A payload carrying newlines keeps its bracketed-paste framing — added here,
    /// in the PTY bytes, where it means what it says — so a multi-line prompt still
    /// lands as one pasted block instead of submitting line by line. A single-line
    /// payload goes verbatim, which is what makes a lone keypress possible.
    ///
    /// Anything but the in-memory backend (no host-managed PTY to write to) falls
    /// back to the surface, which is better than dropping the send.
    private static func writeRaw(_ payload: String, to state: TerminalViewState) {
        guard case let .inMemory(backend) = state.configuration.backend else {
            _ = state.send(payload)
            return
        }
        let bytes = payload.contains("\n")
            ? "\u{1B}[200~" + payload + "\u{1B}[201~"
            : payload
        backend.sendInput(Data(bytes.utf8))
    }

    /// Blocks until the session the prompt was sent to finishes its turn — or stops
    /// to ask the user (`needs-you`) — or the timeout elapses, then reports the
    /// outcome. This is what lets a caller issue one `send --wait` instead of
    /// sending and then polling `list` in a loop.
    ///
    /// Completion is read primarily from the **status resting**: the turn is done once
    /// the session, having been seen `working`, drops back off `working` and stays there
    /// for `settleWindow` (`needs-you` short-circuits immediately). Status is the signal
    /// every real agent drives — built-ins via hooks, rule-based agents via the screen
    /// classifier — and unlike a raw screen watch it is immune to a TUI footer that keeps
    /// animating after the reply. A 300ms poll always catches the `working` span of a real
    /// turn (an LLM round-trip is far longer). Only a session with no status signal at all
    /// — a plain terminal driven by `send --wait` — falls back to the screen first changing
    /// and then going still; an agent session reaching that fallback (every status channel
    /// missed the turn) must sit still for the longer `agentSettleWindow` first. Each poll
    /// awaits off the actor, so a long wait never blocks other control requests (§4.2
    /// stays true even mid-wait).
    ///
    /// Two failure modes end the wait early instead of burning the whole timeout,
    /// both adopted from herdr's agent-wait design:
    /// - **Stalled prompt**: from a non-`working` start, *some* effect — a status
    ///   move or a screen change — must appear within `stallWindow`, or the
    ///   keystrokes were eaten (a half-booted TUI, a program that ignores typed
    ///   text) and no turn is coming: `prompt_stalled`, immediately. A `--timeout`
    ///   at or under the window keeps the plain timeout reply instead.
    /// - **Occupant gone**: the wait is pinned to the session and agent it started
    ///   on. The session closing mid-wait is `session_closed`; its agent exiting
    ///   back to a plain shell, or its process ending outright, is `agent_gone`.
    ///   (A plain-terminal target is exempt from the agent pin — a sent command
    ///   line may legitimately start an agent in the pane, which is progress, not
    ///   replacement.)
    ///
    /// `launching` is a wait on an agent that took its prompt on its command line
    /// (`launchPrompts`). Nothing was typed, so there is no stall to detect, and
    /// its boot is not its turn: until the agent shows it started
    /// (`launchesAwaitingStart`), neither a boot animation the screen streak reads
    /// as `working` nor the paint of the boot screen counts. One held by a startup
    /// question comes back as `needs-you`, from `watchLaunchedPrompt`.
    private func waitForReply(
        _ request: ControlRequest, session: Session,
        cursorAtSend: Int?, created: Bool, launching: Bool = false
    ) async -> Data {
        let cap = min(max(request.timeoutMs ?? 300_000, 1_000), 600_000)
        let started = Date()
        let deadline = started.addingTimeInterval(Double(cap) / 1_000)
        let settleWindow = 1.5
        // The screen-only settle below is meant for a session with *no status
        // signal at all* — but it is reached by an agent session too whenever
        // every status channel missed the turn, and there 1.5s of stillness is
        // weak evidence: both Codex and Claude Code sit visually still for
        // spells early in a turn (issue #545 settled on exactly that, seconds
        // after the send). An agent occupant therefore holds for a longer
        // still window — past `userInputQuietWindow` (3s, the send itself
        // counts as input) plus the promotion streak's two 1s samples, so a
        // turn that *keeps repainting* is promoted to `working` before this
        // fallback can settle. That is a trade, not a proof: a turn that goes
        // screen-silent mid-turn (a long tool call with no spinner repaint)
        // can still settle early, and no finite window closes that — the
        // alternative is burning the caller's whole timeout for every
        // status-less turn that finished quietly. A plain terminal keeps the
        // short window — a shell prompt going quiet after output *is* the
        // turn end.
        let agentSettleWindow = 6.0
        let stallWindow = 5.0

        let statusAtSend = status(for: session.id)
        let occupantAtSend = effectiveAgent(for: session)
        var sawWorking = false
        var restingSince: Date?
        var lastFrame = viewportText(for: session.id)
        var lastChangeAt = started
        var changedSinceSend = false
        var settled: SessionStatus?

        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
            guard let live = self.session(session.id) else {
                return controlError(request, "session_closed",
                    "\(sessionLink(for: session)) was closed while waiting on it.")
            }
            let occupant = effectiveAgent(for: live)
            // The process ending outright — an agent that quit at a startup
            // question, or crashed — leaves the row on screen, so the occupant
            // still reads as the agent and only the exit tells.
            let ended = processEnd(for: live)
            if ended != nil || (occupantAtSend != .terminal && occupant.id != occupantAtSend.id) {
                let who = occupantAtSend == .terminal
                    ? "The shell" : "The \(occupantAtSend.displayName) agent"
                var message = "\(who) in \(sessionLink(for: session)) exited mid-wait"
                if let ended { message += " (\(ended))" }
                message += "; no reply is coming."
                if let transcript = transcriptPaths[session.id] {
                    message += " Its transcript (\(transcript)) holds whatever it did first."
                }
                return controlError(request, "agent_gone", message)
            }

            let current = status(for: session.id)
            let hasStarted = !launching || !isStartingUp(session.id)
            if current == .working, hasStarted {
                sawWorking = true
                restingSince = nil
            } else if current != .working, restingSince == nil {
                restingSince = Date()
            }

            let now = Date()
            let frame = viewportText(for: session.id)
            if frame != lastFrame {
                lastFrame = frame
                lastChangeAt = now
                changedSinceSend = true
            }

            // needs-you settles the wait immediately — but only as *new* evidence.
            // A session already blocked at send time (the caller is answering its
            // menu) must not read as "still waiting on you" on the first poll,
            // before the agent has had a chance to react to the answer.
            if current == .needsAttention,
               statusAtSend != .needsAttention || sawWorking || changedSinceSend {
                settled = .needsAttention
                break
            }

            if !launching, statusAtSend != .working, !sawWorking, !changedSinceSend,
               current == statusAtSend,
               Double(cap) / 1_000 > stallWindow,
               now.timeIntervalSince(started) >= stallWindow {
                return controlError(request, "prompt_stalled",
                    "The prompt showed no effect in \(sessionLink(for: session)) within "
                    + "\(Int(stallWindow))s — no status change, no screen change. The input "
                    + "was likely eaten (agent still booting, or a program that ignores "
                    + "typed text); check the pane before resending.")
            }

            guard current != .working else { continue }
            let rested = restingSince.map { now.timeIntervalSince($0) >= settleWindow } ?? false
            let quietWindow = occupant == .terminal ? settleWindow : agentSettleWindow
            let screenQuiet = now.timeIntervalSince(lastChangeAt) >= quietWindow
            // Status-tracked agent: seen working, now rested. (Footer animation can't
            // fool this — it doesn't touch status.)
            if sawWorking, rested { settled = current; break }
            // No status signal at all: the screen changed, then stilled — for the
            // window the occupant earns (see `agentSettleWindow`). Never for a
            // launch, whose screen changing is its boot.
            if !launching, !sawWorking, changedSinceSend, screenQuiet { settled = current; break }
        }
        return await waitReply(request, session: session,
                               cursorAtSend: cursorAtSend, created: created, settled: settled)
    }

    /// The reply for a completed (or timed-out) `--wait`. Every wait reply — `send`
    /// or `spawn` — shares one shape (§4.4): the turn's final `status` and the exact
    /// transcript range to read, `cursor` (where the reply begins, captured at send)
    /// through `cursor_end` (the log's length now), so the caller's own file tools
    /// read precisely the new content, no polling. When the session is blocked on
    /// the user (`needs-you`), the on-screen question rides along as `prompt` so the
    /// caller can answer without scraping the viewport.
    private func waitReply(
        _ request: ControlRequest, session: Session,
        cursorAtSend: Int?, created: Bool, settled: SessionStatus?
    ) async -> Data {
        let link = sessionLink(for: session)
        let statusToken = Self.statusToken(status(for: session.id))
        var json: [String: Any] = [
            "target": link,
            "title": displayTitle(for: session),
            "status": statusToken,
            "timed_out": settled == nil,
        ]
        if created { json["created"] = true }

        let headline: String
        switch settled {
        case .needsAttention: headline = "\(link) is waiting on you"
        case .some: headline = "\(link) finished (\(statusToken))"
        case nil: headline = "\(link) still \(statusToken) after the wait — timed out"
        }
        var text = headline

        // The transcript may only have become known during the wait (a fresh
        // session's first hook), so re-read it here rather than trusting the
        // send-time snapshot.
        if let transcript = transcriptPaths[session.id] {
            let start = cursorAtSend ?? 0
            let end = await Self.lineCountOffMain(of: transcript)
            json["transcript"] = transcript
            json["cursor"] = start
            json["cursor_end"] = end
            text += "\n  transcript: \(transcript)\n  reply: lines \(start)–\(end) (read this range)"
        }
        if settled == .needsAttention, let prompt = promptExcerpt(for: session.id) {
            json["prompt"] = prompt
            text += "\n  on screen:\n\(prompt)"
        }
        return control(request, ok: true, text: text, json: json)
    }

    /// The current viewport text of a session's terminal, or nil when it has no live
    /// in-memory backend yet (never rendered). Reads only an already-mounted surface —
    /// deliberately no `surface(for:in:)` fallback, so a status broadcast can never
    /// create a surface as a side effect. Reads through the backend's own lock
    /// (`readViewportText`), so it's safe from this actor.
    func viewportText(for id: Session.ID) -> String? {
        guard let state = surfaces[id],
              case .inMemory(let terminal) = state.configuration.backend else { return nil }
        return terminal.readViewportText()
    }

    /// The tail of a session's screen — the question or menu the agent stopped on —
    /// for `needs-you` payloads. The last dozen non-blank rows (right-trimmed, size-
    /// capped) are enough to answer from; the leading rows are the conversation the
    /// caller already has via the transcript.
    func promptExcerpt(for id: Session.ID) -> String? {
        guard let lines = screenLines(for: id), !lines.isEmpty else { return nil }
        return String(lines.suffix(12).joined(separator: "\n").suffix(1_200))
    }

    /// A session's viewport as display rows — right-trimmed, trailing blank rows
    /// dropped — or nil when it has no live surface. The shared source for the
    /// `needs-you` excerpt and the `read` verb.
    private func screenLines(for id: Session.ID) -> [String]? {
        guard let screen = viewportText(for: id) else { return nil }
        var lines = screen.components(separatedBy: "\n").map { line -> String in
            var trimmed = Substring(line)
            while trimmed.last == " " { trimmed.removeLast() }
            return String(trimmed)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// `read`: a sibling's current screen. This is the result channel for a `run`
    /// session — a plain command has no transcript, its output *is* the screen —
    /// and a focus-free peek at any agent's live TUI. Viewport only (what a glance
    /// at the pane would show); scrollback needs a terminal-core buffer API this
    /// build doesn't have. `--lines` keeps just the tail.
    private func readScreen(_ request: ControlRequest, in scope: ControlScope) async -> Data {
        switch resolveTarget(request.target, in: scope) {
        case .found(let session):
            // The Chief of Staff reads sessions nobody has opened, so it mounts
            // one in the background the way `send` already does, instead of
            // answering "open it once in Termio" to someone on their phone.
            if scope.isFleet, surfaces[session.id]?.surface == nil {
                _ = surface(for: session)
                activateInBackground(session.id)
            }
            // A surface exists before SSH and the attach snapshot arrive. Its
            // empty buffer is not evidence that the remote screen is blank.
            guard var lines = await Self.waitForControlScreen(sample: {
                guard self.termiodLinks[session.id]?.hasReceivedScreenOutput == true else { return nil }
                return self.screenLines(for: session.id)
            }) else {
                return controlError(request, "screen_pending",
                    "\(displayTitle(for: session))’s screen has not arrived yet. Try reading it again.")
            }
            if let cap = request.lines, cap > 0 { lines = Array(lines.suffix(cap)) }
            let screen = lines.joined(separator: "\n")
            return control(request, ok: true,
                text: screen.isEmpty ? "(blank screen)" : screen,
                json: ["target": sessionLink(for: session),
                       "title": displayTitle(for: session), "screen": screen])
        case .notFound:
            return controlError(request, "not_found", targetNotFoundMessage(request.target))
        case .ambiguous:
            return controlError(request, "ambiguous",
                "'\(request.target ?? "")' matches more than one session; use a longer id.")
        }
    }

    static func waitForControlScreen(timeout: TimeInterval = 3,
                                     sample: () -> [String]?) async -> [String]? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let lines = sample() { return lines }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return nil }
        } while Date() < deadline
        return nil
    }

    /// Waits for a freshly launched agent TUI to finish booting before keystrokes
    /// are typed into it — text sent into a half-drawn banner is simply eaten.
    /// Only for an agent that can't take its prompt on its command line
    /// (`AgentDefinition.promptArgument`); one that can is never typed into.
    /// There is no boot hook to wait on (Claude's `SessionStart` hook only fires
    /// on `clear`), so readiness is read off the screen itself: two consecutive
    /// identical non-empty viewport frames mean the boot paint has settled. Capped
    /// because some TUIs animate their banner forever; the cap then just sends,
    /// which is no worse than not having waited.
    private func waitForBootSettle(of state: TerminalViewState, timeout: TimeInterval = 10) async {
        guard case .inMemory(let terminal) = state.configuration.backend else {
            try? await Task.sleep(for: .milliseconds(1500))
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        // Give the process a beat to start painting at all before sampling frames,
        // or the pre-banner blank screen counts as two identical frames.
        try? await Task.sleep(for: .milliseconds(700))
        var previous: String?
        while Date() < deadline {
            let frame = terminal.readViewportText()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let frame, !frame.isEmpty {
                if frame == previous { return }
                previous = frame
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    /// The raw `ghostty_surface_t` behind a session's surface — the C entry point
    /// for `ghostty_surface_key`, whose Swift wrapper the package marks `internal`.
    /// `rawValue` is the package's documented escape hatch for exactly this; it
    /// replaced an earlier reflection read of the private stored property, which
    /// would have started returning nil silently the first time the field was
    /// renamed upstream.
    private static func rawSurface(from state: TerminalViewState) -> ghostty_surface_t? {
        state.surface?.rawValue
    }

    /// Sends a Return key press (and release) to the surface — the submit a user makes
    /// by pressing Enter, and the shape every `--key` press takes.
    private static func pressReturn(on surface: ghostty_surface_t) {
        pressKey(.return, on: surface)
    }

    /// Sends one key press (and release) to the surface. `keycode` is the native
    /// macOS virtual key, exactly what an `NSEvent` would carry, and `text` is nil
    /// for every special key and chord so Ghostty's own key encoder emits the
    /// correct bytes for whatever keyboard mode the program negotiated — the whole
    /// point of naming a key instead of hand-writing its escape sequence.
    /// `ghostty_surface_key` drives the surface directly, with no focus or
    /// first-responder needed.
    private static func pressKey(_ press: SessionKeyPress, on surface: ghostty_surface_t) {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if press.modifiers.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if press.modifiers.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if press.modifiers.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if press.modifiers.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }

        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.mods = ghostty_input_mods_e(mods)
        // Consumed modifiers are the ones the *keyboard layout* already spent
        // producing text, which the encoder must then not encode a second time. A
        // real NSEvent learns them from macOS; a synthetic press knows them exactly,
        // because it decided the text itself: Shift, when it shifted a character,
        // and nothing else. Marking Alt consumed here would eat the ESC prefix that
        // makes `--key alt-b` a meta chord at all.
        event.consumed_mods = ghostty_input_mods_e(
            press.text == nil ? GHOSTTY_MODS_NONE.rawValue : (mods & GHOSTTY_MODS_SHIFT.rawValue))
        event.keycode = press.keycode
        event.unshifted_codepoint = press.unshiftedCodepoint
        event.composing = false
        // `text` must stay alive for the duration of the C call, so the press and
        // release both happen inside the borrow.
        let send: (UnsafePointer<CChar>?) -> Void = { text in
            event.text = text
            event.action = GHOSTTY_ACTION_PRESS
            _ = ghostty_surface_key(surface, event)
            event.action = GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(surface, event)
        }
        if let text = press.text {
            text.withCString { send($0) }
        } else {
            send(nil)
        }
    }

    /// The success reply for a send/answer. Beyond confirming delivery, it hands back
    /// the session's transcript address and a cursor (its line count at send time), so
    /// the caller can read the agent's response straight from its own structured log —
    /// the caller's file tools resume from `cursor`.
    private func sentReply(_ request: ControlRequest, _ session: Session) async -> Data {
        let link = sessionLink(for: session)
        var json: [String: Any] = [
            "target": link,
            "title": displayTitle(for: session),
        ]
        var text = "sent to \(link)"
        if let transcript = transcriptPaths[session.id] {
            let cursor = await Self.lineCountOffMain(of: transcript)
            json["transcript"] = transcript
            json["cursor"] = cursor
            text += "\n  transcript: \(transcript)\n  cursor: \(cursor)  (read the response from here on)"
        }
        return control(request, ok: true, text: text, json: json)
    }

    /// The immediate reply for a fresh spawn: the address is the payload, delivery is
    /// still in flight (`queued`). A just-spawned session has no transcript yet — it
    /// appears in `list --json` once the agent's hook reports one. A `run` session
    /// never will: a plain command's results are read off its screen (`read`).
    private func spawnQueuedReply(_ request: ControlRequest, _ session: Session) -> Data {
        let link = sessionLink(for: session)
        let json: [String: Any] = [
            "target": link,
            "title": displayTitle(for: session),
            "created": true,
            "queued": true,
        ]
        let text: String
        if effectiveAgent(for: session).isShell {
            text = "started \(link) — command queued; use this address for follow-ups"
                + "\n  (read its output with `termio sessions read \(link)`)"
        } else {
            text = "started \(link) — prompt queued; use this address for follow-ups"
                + "\n  (transcript path appears in `termio sessions list --json` once the agent reports it)"
        }
        return control(request, ok: true, text: text, json: json)
    }

    /// Newline count of a whole transcript — the cursor a caller resumes a read
    /// from. The count must be exact (an off-by-one hands an agent the wrong
    /// reply lines), so it is always the true count, never cached against a
    /// mutable file. The cost is the read itself, which is why every caller runs
    /// it off the main thread: the hot path (the `done` watch event) counts on
    /// the hub's serial queue, and the request-reply paths await `lineCountOffMain`.
    /// Reading it inline on the main actor stalled the UI once transcripts reached
    /// tens of MB (a spinning cursor under memory pressure).
    nonisolated static func lineCount(of path: String) -> Int {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            // A session with no transcript yet is 0 lines, not an error; a path
            // that exists but won't open is one, so it is logged.
            if FileManager.default.fileExists(atPath: path) {
                Log.app.error("transcript open failed for \(path, privacy: .public)")
            }
            return 0
        }
        defer {
            do { try handle.close() } catch {
                Log.app.error("""
                transcript close failed for \(path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
        do {
            var lines = 0
            while let chunk = try handle.read(upToCount: 1 << 18), !chunk.isEmpty {
                lines += chunk.withUnsafeBytes { buffer in
                    buffer.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
                }
            }
            return lines
        } catch {
            Log.app.error("""
            transcript line count failed for \(path, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """)
            return 0
        }
    }

    /// `lineCount` on a utility queue. Awaited by every main-actor caller so the
    /// O(file) read never runs on the main thread.
    nonisolated static func lineCountOffMain(of path: String) async -> Int {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: lineCount(of: path))
            }
        }
    }

    private func closeTab(_ request: ControlRequest, in scope: ControlScope) -> Data {
        switch resolveTarget(request.target, in: scope) {
        case .found(let session):
            let link = sessionLink(for: session)
            let title = displayTitle(for: session)
            closeSession(session.id)
            return control(request, ok: true, text: "closed \(link) (\(title))",
                json: ["closed": link, "title": title])
        case .notFound:
            return controlError(request, "not_found", targetNotFoundMessage(request.target))
        case .ambiguous:
            return controlError(request, "ambiguous",
                "'\(request.target ?? "")' matches more than one session; use a longer id.")
        }
    }

    /// Selects the session in the sidebar and brings termio to the front — the
    /// "come look at this" verb, for jumping to an agent's live pane from any shell.
    private func focusSession(_ request: ControlRequest, in scope: ControlScope) -> Data {
        switch resolveTarget(request.target, in: scope) {
        case .found(let session):
            let link = sessionLink(for: session)
            revealSession(session.id)
            return control(request, ok: true, text: "focused \(link)", json: ["focused": link])
        case .notFound:
            return controlError(request, "not_found", targetNotFoundMessage(request.target))
        case .ambiguous:
            return controlError(request, "ambiguous",
                "'\(request.target ?? "")' matches more than one session; use a longer id.")
        }
    }

    /// Resolves the calling agent to its project: by the `TERMIO_SESSION` the PTY
    /// carries (exact), else by a working directory that sits inside a project's
    /// directory or one of its session worktrees (the fallback for a plain shell).
    private func callerScope(session id: String?, cwd: String?) -> ControlScope? {
        if let id, let uuid = UUID(uuidString: id), let home = locate(uuid) {
            // Scope follows identity, never a flag: the one session with the
            // Chief of Staff's role sees the fleet, and nothing another caller
            // can pass widens its own (docs/design/20261019-chief-of-staff.md §7.4).
            if self[home].role == .chief { return fleetScope() }
            return scope(at: home)
        }
        guard let cwd else { return nil }
        let target = URL(fileURLWithPath: cwd).standardizedFileURL.path
        func contains(_ directory: String) -> Bool {
            let base = URL(fileURLWithPath: directory).standardizedFileURL.path
            return target == base || target.hasPrefix(base + "/")
        }
        // A session worktree is the most specific match, so prefer it.
        for (index, project) in projects.enumerated() {
            for session in project.sessions where session.worktreePath.map(contains) == true {
                return scope(at: .project(project: index, session: 0))
            }
        }
        if let index = projects.firstIndex(where: { contains($0.path) }) {
            return scope(at: .project(project: index, session: 0))
        }
        // A shell started inside the loose-chat directory is one of the Chats
        // rows, or something the user ran there by hand; either way its siblings
        // are the current workspace's chats.
        guard contains(Self.looseChatRoot),
              let index = workspaces.firstIndex(where: { $0.id == currentWorkspace.id })
        else { return nil }
        return scope(at: .chats(workspace: index, session: 0))
    }

    /// The roster one slot belongs to, named the way `list` prints it. The Chief
    /// of Staff is in no one's roster: it is filed among its workspace's chats,
    /// but only you and Termio talk to it.
    private func scope(at home: SessionSlot) -> ControlScope {
        switch home {
        case .project(let index, _):
            let project = projects[index]
            return ControlScope(id: project.id, name: project.name,
                                sessions: project.sessions, project: project)
        case .terminals(let index, _):
            let workspace = workspaces[index]
            return ControlScope(id: workspace.id, name: "\(workspace.name) — Terminals",
                                sessions: workspace.terminals.filter { $0.role != .chief }, project: nil)
        case .chats(let index, _):
            let workspace = workspaces[index]
            return ControlScope(id: workspace.id, name: "\(workspace.name) — Chats",
                                sessions: workspace.chats.filter { $0.role != .chief }, project: nil)
        }
    }

    /// The `watch` key every fleet subscriber shares. Fixed, because it only has
    /// to differ from every project and workspace id, which are random.
    nonisolated static let fleetScopeID = UUID(uuid: (
        0xC5, 0x1E, 0xF0, 0xF5, 0x7A, 0xFF, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01))

    /// Every session in every workspace on every connected machine, minus the
    /// Chief of Staff itself.
    private func fleetScope() -> ControlScope {
        ControlScope(id: Self.fleetScopeID, name: "All sessions",
                     sessions: allSessions.filter { $0.role != .chief }, project: nil,
                     isFleet: true)
    }

    /// What one `termio sessions` call can see: the caller's own roster.
    ///
    /// A caller inside a project sees that project's sessions; a caller in a loose
    /// shell or chat sees the other rows in its workspace's same section. Both are
    /// "the siblings you can reach", which is the rule the CLI has always followed —
    /// it just used to be spelled "the project", because a funnel was one.
    struct ControlScope {
        /// The project's id, or the workspace's for a loose caller. It is what a
        /// `watch` stream is keyed by, so it only has to be stable and unique.
        let id: UUID
        let name: String
        let sessions: [Session]
        /// The folder a spawned sibling opens in. `nil` for a loose caller: a
        /// scratch session has no project to open another one in.
        let project: Project?
        /// The Chief of Staff's scope: every session, guarded by where its turn
        /// came from (`ChiefOfStaffGuard`).
        var isFleet = false
    }

    private enum TargetResolution {
        case found(Session)
        case notFound
        case ambiguous
    }

    /// Matches a target token within the caller's project. A deep link
    /// (`termio://…/session/<id>`) reduces to its id (full UUID or prefix);
    /// a bare token keeps the plain forms — full id, id prefix, or display
    /// title (case-insensitive). Ambiguity is reported rather than guessed.
    private func resolveTarget(_ token: String?, in scope: ControlScope) -> TargetResolution {
        guard let token = token?.trimmingCharacters(in: .whitespaces).lowercased(), !token.isEmpty else {
            return .notFound
        }
        if let idPart = Self.addressedID(in: token) {
            guard !idPart.isEmpty, idPart.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
                return .notFound
            }
            let matches = scope.sessions.filter {
                $0.id.uuidString.lowercased().hasPrefix(idPart)
            }
            switch matches.count {
            case 0: return .notFound
            case 1: return .found(matches[0])
            default: return .ambiguous
            }
        }
        // Match the *displayed* title only, never the stored one: `list` shows the
        // display title (terminals are re-indexed live), so that's what an agent
        // references. The stored title is an internal worktree-slug seed and can
        // collide with another session's display title — matching it would make an
        // unambiguous name read as ambiguous.
        let matches = scope.sessions.filter { session in
            let id = session.id.uuidString.lowercased()
            return id == token
                || id.hasPrefix(token)
                || displayTitle(for: session).lowercased() == token
        }
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0])
        default: return .ambiguous
        }
    }

    /// The id half of a link in *this channel's* scheme (any endpoint authority):
    /// the path segment after `session/`. Nil for a bare token — and for another
    /// channel's scheme, whose ids address a different app's sessions entirely.
    /// Accepting those would let a `termio-dev://` link prefix-match a release
    /// session; `targetNotFoundMessage` names the mismatch instead.
    private static func addressedID(in token: String) -> String? {
        guard let separator = token.range(of: "://"),
              token[token.startIndex..<separator.lowerBound] == AppChannel.urlScheme.lowercased()
        else { return nil }
        let rest = token[separator.upperBound...]
        guard let marker = rest.range(of: "session/") else { return nil }
        return String(rest[marker.upperBound...].prefix { $0 != "?" && $0 != "/" })
    }

    private func targetNotFoundMessage(_ token: String?) -> String {
        let raw = token ?? ""
        // A well-formed link in the *other* channel's scheme is not a bad address,
        // it's an address for the other app — so say that, rather than sending the
        // caller off to re-check an id that was right all along.
        if let separator = raw.range(of: "://") {
            let scheme = raw[raw.startIndex..<separator.lowerBound].lowercased()
            if scheme.hasPrefix("termio"), scheme != AppChannel.urlScheme {
                return """
                    '\(raw)' addresses the \(scheme) channel; this app owns \
                    \(AppChannel.urlScheme):// links. Use that channel's CLI instead.
                    """
            }
        }
        return "No session '\(raw)' in this project. Run `termio sessions list` to see the links."
    }

    private func control(_ request: ControlRequest, ok: Bool, text: String, json: [String: Any]) -> Data {
        if request.wantsJSON {
            var object = json
            object["ok"] = ok
            // Every JSON reply pins the contract it speaks (§4.5) — agents are
            // coding against these shapes, and versioning them beats breaking them.
            object["schema_version"] = 1
            let data = (try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return data + Data("\n".utf8)
        }
        return Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
    }

    private func controlError(_ request: ControlRequest, _ code: String, _ message: String) -> Data {
        control(request, ok: false, text: "error: \(message)", json: ["error": code, "message": message])
    }

    private static func shortID(_ id: Session.ID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    static func statusToken(_ status: SessionStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .working: return "working"
        case .done: return "done"
        case .needsAttention: return "needs-you"
        }
    }
}
