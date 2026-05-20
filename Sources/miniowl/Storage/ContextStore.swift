import Foundation

/// File-backed store for the user's personalization context.
///
/// Free-form text store where the user describes their work, projects,
/// taxonomy preferences, and tone preferences. The server appends this
/// to the categorization prompt, so every user gets a customized
/// experience without any hardcoded persona on the server.
///
/// File: `~/Library/Application Support/miniowl/context.md`
///
/// Design choices:
/// - Markdown extension so TextEdit/VSCode render headings nicely
/// - Read per-request (not cached) — edits take effect on the very next
///   categorize call without any reload button
/// - Size-capped at 2 KB to bound LLM cost and prompt bloat
/// - Control characters stripped at read time (security + prompt safety)
/// - Missing/empty file is legal — server falls back to generic defaults
struct ContextStore {
    let dataDir: URL

    /// Upper bound on context size after trimming. Users often write
    /// several paragraphs of rules, examples, tone preferences — a few
    /// KB is normal. 8 KB covers that comfortably; LLM input cost at
    /// 24 calls/day is ~$0.05/day extra per user = trivial.
    /// Server-side cap (in miniowl_prompts.py) is matched at 8 KB.
    static let maxBytes = 8192

    var fileURL: URL {
        dataDir.appendingPathComponent("context.md")
    }

    // MARK: - Read

    /// Read the context file and return a sanitized string. Returns nil
    /// if the file is missing, unreadable, or contains only placeholder
    /// comments (lines starting with `#` that aren't markdown headings).
    ///
    /// Sanitization:
    /// - Strip ASCII control chars (0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F, 0x7F)
    /// - Cap at `maxBytes` UTF-8 bytes (truncate mid-word if needed)
    /// - Trim outer whitespace
    func read() -> String? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        // Strip control chars except \n, \t, \r
        let cleaned = raw.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v == 0x09 || v == 0x0A || v == 0x0D { return true }
            if v < 0x20 { return false }
            if v == 0x7F { return false }
            return true
        }
        let text = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty { return nil }

        // Cap at maxBytes (UTF-8)
        if text.utf8.count > Self.maxBytes {
            let truncated = String(text.utf8.prefix(Self.maxBytes))
                ?? String(text.prefix(Self.maxBytes))  // fallback if bytes cut mid-codepoint
            return truncated
        }
        return text
    }

    // MARK: - Initialize placeholder

    /// Create a helpful placeholder file on first launch. The placeholder
    /// uses markdown so `open -t` renders it nicely and the user sees
    /// worked examples they can edit.
    func initializeIfMissing() {
        if FileManager.default.fileExists(atPath: fileURL.path) { return }

        let placeholder = """
        # Context for Miniowl categorization

        > EDIT THIS FILE to personalize how miniowl categorizes your time.
        > The server reads this on every categorize call (no app reload needed).
        > Max 8 KB. Empty = use defaults; the more specific you are, the
        > sharper the categorization gets.

        ## Who I am

        [Your role + 1–2 sentences. Example: "Software engineer at a fintech
        startup, working remotely from Tokyo. Heads-down builder; meetings
        drain me."]

        ## My projects / focus areas

        - [Project name] — what it is
        - [Other responsibilities]

        ## My apps

        [List apps/sites you use heavily so miniowl maps them right. Example:
        "Linear = Planning, Notion = Writing, Slack = Chat, Figma = Design,
        VSCode/iTerm = Coding."]

        ## My tone preference

        [How blunt do you want the summary? "Direct" / "Encouraging" /
        "Neutral data only". Default is neutral data-led summaries.]

        ## My ideal allocation (weekday targets, optional)

        [Example: "Coding 50%, Meetings 20%, Email 10%, Planning 10%, other 10%."]

        ## Categories

        The default 12 categories below cover most knowledge work. Edit, rename,
        or add to fit your role. If you delete this section entirely, the LLM
        falls back to inferring categories from your activity.

        - **Coding** — Software development, debugging, code review, building features
        - **Design** — UI/UX, graphics, Figma, prototyping, visual work
        - **Writing** — Docs, blog posts, articles, reports, specifications
        - **Research** — Reading articles, market research, data analysis, deep work
        - **Meetings** — Video calls (Zoom/Meet/Teams), in-person, async standups
        - **Email** — Email triage, replies, threads in any mail client
        - **Chat** — Slack, Teams, Discord, Telegram (work)
        - **Planning** — Sprint planning, task lists, project management (Linear/Jira/Notion)
        - **Customer** — Sales, support, user interviews, customer-facing communication
        - **Learning** — Courses, tutorials, documentation reading, skill building
        - **Admin** — Invoices, expenses, scheduling, paperwork, taxes, ops
        - **Personal** — Non-work activity — breaks, social media (personal), errands
        """
        try? placeholder.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Open in editor

    /// Open the context file in the user's default text editor. Uses
    /// `open -t` so the file opens in whatever editor the user prefers
    /// for .md files.
    func openInEditor() {
        initializeIfMissing()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-t", fileURL.path]
        try? task.run()
    }
}
